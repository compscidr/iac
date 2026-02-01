# Projects droplet - consolidates small toy projects
# - ping4.network (https://github.com/compscidr/network-tools)
# - ping6.network (https://github.com/compscidr/network-tools)
# - dumpers.xyz (https://github.com/compscidr/network-tools)
# - darksearch.xyz (https://github.com/compscidr/darksearch.xyz)

# VPC for sfo3 region
resource "digitalocean_vpc" "sfo3-vpc" {
  name     = "projects-vpc"
  region   = "sfo3"
  ip_range = "10.10.20.0/24"
}

resource "digitalocean_droplet" "projects" {
  image    = "ubuntu-24-04-x64"
  name     = "projects"
  region   = "sfo3"
  size     = "s-1vcpu-2gb" # $12/mo - room for multiple containerized services
  ipv6     = true
  vpc_uuid = digitalocean_vpc.sfo3-vpc.id
  ssh_keys = [digitalocean_ssh_key.github.fingerprint]

  tags = ["projects"]

  user_data = templatefile("${path.module}/cloud-init/tailscale.yml", {
    tailscale_authkey = data.onepassword_item.tailscale.credential
    hostname          = "projects"
  })
}

# ============================================================================
# ping4.network
# ============================================================================
resource "digitalocean_domain" "ping4-network" {
  name = "ping4.network"
  # Note: Don't use ip_address here - it only sets A record at creation time
  # and won't update if the droplet IP changes. Use explicit records instead.
}

resource "digitalocean_record" "ping4-A" {
  domain = digitalocean_domain.ping4-network.name
  type   = "A"
  name   = "@"
  value  = digitalocean_droplet.projects.ipv4_address
}

resource "digitalocean_record" "ping4-AAAA" {
  domain = digitalocean_domain.ping4-network.name
  type   = "AAAA"
  name   = "@"
  value  = digitalocean_droplet.projects.ipv6_address
}

resource "digitalocean_record" "ping4-CNAME-www" {
  domain = digitalocean_domain.ping4-network.name
  type   = "CNAME"
  name   = "www"
  value  = "@"
}

# ============================================================================
# ping6.network
# ============================================================================
resource "digitalocean_domain" "ping6-network" {
  name = "ping6.network"
}

resource "digitalocean_record" "ping6-A" {
  domain = digitalocean_domain.ping6-network.name
  type   = "A"
  name   = "@"
  value  = digitalocean_droplet.projects.ipv4_address
}

resource "digitalocean_record" "ping6-AAAA" {
  domain = digitalocean_domain.ping6-network.name
  type   = "AAAA"
  name   = "@"
  value  = digitalocean_droplet.projects.ipv6_address
}

resource "digitalocean_record" "ping6-CNAME-www" {
  domain = digitalocean_domain.ping6-network.name
  type   = "CNAME"
  name   = "www"
  value  = "@"
}

resource "digitalocean_record" "ping6-TXT-google" {
  domain = digitalocean_domain.ping6-network.name
  type   = "TXT"
  name   = "@"
  value  = "google-site-verification=QFKakZHMJSkSTb5MB0ZC9epKnzkh7Bzpp_bPnHoMrA0"
}

# ============================================================================
# dumpers.xyz
# ============================================================================
resource "digitalocean_domain" "dumpers-xyz" {
  name = "dumpers.xyz"
}

resource "digitalocean_record" "dumpers-A" {
  domain = digitalocean_domain.dumpers-xyz.name
  type   = "A"
  name   = "@"
  value  = digitalocean_droplet.projects.ipv4_address
}

resource "digitalocean_record" "dumpers-AAAA" {
  domain = digitalocean_domain.dumpers-xyz.name
  type   = "AAAA"
  name   = "@"
  value  = digitalocean_droplet.projects.ipv6_address
}

resource "digitalocean_record" "dumpers-CNAME-www" {
  domain = digitalocean_domain.dumpers-xyz.name
  type   = "CNAME"
  name   = "www"
  value  = "@"
}

# ============================================================================
# darksearch.xyz
# ============================================================================
resource "digitalocean_domain" "darksearch-xyz" {
  name = "darksearch.xyz"
}

resource "digitalocean_record" "darksearch-A" {
  domain = digitalocean_domain.darksearch-xyz.name
  type   = "A"
  name   = "@"
  value  = digitalocean_droplet.projects.ipv4_address
}

resource "digitalocean_record" "darksearch-AAAA" {
  domain = digitalocean_domain.darksearch-xyz.name
  type   = "AAAA"
  name   = "@"
  value  = digitalocean_droplet.projects.ipv6_address
}

resource "digitalocean_record" "darksearch-CNAME-www" {
  domain = digitalocean_domain.darksearch-xyz.name
  type   = "CNAME"
  name   = "www"
  value  = "@"
}

# ============================================================================
# Firewall - minimal exposure
# ============================================================================
resource "digitalocean_firewall" "projects" {
  name        = "projects-fw"
  droplet_ids = [digitalocean_droplet.projects.id]

  # SSH access via Tailscale only - no public port 22

  # HTTP (ACME/Let's Encrypt challenges)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Outbound - allow all (updates, Tailscale, etc.)
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

# ============================================================================
# Outputs
# ============================================================================
output "projects_ip" {
  value = digitalocean_droplet.projects.ipv4_address
}

output "projects_ipv6" {
  value = digitalocean_droplet.projects.ipv6_address
}
