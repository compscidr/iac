# Mail DNS records for 2dogs1bun.io
# Mail is handled by the existing Mailu instance on mail.jasonernst.com
#
# Note the split: the apex/www records in projects.tf point at the projects
# droplet (where the site runs), while everything below points at the www
# droplet (where Mailu runs). Addresses: jason@ (mailbox), noreply@ (listmonk), and
# the hello@ and postmaster@ aliases into jason@ (ansible/roles/mailu/defaults).

# A/AAAA records for mail.2dogs1bun.io -> www droplet (where Mailu runs)
resource "digitalocean_record" "twodogs1bun-A-mail" {
  domain = digitalocean_domain.twodogs1bun-io.name
  type   = "A"
  name   = "mail"
  value  = digitalocean_droplet.www-jasonernst-com.ipv4_address
}

resource "digitalocean_record" "twodogs1bun-AAAA-mail" {
  domain = digitalocean_domain.twodogs1bun-io.name
  type   = "AAAA"
  name   = "mail"
  value  = digitalocean_droplet.www-jasonernst-com.ipv6_address
}

# MX record - mail.2dogs1bun.io handles mail for 2dogs1bun.io
resource "digitalocean_record" "twodogs1bun-MX" {
  domain   = digitalocean_domain.twodogs1bun-io.name
  type     = "MX"
  name     = "@"
  value    = "mail.2dogs1bun.io."
  priority = 10
}

# SPF record - authorize the mail server to send on behalf of this domain.
# If an external mail provider is added later, it needs an include: here or its
# mail will fail SPF alignment under the DMARC policy below.
resource "digitalocean_record" "twodogs1bun-TXT-SPF" {
  domain = digitalocean_domain.twodogs1bun-io.name
  type   = "TXT"
  name   = "@"
  value  = "v=spf1 mx -all"
}

# DMARC record - policy for handling failed authentication
resource "digitalocean_record" "twodogs1bun-TXT-DMARC" {
  domain = digitalocean_domain.twodogs1bun-io.name
  type   = "TXT"
  name   = "_dmarc"
  value  = "v=DMARC1; p=reject; rua=mailto:jason@2dogs1bun.io; ruf=mailto:jason@2dogs1bun.io; adkim=s; aspf=s"
}

# DMARC report record - allows receiving DMARC reports for this domain
resource "digitalocean_record" "twodogs1bun-TXT-DMARC-report" {
  domain = digitalocean_domain.twodogs1bun-io.name
  type   = "TXT"
  name   = "2dogs1bun.io._report._dmarc"
  value  = "v=DMARC1;"
}

# Mail client auto-configuration
resource "digitalocean_record" "twodogs1bun-CNAME-autoconfig" {
  domain = digitalocean_domain.twodogs1bun-io.name
  type   = "CNAME"
  name   = "autoconfig"
  value  = "mail.2dogs1bun.io."
}

resource "digitalocean_record" "twodogs1bun-CNAME-autodiscover" {
  domain = digitalocean_domain.twodogs1bun-io.name
  type   = "CNAME"
  name   = "autodiscover"
  value  = "mail.2dogs1bun.io."
}

# SRV records for mail client auto-discovery
resource "digitalocean_record" "twodogs1bun-SRV-autodiscover" {
  domain   = digitalocean_domain.twodogs1bun-io.name
  type     = "SRV"
  name     = "_autodiscover._tcp"
  value    = "mail.2dogs1bun.io."
  priority = 10
  weight   = 1
  port     = 443
}

resource "digitalocean_record" "twodogs1bun-SRV-submissions" {
  domain   = digitalocean_domain.twodogs1bun-io.name
  type     = "SRV"
  name     = "_submissions._tcp"
  value    = "mail.2dogs1bun.io."
  priority = 10
  weight   = 1
  port     = 465
}

resource "digitalocean_record" "twodogs1bun-SRV-imaps" {
  domain   = digitalocean_domain.twodogs1bun-io.name
  type     = "SRV"
  name     = "_imaps._tcp"
  value    = "mail.2dogs1bun.io."
  priority = 10
  weight   = 1
  port     = 993
}

resource "digitalocean_record" "twodogs1bun-SRV-pop3s" {
  domain   = digitalocean_domain.twodogs1bun-io.name
  type     = "SRV"
  name     = "_pop3s._tcp"
  value    = "mail.2dogs1bun.io."
  priority = 10
  weight   = 1
  port     = 995
}

# Disable plaintext protocols (SRV with target "." means not available)
resource "digitalocean_record" "twodogs1bun-SRV-imap-disabled" {
  domain   = digitalocean_domain.twodogs1bun-io.name
  type     = "SRV"
  name     = "_imap._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}

resource "digitalocean_record" "twodogs1bun-SRV-pop3-disabled" {
  domain   = digitalocean_domain.twodogs1bun-io.name
  type     = "SRV"
  name     = "_pop3._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}

resource "digitalocean_record" "twodogs1bun-SRV-submission-disabled" {
  domain   = digitalocean_domain.twodogs1bun-io.name
  type     = "SRV"
  name     = "_submission._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}
