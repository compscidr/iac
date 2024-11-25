[![ansible lint](https://github.com/compscidr/iac/actions/workflows/ansible-lint.yml/badge.svg)](https://github.com/compscidr/iac/actions/workflows/ansible-lint.yml)
[![ansible lint rules](https://img.shields.io/badge/Ansible--lint-rules%20table-blue.svg)](https://ansible.readthedocs.io/projects/lint/rules/)

# Infrastructure as Code
There are several goals of this project
1. a friction-less way to get back to normal after a fresh install of an OS for
local devices, and use a common set of expectations for all devices in my fleet
2. a way to easily provision and deploy cloud resources
3. a minimal amount of secret management by encrypting secrets

## Opinionated Stuff
- I hate snaps. Wherever possible I use apt on ubuntu.

## Terraform
Used to provision cloud resources (currently on digital ocean and terraform):
- compute
- dns entries
- todo: firewall / vpc configs

[Read more](terraform/README.md)

## Ansible
Used to provision software, services and configuration to local machines and cloud resources
- apt packages for non-gui development (ie common to headless and non-headless)
- apt packages for gui only (don't install on headless setups)
- docker containers
  - nginx proxy to [www.jasonernst.com](https://www.jasonernst.com)
  - letsencrypt to [www.jasonernst.com](https://www.jasonernst.com)
  - goblog to [www.jasonernst.com](https://www.jasonernst.com)
  - prometheus and grafana locally on lp.jasonernst.com accessible via ssh tunnel
  - ombi to [ombi.jasonernst.com](https://ombi.jasonernst.com)
  - livepeer orchestrator to `lp.jasonernst.com`
  - amd lolminer, livepeer transcoder to ubuntu-server, ubuntu-desktop
  - nvidia lolminer, livepeer transcoder to ubuntu-desktop-beast
  - plex, radarr, sonarr to ubuntu-server
- /etc/hosts files
- ssh keys
- .ssh/config mapping identities to hosts and jumpboxes where necessary

- `home.jasonernst.com` pointed to ubuntu-server configured as an ssh jump box into the lan

[Read more](ansible/README.md)

## Packer
Used for a clean and consistent debian virtualbox environment to generate debian packages since most of my systems are ubuntu. Currently not needed because I can accomplish the same thing with a pre-built debian vagrant box. Would be useful if
I needed to do any additional scripted setup that can't be done with ansible.
