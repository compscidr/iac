# Clawdbot droplet - AI assistant
# Access via Tailscale only (no public ports)

resource "digitalocean_vpc" "clawdbot-vpc" {
  name     = "clawdbot-vpc"
  region   = "sfo3"
  ip_range = "10.10.30.0/24"
}

resource "digitalocean_droplet" "clawdbot" {
  image    = "ubuntu-24-04-x64"
  name     = "clawdbot"
  region   = "sfo3"
  size     = "s-1vcpu-2gb" # $12/mo - plenty for Clawdbot
  ipv6     = true
  vpc_uuid = digitalocean_vpc.clawdbot-vpc.id
  ssh_keys = [digitalocean_ssh_key.github.fingerprint]

  tags = ["clawdbot"]

  user_data = templatefile("${path.module}/cloud-init/tailscale.yml", {
    tailscale_authkey = data.onepassword_item.tailscale.credential
    hostname          = "clawdbot"
  })
}

# Firewall - Tailscale only (no public inbound)
resource "digitalocean_firewall" "clawdbot" {
  name        = "clawdbot-fw"
  droplet_ids = [digitalocean_droplet.clawdbot.id]

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

output "clawdbot_ip" {
  value = digitalocean_droplet.clawdbot.ipv4_address
}

output "clawdbot_ipv6" {
  value = digitalocean_droplet.clawdbot.ipv6_address
}
