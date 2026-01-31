# Mail server infrastructure for jasonernst.com
# Uses Stalwart Mail Server

resource "digitalocean_droplet" "mail-jasonernst-com" {
  image    = "ubuntu-24-04-x64"
  name     = "mail-jasonernst-com"
  region   = "sfo2"
  size     = "s-1vcpu-512mb-10gb" # $4/mo - sufficient for Stalwart with 2 users
  ipv6     = true
  vpc_uuid = digitalocean_vpc.www-jasonernst-vpc.id
  ssh_keys = [digitalocean_ssh_key.github.fingerprint]

  tags = ["mail", "jasonernst-com"]

  user_data = templatefile("${path.module}/cloud-init/tailscale.yml", {
    tailscale_authkey = data.onepassword_item.tailscale.credential
    hostname          = "mail.jasonernst.com"
  })
}

# A record for mail.jasonernst.com
resource "digitalocean_record" "A-mail" {
  domain = digitalocean_domain.default.name
  type   = "A"
  name   = "mail"
  value  = digitalocean_droplet.mail-jasonernst-com.ipv4_address
}

# AAAA record for mail.jasonernst.com (IPv6)
resource "digitalocean_record" "AAAA-mail" {
  domain = digitalocean_domain.default.name
  type   = "AAAA"
  name   = "mail"
  value  = digitalocean_droplet.mail-jasonernst-com.ipv6_address
}

# MX record - mail.jasonernst.com handles mail for jasonernst.com
resource "digitalocean_record" "MX" {
  domain   = digitalocean_domain.default.name
  type     = "MX"
  name     = "@"
  value    = "mail.jasonernst.com."
  priority = 10
}

# SPF record - authorize mail server to send on behalf of domain
# Using 'mx' mechanism which covers mail.jasonernst.com
resource "digitalocean_record" "TXT-SPF" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "@"
  value  = "v=spf1 mx -all"
}

# DMARC record - policy for handling failed authentication
resource "digitalocean_record" "TXT-DMARC" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "_dmarc"
  value  = "v=DMARC1; p=quarantine; rua=mailto:postmaster@jasonernst.com; ruf=mailto:postmaster@jasonernst.com; fo=1"
}

# DKIM record - placeholder, update after Stalwart generates the key
# Stalwart uses ed25519 by default for better security
# Run: stalwart-cli -u http://localhost:8080 domain create jasonernst.com
# Then update this value with the generated public key
resource "digitalocean_record" "TXT-DKIM" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "stalwart._domainkey"
  value  = "v=DKIM1; k=ed25519; p=REPLACE_WITH_GENERATED_PUBLIC_KEY"
}

# Reverse DNS (PTR) - set via DigitalOcean console or API
# This is critical for email deliverability
# Note: DigitalOcean automatically sets PTR to droplet name if it matches a domain you own

# DigitalOcean Cloud Firewall for mail server
resource "digitalocean_firewall" "mail" {
  name = "mail-jasonernst-com-fw"

  droplet_ids = [digitalocean_droplet.mail-jasonernst-com.id]

  # SSH
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # SMTP (inbound mail from other servers)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "25"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Submission (client mail submission with STARTTLS)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "587"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # SMTPS (implicit TLS submission)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "465"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # IMAP (with STARTTLS)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "143"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # IMAPS (implicit TLS)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "993"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS (webmail)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTP (ACME certificate challenges)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Note: Management UI (8080) intentionally NOT exposed
  # Access via SSH tunnel: ssh -L 8080:localhost:8080 root@mail.jasonernst.com

  # Allow all outbound
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

output "mail_droplet_ip" {
  value = digitalocean_droplet.mail-jasonernst-com.ipv4_address
}

output "mail_droplet_ipv6" {
  value = digitalocean_droplet.mail-jasonernst-com.ipv6_address
}
