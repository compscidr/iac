# Orca auto-update on `.deb` hosts

2026-11-25. Short design: a small change to the `dev_gui` role.

## Why

Orca ships almost daily. On `.deb` installs the in-app updater downloads the
new package but, by upstream's choice (stablyai/orca#15744), will not install
it: it shows "Copy Install Command" and waits. Jason has to stop work, paste
the command and run it, most days. The headless server on ubuntu-beast is worse
off: it does not download updates at all (found on 1.4.261 with 1.4.274 out).

The upstream fix is a signed apt repo (stablyai/orca#18086, open, no progress
since 2026-09-03). This is a stopgap until that ships.

## Goals

- Desktop hosts: once Orca has downloaded an update and the Orca window is
  closed, the update installs with no prompt and nothing to paste.
- Serve hosts (`dev_gui_orca_serve: true`): once a night, fetch the newest
  release, stop `orca-serve`, install, start `orca-serve` again.
- Nothing is installed as root unless it matches the checksum upstream
  published for that version.

## Non-goals

- Relaunching the desktop app after an update.
- Stopping the desktop app's leftover background daemon (`daemon-entry.js`).
  It holds live terminals and only launching Orca brings it back.
- An apt repo of our own, or changes to the Renovate pin and the existing
  install task (they stay as bootstrap and catch-up).

## Anti-goals

- Installing while the Orca window is open. That can crash the running app
  (stablyai/orca#15176).
- Leaving `orca-serve` stopped after a failed update.
- Passwordless root for anything the user's session can steer. The job runs as
  root from a system timer and treats files under `$HOME` as untrusted.

## Approaches

1. **Root systemd timer and script, deployed by the role (chosen).** No
   password, works headless, and matches upstream's direction that something
   outside the app with root should own updates.
2. **Passwordless polkit/sudoers for the in-app updater.** Dead: since #15744
   Orca never calls `pkexec`/`sudo`, so there is nothing to authorise.
3. **User-level watcher plus a narrow sudoers rule.** Runs the same root
   script with more parts; the only gain is desktop notifications.

## Design

The role installs three root-owned files, gated by a new default
`dev_gui_orca_auto_update: true` and tagged `orca`:

- `/usr/local/sbin/orca-update`: the script, templated with the login user and
  the mode.
- `orca-update.service`: a root oneshot that runs the script.
- `orca-update.timer`: every minute on desktop hosts; daily at 04:00 with
  `Persistent=true` on serve hosts (new default
  `dev_gui_orca_auto_update_serve_time: "04:00"`).

The mode follows `dev_gui_orca_serve`: true means serve mode, otherwise desktop.

### Desktop mode

1. Read `~/.cache/orca-updater/pending/update-info.json` for the file name.
   Accept only `orca-ide_<version>_<arch>.deb` inside that directory. Nothing
   there: exit 0 quietly.
2. Exit 0 unless that version is newer than the installed `orca-ide`
   (`dpkg --compare-versions`). The pending file is left for Orca to clean up.
3. Exit 0 if the Orca app is running: any process whose executable is
   `/opt/Orca/orca-ide`, other than the background daemon
   (`daemon-entry.js`).
4. Copy the `.deb` to a root-only temp directory and check its sha512 against
   `latest-linux.yml` (`latest-linux-arm64.yml` on arm64) from that version's
   GitHub release. A mismatch fails the unit.
5. Check again that Orca is not running, then `apt-get install -y` the copy.

### Serve mode

1. Fetch `latest-linux.yml` from the latest GitHub release. Exit 0 unless its
   version is newer than the installed one.
2. Download the `.deb` to a root-only temp directory and verify its sha512.
3. If the desktop app (not the serve unit) is running, exit 0 and try again
   the next night.
4. Note whether the user's `orca-serve.service` is active, stop it, install,
   and start it again if it was active. The start runs even when the install
   fails.

Stopping `orca-serve` ends every agent terminal on that host. 04:00 was chosen
by Jason to keep that away from working hours.

### Other changes

- Fix the comment on the existing install task: Orca does not update itself on
  `.deb` installs.

## Left to the builder

- Exact process-matching and YAML parsing in the script (no new packages if
  avoidable).
- How root addresses the user's systemd manager (`systemctl --user -M user@`).
- Whether the timer can be enabled inside the molecule containers, or needs a
  guard there.
- A dry-run switch so the decision logic can be exercised without installing.

## Verification

- `shellcheck` and `ansible-lint` clean; molecule converges.
- ubuntu-work-laptop has a pending 1.4.274 over installed 1.4.272: after the
  playbook runs, closing Orca should leave 1.4.274 installed within about a
  minute, and the unit's journal should show a skip while Orca is open.
- ubuntu-beast: a dry run reports it would go from 1.4.261 to the latest; the
  real run is the 04:00 timer, or a manual start with Jason's go-ahead.

## Removal

When #18086 ships an apt repo: add the repo in the role, drop the script, the
units and the Renovate pin.
