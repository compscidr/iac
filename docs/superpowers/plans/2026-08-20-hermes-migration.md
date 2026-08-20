# Hermes Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the openclaw droplet + agent stack with a hermes droplet running Hermes Agent, cut over in one PR.

**Architecture:** New DO droplet (`hermes`, tailnet-only firewall, own VPC) provisioned by terraform with additive-only `hermes.jasonernst.com` DNS records; an ansible `hermes` role installs Hermes Agent, templates `~/.hermes/.env` + `config.yaml` (local ollama/exo providers, five dormant cloud key slots), and runs `hermes gateway` as a linger-enabled user systemd unit. Openclaw terraform/ansible is deleted in the same PR.

**Tech Stack:** Terraform (DigitalOcean + Tailscale providers, `./tf` op-wrapper), Ansible (community.general onepassword lookups), Hermes Agent (upstream install.sh), ollama/exo on ubuntu-beast.

**Spec:** `docs/superpowers/specs/2026-08-20-hermes-migration-design.md`

## Global Constraints

- Never touch existing resources in `jasonernst-com.tf` (`@`/www/mail/projects/TXT records, www droplet/firewall) — new records only.
- Always run terraform via the `./tf` wrapper from `terraform/` (op credential wrapper), never bare `terraform`/`tofu`.
- No Discord snowflakes (IDs) committed to this public repo — all IDs come from 1Password lookups.
- Secrets-bearing ansible tasks get `no_log: true`; secret files mode `0600`, `~/.hermes` mode `0700`.
- 1P: personal account `CZG3A4373RA2FC5W5JKFUMYILI`; agent vault is named `hermes` (renamed from `openclaw` — a pre-merge manual step; grants are by vault UUID so kai's scoped op token survives).
- Commit after every green task; commit messages end with the repo's Co-Authored-By trailer.
- Branch: `feat/hermes-migration` (already exists, spec committed on it). NEVER push to main; the user merges PRs.

---

### Task 1: Terraform — hermes droplet, VPC, firewall; delete openclaw

**Files:**
- Create: `terraform/hermes.tf`
- Delete: `terraform/openclaw.tf`
- Modify: `terraform/projects.tf` (comment on line ~35: `# openclaw.tf for rationale` → `# hermes.tf for rationale`)
- Modify: `terraform/tailscale-acl.hujson` (comment on line ~22: `// Agent (openclaw) - only Ollama + exo access on ubuntu-beast.` → `// Agent (hermes) - only Ollama + exo access on ubuntu-beast.` — the grant itself is unchanged: src `tag:agent`)

**Interfaces:**
- Produces: `digitalocean_droplet.hermes` (referenced by Task 2's DNS records), outputs `hermes_ip` / `hermes_ipv6`.

- [ ] **Step 1: Write `terraform/hermes.tf`**

```hcl
# Hermes droplet - AI agent (Hermes Agent, replaces openclaw)
# Access via Tailscale only (no public inbound ports). The
# hermes.jasonernst.com A/AAAA records in jasonernst-com.tf are
# cosmetic until any inbound rules are added here.
#
# The tailnet ACL (tailscale-acl.hujson) grants tag:agent access to
# ollama/exo on ubuntu-beast; tagging the hermes node with tag:agent
# is a one-time manual step after first boot (see the cutover runbook
# in the PR description):
#
#   ssh hermes 'sudo tailscale up --advertise-tags=tag:agent --ssh'

resource "digitalocean_vpc" "hermes-vpc" {
  name     = "hermes-vpc"
  region   = "sfo3"
  ip_range = "10.10.40.0/24"
}

resource "digitalocean_droplet" "hermes" {
  image    = "ubuntu-24-04-x64"
  name     = "hermes.jasonernst.com"
  region   = "sfo3"
  size     = "s-1vcpu-2gb" # $12/mo - plenty for Hermes Agent
  ipv6     = true
  vpc_uuid = digitalocean_vpc.hermes-vpc.id
  ssh_keys = [digitalocean_ssh_key.github.fingerprint]

  tags = ["hermes"]

  user_data = templatefile("${path.module}/cloud-init/tailscale.yml", {
    tailscale_authkey = data.onepassword_item.tailscale.credential
    hostname          = "hermes"
  })

  # Deregister from Tailscale before the droplet is destroyed so a
  # future replacement can claim the "hermes" hostname cleanly instead
  # of getting "-1" appended. Uses `tailscale ssh` because the DO
  # firewall blocks public 22 and the host authenticates SSH via
  # tailnet identity. Requires the operator running `./tf destroy` to
  # be on the tailnet with ACL ssh access to this host as root.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "tailscale ssh root@hermes -- tailscale logout"
  }

  # Don't let DO provider drift force-replace this droplet. See
  # projects.tf for the full rationale — short version:
  # public_networking regression in provider 2.84.1, user_data comment
  # edits, and image slug default changes should not silently destroy
  # a running host.
  lifecycle {
    ignore_changes = [public_networking, user_data, image]
  }
}

# Firewall - Tailscale only (no public inbound)
resource "digitalocean_firewall" "hermes" {
  name        = "hermes-fw"
  droplet_ids = [digitalocean_droplet.hermes.id]

  # No inbound rules - all access via Tailscale

  # Outbound - allow all (API calls, Tailscale, updates, etc.)
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

output "hermes_ip" {
  value = digitalocean_droplet.hermes.ipv4_address
}

output "hermes_ipv6" {
  value = digitalocean_droplet.hermes.ipv6_address
}
```

No `moved {}` blocks: different software on a new droplet, not a rename. The openclaw droplet is destroyed, not migrated.

- [ ] **Step 2: Delete `terraform/openclaw.tf`**

```bash
git rm terraform/openclaw.tf
```

- [ ] **Step 3: Apply the two comment edits** in `projects.tf` and `tailscale-acl.hujson` (see Files above; text-only changes, no resource/grant edits).

- [ ] **Step 4: Verify formatting and validity**

```bash
cd terraform && ./tf fmt -check -recursive && ./tf validate
```

Expected: fmt silent, `Success! The configuration is valid.` If validate errors that `digitalocean_droplet.hermes` is referenced elsewhere, that's Task 2 not yet done — it must NOT error at this point; nothing else references hermes yet. Any error mentioning `openclaw` means a dangling reference — grep `terraform/` for `openclaw` and fix.

- [ ] **Step 5: Commit**

```bash
git add -A terraform && git commit -m "terraform: replace openclaw droplet with hermes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Terraform — hermes.jasonernst.com DNS records (additive only)

**Files:**
- Modify: `terraform/jasonernst-com.tf` (append two resources at the end of the record block section, after `AAAA-projects` at ~line 123; touch nothing else in the file)

**Interfaces:**
- Consumes: `digitalocean_droplet.hermes` from Task 1.

- [ ] **Step 1: Append the two records**

```hcl
# hermes.jasonernst.com -> hermes droplet (see hermes.tf). Cosmetic
# for now: the hermes firewall has no public inbound rules.
resource "digitalocean_record" "A-hermes" {
  domain = digitalocean_domain.default.name
  type   = "A"
  name   = "hermes"
  value  = digitalocean_droplet.hermes.ipv4_address
}

resource "digitalocean_record" "AAAA-hermes" {
  domain = digitalocean_domain.default.name
  type   = "AAAA"
  name   = "hermes"
  value  = digitalocean_droplet.hermes.ipv6_address
}
```

- [ ] **Step 2: Verify the diff is additive-only**

```bash
git diff terraform/jasonernst-com.tf | grep '^-' | grep -v '^---'
```

Expected: empty output (no deleted lines). Then:

```bash
cd terraform && ./tf fmt -check -recursive && ./tf validate
```

Expected: valid.

- [ ] **Step 3: Commit**

```bash
git add terraform/jasonernst-com.tf && git commit -m "terraform: add hermes.jasonernst.com A/AAAA records

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Ollama role — 64K-context model tag + de-openclaw comments

Hermes requires ≥64K context from local models. The ollama role already has a modelfile mechanism for extended-context tags; add a 64K variant of the MoE general model (the "sweet spot" model per the role's own comments).

**Files:**
- Modify: `ansible/roles/ollama/defaults/main.yml`
- Modify: `ansible/roles/ollama/tasks/main.yml` (~line 285 info message)
- Modify: `ansible/ollama.yml` (header comments ~lines 25-33)

**Interfaces:**
- Produces: ollama model tag `qwen3.5:35b-a3b-64k` on ubuntu-beast (Task 4's `hermes_ollama_model` default names it).

- [ ] **Step 1: Add the 64K modelfile entry** in `defaults/main.yml`, appended to the existing `ollama_modelfiles` list (after the `qwen2.5:14b-32k` entry, same shape):

```yaml
  # 64K-context variant for Hermes Agent (hermes requires >=64K ctx
  # from local models). MoE base: 3B active params keeps it responsive
  # even with the large KV cache spilling to RAM.
  - name: "qwen3.5:35b-a3b-64k"
    base: "hf.co/bartowski/Qwen_Qwen3.5-35B-A3B-GGUF:IQ3_XXS"
    parameters:
      num_ctx: 65536
```

- [ ] **Step 2: Delete the dead `ollama_openclaw_base_url` var** in `defaults/main.yml` (lines ~51-52 — the `# OpenClaw integration` comment and the var). It is referenced nowhere; verify with:

```bash
grep -rn 'ollama_openclaw_base_url' ansible --include='*.yml' | grep -v venv
```

Expected after deletion: no output.

- [ ] **Step 3: Update the deploy-info message** in `tasks/main.yml` (~line 285): replace the `To add to OpenClaw config:` block (through the end of that message's model list) with:

```
      To use from Hermes Agent (see roles/hermes), the OpenAI-compatible
      endpoint is: http://{{ inventory_hostname }}:{{ ollama_port }}/v1
```

- [ ] **Step 4: Update `ansible/ollama.yml` header comments**: replace the clawdbot/openclaw wiring paragraph (~lines 25-33) with:

```
#   To wire it into Hermes Agent, see ansible/hermes.yml — the hermes
#   role points its ollama provider at this server's OpenAI-compatible
#   endpoint (http://ubuntu-beast:11434/v1) over Tailscale.
```

- [ ] **Step 5: Lint and commit**

```bash
cd ansible && ansible-lint roles/ollama ollama.yml
git add ansible && git commit -m "ollama: add 64K-context model tag for hermes, drop openclaw references

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Ansible — hermes role

**Files:**
- Create: `ansible/roles/hermes/defaults/main.yml`
- Create: `ansible/roles/hermes/tasks/main.yml`
- Create: `ansible/roles/hermes/handlers/main.yml`
- Create: `ansible/roles/hermes/templates/env.j2`
- Create: `ansible/roles/hermes/templates/config.yaml.j2`
- Create: `ansible/roles/hermes/templates/hermes-gateway.service.j2`

**Interfaces:**
- Consumes: `username` (from `vars/user.yml`, loaded by the playbook), ollama tag `qwen3.5:35b-a3b-64k` from Task 3.
- Produces: role `hermes` with the vars listed in defaults below — Task 5's playbook sets `hermes_workspace_repo`, `hermes_discord_bot_token`, `hermes_discord_allowed_users`, `hermes_discord_allowed_channels`, `hermes_discord_free_response_channels`.

- [ ] **Step 1: Write `defaults/main.yml`**

```yaml
---
# Hermes role defaults
#
# Hermes Agent (https://hermes-agent.nousresearch.com/, Nous Research,
# MIT) replaces openclaw. This role: installs hermes via the upstream
# installer, templates ~/.hermes/.env (secrets) and ~/.hermes/config.yaml
# (settings), clones the kai-workspace repo (persona/memory source for
# the one-time SOUL.md seed), and runs `hermes gateway` as a
# linger-enabled user systemd unit.
#
# Secrets come from the `hermes` 1Password vault (kai's scoped service
# account token can read it; the vault was renamed from `openclaw` —
# grants are by vault UUID so the token survived). See ansible/hermes.yml
# for the item/field mapping. No Discord snowflakes in this repo: user
# and channel IDs live in the 1P item.
#
# Model providers: local-only by design (ollama on ubuntu-beast primary,
# exo fallback, both over Tailscale — requires the hermes node to carry
# tag:agent, see terraform/tailscale-acl.hujson). Five dormant cloud
# rungs (Anthropic, Kimi/Moonshot, OpenAI, xAI, Gemini) activate when
# their key var is non-empty: drop the key into the 1P item, wire it in
# hermes.yml, re-run the play. Until then, if beast is off/in Windows
# and exo is stopped, hermes is up but model-less and turns fail —
# accepted per the 2026-08-20 design spec.

hermes_user: "{{ username }}"

# Upstream installer drops the binary here (verify on first deploy; if
# the installer uses a different path, override this var — every task
# and the systemd unit consume it).
hermes_bin: "/home/{{ hermes_user }}/.local/bin/hermes"

# Config/state dir. Hermes owns its state subdirs; ansible owns .env,
# config.yaml, and the workspace clone inside it.
hermes_config_dir: "/home/{{ hermes_user }}/.hermes"

# Persona/memory source repo (kai's). Initial-clone-only: hermes/kai
# may write here at runtime; ansible must never clobber it.
hermes_workspace_repo: ""
hermes_workspace_path: "{{ hermes_config_dir }}/workspace"

# Discord (all from 1P via the playbook; empty = task lines skipped).
# ALLOWED_* is hermes's fail-closed access policy: without at least one
# allowed user hermes ignores everyone.
hermes_discord_bot_token: ""
hermes_discord_allowed_users: ""            # comma-separated user IDs
hermes_discord_allowed_channels: ""         # comma-separated channel IDs
hermes_discord_free_response_channels: ""   # channels needing no @-mention

# Local model providers (OpenAI-compatible /v1 endpoints over Tailscale)
hermes_ollama_base_url: "http://ubuntu-beast.tail21090.ts.net:11434/v1"
hermes_ollama_model: "qwen3.5:35b-a3b-64k"
hermes_exo_base_url: "http://ubuntu-beast.tail21090.ts.net:52415/v1"
# exo model id as reported by its /v1/models when exo is running
hermes_exo_model: "mlx-community/Llama-3.2-3B-Instruct-8bit"

# Dormant cloud provider rungs. Empty key = not rendered into .env or
# config.yaml. Model tags are best-current-guess defaults; check the
# provider's model list when activating a rung.
hermes_anthropic_api_key: ""
hermes_anthropic_model: "claude-sonnet-5"
hermes_kimi_api_key: ""
hermes_kimi_model: "kimi-k3"
hermes_openai_api_key: ""
hermes_openai_model: "gpt-5.6"
hermes_xai_api_key: ""
hermes_xai_model: "grok-4.6"
hermes_gemini_api_key: ""
hermes_gemini_model: "gemini-3.1-pro"
```

- [ ] **Step 2: Write `templates/env.j2`**

```jinja
# {{ ansible_managed }}
# Secrets for Hermes Agent. Sourced from the `hermes` 1P vault by
# ansible/hermes.yml — edit there, not here.
DISCORD_BOT_TOKEN={{ hermes_discord_bot_token }}
DISCORD_ALLOWED_USERS={{ hermes_discord_allowed_users }}
DISCORD_ALLOWED_CHANNELS={{ hermes_discord_allowed_channels }}
DISCORD_FREE_RESPONSE_CHANNELS={{ hermes_discord_free_response_channels }}
{% if hermes_anthropic_api_key %}
ANTHROPIC_API_KEY={{ hermes_anthropic_api_key }}
{% endif %}
{% if hermes_kimi_api_key %}
KIMI_API_KEY={{ hermes_kimi_api_key }}
{% endif %}
{% if hermes_openai_api_key %}
OPENAI_API_KEY={{ hermes_openai_api_key }}
{% endif %}
{% if hermes_xai_api_key %}
XAI_API_KEY={{ hermes_xai_api_key }}
{% endif %}
{% if hermes_gemini_api_key %}
GEMINI_API_KEY={{ hermes_gemini_api_key }}
{% endif %}
```

- [ ] **Step 3: Write `templates/config.yaml.j2`**

```jinja
# {{ ansible_managed }}
# Hermes Agent settings. Ansible-owned: hermes is expected to keep its
# runtime state in other files under ~/.hermes. If a deployed hermes
# version is observed rewriting this file, switch the template task to
# `force: false` and manage settings via `hermes config set` instead.

# Primary model: ollama on ubuntu-beast over Tailscale.
model:
  default: "{{ hermes_ollama_model }}"
  provider: ollama-beast

providers:
  ollama-beast:
    api: "{{ hermes_ollama_base_url }}"
    transport: chat_completions
    default_model: "{{ hermes_ollama_model }}"
  exo-beast:
    api: "{{ hermes_exo_base_url }}"
    transport: chat_completions
    default_model: "{{ hermes_exo_model }}"

# Tried in order when the primary fails (beast off / model unloaded /
# rate-limited). Cloud rungs render only once their key is in .env.
fallback_providers:
  - provider: exo-beast
    model: "{{ hermes_exo_model }}"
{% if hermes_anthropic_api_key %}
  - provider: anthropic
    model: "{{ hermes_anthropic_model }}"
{% endif %}
{% if hermes_kimi_api_key %}
  - provider: kimi
    model: "{{ hermes_kimi_model }}"
{% endif %}
{% if hermes_openai_api_key %}
  - provider: openai
    model: "{{ hermes_openai_model }}"
{% endif %}
{% if hermes_xai_api_key %}
  - provider: xai
    model: "{{ hermes_xai_model }}"
{% endif %}
{% if hermes_gemini_api_key %}
  - provider: gemini
    model: "{{ hermes_gemini_model }}"
{% endif %}

discord:
  # Mention required in general; the #hermes-agent channel is in
  # DISCORD_FREE_RESPONSE_CHANNELS (.env) so it needs no mention —
  # parity with openclaw's requireMention: false on its channel.
  require_mention: true
  auto_thread: true

# Per-user session isolation in group channels.
group_sessions_per_user: true
```

- [ ] **Step 4: Write `templates/hermes-gateway.service.j2`**

```jinja
# {{ ansible_managed }}
[Unit]
Description=Hermes Agent gateway (Discord)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart={{ hermes_bin }} gateway
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

- [ ] **Step 5: Write `handlers/main.yml`**

```yaml
---
- name: Restart hermes-gateway
  become: true
  become_user: "{{ hermes_user }}"
  ansible.builtin.systemd_service:
    name: hermes-gateway.service
    scope: user
    state: restarted
    daemon_reload: true
```

- [ ] **Step 6: Write `tasks/main.yml`**

```yaml
---
# Hermes Agent installation and configuration. See defaults/main.yml
# for the role contract and 1Password notes.

# Upstream installer (same pattern as the claude installer the openclaw
# role used): single-user install, idempotent via `creates:`. Upgrades
# happen on-host via hermes's own updater, not by re-running this.
- name: Install hermes via upstream installer
  become: true
  become_user: "{{ hermes_user }}"
  ansible.builtin.shell: |
    set -euo pipefail
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
  args:
    creates: "{{ hermes_bin }}"
    executable: /bin/bash
  tags:
    - hermes
    - install

# Pre-create the state dir with tight permissions before dropping
# config into it, so a fresh host never has a world-readable ~/.hermes.
- name: Create hermes config directory
  become: true
  become_user: "{{ hermes_user }}"
  ansible.builtin.file:
    path: "{{ hermes_config_dir }}"
    state: directory
    mode: "0700"
  tags:
    - hermes
    - config

- name: Template hermes .env (secrets)
  become: true
  become_user: "{{ hermes_user }}"
  ansible.builtin.template:
    src: env.j2
    dest: "{{ hermes_config_dir }}/.env"
    mode: "0600"
  no_log: true
  notify: Restart hermes-gateway
  tags:
    - hermes
    - config
    - secrets

- name: Template hermes config.yaml (settings)
  become: true
  become_user: "{{ hermes_user }}"
  ansible.builtin.template:
    src: config.yaml.j2
    dest: "{{ hermes_config_dir }}/config.yaml"
    mode: "0600"
    backup: true
  notify: Restart hermes-gateway
  tags:
    - hermes
    - config

# Kai's persona/memory source. Initial-clone-only (`update: false`):
# once present it's runtime state and must never be fast-forwarded by
# ansible. The one-time SOUL.md seed from this content is a manual
# step (see cutover runbook).
- name: Clone workspace repository
  become: true
  become_user: "{{ hermes_user }}"
  ansible.builtin.git:
    repo: "{{ hermes_workspace_repo }}"
    dest: "{{ hermes_workspace_path }}"
    version: main
    accept_hostkey: true
    update: false
  when: hermes_workspace_repo | length > 0
  tags:
    - hermes
    - workspace

# Keep the user systemd manager (and the gateway) alive when nobody is
# logged in.
- name: Enable systemd linger for hermes user
  become: true
  ansible.builtin.command: loginctl enable-linger {{ hermes_user }}
  args:
    creates: "/var/lib/systemd/linger/{{ hermes_user }}"
  tags:
    - hermes
    - systemd

- name: Install hermes-gateway user systemd unit
  become: true
  become_user: "{{ hermes_user }}"
  ansible.builtin.template:
    src: hermes-gateway.service.j2
    dest: "/home/{{ hermes_user }}/.config/systemd/user/hermes-gateway.service"
    mode: "0644"
  notify: Restart hermes-gateway
  tags:
    - hermes
    - systemd

- name: Ensure user systemd dir exists
  become: true
  become_user: "{{ hermes_user }}"
  ansible.builtin.file:
    path: "/home/{{ hermes_user }}/.config/systemd/user"
    state: directory
    mode: "0755"
  tags:
    - hermes
    - systemd

- name: Enable and start hermes-gateway.service (user)
  become: true
  become_user: "{{ hermes_user }}"
  ansible.builtin.systemd_service:
    name: hermes-gateway.service
    scope: user
    enabled: true
    state: started
    daemon_reload: true
  tags:
    - hermes
    - systemd
```

NOTE ordering bug to avoid: "Ensure user systemd dir exists" must be placed BEFORE "Install hermes-gateway user systemd unit" in the file (the template task writes into that dir). Order the tasks: install → config dir → .env → config.yaml → workspace → linger → systemd dir → unit template → enable/start.

- [ ] **Step 7: Lint**

```bash
cd ansible && ansible-lint roles/hermes
```

Expected: no failures (warnings about `command` without `changed_when` are avoided above — the two `command` tasks use `creates:`).

- [ ] **Step 8: Commit**

```bash
git add ansible/roles/hermes && git commit -m "ansible: add hermes role

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Ansible — hermes playbook + inventory

**Files:**
- Create: `ansible/hermes.yml`
- Modify: `ansible/inventory.yml` (replace `openclaw:` with `hermes:` in BOTH the `ungrouped` and `tailscale` groups)

**Interfaces:**
- Consumes: role `hermes` (Task 4) and its var names exactly as defined there.

- [ ] **Step 1: Write `ansible/hermes.yml`**

```yaml
---
# Hermes playbook - AI agent deployment (replaces openclaw.yml)
#
# Targets the `hermes` host (hermes.tail21090.ts.net via MagicDNS).
#
# Prerequisites (personal 1P account ernstjason1@gmail.com):
#   1. Droplet created via Terraform (Tailscale joined via cloud-init).
#   2. Node tagged as agent (one-time, grants ollama/exo access to
#      ubuntu-beast per tailscale-acl.hujson):
#        ssh hermes 'sudo tailscale up --advertise-tags=tag:agent --ssh'
#   3. Bootstrap run: ansible-playbook bootstrap.yml --limit hermes -u root
#   4. `hermes` vault (renamed from `openclaw`; kai's scoped service
#      account token still reads it — grants are by vault UUID):
#        - `discord hermes` item:
#            credential            = bot token
#            allowed user ids      = Jason's Discord user ID
#            allowed channel ids   = #hermes-agent channel ID
#      (Snowflake IDs live in 1P on purpose — keep them out of this
#      public repo.)
#
# Cloud model rungs (all dormant): to activate Anthropic / Kimi /
# OpenAI / xAI / Gemini, add the key to the `hermes` vault, wire a
# lookup for the matching hermes_*_api_key var below, and re-run.
#
# Usage:
#   ansible-playbook -i inventory.yml hermes.yml
#
# Post-run on a fresh install (one-time): seed kai's persona —
# copy/adapt IDENTITY.md + MEMORY.md from ~/.hermes/workspace into
# ~/.hermes/SOUL.md on the host, then send a test message in
# #hermes-agent.

- name: Deploy Hermes Agent
  hosts: hermes
  vars_files:
    - vars/user.yml
  pre_tasks:
    - name: Verify Tailscale reachability to hermes host
      ansible.builtin.include_tasks: tailscale_check.yml
  vars:
    hermes_workspace_repo: "git@github.com:compscidr/kai-workspace.git"
    # Runtime secrets — `hermes` vault on the personal account (NOT the
    # Infrastructure default vault).
    hermes_discord_bot_token: >-
      {{ lookup('community.general.onepassword',
                'discord hermes',
                field='credential',
                vault='hermes',
                account_id=onepassword_account_id) }}
    hermes_discord_allowed_users: >-
      {{ lookup('community.general.onepassword',
                'discord hermes',
                field='allowed user ids',
                vault='hermes',
                account_id=onepassword_account_id) }}
    hermes_discord_allowed_channels: >-
      {{ lookup('community.general.onepassword',
                'discord hermes',
                field='allowed channel ids',
                vault='hermes',
                account_id=onepassword_account_id) }}
    # No @-mention needed in the allowed channel(s) — parity with
    # openclaw's requireMention: false.
    hermes_discord_free_response_channels: "{{ hermes_discord_allowed_channels }}"
  roles:
    - hermes
```

- [ ] **Step 2: Update `ansible/inventory.yml`** — in `ungrouped.hosts` replace the `openclaw:` line with `hermes:`; in `tailscale.hosts` replace `openclaw:` with `hermes:`. No other lines change.

- [ ] **Step 3: Syntax check + lint**

```bash
cd ansible && ansible-playbook -i inventory.yml hermes.yml --syntax-check && ansible-lint hermes.yml
```

Expected: `playbook: hermes.yml` (syntax OK), lint clean. (Lookups don't execute during syntax-check, so no 1P access is needed.)

- [ ] **Step 4: Commit**

```bash
git add ansible/hermes.yml ansible/inventory.yml && git commit -m "ansible: add hermes playbook, swap inventory openclaw -> hermes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Delete openclaw ansible + residual-reference sweep

**Files:**
- Delete: `ansible/openclaw.yml`, `ansible/roles/openclaw/` (entire dir)

**Interfaces:**
- Consumes: nothing; must run after Task 5 so the repo never lacks an agent playbook.

- [ ] **Step 1: Delete**

```bash
git rm ansible/openclaw.yml && git rm -r ansible/roles/openclaw
```

- [ ] **Step 2: Sweep for residual references** (historical docs under `docs/superpowers/` are expected and stay; the venv is noise):

```bash
grep -rni 'openclaw\|clawdbot' --exclude-dir=venv --exclude-dir=.git --exclude-dir=docs . | grep -v '^Binary'
```

Expected: NO hits outside `docs/`. Any hit (e.g. a missed comment, a workflow, a README) gets fixed in this task. In particular check `README.md` at the repo root and `terraform/README.md`.

- [ ] **Step 3: Full-repo verification**

```bash
cd ansible && ansible-lint . && cd ../terraform && ./tf fmt -check -recursive && ./tf validate
```

Expected: all clean. Molecule's converge only imports common.yml + dev.yml, so no molecule changes are needed for this migration.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "ansible: remove openclaw playbook and role

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Plan review + PR with cutover runbook

**Files:**
- None created; PR only.

- [ ] **Step 1: Run `./tf plan` and review the change set**

```bash
cd terraform && ./tf plan -no-color 2>&1 | tail -40
```

Expected plan summary: **create** `digitalocean_vpc.hermes-vpc`, `digitalocean_droplet.hermes`, `digitalocean_firewall.hermes`, `digitalocean_record.A-hermes`, `digitalocean_record.AAAA-hermes`; **destroy** `digitalocean_vpc.openclaw-vpc`, `digitalocean_droplet.openclaw`, `digitalocean_firewall.openclaw`. ZERO changes to any `www`, `mail`, `projects`, or existing `digitalocean_record.*` resources. If anything else shows as changed/destroyed, STOP — do not open the PR; report the diff to Jason.

- [ ] **Step 2: Push branch and open PR** (never merge it — Jason merges):

```bash
git push -u origin feat/hermes-migration
gh pr create --title "Replace openclaw with hermes (Hermes Agent)" --body "$(cat <<'EOF'
Replaces the openclaw droplet + agent stack with a hermes droplet
running Hermes Agent (Nous Research). Spec:
docs/superpowers/specs/2026-08-20-hermes-migration-design.md

## Terraform
- New: hermes droplet (sfo3, s-1vcpu-2gb, tailnet-only firewall,
  hermes-vpc 10.10.40.0/24), hermes.jasonernst.com A/AAAA records
  (additive only — no existing DNS records touched).
- Removed: openclaw droplet/VPC/firewall.

## Ansible
- New: hermes role + playbook (.env + config.yaml templated from 1P,
  ollama-on-beast primary, exo fallback, five dormant cloud key slots,
  user systemd unit + linger).
- Ollama role: new qwen3.5:35b-a3b-64k tag (hermes needs >=64K ctx).
- Removed: openclaw role + playbook. Inventory swapped.

## Cutover runbook (in order, after merge approval)
1. [manual, pre-apply] Discord: create "hermes" bot app, enable Server
   Members + Message Content intents, invite with bot +
   applications.commands scopes, create #hermes-agent channel.
2. [manual, pre-apply] 1P: rename vault openclaw -> hermes; add
   `discord hermes` item (credential=bot token, `allowed user ids`,
   `allowed channel ids` fields with the Discord snowflakes).
3. [manual, pre-apply] `tailscale ssh root@openclaw -- tailscale logout`
   (openclaw's destroy-time provisioner can't run once its resource
   block is deleted; skipping leaves a harmless stale node record).
4. `cd terraform && ./tf apply` — creates hermes, destroys openclaw.
5. Tag the node: `ssh hermes 'sudo tailscale up --advertise-tags=tag:agent --ssh'`
   (grants ollama/exo access on ubuntu-beast per tailscale-acl.hujson).
6. `cd ansible && ansible-playbook bootstrap.yml --limit hermes -u root`
7. Pull the new 64K model on beast (with beast booted into Ubuntu):
   `ansible-playbook -i inventory.yml ollama.yml --limit ubuntu-beast.local`
8. `ansible-playbook -i inventory.yml hermes.yml`
9. Verify config keys against the installed hermes version
   (`hermes gateway status`, journalctl --user -u hermes-gateway); the
   config.yaml provider schema was written from upstream docs and may
   need a key rename on first contact.
10. [one-time] Seed ~/.hermes/SOUL.md from ~/.hermes/workspace
    (kai-workspace IDENTITY.md/MEMORY.md).
11. Test: message in #hermes-agent (no mention needed); confirm a turn
    served by ollama-on-beast; stop ollama briefly to watch the exo
    rung fail through (exo is usually off — expect model-less errors,
    that's the accepted design).
12. 1P cleanup: retire `openclaw claude-code credentials` and
    `discord clawdbot` items.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Confirm CI (verify workflow: terraform validate/plan, ansible-lint, molecule) is green on the PR.** If terraform-plan fails in CI on the destroy provisioner or 1P reads, report the failure output; do not force anything.

---

## Self-Review Notes

- Spec coverage: droplet/VPC/firewall/moved-rationale (Task 1), DNS (Task 2), 64K model + ollama comment cleanup (Task 3), role incl. all five dormant slots with hermes's real env var names (Task 4), playbook/1P/inventory (Task 5), openclaw deletion + sweep (Task 6), runbook incl. manual Discord/1P/tag steps and destroy caveat (Task 7). Tailscale Serve from the spec is intentionally dropped: hermes has no known web UI (spec allowed "task dropped if not applicable").
- Known uncertainty, by design: `hermes_bin` install path and the `config.yaml` provider schema are verified on first deploy (runbook step 9); both are single-var/single-file fixes if upstream differs.
