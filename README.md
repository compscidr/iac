[![ansible lint](https://github.com/compscidr/iac/actions/workflows/ansible-lint.yml/badge.svg)](https://github.com/compscidr/iac/actions/workflows/ansible-lint.yml)
[![ansible lint rules](https://img.shields.io/badge/Ansible--lint-rules%20table-blue.svg)](https://ansible-lint.readthedocs.io/en/latest/default_rules.html)
# Infrastructure as Code
There are several goals of this project
1. a friction-less way to get back to normal after a fresh install of an OS for
local devices, and use a common set of expectations for all devices in my fleet
2. a way to easily provision and deploy cloud resources
3. a minimal amount of secret management by encrypting secrets

## Prerequisites on the ansible / terraform deploy machine
- terraform 0.13.1 on the local deploy machine
- ansible (installed from apt on the local machine)

Terraform is used to deploy resources on digital ocean. Then once the resources
are deployed, ansible is used to configure them.

Most of this was created from this guide:
https://www.digitalocean.com/community/tutorials/how-to-use-terraform-with-digitalocean#step-4-%E2%80%94-using-terraform-to-create-the-nginx-server

Everything is made to work via setting two environment variables. The DO_PAT
is the digital ocean API token. The pvt_key is set to the key which should be
rolled out to the deployed resources.

- Ansible (>=3.2)
  - via ppa:ansible/ansible because default ubuntu only has 2.8 or something
- A `/etc/hosts` or `/etc/ansible/hosts` entry which maps the host from the
ansible playbooks to the IP (either locally or public)
- Install the gpg module on ansible machine:
  - `mkdir -p ~/.ansible/plugins/modules`
  - `wget -O ~/.ansible/plugins/modules/gpg.py https://raw.githubusercontent.com/brandonkal/ansible-gpg/master/gpg.py`
  - verify it is there with `ansible-doc -t module gpg`
  - todo: see if we can get this work with dependencies so we don't need to do this manually
  - install requirements: `ansible-galaxy install -r ansible/requirements.yml`
- Ensure the .vault_pass file exists (its on keybase):
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

## Terraform Commands:
To plan:
`terraform plan -var "do_token=${DO_PAT}" -var "pvt_key=$HOME/.ssh/id_rsa" -var "pub_key=$HOME/.ssh/id_rsa.pub"`

To apply:
`terraform apply -var "do_token=${DO_PAT}" -var "pvt_key=$HOME/.ssh/id_rsa" -var "pub_key=$HOME/.ssh/id_rsa.pub"`

To show state:
`terraform show terraform.tfstate`

To use ansible after on the provisioned devices:
`ansible-playbook -i inventory.yml ansible/site.yml -u root --vault-password-file=.vault_pass`

To destroy:
`terraform plan -destroy -out=terraform.tfplan \
      -var "do_token=${DO_PAT}" \
      -var "pvt_key=$HOME/.ssh/id_rsa" \
      -var "pub_key=$HOME/.ssh/id_rsa.pub"`

to make the destroy plan and `terraform apply terraform.tfplan`

## Ansible
Ansible automatically runs as part of the terraform script, but this guide
was used to update the terraform to work together:
https://www.digitalocean.com/community/tutorials/how-to-use-ansible-with-terraform-for-configuration-management

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
`ansible-playbook -i ansible/inventories/production/hosts.yml ansible/site.yml --ask-become-pass --vault-password-file=.vault_pass --limit ubuntu-server`

Deploy to entire lan:

Deploy to www.jasonernst.com:
`ansible-playbook -i ansible/inventories/production/hosts.yml ansible/site.yml -u root --vault-password-file=.vault_pass --limit www.jasonernst.com`

## Encrypting new secrets:
Note, this will clobber the original file with an encrypted version, so make a copy first.
`ansible-vault encrypt --vault-password-file .vault_pass <file>`

## Todo:
- setup local dns on lan (so we can reach devices by hostname instead of ip)
  - opendns? https://superuser.com/questions/45789/running-dns-locally-for-home-network
  - pihole? https://pi-hole.net/
- nordvpn for only torrent traffic on ubuntu-server
- Setup the docker container for the goblog with a pinned release version
- Determine if we can migrate away from the local .db file for storing posts
