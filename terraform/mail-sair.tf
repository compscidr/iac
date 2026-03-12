# Mail DNS records for sair.run
# Mail is handled by the existing Mailu instance on mail.jasonernst.com

# A/AAAA records for mail.sair.run -> www droplet (where Mailu runs)
resource "digitalocean_record" "sair-A-mail" {
  domain = digitalocean_domain.sair-run.name
  type   = "A"
  name   = "mail"
  value  = digitalocean_droplet.www-jasonernst-com.ipv4_address
}

resource "digitalocean_record" "sair-AAAA-mail" {
  domain = digitalocean_domain.sair-run.name
  type   = "AAAA"
  name   = "mail"
  value  = digitalocean_droplet.www-jasonernst-com.ipv6_address
}

# MX record - mail.sair.run handles mail for sair.run
resource "digitalocean_record" "sair-MX" {
  domain   = digitalocean_domain.sair-run.name
  type     = "MX"
  name     = "@"
  value    = "mail.sair.run."
  priority = 10
}

# SPF record - authorize the mail server to send on behalf of this domain
resource "digitalocean_record" "sair-TXT-SPF" {
  domain = digitalocean_domain.sair-run.name
  type   = "TXT"
  name   = "@"
  value  = "v=spf1 mx -all"
}

# DMARC record - policy for handling failed authentication
resource "digitalocean_record" "sair-TXT-DMARC" {
  domain = digitalocean_domain.sair-run.name
  type   = "TXT"
  name   = "_dmarc"
  value  = "v=DMARC1; p=reject; rua=mailto:jason@sair.run; ruf=mailto:jason@sair.run; adkim=s; aspf=s"
}

# DMARC report record - allows receiving DMARC reports for this domain
resource "digitalocean_record" "sair-TXT-DMARC-report" {
  domain = digitalocean_domain.sair-run.name
  type   = "TXT"
  name   = "sair.run._report._dmarc"
  value  = "v=DMARC1;"
}

# DKIM record for Mailu
resource "digitalocean_record" "sair-TXT-DKIM" {
  domain = digitalocean_domain.sair-run.name
  type   = "TXT"
  name   = "dkim._domainkey"
  value  = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA8/bhNGc+JfsAUTPlvK3b7s34jjR+lLdGdGadPhN9G0R95kMCUutTkYoL1zO60U/xRyWjXaXGMkukOyJL2sIfFqag4LjTCNX5K+TAn/kzTV5y6pLDbUCB4hyrcgbZTMbCCPCjUTYSyQFF1SmJwAAwwQ8WGLPLy+L5JEmRIsu5XVzCe5VKUxncxG/xdufllJx2TRuWxecZOmtmGgLilPa+lVsJQVFRpYuNIeIUFDM2kayqkYQYbv+mt3Edm6iR40uRNpO/8AG8Z26E+P/tL5iwXa2T8bXOiOBgVouiJaUFpO3TnQsZtp0RniSLB34M+10mK7EmryBA6rQyGY1K959GJQIDAQAB"
}

# Mail client auto-configuration
resource "digitalocean_record" "sair-CNAME-autoconfig" {
  domain = digitalocean_domain.sair-run.name
  type   = "CNAME"
  name   = "autoconfig"
  value  = "mail.sair.run."
}

resource "digitalocean_record" "sair-CNAME-autodiscover" {
  domain = digitalocean_domain.sair-run.name
  type   = "CNAME"
  name   = "autodiscover"
  value  = "mail.sair.run."
}

# SRV records for mail client auto-discovery
resource "digitalocean_record" "sair-SRV-autodiscover" {
  domain   = digitalocean_domain.sair-run.name
  type     = "SRV"
  name     = "_autodiscover._tcp"
  value    = "mail.sair.run."
  priority = 10
  weight   = 1
  port     = 443
}

resource "digitalocean_record" "sair-SRV-submissions" {
  domain   = digitalocean_domain.sair-run.name
  type     = "SRV"
  name     = "_submissions._tcp"
  value    = "mail.sair.run."
  priority = 10
  weight   = 1
  port     = 465
}

resource "digitalocean_record" "sair-SRV-imaps" {
  domain   = digitalocean_domain.sair-run.name
  type     = "SRV"
  name     = "_imaps._tcp"
  value    = "mail.sair.run."
  priority = 10
  weight   = 1
  port     = 993
}

resource "digitalocean_record" "sair-SRV-pop3s" {
  domain   = digitalocean_domain.sair-run.name
  type     = "SRV"
  name     = "_pop3s._tcp"
  value    = "mail.sair.run."
  priority = 10
  weight   = 1
  port     = 995
}

# Disable plaintext protocols (SRV with target "." means not available)
resource "digitalocean_record" "sair-SRV-imap-disabled" {
  domain   = digitalocean_domain.sair-run.name
  type     = "SRV"
  name     = "_imap._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}

resource "digitalocean_record" "sair-SRV-pop3-disabled" {
  domain   = digitalocean_domain.sair-run.name
  type     = "SRV"
  name     = "_pop3._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}

resource "digitalocean_record" "sair-SRV-submission-disabled" {
  domain   = digitalocean_domain.sair-run.name
  type     = "SRV"
  name     = "_submission._tcp"
  value    = "."
  priority = 0
  weight   = 0
  port     = 0
}
