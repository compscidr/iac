# Codify Ollama IaC on ubuntu-beast

## Context

Ollama runs on `ubuntu-beast.local` (RTX 5080, 16GB VRAM) and is reachable from
the `clawdbot` host over Tailscale at `http://ubuntu-beast:11434`. The existing
`ansible/roles/ollama/` role was previously used to deploy it (the container
`ollama/ollama:latest` and `/var/lib/ollama/docker-compose.yml` both exist), but
the installed model set and some custom-context Modelfile variants have drifted
from the role defaults. An orphan `ollama.service` systemd unit from an earlier
manual install is present but inactive.

The motivating use case: clawdbot lost Anthropic Claude Code OAuth access and
should use local Ollama instead of paid API. The clawdbot-side config lives in
the `openclaw` 1Password vault (runtime-fetched) and is out of scope for this
spec.

## Goals

1. Re-running `ansible-playbook ollama.yml --limit ubuntu-beast.local` should
   reproduce the current running state with no drift.
2. Custom Modelfile variants (extended context windows) should be reproducible
   via the role, not manual `ollama create` runs.
3. The orphan `ollama.service` systemd unit should be stopped, disabled, and
   masked so it cannot silently re-activate and shadow the Docker install.
4. The clawdbot → ollama wiring should be documented near the ollama playbook
   so the user knows where to make the 1Password change.

## Non-goals

- No changes to the `clawdbot` role, `clawdbot.json.j2`, or 1Password vault
  contents.
- No addition of `ubuntu-beast.local` to the `tailscale` inventory group; that
  group's `tailscale_check.yml` preflight is aimed at cloud hosts.
- No prescriptive recommendations about which models to keep long-term; the
  role codifies the current set and the user can prune later.

## Design

### 1. Model defaults

Update `ansible/roles/ollama/defaults/main.yml` `ollama_models` to match the
installed pullable set:

```yaml
ollama_models:
  - "qwen2.5:72b"
  - "qwen2.5:14b"
  - "qwen3-coder:30b"
  - "hf.co/bartowski/cerebras_Qwen3-Coder-REAP-25B-A3B-GGUF:Q4_K_M"
  - "hf.co/bartowski/Qwen_Qwen3.5-35B-A3B-GGUF:IQ3_XXS"
```

Remove the `ollama_models` override block from `ansible/ollama.yml` so the
playbook inherits role defaults.

### 2. Modelfile variants

Add a new defaults var to `ansible/roles/ollama/defaults/main.yml`:

```yaml
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

Add template `ansible/roles/ollama/templates/modelfile.j2`:

```
FROM {{ item.base }}
{% for key, value in item.parameters.items() %}
PARAMETER {{ key }} {{ value }}
{% endfor %}
```

Add tasks to `ansible/roles/ollama/tasks/main.yml` (after the existing "Pull
Ollama models" task, tagged `ollama` + `modelfiles`):

1. List installed model tags:
   `docker exec {{ ollama_container_name }} ollama list`, register stdout,
   `changed_when: false`.
2. For each entry in `ollama_modelfiles` whose `name` does not appear as a
   substring in the registered stdout:
   - Render `modelfile.j2` to `{{ ollama_data_path }}/modelfiles/{{ item.name |
     regex_replace('[^A-Za-z0-9]', '_') }}.Modelfile` on the host (the
     directory is bind-mounted-adjacent, but we'll read it back via `cat` into
     `docker exec`, so no `docker cp` needed).
   - Create the model with:
     `cat <path> | docker exec -i {{ ollama_container_name }} ollama create
     {{ item.name }} -f /dev/stdin`
3. The rendered Modelfiles are kept on the host under
   `{{ ollama_data_path }}/modelfiles/` as a record of current state.

Idempotent: the `ollama list` substring gate prevents recreation when the
variant already exists.

### 3. Orphan systemd cleanup

Add a task block tagged `ollama` + `cleanup`, placed after the "Check if
Docker is available" preflight and before the NVIDIA toolkit tasks:

1. `ansible.builtin.stat` on `/etc/systemd/system/ollama.service`; register.
2. When the stat result exists, use `ansible.builtin.systemd` with
   `name: ollama`, `state: stopped`, `enabled: false`, `masked: true`,
   `become: true`.

Masking is the key step: it prevents an accidental `systemctl enable` or
upstream install-script run from re-activating the unit and colliding with
the Docker container on port 11434.

### 4. Clawdbot integration doc

Update the header comment of `ansible/ollama.yml` with a "Using from clawdbot"
section:

> Ollama is reachable at `http://ubuntu-beast:11434` over Tailscale. To wire it
> into clawdbot, update the ollama provider entry in the `openclaw` 1Password
> vault (runtime-fetched by clawdbot). The OpenAI-compatible endpoint is
> `http://ubuntu-beast:11434/v1`. This is not managed by Ansible.

No code change to the clawdbot role.

## File change summary

| File | Change |
| --- | --- |
| `ansible/roles/ollama/defaults/main.yml` | Update `ollama_models`; add `ollama_modelfiles` var |
| `ansible/roles/ollama/templates/modelfile.j2` | New — Modelfile template |
| `ansible/roles/ollama/tasks/main.yml` | Add cleanup block (top) + Modelfile tasks (after pull step) |
| `ansible/ollama.yml` | Drop `ollama_models` override; update header comment with clawdbot wiring doc |

## Verification

Run on ubuntu-beast.local:

```bash
ansible-playbook -i inventory.yml ollama.yml --limit ubuntu-beast.local
```

(`--check` mode is not reliable here — `docker exec`/`command` tasks with
`changed_when: false` don't support check mode cleanly. A real run is the
verification.)

Post-run checks:

- `systemctl is-masked ollama` → `masked`
- `docker exec ollama ollama list` includes `qwen2.5:14b-16k` and `-32k`
  after first real run (existing tags should not be recreated)
- `curl -s http://ubuntu-beast:11434/api/tags` from clawdbot still works
- A second run reports 0 changed tasks (idempotence check)
