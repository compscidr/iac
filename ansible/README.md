# Ansible

> **📖 Dependency Management**: This project uses a dual workflow for dependency management. See [DEPENDENCIES.md](DEPENDENCIES.md) for details on installing external roles and collections for Molecule vs. standalone playbook execution.

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
- Masks wpa_supplicant@wlan0.service (temporary interface name that gets renamed)
- Configures WiFi with wpa_supplicant using credentials from 1Password

GUI systems with NetworkManager are automatically detected and skipped.

## Testing molecule locally

Molecule tests require the `OP_SERVICE_ACCOUNT_TOKEN` environment variable to be set with your personal 1Password account token (to access the "Infrastructure" vault):

```bash
export OP_SERVICE_ACCOUNT_TOKEN="your-personal-account-token"
cd ansible
python -m venv venv
. venv/bin/activate
pip install molecule molecule-docker passlib
molecule test
```