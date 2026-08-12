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
target path on the storage pool, prune to 30 days. **Superseded in deploy, see Implementation
notes:** this whole ssh-based design (both the original `rrsync` transport and its
forced-command-receive-script replacement) was unimplementable on the real nas hardware —
vendor-patched `rsync`, a global sshd `ForceCommand`, and admin-account passthrough closed off
every layer of the intended ssh jail independently. The final, proven-working transport is the
nas' own **rsync daemon** (UGOS UI, port 873, manual prerequisite), not ssh at all — see
Implementation notes for the full field story and the resulting shared-credential security
follow-up. Network path needs no ACL change today (droplets are member devices; the member→`*`
grant covers it); the daemon runs on port 873, not 22, so the caveat below is now moot unless a
future change moves the receive port too — **caveat:** if droplets are ever moved to tagged
identities, a `projects → nas:873` grant must be added.

### B4. Mailu: alias support + contact@

The mailu role manages users but not aliases. Add an alias task (`flask mailu alias <local>
<domain> <destination>`, same idempotent failed_when-tolerant shape as user creation) driven by
a `mailu_aliases`-style var, and define `contact@rustd.xyz → jason@rustd.xyz`. This closes the
bouncing landing-page mailto from rustd.xyz#375.

## Runbook (deploy order)

1. Create the `rustd-db` 1Password item (manual).
2. Enable the nas' rsync daemon in the UGOS UI (manual, one-time): Rsync service on,
   module `storage` → `/volume1/storage`, auth user `jason:rw`. See
   `ansible/roles/rustd_backup_nas/README.md` ("Manual prerequisite") — ansible cannot do
   this step, it's a closed vendor UI.
3. Terraform resize (tenant downtime window).
4. Merge the rustd.xyz PR → image appears on GHCR.
5. Run `ansible-playbook -i inventory.yml jasonernst_com.yml --tags mailu --ask-become-pass`
   (the mailu role lives in `jasonernst_com.yml`, hosts `www`) → `contact@` alias live.
6. Run `projects.yml` (rustd tags) → postgres + app up, TLS issued, Flyway migrates, backup
   timer installed (first push happens at the next 04:30 window, or run the timer's unit
   manually to test sooner).
7. Run `nas.yml` (rustd-backup tags) → joins the nas to the tailnet and installs the
   prune cron. No key-authorization step, no bootstrap ordering constraint against step 6
   — the rsync daemon (step 2) is independent of anything either playbook generates, so
   steps 6 and 7 can run in either order, and both are idempotent on re-run.
