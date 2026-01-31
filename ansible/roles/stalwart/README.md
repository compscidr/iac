# Stalwart Mail Server Role

Installs and configures [Stalwart Mail Server](https://stalw.art/) - a modern, fast, and secure all-in-one mail server.

## Features

- SMTP (port 25, 587 with STARTTLS, 465 implicit TLS)
- IMAP (port 143 with STARTTLS, 993 implicit TLS)
- Web interface on HTTPS (443)
- Let's Encrypt TLS via ACME
- DKIM signing (ed25519)
- Spam filtering via Sieve
- Fail2ban integration
- Runs as dedicated `stalwart` user (not root)

## Requirements

- Ubuntu 20.04+ (22.04 or 24.04 recommended)
- Open ports: 22, 25, 587, 465, 143, 993, 80, 443
- Valid DNS records (MX, SPF, DKIM, DMARC)

## Security

- Runs as unprivileged `stalwart` user with `CAP_NET_BIND_SERVICE`
- Management interface bound to localhost only (access via SSH tunnel)
- Systemd hardening: `NoNewPrivileges`, `ProtectSystem`, `PrivateTmp`

## Role Variables

See `defaults/main.yml` for all available variables.

Key variables:
- `stalwart_domain`: Your mail domain (e.g., `jasonernst.com`)
- `stalwart_hostname`: Mail server FQDN (e.g., `mail.jasonernst.com`)

## Post-Installation

1. SSH tunnel to access admin panel:
   ```bash
   ssh -L 8080:localhost:8080 root@mail.jasonernst.com
   ```

2. Open http://localhost:8080 in your browser

3. Create domain and generate DKIM key:
   ```bash
   stalwart-cli -u http://localhost:8080 domain create jasonernst.com
   ```

4. Update DKIM DNS record in Terraform with the generated public key

5. Create user accounts:
   ```bash
   stalwart-cli -u http://localhost:8080 account create kai@jasonernst.com
   ```

## Testing

```bash
# Test SMTP
telnet mail.jasonernst.com 25

# Test IMAP with TLS
openssl s_client -connect mail.jasonernst.com:993

# Test STARTTLS on submission
openssl s_client -starttls smtp -connect mail.jasonernst.com:587

# Send test email
swaks --to test@example.com --from kai@jasonernst.com --server mail.jasonernst.com:587 --tls
```

## DNS Records Required

See `terraform/mail.tf` for the DNS records that need to be configured:
- A/AAAA records for mail.jasonernst.com
- MX record pointing to mail subdomain
- SPF record (`v=spf1 mx -all`)
- DMARC record
- DKIM record (update after key generation)
