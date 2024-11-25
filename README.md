[![ansible lint](https://github.com/compscidr/iac/actions/workflows/ansible-lint.yml/badge.svg)](https://github.com/compscidr/iac/actions/workflows/ansible-lint.yml)
[![ansible lint rules](https://img.shields.io/badge/Ansible--lint-rules%20table-blue.svg)](https://ansible.readthedocs.io/projects/lint/rules/)

# Infrastructure as Code
There are several goals of this project
1. a friction-less way to get back to normal after a fresh install of an OS for
local devices, and use a common set of expectations for all devices in my fleet
2. a way to easily provision and deploy cloud resources
3. a minimal amount of secret management by using 1password

## Opinionated Stuff
- I hate snaps. Wherever possible I use apt on ubuntu.

## Terraform
Used to provision cloud resources (currently on digital ocean and aws):
- compute, dns entries
- todo: firewall / vpc configs

[Read more](terraform/README.md)

## Ansible
Used to provision software, services and configuration to all of the machines in my fleet.
[Read more](ansible/README.md)

## Vagrant
Used to run a clean base OS image in a VM (prefer this to docker since its more of a "complete" system).
Currently setup to start the VM, and uses a provisioner to deploy ansible roles. The idea
with these is to make sure that fresh installs can still provision because over time
a system accumulates little changes and can diverge signficantly from a fresh install.
[Read more](vagrant/README.md)

## Packer
Not really used right now. If I wanted to make a custom VM image to start from I could
do it here, but I've found the vagrant bento images sufficient instead.
[Read more](packer/README.md)