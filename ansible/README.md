## Prerequisites on the ansible / terraform deploy machine

- Ansible (>=3.2)
  - via ppa:ansible/ansible because default ubuntu only has 2.8 or something
  - ```sudo add-apt-repository ppa:ansible/ansible && sudo apt update && sudo apt install ansible ansible-lint```

- Upgrade Ubuntu 20.04 -> 22.04 Notes: https://github.com/nickjj/ansible-docker/issues/117
  ```sudo rm -rf /usr/local/lib/docker/virtualenv```

- Install requirements: `ansible-galaxy install -r meta/requirements.yml`

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

## Deploying to nas
Requires an extra `ask-pass` argument:
`ansible-playbook -i inventory.yml playbook.yml --ask-become-pass --ask-pass --limit nas.local --tags rust-weekly`

# Checking for problems
`ansible-playbook -i inventory.yml playbook.yml --check -vvvv`

# Linting
`ansible-lint inventory.yml playbook.yml`

## Encrypting new secrets:
`ansible-vault encrypt <file>`

## Decrypted encrypted secrets:
`ansible-vault decrypt <file>`

Note: deploying for the first time to a machine which only has root (ie: digital ocean)
may require running with `-u root` and not `--ask-become-pass`
