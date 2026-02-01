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
  value  = "v=DMARC1; p=quarantine; rua=mailto:admin@jasonernst.com; ruf=mailto:admin@jasonernst.com; fo=1"
}

# DKIM record for Mailu
# Generated via Mailu admin UI: https://mail.jasonernst.com/admin
resource "digitalocean_record" "TXT-DKIM" {
  domain = digitalocean_domain.default.name
  type   = "TXT"
  name   = "dkim._domainkey"
  value  = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwoq0cBEGBSux4sWE2AVkhMhfkjq3q1AHidf0OhzMb0tByDvYm8iGIvEvmH8ZjKjyJMhZGPwgkjomQ7/glVUTQ0RqbjCODt8Z+Ch9OcLc3vwFv5Zd18wCuiu7KlaaaP2zWJMheCfNm16Oroqs0kQJ9m/RVB2UQWHJmu0cjtdVbIu6ICEyd/yY42GXR1wMWKPqYIagZU8dYau7NDHwJJCKmtybKWNLkpMZq19KC4XxrjzvKcCZuhhM6sbxw9hpoTA1Tj708nYHMg5rS+GHrUA8T4DqJDBjWhXfVfkmRQnK0lwV5A12KAifOjWu4L5+B10y2SE7jojnxQ1rHwHwPLwUHwIDAQAB"
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
