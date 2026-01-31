# Projects droplet - consolidates small toy projects
# - ping4.network (https://github.com/compscidr/network-tools)
# - ping6.network (https://github.com/compscidr/network-tools)
# - dumpers.xyz (https://github.com/compscidr/network-tools)
# - darksearch.xyz (https://github.com/compscidr/darksearch.xyz)

resource "digitalocean_droplet" "projects" {
  image    = "ubuntu-24-04-x64"
  name     = "projects"
  region   = "sfo3"
  size     = "s-1vcpu-2gb"  # $12/mo - room for multiple containerized services
  ipv6     = true
  vpc_uuid = digitalocean_vpc.sfo3-vpc.id
  ssh_keys = [digitalocean_ssh_key.github.fingerprint]

  tags = ["projects"]
}

# VPC for sfo3 region
resource "digitalocean_vpc" "sfo3-vpc" {
  name     = "projects-vpc"
  region   = "sfo3"
  ip_range = "10.10.20.0/24"
}

# ============================================================================
# ping4.network
# ============================================================================
resource "digitalocean_domain" "ping4-network" {
  name       = "ping4.network"
  ip_address = digitalocean_droplet.projects.ipv4_address
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
  name       = "ping6.network"
  ip_address = digitalocean_droplet.projects.ipv4_address
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

# ============================================================================
# dumpers.xyz
# ============================================================================
resource "digitalocean_domain" "dumpers-xyz" {
  name       = "dumpers.xyz"
  ip_address = digitalocean_droplet.projects.ipv4_address
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
  name       = "darksearch.xyz"
  ip_address = digitalocean_droplet.projects.ipv4_address
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
# Outputs
# ============================================================================
output "projects_ip" {
  value = digitalocean_droplet.projects.ipv4_address
}

output "projects_ipv6" {
  value = digitalocean_droplet.projects.ipv6_address
}
