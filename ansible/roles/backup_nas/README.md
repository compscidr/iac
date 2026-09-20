# backup_nas Role

Receiving end of the nightly backup pipelines (rustd.xyz `pg_dump`, jasonernst.com
goblog, mailu). Runs in `nas.yml`, against `nas.local`. The pushing ends are the
`rustd_xyz` (`projects.yml`), `jasonernst_com` and `mailu` (`jasonernst_com.yml`) roles —
see each role's README / task comments for the same pipeline from the other side, and
"Restoring" below for how to put any of it back.

## What it does

This role is deliberately small: **join the nas to the tailnet, and prune old dumps.**
That's it.

- Joins the nas to the tailnet (see "Tailnet membership" below).
- Prunes backups older than `rustd_xyz_backup_nas_keep` (30 days) via a **root** `cron`
  job — the nas is the **sole owner** of nas-side retention. The push script
  (`rustd-db-backup.sh.j2`, in `rustd_xyz`) never deletes anything remote; it only prunes
  its own local copy. There is exactly one place backups on the nas get deleted from.
- Same-shaped prunes for the jasonernst.com goblog and mailu pipelines (push sides:
  `jasonernst_com` and `mailu` roles, both in `jasonernst_com.yml`): db snapshots older
  than `jasonernst_com_backup_nas_keep` / `mailu_backup_nas_keep` under each pipeline's
  `db/` directory. The sibling mirrors (goblog `uploads/`; mailu `dkim/`, `data/`,
  `mail/`, `mailu.env`) are never pruned.

- Daily backup freshness check (08:00 cron) — a dead-man's switch for **all three**
  pipelines: if a pipeline's newest db snapshot on the nas is older than
  `backup_nas_freshness_max_age_hours` (26h — catches a single missed night on the
  first morning), it posts to discord #dev-alerts via a channel webhook (1Password item
  `discord-dev-alerts`, no bot). Checking arrival here rather than hooking run failures
  on the droplets covers every silent-stop mode with one mechanism — failed run, dead
  timer, dead droplet, broken tailnet, broken rsync auth. The push scripts send their db
  snapshot **last**, so a fresh marker means that night's whole run (mirrors included)
  succeeded. Silent when everything is fresh.

That's the whole role. It does **not** create a receiver user, a target directory, an
SSH key, or any receive-side script — see "Field reality" below for why: the actual
receive path is the nas' own rsync daemon, which owns all of that itself.

## Manual prerequisite: enable the nas' rsync daemon (UGOS UI)

**Ansible does not and cannot configure this.** The nas is a closed UGREEN vendor
appliance (UGOS) — there is no ansible module for its web UI, and there is no config
file on disk this role is allowed to template its way around. Before the backup
pipeline can receive anything, an operator has to, once, in the UGOS UI:

1. Enable the **Rsync** service (Control Panel → Services, or equivalent — UGOS's own
   term for it).
2. Configure a module named `storage` mapped to `/volume1/storage`.
3. Create a dedicated **non-admin** user `backup` (Control Panel → Users; its own
   generated password, **not** in the admin group), give it **read/write** on the
   `storage` share only, and allow it to use rsync. In rsyncd.conf terms that yields
   `auth users = backup:rw` on the `storage` module and nothing on `docker`/`home`/
   `homes`. Save the password as the 1Password item `nas-rsync` (Infrastructure vault,
   `password` field) — every push side looks it up from there.

Confirmed working config, field-verified: module `storage` → `path = /volume1/storage`,
`auth users = <user>:rw`. The daemon listens on port 873. Auth password is the UGOS
account's actual login password (UGOS has no separate rsync-only secret) — which is
exactly why it must be a dedicated account, see "Security note" below.

## Field reality: why this role used to be much bigger

This role originally implemented an ssh-forced-command receiver: a dedicated user, a
target directory, `rrsync`, and later a hand-rolled receive script authorized via a
restricted SSH key. **All of that is dead.** Deploy testing found three independent,
compounding reasons the ssh-jail design could never have worked on this hardware:

1. **The nas' vendor-patched `rsync` (UGREEN's own 3.4.1 build) rejects every
   server-side receive**, with a custom `not support path` error regardless of the
   destination path given. `rrsync` just shells out to that same broken binary, so no
   packaging of `rrsync` could have worked around it — and there's no stock rsync to
   fall back to, since installing packages on this vendor appliance is forbidden.
2. **sshd on the appliance has a GLOBAL `ForceCommand`** that overrides any per-key
   `command=` in `authorized_keys`. The entire ssh-jail model — "this key can only run
   this one forced command" — assumes per-key `command=` wins; on this box it doesn't.
   There is no way to build an ssh-forced-command jail here at all, for any key.
