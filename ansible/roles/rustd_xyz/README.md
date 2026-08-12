# rustd_xyz Role

Deploys the rustd.xyz panel (Quarkus app, GHCR image) and its postgres database
on the projects droplet, behind `nginx-proxy`. Mirrors `sair_portal`'s
GHCR-login / container-deploy shape.

## What it deploys

- `rustd-db` — `postgres:17`, on a private `rustd-db` docker network, data on
  the named volume `rustd-db-data`. Not reachable from `nginx-proxy`.
- `rustd-xyz` — the panel container, on both `nginx-proxy` (for TLS routing)
  and `rustd-db` (to reach postgres). `VIRTUAL_HOST`/`LETSENCRYPT_HOST` are the
  **apex domain only** (`rustd.xyz`) — never add `www`, it breaks the
  `__Host-` prefixed auth cookie.
- `/opt/rustd` (`0755`) and `/opt/rustd/backups` (`0700` — dumps hold RCON
  credentials, so the directory isn't world-readable) on the host, plus a
  `rustd-db-backup.timer` (04:30 daily, 15m random delay) that runs
  `rustd-db-backup.sh`: `pg_dump`s `rustd-db`, keeps the newest
  `rustd_xyz_backup_local_keep` dumps locally, and pushes the whole local
  backup directory to the nas' built-in rsync daemon (port 873 — not ssh).

## Rollback

Pin `rustd_xyz_image` to a specific tag, e.g. `ghcr.io/compscidr/rustd.xyz:sha-<sha>`,
and re-run the play. `recreate: true` on the container task means the next run
picks up the pin immediately.

## First deploy / claim flow

rustd.xyz's first-boot flow issues a one-time claim token instead of a seeded
admin password. After the first deploy, check the container logs for it:

```bash
docker logs rustd-xyz
```

## Restore drill

Given a `pg_dump -Fc` dump (see the backup script), restore into a running
`rustd-db` container with:

```bash
docker exec -i rustd-db pg_restore -U rustd -d rustd --clean --if-exists < dump.dump
```

`--if-exists` (paired with `--clean`) suppresses the "does not exist" errors
`pg_restore` would otherwise print for every object it tries to drop before
recreating on a database that doesn't already have them — expected when
restoring into a fresh/empty `rustd-db`, not a sign the restore failed.

## Secrets

All secrets (`rustd_xyz_ghcr_token`, `rustd_xyz_db_password`,
`rustd_xyz_smtp_username`, `rustd_xyz_smtp_password`,
`rustd_xyz_backup_nas_rsync_password`) are 1Password lookups set as `vars` in
`projects.yml` — never hardcoded in `defaults/main.yml`. The postgres password
comes from the `rustd-db` item (Infrastructure vault), created manually by the
operator before the first deploy. The rsync-daemon backup password comes from
the `ugnas` item (Infrastructure vault) — see "Nightly backup -> nas" below for
why that's jason's actual nas login password, not a dedicated secret.

## Nightly backup -> nas

`rustd-db-backup.sh` (templated to `/opt/rustd/rustd-db-backup.sh`) pg_dumps
`rustd-db` in custom (`-Fc`) format, prunes local dumps beyond
`rustd_xyz_backup_local_keep` (7), then pushes the whole local backup
directory to the nas in **one rsync-daemon transfer**:

```
rsync -a --mkpath --password-file={{ rustd_xyz_backup_rsync_password_file }} \
  {{ rustd_xyz_backup_local_dir }}/ \
  rsync://{{ rustd_xyz_backup_nas_rsync_user }}@{{ rustd_xyz_backup_nas_host }}:{{ rustd_xyz_backup_nas_rsync_port }}/{{ rustd_xyz_backup_nas_rsync_module }}/{{ rustd_xyz_backup_nas_rsync_subpath }}/
```

No `--delete`: the nas keeps a longer retention window (`rustd_xyz_backup_nas_keep`,
30 days) than this local directory does (7), so a mirroring sync would prune the nas
copy down to whatever's still local. The nas owns pruning its own copy (a root cron in
the `rustd_backup_nas` role, run by `nas.yml`) — the push script never deletes anything
remote, so there is exactly one owner of nas-side retention.

**Transport is the nas' built-in rsync daemon (port 873), not ssh — see
`rustd_backup_nas`'s README ("Field reality") for the full field story.** In short: the
original design was an ssh-forced-command jail (dedicated key, restricted
`authorized_keys` entry, `rrsync` or a hand-rolled receive script). Deploy testing found
it was unimplementable on this hardware for three independent reasons — the nas'
vendor-patched `rsync` rejects every server-side receive, `sshd` on the appliance has a
**global** `ForceCommand` that overrides any per-key `command=` (no ssh-jail is possible
at all), and admin accounts get full passthrough through that global command anyway.
None of that applies to the vendor's own rsync daemon, which sits entirely outside sshd
and turned out to be the actual supported receive path — proven end-to-end, a real dump
landed on the nas' 91TB bcache array over the tailnet.

**Auth is a daemon username/password, not a key**, written to
`rustd_xyz_backup_rsync_password_file` (root-owned, mode `0600`, `no_log`'d) by this
role's "Write the nas rsync-daemon password file" task. The password is jason's actual
nas login password (1Password `ugnas` item) — see `rustd_backup_nas`'s README
("Security note") for the shared-credential blast-radius this creates and the scoped-
account follow-up it recommends.

**Manual prerequisite:** the nas' rsync daemon has to be enabled once via the UGOS UI —
module `storage` -> `/volume1/storage`, `auth users = jason:rw`. Ansible does not and
cannot configure it (closed vendor appliance, no UGOS-UI ansible module). See
`rustd_backup_nas`'s README for the exact steps.

## Mailer TLS

`rustd_xyz_smtp_port` is `465` — Mailu's implicit-TLS submissions port. The
app container sets `QUARKUS_MAILER_TLS=true` (not `QUARKUS_MAILER_SSL`, the
deprecated alias, and not `QUARKUS_MAILER_START_TLS`, which is a different,
opt-in-STARTTLS-on-a-plaintext-connection knob). See `tasks/main.yml` for the
version-specific evidence.
