# Orca Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install Orca `.deb` updates automatically: on desktops when a downloaded update is pending and the app is closed, on serve hosts nightly with a stop/install/start of `orca-serve`.

**Architecture:** One root-owned bash script, `orca-update <desktop|serve> <user> [--dry-run]`, run by a root systemd oneshot on a timer. The `dev_gui` role installs the script and units and picks the mode from `dev_gui_orca_serve`. The script is a static file with a few environment seams so a plain bash test script can drive it with stubbed commands.

**Tech Stack:** bash, systemd, Ansible (`dev_gui` role), shellcheck, ansible-lint, molecule (CI).

**Spec:** `docs/superpowers/specs/2026-11-25-orca-auto-update-design.md`

## Global Constraints

- Nothing is installed unless its sha512 matches `latest-linux.yml` (`latest-linux-arm64.yml` on arm64) from the GitHub release of that version.
- Never install while the Orca app is running; never leave `orca-serve` stopped after a failed update.
- Files under the user's home are untrusted: copy to a root-only temp dir (`mktemp -d`, removed on exit) before verifying and installing.
- No new packages on hosts. Use `curl`, `openssl`, `awk`, `sed`, `dpkg`, `apt-get`, `pgrep`, `runuser`.
- The background daemon (`daemon-entry.js`) is never stopped on desktops.
- New defaults: `dev_gui_orca_auto_update: true`, `dev_gui_orca_auto_update_serve_time: "04:00"`. Ansible tasks are tagged `orca`.
- Git: work on branch `compscidr/orca-auto-update`; run `git branch --show-current` before each commit; never push to main.

## Decisions the spec left open

- **App-running test:** `pgrep -f '^/opt/Orca/orca-ide .*--type='` succeeds. Chromium child processes exist only while an Electron app (window or serve) is up; the daemon and other node helpers have none.
- **Serve mode ordering:** check `orca-serve` first. If it is active, skip the app-running test (its own processes would match). If it is inactive and the app is running, skip the update.
- **User systemd from root:** `runuser -u <user> -- env XDG_RUNTIME_DIR=/run/user/<uid> systemctl --user <verb> orca-serve.service`.
- **sha512 format:** upstream publishes base64 of the binary digest: `openssl dgst -sha512 -binary <file> | base64 -w0`.
- **Journal noise:** the desktop timer fires every minute, so its service sets `LogLevelMax=notice`. The script prefixes lines with sd-daemon levels: `<5>` for installs, `<4>` for warnings, `<3>` for errors, `<7>` for skips and "up to date". Routine skips therefore stay out of the journal; use `--dry-run` to see them. This replaces the spec's "journal shows a skip" check.
- **Network failure** (cannot fetch the yml or the `.deb`): warning, exit 0, nothing installed. A checksum mismatch or failed install exits 1.
- **`orca-ide` not installed:** exit 0; the role's install task bootstraps.

## Review Focus

1. Pending `.deb` whose content differs from upstream (tampered or truncated download): nothing installed, exit 1.
2. `update-info.json` naming a file outside the pending dir or with an unexpected name (`../../tmp/x.deb`): rejected, exit 1, nothing read outside the dir.
3. GitHub unreachable: exit 0 with a warning, nothing installed, `orca-serve` untouched.
4. Install fails in serve mode: `orca-serve` is started again, exit 1.
5. Orca launched between the first check and the install on a desktop: the second check catches it, nothing installed.

Each has a test case in Task 1 or 2.

---

### Task 1: `orca-update` script, desktop mode

**Files:**
- Create: `ansible/roles/dev_gui/files/orca-update`
- Create: `ansible/roles/dev_gui/tests/orca-update-test.sh`

**Interfaces:**
- Produces: `orca-update <desktop|serve> <user> [--dry-run]`. Exit 0 for installed, skipped or nothing to do; exit 1 for bad arguments, rejected file name, checksum mismatch or failed install.
- Environment seams (defaults in brackets), used by tests only:
  - `ORCA_UPDATE_PENDING_DIR` [`<home of user>/.cache/orca-updater/pending`]
  - `ORCA_UPDATE_RELEASES_URL` [`https://github.com/stablyai/orca/releases`]
