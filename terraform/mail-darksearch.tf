# Mail DNS records for darksearch.xyz
# Mail is handled by the existing Mailu instance on mail.jasonernst.com
#
# Note the split: the apex/www records in projects.tf point at the projects
# droplet (where the site runs), while everything below points at the www
# droplet (where Mailu runs). Addresses: jason@ (mailbox), and the abuse@,
# dmca@ and postmaster@ aliases into it (ansible/roles/mailu/defaults).

# A/AAAA records for mail.darksearch.xyz -> www droplet (where Mailu runs)
resource "digitalocean_record" "darksearch-A-mail" {
  domain = digitalocean_domain.darksearch-xyz.name
  type   = "A"
  name   = "mail"
  value  = digitalocean_droplet.www-jasonernst-com.ipv4_address
}

resource "digitalocean_record" "darksearch-AAAA-mail" {
  domain = digitalocean_domain.darksearch-xyz.name
  type   = "AAAA"
  name   = "mail"
  value  = digitalocean_droplet.www-jasonernst-com.ipv6_address
}

# MX record - mail.darksearch.xyz handles mail for darksearch.xyz
resource "digitalocean_record" "darksearch-MX" {
  domain   = digitalocean_domain.darksearch-xyz.name
  type     = "MX"
  name     = "@"
  value    = "mail.darksearch.xyz."
  priority = 10
}

# SPF record - authorize the mail server to send on behalf of this domain.
# If an external mail provider is added later, it needs an include: here or its
# mail will fail SPF alignment under the DMARC policy below.
resource "digitalocean_record" "darksearch-TXT-SPF" {
  domain = digitalocean_domain.darksearch-xyz.name
  type   = "TXT"
  name   = "@"
  value  = "v=spf1 mx -all"
}

# DMARC record - policy for handling failed authentication
resource "digitalocean_record" "darksearch-TXT-DMARC" {
  domain = digitalocean_domain.darksearch-xyz.name
  type   = "TXT"
  name   = "_dmarc"
  value  = "v=DMARC1; p=reject; rua=mailto:jason@darksearch.xyz; ruf=mailto:jason@darksearch.xyz; adkim=s; aspf=s"
}

# DMARC report record - allows receiving DMARC reports for this domain
resource "digitalocean_record" "darksearch-TXT-DMARC-report" {
  domain = digitalocean_domain.darksearch-xyz.name
  type   = "TXT"
  name   = "darksearch.xyz._report._dmarc"
  value  = "v=DMARC1;"
}

# DKIM record for Mailu.
# Generated up front via `flask mailu config-import` (the same command the mailu
# role runs) so this record is correct from the start - see
# docs/superpowers/specs/2026-08-05-rustd-xyz-dns-mail-design.md for why a
# placeholder here is a trap.
resource "digitalocean_record" "darksearch-TXT-DKIM" {
  domain = digitalocean_domain.darksearch-xyz.name
  type   = "TXT"
  name   = "dkim._domainkey"
  value  = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA15RbLL/OnsiHi5AsP1aSbAlLOcf3BCE4XI0bQSpoW57kB7J4fkNbEO17mo83bBzvCGGILdMGlvnRbcvA4ZrwQaWFWoOWdPVnBslHpRub0YEM56htgF6OhaZ6ot2FGBWMsHsuAH4RGIiNBDlIv0K2LhbWop1FcOhkQkzGYPuUCwHkFYHd26VVkyxwqJhh0N/Df7c6fO5IjgCrBVakZn7hdMw27+j+FA9K9YIgyjZ/ODu6WXS/QjuVBZJgLJc8qIbn5UskHjaMFWzAGY7nBJzKVqDHy2WtApEWc7e2yqzRrwQTBcFXzMWe3JKngYrP8FkY7gVuERPh6DZKAX5t3M0zRQIDAQAB"
}

# Mail client auto-configuration
resource "digitalocean_record" "darksearch-CNAME-autoconfig" {
  domain = digitalocean_domain.darksearch-xyz.name
  type   = "CNAME"
  name   = "autoconfig"
  value  = "mail.darksearch.xyz."
}

resource "digitalocean_record" "darksearch-CNAME-autodiscover" {
  domain = digitalocean_domain.darksearch-xyz.name
  type   = "CNAME"
  name   = "autodiscover"
  value  = "mail.darksearch.xyz."
}

# SRV records for mail client auto-discovery
resource "digitalocean_record" "darksearch-SRV-autodiscover" {
  domain   = digitalocean_domain.darksearch-xyz.name
  type     = "SRV"
  name     = "_autodiscover._tcp"
  value    = "mail.darksearch.xyz."
  priority = 10
  weight   = 1
  port     = 443
}

resource "digitalocean_record" "darksearch-SRV-submissions" {
  domain   = digitalocean_domain.darksearch-xyz.name
  type     = "SRV"
  name     = "_submissions._tcp"
  value    = "mail.darksearch.xyz."
  priority = 10
  weight   = 1
  port     = 465
}

resource "digitalocean_record" "darksearch-SRV-imaps" {
  domain   = digitalocean_domain.darksearch-xyz.name
  type     = "SRV"
  name     = "_imaps._tcp"
  value    = "mail.darksearch.xyz."
  priority = 10
  weight   = 1
  port     = 993
}

resource "digitalocean_record" "darksearch-SRV-pop3s" {
  domain   = digitalocean_domain.darksearch-xyz.name
  type     = "SRV"
  name     = "_pop3s._tcp"
  value    = "mail.darksearch.xyz."
  priority = 10
  weight   = 1
  port     = 995
}

# Disable plaintext protocols (SRV with target "." means not available)
resource "digitalocean_record" "darksearch-SRV-imap-disabled" {
  domain   = digitalocean_domain.darksearch-xyz.name
  type     = "SRV"
  name     = "_imap._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}

resource "digitalocean_record" "darksearch-SRV-pop3-disabled" {
  domain   = digitalocean_domain.darksearch-xyz.name
  type     = "SRV"
  name     = "_pop3._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}

resource "digitalocean_record" "darksearch-SRV-submission-disabled" {
  domain   = digitalocean_domain.darksearch-xyz.name
  type     = "SRV"
  name     = "_submission._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}
