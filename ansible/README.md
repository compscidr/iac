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

You can do this: `eval $(op signin)` in order to login, and enter your 1password password.

Once this is done successfully, machines will be deployed with a service account token to
their environment and they will not need this step any longer for self-deploying or to
deploy to other machines

After this, you can run any of the example commands below.

## Example commands

Run all the roles in the common playbook:
`ansible-playbook -i inventory.yml common.yml --ask-become-pass`

Run specific roles by tag in the common playbook
`ansible-playbook -i inventory.yml common.yml --ask-become-pass --tags sometag`

Run all roles in the common playbook on a specific machine:
`ansible-playbook -i inventory.yml common.yml --ask-become-pass --limit ubuntu-beast`

Run all roles in the common playbook on a specific machine that requires an ssh password:
`ansible-playbook -i inventory.yml common.yml --ask-become-pass --ask-pass --limit nas.local`

## Testing molecule locally
Inside the ansible directory:
```
python -m venv venv
. venv/bin/activate
pip install molecule molecule-docker passlib
molecule test
```