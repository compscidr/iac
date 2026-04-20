# Ollama IaC Codify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codify the currently-running Ollama install on `ubuntu-beast.local` so the existing `ansible/roles/ollama/` role reproduces it with no drift, including custom-context Modelfile variants, with the orphan systemd unit masked.

**Architecture:** Three role-level changes (cleanup block, model defaults, Modelfile variant support) plus a documentation update in the playbook header. No new files outside the ollama role. Clawdbot → ollama integration is an out-of-band edit to `~/.clawdbot/clawdbot.json` on the clawdbot host (populated by the clawdbot wizard), documented but not automated. The `openclaw` 1Password vault holds API keys that clawdbot reads at runtime, not provider config.

**Tech Stack:** Ansible, `community.docker.docker_compose_v2`, Ollama (Docker deploy at `ollama/ollama:latest`), ansible-lint for static checks. Role target: `ubuntu-beast.local` (RTX 5080, 16GB VRAM, Tailscale-connected).

**Spec:** `docs/superpowers/specs/2026-04-20-ollama-iac-codify-design.md`

**Branch:** `jason/codify-ollama-iac` (already checked out)

---

## Pre-flight

Confirm you're on the right branch and the design doc exists:

```bash
git branch --show-current   # expect: jason/codify-ollama-iac
ls docs/superpowers/specs/2026-04-20-ollama-iac-codify-design.md
```

All ansible work runs from repo root. Lint command used throughout:

```bash
ansible-lint ansible/roles/ollama ansible/ollama.yml
```

Playbook command used for runs against the target:

```bash
ansible-playbook -i ansible/inventory.yml ansible/ollama.yml --limit ubuntu-beast.local
```

---

### Task 1: Mask orphan systemd `ollama.service`

Add a cleanup block to the role that stops, disables, and masks `/etc/systemd/system/ollama.service` when present. Prevents silent re-activation if someone re-runs the upstream curl-install script.

**Files:**
- Modify: `ansible/roles/ollama/tasks/main.yml` (insert block between the existing "Check if Docker is available" preflight and the NVIDIA toolkit section)

- [ ] **Step 1: Add the cleanup block**

Open `ansible/roles/ollama/tasks/main.yml`. Find the "Check if Docker is available" task (the first task in the file). Insert the following block immediately after it, before the "# Install NVIDIA Container Toolkit for GPU support" comment.

Note: systemd refuses to mask a unit when a real file exists at its path (`File ... already exists`). The block below removes the orphan unit file first, then masks (which creates a `/dev/null` symlink at that path). An `islnk` guard keeps it idempotent — a masked unit's path is a symlink, so subsequent runs detect that and skip.

```yaml
# Mask any orphan systemd ollama.service from a previous manual install.
# The Docker deploy below is authoritative; an active systemd unit would
# collide on port 11434. systemd refuses to mask when a real unit file
# sits at the target path, so we stop/disable, remove the file, then mask
# (mask creates a /dev/null symlink there). islnk check keeps the block
# idempotent — once masked, subsequent runs see a symlink and skip.
- name: Stat orphan systemd ollama unit
  become: true
  ansible.builtin.stat:
    path: /etc/systemd/system/ollama.service
  register: ollama_systemd_unit
  tags:
    - ollama
    - cleanup

- name: Stop and disable orphan systemd ollama.service
  become: true
  ansible.builtin.systemd:
    name: ollama
    state: stopped
    enabled: false
  when:
    - ollama_systemd_unit.stat.exists
    - not ollama_systemd_unit.stat.islnk
  tags:
    - ollama
    - cleanup

- name: Remove orphan systemd ollama unit file
  become: true
  ansible.builtin.file:
    path: /etc/systemd/system/ollama.service
    state: absent
  when:
    - ollama_systemd_unit.stat.exists
    - not ollama_systemd_unit.stat.islnk
  tags:
    - ollama
    - cleanup

- name: Mask orphan systemd ollama.service
  become: true
  ansible.builtin.systemd:
    name: ollama
    masked: true
    daemon_reload: true
  when:
    - ollama_systemd_unit.stat.exists
    - not ollama_systemd_unit.stat.islnk
  tags:
    - ollama
    - cleanup
```

- [ ] **Step 2: Lint**

Run: `ansible-lint ansible/roles/ollama ansible/ollama.yml`
Expected: no new errors introduced (pre-existing warnings about the role are acceptable — compare before/after if uncertain).

