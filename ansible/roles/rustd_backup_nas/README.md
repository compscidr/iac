# rustd_backup_nas Role

Receiving end of the rustd.xyz nightly `pg_dump` pipeline. Runs in `nas.yml`, against
`nas.local`. The pushing end is the `rustd_xyz` role (`projects.yml`) — see that role's
README for the "Nightly backup -> nas" section, which documents the same pipeline from
the other side.

## What it does

- Installs `rsync` (Debian/Ubuntu, via `apt`) — needed both for the transfer itself and
  because `rrsync` ships bundled inside the rsync package.
- Creates a dedicated system user, `rustd-backup` (a real `/bin/bash` shell, not
  `nologin` — see "Restricted key" below for why).
- Creates the backup target directory (`rustd_xyz_backup_nas_path`,
  `/volume1/storage/backups/rustd-db`), owned by `rustd-backup`, mode `0700`.
- Installs `rrsync` from the rsync package's bundled gzipped script
  (`/usr/share/doc/rsync/scripts/rrsync.gz` → `/usr/local/bin/rrsync`) if not already
  present.
- Slurps the backup public key live off the projects droplet (see "Key flow" below) and
  authorizes it in `rustd-backup`'s `authorized_keys`, restricted to a forced write-only
  `rrsync` command when available.
- Prunes backups older than `rustd_xyz_backup_nas_keep` (30 days) via a `cron` job — the
  nas is the **sole owner** of nas-side retention. The push script
  (`rustd-db-backup.sh.j2`, in `rustd_xyz`) never deletes anything remote; it only prunes
  its own local copy. There is exactly one place backups on the nas get deleted from.

## Key-flow rationale

The projects droplet generates its own ed25519 keypair the first time the `rustd_xyz`
role runs (`ssh-keygen ... creates=...` — `community.crypto` isn't in
`requirements.yml`, so this doesn't use `openssh_keypair`). **The private key is
generated on the droplet and never leaves it**: not copied to the ansible controller,
not put in 1Password, not templated anywhere.

This is the opposite of generating the keypair on the ansible controller and templating
the private half out to the droplet. Controller-side generation would leave private key
material sitting in a bare file on the operator's own machine with no place in this
repo's secret model to account for it — it isn't a 1Password item, and unlike every
other secret in this repo it would exist only as a controller-local artifact, with no
rotation story and a real risk of an accidental `git add -A`. Droplet-side generation
means the only copy of the private key lives on the one machine that actually uses it,
and is never transmitted anywhere — not even over the ansible control channel.

Only the **public** key is ever read off the droplet, and only by this role: the task
`Read the rustd.xyz backup public key from the projects droplet`
(`tasks/main.yml`) delegates a live `ansible.builtin.slurp` back to the projects host
(`rustd_backup_nas_projects_host`, must match the `projects` inventory host) from within
this (`nas.yml`) play. No cross-playbook fact sharing or combined-invocation requirement
— `projects.yml` and `nas.yml` stay independently runnable plays; this one just needs the
key to already exist on disk over on the projects host.

## First-run ordering

**`nas.yml` (this role) must run *after* `projects.yml` has run at least once on the
projects host.** The slurp task above reads
`rustd_backup_nas_pubkey_path` (`/root/.ssh/rustd-backup_ed25519.pub`) off the projects
droplet; that file doesn't exist until the `rustd_xyz` role's key-generation task has run
there. If `nas.yml` is run first (or against a projects host that has never run
`rustd_xyz`), the slurp task fails with a missing-file error.

This is not enforced by any `ansible-playbook` ordering or pre-flight check — it's a
one-time bootstrap dependency between two otherwise-independent playbooks. See the
deploy runbook in
`docs/superpowers/specs/2026-08-11-rustd-xyz-prod-deploy-design.md`, which sequences
`projects.yml` before the `nas.yml` run that authorizes the backup key. After the first
successful run on both sides, re-running either playbook is idempotent and the ordering
no longer matters (the key already exists on the droplet and is already authorized on
the nas).

## Restricted key

The authorized key is restricted with `command="rrsync -wo <path>",restrict` when
`rrsync` is available (it is, on Debian/Ubuntu). This confines the key to write-only
rsync into the one backups directory — no shell, no read-back, no port/agent/X11
forwarding. If `rrsync` were ever unavailable, the role falls back to a plain
(unrestricted) key on the same dedicated, single-purpose system user — weaker, but still
scoped to a user with no other role on the box.

`rustd-backup` gets a real shell (`/bin/bash`), not `nologin`: `sshd` runs the
`authorized_keys` forced `command=` regardless of login shell, but some PAM
configurations (`pam_shells`) reject the session at the account phase before that if the
shell isn't listed in `/etc/shells` — which would break the restricted key too, not just
interactive login.

## Prune ownership

Nas-side retention (`rustd_xyz_backup_nas_keep`, 30 days) is owned entirely by this
role's `cron` job:

```
find {{ rustd_xyz_backup_nas_path }} -maxdepth 1 -name 'rustd-*.dump' -mtime +{{ rustd_xyz_backup_nas_keep }} -delete
```

The push script never deletes anything on the nas — only its own local copy, kept to
`rustd_xyz_backup_local_keep` (7 days). This keeps exactly one owner per retention
window: local pruning is the droplet's job, nas pruning is this role's job.

## Shared coordinates

`rustd_xyz_backup_nas_host`/`_user`/`_path`/`_keep` are shared between this role and
`rustd_xyz` (they describe the same pipeline from both ends) and live in
`ansible/group_vars/all.yml`, not in either role's `defaults/main.yml` — `projects.yml`
and `nas.yml` are separate playbook runs with no common `vars_files`, so neither role's
own defaults are visible to the other. See the comment in `group_vars/all.yml` for why.