- URLs: `$BASE/download/v<ver>/<yml>`, `$BASE/download/v<ver>/<deb>`, `$BASE/latest/download/<yml>`.
- Stable output lines (after the level prefix), all starting `orca-update: `:
  - `installed orca-ide <new> (was <old>)`
  - `would install orca-ide <new> (installed <old>)` (dry run)
  - `up to date (<installed>)`
  - `skip: Orca is running`
  - `skip: no pending update`
  - `checksum mismatch for <file name>`
  - `rejected pending file name: <name>`
  - `cannot fetch <url>`
  - `install failed`

- [ ] **Step 1: Write the test harness and the failing desktop tests**

`orca-update-test.sh` is plain bash (`set -u`), runs as a normal user, and exits non-zero if any case fails. Per case it builds a temp dir with:

- `bin/` first on `PATH`, holding stubs:
  - `dpkg-query`: prints `$STUB_INSTALLED`; exits 1 when it is empty.
  - `apt-get`: appends its arguments to `$STUB_LOG`; exits `$STUB_APT_RC` (default 0).
  - `pgrep`: reads return codes from `$STUB_PGREP_RCS` (space-separated, one consumed per call, last one repeats; default `1`).
  - `runuser`: appends its arguments to `$STUB_LOG`; when they contain `is-active` exits `$STUB_SERVE_ACTIVE_RC` (default 3), otherwise 0.
- `pending/` with a fake `.deb` (any bytes) named `orca-ide_<ver>_<arch>.deb` and `update-info.json` in upstream's shape: `{"fileName":"<name>","sha512":"<b64>","isAdminRightsRequired":false}`.
- `releases/download/v<ver>/` and `releases/latest/download/` with a `latest-linux.yml` in upstream's shape (see the spec's source: a `version:` line, then `files:` entries of `- url:` followed by `sha512:`), served through `ORCA_UPDATE_RELEASES_URL=file://...`.
- `<arch>` is `$(dpkg --print-architecture)`; on arm64 the yml is `latest-linux-arm64.yml`.

Desktop cases (installed `1.4.272` unless stated):

| Case | Setup | Expect |
|---|---|---|
| installs pending | pending `1.4.274`, matching yml | exit 0; log has `apt-get install -y` with a path outside `pending/`; output has `installed orca-ide 1.4.274 (was 1.4.272)` |
| nothing pending | empty `pending/` | exit 0; no `apt-get` |
| pending not newer | pending `1.4.272` | exit 0; no `apt-get`; `up to date (1.4.272)` |
| app running | `STUB_PGREP_RCS=0` | exit 0; no `apt-get`; `skip: Orca is running` |
| app starts mid-run | `STUB_PGREP_RCS="1 0"` | exit 0; no `apt-get` |
| tampered deb | append a byte to the `.deb` after writing the yml | exit 1; no `apt-get`; `checksum mismatch for` |
| bad file name | `fileName` is `../../tmp/x.deb` | exit 1; no `apt-get`; `rejected pending file name` |
| offline | `ORCA_UPDATE_RELEASES_URL=file:///nonexistent` | exit 0; no `apt-get`; `cannot fetch` |
| apt fails | `STUB_APT_RC=100` | exit 1; `install failed` |
| not installed | `STUB_INSTALLED=` | exit 0; no `apt-get` |
| dry run | `--dry-run`, pending `1.4.274` | exit 0; no `apt-get`; `would install orca-ide 1.4.274 (installed 1.4.272)` |
| bad arguments | mode `bogus`, or no user | exit 1 |

- [ ] **Step 2: Run the tests and see them fail**

Run: `bash ansible/roles/dev_gui/tests/orca-update-test.sh`
Expected: every case fails because the script does not exist.

- [ ] **Step 3: Implement desktop mode in `ansible/roles/dev_gui/files/orca-update`**

