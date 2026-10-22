#!/usr/bin/env bash
# Converge the stalwart role twice against local Docker; the second run must report
# changed=0 (no re-apply of the plan, no container recreate).
#
#   bash ansible/roles/stalwart/tests/local-converge.sh
#
# ansible-playbook runs as root in a throwaway docker:cli container with the host's
# docker socket (the role chowns to UID 2000 and drives docker), against a temp dir
# bind-mounted at the same path so the daemon resolves the role's bind mounts. Staged
# mode on 127.0.0.2. 1Password is skipped (--skip-tags onepassword); every secret is a
# throwaway constant and every key is generated per run. Creates and removes a
# container `stalwart`, network `stalwart` and volume `certs` (refuses if they exist),
# plus network `nginx-proxy` if absent. SMOKE_KEEP=1 leaves them for poking at.
set -euo pipefail

ROLE=$(cd "$(dirname "$0")/.." && pwd)
RUNNER=docker:29.1.3-cli # ansible from apk; any docker CLI that speaks the host's API
WORK=$(mktemp -d)
MADE_PROXY_NET=

for c in stalwart stalwart-bootstrap; do
  if docker container inspect "$c" >/dev/null 2>&1; then echo "container $c exists; refusing"; exit 2; fi
done
if docker volume inspect certs >/dev/null 2>&1; then echo "volume certs exists; refusing"; exit 2; fi

cleanup() {
  if [ -n "${SMOKE_KEEP:-}" ]; then echo "SMOKE_KEEP: left stalwart running (files $WORK)"; return; fi
  docker rm -f stalwart stalwart-bootstrap >/dev/null 2>&1 || true
  docker volume rm certs >/dev/null 2>&1 || true
  docker network rm stalwart >/dev/null 2>&1 || true
  [ -n "$MADE_PROXY_NET" ] && docker network rm nginx-proxy >/dev/null 2>&1
  docker run --rm -v "$WORK:/w" "$RUNNER" sh -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1 || true
  rmdir "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

docker network inspect nginx-proxy >/dev/null 2>&1 || { docker network create nginx-proxy >/dev/null; MADE_PROXY_NET=1; }

mkdir -p "$WORK/certs" "$WORK/mailu-dkim"
openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj '/CN=mail.jasonernst.com' \
  -addext 'subjectAltName=DNS:mail.jasonernst.com,DNS:mail.rustd.xyz,DNS:mail.sair.run' \
  -keyout "$WORK/certs/mail.jasonernst.com.key" -out "$WORK/certs/mail.jasonernst.com.crt" 2>/dev/null
for d in rustd.xyz sair.run; do openssl genrsa -traditional -out "$WORK/mailu-dkim/$d.dkim.key" 2048 2>/dev/null; done
chmod 0644 "$WORK"/certs/* "$WORK"/mailu-dkim/*
docker volume create certs >/dev/null
docker run --rm -v certs:/c -v "$WORK/certs:/s:ro" "$RUNNER" sh -c 'cp /s/* /c/'

python3 -I - "$WORK" "$ROLE" <<'PYEOF'
import json, sys
w, role = sys.argv[1:3]
json.dump({
    "stalwart_install_path": f"{w}/opt",
    "stalwart_mailu_dkim_dir": f"{w}/mailu-dkim",
    "stalwart_tailnet_ip": "127.0.0.2",
    "stalwart_staged_http_port": 18080,  # a dev server often holds *:8080
    "stalwart_public_url": "https://smoke.invalid",
    "stalwart_domain": "rustd.xyz",
    "stalwart_domains": [
        {"domain": "rustd.xyz", "users": [{"user": "jason", "password": "jason-fixture-Pw-7731"},
                                           {"user": "noreply", "password": 'pa"ss\\wo%rd{x}'}]},
        {"domain": "sair.run", "users": [{"user": "jason", "password": "sair-fixture-Pw-2208"}]},
    ],
    "stalwart_aliases": [
        {"local": "contact", "domain": "rustd.xyz", "destination": "jason@rustd.xyz"},
        {"local": "postmaster", "domain": "sair.run", "destination": "jason@sair.run"},
    ],
    "stalwart_admin_password": "admin-fixture-Pw-5519",
    "stalwart_recovery_admin_password": "recovery-fixture-pw",
}, open(f"{w}/vars.json", "w"))
open(f"{w}/site.yml", "w").write(f"""---
- name: Converge stalwart locally
  hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - role: {role}
""")
PYEOF

docker run --rm --network host -v /var/run/docker.sock:/var/run/docker.sock -v "$WORK:$WORK" -v "$ROLE:$ROLE:ro" -w "$WORK" \
  -e ANSIBLE_LOCALHOST_WARNING=false -e ANSIBLE_PYTHON_INTERPRETER=auto_silent "$RUNNER" sh -c '
    apk add -q ansible sudo py3-requests tar xz >/dev/null &&
    for run in 1 2; do
      ansible-playbook -i localhost, site.yml -e @vars.json --skip-tags onepassword > run$run.log 2>&1 || { tail -40 run$run.log; exit 1; }
    done &&
    rm -f opt/etc/plan.applied.sha256 &&
    ansible-playbook -i localhost, site.yml -e @vars.json --skip-tags onepassword > run3.log 2>&1 || { tail -40 run3.log; exit 1; }' || { echo "FAIL converge"; exit 1; }

for run in 1 2; do echo "run $run: $(grep -A1 'PLAY RECAP' "$WORK/run$run.log" | tail -1)"; done
if grep -A1 'PLAY RECAP' "$WORK/run2.log" | tail -1 | grep -q 'changed=0 .*failed=0'; then echo "PASS idempotent"
else echo "FAIL idempotent: second run changed:"; grep -B1 '^changed' "$WORK/run2.log"; exit 1; fi
# A plan whose apply never succeeded (no stamp) is applied on the next run.
if grep -q 'RUNNING HANDLER .*Apply Stalwart plan' "$WORK/run3.log"; then echo "PASS unstamped_plan_reapplied"
else echo "FAIL unstamped_plan_reapplied: no apply after the stamp was removed"; exit 1; fi
# The full plan went in after the first normal start: stock rules plus the probe rule.
cli=$(ls "$WORK"/opt/bin/*/stalwart-cli-*/stalwart-cli)
rules=$(docker run --rm --network container:stalwart -v "$cli:/usr/local/bin/stalwart-cli:ro" -e HOME=/tmp -e STALWART_URL=http://127.0.0.1:8081 \
  -e STALWART_USER=admin@rustd.xyz -e STALWART_PASSWORD=admin-fixture-Pw-5519 --entrypoint stalwart-cli \
  "$(docker inspect -f '{{.Config.Image}}' stalwart)" --no-color query SpamRule)
if grep -q IAC_JUNK_PROBE <<<"$rules" && [ "$(grep -c STWT_ <<<"$rules")" -gt 10 ]; then echo "PASS spam_rules"
else echo "FAIL spam_rules: ${rules:0:300}"; exit 1; fi
if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' stalwart | grep -q STALWART_RECOVERY; then
  echo "FAIL no_recovery: recovery variables on the running container"; exit 1; fi
echo "PASS no_recovery"
