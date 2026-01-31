resource "digitalocean_vpc" "www-jasonernst-vpc" {
  name     = "www-jasonernst-vpc"
  region   = "sfo2"
  ip_range = "10.10.10.0/24"
}

# size chart: https://developers.digitalocean.com/documentation/changelog/api-v2/new-size-slugs-for-droplet-plan-changes/
resource "digitalocean_droplet" "www-jasonernst-com" {
  image    = "ubuntu-24-04-x64"
  name     = "www-jasonernst-com"
  region   = "sfo2"
  size     = "s-1vcpu-2gb"
  ipv6     = true
  vpc_uuid = digitalocean_vpc.www-jasonernst-vpc.id
  ssh_keys = [digitalocean_ssh_key.github.fingerprint]

  user_data = templatefile("${path.module}/cloud-init/tailscale.yml", {
    tailscale_authkey = data.onepassword_item.tailscale.credential
  })
}

resource "digitalocean_domain" "default" {
  name       = "jasonernst.com"
  ip_address = digitalocean_droplet.www-jasonernst-com.ipv4_address
}

resource "digitalocean_record" "AAAA" {
  domain = digitalocean_domain.default.name
  type   = "AAAA"
  name   = "@"
  value  = digitalocean_droplet.www-jasonernst-com.ipv6_address
}

resource "digitalocean_record" "CNAME-www" {
  domain = digitalocean_domain.default.name
  type   = "CNAME"
  name   = "www"
  value  = "@"
}

resource "digitalocean_record" "CNAME-staging" {
  domain = digitalocean_domain.default.name
  type   = "CNAME"
  name   = "staging"
  value  = "@"
}

resource "digitalocean_record" "CNAME-dev" {
  domain = digitalocean_domain.default.name
  type   = "CNAME"
  name   = "dev"
  value  = "@"
}

# projects.jasonernst.com -> projects droplet
resource "digitalocean_record" "A-projects" {
  domain = digitalocean_domain.default.name
  type   = "A"
  name   = "projects"
  value  = digitalocean_droplet.projects.ipv4_address
}

resource "digitalocean_record" "AAAA-projects" {
  domain = digitalocean_domain.default.name
  type   = "AAAA"
  name   = "projects"
  value  = digitalocean_droplet.projects.ipv6_address
}

resource "digitalocean_record" "TXT-keybase" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "@"
  value  = "keybase-site-verification=YuSsvhu0S_6Oy2jZeTSr9ZojN-hYTcSl4HlWTvYxZBw"
}

# Google site verification
resource "digitalocean_record" "TXT-google" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "@"
  value  = "google-site-verification=RoGJzQFlM7_9E-aX1L6ly6A_ztGlKSywHyen151HrBE"
}

# maven verification record
resource "digitalocean_record" "TXT-maven" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "@"
  value  = "7mi6gm0pb0"
}

# Firewall - minimal exposure
resource "digitalocean_firewall" "www" {
  name        = "www-jasonernst-com-fw"
  droplet_ids = [digitalocean_droplet.www-jasonernst-com.id]

  # SSH
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

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

output "droplet_ip_addresses" {
  value = digitalocean_droplet.www-jasonernst-com.ipv4_address
}
