# Projects Role

Deploys toy projects to a consolidated droplet behind nginx-proxy with automatic SSL.

## Architecture

```
Internet → Host :80/:443 → nginx-proxy
                               │
                    Routes by VIRTUAL_HOST header
                               │
            ┌──────────────────┼──────────────────┐
            ▼                  ▼                  ▼
    network-tools:80     darksearch:80      (future apps)
    ├─ ping4.network     └─ darksearch.xyz
    ├─ ping6.network
    └─ dumpers.xyz
```

All containers `expose: 80` internally. nginx-proxy is the only thing bound to host ports 80/443.
This allows multiple services to coexist without port conflicts.

## Services

| Service | Domains | Repo |
|---------|---------|------|
| network-tools | ping4.network, ping6.network, dumpers.xyz | [compscidr/network-tools](https://github.com/compscidr/network-tools) |
| darksearch | darksearch.xyz | [compscidr/darksearch.xyz](https://github.com/compscidr/darksearch.xyz) |

## SSL Certificates

Automatic via Let's Encrypt companion. Each service defines:
- `VIRTUAL_HOST` — domains nginx-proxy routes to this container
- `LETSENCRYPT_HOST` — domains to get SSL certs for
- `LETSENCRYPT_EMAIL` — email for cert notifications

## Usage

```bash
# After Terraform + bootstrap
ansible-playbook -i inventory.yml projects.yml
```

## Adding New Projects

1. Create docker-compose.yml with:
   ```yaml
   services:
     web:
       expose:
         - "80"
       environment:
         - VIRTUAL_HOST=mydomain.com,www.mydomain.com
         - LETSENCRYPT_HOST=mydomain.com
         - LETSENCRYPT_EMAIL=you@example.com
   networks:
     default:
       external: true
       name: bridge
   ```

2. Add to `defaults/main.yml` and `tasks/main.yml`

3. Add DNS records in Terraform (`projects.tf`)