- [ ] **Step 3: Apply the cleanup block against ubuntu-beast**

Run:
```bash
ansible-playbook -i ansible/inventory.yml ansible/ollama.yml --limit ubuntu-beast.local --tags cleanup
```
Expected: the `Mask orphan systemd ollama.service` task reports `changed` on the first run.

- [ ] **Step 4: Verify the unit is masked**

Run: `ssh ubuntu-beast.local 'systemctl is-masked ollama'`
Expected output: `masked`

Run: `ssh ubuntu-beast.local 'systemctl is-enabled ollama'`
Expected output: `masked` (systemd reports masked here too).

- [ ] **Step 5: Verify Ollama API still responds**

Run: `curl -s http://ubuntu-beast.local:11434/api/tags | head -c 200`
Expected: JSON beginning with `{"models":[...`

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/ollama/tasks/main.yml
git commit -m "$(cat <<'EOF'
Mask orphan systemd ollama.service in ollama role

An inactive /etc/systemd/system/ollama.service from an earlier manual
install remains on ubuntu-beast. Stop + disable + mask it so a stray
upstream install-script run cannot re-activate it and collide with the
Docker deploy on port 11434.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Align `ollama_models` defaults with installed set

Update the default model list to match what's on ubuntu-beast, and drop the override block in the playbook so it inherits the role default.

**Files:**
- Modify: `ansible/roles/ollama/defaults/main.yml`
- Modify: `ansible/ollama.yml`

- [ ] **Step 1: Update `ollama_models` in role defaults**

In `ansible/roles/ollama/defaults/main.yml`, replace the existing `ollama_models:` list block with:

```yaml
# Models to pull on deployment (empty list = none)
# Current set reflects what runs on ubuntu-beast (RTX 5080, 16GB VRAM).
# The MoE variants (*-A3B-*) are the sweet spot: large total params for
# quality, 3B active params for responsiveness.
ollama_models:
  - "qwen2.5:72b"                                                     # large, GPU + RAM offload
  - "qwen2.5:14b"                                                     # fast fallback, fits in VRAM
  - "qwen3-coder:30b"                                                 # coding, partial offload
  - "hf.co/bartowski/cerebras_Qwen3-Coder-REAP-25B-A3B-GGUF:Q4_K_M"   # MoE coder, fits in VRAM
  - "hf.co/bartowski/Qwen_Qwen3.5-35B-A3B-GGUF:IQ3_XXS"               # MoE general, fits in VRAM
```

- [ ] **Step 2: Drop the `vars:` override in the playbook**

In `ansible/ollama.yml`, remove the entire `vars:` block that overrides `ollama_models`:

Before:
```yaml
- name: Deploy Ollama LLM Server
  hosts: all
  vars_files:
    - vars/user.yml
  vars:
    # Default models for high-RAM machines (128GB+ RAM, 16GB VRAM)
    # Larger models use GPU + RAM offloading for inference
    ollama_models:
      - "qwen2.5:72b"      # ~45GB, excellent quality, partial GPU + RAM
      - "qwen2.5:14b"      # Fast fallback, fits entirely in VRAM
  roles:
    - ollama
```

After:
```yaml
- name: Deploy Ollama LLM Server
  hosts: all
  vars_files:
    - vars/user.yml
  roles:
    - ollama
```

- [ ] **Step 3: Lint**

Run: `ansible-lint ansible/roles/ollama ansible/ollama.yml`
Expected: no new errors.

- [ ] **Step 4: Apply the models-only subset to ubuntu-beast**

Run:
```bash
ansible-playbook -i ansible/inventory.yml ansible/ollama.yml --limit ubuntu-beast.local --tags models
```
Expected: the "Pull Ollama models" task runs for each of the five models; because they're already present on-disk, the `ollama pull` output should read `up to date` or similar and `changed_when: "'pulling' in model_pull.stdout"` should keep them `ok` (no `changed`). If any model is reported `changed`, inspect output — it means a new layer was fetched, which is acceptable but worth noting.

- [ ] **Step 5: Verify the installed set is unchanged**

Run: `curl -s http://ubuntu-beast.local:11434/api/tags | python3 -c 'import json,sys; [print(m["name"]) for m in json.load(sys.stdin)["models"]]' | sort`

Expected output includes all of:
```
hf.co/bartowski/Qwen_Qwen3.5-35B-A3B-GGUF:IQ3_XXS
hf.co/bartowski/cerebras_Qwen3-Coder-REAP-25B-A3B-GGUF:Q4_K_M
qwen2.5:14b
qwen2.5:14b-16k
qwen2.5:14b-32k
qwen2.5:72b
qwen3-coder:30b
```

