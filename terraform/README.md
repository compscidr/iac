# Terraform Infrastructure

Manages DigitalOcean infrastructure for jasonernst.com and related projects.

## Prerequisites

1. **1Password CLI** with desktop app integration enabled
2. **Terraform** installed
3. **DigitalOcean Spaces bucket** for remote state: `terraform-state-jasonernst`
4. **1Password items** in `Infrastructure` vault:
   - `DO Spaces` - Spaces access key (username) and secret (credential)
   - `DigitalOcean` - API token (credential)
   - `Github SSH` - SSH public key
   - `Tailscale` - Auth key (credential)
   - `System Account` - Username for server user

## Usage

Use the `./tf` wrapper script — it injects 1Password credentials automatically:

```bash
# Initialize (first time or after provider changes)
./tf init

# Preview changes
./tf plan

# Apply changes
./tf apply

# Import existing resources
./tf import digitalocean_domain.default jasonernst.com
```

## Provisioning Flow

```
1. ./tf apply
   └─ Creates droplet with cloud-init
   └─ Cloud-init installs Tailscale, joins tailnet

2. Droplet appears on your Tailscale network

3. Run Ansible bootstrap (via Tailscale SSH):
   cd ../ansible
   ansible-playbook -i inventory.yml bootstrap.yml --limit <hostname> -u root
   # Creates user, installs Docker, deploys SSH key for private repos

4. Deploy your application:
   # For projects droplet:
   ansible-playbook -i inventory.yml projects.yml
   
   # For jasonernst.com:
   ansible-playbook -i inventory.yml jasonernst_com.yml
```

## File Structure

| File | Purpose |
|------|---------|
| `provider.tf` | Providers (DO, 1Password), SSH key, Tailscale authkey |
| `jasonernst-com.tf` | Personal site droplet + domain + DNS |
| `mail.tf` | Mail server droplet + DNS + firewall |
| `projects.tf` | Toy projects droplet (ping4, ping6, dumpers, darksearch) |
| `cloud-init/tailscale.yml` | Cloud-init template for Tailscale setup |
| `tf` | Wrapper script (injects 1Password creds) |
| `.env.op` | 1Password secret references |

## Remote State

State is stored in DigitalOcean Spaces (S3-compatible):
- Bucket: `terraform-state-jasonernst`
- Key: `iac/terraform.tfstate`
- Region: `sfo3`

The `./tf` wrapper handles Spaces authentication via 1Password.

## CI/CD

GitHub Actions runs on every PR:
1. `terraform fmt -check` - Formatting
2. `terraform validate` - Configuration validation
3. `tflint` - Best practices
4. `terraform plan` - Full plan (uses 1Password service account)
