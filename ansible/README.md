## Prerequisites on the ansible / terraform deploy machine

- Ansible (>=3.2)
  - via ppa:ansible/ansible because default ubuntu only has 2.8 or something

- Install requirements: `ansible-galaxy install -r ansible/meta/requirements.yml`

- Install the gpg module on ansible machine:
  - `mkdir -p ~/.ansible/plugins/modules`
  - `wget -O ~/.ansible/plugins/modules/gpg.py https://raw.githubusercontent.com/brandonkal/ansible-gpg/master/gpg.py`
  - verify it is there with `ansible-doc -t module gpg`
  - todo: see if we can get this work with dependencies so we don't need to do this manually

- Ensure the `.vault_pass` file exists in the ansible directory (its on keybase):
  - https://www.digitalocean.com/community/tutorials/how-to-use-vault-to-protect-sensitive-ansible-data-on-ubuntu-16-04

## Prerequisites on the ansible target machine (for non-terraform machines)
- ssh installed and ssh access via key from deploy machine (ie: authorized keys
  contains public key of deploy machine):
```
sudo apt install ssh
ssh-import-id gh:compscidr
```
You'll probably want to test it works (and accept the ssh key) - with:
`ssh <target-host>`

## Deploying to all machines
`ansible-playbook -i inventory.yml playbook.yml --ask-become-pass`

## Deploying to just www.jasonernst.com
`ansible-playbook -i inventory.yml playbook.yml --ask-become-pass --limit www.jasonernst.com`

# Checking for problems
`ansible-playbook -i inventory.yml playbook.yml --check -vvvv`

# Linting
`ansible-lint inventory.yml playbook.yml`


Note: deploying for the first time to a machine which only has root (ie: digital ocean)
may require running with `-u root` and not `--ask-become-pass`

###### old


## Inventories:
Since we have separate inventories for different classes of hosts
(production, staging, development), we need to pass the appropriate inventory
file with `-i` when we run.

For instance to setup the development machines:
`ansible-playbook -i ansible/inventories/development/hosts.yml ansible/site.yml --ask-become-pass --vault-password-file=.vault_pass`

To setup a particular host:
`ansible-playbook -i ansible/inventories/development/hosts.yml ansible/site.yml --ask-become-pass --vault-password-file=.vault_pass --limit <host>`

### Common commands
Deploy to ubuntu-server:
`ansible-playbook -i ansible/inventories/development/hosts.yml ansible/site.yml --ask-become-pass --vault-password-file=.vault_pass --limit ubuntu-server`

Deploy to entire lan:

Deploy to www.jasonernst.com:
`ansible-playbook -i ansible/inventories/production/hosts.yml ansible/site.yml -u root --vault-password-file=.vault_pass --limit www.jasonernst.com`

## Encrypting new secrets:
Note, this will clobber the original file with an encrypted version, so make a copy first.
`ansible-vault encrypt --vault-password-file .vault_pass <file>`
