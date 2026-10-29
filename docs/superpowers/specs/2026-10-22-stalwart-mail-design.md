# Replace Mailu with Stalwart + Bulwark Lite

Date: 2026-10-22
Status: draft, awaiting approval

## Why

Mailu's webmail images run PHP. PHP2Shell (CVE-2026-109618/109619, unauthenticated
RCE, fixed in PHP 8.3.36 / 8.4.27) forced `mailu_webmail: none` on 2026-10-21. Mailu's
stable `2024.06` webmail is still PHP 8.3.15 with only a config stopgap (Mailu PR #4148);
only `master` has a patched PHP, and nothing upstream tracks a stable rebuild.

The goal is to get webmail back **without any PHP anywhere in the mail stack**, and to do
it by replacing Mailu entirely rather than waiting on it.

- **Stalwart** (Rust): one process for SMTP, IMAP, JMAP, spam filtering, DKIM, web admin.
- **Bulwark Lite** (static TypeScript/JS, AGPL-3.0, `bulwarkmail/webmail`): a JMAP webmail
  that is just files. Stalwart serves it as an *Application*, so there is no Node process
  and no web server of its own. The full Bulwark edition (Node/Next.js backend) is rejected
  for that reason.

## Who uses it

A single operator. Accounts are one human mailbox per domain, one agent mailbox, and
send-only service accounts that apps log in to over SMTP. Volume is tiny: total mail on
disk today is ~6.5 MB.

## Current state (Mailu, read from IaC and the live admin DB on 2026-10-22)

Runs on the `www` droplet (2 GB RAM, ~940 MB available; Mailu uses ~350 MB) behind
nginx-proxy, role `ansible/roles/mailu`, invoked from `jasonernst_com.yml`.

| Domain | Mailboxes | Aliases |
|---|---|---|
| jasonernst.com | `jason`, `kai` (agent), `noreply` (goblog), `admin` (Mailu admin; DMARC rua/ruf target) | `postmaster` → jason |
| sair.run | `jason`, `noreply` (sair_portal) | `postmaster` → jason |
| rustd.xyz | `jason`, `noreply` (rustd_xyz panel; the panel cannot log anyone in without it) | `postmaster`, `contact` → jason |
| darksearch.xyz | `jason` | `postmaster`, `abuse`, `dmca` → jason |

- No catch-alls, forwards or auto-replies exist today. The live DB matches IaC exactly.
- Passwords for every mailbox are in 1Password (Infrastructure vault) and read by the role.
  The `noreply` passwords are the same items the consumer roles read (`SMTP_USER - goblog`,
  `SMTP_USER - sair`, `SMTP_USER - rustd`).
- Consumers connect to `mail.<domain>:465` (implicit TLS). goblog reaches
  `mail.jasonernst.com` via `host-gateway` because the droplet's own hostname is that name.
- Ports exposed: 25, 465, 993 only (587/143 deliberately absent, #557).
- TLS: one SAN cert for `mail.jasonernst.com` + `mail.<each additional domain>`, issued by
  nginx-proxy's acme-companion into the external `certs` volume via `VIRTUAL_HOST` /
  `LETSENCRYPT_HOST` on Mailu's `front` container. The role symlinks `cert.pem`/`key.pem`
  in that volume.
- DKIM: RSA keys under selector `dkim` at `/opt/mailu/dkim/<domain>.dkim.key`; public halves
  are in `terraform/mail*.tf`.
- DMARC for jasonernst.com: `p=reject`, reports to `admin@jasonernst.com`.
- Outbound rate limit 200/day. Antivirus, webdav, fetchmail off.
- Nightly backup (systemd timer) rsyncs dkim keys, admin DB snapshot, maildirs and env to the
  NAS rsync daemon; the newest DB snapshot is the freshness marker the NAS-side check reads.
- `ansible/roles/stalwart` exists from 2026-01-31 (binary install, own ACME, separate
  droplet). It was never used and is replaced by this work.

## Goals

1. Stalwart serves all four domains with the same mailboxes, aliases and passwords. Every
   existing client (the three apps, kai, the operator's mail clients) keeps working with
   **no configuration change on its side**: same host names, ports 25/465/993, same
   usernames and passwords.
2. **Catch-all per domain to that domain's `jason@`**: unknown `x@rustd.xyz` lands in
   `jason@rustd.xyz`, and so on for all four. The mailbox it lands in says which domain it
   was for.
3. Webmail at `https://mail.jasonernst.com/webmail/` via Bulwark Lite served by Stalwart.
   The other three `mail.<domain>/webmail/` paths redirect there. The operator signs in to
   all four `jason@` mailboxes from that one page (Bulwark supports several accounts at once).
4. Spam is filed, not bounced: likely spam goes to the recipient's Junk folder, and only mail
   Stalwart is highly confident about is rejected at SMTP time. A real message is never
   bounced without the operator seeing it.
5. Stalwart's admin UI and management API reachable **only over the tailnet**, never from the
   public internet.
6. Outbound mail keeps passing SPF/DKIM/DMARC with no DNS change: existing RSA keys under
   selector `dkim` are imported and used for signing.
7. Everything declared in Ansible and converged idempotently on every run, in the repo's
   existing style (1Password lookups read once per play, `no_log` on secrets, digests pinned
   and bumped by Renovate).
8. Backups of the new data to the NAS, same pipeline shape and freshness-marker contract.
9. No mail lost across the cutover; Mailu data retained on disk for a rollback window.

## Non-goals

- Bulwark full edition, OAuth/SSO, plugins, settings sync.
- CalDAV/CardDAV/files rollout (Stalwart has them; nobody uses Mailu's today). Not blocked,
  just not part of this work.
- Re-enabling 587/143 or POP3.
- Stalwart-managed ACME, DNS management or automatic DKIM rotation.
- Moving mail to another droplet.

## Anti-goals (failure even if it "works")

- Any PHP, or any Node/other app server, in the mail path.
- A `noreply` account that stops authenticating: rustd.xyz becomes un-loginable, sair magic
  links and goblog login codes silently stop.
- New DKIM selectors or keys that require DNS edits before mail is signed correctly.
- Admin UI or management API answering from the public internet.
- Stalwart obtaining its own certificates or binding 80/443 on the host (nginx-proxy owns them).
- Mail-domain cert renewals that Stalwart does not pick up, leading to an expired cert ~90
  days later.

## Decided

- **Deployment:** Docker on `www`, managed with `community.docker.docker_container` (and
  related `community.docker` modules) directly. **No compose file.** Image
  `stalwartlabs/stalwart` on the `v0.16` line, pinned by digest, Renovate-tracked like
  `mailu_images`. A memory cap on the container, in line with the projects role (#920).
- **Role:** rewrite `ansible/roles/stalwart` in place (delete the old binary-install
  content), invoked from `jasonernst_com.yml` where `mailu` is today.
- **Configuration model:** Stalwart 0.16 keeps only the `DataStore` in `config.json`;
  everything else (domains, accounts, aliases, certificates, DKIM signatures, listeners,
  applications) is created through `stalwart-cli apply` with an `upsert` plan, which is
  idempotent and is Stalwart's documented Ansible path ("Declarative deployments").
  First boot uses recovery mode with `STALWART_RECOVERY_ADMIN` from 1Password, not the
  setup wizard.
- **TLS:** Stalwart's `Domain.certificateManagement = Manual`, with a `Certificate` object whose
  certificate and private key are **file paths** into the read-only mounted `certs` volume
  (`mail.jasonernst.com.crt` / `.key`). acme-companion keeps issuing the SAN cert because
  the Stalwart container carries the same `VIRTUAL_HOST` / `LETSENCRYPT_HOST` list Mailu's
  `front` carries today.
- **HTTP:** nginx-proxy terminates public TLS for `mail.*` and proxies to Stalwart's plain
  HTTP listener on the docker network. `STALWART_PUBLIC_URL` set so discovery documents
  publish `https://mail.jasonernst.com`.
- **Webmail:** a Stalwart `Application` with `urlPrefix {"/webmail": true}` and `resourceUrl`
  pinned to a **specific** Bulwark release's `bulwark-lite-stalwart.zip` (never
  `releases/latest`), Renovate-tracked. Same-origin, so no permissive CORS.
- **Catch-all:** `Domain.catchAllAddress = jason@<domain>` on each of the four domains.
- **DKIM:** `Domain.dkimManagement = Manual`; one RSA `DkimSignature` per domain, selector
  `dkim`, private key copied from Mailu's `/opt/mailu/dkim/<domain>.dkim.key`.
- **Admin exposure:** tailnet only (see "Left to the builder" for the mechanism).
- **Cutover shape:** stage Stalwart alongside Mailu without public ports or `VIRTUAL_HOST`,
  test it over the tailnet, migrate mailboxes, then stop Mailu and give Stalwart the ports and
  virtual hosts. Mailu's containers removed, `/opt/mailu` left on disk for rollback, deleted in
  a later PR. Sending MTAs queue and retry during the swap.
- **Cutover downtime:** a few minutes of app-side SMTP failure (rustd.xyz login emails, sair
  magic links, goblog login codes) during the port swap is acceptable, at any time of day.
  No zero-downtime machinery. Keep the window short by having the Stalwart container fully
  configured before Mailu stops, so the swap is stop-Mailu, recreate-Stalwart-with-ports.
- **Webmail host:** `mail.jasonernst.com` only; the others redirect (goal 3). This keeps
  Bulwark and JMAP same-origin under the single `STALWART_PUBLIC_URL`.
- **Spam handling:** Junk folder by default, SMTP reject only at Stalwart's high-confidence
  threshold (goal 4). Applies to catch-all and normal mail alike.

## Calls I made (flag any you disagree with)

- **`admin@jasonernst.com`** becomes an alias to `jason@jasonernst.com` (it is Mailu's admin
  login, only used as the DMARC report address). Its 1.9 MB of old DMARC reports are not
  migrated; they stay in the NAS backup and in `/opt/mailu` until it is deleted.
- **Outbound rate limit** carried over as ~200 messages/day per account, so a leaked
  `noreply` password can't be used to blast mail.
- **Stalwart admin credential** is a new 1Password item (`Stalwart Admin`), separate from
  any mailbox. It is a **permanent admin account created by the `apply` plan**, and it is what
  Ansible authenticates `stalwart-cli apply` with on every run. `STALWART_RECOVERY_ADMIN`
  (its own value, also from 1Password) is set only for the first-boot recovery start and
  removed from the container afterwards, so no standing recovery credential lives in the
  container environment and the server never stays in recovery mode.
- **Mailbox migration** uses whichever of `imapsync` or Stalwart's built-in maildir importer
  is simpler; at 6.5 MB either works. Target folders keep their names.

## Left to the builder (verify, don't assume)

- **Cert renewal pickup.** Confirm whether a file-path `Certificate` is re-read when
  acme-companion replaces the file. If not, add a host-side trigger (e.g. a systemd path unit
  on the cert file that runs Stalwart's reload action or restarts the container) so renewal
  needs no Ansible run. Prove it by touching/replacing the file and observing the served cert.
- **Tailnet-only admin.** The WebUI and management API share Stalwart's HTTP listener with
  JMAP and `/webmail`, and Bulwark needs `/api/auth`, `/auth/token`, `/jmap`,
  `/.well-known/jmap` publicly. Design the split (e.g. nginx-proxy per-`VIRTUAL_HOST`
  location rules denying `/admin` and admin-only API paths publicly, plus a second Stalwart
  listener bound to the droplet's tailnet IP for admin). Verify from off-tailnet that admin
  sign-in and admin JMAP calls fail, and that webmail login still works.
- **Exact object/field names** for the `apply` plan against the pinned 0.16.x (the docs
  reference: Domain, Account, Certificate, DkimSignature, Application, NetworkListener).
- **Listener TLS** for 465/993 using the manual certificate, and SNI across all
  `mail.<domain>` names.
- **Consistent backup** of Stalwart's RocksDB (a raw rsync of a live RocksDB dir is not a
  consistent copy; Stalwart has a snapshot/backup path). Keep the NAS layout and make the
  newest snapshot the final transfer, so the NAS-side freshness check still works. Update
  `group_vars/all.yml` / `backup_nas` paths as needed.
- **Autoconfig/autodiscover:** DNS already has `autoconfig` CNAME and SRV records; confirm
  Stalwart answers them, or note what breaks.
- **Memory cap** value, sized from observed usage under the spam filter.
- **Rollback steps** written down before the cutover: how to put Mailu back (start its
  containers, restore its `VIRTUAL_HOST`), what mail received on Stalwart in the meantime
  would need copying back.

## Acceptance

From outside the tailnet unless noted:

- Each `noreply` account sends via `mail.<domain>:465`; each app's real flow is exercised
  (rustd.xyz login email, sair magic link, goblog login code) and the mail arrives with
  DKIM `pass` under selector `dkim` and DMARC `pass`.
- `jason@` on each domain and `kai@jasonernst.com` log in over IMAPS 993 and see their
  migrated mail.
- Mail from outside to each alias and to a random unknown address on each domain lands in
  that domain's `jason@`.
- `https://mail.jasonernst.com/webmail/` signs in with each `jason@` account (several at
  once); `mail.{sair.run,rustd.xyz,darksearch.xyz}/webmail/` redirect to it; no PHP or Node
  process exists on the host for it.
- A test message scored above the Junk threshold but below the reject threshold arrives in
  Junk and is not bounced (builder picks how to produce one; GTUBE likely scores high enough
  to be rejected, so it tests the other branch).
- Admin UI and admin API refuse from the public internet; work over the tailnet.
- Served cert on 465/993/443 is the acme-companion SAN cert; renewal pickup demonstrated.
- Nightly backup lands on the NAS and the freshness check passes.
- A second Ansible run reports no changes.
