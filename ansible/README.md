# Ansible

> **📖 Dependency Management**: This project uses a dual workflow for dependency management. See [DEPENDENCIES.md](DEPENDENCIES.md) for details on installing external roles and collections for Molecule vs. standalone playbook execution.

## Roles Overview

### Core Roles
| Role | Purpose | Used By |
|------|---------|---------|
| `bootstrap` | Minimal server setup: user + Docker + SSH keys | Servers (via Tailscale SSH) |
| `common_cli` | CLI tools, Tailscale, dotfiles, dev environment | Workstations |
| `common_gui` | GUI apps, fonts, desktop settings | GUI machines |

### Development Roles
| Role | Purpose | Used By |
|------|---------|---------|
| `dev` | Dev tools: SDKs, IDEs, languages | `dev` group |
| `dev_gui` | GUI dev tools: VS Code, Android Studio | `dev_gui` group |
| `academic_gui` | Academic tools: LaTeX, Zotero | `academic_gui` group |
| `zed` | Zed editor from the pinned GitHub release tarball | `dev_gui` (via `dev_gui`) |

### Service Roles
| Role | Purpose | Used By |
|------|---------|---------|
| `jasonernst_com` | Personal website (goblog) | www.jasonernst.com |
| `stalwart` | Stalwart mail server | mail.jasonernst.com |
| `uptime_kuma` | Uptime monitoring (uptime.jasonernst.com) | www.jasonernst.com |
| `media_server` | Plex, Sonarr, Radarr, etc. | NAS |
| `home_assistant` | Home automation | NAS |
| `dyndns` | Dynamic DNS updater | NAS, workstations |

### Game Server Roles
| Role | Purpose | Used By |
|------|---------|---------|
| `rust_game` | Rust game servers (weekly, monthly, build) | NAS, ubuntu-cube |
| `cs2_game` | Counter-Strike 2 server | NAS |
| `minecraft_game` | Minecraft Java Edition server (whitelisted) | NAS |
| `minecraft_bedrock` | Minecraft Bedrock Edition server | NAS |
| `factorio_game` | Factorio headless server (Space Age) | NAS |

### Server Provisioning Flow

```
1. Terraform creates droplet with cloud-init (installs Tailscale)
2. Droplet joins your Tailscale network
3. Run bootstrap via Tailscale SSH:
   ansible-playbook -i inventory.yml bootstrap.yml --limit <hostname> -u root
4. Deploy your application
```

### Workstation Setup

```bash
ansible-playbook -i inventory.yml common.yml --limit <hostname> --ask-become-pass
```

## Requirements / Bootstrapping Host Machine
The machine running the ansible plays requires ansible >= 3.2. 
Note, this doesn't have to be the target machine where you are deploying things to.
If you want to add it to ubuntu, for example, do the following (the ansible included in ubuntu is very old)
```sudo add-apt-repository ppa:ansible/ansible && sudo apt update && sudo apt install ansible```

## Target Machines:
The only real requirement on the target machines, is that they have SSH, are reachable
and have the authorized the key from the deploying machine.

### Ubuntu 24.04
- Install ssh and import ssh authorized key: 
```
sudo apt install ssh
ssh-import-id gh:compscidr
```

### Mac OS
- Ensure command lines tools are installed: `xcode-select --install`
- Import ssh authorized key: `pip3 install ssh-import-id`
- Add the python bin directory to your path, for example:
- `export PATH="$HOME/Library/Python/3.9/bin:$PATH"`
- Import the key: `ssh-import-id gh:compscidr`
- Disable SSH password login (edit /etc/ssh/sshd_config and set `PasswordAuthentication no`, set `KbdInteractiveAuthentication no`)
- Turn on SSH access (System Preferences -> Sharing -> Remote Login)

## Credentials / Secrets
For any plays which deploy secrets / credentials, all of these are managed by 1password.
The plays are setup to lookup the secrets using 1password cli (op). In order for this
to work, you must login to onepassword in the terminal you are doing the deploying from.

### First-time setup
On your first run, before the dotfiles are deployed, sign in manually:
```bash
eval $(op signin --account CZG3A4373RA2FC5W5JKFUMYILI)  # Personal account
```

### After dotfiles are deployed
Once the common.yml playbook has run, you'll have convenient aliases:
```bash
op-personal  # Sign into personal account (ernstjason1@gmail.com)
op-work      # Sign into work account (jason@bumpapp.xyz)
```