`#!/usr/bin/env bash`, `set -euo pipefail`. Follow the spec's desktop steps 1 to 5 and the decisions above. Accept only names matching `^orca-ide_[0-9]+(\.[0-9]+)*_(amd64|arm64)\.deb$` whose arch equals `dpkg --print-architecture`. Take the version from the file name. Install with `DEBIAN_FRONTEND=noninteractive apt-get install -y <temp copy>`. Leave the pending files in place. Structure it as functions (`log`, `installed_version`, `app_running`, `fetch`, `expected_sha512`, `actual_sha512`, `install_deb`, `run_desktop`) so Task 2 adds `run_serve` beside them.

- [ ] **Step 4: Run the tests and shellcheck**

Run: `bash ansible/roles/dev_gui/tests/orca-update-test.sh && shellcheck ansible/roles/dev_gui/files/orca-update ansible/roles/dev_gui/tests/orca-update-test.sh`
Expected: all desktop cases pass; shellcheck prints nothing.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/dev_gui/files/orca-update ansible/roles/dev_gui/tests/orca-update-test.sh
git commit -m "feat(dev_gui): add orca-update script, desktop mode"
```

### Task 2: Serve mode

**Files:**
- Modify: `ansible/roles/dev_gui/files/orca-update`
- Modify: `ansible/roles/dev_gui/tests/orca-update-test.sh`

**Interfaces:**
- Consumes: the functions and stubs from Task 1.
- Produces: `orca-update serve <user> [--dry-run]` with the same exit codes, plus output lines `stopping orca-serve` and `starting orca-serve`.

- [ ] **Step 1: Add the failing serve tests**

Installed `1.4.261`, latest yml `1.4.274` with a matching `.deb` in `releases/download/v1.4.274/`:

| Case | Setup | Expect |
|---|---|---|
| updates and restarts | `STUB_SERVE_ACTIVE_RC=0` | exit 0; log order is `stop orca-serve.service`, `apt-get install -y`, `start orca-serve.service`; `installed orca-ide 1.4.274 (was 1.4.261)` |
| already current | installed `1.4.274` | exit 0; no `stop`, no `apt-get` |
| serve inactive, app closed | `STUB_SERVE_ACTIVE_RC=3` | exit 0; `apt-get` called; no `stop`, no `start` |
| serve inactive, app open | `STUB_SERVE_ACTIVE_RC=3`, `STUB_PGREP_RCS=0` | exit 0; no `apt-get`; `skip: Orca is running` |
| install fails | `STUB_SERVE_ACTIVE_RC=0`, `STUB_APT_RC=100` | exit 1; log still ends with `start orca-serve.service` |
| tampered download | yml sha512 does not match the `.deb` | exit 1; no `stop`, no `apt-get` |
| offline | `ORCA_UPDATE_RELEASES_URL=file:///nonexistent` | exit 0; no `stop`, no `apt-get`; `cannot fetch` |
| dry run | `--dry-run` | exit 0; no `stop`, no `apt-get`; `would install orca-ide 1.4.274 (installed 1.4.261)` |

- [ ] **Step 2: Run the tests and see the serve cases fail**

Run: `bash ansible/roles/dev_gui/tests/orca-update-test.sh`
Expected: Task 1 cases pass, serve cases fail.

- [ ] **Step 3: Implement `run_serve`**

Follow the spec's serve steps and the ordering decision above. The dry run stops after the version comparison and does not download the `.deb`. Download and verify before stopping anything. Restart through a `trap` or equivalent so `start` runs on every exit path after `stop`.

- [ ] **Step 4: Run the tests and shellcheck**

