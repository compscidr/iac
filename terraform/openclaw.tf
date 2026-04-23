# Openclaw droplet - AI assistant
# Access via Tailscale only (no public ports)
#
# Renamed from clawdbot to openclaw in 2026-04. The DO droplet, VPC,
# and firewall resources keep their state across the rename via the
# moved {} blocks below; no destroy/recreate. Tailscale hostname and
# on-host hostname still need a one-time manual reconciliation:
#
#   ssh clawdbot 'sudo tailscale set --hostname=openclaw && \
#                 sudo hostnamectl set-hostname openclaw'
#
# After that the host is reachable at openclaw.tail21090.ts.net.

resource "digitalocean_vpc" "openclaw-vpc" {
  name     = "openclaw-vpc"
  region   = "sfo3"
  ip_range = "10.10.30.0/24"
}

resource "digitalocean_droplet" "openclaw" {
  image    = "ubuntu-24-04-x64"
  name     = "openclaw"
  region   = "sfo3"
  size     = "s-1vcpu-2gb" # $12/mo - plenty for Openclaw
  ipv6     = true
  vpc_uuid = digitalocean_vpc.openclaw-vpc.id
  ssh_keys = [digitalocean_ssh_key.github.fingerprint]

  tags = ["openclaw"]

  user_data = templatefile("${path.module}/cloud-init/tailscale.yml", {
    tailscale_authkey = data.onepassword_item.tailscale.credential
    hostname          = "openclaw"
  })

  # Don't let DO provider drift force-replace this droplet. See projects.tf
  # for the full rationale — short version: public_networking regression in
  # provider 2.84.1, user_data comment edits, and image slug default changes
  # should not silently destroy a running host.
  lifecycle {
    ignore_changes = [public_networking, user_data, image]
  }
}

# Firewall - Tailscale only (no public inbound)
resource "digitalocean_firewall" "openclaw" {
  name        = "openclaw-fw"
  droplet_ids = [digitalocean_droplet.openclaw.id]

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

# State migrations for the clawdbot -> openclaw rename. Terraform 1.1+
# treats these as in-place refactors: the droplet, VPC, and firewall
# are preserved -- only the state address changes. Safe to remove once
# `terraform apply` has recorded the new addresses.
moved {
  from = digitalocean_vpc.clawdbot-vpc
  to   = digitalocean_vpc.openclaw-vpc
}

moved {
  from = digitalocean_droplet.clawdbot
  to   = digitalocean_droplet.openclaw
}

moved {
  from = digitalocean_firewall.clawdbot
  to   = digitalocean_firewall.openclaw
}

output "openclaw_ip" {
  value = digitalocean_droplet.openclaw.ipv4_address
}

output "openclaw_ipv6" {
  value = digitalocean_droplet.openclaw.ipv6_address
}