8. `docker logs rustd-xyz` → claim URL → claim the panel.
9. Add servers/credentials in the panel; flip demo/signup switches when ready to go public.
10. Confirm first nightly backup landed on the nas.

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
- Backup restore drill: after step 10, `pg_restore` the nas dump into a scratch container once,
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
- **[SUPERSEDED — the entire ssh/forced-command receive design below was later removed; see
  "The ssh-based receive design was removed outright and replaced with the nas' built-in rsync
  daemon" further down. This bullet is retained only as field history: `rustd-receive-dump`,
  the `command=,restrict` key, and `rustd_xyz_backup_nas_user` no longer exist.]**
  **Receiver identity on the nas is the vendor account `jason`, not a dedicated
  `rustd-backup` user.** The design's assumed shape (and this role's first implementation)
  was a dedicated locked system user, `rustd-backup`, holding the receive-side end of the
  restricted key. Field deploy discovery found the nas appliance's vendor PAM/login stack
  refuses to run the forced command for a locked account at all ("This account is currently
  not available"), independent of the shell-in-`/etc/shells` issue the design already
  anticipated (hence the earlier decision to give `rustd-backup` a real `/bin/bash` shell
  instead of `nologin`). Unlocking a dedicated system account wasn't a fix this role wanted
  to own on a vendor-managed appliance, so the receiver identity is instead `jason` — the
  appliance's real, unlocked, vendor-managed account — with `rustd_xyz_backup_nas_user`
  (`group_vars/all.yml`) repointed at it. The forced command remains the actual security
  boundary either way: `command="/usr/local/bin/rustd-receive-dump",restrict` on the
  authorized key means nothing about the underlying account's broader privileges is
  reachable through that key, so this is the standard deploy-key pattern (jail a shared or
  third-party account down to one script) rather than a weakening of the original design.
  `rustd_backup_nas` now has no user-creation task at all — Ansible only appends to
  `jason`'s `authorized_keys` and never touches the account itself — and carries a one-time
  cleanup block that removes the abandoned `rustd-backup` authorized_key entry and account
  on any host that still has it. Full rationale in `ansible/roles/rustd_backup_nas/README.md`
  ("Restricted key").

None of the above required changing this design's Decisions table or Part A; they're
implementation-detail resolutions of things the design flagged as needing verification, plus one
bug fix (atomic dumps) found in review.

- **The nas was not a tailnet member.** §B3's "Network path needs no ACL change today
  (droplets are member devices; the member→`*` grant covers it)" implicitly assumed both ends of
  the backup pipeline were already on the tailnet. Deploy discovery found otherwise: the
  `tailscale` package was present on the nas but `tailscaled` had never been enabled and
  `tailscale up` had never been run — it was never actually a member, so the ACL analysis had
  nothing to grant against on that side. Resolved by having `rustd_backup_nas` own a minimal
  join (install is an idempotent no-op since the package already exists; enable the daemon;
  `tailscale up --hostname=nas --accept-dns=false`, no `--ssh`) rather than routing the nas
  through `common_cli` (the repo's usual tailnet-join path), since the nas is a vendor-managed
  UGREEN appliance where package/config changes are kept to the minimum this pipeline needs. See
  `ansible/roles/rustd_backup_nas/README.md` ("Tailnet membership") for the full rationale.
- **The nas' vendor rsync can't receive, so the `rrsync` design (§B3) was replaced with a
  forced-command receive script.** With the tailnet join working, deploy testing hit a second,
  unrelated blocker: the nas' `/usr/bin/rsync` is a vendor-patched build (UGREEN, version 3.4.1)
  that rejects every server-side receive with a custom `not support path` error, regardless of
  the destination path given. There is no stock rsync to install as a workaround — this is a
  closed vendor appliance and installing packages on it is forbidden — and `rrsync` itself just
  shells out to that same broken `rsync` binary, so no packaging of `rrsync` (real binary or the
  gzipped-script fallback) could have worked around it. The rrsync-based forced-command design
  in `rustd_backup_nas` (rsync install, rrsync discovery/extract/resolve, and the `:/`
  destination contract on the push side) was therefore unimplementable on this hardware and was
  removed outright, not patched around.
  Replacement protocol: the droplet ships each dump as
  `ssh <nas-key> rustd-<date>.dump < dumpfile` — one `ssh` connection per file, the bare
  filename as the (sole) remote command, the dump itself on stdin. The nas' authorized key is
  now restricted to `command="/home/<user>/receive-dump.sh",restrict`, a small script deployed
  by `rustd_backup_nas` (owned `root:root`, mode `0755` — deliberately not owned by the backup
  user whose key it constrains) that validates `SSH_ORIGINAL_COMMAND` against a strict
  `^rustd-[0-9]{4}-[0-9]{2}-[0-9]{2}\.dump$` filename regex (no `/`, so no path traversal),
  then streams stdin to `<name>.tmp` and `mv`s it into place. This needs only `sshd` and `bash`
  on the nas — no rsync protocol surface at all — and is arguably tighter than the original
  `rrsync` design: the client controls nothing but which of a fixed filename pattern it's
  writing, there's no read/list/delete verb to expose, and the receiver can't itself be broken
  by a vendor rsync build. The push script now re-ships *every* local dump each night (not just
  the newest one) rather than a single rsync of the whole directory — each dump is ~50KB, so
  resending all `rustd_xyz_backup_local_keep` (7) nightly is cheap, and since the receive script
  overwrites via an atomic `mv`, re-sending a dump the nas already has is an idempotent no-op
  rather than a duplicate; this also makes the pipeline self-healing after a missed night. The
  nas-side prune cron (`rustd_backup_nas`) additionally sweeps `*.dump.tmp` leftovers (from a
  dead/interrupted upload) older than 1 day. Full rationale in
  `ansible/roles/rustd_backup_nas/README.md` ("Restricted key") and
  `ansible/roles/rustd_xyz/README.md` ("Receive protocol").
- **The forced-command receive script above was itself defeated, and the entire
  ssh-based receive design (§B3, and every note above about `rrsync`, restricted keys,
  `receive-dump.sh`, and the dedicated `rustd-backup`/`jason` receiver identity) was
  removed outright and replaced with the nas' built-in rsync daemon.** Real-world
  deploy testing of the forced-command receiver (this doc's previous entry) uncovered
  two further blockers that, together with the already-known broken vendor `rsync`,
  made *any* ssh-jail design on this hardware unimplementable, not just the specific
  `rrsync` variant:
  1. **`sshd` on the appliance has a GLOBAL `ForceCommand`** that overrides any per-key
     `command=` in `authorized_keys`. The forced-command receiver's entire security
     model — "this key can only ever run `rustd-receive-dump`" — assumed per-key
     `command=` takes precedence, which is the normal OpenSSH behavior but is not what
     this vendor sshd config does. On this box, the global directive wins regardless of
     what an individual key's `authorized_keys` entry says, so a key that ssh's in gets
     whatever the global `ForceCommand` runs, not the receive script.
  2. **Admin-privileged accounts get full command passthrough** through that global
     `ForceCommand` anyway (a common vendor-appliance pattern: the forced command is a
     restricted shell for ordinary users but a no-op for admins) — so even if per-key
     restriction had worked, routing the receiver through an account with any admin
     adjacency would not have contained it the way the design intended.
  Combined with the earlier-documented vendor-`rsync` breakage, every layer of the
  intended jail (rsync protocol, forced command, restricted key) turned out to be
  closed off independently by the vendor firmware — no amount of patching the receive
  script or picking a different receiver account could have worked, because the
  vulnerability wasn't in this repo's script, it was in assuming sshd on this appliance
  behaves like stock OpenSSH.
  **The working replacement, proven end-to-end** (a real `pg_dump` landed on the nas'
  91TB bcache array, over the tailnet, verified present on disk): UGOS's own **rsync
  daemon**, port 873, entirely outside sshd — none of the three sshd-side blockers
  apply to it, because it was never going through sshd. Enabling it is a **manual UGOS
  UI prerequisite** ansible cannot perform (closed vendor appliance, no UI automation
  path): enable the Rsync service, define a module named `storage` mapped to
  `/volume1/storage`, and add an auth user `jason` with `rw` access
  (`auth users = jason:rw`). The droplet now pushes the whole local backup directory in
  one additive (no `--delete`) transfer per night:
  ```
  rsync -a --mkpath --password-file=<file> <localdir>/ rsync://jason@nas:873/storage/backups/rustd-db/
  ```
  replacing the previous per-file `ssh ... < dumpfile` loop entirely. `rustd_backup_nas`
  shrank drastically as a result — it now only joins the tailnet and runs a root prune
  cron; the dedicated user, target-directory ownership, `getent` group lookup,
  `receive-dump.sh.j2` forced-command script, restricted `authorized_keys` entry, and
  the legacy-`rustd-backup`-user cleanup tasks were all removed, and
  `templates/receive-dump.sh.j2` was deleted from the repo. `rustd_xyz` lost its
  droplet-side ed25519 keypair generation entirely (no key exists in this design at
  all) and gained a single task writing the rsync daemon's password to a root-owned,
  mode-`0600`, `no_log`'d file instead.
  **Security note (flagged, not fixed):** the daemon's auth password for `jason` is
  `jason`'s actual nas login password, not a separate rsync-scoped secret — UGOS
  doesn't appear to offer distinct daemon-only credentials for the same auth-user name.
  This means a compromise of the rustd.xyz droplet leaks full access to `jason`'s nas
  account, not just write access to one backup directory — a real blast-radius
  regression versus the (unimplementable) ssh-jail design's intent. Recommended
  follow-up, not yet done: a dedicated non-admin UGOS user with its own password and
  rsync access scoped to a narrower module (ideally rooted at `backups/rustd-db`
  directly rather than all of `storage`), so a droplet compromise can't reach anything
  beyond the backup pipeline itself. Full rationale, including the field evidence for
  each blocker, in `ansible/roles/rustd_backup_nas/README.md` ("Field reality" and
  "Security note") and `ansible/roles/rustd_xyz/README.md` ("Nightly backup -> nas").
