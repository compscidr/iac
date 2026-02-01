[![verify](https://github.com/compscidr/iac/actions/workflows/verify.yml/badge.svg)](https://github.com/compscidr/iac/actions/workflows/verify.yml)
[![ansible lint rules](https://img.shields.io/badge/Ansible--lint-rules%20table-blue.svg)](https://ansible.readthedocs.io/projects/lint/rules/)

# Infrastructure as Code

Goals:
1. Friction-less recovery after fresh OS install for local devices
2. Easy cloud resource provisioning with Terraform
3. Minimal secret management via 1Password

## Quick Start

### Server Provisioning
```bash
# 1. Create infrastructure (Tailscale auto-installs via cloud-init)
cd terraform
./tf apply

# 2. Wait for droplet to appear on Tailscale

# 3. Bootstrap server (via Tailscale SSH)
cd ../ansible
ansible-playbook -i inventory.yml bootstrap.yml --limit <hostname> -u root
```

### Workstation Setup
```bash
cd ansible
op-personal  # Sign into 1Password
ansible-playbook -i inventory.yml common.yml --limit <hostname> --ask-become-pass
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     1Password                            │
│  (SSH keys, passwords, Tailscale authkey, API tokens)   │
└─────────────────────────────────────────────────────────┘
                          │
          ┌───────────────┴───────────────┐
          ▼                               ▼
┌─────────────────────┐       ┌─────────────────────┐
│     Terraform       │       │      Ansible        │
│  (cloud resources)  │       │   (configuration)   │
├─────────────────────┤       ├─────────────────────┤
│ • Droplets          │       │ • bootstrap (all)   │
│ • DNS records       │       │ • common_cli        │
│ • Firewalls         │       │ • dev / dev_gui     │
│ • VPCs              │       │ • media_server      │
│ • Cloud-init        │       │ • projects          │
│   (Tailscale)       │       │ • jasonernst_com    │
└─────────────────────┘       └─────────────────────┘
```

## Opinionated Stuff
- I hate snaps. Wherever possible I use apt on ubuntu.
- SSH access via Tailscale SSH (no public SSH keys on servers)
- All secrets from 1Password (no hardcoded values)

## Terraform
Provisions DigitalOcean cloud resources:
- Droplets with cloud-init (Tailscale auto-setup)
- DNS records
- Firewalls
- VPCs
- Remote state in DO Spaces

[Read more](terraform/README.md)

## Ansible
Configures all machines in the fleet:
- `bootstrap` role: minimal server setup (user + Docker + SSH keys)
- `common_cli` role: full workstation setup (Tailscale + dev tools + dotfiles)

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