# listmonk Role

The 2dogs1bun.io waitlist: [listmonk](https://listmonk.app) and postgres on the projects
droplet, sending through Mailu as `noreply@2dogs1bun.io`.

- **Public:** `https://lists.2dogs1bun.io` serves only the signup, confirm and unsubscribe
  pages. `files/nginx-vhost.conf` returns 404 for `/admin` and the private `/api`.
- **Admin:** `https://projects.<tailnet>.ts.net:9444/admin`, tailnet only. Log in as `admin`
  with the `listmonk-admin` 1Password item.
- **Signups:** the form in the 2dogs1bun.io page posts to `/subscription/form` with
  `listmonk_waitlist_uuid`. The list is double opt-in. The empty `nonce` field is listmonk's
  honeypot.
- **Settings:** `listmonk_settings` is written to the settings table on every deploy, and
  listmonk restarts if anything changed. Other settings belong to the admin UI.
- **Backups:** nightly `pg_dump` to the nas (`/volume1/storage/backups/listmonk-db`), covered
  by `backup_nas`'s prune and freshness check.

## Limits

Mailu caps each sender at `mailu_message_ratelimit` (200/day). Campaigns are held to 150/day
so confirmations still get through. A signup while Mailu is unreachable or over the limit
shows the visitor an error page, though their address is saved as unconfirmed.

## Restore

```bash
docker exec -i listmonk-db pg_restore --clean --if-exists -U listmonk -d listmonk < listmonk-YYYY-MM-DD.dump
docker restart listmonk
```