The `-16k` and `-32k` variants are Modelfile-derived and are NOT pulled — they should still be present because this task did not touch them.

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/ollama/defaults/main.yml ansible/ollama.yml
git commit -m "$(cat <<'EOF'
Align ollama_models defaults with ubuntu-beast install

Update the role's default model list to reflect what's actually pulled
on ubuntu-beast and drop the now-redundant override in ollama.yml so
the playbook inherits role defaults.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add Modelfile variant support

Codify the extended-context Qwen variants (`qwen2.5:14b-16k` and `qwen2.5:14b-32k`) that were previously created by hand via `ollama create`. Introduce a new `ollama_modelfiles` defaults var, a `modelfile.j2` template, and idempotent creation tasks.

**Files:**
- Modify: `ansible/roles/ollama/defaults/main.yml`
- Create: `ansible/roles/ollama/templates/modelfile.j2`
- Modify: `ansible/roles/ollama/tasks/main.yml`

- [ ] **Step 1: Add `ollama_modelfiles` default**

Append to `ansible/roles/ollama/defaults/main.yml` (just before the "Tailscale access control" section):

```yaml
# Custom Modelfile variants created locally via `ollama create`.
# Each entry generates a new tag from `base` with the supplied PARAMETER
# overrides. Used to produce extended-context variants of base models.
ollama_modelfiles:
  - name: "qwen2.5:14b-16k"
    base: "qwen2.5:14b"
    parameters:
      num_ctx: 16384
  - name: "qwen2.5:14b-32k"
    base: "qwen2.5:14b"
    parameters:
      num_ctx: 32768
```

- [ ] **Step 2: Create the Modelfile template**

Create `ansible/roles/ollama/templates/modelfile.j2` with exactly this content:

```
FROM {{ item.base }}
{% for key, value in item.parameters.items() %}
PARAMETER {{ key }} {{ value }}
{% endfor %}
```

- [ ] **Step 3: Add Modelfile creation tasks**

In `ansible/roles/ollama/tasks/main.yml`, after the existing "Pull configured models" block (the `ansible.builtin.command` with `loop: "{{ ollama_models }}"`), and before the "Display connection info" task, insert:

```yaml
# Create custom Modelfile variants (e.g. extended-context tags)
- name: Ensure Modelfile staging directory exists
  become: true
  ansible.builtin.file:
    path: "{{ ollama_data_path }}/modelfiles"
    state: directory
    mode: '0755'
  when: ollama_modelfiles | length > 0
  tags:
    - ollama
    - modelfiles

- name: List installed Ollama tags
  become: true
  ansible.builtin.command:
    cmd: "docker exec {{ ollama_container_name }} ollama list"
  register: ollama_installed_tags
  changed_when: false
  when: ollama_modelfiles | length > 0
  tags:
    - ollama
    - modelfiles

- name: Render Modelfile templates
  become: true
  ansible.builtin.template:
    src: modelfile.j2
    dest: "{{ ollama_data_path }}/modelfiles/{{ item.name | regex_replace('[^A-Za-z0-9]', '_') }}.Modelfile"
    mode: '0644'
  loop: "{{ ollama_modelfiles }}"
  loop_control:
    label: "{{ item.name }}"
  when: ollama_modelfiles | length > 0
  tags:
    - ollama
    - modelfiles

- name: Create Modelfile variants when absent
  become: true
  ansible.builtin.shell: |
    cat {{ ollama_data_path }}/modelfiles/{{ item.name | regex_replace('[^A-Za-z0-9]', '_') }}.Modelfile \
      | docker exec -i {{ ollama_container_name }} ollama create {{ item.name }} -f /dev/stdin
  loop: "{{ ollama_modelfiles }}"
  loop_control:
    label: "{{ item.name }}"
  when:
    - ollama_modelfiles | length > 0
    - item.name not in ollama_installed_tags.stdout
  register: modelfile_create
  changed_when: modelfile_create.rc == 0
  tags:
    - ollama
    - modelfiles
```

- [ ] **Step 4: Lint**

Run: `ansible-lint ansible/roles/ollama ansible/ollama.yml`
Expected: no new errors.

- [ ] **Step 5: Dry-run the modelfiles tag — should be no-op because variants already exist**

