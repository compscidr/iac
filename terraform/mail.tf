# Mail server infrastructure for jasonernst.com
# Uses Stalwart Mail Server

resource "digitalocean_droplet" "mail-jasonernst-com" {
  image    = "ubuntu-24-04-x64"
  name     = "mail-jasonernst-com"
  region   = "sfo2"
  size     = "s-1vcpu-2gb"
  ipv6     = true
  vpc_uuid = digitalocean_vpc.www-jasonernst-vpc.id
  ssh_keys = [28506911]

  tags = ["mail", "jasonernst-com"]
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
resource "digitalocean_record" "TXT-SPF" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "@"
  value  = "v=spf1 mx a:mail.jasonernst.com -all"
}

# DMARC record - policy for handling failed authentication
resource "digitalocean_record" "TXT-DMARC" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "_dmarc"
  value  = "v=DMARC1; p=quarantine; rua=mailto:postmaster@jasonernst.com; ruf=mailto:postmaster@jasonernst.com; fo=1"
}

# DKIM record - placeholder, update after Stalwart generates the key
# Run: stalwart-cli dkim generate <selector> jasonernst.com
# Then update this value with the generated public key
resource "digitalocean_record" "TXT-DKIM" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "stalwart._domainkey"
  value  = "v=DKIM1; k=rsa; p=REPLACE_WITH_GENERATED_PUBLIC_KEY"
}

# Reverse DNS (PTR) - set via DigitalOcean console or API
# This is critical for email deliverability
# Note: DigitalOcean automatically sets PTR to droplet name if it matches a domain you own

output "mail_droplet_ip" {
  value = digitalocean_droplet.mail-jasonernst-com.ipv4_address
}

output "mail_droplet_ipv6" {
  value = digitalocean_droplet.mail-jasonernst-com.ipv6_address
}
