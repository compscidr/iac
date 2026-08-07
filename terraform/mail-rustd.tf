# Mail DNS records for rustd.xyz
# Mail is handled by the existing Mailu instance on mail.jasonernst.com
#
# Note the split: the apex/www records in projects.tf point at the projects
# droplet (where the app will run), while everything below points at the www
# droplet (where Mailu runs).

# A/AAAA records for mail.rustd.xyz -> www droplet (where Mailu runs)
resource "digitalocean_record" "rustd-A-mail" {
  domain = digitalocean_domain.rustd-xyz.name
  type   = "A"
  name   = "mail"
  value  = digitalocean_droplet.www-jasonernst-com.ipv4_address
}

resource "digitalocean_record" "rustd-AAAA-mail" {
  domain = digitalocean_domain.rustd-xyz.name
  type   = "AAAA"
  name   = "mail"
  value  = digitalocean_droplet.www-jasonernst-com.ipv6_address
}

# MX record - mail.rustd.xyz handles mail for rustd.xyz
resource "digitalocean_record" "rustd-MX" {
  domain   = digitalocean_domain.rustd-xyz.name
  type     = "MX"
  name     = "@"
  value    = "mail.rustd.xyz."
  priority = 10
}

# SPF record - authorize the mail server to send on behalf of this domain.
# If an external mail provider is added later (see the design doc), it needs an
# include: here or its mail will fail SPF alignment under the DMARC policy below.
resource "digitalocean_record" "rustd-TXT-SPF" {
  domain = digitalocean_domain.rustd-xyz.name
  type   = "TXT"
  name   = "@"
  value  = "v=spf1 mx -all"
}

# DMARC record - policy for handling failed authentication
resource "digitalocean_record" "rustd-TXT-DMARC" {
  domain = digitalocean_domain.rustd-xyz.name
  type   = "TXT"
  name   = "_dmarc"
  value  = "v=DMARC1; p=reject; rua=mailto:jason@rustd.xyz; ruf=mailto:jason@rustd.xyz; adkim=s; aspf=s"
}

# DMARC report record - allows receiving DMARC reports for this domain
resource "digitalocean_record" "rustd-TXT-DMARC-report" {
  domain = digitalocean_domain.rustd-xyz.name
  type   = "TXT"
  name   = "rustd.xyz._report._dmarc"
  value  = "v=DMARC1;"
}

# DKIM record for Mailu.
# Generated up front via `flask mailu config-import` so this record is correct
# from the start - see the design doc for why a placeholder here is a trap.
resource "digitalocean_record" "rustd-TXT-DKIM" {
  domain = digitalocean_domain.rustd-xyz.name
  type   = "TXT"
  name   = "dkim._domainkey"
  value  = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsat/zt9/fOGGoJrkVf4xE9p2+FiSUPL4xsieh7aG9GXkkEek4Ph5WjCfPuAKYsLpjQM6vtW/zUZ1he5TPIOkghIPBGt1HphdV6A68+1NEdk83gG1K/IsMYUUKCew4J+VL3RlGhWBbOpLJaGZTt4W/94F5CIAikr2lvvMIygtkR9uyUSu4Jj7tyPZI4kt01Pll8ilYSxsw3LRnlV0r1uHQ8yoOmhhKMJY7IfpV0BIf5A9ttvPJI0p1tR0+bC4wZDZitemqwpy5DDGeaJC1w1RNaA/vHZlBv1Up7hQcrKmLD4mtdFbaOrkztsD63BMaK39Cwb/93zfzq8EyRzLIrfj1QIDAQAB"
}

# Mail client auto-configuration
resource "digitalocean_record" "rustd-CNAME-autoconfig" {
  domain = digitalocean_domain.rustd-xyz.name
  type   = "CNAME"
  name   = "autoconfig"
  value  = "mail.rustd.xyz."
}

resource "digitalocean_record" "rustd-CNAME-autodiscover" {
  domain = digitalocean_domain.rustd-xyz.name
  type   = "CNAME"
  name   = "autodiscover"
  value  = "mail.rustd.xyz."
}

# SRV records for mail client auto-discovery
resource "digitalocean_record" "rustd-SRV-autodiscover" {
  domain   = digitalocean_domain.rustd-xyz.name
  type     = "SRV"
  name     = "_autodiscover._tcp"
  value    = "mail.rustd.xyz."
  priority = 10
  weight   = 1
  port     = 443
}

resource "digitalocean_record" "rustd-SRV-submissions" {
  domain   = digitalocean_domain.rustd-xyz.name
  type     = "SRV"
  name     = "_submissions._tcp"
  value    = "mail.rustd.xyz."
  priority = 10
  weight   = 1
  port     = 465
}

resource "digitalocean_record" "rustd-SRV-imaps" {
  domain   = digitalocean_domain.rustd-xyz.name
  type     = "SRV"
  name     = "_imaps._tcp"
  value    = "mail.rustd.xyz."
  priority = 10
  weight   = 1
  port     = 993
}

resource "digitalocean_record" "rustd-SRV-pop3s" {
  domain   = digitalocean_domain.rustd-xyz.name
  type     = "SRV"
  name     = "_pop3s._tcp"
  value    = "mail.rustd.xyz."
  priority = 10
  weight   = 1
  port     = 995
}

# Disable plaintext protocols (SRV with target "." means not available)
resource "digitalocean_record" "rustd-SRV-imap-disabled" {
  domain   = digitalocean_domain.rustd-xyz.name
  type     = "SRV"
  name     = "_imap._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}

resource "digitalocean_record" "rustd-SRV-pop3-disabled" {
  domain   = digitalocean_domain.rustd-xyz.name
  type     = "SRV"
  name     = "_pop3._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}

resource "digitalocean_record" "rustd-SRV-submission-disabled" {
  domain   = digitalocean_domain.rustd-xyz.name
  type     = "SRV"
  name     = "_submission._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}