3. **Admin users get full passthrough** through that global `ForceCommand` anyway, so
   even accepting (1) and (2), routing through an admin-adjacent account wouldn't have
   been meaningfully restricted.

None of this was fixable by trying harder at the ssh layer — every layer of the intended
jail (rsync protocol, forced command, restricted key) was closed off by the vendor
firmware independently of the others.

**The working path, proven end-to-end** (a real dump landed on the nas' 91TB bcache
array, over the tailnet, verified on disk): UGOS's own **rsync daemon**, port 873,
enabled via the UGOS UI as described above. The daemon sits entirely outside sshd —
none of the three blockers above apply to it, because it was never going through sshd in
the first place. The droplet pushes with:

```
rsync -a --mkpath --password-file=<file> <localdir>/ rsync://backup@nas:873/storage/backups/rustd-db/
```

See `rustd_xyz`'s `templates/rustd-db-backup.sh.j2` for the real templated command.

## Security note: why a dedicated account

The daemon's "auth users" password for a user **is that user's actual nas login
password** — UGOS offers no separate rsync-only secret. The pipelines originally shipped
authenticating as `jason` (the first thing that worked, see above), which meant the
`.rsync-nas-pass` file on each droplet **was** jason's full nas login, with rw on every
module the daemon exports (`docker`, `home`, `homes`, `storage`). A compromised droplet
leaked the whole nas, not one backup directory.

Fixed in #502: all three push sides authenticate as `backup`, a dedicated non-admin UGOS
user whose only share is `storage` (1Password `nas-rsync` item). A compromised droplet now
gets write into `/volume1/storage` and nothing else. The `*_backup_nas_rsync_user`
defaults in `rustd_xyz`, `jasonernst_com` and `mailu` name that account; if it's ever
renamed in the UGOS UI, change all three.

Ceiling, deliberately not chased: the daemon runs as `uid = jason` (UGOS's own
`rsyncd.conf`), so files still land owned by jason, and `storage` is wider than the
`backups/` subtree — a module rooted at `/volume1/storage/backups` would be tighter still
if UGOS ever lets a share be created there.

## Restoring

Everything lands under `/volume1/storage/backups/<pipeline>/` on the nas. The droplet
side pulls it back through the same rsync daemon it pushes to — reverse the source and
destination of the push script's command, using the password file the role already
wrote (`/opt/goblog/.rsync-nas-pass`, `/opt/mailu/.rsync-nas-pass`). On a fresh droplet,
run the normal play first so the directories, containers and password files exist, then
restore over the top, then run the play once more.

Dry-run any pull with `-n` first: `--delete` is never used here, so a pull only ever
adds or overwrites — but it is still root writing into a live service's directory.

### rustd.xyz

See `roles/rustd_xyz/README.md` "Restore drill" (`pg_restore --clean --if-exists` into
`rustd-db` from a `rustd-*.dump`).

### jasonernst.com (goblog)

`backups/goblog/db/goblog-<date>.db` (sqlite snapshots, 30 days) and
`backups/goblog/uploads/` (additive mirror of `/opt/goblog/prod/uploads`).

```bash
cd /opt/goblog
R="rsync -a --password-file=/opt/goblog/.rsync-nas-pass rsync://backup@nas:873/storage/backups/goblog"
$R/db/goblog-YYYY-MM-DD.db prod/restore.db
docker stop www.jasonernst.com
cp prod/restore.db prod/database.db          # bind-mounted into the container as-is
$R/uploads/ prod/uploads/
docker start www.jasonernst.com
```

The db is a plain bind mount, so a file swap while the container is stopped is the
whole restore. Verify: the site renders the posts, and an image from `uploads/` loads.

### mailu

`backups/mailu/db/mailu-<date>.db` (admin sqlite snapshots, 30 days) plus additive
mirrors of `dkim/`, `data/` (minus the live db), `mail/` and `mailu.env`.

