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
- `/opt/rustd` and `/opt/rustd/backups` on the host (the backups directory is
  populated by the nightly pg_dump timer added in a later change).

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
docker exec -i rustd-db pg_restore -U rustd -d rustd --clean < dump.dump
```

## Secrets

All secrets (`rustd_xyz_ghcr_token`, `rustd_xyz_db_password`,
`rustd_xyz_smtp_username`, `rustd_xyz_smtp_password`) are 1Password lookups
set as `vars` in `projects.yml` — never hardcoded in `defaults/main.yml`.
The postgres password comes from the `rustd-db` item (Infrastructure vault),
created manually by the operator before the first deploy.

## Mailer TLS

`rustd_xyz_smtp_port` is `465` — Mailu's implicit-TLS submissions port. The
app container sets `QUARKUS_MAILER_TLS=true` (not `QUARKUS_MAILER_SSL`, the
deprecated alias, and not `QUARKUS_MAILER_START_TLS`, which is a different,
opt-in-STARTTLS-on-a-plaintext-connection knob). See `tasks/main.yml` for the
version-specific evidence.
