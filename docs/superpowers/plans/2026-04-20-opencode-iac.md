# Opencode IaC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install opencode on every host in the `dev` inventory group via a new Ansible role, configured to use the Ollama server on `ubuntu-beast` via Tailscale.

**Architecture:** One new role (`ansible/roles/opencode/`) with two tasks (install via upstream script, then render a config template) and a new playbook (`ansible/opencode.yml`) that targets `hosts: dev`. Cross-platform (Ubuntu + macOS) without branching logic — the upstream install script handles platform detection, and `ansible_user_dir` resolves home paths correctly on both OSes. No `become:` because the role runs as the connecting user.

**Tech Stack:** Ansible, opencode's upstream install script, ansible-lint for static checks. Target hosts are the `dev` inventory group (Mac + all Ubuntu dev machines).

**Spec:** `docs/superpowers/specs/2026-04-20-opencode-iac-design.md`

**Branch:** `jason/opencode-iac` (already checked out)

---

## Pre-flight

Confirm you're on the right branch and the spec exists:

```bash
git branch --show-current   # expect: jason/opencode-iac
ls docs/superpowers/specs/2026-04-20-opencode-iac-design.md
```

All ansible work runs from the repo root `/home/jason/dev/iac`. Lint command used throughout:

```bash
ansible-lint ansible/roles/opencode ansible/opencode.yml
```

## File structure

| File | Created/Modified | Responsibility |
| --- | --- | --- |
| `ansible/roles/opencode/defaults/main.yml` | Create | Role vars (baseURL, model list, tools, permission) |
| `ansible/roles/opencode/tasks/main.yml` | Create | Install + config tasks |
| `ansible/roles/opencode/templates/opencode.json.j2` | Create | opencode.json template |
| `ansible/opencode.yml` | Create | Playbook targeting `hosts: dev` |

No existing files are modified. The plan decomposes along file boundaries — each task creates exactly one file, with the playbook last so earlier tasks can be lint-checked in isolation.

---

### Task 1: Role defaults

**Files:**
- Create: `ansible/roles/opencode/defaults/main.yml`

- [ ] **Step 1: Create the role directory structure**

```bash
mkdir -p ansible/roles/opencode/defaults ansible/roles/opencode/tasks ansible/roles/opencode/templates
```

- [ ] **Step 2: Write `ansible/roles/opencode/defaults/main.yml`**

Contents (exact):

```yaml
---
# Opencode role defaults
#
# Installs opencode (opencode.ai) via its upstream install script and
# renders an Ansible-owned opencode.json pointing at the Ollama server
# on ubuntu-beast. Runs as the connecting user — no `become` needed.

# Ollama endpoint (reachable from all dev hosts via Tailscale)
opencode_ollama_base_url: "http://ubuntu-beast:11434/v1"
opencode_ollama_provider_name: "Ollama (local)"

# Models to expose via the ollama provider. Each entry is a dict with
# `id` (the Ollama tag) and `name` (display name). Override per-host
# in inventory vars if different machines should see different models.
opencode_models:
  - id: "hf.co/bartowski/cerebras_Qwen3-Coder-REAP-25B-A3B-GGUF:Q4_K_M"
    name: "Qwen3-Coder"
  - id: "qwen2.5:14b-32k"
    name: "qwen2.5:14b-32k"

# Tools opencode is allowed to use. Dict rendered verbatim into the
# "tools" object of opencode.json.
opencode_tools:
  write: true
  bash: true

# Permission policy rendered verbatim into the "permission" object.
opencode_permission:
  edit: "allow"
```

- [ ] **Step 3: Lint**

Run: `ansible-lint ansible/roles/opencode`
Expected: Passes (0 failures) — the role has only a defaults file at this point, and it's trivial YAML.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/opencode/defaults/main.yml
git commit -m "$(cat <<'EOF'
Add opencode role defaults

Introduces the opencode role with vars for the Ollama baseURL
(ubuntu-beast over Tailscale), a default model list matching what's
currently hand-tuned on ubuntu-beast, and the tools/permission
policy that opencode.json expects.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Config template

**Files:**
- Create: `ansible/roles/opencode/templates/opencode.json.j2`

- [ ] **Step 1: Write `ansible/roles/opencode/templates/opencode.json.j2`**

Contents (exact):

