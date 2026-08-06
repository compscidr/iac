# rustd.xyz DNS and mail groundwork

**Status:** approved, ready for implementation
**Date:** 2026-08-05

## Problem

`rustd.xyz` is registered but parked at GoDaddy, still delegated to `ns29`/`ns30.domaincontrol.com`. It needs to join the rest of the estate: DNS managed in Terraform, web traffic pointed at the `projects` droplet, and mail served by the existing Mailu instance — the same shape as `sair.run`.

The application (`compscidr/rustd.xyz`, a Kotlin/Quarkus panel) uses passwordless magic-link login as its **only** authentication path, with `quarkus.mailer.from=noreply@rustd.xyz` already hardcoded in `application.properties`. Working outbound mail is therefore a prerequisite for the product being usable at all, not a nice-to-have.

## Scope

**In scope:** DNS zone in Terraform, mail records, Mailu domain and mailboxes, DKIM.

**Out of scope:** deploying the application. The repo has no production Dockerfile, no `src/main/docker/`, and no image-publishing workflow — its only CI job runs `./gradlew build`. Hosting the panel requires authoring a container and publish pipeline first, which is separate work with its own spec.

## Architecture

Mail and web live on different hosts, exactly as with `sair.run`:

- **Web** (`rustd.xyz`, `www.rustd.xyz`) → `projects` droplet (sfo3), which runs nginx-proxy + acme-companion.
- **Mail** (`mail.rustd.xyz`, MX target) → `www` droplet (sfo2), which runs the single Mailu instance serving every domain.

Adding a domain to `mailu_additional_domains` in the mailu role is all that is needed on the Mailu side: `mailu.env.j2` and `docker-compose.yml.j2` both derive `HOSTNAMES`, `VIRTUAL_HOST`, and `LETSENCRYPT_HOST` from that list.

## The ordering constraint

**This is the single most important part of the plan.**

The `mailu-front` container is issued **one SAN certificate covering all of its mail hostnames**, not a certificate per hostname. Verified on the live host: `mail.jasonernst.com.crt` and `mail.sair.run.crt` are byte-identical files whose SAN list is `DNS:mail.jasonernst.com, DNS:mail.sair.run`.

Because `LETSENCRYPT_HOST` is generated from `mailu_additional_domains`, adding `rustd.xyz` to that list and running the mailu role causes acme-companion to request a certificate covering all three names. If `mail.rustd.xyz` does not yet resolve to the `www` droplet, its HTTP-01 challenge fails — and since it is one certificate, **the entire issuance fails**, putting renewal of the working `mail.jasonernst.com` / `mail.sair.run` certificate at risk. The current certificate expires 2026-09-26, so there is slack rather than immediate breakage, but the rule is absolute:

> Do not run the mailu role with `rustd.xyz` present in `mailu_additional_domains` until `mail.rustd.xyz` resolves to the `www` droplet's IPv4 address.

This is also why DKIM is generated out of band (step 1) rather than by a role run: `flask mailu config-import` creates the domain, generates the key, and creates mailboxes **without** touching `docker-compose.yml` or `mailu.env`, so nothing triggers ACME. That in turn lets the Terraform DKIM record carry the real public key from the start, avoiding the placeholder-then-patch cycle that left `jasonernst.com` advertising a stale key for three months.

## Sequence

1. **1Password items.** Create `mail.rustd.xyz - jason` (field `password`) and `SMTP_USER - rustd` (field `username` = `noreply@rustd.xyz`, field `password`), both in the `Infrastructure` vault, mirroring the naming of the existing `mail.sair.run - jason` and `SMTP_USER - sair` items.
2. **Mailu domain and mailboxes, out of band.** On `www`, in `/opt/mailu`: `flask mailu config-import --update` with `dkim_key: -generate-` to create the domain and key, then `flask mailu user jason rustd.xyz <pw>` and `flask mailu user noreply rustd.xyz <pw>`. Restart `antispam` so rspamd loads the new key. No compose changes.
3. **Read the DKIM public key** from `/opt/mailu/dkim/rustd.xyz.dkim.key`.
4. **Terraform.** Add the records below, with the real DKIM value from step 3.
5. **Apply**, using `-target` on the new resources. The zone is created at DigitalOcean but inert while GoDaddy holds the delegation.
6. **Nameserver switch (manual, Jason).** Repoint `rustd.xyz` at `ns1`/`ns2`/`ns3.digitalocean.com` in the GoDaddy console. Terraform cannot do this; the DigitalOcean provider manages the zone, not the registration.
7. **Codify in Ansible** — add `rustd.xyz` to `mailu_additional_domains` with both users.
8. **After `mail.rustd.xyz` resolves**, run the mailu role so the certificate picks up the third name.

Steps 1–5 are safe in any order relative to each other. Step 8 must follow step 6.

