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
  `rustd_xyz_backup_local_keep` dumps locally, and `rsync`s the whole
  backups directory to the nas over a dedicated ed25519 key.

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
`rustd_xyz_smtp_username`, `rustd_xyz_smtp_password`) are 1Password lookups
set as `vars` in `projects.yml` — never hardcoded in `defaults/main.yml`.
The postgres password comes from the `rustd-db` item (Infrastructure vault),
created manually by the operator before the first deploy.

## Nightly backup -> nas

`rustd-db-backup.sh` (templated to `/opt/rustd/rustd-db-backup.sh`) pg_dumps
`rustd-db` in custom (`-Fc`) format, prunes local dumps beyond
`rustd_xyz_backup_local_keep` (7), then `rsync`s the backups directory to
`rustd_xyz_backup_nas_user@rustd_xyz_backup_nas_host:/` — the bare root, not
`rustd_xyz_backup_nas_path`; see "Push destination is `:/`" below for why.
The nas keeps `rustd_xyz_backup_nas_keep` (30) and owns pruning its own copy
(cron, in the `rustd_backup_nas` role run by `nas.yml`) — the push script
never deletes anything remote, so there is exactly one owner of nas-side
retention.

**Key flow.** The role generates a dedicated ed25519 keypair on this droplet
the first time it runs (`ssh-keygen ... creates=...` — `community.crypto`
isn't in `requirements.yml`, so this doesn't use `openssh_keypair`). The
private key is created here and never leaves this host: not copied to the
ansible controller, not put in 1Password, not templated anywhere. Only the
*public* key is ever read off the box — the `rustd_backup_nas` role, running
`nas.yml` against the nas, delegates a `slurp` task back to this host to
fetch it live and authorize it in `rustd-backup`'s `authorized_keys`.

This is the opposite of the design doc's stated default (generate the
keypair on the ansible controller and template private key -> droplet,
public key -> nas). That version would leave private key material sitting
in a file on the operator's own machine with no 1Password entry and no
place in this repo's secret model to account for it — exactly the kind of
controller-local artifact this repo otherwise avoids. Generating on the
droplet means the only copy of the private key lives on the one machine
that uses it, is never transmitted over the control channel at all, and
needs no 1Password item.

The authorized key is restricted with `command="<rrsync> -wo <rustd_xyz_backup_nas_path>",restrict`
(`rustd_backup_nas` role — `rrsync` is a *required* dependency there: the role
fails its play if it can't find it, rather than falling back to a plain key).
This confines the key to write-only rsync into the one backups directory —
no shell, no read-back, no port/agent/X11 forwarding.

**Push destination is `:/`, not the nas-side path.** rrsync re-roots an
absolute destination path under its own restricted directory instead of
treating it as a literal filesystem path, so rsyncing to
`rustd_xyz_backup_nas_path` on the wire would land at `DIR` + `DIR`, not
`DIR`. `rustd-db-backup.sh.j2` therefore hardcodes its destination as the
bare root (`:/`), which rrsync resolves as "the restricted directory
itself". That hardcoding relies on the key always being rrsync-restricted —
see `rustd_backup_nas`'s README ("Restricted key") for why that's now
guaranteed rather than best-effort.

## Mailer TLS

`rustd_xyz_smtp_port` is `465` — Mailu's implicit-TLS submissions port. The
app container sets `QUARKUS_MAILER_TLS=true` (not `QUARKUS_MAILER_SSL`, the
deprecated alias, and not `QUARKUS_MAILER_START_TLS`, which is a different,
opt-in-STARTTLS-on-a-plaintext-connection knob). See `tasks/main.yml` for the
version-specific evidence.
