# Mail server DNS and configuration for jasonernst.com
# Mail runs on the www droplet (consolidated) using Mailu

# A record for mail.jasonernst.com -> www droplet
resource "digitalocean_record" "A-mail" {
  domain = digitalocean_domain.default.name
  type   = "A"
  name   = "mail"
  value  = digitalocean_droplet.www-jasonernst-com.ipv4_address
}

# AAAA record for mail.jasonernst.com (IPv6)
resource "digitalocean_record" "AAAA-mail" {
  domain = digitalocean_domain.default.name
  type   = "AAAA"
  name   = "mail"
  value  = digitalocean_droplet.www-jasonernst-com.ipv6_address
}

# MX record - mail.jasonernst.com handles mail for jasonernst.com
resource "digitalocean_record" "MX" {
  domain   = digitalocean_domain.default.name
  type     = "MX"
  name     = "@"
  value    = "mail.jasonernst.com."
  priority = 10
}

# SPF record - authorize mail server and SendGrid to send on behalf of domain
resource "digitalocean_record" "TXT-SPF" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "@"
  value  = "v=spf1 mx include:sendgrid.net -all"
}

# DMARC record - policy for handling failed authentication
resource "digitalocean_record" "TXT-DMARC" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "_dmarc"
  value  = "v=DMARC1; p=reject; rua=mailto:admin@jasonernst.com; ruf=mailto:admin@jasonernst.com; adkim=s; aspf=s"
}

# DMARC report record - allows receiving DMARC reports for this domain
resource "digitalocean_record" "TXT-DMARC-report" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "jasonernst.com._report._dmarc"
  value  = "v=DMARC1;"
}

# DKIM record for Mailu
# Generated via Mailu admin UI: https://mail.jasonernst.com/admin
resource "digitalocean_record" "TXT-DKIM" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "dkim._domainkey"
  value  = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwoq0cBEGBSux4sWE2AVkhMhfkjq3q1AHidf0OhzMb0tByDvYm8iGIvEvmH8ZjKjyJMhZGPwgkjomQ7/glVUTQ0RqbjCODt8Z+Ch9OcLc3vwFv5Zd18wCuiu7KlaaaP2zWJMheCfNml6Oroqs0kQJ9m/RVB2UQWHJmu0cjtdVbIu6ICEyd/yY42GXR1wMWKPqYIagZU8dYau7NDHwJJCKmtybKWNLkpMZql9KC4XxrjzvKcCZuhhM6sbxw9hpoTAlTj708nYHMg5rS+GHrUA8T4DqJDBjWhXfVfkmRQnK0lwV5A12KAifOjWu4L5+Bl0y2SE7jojnxQ1rHwHWPLwUHwIDAQAB"
}

# SendGrid DNS records for domain authentication and link branding
resource "digitalocean_record" "CNAME-sendgrid-url" {
  domain = digitalocean_domain.default.name
  type   = "CNAME"
  name   = "url8795"
  value  = "sendgrid.net."
}

resource "digitalocean_record" "CNAME-sendgrid-59516169" {
  domain = digitalocean_domain.default.name
  type   = "CNAME"
  name   = "59516169"
  value  = "sendgrid.net."
}

resource "digitalocean_record" "CNAME-sendgrid-em" {
  domain = digitalocean_domain.default.name
  type   = "CNAME"
  name   = "em3384"
  value  = "u59516169.wl170.sendgrid.net."
}

# SendGrid DKIM records
resource "digitalocean_record" "CNAME-sendgrid-dkim-s1" {
  domain = digitalocean_domain.default.name
  type   = "CNAME"
  name   = "s1._domainkey"
  value  = "s1.domainkey.u59516169.wl170.sendgrid.net."
}

resource "digitalocean_record" "CNAME-sendgrid-dkim-s2" {
  domain = digitalocean_domain.default.name
  type   = "CNAME"
  name   = "s2._domainkey"
  value  = "s2.domainkey.u59516169.wl170.sendgrid.net."
}

# Mail client auto-configuration records
resource "digitalocean_record" "CNAME-autoconfig" {
  domain = digitalocean_domain.default.name
  type   = "CNAME"
  name   = "autoconfig"
  value  = "mail.jasonernst.com."
}

resource "digitalocean_record" "CNAME-autodiscover" {
  domain = digitalocean_domain.default.name
  type   = "CNAME"
  name   = "autodiscover"
  value  = "mail.jasonernst.com."
}

# SRV records for mail client auto-discovery
resource "digitalocean_record" "SRV-autodiscover" {
  domain   = digitalocean_domain.default.name
  type     = "SRV"
  name     = "_autodiscover._tcp"
  value    = "mail.jasonernst.com."
  priority = 10
  weight   = 1
  port     = 443
}

resource "digitalocean_record" "SRV-submissions" {
  domain   = digitalocean_domain.default.name
  type     = "SRV"
  name     = "_submissions._tcp"
  value    = "mail.jasonernst.com."
  priority = 10
  weight   = 1
  port     = 465
}

resource "digitalocean_record" "SRV-imaps" {
  domain   = digitalocean_domain.default.name
  type     = "SRV"
  name     = "_imaps._tcp"
  value    = "mail.jasonernst.com."
  priority = 10
  weight   = 1
  port     = 993
}

resource "digitalocean_record" "SRV-pop3s" {
  domain   = digitalocean_domain.default.name
  type     = "SRV"
  name     = "_pop3s._tcp"
  value    = "mail.jasonernst.com."
  priority = 10
  weight   = 1
  port     = 995
}

# Disable plaintext protocols (SRV with target "." means not available)
resource "digitalocean_record" "SRV-imap-disabled" {
  domain   = digitalocean_domain.default.name
  type     = "SRV"
  name     = "_imap._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}

resource "digitalocean_record" "SRV-pop3-disabled" {
  domain   = digitalocean_domain.default.name
  type     = "SRV"
  name     = "_pop3._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}

resource "digitalocean_record" "SRV-submission-disabled" {
  domain   = digitalocean_domain.default.name
  type     = "SRV"
  name     = "_submission._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}
