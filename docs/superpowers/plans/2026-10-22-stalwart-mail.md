# Stalwart + Bulwark Lite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Mailu stack on the `www` droplet with a single Stalwart container plus Bulwark Lite webmail, with no PHP or Node anywhere in the mail path, and no change for any existing client.

**Architecture:** `ansible/roles/stalwart` is rewritten to run `stalwartlabs/stalwart` with `community.docker.docker_container`. Stalwart 0.16 keeps only the DataStore in `config.json`; everything else (domains, accounts, aliases, catch-alls, the certificate as file paths into the nginx-proxy `certs` volume, RSA DKIM, listeners, the Bulwark Application, spam and rate settings) comes from an NDJSON `upsert` plan applied with `stalwart-cli apply`. nginx-proxy keeps terminating public HTTPS. The admin UI is served only on a listener bound to the droplet's tailnet IP. A `stalwart_staged` switch runs the container on tailnet-only ports beside Mailu until the cutover.

**Tech Stack:** Ansible (`community.docker`, `community.general.onepassword`), Stalwart v0.16.x, Bulwark Lite (`bulwark-lite-stalwart.zip`), nginx-proxy + acme-companion, Vandelay (Stalwart's importer) for the mailbox move, Python 3 stdlib for the acceptance script (plus `dkimpy` for the DKIM check), Renovate.

**Spec:** `docs/superpowers/specs/2026-10-22-stalwart-mail-design.md`

## Global Constraints

- No PHP and no Node/app server anywhere in the mail path. Bulwark is the **Lite** zip served by Stalwart, never the `ghcr.io/bulwarkmail/webmail` image.
- Image `stalwartlabs/stalwart`, `v0.16` line, pinned `image:tag` + `digest:` in defaults (the same shape as `mailu_images`). Bulwark `resourceUrl` pinned to a specific release tag, never `releases/latest`.
- `community.docker.docker_container` only, no compose file. The container has a `memory` cap.
- Host names `mail.jasonernst.com`, `mail.sair.run`, `mail.rustd.xyz`, `mail.darksearch.xyz`. Public ports **25, 465, 993 only** (no 587/143/110/995/4190). Stalwart never binds host 80/443 and never runs ACME.
- The same usernames and the same 1Password items for every password the `mailu` role reads today (`ansible/roles/mailu/tasks/main.yml` first task). No consumer role (`jasonernst_com`, `sair_portal`, `rustd_xyz`) changes.
- DKIM: RSA, selector `dkim`, keys copied from `/opt/mailu/dkim/<domain>.dkim.key`. No DNS/terraform change.
- Catch-all on each domain → `jason@<domain>`. `admin@jasonernst.com` becomes an alias to `jason@jasonernst.com`.
- Webmail on `https://mail.jasonernst.com/webmail/`; `/webmail/` on the other three hosts redirects there.
- Spam goes to Junk by default; SMTP reject only at Stalwart's high-confidence threshold.
- Outbound limit of about 200 messages/day per account.
- The admin UI and admin API are reachable only over the tailnet. `STALWART_RECOVERY_ADMIN` is set only for the first-boot start and absent afterwards.
- 1Password items are read once per play into `stalwart_op_*` facts (#542 pattern), and `no_log: true` goes on every task that handles a secret or a rendered plan.
- The NAS backup keeps the pipeline shape and the "newest DB snapshot is the last transfer" freshness contract.
- `ansible-lint .` (in `ansible/`) passes; that is CI's gate (`.github/workflows/verify.yml`).
- A second converge of the play reports `changed=0` for the stalwart role.

## Review Focus

1. **Re-running the play.** `stalwart-cli apply` always reports "updated" for matched upserts. The expected behaviour is that a second run is `changed=0`. Pinned in Task 3 by gating apply on the rendered plan changing, plus a converge-twice check.
2. **Passwords with JSON-hostile characters** (`"`, `\`, `%`, `{`) in 1Password. The expected behaviour is that the account still authenticates. Pinned in Task 3's local smoke test with a fixture password `pa"ss\wo%rd{x}`.
3. **SNI on a non-primary host name** (`mail.rustd.xyz:993`, `mail.sair.run:465`). The expected behaviour is that the same SAN cert is served and the client does not warn. Pinned in Task 2's `tls_cert_*` checks, which run for every host on every port.
4. **The cert renewed while Stalwart is running.** The expected behaviour is that the new cert is served with no Ansible run. Pinned in Task 5.
5. **Plus-addressing and mixed case** (`jason+x@rustd.xyz`, `Jason@RustD.xyz`). The expected behaviour is delivery to `jason@rustd.xyz`: not a catch-all hit in a different form, and not a bounce. Pinned in Task 2 (`plus_address`, `mixed_case`).

---

### Task 1: Prove the Stalwart object model locally

The spec leaves exact object and field names to the builder. Pin them against the exact version before writing any Ansible, using a throwaway local container. Every later task copies names from this task's output.

**Files:**
- Create: `ansible/roles/stalwart/tests/local-smoke.sh`
- Create: `ansible/roles/stalwart/tests/fixtures/` (self-signed SAN cert + key for the four `mail.*` names, one RSA DKIM key)
- Modify: `ansible/roles/stalwart/README.md` (replace it; add a "Verified against v0.16.N" section)

**Interfaces:**
- Produces: the README section listing, for the pinned version, the exact object names and fields used by `Domain` (`name`, `catchAllAddress`, `subAddressing`, `certificateManagement`, `dkimManagement`, `reportAddressUri`), `Account` (individual: name, domain ref, secret field, aliases or alias mechanism, per-account send limit field), `Certificate` (file-path form for `certificate`/`privateKey`), `DkimSignature` (RSA, selector, private key, domain ref), `NetworkListener` (bind, protocol, implicit TLS), `Application` (`resourceUrl`, `urlPrefix`), the spam-filter junk/reject threshold objects, how the admin role/IP restriction is expressed, and the CLI auth flags/env (URL, user, password) that `stalwart-cli` takes.
- Produces: `local-smoke.sh <plan.ndjson>`, which starts `stalwartlabs/stalwart@<digest>` locally on a random port set, bootstraps with `STALWART_RECOVERY_MODE=1` + `STALWART_RECOVERY_ADMIN`, applies the plan, restarts without recovery, runs the assertions below, and tears down. Exit 0 = all pass.

- [ ] **Step 1: Pick the version.** Take the latest `v0.16.*` release (v0.16.27 on 2026-10-18), and record the tag and the `docker buildx imagetools inspect` digest for `stalwartlabs/stalwart:v0.16.N`.
- [ ] **Step 2: Dump the schema.** In a local container started in recovery mode, run `stalwart-cli describe <Object>` for each object above and save the raw output under `tests/fixtures/describe/` (gitignored if large; summarize in the README).
- [ ] **Step 3: Write `local-smoke.sh` with these assertions, failing first** (no plan yet):
  - `smtp_auth`: AUTH PLAIN on implicit-TLS submission for `noreply@rustd.xyz` with fixture password `pa"ss\wo%rd{x}` succeeds.
  - `imap_login`: IMAPS login for `jason@rustd.xyz` succeeds.
  - `catchall`: mail to `nobody-<rand>@rustd.xyz` on the SMTP listener lands in `jason@rustd.xyz` INBOX.
  - `alias`: mail to `contact@rustd.xyz` lands in `jason@rustd.xyz`.
  - `dkim_signed`: a message submitted by `noreply@rustd.xyz` and delivered locally carries `DKIM-Signature` with `s=dkim; d=rustd.xyz; a=rsa-sha256`, verified against the fixture public key.
  - `cert_file`: the IMAPS listener serves the fixture cert (SHA-256 fingerprint match) for SNI `mail.rustd.xyz`.
  - `webmail`: `GET /webmail/` returns 200 with Bulwark's `index.html`.
  - `no_recovery`: after the restart, the recovery admin credential is refused.
- [ ] **Step 4: Run it.** Run `bash ansible/roles/stalwart/tests/local-smoke.sh /dev/null`. Expected: FAIL on every assertion except container start.
- [ ] **Step 5: Hand-write `tests/fixtures/plan.ndjson`** for one domain (`rustd.xyz`) using the names from Step 2, then iterate until `local-smoke.sh tests/fixtures/plan.ndjson` exits 0. Also prove:
  - The cert reload behaviour: replace the fixture cert file in place, then record whether the listener serves the new one, after how long, or only after a named reload action. This drives Task 5.
  - How an admin principal is restricted to source IPs (or whatever 0.16 offers). This drives Task 4.
  - A way to produce a mid-score spam message that lands in Junk. Record the method for Task 2.
  - The Vandelay command pair that imports a Maildir++ root and pushes it into a Stalwart account. Use a copied fixture maildir with `.Sent`/`.Junk` subfolders. This drives Task 9. If Vandelay cannot push into Stalwart, stop and bring the migration method back to the operator before Task 9; the fallback is imapsync from a Mailu IMAP that is still running.
- [ ] **Step 6: Record findings** in the README "Verified against v0.16.N" section, with exact names, the cert-reload result, and the admin-restriction and Vandelay commands.
- [ ] **Step 7: Commit.** `git add ansible/roles/stalwart && git commit -m "test(stalwart): local smoke harness pinned to v0.16.N"`. Delete the old binary-install files (`templates/config.toml.j2`, `templates/stalwart-mail.service.j2`, the old `tasks/` and `defaults/` content) in this commit too.

### Task 2: Acceptance script (red against today's Mailu)

**Files:**
- Create: `scripts/mail_acceptance.py`
- Create: `scripts/mail_acceptance.env` (only `op://Infrastructure/<item>/password` references, no secrets)

**Interfaces:**
- Produces: `python3 scripts/mail_acceptance.py --mode {staged,public} [--only CHECK ...]`, which prints one `PASS|FAIL|SKIP <check>` line per check and exits non-zero on any FAIL. Run it as `op run --env-file scripts/mail_acceptance.env -- python3 scripts/mail_acceptance.py ...`.
- `--mode staged` connects to the tailnet IP (`--connect`, default `100.98.223.44`) on staged ports `2525/4465/9993`, with HTTP at `http://<ip>:8080` and admin at `http://<ip>:8081`, using the real host names as SNI. `--mode public` uses DNS and ports `25/465/993` with HTTPS.

- [ ] **Step 1: Write the checks.** Use stdlib `smtplib`/`imaplib`/`ssl`/`urllib`, and `dkim` from `dkimpy` for `dkim_*`. Each delivery check uses a unique `Subject` token, polls IMAP for 90 s, and deletes the message afterwards.
  - `tls_cert_<host>_<port>`: for all 4 hosts × {465, 993} (staged: 4465, 9993), the cert's SANs include all four `mail.*` names and the issuer is Let's Encrypt.
  - `smtp_auth_<account>`: all eight mailbox accounts (`jason@` ×4, `kai@jasonernst.com`, `noreply@` ×3) authenticate on 465.
  - `imap_login_<account>`: `jason@` ×4 and `kai@jasonernst.com`.
  - `alias_<alias>`: every alias in the spec's table, plus `admin@jasonernst.com`, delivers to its destination's INBOX.
  - `catchall_<domain>`: `zz-<token>@<domain>` → `jason@<domain>` INBOX, for all four.
  - `plus_address`: `jason+acc@rustd.xyz` → `jason@rustd.xyz`. `mixed_case`: `Jason@RustD.xyz` → `jason@rustd.xyz`.
  - `dkim_<domain>`: a message sent by `noreply@<domain>` (`jason@darksearch.xyz` for darksearch) and read back raw verifies with `dkim.verify()` against live DNS, with `s=dkim`.
  - `webmail_primary`: `/webmail/` on `mail.jasonernst.com` → 200 with the Bulwark marker. `webmail_redirect_<host>`: the other three → 301/302 to `https://mail.jasonernst.com/webmail/`.
  - `admin_public_blocked` (public only): `/admin` on every host → 403 or 404, and a JMAP admin call with the Stalwart admin credential against the public URL is refused.
  - `admin_tailnet_ok`: `http://<tailnet-ip>:8081/admin` → 200.
  - `spam_junk`: the method recorded in Task 1 lands the message in `jason@jasonernst.com` Junk, not INBOX, and with no bounce.
  - `spam_reject_gtube`: GTUBE to `jason@jasonernst.com` gets a 5xx at SMTP.
  - `autoconfig` (public only, reports WARN rather than FAIL): `https://autoconfig.jasonernst.com/mail/config-v1.1.xml` and `https://mail.jasonernst.com/.well-known/autoconfig/mail/config-v1.1.xml` return XML naming `mail.jasonernst.com` on 465/993. The spec only asks to confirm this or note what breaks, so a WARN goes in the PR description.
- [ ] **Step 2: Run against Mailu today.** Run `... --mode public`. Expected: `smtp_auth_*`, `imap_login_*`, `alias_*` (except `admin@`), `tls_cert_*` and `dkim_*` PASS. `catchall_*`, `webmail_*`, `admin_*`, `alias_admin` and `spam_junk` FAIL. Record the output in the PR description as the baseline.
- [ ] **Step 3: Commit.** `git commit -m "test(mail): acceptance script for the Mailu -> Stalwart move"`

### Task 3: Role core: container, bootstrap, plan

**Files:**
- Create/replace: `ansible/roles/stalwart/defaults/main.yml`, `tasks/main.yml`, `tasks/bootstrap.yml`, `templates/config.json.j2`, `templates/plan.ndjson.j2`, `handlers/main.yml`, `meta/main.yml`
- Modify: `ansible/roles/stalwart/tests/local-smoke.sh` (accept a plan rendered from the role template)

**Interfaces:**
- Consumes: the object/field names from the Task 1 README.
- Produces these defaults:
  - `stalwart_image` / `stalwart_image_digest`; `stalwart_install_path: /opt/stalwart` (subdirectories `etc/`, `data/`, `dkim/`, `backups/`, owned by UID 2000).
  - `stalwart_staged: true`; `stalwart_tailnet_ip` (a fact from `tailscale ip -4` on the host).
  - `stalwart_domains`: a list in the same shape as `mailu_additional_domains`, plus the primary domain as an entry. Each entry has `domain` and `users: [{user, password}]`.
  - `stalwart_aliases` (the same shape as `mailu_aliases`, plus `admin@jasonernst.com`); `stalwart_memory: "512m"` (revisit in Task 8).
  - `stalwart_admin_user: admin`, with its password from 1Password item `Stalwart Admin`; recovery credential from item `Stalwart Recovery Admin`.
- Produces the handler `Apply Stalwart plan`, which runs `docker exec stalwart stalwart-cli ... apply --file /etc/stalwart/plan.ndjson` (auth per Task 1). Task 4 adds plan lines through the same template.
- Produces the container name `stalwart`, on networks `nginx-proxy` plus its own `stalwart` network.

- [ ] **Step 1: Make the smoke test render the role template.** Extend `local-smoke.sh` to render `templates/plan.ndjson.j2` with `ansible localhost -m template` and test vars (two domains, the fixture password from Review Focus 2). Run it. Expected: FAIL (the template doesn't exist).
- [ ] **Step 2: Write the 1Password read.** In the role's first task, read every `mailu_op_*` item the mailu role reads, plus the two new Stalwart items, into `stalwart_op_*` facts. One lookup per item, `no_log: true`.
- [ ] **Step 3: Write `config.json.j2`** with the RocksDB DataStore at `/var/lib/stalwart` only.
- [ ] **Step 4: Write `plan.ndjson.j2`** with `upsert` only (never `reconcile`, never `destroy`), parents first:
  - Domains with `catchAllAddress` `jason@<domain>`, `subAddressing` Enabled, `certificateManagement` Manual and `dkimManagement` Manual.
  - The Certificate as file paths `/certs/mail.jasonernst.com.crt` / `.key`.
  - One RSA DkimSignature per domain, selector `dkim`, private key `/dkim/<domain>.dkim.key`.
  - Individual accounts, the permanent admin account, aliases, and the spam thresholds (Junk default, reject high-confidence only).
  - The per-account ~200/day outbound limit.
  - Listeners: SMTP 25, implicit-TLS submission 465, IMAPS 993, and plain HTTP 8080 for the docker network.

  Every interpolated string goes through `| to_json`. Then run `local-smoke.sh`. Expected: PASS.
- [ ] **Step 5: Write `tasks/main.yml`:**
  - Directories.
  - Copy `/opt/mailu/dkim/<domain>.dkim.key` → `/opt/stalwart/dkim/` (`remote_src`, `mode 0600`, owner 2000, `force: false`), for every domain.
  - Template `config.json` and `plan.ndjson` (`mode 0600`, `no_log`). The plan notifies the apply handler.
  - `include_tasks: bootstrap.yml` when `/opt/stalwart/data` is empty. It starts with `STALWART_RECOVERY_MODE=1` + `STALWART_RECOVERY_ADMIN`, applies the plan against the recovery listener, then recreates the container without those env vars.
  - `docker_container` with env `STALWART_PUBLIC_URL=https://mail.jasonernst.com` and `memory: "{{ stalwart_memory }}"`.
  - Volumes: `certs:/certs:ro`, `/opt/stalwart/etc:/etc/stalwart`, `/opt/stalwart/data:/var/lib/stalwart`, `/opt/stalwart/dkim:/dkim:ro`.
  - Ports: when `stalwart_staged`, `{{ stalwart_tailnet_ip }}:2525:25`, `:4465:465`, `:9993:993`, `:8080:8080`; otherwise `25:25`, `465:465`, `993:993` with `default_host_ip: ""` (IPv6, like nginx-proxy, #591).
  - `restart_policy: unless-stopped`.
  - `meta: flush_handlers`, then `wait_for` on each mail port via `ansible_default_ipv4.address` (or the tailnet IP when staged), as the mailu role does (#557).
- [ ] **Step 6: Lint.** Run `cd ansible && ansible-lint roles/stalwart`. Expected: `0 failure(s)`.
- [ ] **Step 7: Commit.** `git commit -m "feat(stalwart): dockerized role with declarative apply plan"`

### Task 4: HTTP: webmail, redirects, tailnet-only admin

**Files:**
- Modify: `ansible/roles/stalwart/templates/plan.ndjson.j2` (Application, admin listener, admin restriction)
- Modify: `ansible/roles/stalwart/tasks/main.yml` (`VIRTUAL_HOST`/`LETSENCRYPT_HOST` when not staged; vhost.d files)
- Create: `ansible/roles/stalwart/templates/vhost-primary.conf.j2`, `vhost-secondary.conf.j2`
- Modify: `ansible/roles/stalwart/defaults/main.yml` (`stalwart_bulwark_version`, `stalwart_bulwark_url`)

**Interfaces:**
- Consumes: the `Apply Stalwart plan` handler and `plan.ndjson.j2` from Task 3; the admin-restriction mechanism from Task 1.
- Produces: `/webmail` served by Stalwart. nginx-proxy per-host files in the `vhost` volume (`/var/lib/docker/volumes/vhost/_data/<host>`), where:
  - all four hosts carry `location /admin { return 403; }`;
  - the three secondaries also carry `location /webmail { return 302 https://mail.jasonernst.com/webmail/; }`.
  An admin listener on container port 8081, published only on `{{ stalwart_tailnet_ip }}:8081`.

- [ ] **Step 1: Add assertions to `local-smoke.sh`.** `webmail` (already present) plus `admin_listener`: `/admin` on 8081 → 200, and admin login via the 8080 listener refused per the Task 1 mechanism. Run it. Expected: the new assertions FAIL.
- [ ] **Step 2: Extend the plan.** Add the Application `{"urlPrefix":{"/webmail":true},"resourceUrl":"https://github.com/bulwarkmail/webmail/releases/download/v{{ stalwart_bulwark_version }}/bulwark-lite-stalwart.zip"}` and the UpdateApps action, the 8081 listener, and the admin restriction. Run `local-smoke.sh`. Expected: PASS.
- [ ] **Step 3: Add the nginx-proxy wiring.**
  - When `not stalwart_staged`: set `VIRTUAL_HOST`/`LETSENCRYPT_HOST` to the four `mail.*` names (the same list template as `ansible/roles/mailu/templates/docker-compose.yml.j2:29-32`), plus `VIRTUAL_PORT=8080`, `LETSENCRYPT_EMAIL` as mailu sets it, and the vhost.d files.
  - Notify the existing `Reload nginx-proxy` pattern (copy the handler from `roles/jasonernst_com`; don't depend on that role's handler).
- [ ] **Step 4: Lint.** Run `ansible-lint roles/stalwart`. Expected: 0 failures.
- [ ] **Step 5: Commit.** `git commit -m "feat(stalwart): Bulwark Lite webmail, redirects, tailnet-only admin"`

### Task 5: Cert renewal pickup

**Files:**
- Create (only if Task 1 showed no automatic re-read): `ansible/roles/stalwart/templates/stalwart-cert-reload.path.j2`, `stalwart-cert-reload.service.j2`
- Modify: `ansible/roles/stalwart/tasks/main.yml`

**Interfaces:**
- Consumes: Task 1's reload finding.
- Produces: a mechanism by which a changed `/var/lib/docker/volumes/certs/_data/mail.jasonernst.com.crt` is served by 465/993 without an Ansible run. The mechanism is a systemd `.path` unit on that file triggering the reload action Task 1 named, or, failing that, `docker restart stalwart`.

- [ ] **Step 1: Write the test** in `local-smoke.sh` (`cert_renewal`): swap the fixture cert for a second fixture cert, wait up to 120 s, and assert the IMAPS fingerprint changed. Run it. Expected: FAIL, unless Task 1 found an automatic re-read; in that case it PASSES and Steps 2–3 are skipped, with a note in the README.
- [ ] **Step 2: Implement the `.path` + `.service` units** with `PathChanged=` on the cert file, deployed and enabled by the role.
- [ ] **Step 3: Verify on `www` after Task 8 staging.** Run `sudo touch` on the cert file, then check `systemctl status stalwart-cert-reload.service` ran, and that `openssl s_client -connect 100.98.223.44:9993 -servername mail.rustd.xyz` shows the current cert.
- [ ] **Step 4: Commit.** `git commit -m "feat(stalwart): pick up acme-companion renewals"`

### Task 6: NAS backup

**Files:**
- Create: `ansible/roles/stalwart/templates/stalwart-backup.sh.j2`, `stalwart-backup.service.j2`, `stalwart-backup.timer.j2` (port from `roles/mailu/templates/mailu-backup.*`)
- Modify: `ansible/roles/stalwart/defaults/main.yml` (`stalwart_backup_*` mirroring `mailu_backup_*`), `ansible/roles/stalwart/tasks/main.yml` (tagged `backup`)
- Modify: `ansible/group_vars/all.yml` (`stalwart_backup_nas_path: /volume1/storage/backups/stalwart`, `stalwart_backup_nas_keep: 30`), `ansible/roles/backup_nas/defaults/main.yml:73` (add a `stalwart` freshness entry), `ansible/roles/backup_nas/tasks/main.yml` (a prune cron like the mailu one at :169-182)
- Modify: `ansible/jasonernst_com.yml` (`stalwart_backup_nas_rsync_password` alongside the mailu one)

**Interfaces:**
- Produces: a nightly snapshot `stalwart-YYYY-MM-DD.<ext>`, made with the consistent-snapshot method from Task 1 or the Stalwart backup docs (not a raw rsync of live RocksDB). It goes up as the **last** transfer to `<module>/backups/stalwart/db/`, after the mirrors of `dkim/` and `etc/`. The freshness glob is `stalwart-*`. Mailu's backup entries stay until Mailu is deleted.

- [ ] **Step 1: Write the test in `local-smoke.sh` (`backup_restore`)**: run the snapshot command, start a second container from the snapshot, and assert `jason@rustd.xyz` still logs in and its test message is present. Run it. Expected: FAIL.
- [ ] **Step 2: Implement the script and units** (`set -euo pipefail`, temp name + rename, local keep 7, the same rsync opts as `mailu-backup.sh.j2`). Run `local-smoke.sh`. Expected: PASS.
- [ ] **Step 3: Lint.** Run `ansible-lint roles/stalwart roles/backup_nas`. Expected: 0 failures.
- [ ] **Step 4: Commit.** `git commit -m "feat(stalwart): nightly NAS backup"`

### Task 7: Renovate

**Files:**
- Modify: `renovate.json`

**Interfaces:**
- Produces two custom managers: `stalwartlabs/stalwart` digest tracking on `ansible/roles/stalwart/defaults/main.yml`, in the same regex shape as the mailu manager, and `bulwarkmail/webmail` github-releases on `stalwart_bulwark_version`. Both carry a packageRule `groupName: "stalwart"`, `automerge: false`, with the mailu rule's description ("merging doesn't deploy it; run `--tags stalwart`, then merge by hand").

- [ ] **Step 1: Validate.** Run `npx --yes --package renovate@latest -- renovate-config-validator renovate.json`. Expected: `Config validated successfully`.
- [ ] **Step 2: Check the regex.** Confirm each regex matches the defaults with `python3 -c 're.search(...)'` against the file. Expected: one match each, capturing the current tag/digest and the version.
- [ ] **Step 3: Commit.** `git commit -m "chore(renovate): track stalwart image and bulwark lite"`

### Task 8: Stage on `www` beside Mailu

**Files:**
- Modify: `ansible/jasonernst_com.yml` (add `{ role: stalwart, tags: [stalwart] }` after `mailu`; `stalwart_staged: true`)

- [ ] **Step 1: Create the 1Password items.** Have the operator create `Stalwart Admin` and `Stalwart Recovery Admin` in the Infrastructure vault. These are outward-facing actions, so confirm with the operator first.
- [ ] **Step 2: Deploy.** From `ansible/`, run `ansible-playbook jasonernst_com.yml --tags stalwart`. Expected: success. Then run it again. Expected: `changed=0` for the stalwart role.
- [ ] **Step 3: Accept.** Run `op run --env-file scripts/mail_acceptance.env -- python3 scripts/mail_acceptance.py --mode staged`. Expected: every check PASS, except the public-only ones (`admin_public_blocked`, `webmail_redirect_*`), which SKIP.
- [ ] **Step 4: Size memory.** Run `docker stats --no-stream stalwart` after the acceptance run. Set `stalwart_memory` to roughly twice the observed value, at most `768m` (the droplet has ~940 MB free). Re-deploy.
- [ ] **Step 5: Write the cutover and rollback runbook** into `ansible/roles/stalwart/README.md`, with Task 9's steps and the rollback below.
  - Rollback: run `docker stop stalwart`; run `docker compose -f /opt/mailu/docker-compose.yml up -d`; re-run `--tags mailu`.
  - Mail that arrived on Stalwart in the meantime is exported with Vandelay (JMAP source) and pushed back with imapsync to Mailu, using each user's 1Password credentials.
- [ ] **Step 6: Commit and open the PR.** Commit, push the branch, open the PR with `--repo compscidr/iac`, and monitor CI. Do not merge.

### Task 9: Cutover (done from the branch once the operator OKs the staged PR; the operator merges afterwards)

**Files:**
- Modify: `ansible/jasonernst_com.yml` (remove `{ role: mailu ... }`; `stalwart_staged: false`)
- Modify: `ansible/roles/mailu/defaults/main.yml` (header comment only: "retired 2026-MM-DD, kept for rollback until <date>")

- [ ] **Step 1: Stop Mailu.** On `www`: `cd /opt/mailu && sudo docker compose down` (data stays on disk). Inbound mail starts queuing at senders; app SMTP fails from here on.
- [ ] **Step 2: Import mailboxes.** For each of the eight mailboxes except `admin@`, run the Vandelay Maildir import from `/opt/mailu/mail/<address>/`, then push into the same Stalwart account, using the commands recorded in Task 1. Expected per account: the message count in Stalwart equals `find /opt/mailu/mail/<address> -path '*/cur/*' -o -path '*/new/*' -type f | wc -l` (excluding `tmp/`).
- [ ] **Step 3: Flip.** Run `ansible-playbook jasonernst_com.yml --tags stalwart` with `stalwart_staged: false`. Expected: the container is recreated on 25/465/993 with `VIRTUAL_HOST`.
- [ ] **Step 4: Remove Mailu's cert symlinks.** Remove `cert.pem`/`key.pem` in the `certs` volume, then confirm that acme-companion still lists the four `mail.*` names in its logs.
- [ ] **Step 5: Accept.** Run `op run --env-file scripts/mail_acceptance.env -- python3 scripts/mail_acceptance.py --mode public`. Expected: every check PASS. Also run the three app flows by hand: the rustd.xyz login email, the sair magic link, and the goblog login code (the goblog one goes via `host-gateway`, which proves the in-host path). All three should arrive with DKIM and DMARC `pass` in the headers.
- [ ] **Step 6: Check uptime-kuma** monitors for mail ports and hosts, and confirm they're green.
- [ ] **Step 7: Commit, push, and update the PR.** Re-check the PR state first, in case it was already squash-merged.
- [ ] **Step 8: Follow up.** File an issue for deleting `/opt/mailu`, `roles/mailu`, the Mailu Renovate rules and the Mailu backup/prune entries after the rollback window. Not in this PR.