**`dkim/` first, before the admin container has ever started on the new host.** Mailu
generates fresh signing keys on first start if none exist; the April wipe restored
everything except these, DNS kept the old public keys, and outbound mail failed
DKIM/DMARC for three months (#478). If the play has already been run and keys were
regenerated, the pull below overwrites them — just make sure to restart the stack
afterwards so rspamd picks the restored keys up.

```bash
cd /opt/mailu
R="rsync -a --password-file=/opt/mailu/.rsync-nas-pass rsync://backup@nas:873/storage/backups/mailu"
docker compose down
$R/dkim/ dkim/
$R/data/ data/                                # instance keys etc; live db excluded on push
$R/db/mailu-YYYY-MM-DD.db data/main.db        # accounts, domains, aliases
rm -f data/main.db-wal data/main.db-shm       # journals belong to the old db, not this one
$R/mail/ mail/                                # maildirs; dovecot rebuilds its indexes
docker compose up -d
```

`mailu.env` is on the nas too but is templated by the role, so only pull it if the
controller is what you lost. Then re-run `jasonernst_com.yml`: the role's "Display DKIM
key for DNS" task prints the public key derived from the restored `dkim/` — it must
match the `dkim._domainkey` TXT records in `terraform/mail*.tf`. If it doesn't, the
restore didn't take and outbound mail is about to fail signature checks again.

Verify: log into webmail as an existing user, and send one outbound message to a Gmail
address and check "show original" reports `dkim=pass`.

## Tailnet membership

The backup pipeline design assumed the nas was already a tailnet member; deploy discovery
found it wasn't — the `tailscale` package was present but `tailscaled` had never been
enabled and `tailscale up` had never been run. This role owns the join, and it stays even
though the ssh-based receive design that originally motivated it is gone: the rsync
daemon is still reached over the tailnet, not the public internet.

**Why this role, not `common_cli`:** `common_cli` is how every workstation and server in
this repo joins the tailnet, but it's paired with a general CLI/dotfiles/user-account setup
that assumes a machine this repo fully owns. The nas is a vendor-managed UGREEN appliance
(Debian-based, hostname `DXP8800PLUS-3F06`) — package/config changes on it are deliberately
kept to the minimum this pipeline needs, so it never runs `common_cli`. `backup_nas`
adds the smallest tailnet-join footprint instead: install (idempotent no-op here, since the
package already exists), enable the daemon, and `up`.

**Hostname contract:** `tailscale up` is given `--hostname={{ backup_nas_tailnet_hostname }}`
(default `nas`) rather than letting the appliance's own hostname become its tailnet name.
This value **must match `rustd_xyz_backup_nas_host`** in `group_vars/all.yml` — that's the
name the droplet-side backup script dials to reach the nas over the tailnet. See the sync
contract comments on both variables.

**Flag rationale:**

- `--accept-dns=false` — MagicDNS must not rewrite a vendor appliance's `resolv.conf`; DNS
  resolution on the box stays whatever the vendor OS configures.
- No `--ssh` — the vendor `sshd` stays authoritative for admin login. Backups no longer
  go over sshd at all (see "Field reality" above); Tailscale SSH was never part of this
  pipeline either way.

**Idempotency:** unlike `common_cli`, which re-runs `tailscale up` on every play
(`failed_when: false` tolerates the no-op), this role checks `tailscale status --self`
first and only runs `up` when the nas isn't already logged in (`rc != 0` or a `NeedsLogin`
status) — preferring not to re-invoke `up` on every run against a vendor appliance.

## Prune ownership

Nas-side retention (`rustd_xyz_backup_nas_keep`, 30 days) is owned entirely by this
role's root `cron` job:

```
find {{ rustd_xyz_backup_nas_path }} -maxdepth 1 -name 'rustd-*.dump' -mtime +{{ rustd_xyz_backup_nas_keep }} -delete
```

It's a **root** cron, not a per-user one: the rsync daemon writes as whatever Linux user
the daemon process itself runs as (vendor-configured, opaque to this role), not
necessarily as `jason` — there's no single non-root account this role can reliably own a
crontab for, and root can always read/delete regardless of which user owns the dumped
files.

The push script never deletes anything on the nas — only its own local copy, kept to
`rustd_xyz_backup_local_keep` (7 days). This keeps exactly one owner per retention
window: local pruning is the droplet's job, nas pruning is this role's job.

## Shared coordinates

`rustd_xyz_backup_nas_host`/`_path`/`_keep` are shared between this role and `rustd_xyz`
(they describe the same pipeline from both ends) and live in `ansible/group_vars/all.yml`,
not in either role's `defaults/main.yml` — `projects.yml` and `nas.yml` are separate
playbook runs with no common `vars_files`, so neither role's own defaults are visible to
the other. See the comment in `group_vars/all.yml` for why.

`backup_nas_tailnet_hostname` (this role's own `defaults/main.yml`) is a related but
separately-enforced sync contract: it must match `rustd_xyz_backup_nas_host` above, but
lives here rather than in `group_vars/all.yml` since only this role ever sets it — see the
comment on the variable itself.