```
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

- [ ] **Step 2: Render-check the template offline**

Ansible-lint doesn't parse Jinja in templates, and we don't have a built-in "render this template with defaults and validate the JSON" primitive. Use a one-liner Python+Jinja render to confirm it produces valid JSON against the role defaults:

```bash
python3 -c '
import json, yaml
from jinja2 import Environment
defaults = yaml.safe_load(open("ansible/roles/opencode/defaults/main.yml"))
tpl = open("ansible/roles/opencode/templates/opencode.json.j2").read()
env = Environment()
env.filters["to_nice_json"] = lambda v: json.dumps(v, indent=4)
rendered = env.from_string(tpl).render(**defaults)
json.loads(rendered)
print("OK: template renders valid JSON")
print(rendered)
'
```

Expected: prints `OK: template renders valid JSON` followed by a pretty-printed opencode.json with the default ollama provider, 2 models, tools, and permission. If the JSON parse fails, check comma placement in the `{% for %}` loop — a stray or missing comma after the last model entry is the usual culprit.

- [ ] **Step 3: Lint**

Run: `ansible-lint ansible/roles/opencode`
Expected: still passes (0 failures). ansible-lint doesn't fail on Jinja templates in `templates/`.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/opencode/templates/opencode.json.j2
git commit -m "$(cat <<'EOF'
Add opencode.json Jinja template

Renders opencode.json from the role's defaults: ollama provider with
a configurable baseURL, a loop over opencode_models for the models
dict, and to_nice_json for the tools/permission objects.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Install + config tasks

**Files:**
- Create: `ansible/roles/opencode/tasks/main.yml`

- [ ] **Step 1: Write `ansible/roles/opencode/tasks/main.yml`**

Contents (exact):

```yaml
---
# Opencode installation and configuration
#
# Runs as the connecting user — no `become:`. ansible_user_dir
# resolves to /home/<user> on Linux and /Users/<user> on macOS, so
# the same tasks work on every host in the `dev` group without
# platform branching.

- name: Install opencode via upstream script
  ansible.builtin.shell: |
    set -euo pipefail
    curl -fsSL https://opencode.ai/install | bash
  args:
    creates: "{{ ansible_user_dir }}/.opencode/bin/opencode"
  tags:
    - opencode
    - install

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

- [ ] **Step 2: Lint**

Run: `ansible-lint ansible/roles/opencode`

Expected output:
- `risky-shell-pipe` on the `Install opencode via upstream script` task (because `curl | bash` is a pipe). This is an intentional trade-off of using the upstream install script — document but accept. Same pattern as the NVIDIA GPG key task in the `ollama` role.
- No other new failures.

If any other failure type surfaces, stop and fix before committing.

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/opencode/tasks/main.yml
git commit -m "$(cat <<'EOF'
Add opencode install + config tasks

Three tasks: (1) run the upstream install script (idempotent via
creates:), (2) ensure ~/.config/opencode exists, (3) render
opencode.json from the template. All use ansible_user_dir so the
same role works on Linux and macOS. No become — the role runs as
the connecting user.

The upstream installer uses `curl | bash`, which triggers one
expected risky-shell-pipe lint warning (same pattern as the NVIDIA
GPG key task in the ollama role).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Playbook

**Files:**
- Create: `ansible/opencode.yml`

- [ ] **Step 1: Write `ansible/opencode.yml`**

Contents (exact):

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

- [ ] **Step 2: Lint**