Run: `bash ansible/roles/dev_gui/tests/orca-update-test.sh && shellcheck ansible/roles/dev_gui/files/orca-update ansible/roles/dev_gui/tests/orca-update-test.sh`
Expected: all cases pass; shellcheck prints nothing.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/dev_gui/files/orca-update ansible/roles/dev_gui/tests/orca-update-test.sh
git commit -m "feat(dev_gui): add serve mode to orca-update"
```

### Task 3: Role wiring and CI

**Files:**
- Modify: `ansible/roles/dev_gui/defaults/main.yml` (after `dev_gui_orca_version`)
- Modify: `ansible/roles/dev_gui/tasks/main.yml` (after the `Install orca` task, before the `orca-serve` block; also the comment at lines 252-254)
- Modify: `ansible/roles/dev_gui/handlers/main.yml`
- Modify: `.github/workflows/verify.yml` (lint job)

**Interfaces:**
- Consumes: `ansible/roles/dev_gui/files/orca-update` and its CLI from Tasks 1 and 2.
- Produces: `/usr/local/sbin/orca-update` (root, 0755), `/etc/systemd/system/orca-update.service`, `/etc/systemd/system/orca-update.timer`.

- [ ] **Step 1: Add the defaults**

`dev_gui_orca_auto_update: true` and `dev_gui_orca_auto_update_serve_time: "04:00"`, with a comment pointing at stablyai/orca#18086 as the reason this exists and when to remove it.

- [ ] **Step 2: Add the tasks**

All `become: true`, tagged `orca`, `when: dev_gui_orca_auto_update`:

1. Copy the script to `/usr/local/sbin/orca-update`.
2. Write `orca-update.service` (inline `content:`, as the `orca-serve` unit does): `Type=oneshot`, `ExecStart=/usr/local/sbin/orca-update {{ 'serve' if dev_gui_orca_serve else 'desktop' }} {{ ansible_user_id }}`, and `LogLevelMax=notice` on desktop hosts only.
3. Write `orca-update.timer`: desktop hosts `OnBootSec=2min` and `OnUnitInactiveSec=1min`; serve hosts `OnCalendar=*-*-* {{ dev_gui_orca_auto_update_serve_time }}:00` and `Persistent=true`. `WantedBy=timers.target`.
4. Enable and start `orca-update.timer` with `daemon_reload: true`.

Unit changes notify a new handler `Restart orca-update timer` (system scope, `daemon_reload: true`).

When `dev_gui_orca_auto_update` is false: the timer is stopped and disabled and the three files are removed. The play must also converge on a host that never had them.

Rewrite the comment above `Gather installed packages`: Orca downloads updates but does not install them on `.deb` hosts; `orca-update` does that; the pinned install only bootstraps and must not downgrade.

- [ ] **Step 3: Run the script tests in CI**

In the lint job of `.github/workflows/verify.yml`, add a step after ansible-lint that runs `shellcheck` on the two files and then `bash ansible/roles/dev_gui/tests/orca-update-test.sh`.

- [ ] **Step 4: Lint and syntax-check**

Run: `cd ansible && ansible-lint roles/dev_gui && ansible-playbook dev.yml --syntax-check`
Expected: ansible-lint reports no violations; syntax check prints the playbook name with no error.

- [ ] **Step 5: Render check**

Run: `cd ansible && ansible-playbook -i inventory.yml dev.yml --tags orca --check --diff --limit ubuntu-work-laptop.local -c local` only if it runs without a sudo prompt; otherwise skip and say so. Molecule runs in CI on the PR (the `dev_gui` path filter triggers it), on both Ubuntu images, where the timer is enabled for real under systemd.

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/dev_gui .github/workflows/verify.yml docs/superpowers
git commit -m "feat(dev_gui): install orca updates from a root timer"
```

### Task 4: Hand over for deployment

Deployment needs Jason's sudo password and touches host state, so Claude does not run it.

- [ ] **Step 1:** Push the branch and open a PR (never merge it). Wait for molecule.
- [ ] **Step 2:** Give Jason the commands:
  - Laptop: `cd ansible && ansible-playbook -i inventory.yml dev.yml --tags orca --limit ubuntu-work-laptop.local -K`, then `sudo /usr/local/sbin/orca-update desktop jason --dry-run` (expect `skip: Orca is running` while Orca is open), then quit Orca and check `dpkg -s orca-ide | grep Version` after about a minute (expect `1.4.274` or whatever is pending).
  - Beast: the same playbook with `--limit ubuntu-beast.local`, then `sudo /usr/local/sbin/orca-update serve jason --dry-run` (expect `would install orca-ide <latest> (installed 1.4.261)`). The real update happens at 04:00, or with `sudo systemctl start orca-update.service` when Jason is ready for `orca-serve` to restart.
- [ ] **Step 3:** Verify over SSH what Jason reports: `systemctl list-timers orca-update.timer` and `journalctl -u orca-update.service -n 20` on each host.
