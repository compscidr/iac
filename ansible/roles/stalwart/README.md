# Stalwart role

Stalwart mail server (Docker, `stalwartlabs/stalwart` v0.16 line) plus Bulwark Lite webmail,
replacing the `mailu` role on the `www` droplet. Design:
`docs/superpowers/specs/2026-10-22-stalwart-mail-design.md`.

The role itself is being rebuilt; the old binary-install content (systemd unit, `config.toml`)
is gone. What exists today is the local harness that pinned the object model below.

## Local smoke test

```bash
bash ansible/roles/stalwart/tests/local-smoke.sh ansible/roles/stalwart/tests/fixtures/plan.ndjson
```

Local Docker only, 15 to 40 s. It starts the pinned image in recovery mode, applies the plan with
`stalwart-cli apply`, recreates the container without the recovery variables, then checks:
`container_start`, `admin_cli_netns`, `smtp_auth`, `imap_login`, `catchall`, `alias`,
`dkim_signed`, `junk_probe`, `gtube_reject`, `cert_file`, `webmail`, `no_recovery`,
`admin_ip_restricted`, `admin_no_extra_credentials`, `admin_ui_listener`. Exit 0 = all pass. `SMOKE_KEEP=1` leaves the container running.

- `stalwart-cli` comes from `$STALWART_CLI`, `PATH`, or is downloaded (pinned, sha256-checked).
- No private key is in the repo. Each run generates a self-signed SAN cert for the four
  `mail.*` names and one RSA DKIM key (PKCS#1, like Mailu's) in a temp dir, mounted read-only
  at `/certs` and `/dkim` as in production. `tests/fixtures/` holds the plan, a small
  Maildir++ tree and the `describe` output of the objects used (`tests/fixtures/describe/`).
  Passwords in the plan and script are throwaway constants.
- Admin calls after the restart (the lab overlay, the admin checks) run `stalwart-cli`/`curl`
  inside the container's network namespace (`docker run --network container:<name>`),
  because the admin credential only accepts `127.0.0.1`.
- After start the harness applies a lab-only overlay (a `SMOKE_LAB_SENDER` rule, −50 for
  `from.domain == 'sender.test'`): lab mail scores ~11 on missing rDNS/SPF/DMARC alone, so
  without it nothing unauthenticated reaches INBOX. Strangers (`other.test`) are scored
  normally, which is what `junk_probe` and `gtube_reject` use.

## Verified against v0.16.27

Everything below was seen working on a local container on 2026-10-22, not copied from docs.

### Versions

```yaml
stalwart_image: "stalwartlabs/stalwart:v0.16.27"
stalwart_image_digest: "sha256:c429b311c93db5606598abc1c68225a85a6953183848ae01bee9c6a98885836c"
```

- Digest is the multi-arch index (`docker buildx imagetools inspect stalwartlabs/stalwart:v0.16.27`).
- **`stalwart-cli` is not in the image** (it holds only `/usr/local/bin/stalwart`) and not
  attached to `stalwartlabs/stalwart` releases. It is its own repo, `stalwartlabs/cli`;
  tested `v1.0.13`, asset `stalwart-cli-x86_64-unknown-linux-musl.tar.xz`
  (sha256 `689644a491c298b4916714a93a2a249ee2ea70f2f2c054991658c3e8f0f27c13`). It runs on the
  host and talks HTTP to the server.
- Vandelay: `stalwartlabs/vandelay` `v1.0.12`, asset `vandelay-x86_64-unknown-linux-musl.tar.gz`.
- Bulwark Lite: `https://github.com/bulwarkmail/webmail/releases/download/1.17.0/bulwark-lite-stalwart.zip`
  (tags have no `v`; 82 MB, under Stalwart's 100 MB bundle limit).
- Image: runs as UID 2000, `--config /etc/stalwart/config.json`, volumes `/etc/stalwart` and
  `/var/lib/stalwart`, healthcheck built in (`/healthz/live`).

### Boot sequence

- `config.json` holds only the DataStore: `{"@type":"RocksDb","path":"/var/lib/stalwart/"}`.
  It can be mounted read-only. Without it the server enters bootstrap mode (wizard), not
  recovery mode.
- First boot: `STALWART_RECOVERY_MODE=1` + `STALWART_RECOVERY_ADMIN=user:pass`; only an HTTP
  listener on 8080 (`http-recovery`) runs; apply the plan against it.
- Then recreate the container **without both variables**. `STALWART_RECOVERY_ADMIN` alone is
  honoured in normal mode too (proved: leaving it set makes `no_recovery` fail with HTTP 200).
- With **no** `NetworkListener` objects the server opens its built-in default set (it served
  a self-signed cert on 993 in the empty-plan run). Once the plan creates listeners, only those
  exist: the plan's five give exactly 25, 465, 993, 8080, 8081 (no 587/143/443/110/995/4190).
- No `Tracer` object means **no log output at all** in normal mode; the default is a `Log`
  tracer writing to `/var/log/stalwart` inside the container. The plan reconciles it to one
  `Stdout` tracer.
- `STALWART_PUBLIC_URL` sets the URLs in `/jmap/session` (`apiUrl`, `uploadUrl`, OAuth).
  Without it they are `https://<defaultHostname>/…`. A JMAP client (Vandelay, Bulwark) follows
  them, so a lab container with `defaultHostname = mail.jasonernst.com` sends clients to the
  real server. The harness sets `https://smoke.invalid`.

### `stalwart-cli` auth

`--url` / `STALWART_URL`, `--user` / `STALWART_USER`, `--password` / `STALWART_PASSWORD`
(basic auth), or `--api-key` / `STALWART_TOKEN` (bearer). `-k` skips TLS verification. The
basic-auth username may be the bare account name (`stalwart-admin`) or the address
(`stalwart-admin@rustd.xyz`). The CLI uses `GET /api/schema`, `GET /jmap/session` and
`POST /jmap` on the base URL. Management methods (`x:Domain/get`, …) go over the same `/jmap`
endpoint as mail, so path rules cannot separate "admin API" from JMAP.

`apply --file plan.ndjson`: an `upsert` that matches always reports "updated". Re-applying the
fixture plan twice gave `18 updated, 0 created` and no duplicate objects.

### Object names and fields (as used in `tests/fixtures/plan.ndjson`)

Encoding: sets and lists are JSON objects (`{"[::]:25":true}`, `{"0":{…}}`), durations are
milliseconds, multi-variant objects carry `@type`.

| Object | Fields used | Match key |
|---|---|---|
| `Domain` | `name`, `catchAllAddress` (`"jason@rustd.xyz"`), `subAddressing` `{"@type":"Enabled"}`, `certificateManagement` `{"@type":"Manual"}`, `dkimManagement` `{"@type":"Manual"}`, `dnsManagement` `{"@type":"Manual"}` (required), `reportAddressUri` (`"mailto:…"`, default `"mailto:postmaster"`) | `["name"]` |
| `Certificate` | `certificate` `{"@type":"File","filePath":"/certs/mail.jasonernst.com.crt"}`, `privateKey` `{"@type":"File","filePath":"/certs/mail.jasonernst.com.key"}` (also `Text` / `EnvironmentVariable` variants). SANs are server-set from the file. | `["certificate"]` (the label is the server-set `subjectAlternativeNames`) |
| `DkimSignature` | `@type: "Dkim1RsaSha256"`, `domainId`, `selector: "dkim"`, `privateKey` `{"@type":"File","filePath":"/dkim/rustd.xyz.dkim.key"}`. PKCS#1 `BEGIN RSA PRIVATE KEY` accepted. Signs `h=Date:Message-ID:Subject:To:From`, `c=relaxed/relaxed`. | `["domainId","selector"]` (the label is `selector` alone, ambiguous across four domains) |
| `Account` | `@type: "User"`, `name` (local part), `domainId`, `credentials` `{"0":{"@type":"Password","secret":"…","allowedIps":{…}}}`, `aliases` `{"0":{"name":"contact","domainId":"#d"}}`, `roles` `{"@type":"Admin"}` (default `User`), `quotas` `{"maxAppPasswords":0,"maxApiKeys":0}` | `["name","domainId"]` (the label is `name` alone; `jason` exists in four domains) |
| `NetworkListener` | `name`, `bind` `{"[::]:465":true}`, `protocol` (`smtp`, `imap`, `http`, `lmtp`, `pop3`, `manageSieve`), `useTls` + `tlsImplicit` for 465/993 | `["name"]` |
| `Application` | `description`, `resourceUrl`, `urlPrefix` `{"/webmail":true}`, `enabled` | `["description"]` |
| `SystemSettings` (singleton, `update`) | `defaultHostname`, `defaultDomainId`, `defaultCertificateId` | n/a |
| `Http` (singleton) | `allowedEndpoints` expression (see admin restriction) | n/a |
| `Tracer` | `reconcile`, `@type: "Stdout"`, `level: "info"`, `ansi: false` | `["@type"]` |
| `SpamSettings` (singleton) | `scoreSpam` (default 5), `scoreReject` (default 0 = off), `scoreDiscard` (0 = off), `spamFilterRulesUrl` | n/a |
| `Email` (singleton) | `defaultFolders` `{"junk":{"name":"Junk"},"sent":{"name":"Sent"},"trash":{"name":"Trash"},"drafts":{"name":"Drafts"}}` | n/a |
| `MtaInboundThrottle` | `description` (immutable), `key` `{"authenticatedAs":true}`, `match` `{"match":{},"else":"!is_empty(authenticated_as)"}`, `rate` `{"count":200,"period":86400000}` | `["description"]` |

- **Aliases** are `Account.aliases` entries (local part + domain ref). Mail to two of one
  account's addresses in one transaction is delivered once.
- **Catch-all**: `nobody-x@rustd.xyz` lands in `jason@rustd.xyz` INBOX with
  `Delivered-To: jason@rustd.xyz` and the original `To:`. Without `catchAllAddress` the RCPT
  gets `550 5.1.2 Mailbox does not exist`.
- **Per-account send limit**: there is no field on `Account`. The `MtaInboundThrottle` above
  is evaluated at RCPT (so it counts recipients, not messages) per authenticated login.
  Proved with `count: 2`: the third RCPT got `452 4.4.5 Rate limit exceeded`.
- **Folders**: the stock names are `Deleted Items`, `Drafts`, `Junk Mail`, `Sent Items`. The
  `Email.defaultFolders` override gives Mailu's `Junk`/`Sent`/`Trash`/`Drafts`, but only for
  folders created after it is set, so it must be in the first apply. Keys are the `SpecialUse`
  enum (`inbox`, `trash`, `junk`, `drafts`, `archive`, `sent`, …).
- **Submission**: the `MtaStageAuth` defaults offer PLAIN/LOGIN only when `local_port != 25 &&
  is_tls`, require auth on ports other than 25, and `mustMatchSender` is true. The fixture
  password `pa"ss\wo%rd{x}` round-trips through the plan JSON (`"pa\"ss\\wo%rd{x}"`).
  `Authentication.passwordMinStrength` did not reject plan-set passwords.
- **Settings reload**: listener, MTA, spam-rule and expression changes are compiled at start.
  A new `SpamRule` did not fire until `Action/ReloadSettings` (proved with `ClassifySpam`
  before and after). In a plan:
  `{"@type":"create","object":"Action","value":{"r":{"@type":"ReloadSettings"}}}`.
  The first-boot flow does not need it because the server restarts after the apply.

### Webmail

The `Application` above serves Bulwark at `/webmail/` on any HTTP listener (200 on 8080 and
8081). Stalwart downloads the zip a few seconds after start and keeps it in its store, which
grows the RocksDB directory by ~80 MB. Creating the Application in recovery mode and
restarting is enough; on a running server it needs `Action/UpdateApps`. The stock web admin
is a second Application (`/admin`, `/account`). `Http.redirectRoot` defaults to `/account`,
so `GET /` on the public listener ends at a 403 under the rule below.

### Admin restriction (Task 4)

Proved by `admin_ip_restricted`, `admin_no_extra_credentials`, `admin_cli_netns` and
`admin_ui_listener`:

1. **Per-credential source IPs**: `Account.credentials.<n>.allowedIps` (`Set<IpMask>`, e.g.
   `{"127.0.0.1":true}`). The limit belongs to **one credential**, not to the account. A
   login with that credential from any other address is refused on every protocol:
   JMAP/HTTP answers `403` and logs `security.ip-unauthorized … "IP address not allowed."`,
   and IMAP login fails the same way. Other accounts are unaffected. It keys on the TCP peer
   address because `Http.useXForwarded` is `false` by default. Keep it that way: with it on,
   a client-supplied `X-Forwarded-For` passed through nginx-proxy could claim a tailnet address.
2. **No other credentials on the admin**. App passwords and API keys are credentials of
   their own with their own (empty by default) `allowedIps`. Proved: an app password and an
   API key created for the admin both ran `x:Domain/query` over the public listener from
   the "nginx-proxy" sidecar. Three facts close this:
   - `x:Account/set` refuses a second Password credential ("Only one password credential is
     allowed.") and refuses to add secondary credentials directly ("Secondary credentials
     cannot be set directly."). They can only be created through `x:AppPassword/set` and
     `x:ApiKey/set`.
   - The plan gives the admin `"quotas":{"maxAppPasswords":0,"maxApiKeys":0}`. Both creates
     then fail with `overQuota` (asserted by `admin_no_extra_credentials`).
   - Every `Account` upsert sends the whole `credentials` list, so a re-apply deletes any
     secondary credential (see "Re-applying an Account upsert" below). An admin who raises
     their own quota and adds a key (which takes an admin login from an allowed address) is
     undone on the next Ansible run.
3. **Per-listener path rule** (stops the web admin UI loading publicly):
   `Http.allowedEndpoints` =
   `{"match":{"0":{"if":"listener == 'http' && (starts_with(path, '/admin') || starts_with(path, '/account'))","then":"403"}},"else":"200"}`.
   `listener` is the `NetworkListener.name`. Available variables: `listener`, `remote_ip`,
   `local_ip`, `local_port`, `path`, `url`, `method`, `headers`, `is_tls`, `protocol`.

**Never put a docker gateway address in `allowedIps`.** Anything that reaches a published
port through docker-proxy (userland proxy, hairpin, IPv6 to a published port without ip6tables
NAT) arrives from the gateway, public clients included. `admin_ip_restricted` checks that the
admin is refused through the host's published 8081, which arrives from the gateway.

**How Ansible on the droplet runs `stalwart-cli`**: inside the container's network namespace,
against `127.0.0.1`, with `127.0.0.1` in `allowedIps`. Nothing outside the container can
originate from its loopback. The CLI is not in the image, so mount the static musl binary.
The image user's HOME is not writable and the CLI needs one for its schema cache (without it:
`error: Permission denied (os error 13)`):

```bash
docker run --rm --network container:stalwart \
  -v /usr/local/bin/stalwart-cli:/usr/local/bin/stalwart-cli:ro -v /path/plan.ndjson:/plan.ndjson:ro \
  -e HOME=/tmp -e STALWART_URL=http://127.0.0.1:8081 -e STALWART_USER=… -e STALWART_PASSWORD=… \
  --entrypoint stalwart-cli stalwartlabs/stalwart@<digest> apply --file /plan.ndjson
```

(`docker exec` would work the same way if the binary were in the container, but it is not.)
The smoke applies its overlay this way (`admin_cli_netns`), and a re-apply of the full plan
through it gave `18 updated, 0 created`.

Human access to the admin UI over the tailnet listener needs the operator's tailnet address
(or `100.64.0.0/10`) in `allowedIps` as well. That only works if the tailnet connection reaches
the container with its source address intact (iptables DNAT, not docker-proxy); there is no
tailnet in the lab, so it was not verified. Also not tested: the OAuth sign-in form
(`/api/auth`). The credential check is the same one, but sign-in was only exercised with basic
auth and IMAP.

### Re-applying an Account upsert (Task 3)

An `upsert` of an `Account` replaces its entire `credentials` list with the plan's. Proved
twice: an app password created by `jason@rustd.xyz` through `x:AppPassword/set` answered 200 on
`/jmap/session` before a re-apply of the unchanged plan and 401 after it. The admin's app
password and API key also disappeared from `credentials`. The plan's Password keeps working
(re-set to the same secret). So with this plan shape, **every Ansible run deletes every app
password and API key on every account**. If users are to keep app passwords, Task 3 must not
send `credentials` on re-runs (for example, set the password only when creating the account,
or patch just the Password entry with an `update`). Neither alternative was tested here.

### Certificate reload (Task 5)

Replacing `mail.jasonernst.com.crt`/`.key` in place under the read-only mount is **not**
picked up: 993 and 465 kept serving the old certificate for 120 s. `stalwart-cli create
Action/ReloadTlsCertificates` switched both listeners (SNI and no-SNI) to the new cert
within one second. A container restart also re-reads the files. So renewal needs a host-side
trigger that runs that action (or restarts the container).

### Spam: Junk and reject (Task 2)

- With `scoreReject` above 0, a message at or above it gets `550 5.7.1 Message rejected due to
  excessive spam score.` at DATA. Between `scoreSpam` and `scoreReject` it is delivered to the
  `\Junk` folder with `X-Spam-Status: Yes` and `X-Spam-Score: spam, score=…`.
- **GTUBE is matched on the Subject**, exactly:
  `XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X`. In the body it does
  nothing. The `GTUBE_TEST` tag scores 1000, so it hits any reject threshold.
- **Stock rules download on the first normal start, and only when no `SpamRule` exists.**
  A plan that ships its own `SpamRule` before that start gets *no* stock rules (every tag
  scored 0, GTUBE was accepted). If one is needed, add it after the first start, or run
  `stalwart-cli create Task/SpamFilterMaintenance --field maintenanceType=updateRules`
  (re-downloads the rules and keeps custom ones), then `ReloadSettings`. The default
  `spamFilterRulesUrl` follows `stalwartlabs/spam-filter` `releases/latest`.
- **Mid-score method for the production acceptance test**: a marker rule plus tag, applied
  after first start, then `ReloadSettings`:
  ```
  {"@type":"upsert","object":"SpamRule","matchOn":["name"],"value":{"r-junk-probe":{"@type":"Any","name":"IAC_JUNK_PROBE","priority":5000,"condition":{"match":{"0":{"if":"contains(subject, 'iac-junk-probe')","then":"'IAC_JUNK_PROBE'"}},"else":"false"}}}}
  {"@type":"upsert","object":"SpamTag","matchOn":["tag"],"value":{"tag-junk-probe":{"@type":"Score","tag":"IAC_JUNK_PROBE","score":8.0}}}
  ```
  The `subject` variable is **lowercased**: the same rule written with `'IAC-JUNK-PROBE'`
  never fired. Proved with `Action/ClassifySpam` through `x:Action/set` (the CLI's `create`
  cannot show its result): the tag added 8.0. A clean outside sender (~0 to 2) plus 8 lands
  between 5 and 15. In the lab the baseline is already ~11, so the harness uses an
  unmodified stranger message for `junk_probe` instead.
- Trusted contacts (`trustContacts`) did **not** rescue unauthenticated lab mail from a sender
  in the recipient's address book; it still went to Junk at 11.2.

### Backup and restore of the RocksDB store (Task 6)

No online snapshot action exists (`Action` and `Task/StoreMaintenance` have none). Both
methods below were tested, each restored into a fresh volume, and the restored server showed
the same INBOX/Junk messages over IMAP:

- **Logical export** (the documented path; needs a stop): `docker stop stalwart`, then
  `docker run --rm -v <data>:/var/lib/stalwart -v <etc>:/etc/stalwart:ro -v <dir>:/export
  stalwartlabs/stalwart@<digest> --config /etc/stalwart/config.json --export /export`, then
  `docker start stalwart`. About 3 s of downtime. The output is `subspace_*` files (80 MB
  here, mostly the stored webmail bundles). Restore into an empty data volume with
  `--import /export` in place of `--export`, then start normally.
- **Pause and copy**: `docker pause stalwart`, tar the data volume from a throwaway
  container, `docker unpause stalwart`. Crash-consistent; about 3.5 s for 160 MB gzipped. On
  restore the files must be owned by UID 2000.

### Mailbox import with Vandelay (Task 9)

```bash
vandelay import maildir ./maildir ./jason.vandelay
VANDELAY_PASSWORD=… vandelay export --url https://<host>/jmap/session \
  --auth-basic jason@rustd.xyz --account-name jason@rustd.xyz ./jason.vandelay
```

Run against `tests/fixtures/maildir` (INBOX read + unread, `.Sent`, `.Junk`, and one
`T`-flagged message): `.Sent` went to `Sent` and `.Junk` to `Junk`. Both matched the existing
folders, so no duplicates, because the `defaultFolders` override names them like Mailu.
`\Seen` was kept and the trashed message skipped. A second export reported `skipped=4`, so it
is safe to re-run. Two things to know:

- Pass the session URL (`…/jmap/session`). A bare base URL makes Vandelay `GET /`, which
  redirects to `/account`, which is 403 on the public listener.
- Vandelay follows the session's `apiUrl`, so the server's `STALWART_PUBLIC_URL` must be
  right for where Vandelay runs.