Run: `ansible-lint ansible/roles/opencode ansible/opencode.yml`
Expected: 1 `risky-shell-pipe` on `tasks/main.yml` (Task 3's curl | bash), no new failures.

- [ ] **Step 3: Syntax check**

Run: `ansible-playbook -i ansible/inventory.yml ansible/opencode.yml --syntax-check`
Expected: `playbook: ansible/opencode.yml`, exit code 0, no errors.

- [ ] **Step 4: Commit**

```bash
git add ansible/opencode.yml
git commit -m "$(cat <<'EOF'
Add opencode playbook targeting dev hosts

Thin playbook wrapping the opencode role against hosts: dev.
Usage is documented in the header; prerequisites are that the
host is in the dev group, on the tailnet, and ubuntu-beast is
running ollama at port 11434.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: First-run verification on ubuntu-beast

Ubuntu-beast already has opencode installed from a prior manual install via the upstream script. The `creates:` check means the install task will skip; only the config tasks should report `changed` — and even those should be no-ops if the role defaults exactly match the on-host config. This is a low-risk first target.

**Files:** none

- [ ] **Step 1: Capture current config for reference**

```bash
ssh ubuntu-beast.local 'cat ~/.config/opencode/opencode.json' > /tmp/opencode-beast-before.json
cat /tmp/opencode-beast-before.json
```

Note what's there. Expected fields: `$schema`, `provider.ollama.{npm,name,options.baseURL,models}`, `tools`, `permission`. The `baseURL` will currently be `http://localhost:11434/v1` (pre-Ansible), and the role defaults set it to `http://ubuntu-beast:11434/v1`.

- [ ] **Step 2: First run**

```bash
ansible-playbook -i ansible/inventory.yml ansible/opencode.yml --limit ubuntu-beast.local --ask-become-pass
```

Expected:
- `Install opencode via upstream script` → **skipped** (creates: path exists).
- `Ensure opencode config directory exists` → **ok** (directory already exists).
- `Render opencode.json` → **changed** (baseURL flips from `localhost` to `ubuntu-beast`, and any other hand-tuned differences get overwritten).

- [ ] **Step 3: Confirm the rendered config**

```bash
ssh ubuntu-beast.local 'cat ~/.config/opencode/opencode.json'
```

Expected: matches the role defaults — `baseURL: "http://ubuntu-beast:11434/v1"`, the two default models, tools `{ write: true, bash: true }`, permission `{ edit: "allow" }`, and valid JSON.

- [ ] **Step 4: Second run — idempotence check**

```bash
ansible-playbook -i ansible/inventory.yml ansible/opencode.yml --limit ubuntu-beast.local --ask-become-pass
```

Expected `PLAY RECAP`: `changed=0`. Config is already what Ansible would write, so template reports `ok`.

- [ ] **Step 5: Functional check**

```bash
ssh ubuntu-beast.local 'opencode --version'
ssh ubuntu-beast.local 'curl -s http://ubuntu-beast:11434/api/tags | head -c 100'
```

Expected: opencode version prints; the curl returns JSON starting with `{"models":[...`. Both prove the endpoint referenced in opencode.json is actually reachable from that host.

---

### Task 6: Rollout to remaining dev hosts + PR

**Files:** none (operational only)

- [ ] **Step 1: Push branch**

```bash
git push -u origin jason/opencode-iac
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "Add opencode role for dev hosts" --body "$(cat <<'EOF'
## Summary
- New `ansible/roles/opencode/` installs opencode (opencode.ai) via the upstream install script and renders an Ansible-owned `~/.config/opencode/opencode.json` pointing at the Ollama server on `ubuntu-beast` over Tailscale
- New `ansible/opencode.yml` playbook targeting `hosts: dev`
- Works cross-platform (Ubuntu + macOS) without branching — `ansible_user_dir` resolves the home path correctly on both OSes, and the role runs as the connecting user (no `become:`)
- Opencode self-updates on startup, so the role only bootstraps the initial install; `creates:` makes re-runs no-ops

## Test plan
- [x] `ansible-lint` passes (one intentional `risky-shell-pipe` on the install task; same pattern as the NVIDIA GPG key task in the ollama role)
- [x] `ansible-playbook --syntax-check` passes
- [x] Offline Python+Jinja render of `opencode.json.j2` against role defaults produces valid JSON
- [x] First run against `ubuntu-beast.local` completes; install task skips (creates:), config template renders with new `ubuntu-beast` baseURL
- [x] Second run against `ubuntu-beast.local` reports `changed=0` (idempotent)
- [x] `opencode --version` works on ubuntu-beast post-run
- [ ] First runs against remaining dev hosts (Mac + other Ubuntu boxes) are deferred — they'll install fresh

Spec: `docs/superpowers/specs/2026-04-20-opencode-iac-design.md`
Plan: `docs/superpowers/plans/2026-04-20-opencode-iac.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. Note it.

- [ ] **Step 3: (Optional) Roll out to other dev hosts**

Only do this if the user wants full rollout today. Otherwise, merging the PR is sufficient — anyone can run the playbook against any dev host when they want.

Per host, one at a time (so we catch host-specific problems early):

```bash
ansible-playbook -i ansible/inventory.yml ansible/opencode.yml --limit <hostname> --ask-become-pass
```

Dev hosts from `ansible/inventory.yml`:
- `jasons-macbook-air.local` (macOS — validates cross-platform)
- `ubuntu-silverstone.local`
- `ubuntu-cube.local`
- `ubuntu-work-laptop.local`
- `ubuntu-asus-laptop.local`
- `ubuntu-toshiba-laptop.local`
- `ubuntu-toshiba-mini-laptop.local`

First run on each expects: install task **changed** (binary downloaded), config dir **changed** (new dir), config template **changed** (new file). Second run on each: **changed=0**.

---

## Rollback

If the role breaks something on a host:

1. `git revert` the relevant commits and re-run — this restores the previous state.
2. On the affected host, if you want to drop opencode entirely:
   ```bash
   rm -rf ~/.opencode ~/.config/opencode
   ```
3. If the `opencode.json` template overwrote a hand-tuned config you wanted to keep: this role's `template` task is not configured with `backup: true`, so no `.bak` is written. Restore from the "Capture current config for reference" snapshot in Task 5 Step 1 (if you took it) or from memory. If ongoing preservation matters more than Ansible ownership, either add `backup: true` to the template task or flip it to `force: false`.
