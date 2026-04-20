# Opencode IaC Design

## Context

Opencode is a terminal-based AI coding assistant (`opencode.ai`). It's
currently installed on `ubuntu-beast.local` via the upstream install
script (`curl -fsSL https://opencode.ai/install | bash`) and configured
to talk to the local Ollama server on that same host at
`http://localhost:11434/v1`. The goal: install opencode on every host in
the `dev` inventory group and point all of them at the Ollama server on
`ubuntu-beast` over Tailscale.

On-disk layout observed on ubuntu-beast:
- Binary: `~/.opencode/bin/opencode` (single 143 MB standalone binary, not an
  npm package). Version `1.14.19` at the time of writing.
- Plugin system: `~/.opencode/package.json` + `~/.opencode/node_modules/`
  (managed by opencode itself via bun — not Ansible's concern).
- Config: `~/.config/opencode/opencode.json` — schema `https://opencode.ai/config.json`,
  no secrets (Ollama requires no API key).

## Goals

1. Any host in the `dev` inventory group runs `ansible-playbook opencode.yml`
   and ends up with opencode installed and configured to use Ollama on
   ubuntu-beast.
2. Config is fully Ansible-owned. Per-host customization happens by
   overriding role vars, not by editing `opencode.json` on-host.
3. Works on both Linux (Ubuntu) and macOS without branching logic in
   the role (the upstream install script handles platform detection).
4. Opencode self-updates on startup; the role only bootstraps the
   initial install. Re-running the role is a no-op once opencode is
   present.

## Non-goals

- No Windows support (no dev hosts run Windows).
- No version pinning in the initial cut. If one-off pinning is ever
  needed, an `opencode_version` var can be added to pass
  `OPENCODE_VERSION=x.y.z` to the install script.
- No teardown / uninstall tasks.
- No additional providers beyond Ollama in the first cut (Anthropic,
  OpenAI, etc. can be layered on later if needed).
- Opencode's own plugin system (`@opencode-ai/plugin` managed via bun
  inside `~/.opencode/`) is not managed by Ansible — opencode owns it.

## Design

### 1. Role structure

Create `ansible/roles/opencode/`:
- `defaults/main.yml` — role vars (baseURL, models, tools, permission)
- `tasks/main.yml` — install + config tasks
- `templates/opencode.json.j2` — config template

Create `ansible/opencode.yml` — new playbook targeting `hosts: dev`.

### 2. Install task

Idempotent via `creates:` — the install script is not re-run once
opencode exists on-host.

```yaml
- name: Install opencode via upstream script
  ansible.builtin.shell: |
    set -euo pipefail
    curl -fsSL https://opencode.ai/install | bash
  args:
    creates: "{{ ansible_user_dir }}/.opencode/bin/opencode"
  tags:
    - opencode
    - install
```

No `become:` — the role runs as the connecting user (the same user
who owns the eventual install). `ansible_user_dir` resolves to that
user's home directory on both Linux (`/home/jason`) and macOS
(`/Users/jason`), so the same task works for the mac-mini and all
Ubuntu dev boxes. `set -euo pipefail` at the top of the shell block
catches `curl` failures before the piped `bash` silently swallows them.

### 3. Config task

```yaml
- name: Ensure opencode config directory exists
  ansible.builtin.file:
    path: "{{ ansible_user_dir }}/.config/opencode"
    state: directory
    mode: '0755'
  tags:
    - opencode
    - config

- name: Render opencode.json
  ansible.builtin.template:
    src: opencode.json.j2
    dest: "{{ ansible_user_dir }}/.config/opencode/opencode.json"
    mode: '0644'
  tags:
    - opencode
    - config
```

No `become:` and no `force: false` — Ansible owns this file and runs
as the connecting user. Re-runs overwrite, so any hand-tuning on
ubuntu-beast will be replaced by the templated output on the next run.
Role defaults are set to match what's currently on ubuntu-beast to
minimize drift on that first apply.

### 4. Role variables (`defaults/main.yml`)

```yaml
---
# Opencode role defaults

opencode_ollama_base_url: "http://ubuntu-beast:11434/v1"
opencode_ollama_provider_name: "Ollama (local)"

# Models to expose via the ollama provider. Each entry is a dict with
# `id` (the Ollama tag) and `name` (display name). Override this list
# per-host via inventory vars if different machines should see
# different models.
opencode_models:
  - id: "hf.co/bartowski/cerebras_Qwen3-Coder-REAP-25B-A3B-GGUF:Q4_K_M"
    name: "Qwen3-Coder"
  - id: "qwen2.5:14b-32k"
    name: "qwen2.5:14b-32k"

opencode_tools:
  write: true
  bash: true

opencode_permission:
  edit: "allow"
```

### 5. Template (`templates/opencode.json.j2`)

```jinja
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "{{ opencode_ollama_provider_name }}",
      "options": {
        "baseURL": "{{ opencode_ollama_base_url }}"
      },
      "models": {
{% for m in opencode_models %}
        "{{ m.id }}": { "name": "{{ m.name }}" }{% if not loop.last %},{% endif %}
{% endfor %}
      }
    }
  },
  "tools": {{ opencode_tools | to_nice_json }},
  "permission": {{ opencode_permission | to_nice_json }}
}
```

### 6. Playbook (`ansible/opencode.yml`)

```yaml
---
# Opencode deployment - terminal AI coding assistant
#
# Installs opencode on all dev hosts and configures it to use the
# Ollama server on ubuntu-beast over Tailscale.
#
# Usage:
#   ansible-playbook -i inventory.yml opencode.yml
#   ansible-playbook -i inventory.yml opencode.yml --limit ubuntu-beast.local
#
# Prerequisites:
#   1. Host is in the `dev` inventory group
#   2. Host can reach ubuntu-beast over Tailscale (on tailnet or via
#      MagicDNS)
#   3. Ollama is running on ubuntu-beast at port 11434 (deployed via
#      ansible/ollama.yml)

- name: Deploy opencode
  hosts: dev
  vars_files:
    - vars/user.yml
  roles:
    - opencode
```

## File change summary

| File | Change |
| --- | --- |
| `ansible/opencode.yml` | New — playbook |
| `ansible/roles/opencode/defaults/main.yml` | New — role vars |
| `ansible/roles/opencode/tasks/main.yml` | New — install + config tasks |
| `ansible/roles/opencode/templates/opencode.json.j2` | New — config template |

## Verification

First run on a fresh host:

```bash
ansible-playbook -i inventory.yml opencode.yml --limit <host> --ask-become-pass
```

Expected: `Install opencode via upstream script` and both config tasks
report `changed`. Expect about a minute for the install step (downloads
~143 MB).

Second run on the same host:

```bash
ansible-playbook -i inventory.yml opencode.yml --limit <host> --ask-become-pass
```

Expected: `changed=0`. The install task is skipped (via `creates:`) and
the config template is unchanged.

Functional check:

```bash
ssh <host> 'opencode --version && curl -s http://ubuntu-beast:11434/api/tags | head -c 100'
```

Both should succeed — the first proves opencode is installed, the
second proves the Ollama endpoint is reachable from that host over
Tailscale.

## Rollback

If the role produces a broken state on a host:

1. Revert the role commit.
2. On the affected host, `rm -rf ~/.opencode ~/.config/opencode` to
   drop the installation and config — then re-run the playbook.
