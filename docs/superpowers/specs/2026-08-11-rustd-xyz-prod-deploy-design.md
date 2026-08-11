# rustd.xyz production deployment — design

**Date:** 2026-08-11
**Status:** Approved (brainstormed with Jason; all four forks decided by him)
**Repos touched:** `compscidr/rustd.xyz` (image + prod config + publish workflow) and this repo (terraform resize, new ansible role, mailu alias, backups)
**Prior art:** `docs/superpowers/specs/2026-08-05-rustd-xyz-dns-mail-design.md` (DNS/mail, #481 — apex already points at the projects droplet; `jason@` and `noreply@rustd.xyz` Mailu users already exist), the `sair_portal` role (the deployment shape this mirrors).

## Goal

rustd.xyz runs in production on the projects droplet: containerized Quarkus app behind the
existing nginx-proxy/LetsEncrypt pair, postgres alongside it, magic-link mail through Mailu,
nightly DB dumps to the nas, and a working `contact@rustd.xyz` (the landing page has linked it
since rustd.xyz#375 — it currently bounces).

## Decisions (made 2026-08-11)

| Fork | Decision | Rejected alternatives |
|---|---|---|
| Capacity | Resize projects droplet to `s-2vcpu-4gb` (~$24/mo) | GraalVM native (Mina SSHD/krcon reflection risk), tuned-JVM-on-2GB (OOM risk with 7 tenant containers), separate droplet (more hosts) |
| Image publish | Every merge to main → `ghcr.io/compscidr/rustd.xyz:latest` + `:<sha>` | Tagged releases (adds a release step to a merge-to-main project) |
| Database | `postgres:17` container, named volume, nightly `pg_dump` shipped off-box | DO managed postgres ($15/mo), no-backup container |
| Backup destination | nas over the tailnet (rsync over SSH, dedicated key) | DO Spaces (new bill + s3 plumbing), droplet-local only |

## Part A — rustd.xyz repo

### A1. Dockerfile

Quarkus JVM fast-jar, two stages: `gradle build` (tests run in CI before this) → copy
`build/quarkus-app` onto `eclipse-temurin:21-jre`, non-root user, `EXPOSE 8080`,
`java -jar quarkus-run.jar`. No native image.

### A2. Prod configuration

Everything host-specific arrives as environment variables (Quarkus maps
`QUARKUS_DATASOURCE_JDBC_URL`, `QUARKUS_DATASOURCE_USERNAME`, `QUARKUS_DATASOURCE_PASSWORD`,
`QUARKUS_MAILER_HOST/PORT/USERNAME/PASSWORD/TLS` natively — no properties changes needed for
those). `application.properties` gains only `%prod` entries that aren't env-shaped (audit at
implementation time; expected: none or near-none — `rustd.auth.trust-forwarded-for` is already
`%prod=true`, correct behind nginx-proxy's `X-Forwarded-For`; mailer mock is already dev/test-only).
Flyway migrates on startup, so an empty prod DB self-initializes; the first-boot claim URL
prints to the container log (`docker logs rustd-xyz`), and the panel starts private (demo and
signup are DB-backed runtime switches, default off).

### A3. Publish workflow

`.github/workflows/publish.yml`: on push to `main` — gradle build (tests included), docker
build, push `:latest` + `:<sha>` to GHCR. `:<sha>` tags are the rollback mechanism (set
`rustd_xyz_image` to a pinned sha in ansible and re-run). Deploys remain explicit playbook runs
— no watchtower, same as sair.

## Part B — this repo

### B1. Terraform: droplet resize

`projects.tf`: `size = "s-1vcpu-2gb"` → `"s-2vcpu-4gb"`. In-place resize; **disk grows too and
that is one-way** (can never resize back below the disk size). Requires a shutdown window of a
few minutes for every tenant on the droplet.

### B2. Ansible: new `rustd_xyz` role (mirrors `sair_portal`)

- GHCR login (same PAT lookup as sair).
- Private docker network `rustd-db` (the DB is never on `nginx-proxy`).
- `postgres:17` container: named volume `rustd-db-data`, env from a **new 1Password item**
  (`Infrastructure` vault, suggested name `rustd-db`) — the one manual pre-step.
- App container `rustd-xyz`: image `ghcr.io/compscidr/rustd.xyz:latest` (var-overridable for
  rollback), networks `nginx-proxy` + `rustd-db`, `pull: true`, `recreate: true`,
  `restart_policy: unless-stopped`, env:
  - `VIRTUAL_HOST=rustd.xyz`, `VIRTUAL_PORT=8080`, `LETSENCRYPT_HOST=rustd.xyz` — **apex only,
    never www** (the `__Host-` auth cookie is pinned to the apex; #481's spec already documents
    the no-www rule, and rustd.xyz must never be added to `www_redirect_domains`).
  - `QUARKUS_DATASOURCE_*` pointing at the `rustd-db` network alias.
  - `QUARKUS_MAILER_*` from the existing `SMTP_USER - rustd` 1Password item; host
    `mail.rustd.xyz`, port 465 (sair's pattern is `mail.<domain>`:465 against the same Mailu —
    the mail hostname is already on Mailu's SAN cert per #481).
  - No `RUSTD_AUTH_BASE_URL` needed: `rustd.auth.base-url` already defaults to
    `https://rustd.xyz` with dev/test overrides — the prod default is the prod value.
- Wired into `projects.yml` after `www_redirect`, alongside the other roles.

### B3. Backups

Role-managed on the droplet: a script + systemd timer (`rustd-db-backup.timer`, nightly) that
`docker exec`s `pg_dump -Fc` into `/opt/rustd/backups/`, prunes to 7 local dumps, and rsyncs
the directory to the nas over the tailnet as a dedicated non-root user with a dedicated ed25519
key. nas side (nas playbook): create the backup user + `authorized_keys` (restricted to rsync),
target path on the storage pool, prune to 30 days. Network path needs no ACL change today
(droplets are member devices; the member→`*` grant covers it) — **caveat:** if droplets are
ever moved to tagged identities, a `projects → nas:22` grant must be added.

### B4. Mailu: alias support + contact@

The mailu role manages users but not aliases. Add an alias task (`flask mailu alias <local>
<domain> <destination>`, same idempotent failed_when-tolerant shape as user creation) driven by
a `mailu_aliases`-style var, and define `contact@rustd.xyz → jason@rustd.xyz`. This closes the
bouncing landing-page mailto from rustd.xyz#375.

## Runbook (deploy order)

1. Create the `rustd-db` 1Password item (manual).
2. Terraform resize (tenant downtime window).
3. Merge the rustd.xyz PR → image appears on GHCR.
4. Run the mail playbook → `contact@` alias live.
5. Run `projects.yml` (rustd tags) → postgres + app up, TLS issued, Flyway migrates.
6. `docker logs rustd-xyz` → claim URL → claim the panel.
7. Add servers/credentials in the panel; flip demo/signup switches when ready to go public.
8. Confirm first nightly backup landed on the nas.

## Error handling / operational notes

- App crash-loops (bad DB creds, Mailu unreachable): `restart_policy: unless-stopped` retries;
  diagnosis via `docker logs`. Flyway failure aborts startup by design — never boots on a
  half-migrated schema.
- LetsEncrypt: apex cert issuance follows the same companion flow as every other tenant; DNS
  already resolves, so no ordering hazard.
- The panel dials OUT to game servers (RCON websocket, SSH) — no inbound ports beyond 443/80.
- Postgres is reachable only on the `rustd-db` docker network; no published port.

## Testing

- rustd repo: existing full suite in CI gates the publish job; the Dockerfile is smoke-tested in
  the workflow (container starts, `/q/health`-less — hit `/login` for 200) before push.
- iac repo: `ansible-lint`/molecule per repo convention; the role's first real run IS the
  deploy (matches how every other role here is validated).
- Backup restore drill: after step 8, `pg_restore` the nas dump into a scratch container once,
  documented in the role README.

## Out of scope

- Footer Privacy/Terms/GitHub placeholders (deferred separately).
- Monitoring/alerting beyond fail2ban + docker restart policies (nothing else on the droplet
  has it either).
- Zero-downtime deploys (recreate = seconds of downtime; acceptable for this panel).
