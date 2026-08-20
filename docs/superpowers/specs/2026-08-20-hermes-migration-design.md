# Hermes migration design (openclaw → hermes)

Date: 2026-08-20
Status: approved pending user review

## Summary

Replace the openclaw droplet and its agent stack with a new droplet running
[Hermes Agent](https://hermes-agent.nousresearch.com/) (Nous Research, MIT).
The agent identity (kai) carries over: same 1Password vault + scoped service
account token, same mail/GitHub accounts, persona seeded from kai-workspace.
One PR creates hermes and deletes openclaw (droplet, VPC, firewall, playbook,
role, inventory entries).

Key decisions made during brainstorming:

- **Migration:** fresh droplet, cut over in the same PR (openclaw resources
  deleted in the PR that adds hermes).
- **DNS:** public `hermes.jasonernst.com` A/AAAA records — *additive only*;
  no existing `jasonernst.com` records are touched. Firewall still blocks all
  public inbound, so the records are cosmetic for now.
- **Models:** local-only. Primary = ollama on ubuntu-beast, fallback = exo
  (both over Tailscale, OpenAI-compatible `/v1` endpoints). **No claude CLI,
  no subscription proxy** — Anthropic's Feb/Apr 2026 policy prohibits routing
  third-party tools through subscription credentials, so that path is dropped.
  A var slot is left for a proper `ANTHROPIC_API_KEY` later; when beast is
  off/in Windows and exo is down, hermes is up but model-less and turns fail.
- **Discord:** new bot application ("hermes"), restricted to the
  `#hermes-agent` channel, allow-listed to Jason's user ID (hermes fails
  closed without an access policy). Free-response mode on that channel so no
  @-mention is needed (parity with openclaw's `requireMention: false`).
- **Identity:** kai moves to hermes. Reuse the existing agent 1P vault and
  scoped op service-account token (grants are by vault UUID, so an optional
  vault rename openclaw→hermes is safe). Mail/GitHub creds remain
  manual-on-host, exactly as they were under openclaw (pre-existing gap,
  out of scope).

## Terraform

`terraform/hermes.tf` (new), `terraform/openclaw.tf` (deleted):

- `digitalocean_vpc.hermes-vpc` — sfo3, `10.10.40.0/24` (new CIDR, no reuse).
- `digitalocean_droplet.hermes` — ubuntu-24-04-x64, `s-1vcpu-2gb`, sfo3,
  ipv6, display name `hermes.jasonernst.com` (PTR convention, matches the
  mail droplet), tags `["hermes"]`, cloud-init template
  `cloud-init/tailscale.yml` with `hostname = "hermes"`, same
  `lifecycle.ignore_changes = [public_networking, user_data, image]` guard,
  destroy-time `tailscale ssh root@hermes -- tailscale logout` provisioner.
- `digitalocean_firewall.hermes` — no inbound, all outbound (copy of
  openclaw's).
- Outputs: `hermes_ip`, `hermes_ipv6`.
- No `moved {}` blocks: this is a different piece of software on a new
  droplet, not a rename.
- Cosmetic: `projects.tf` comment references `openclaw.tf` for the
  tailscale-logout rationale — repoint to `hermes.tf`.

**Destroy caveat:** openclaw's destroy-time provisioner will NOT run when its
resource block is removed from config. The runbook therefore includes a manual
`tailscale ssh root@openclaw -- tailscale logout` before `./tf apply`.
If skipped: harmless stale tailnet node record until key expiry.

## DNS (`terraform/jasonernst-com.tf`, additions only)

```hcl
resource "digitalocean_record" "A-hermes"    { name = "hermes" ... value = hermes ipv4 }
resource "digitalocean_record" "AAAA-hermes" { name = "hermes" ... value = hermes ipv6 }
```

Nothing else in this file changes. `@`, `www`, mail-related, projects, and
TXT records are untouched.

## Ansible

`ansible/hermes.yml` + `ansible/roles/hermes/` (new);
`ansible/openclaw.yml` + `ansible/roles/openclaw/` (deleted);
`inventory.yml`: `openclaw` → `hermes` in `ungrouped` and `tailscale` groups.

Role tasks (mirroring the openclaw role's conventions: `creates:` guards,
tags, handlers, `no_log` on secret-bearing tasks):

1. Install Hermes via upstream installer
   (`curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`),
   guarded by `creates:` on the installed binary.
2. Create `~/.hermes` with `0700` before writing config into it.
3. Template `~/.hermes/.env` (mode `0600`, `no_log`) from 1P lookups:
   - `DISCORD_BOT_TOKEN`
   - `DISCORD_ALLOWED_USERS` (Jason's Discord user ID)
   - `DISCORD_ALLOWED_CHANNELS` (#hermes-agent channel ID)
   - `DISCORD_FREE_RESPONSE_CHANNELS` (#hermes-agent channel ID)
   - (future, empty-default var) `ANTHROPIC_API_KEY`
   All Discord snowflakes live in the 1P item, not in this public repo.
4. Manage model settings in `~/.hermes/config.yaml`: primary model = custom
   OpenAI-compatible endpoint at
   `http://ubuntu-beast.tail21090.ts.net:11434/v1` (ollama);
   `fallback_providers:` → exo at
   `http://ubuntu-beast.tail21090.ts.net:52415/v1`.
   Exact YAML schema (and whether `hermes config set` is preferable to
   templating) is confirmed at implementation time against the installed
   version. Model tags are role vars with defaults matching what beast
   serves.
5. Clone `kai-workspace` (initial-clone-only, `update: false`) so kai's
   IDENTITY/MEMORY content is on-host for the SOUL.md seed.
6. `loginctl enable-linger`; Ansible-managed **user** systemd unit
   `hermes-gateway.service` running `hermes gateway`, enabled + started;
   config changes notify a restart handler.
7. Tailscale Serve fronting hermes's web UI **if it has one** — verified at
   implementation time; task dropped if not applicable.
8. Cosmetic cleanups: `ollama.yml` / `roles/ollama` comments and info
   messages that say "OpenClaw" get updated to name hermes.

Vars sourced from 1P in `hermes.yml` (vault name is a playbook var so the
optional openclaw→hermes vault rename is a one-line change):

- `discord hermes` item: `credential` = bot token, plus fields for guild ID,
  Jason's user ID, and the #hermes-agent channel ID.

Dropped relative to openclaw (deliberately): claude binary install, Claude
credential restore + R-1 pre-destroy sync ritual, claude-max-api-proxy,
Brave web search wiring (revisit if hermes's web tooling wants a key later),
fnm/node (nothing in this stack needs node anymore).

## Manual steps (Jason, pre-merge)

1. Create Discord application/bot "hermes"; enable Server Members Intent and
   Message Content Intent; invite with `bot` + `applications.commands`.
2. Create `discord hermes` item in the agent 1P vault (token, guild ID, user
   ID, channel ID). Optionally rename the vault openclaw→hermes.
3. (Post-provision, one-time) Seed `~/.hermes/SOUL.md` from kai-workspace's
   IDENTITY.md/MEMORY.md — a content task, not IaC.

## Cutover runbook (PR description)

1. Manual steps above.
2. `tailscale ssh root@openclaw -- tailscale logout` (see destroy caveat).
3. `./tf apply` — creates hermes droplet/VPC/firewall + DNS records,
   destroys openclaw's.
4. `ansible-playbook bootstrap.yml --limit hermes -u root`.
5. `ansible-playbook -i inventory.yml hermes.yml`.
6. Seed SOUL.md; send a test message in #hermes-agent; verify a turn served
   by ollama-on-beast, and fallback behavior with beast down.
7. Clean up 1P: remove/retire `openclaw claude-code credentials` and the
   `discord clawdbot` item once hermes is verified.

## Open items / risks

- **64K context requirement:** Hermes docs state local models need ≥64K
  context. Beast currently serves `qwen2.5:14b-32k`. Implementation will
  verify and, if needed, add a 64K-context model tag on beast (ollama role
  var) before hermes goes live.
- **Availability:** with no cloud provider configured, hermes is model-less
  whenever beast is off/in Windows and exo is stopped. Accepted; the
  `ANTHROPIC_API_KEY` slot is the future fix.
- **Hermes config surface:** `.env`/`config.yaml` keys above are from current
  upstream docs; exact keys re-verified against the installed version during
  implementation.

## Out of scope

- Any change to www/mail/projects droplets, their firewalls, or existing DNS
  records.
- ubuntu-cube ollama (exo already covers the dual-GPU split).
- Work Claude Max subscription.
- Automating kai's mail/GitHub credential deployment (pre-existing gap).