The session lasts 30 minutes, so you can run multiple playbooks without re-authenticating.

### 1Password rate limit (read this before adding a lookup)
1Password caps API reads per hour, and the counter is **account-wide**: one budget
shared by every play, terraform's 1Password provider (locally and in CI), and any
`op` command run by hand. A play that gets `Too many requests. Your client has been
rate-limited` also blocks `./tf apply` until the window resets, and the error never
says when that is - `op service-account ratelimit` is the only way to see it:

```bash
op service-account ratelimit   # `account read_write` is the shared counter
```

Every `lookup('community.general.onepassword', ...)` is one `op` call, and a lookup
in a play var, role default, or task `vars:` is re-run at **every reference** (each
task that uses it, each `when` that tests it, each loop that evaluates the structure
holding it), and on every host of the play. That was ~30 calls for 8 secrets in
hermes.yml and 60+ for a `common.yml` run (#542). The rules that keep it bounded:

- Read secrets **once**, at the top of the play (`pre_tasks`) or role, into facts with
  `set_fact` + `no_log: true`; never as a play var or role default holding a lookup.
  Tag the task `always` in a playbook, or with the union of its consumers' tags in a
  role, so `--tags` runs still have them.
- One call per **item**, not per field: read multi-field items with
  `community.general.onepassword_raw` and split locally with
  `community.general.json_query("fields[?label=='x' || id=='x'].value | [0]")`. Match
  on `id` as well as `label` - some items (the `SMTP_USER - *` logins) carry custom
  labels, and only the id is stable.
- A play against many hosts reads each shared item once: `run_once: true` on the
  `set_fact` broadcasts the fact to every host in the play.
- A lazy var you cannot move (a role default a playbook overrides) is resolved once by
  assigning it to itself: `set_fact: {foo: "{{ foo }}"}`.

See `hermes.yml`, `projects.yml`, and `roles/common_cli/tasks/main.yml` for the shape.

After signing in, you can run any of the example commands below. You'll still need to use
`--ask-become-pass` to provide your sudo password (typing it once per playbook run is simpler
than dealing with 1Password desktop app prompts for every secret lookup).

## Example commands

**Important:** Always sign in to 1Password first:
```bash
op-personal  # Use this for personal infrastructure
```

Run all the roles in the common playbook:
```bash
ansible-playbook -i inventory.yml common.yml --ask-become-pass
```

Run specific roles by tag in the common playbook:
```bash
ansible-playbook -i inventory.yml common.yml --tags sometag --ask-become-pass
```

Run all roles in the common playbook on a specific machine:
```bash
ansible-playbook -i inventory.yml common.yml --limit ubuntu-beast --ask-become-pass
```

Run all roles in the common playbook on a specific machine that requires an ssh password:
```bash
ansible-playbook -i inventory.yml common.yml --ask-pass --ask-become-pass --limit nas.local
```

## Networking Configuration

For Ubuntu 24.04+ headless servers, the playbook automatically:
- Configures systemd-networkd with wildcard interface matching (works with any interface names)
- Disables obsolete isc-dhcp-client (Ubuntu 24.04+ uses systemd-networkd's built-in DHCP)
- Disables systemd-networkd-wait-online to prevent boot delays
- Removes netplan and cloud-init network configurations to prevent conflicts
- Masks wpa_supplicant@wlan0.service to avoid conflicts with systemd-networkd-managed WiFi. On systems that use a temporary wlan0 name during boot, this prevents the transient wpa_supplicant unit from interfering after the interface is renamed; on systems where wlan0 is permanent, this simply disables that legacy wpa_supplicant instance.
- Configures WiFi with wpa_supplicant using credentials from 1Password

GUI systems with NetworkManager are automatically detected and skipped.

## Testing molecule locally

Molecule tests use `OP_SERVICE_ACCOUNT_TOKEN` for non-interactive authentication, while normal playbook runs use interactive `op signin` to avoid desktop app prompts. This allows automated testing while keeping interactive workflows smooth for manual use.

Set your personal 1Password account service account token:

```bash
export OP_SERVICE_ACCOUNT_TOKEN="your-personal-account-token"
cd ansible
python -m venv venv
. venv/bin/activate
pip install molecule molecule-docker passlib jmespath  # jmespath: the json_query filter that splits raw 1Password items
molecule test
```