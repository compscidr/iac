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

  # Deregister from Tailscale before the droplet is destroyed so the
  # replacement node can claim the "openclaw" hostname cleanly instead
  # of getting "-1" appended. Without this, Tailscale keeps the offline
  # node record until key expiry (~180 days) and collides with any
  # replacement that registers the same hostname.
  #
  # Uses `tailscale ssh` rather than the remote-exec provisioner because:
  #   1. The DO firewall blocks public port 22; SSH only works over the
  #      tailnet.
  #   2. The droplets run with `tailscale up --ssh`, which authenticates
  #      via tailnet identity, not SSH keys. Terraform's Go SSH client
  #      can't speak that; the system `tailscale ssh` binary can.
  #
  # Requires: the operator running `./tf destroy` must be signed into
  # the same tailnet with an ACL permitting `ssh` to this host as root.
  # `on_failure = continue` keeps destroy moving if the droplet is
  # already unreachable (worst case: fall back to the pre-PR behavior
  # where the offline record hangs around and the replacement gets -1).
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "tailscale ssh root@openclaw -- tailscale logout"
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
