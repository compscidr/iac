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
4. Run `ansible-playbook -i inventory.yml jasonernst_com.yml --tags mailu --ask-become-pass`
   (the mailu role lives in `jasonernst_com.yml`, hosts `www`) → `contact@` alias live.
5. Run `projects.yml` (rustd tags) → postgres + app up, TLS issued, Flyway migrates.
6. Run `nas.yml` (rustd-backup tags) → authorizes the backup key on the nas. **Must run
   after step 5, not before**: the `rustd_backup_nas` role slurps the backup public key
   live off the projects droplet, which doesn't exist until `projects.yml` has generated
   it there. This is a one-time bootstrap ordering constraint, not enforced by tooling —
   see `ansible/roles/rustd_backup_nas/README.md` ("First-run ordering"). After both
   playbooks have run once, re-running either is idempotent and the ordering no longer
   matters.
7. `docker logs rustd-xyz` → claim URL → claim the panel.
8. Add servers/credentials in the panel; flip demo/signup switches when ready to go public.
9. Confirm first nightly backup landed on the nas.

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
- Backup restore drill: after step 9, `pg_restore` the nas dump into a scratch container once,
  documented in the role README.

## Out of scope

- Footer Privacy/Terms/GitHub placeholders (deferred separately).
- Monitoring/alerting beyond fail2ban + docker restart policies (nothing else on the droplet
  has it either).
- Zero-downtime deploys (recreate = seconds of downtime; acceptable for this panel).

## Implementation notes

Deviations from this design, accumulated across the implementation tasks. Deviations that
belong to the `rustd.xyz` repo (Part A, e.g. `.dockerignore` adjustments) are recorded in that
repo's own PR, not here — this section covers only the iac-side implementation (Part B).

- **Backup keypair generated on the droplet, not the ansible controller.** The design's stated
  default (§B3, implicit) was controller-side `community.crypto.openssh_keypair` generation,
  templating the private key out to the droplet and the public key out to the nas. Implemented
  the opposite: the droplet generates its own ed25519 keypair on first run
  (`ssh-keygen -f ... -N "" `, gated by `creates:`) and the private half never leaves it — not
  copied to the controller, not put in 1Password, not templated anywhere. A controller-generated
  private key would have to land in some file on the operator's own machine with no place in this
  repo's secret model to account for it (not a 1Password item, not otherwise version-controlled),
  which is exactly the kind of stray artifact this repo's "secrets are 1Password lookups, never
  files" convention exists to avoid. Only the public key is ever read off the droplet, via a live
  `slurp` delegated from `nas.yml`. Full rationale in
  `ansible/roles/rustd_xyz/README.md` ("Key flow") and `ansible/roles/rustd_backup_nas/README.md`
  ("Key-flow rationale"). This also means **`nas.yml` must run after `projects.yml` has run at
  least once** — added as runbook step 6 above (was implicit/undocumented before this note).
- **`community.crypto` is not in `requirements.yml`**, so the design's assumed
  `openssh_keypair` module wasn't available regardless of the generation-location decision above;
  used the plan's allowed `ansible.builtin.command: ssh-keygen ... creates:` fallback instead.
- **Nas storage root is `/volume1/storage/backups/rustd-db`**, not the design/plan's placeholder
  `/volume/backups/rustd-db` — `/volume1` is the nas' actual (only) data mount, confirmed from
  `roles/media_server` (`media_storage_base_path: /volume1/storage`) and `roles/cs2_game`
  (`/volume1/storage/cs2`); there is no `/volume` share on the real box.
- **`mailu_install_path`, not `mailu_base_path`.** The design/plan's illustrative alias task used
  `chdir: "{{ mailu_base_path }}"`; the role's real variable (used throughout `tasks/main.yml`) is
  `mailu_install_path`. Used the real one. Likewise `changed_when` on the alias task follows the
  existing `Create mail users` task's idiom (`changed_when: false`, with a comment that a looped
  command's register doesn't give a reliable single-instance `rc` to key off), not the plan's
  illustrative `changed_when: mailu_alias_result.rc == 0`.
- **Dropped the droplet's stale `# $12/mo` cost comment** when resizing (Task 1) rather than
  updating it to a new figure — it described the old `s-1vcpu-2gb` size and would have been
  actively misleading left in place next to the new `s-2vcpu-4gb` line; the new required comment
  already explains the resize.
- **`QUARKUS_MAILER_TLS=true` confirmed by disassembly, not assumption.** The design flagged this
  as needing verification against the pinned Quarkus version. Extracted
  `quarkus-mailer-3.38.1.jar` from the local Gradle cache (the exact artifact rustd.xyz's build
  resolves, per its `libs.versions.toml`) and read the bytecode with `javap`: both
  `quarkus.mailer.tls` and the deprecated `quarkus.mailer.ssl` feed the same Vert.x
  `MailConfig#setSsl(true)` (implicit TLS, wrap-from-connect) — the correct mechanism for Mailu's
  port 465. `quarkus.mailer.start-tls` is a separate, inapplicable STARTTLS-upgrade knob. Evidence
  recorded in `ansible/roles/rustd_xyz/tasks/main.yml` (inline comment) and the role README
  ("Mailer TLS").
- **Atomic backup dumps** (fixed after initial review): the backup script originally wrote
  `pg_dump` output straight to its final filename
  (`rustd-<date>.dump`). A `pg_dump` that dies partway (disk full, OOM, host reboot mid-run)
  would leave a truncated file at that name — which the *next* night's successful run would then
  rsync to the nas indistinguishably from a good backup, silently corrupting the offsite copy.
  Fixed by dumping to `<name>.dump.tmp` and `mv`-ing into place only after `pg_dump` exits 0
  (`set -euo pipefail` means a failed `pg_dump` never reaches the `mv`); added `rm -f` of any
  leftover `.tmp` at the top of the script and excluded `*.tmp` from the rsync push, in case a
  dump is still in flight when the script's own rsync step runs.

None of the above required changing this design's Decisions table or Part A; they're
implementation-detail resolutions of things the design flagged as needing verification, plus one
bug fix (atomic dumps) found in review.