Step 7 needs care, and "commit" is not the same as "safe". Writing `rustd.xyz` into `mailu_additional_domains` is harmless as a file change, but the moment that change is on `main` **any routine `ansible-playbook jasonernst_com.yml` run picks it up** and triggers the failed certificate issuance described above — the role does not need to be run deliberately for this to happen. So either hold the Ansible change unmerged until step 6 is done, or accept that whoever merges it owns the constraint. The safest ordering is 1–6, then 7, then 8.

## DNS records

In `terraform/projects.tf`, following the existing per-domain block style:

| Resource | Type | Name | Value |
|---|---|---|---|
| `rustd-xyz` | domain | `rustd.xyz` | — |
| `rustd-A` | A | `@` | `projects` droplet IPv4 |
| `rustd-AAAA` | AAAA | `@` | `projects` droplet IPv6 |
| `rustd-CNAME-www` | CNAME | `www` | `@` |

In a new `terraform/mail-rustd.tf`, mirroring `mail-sair.tf`:

| Type | Name | Value |
|---|---|---|
| A / AAAA | `mail` | **`www` droplet** IPv4 / IPv6 |
| MX | `@` | `mail.rustd.xyz.` priority 10 |
| TXT | `@` | `v=spf1 mx -all` |
| TXT | `_dmarc` | `v=DMARC1; p=reject; rua=mailto:jason@rustd.xyz; ruf=mailto:jason@rustd.xyz; adkim=s; aspf=s` |
| TXT | `rustd.xyz._report._dmarc` | `v=DMARC1;` |
| TXT | `dkim._domainkey` | real key from step 3 |
| CNAME | `autoconfig`, `autodiscover` | `mail.rustd.xyz.` |
| SRV | `_autodiscover._tcp` (443), `_submissions._tcp` (465), `_imaps._tcp` (993), `_pop3s._tcp` (995) | `mail.rustd.xyz.` |
| SRV | `_imap._tcp`, `_pop3._tcp`, `_submission._tcp` | `.` (disabled) |

Deliberately omitted: the `google-site-verification` TXT that the other domains carry, since there is no token for this domain yet.

## Divergence from the sair.run pattern

`sair.run` is listed in `www_redirect_domains` in `projects.yml`, which 301s the apex to `www`. **`rustd.xyz` must not get that entry.** The application's `RUSTD_AUTH_BASE_URL` defaults to `https://rustd.xyz` — the apex — and the auth flow sets a `__Host-` prefixed cookie, which is bound to an exact host and cannot survive a cross-host redirect. Redirecting the apex to `www` would break magic-link callbacks.

The apex serves the application; `www` exists only as a CNAME so the name resolves.

## Known trade-offs

- **The parking page goes away.** After the nameserver switch, `rustd.xyz` stops serving GoDaddy's parked page and serves nothing, because nginx-proxy on the `projects` droplet has no vhost for it until the app is deployed. Accepted: this is an unlaunched product and a parking page has no value.
- **Certificate lag.** Mail for `rustd.xyz` works as soon as the MX resolves, but until step 8 a mail client pointed at `mail.rustd.xyz` will see a certificate name mismatch. Using `mail.jasonernst.com` as the server name works in the interim.

## Future consideration: mail provider for production

The application's own auth-gate design warns against relying on a self-hosted, single-IP relay for production magic links — if sign-in mail is filtered as spam, users cannot log in at all. This spec does not address that: the Mailu account is the correct swappable default (Quarkus mailer config is entirely environment-driven), and it matches what `sair.run` does today.

If an ESP is introduced later, the SPF record must gain an `include:` alongside `mx`, the way `jasonernst.com` carries `include:sendgrid.net`. Changing the sending path without updating SPF would cause exactly the alignment failure this estate has already been bitten by.

## Verification

- The public key derived from `/opt/mailu/dkim/rustd.xyz.dkim.key` matches the published `dkim._domainkey.rustd.xyz` TXT record byte-for-byte.
- `rustd.xyz` NS records resolve to DigitalOcean; apex A/AAAA, MX, SPF, and DMARC all resolve from `ns1.digitalocean.com`.
- SMTP AUTH as `noreply@rustd.xyz` succeeds from off-network. Before step 8 this must be tested against `mail.jasonernst.com:465`, which has a valid certificate; testing against `mail.rustd.xyz:465` will fail TLS verification on a name mismatch until the certificate is reissued, and that failure would be a false alarm rather than a mail problem. After step 8, both hostnames work.
- A test message to an external receiver reports `dkim=pass`, `spf=pass`, `dmarc=pass`.
- **Regression check:** `mail.jasonernst.com` and `mail.sair.run` still serve, and the certificate still lists them in its SAN set.

## Rollback

Every step is reversible. Terraform records can be destroyed individually; the Mailu domain can be removed with `flask mailu config-import`; the nameserver switch can be reverted at GoDaddy. The only irreversible-ish action is the nameserver change, which propagates on TTL — but since the DigitalOcean zone is fully populated before the switch, there is no window in which the domain resolves incorrectly.