Run:
```bash
ansible-playbook -i ansible/inventory.yml ansible/ollama.yml --limit ubuntu-beast.local --tags modelfiles
```
Expected:
- "Ensure Modelfile staging directory exists" → changed (new directory)
- "List installed Ollama tags" → ok (changed_when: false)
- "Render Modelfile templates" → changed (new files)
- "Create Modelfile variants when absent" → **skipped** for both entries because their names appear in `ollama_installed_tags.stdout`

If "Create Modelfile variants when absent" runs (not skipped), the existence gate is broken — inspect the `when:` clause and registered stdout.

- [ ] **Step 6: Destructive check — delete and recreate one variant**

This verifies the creation path works end-to-end. Pick the less-commonly-used variant:

```bash
ssh ubuntu-beast.local 'docker exec ollama ollama rm qwen2.5:14b-16k'
ansible-playbook -i ansible/inventory.yml ansible/ollama.yml --limit ubuntu-beast.local --tags modelfiles
ssh ubuntu-beast.local 'docker exec ollama ollama list | grep 14b-16k'
```
Expected: after the playbook run, `ollama list` shows `qwen2.5:14b-16k` again.

- [ ] **Step 7: Re-run to confirm idempotence**

Run:
```bash
ansible-playbook -i ansible/inventory.yml ansible/ollama.yml --limit ubuntu-beast.local --tags modelfiles
```
Expected: no tasks reported as `changed` (the render task will be `ok` because the file content is unchanged; the create task will be skipped).

- [ ] **Step 8: Commit**

```bash
git add ansible/roles/ollama/defaults/main.yml ansible/roles/ollama/templates/modelfile.j2 ansible/roles/ollama/tasks/main.yml
git commit -m "$(cat <<'EOF'
Support custom Ollama Modelfile variants in role

Add an ollama_modelfiles defaults list, a modelfile.j2 template, and
tasks that render Modelfiles and run 'ollama create' for any variant
not already present. Captures the qwen2.5:14b-16k/-32k extended-context
tags previously created by hand on ubuntu-beast.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Document clawdbot wiring in playbook header

Add a section to the header comment of `ansible/ollama.yml` explaining how to point clawdbot at the ollama endpoint. Provider config lives in `~/.clawdbot/clawdbot.json` on the clawdbot host (wizard-populated; the role's template is a placeholder with `force: false`). The `openclaw` 1Password vault holds API keys, not provider config.

**Files:**
- Modify: `ansible/ollama.yml`

- [ ] **Step 1: Extend the header comment**

In `ansible/ollama.yml`, replace the existing header comment block (the lines from `# Ollama LLM server deployment` down through the last `# ansible-playbook ... -e '{"ollama_models": ...}'` example) with:

```yaml
---
# Ollama LLM server deployment
#
# Deploys Ollama with GPU support for local LLM inference.
# Designed for machines with NVIDIA GPUs (e.g., ubuntu-beast with RTX 5080).
#
# Prerequisites:
#   1. Docker installed on target host
#   2. NVIDIA drivers installed (for GPU support)
#   3. Tailscale connected (for secure remote access)
#
# Usage:
#   # Deploy to ubuntu-beast:
#   ansible-playbook -i inventory.yml ollama.yml --limit ubuntu-beast.local
#
#   # Deploy without GPU (CPU only):
#   ansible-playbook -i inventory.yml ollama.yml --limit ubuntu-beast.local -e ollama_gpu_enabled=false
#
#   # With custom models:
#   ansible-playbook -i inventory.yml ollama.yml --limit ubuntu-beast.local \
#     -e '{"ollama_models": ["qwen2.5:14b", "codestral:latest"]}'
#
# Using from clawdbot:
#   Ollama is reachable at http://ubuntu-beast:11434 over Tailscale.
#   To wire it into clawdbot, add an ollama provider entry to
#   ~/.clawdbot/clawdbot.json on the clawdbot host (via the clawdbot
#   wizard or by editing the file directly). OpenAI-compatible endpoint:
#   http://ubuntu-beast:11434/v1
#   The Ansible-managed clawdbot.json template is a placeholder with
#   force: false, so it will not overwrite the wizard-populated config.
#   The `openclaw` 1Password vault holds the API keys/tokens clawdbot
#   reads at runtime — it does not hold provider config.
```

- [ ] **Step 2: Lint**

Run: `ansible-lint ansible/roles/ollama ansible/ollama.yml`
Expected: no new errors.

- [ ] **Step 3: Syntax check**

