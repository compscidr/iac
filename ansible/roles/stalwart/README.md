# Stalwart Mail Server Role

Installs and configures [Stalwart Mail Server](https://stalw.art/) - a modern, fast, and secure all-in-one mail server.

## Features

- SMTP (port 25, 587, 465)
- IMAP (port 143, 993)
- Web admin interface
- Let's Encrypt TLS via ACME
- DKIM signing
- Spam filtering via Sieve
- Fail2ban integration

## Requirements

- Ubuntu 20.04+ (22.04 or 24.04 recommended)
- Open ports: 25, 587, 465, 143, 993, 443, 8080
- Valid DNS records (MX, SPF, DKIM, DMARC)

## Role Variables

See `defaults/main.yml` for all available variables.

Key variables:
- `stalwart_domain`: Your mail domain (e.g., `jasonernst.com`)
- `stalwart_hostname`: Mail server FQDN (e.g., `mail.jasonernst.com`)
- `stalwart_admin_password`: Admin password (store in 1Password)

## Post-Installation

1. Access admin panel at `https://mail.jasonernst.com:8080`

2. Generate DKIM key:
   ```bash
   stalwart-cli -u https://localhost:8080 dkim generate stalwart jasonernst.com
   ```

3. Update DKIM DNS record with the generated public key

4. Create user accounts:
   ```bash
   stalwart-cli -u https://localhost:8080 account create kai@jasonernst.com
   ```

## Testing

```bash
# Test SMTP
telnet mail.jasonernst.com 25

# Test IMAP with TLS
openssl s_client -connect mail.jasonernst.com:993

# Send test email
swaks --to test@example.com --from kai@jasonernst.com --server mail.jasonernst.com:587 --tls
```

## DNS Records Required

See `terraform/mail.tf` for the DNS records that need to be configured.
