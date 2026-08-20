# Hermes droplet - AI agent (Hermes Agent)
# Access via Tailscale only (no public inbound ports). The
# hermes.jasonernst.com A/AAAA records in jasonernst-com.tf are
# cosmetic until any inbound rules are added here.
#
# The tailnet ACL (tailscale-acl.hujson) grants tag:agent access to
# ollama/exo on ubuntu-beast; tagging the hermes node with tag:agent
# is a one-time manual step after first boot (see the cutover runbook
# in the PR description):
#
#   ssh hermes 'sudo tailscale up --advertise-tags=tag:agent --ssh'

resource "digitalocean_vpc" "hermes-vpc" {
  name     = "hermes-vpc"
  region   = "sfo3"
  ip_range = "10.10.40.0/24"
}

resource "digitalocean_droplet" "hermes" {
  image    = "ubuntu-24-04-x64"
  name     = "hermes.jasonernst.com"
  region   = "sfo3"
  size     = "s-1vcpu-2gb" # $12/mo - plenty for Hermes Agent
  ipv6     = true
  vpc_uuid = digitalocean_vpc.hermes-vpc.id
  ssh_keys = [digitalocean_ssh_key.github.fingerprint]

  tags = ["hermes"]

  user_data = templatefile("${path.module}/cloud-init/tailscale.yml", {
    tailscale_authkey = data.onepassword_item.tailscale.credential
    hostname          = "hermes"
  })

  # Deregister from Tailscale before the droplet is destroyed so a
  # future replacement can claim the "hermes" hostname cleanly instead
  # of getting "-1" appended. Uses `tailscale ssh` because the DO
  # firewall blocks public 22 and the host authenticates SSH via
  # tailnet identity. Requires the operator running `./tf destroy` to
  # be on the tailnet with ACL ssh access to this host as root.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "tailscale ssh root@hermes -- tailscale logout"
  }

  # Don't let DO provider drift force-replace this droplet. See
  # projects.tf for the full rationale — short version:
  # public_networking regression in provider 2.84.1, user_data comment
  # edits, and image slug default changes should not silently destroy
  # a running host.
  lifecycle {
    ignore_changes = [public_networking, user_data, image]
  }
}

# Firewall - Tailscale only (no public inbound)
resource "digitalocean_firewall" "hermes" {
  name        = "hermes-fw"
  droplet_ids = [digitalocean_droplet.hermes.id]

  # No inbound rules - all access via Tailscale

  # Outbound - allow all (API calls, Tailscale, updates, etc.)
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

output "hermes_ip" {
  value = digitalocean_droplet.hermes.ipv4_address
}

output "hermes_ipv6" {
  value = digitalocean_droplet.hermes.ipv6_address
}