Run:
```bash
ansible-playbook -i ansible/inventory.yml ansible/ollama.yml --syntax-check
```
Expected: `playbook: ansible/ollama.yml` with no errors.

- [ ] **Step 4: Commit**

```bash
git add ansible/ollama.yml
git commit -m "$(cat <<'EOF'
Document clawdbot → ollama wiring in playbook header

Clawdbot's model provider config lives in ~/.clawdbot/clawdbot.json on
the clawdbot host, populated by the wizard on first install. The
Ansible-managed template is a placeholder (force: false). The openclaw
1Password vault holds API keys, not provider config — note this so
future wiring changes happen in the right file.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: End-to-end idempotence verification

Run the full playbook twice against ubuntu-beast. The second run must be a no-op to prove the role codifies current state correctly.

**Files:** none

- [ ] **Step 1: Full run**

Run:
```bash
ansible-playbook -i ansible/inventory.yml ansible/ollama.yml --limit ubuntu-beast.local
```
Expected: completes without errors. Some tasks may be `changed` on this first full run (e.g., the NVIDIA toolkit tasks if anything drifted) — that's OK for the first run.

- [ ] **Step 2: Second full run — idempotence check**

Run the same command again immediately:
```bash
ansible-playbook -i ansible/inventory.yml ansible/ollama.yml --limit ubuntu-beast.local
```
Expected `PLAY RECAP`:
```
ubuntu-beast.local : ok=N changed=0 unreachable=0 failed=0 ...
```

If `changed` is non-zero on the second run, find the task and determine whether its `changed_when` is wrong or whether the task is genuinely non-idempotent. Common culprits:
- The `ansible.builtin.command` calling `ollama pull` — `changed_when: "'pulling' in model_pull.stdout"` should flip to `ok` on the second run.
- The `ansible.builtin.command` calling `nvidia-ctk runtime configure` — already has `changed_when: false`.

Fix and re-verify before continuing.

- [ ] **Step 3: Functional checks from clawdbot**

Run from clawdbot (or SSH to it):
```bash
ssh clawdbot 'curl -s http://ubuntu-beast:11434/api/tags | head -c 200'
ssh clawdbot 'curl -s http://ubuntu-beast:11434/api/generate -d "{\"model\":\"qwen2.5:14b\",\"prompt\":\"hi\",\"stream\":false}" | head -c 200'
```
Expected: JSON response in both cases, same as pre-change behavior.

- [ ] **Step 4: Confirm orphan unit state**

```bash
ssh ubuntu-beast.local 'systemctl is-masked ollama'
```
Expected: `masked`

- [ ] **Step 5: Push branch and open PR**

```bash
git push -u origin jason/codify-ollama-iac
gh pr create --title "Codify Ollama IaC on ubuntu-beast" --body "$(cat <<'EOF'
## Summary
- Align `ollama_models` defaults with what's installed on ubuntu-beast; drop the redundant override in `ollama.yml`
- Add `ollama_modelfiles` support (defaults var + `modelfile.j2` template + idempotent create tasks) to capture the `qwen2.5:14b-16k/-32k` extended-context variants
- Mask the orphan `/etc/systemd/system/ollama.service` from a previous manual install so it cannot shadow the Docker deploy
- Document the clawdbot → ollama wiring (edit `~/.clawdbot/clawdbot.json` on the clawdbot host) in the playbook header

## Test plan
- [x] `ansible-lint` clean
- [x] First full run against ubuntu-beast.local completes without error
- [x] Second full run reports `changed=0` (idempotent)
- [x] `systemctl is-masked ollama` reports `masked`
- [x] Deleted `qwen2.5:14b-16k` and re-ran — variant was recreated from Modelfile template
- [x] `curl http://ubuntu-beast:11434/api/tags` still works from clawdbot over Tailscale

Spec: `docs/superpowers/specs/2026-04-20-ollama-iac-codify-design.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. Report the URL back.

---

## Rollback

If any task produces a broken state on ubuntu-beast:

1. `git revert` the commits on this branch (never force-push to main).
2. Re-run the playbook with the reverted code to re-apply the prior state.
3. If the orphan `ollama.service` needs to come back for some reason:
   ```bash
   ssh ubuntu-beast.local 'sudo systemctl unmask ollama'
   ```
   (The unit file on disk is untouched by mask.)
4. If a custom Modelfile variant got corrupted, recreate it manually and adjust the defaults list to match — or delete the bad tag and re-run the `modelfiles` tag.
