#!/usr/bin/env bash
# Converge the stalwart role twice against local Docker; the second run must report
# changed=0, and that a part-failed or interrupted bootstrap is recovered (see runs.sh).
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
for d in rustd.xyz sair.run; do openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/mailu-dkim/$d.dkim.key" 2>/dev/null; done
chmod 0644 "$WORK"/certs/* "$WORK"/mailu-dkim/*
docker volume create certs >/dev/null
docker run --rm -v certs:/c -v "$WORK/certs:/s:ro" "$RUNNER" sh -c 'cp /s/* /c/'

python3 -I - "$WORK" "$ROLE" <<'PYEOF'
import json, os, sys
w, role = sys.argv[1:3]
os.makedirs(f"{w}/systemd")
json.dump({
    "stalwart_install_path": f"{w}/opt",
    "stalwart_mailu_dkim_dir": f"{w}/mailu-dkim",
    "stalwart_tailnet_ip": "127.0.0.2",
    "stalwart_systemd_dir": f"{w}/systemd",  # no systemd here: the units are templated, not enabled
    "stalwart_systemd_enable": False,
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
v5 = json.load(open(f"{w}/vars.json"))
v5["stalwart_admin_password"] = "admin-canary-Pw-4417"
v5["stalwart_domains"][1]["users"].append({"user": "canary", "password": 'canary"Pw\\9931'})
json.dump({k: v5[k] for k in ("stalwart_admin_password", "stalwart_domains")}, open(f"{w}/vars5.json", "w"))
v6 = json.load(open(f"{w}/vars.json"))
v6["stalwart_domains"][0]["users"][0]["password"] = "jason-changed-Pw-6604"
json.dump({"stalwart_domains": v6["stalwart_domains"]}, open(f"{w}/vars6.json", "w"))
# Every secret of both runs, raw and JSON-escaped, for the leak check.
pw = [u["password"] for f in (v5, json.load(open(f"{w}/vars.json"))) for d in f["stalwart_domains"] for u in d["users"]]
pw += [v5["stalwart_admin_password"], "admin-fixture-Pw-5519", "recovery-fixture-pw"]
open(f"{w}/secrets.txt", "w").write("\n".join(sorted(set(pw + [json.dumps(p)[1:-1] for p in pw]))) + "\n")
open(f"{w}/site.yml", "w").write(f"""---
- name: Converge stalwart locally
  hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - role: {role}
""")
PYEOF

# Runs, in one runner container (ansible needs installing once):
#   run0  stock-rules URL unreachable: must fail, and leave no bootstrap.done
#   run1  the real URL: redoes the part-failed bootstrap, must pass
#   run2  must report changed=0
#   run3  with the applied-plan stamp removed: must re-apply
#   run4  with the main container gone and a recovery container left holding the store
#         (a play killed mid-bootstrap): must remove it and start stalwart
#   run6  a mailbox password changed: must apply the plan and NOT run UpdateApps
#   run7  stalwart_bulwark_version changed: must run UpdateApps (and re-stamp)
#   run5  at -vvv, with a changed admin password the server does not know and a canary
#         mailbox password: the apply must fail, and no secret may appear in the output
cat > "$WORK/runs.sh" <<'SHEOF'
set -u
play() { ansible-playbook -i localhost, site.yml -e @vars.json --skip-tags onepassword "$@"; }
apk add -q ansible sudo py3-requests tar xz bash >/dev/null || exit 1
play -e stalwart_spam_rules_url=http://127.0.0.1:9/none.json.gz > run0.log 2>&1; echo $? > run0.rc
[ -e opt/bootstrap.done ] && echo yes > run0.marker
for run in 1 2; do play > run$run.log 2>&1 || { tail -40 run$run.log; exit 1; }; done
ls -a opt/etc > etc.txt
rm -f opt/etc/plan.applied.sha256
play > run3.log 2>&1 || { tail -40 run3.log; exit 1; }
image=$(docker inspect -f '{{.Config.Image}}' stalwart)
docker rm -f stalwart >/dev/null
docker run -d --name stalwart-bootstrap -e STALWART_RECOVERY_MODE=1 -e STALWART_RECOVERY_ADMIN=recovery:leftover \
  -v "$PWD/opt/etc:/etc/stalwart:ro" -v "$PWD/opt/data:/var/lib/stalwart" "$image" >/dev/null
sleep 5
play > run4.log 2>&1 || { tail -40 run4.log; exit 1; }
play -e @vars6.json > run6.log 2>&1 || { tail -40 run6.log; exit 1; }
play -e @vars6.json -e stalwart_bulwark_version=1.16.0 > run7.log 2>&1 || { tail -40 run7.log; exit 1; }
cp opt/etc/bulwark.applied bulwark7.txt
play -vvv -e @vars5.json > run5.log 2>&1; echo $? > run5.rc
SHEOF
docker run --rm --network host -v /var/run/docker.sock:/var/run/docker.sock -v "$WORK:$WORK" -v "$ROLE:$ROLE:ro" -w "$WORK" \
  -e ANSIBLE_LOCALHOST_WARNING=false -e ANSIBLE_PYTHON_INTERPRETER=auto_silent "$RUNNER" sh runs.sh || { echo "FAIL converge"; exit 1; }

recap() { grep -A1 'PLAY RECAP' "$WORK/$1.log" | tail -1; }
for run in run0 run1 run2 run3 run4 run6 run7; do echo "$run: $(recap $run)"; done
FAILED=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1${3:+: $3}"; FAILED=1; fi; }
check bootstrap_failure_loud '[ "$(cat "$WORK/run0.rc")" != 0 ] && grep -q "Fewer than 6 SpamRules after 120 s: the stock rules were not loaded" "$WORK/run0.log" && [ ! -e "$WORK/run0.marker" ]' \
  "run0 rc=$(cat "$WORK/run0.rc"), marker=$(cat "$WORK/run0.marker" 2>/dev/null)"
check part_failed_bootstrap_redone 'grep -q "Render the bootstrap plan" "$WORK/run1.log"'
check idempotent 'recap run2 | grep -q "changed=0 .*failed=0"' "$(grep -B1 '^changed' "$WORK/run2.log" | head -6)"
check no_logs_on_disk '! grep -q "\.log$" "$WORK/etc.txt"' "$(tr '\n' ' ' < "$WORK/etc.txt")"
check unstamped_plan_reapplied 'grep -q "RUNNING HANDLER .*Apply Stalwart plan" "$WORK/run3.log"'
check leftover_recovery_removed '! docker container inspect stalwart-bootstrap >/dev/null 2>&1 && [ "$(docker inspect -f "{{.State.Running}}" stalwart)" = true ]'
# After the part-failed run0: stock rules plus the probe rule, no duplicates.
cli=$(ls "$WORK"/opt/bin/*/stalwart-cli-*/stalwart-cli)
rules=$(docker run --rm --network container:stalwart -v "$cli:/usr/local/bin/stalwart-cli:ro" -e HOME=/tmp -e STALWART_URL=http://127.0.0.1:8081 \
  -e STALWART_USER=stalwart-admin@rustd.xyz -e STALWART_PASSWORD=admin-fixture-Pw-5519 --entrypoint stalwart-cli \
  "$(docker inspect -f '{{.Config.Image}}' stalwart)" --no-color query SpamRule | awk 'NR > 1 && NF { print $2 }')
check spam_rules 'grep -qx IAC_JUNK_PROBE <<<"$rules" && [ "$(grep -c STWT_ <<<"$rules")" -gt 10 ] && [ -z "$(sort <<<"$rules" | uniq -d)" ]' \
  "$(grep -c STWT_ <<<"$rules") stock rules"
check apply_failure_leaks_nothing '[ "$(cat "$WORK/run5.rc")" != 0 ] && grep -q "stalwart-cli apply of .* failed (rc=" "$WORK/run5.log" \
  && ! grep -qF -f "$WORK/secrets.txt" "$WORK/run5.log"' "rc=$(cat "$WORK/run5.rc"), leaked: $(grep -oF -f "$WORK/secrets.txt" "$WORK/run5.log" | sort -u | head -3 | tr '\n' ' ')"
check bootstrap_updates_apps 'grep -q "RUNNING HANDLER .*Update Stalwart apps" "$WORK/run1.log"'
check plan_change_no_update_apps 'grep -q "RUNNING HANDLER .*Apply Stalwart plan" "$WORK/run6.log" && ! grep -q "Update Stalwart apps" "$WORK/run6.log" \
  && ! grep -q "Update Stalwart apps" "$WORK/run3.log"'
# The new bundle is really served: Bulwark's index names its build.
for _ in $(seq 60); do curl -s http://127.0.0.2:18080/webmail/ | grep -q 'BUILD_ID = "1.16.0' && break; sleep 2; done
check bulwark_change_updates_apps 'grep -q "RUNNING HANDLER .*Update Stalwart apps" "$WORK/run7.log" && grep -q "/1.16.0/" "$WORK/bulwark7.txt" \
  && curl -s http://127.0.0.2:18080/webmail/ | grep -q "BUILD_ID = \"1.16.0"' "stamp $(cat "$WORK/bulwark7.txt" 2>/dev/null)"
check no_recovery '! docker inspect -f "{{range .Config.Env}}{{println .}}{{end}}" stalwart | grep -q STALWART_RECOVERY'
# Last: it bans an address for good. Published ports map to the gateway network (stalwart,
# gw_priority), so 127.0.0.2:9993, relayed by docker-proxy, arrives from the stalwart
# network's gateway, which must NOT be ban-exempt: 105 bad IMAP logins, then the right
# password is refused. The nginx-proxy network (exempt) still logs in after its own 105.
imap() { python3 -I - "$@" <<'PYEOF'
import imaplib, ssl, sys
pw, n = sys.argv[1], int(sys.argv[2])
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
for _ in range(n):
    try:
        m = imaplib.IMAP4_SSL("127.0.0.2", 9993, ssl_context=ctx, timeout=10); m.login("jason@rustd.xyz", pw); m.logout(); print("ok")
    except Exception as e:
        print(type(e).__name__)
PYEOF
}
imap wrong 105 > "$WORK/imap-bad.txt"
gw_after=$(imap jason-changed-Pw-6604 1)
GW=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' stalwart)
SIP=$(docker inspect -f '{{(index .NetworkSettings.Networks "nginx-proxy").IPAddress}}' stalwart)
px_after=$(docker run --rm --network nginx-proxy --entrypoint sh "$(docker inspect -f '{{.Config.Image}}' stalwart)" -c '
  for i in $(seq 105); do curl -s -o /dev/null -u jason@rustd.xyz:wrong "http://$0:8080/jmap/session"; done
  curl -s -o /dev/null -w "%{http_code}" -u jason@rustd.xyz:jason-changed-Pw-6604 "http://$0:8080/jmap/session"' "$SIP")
blocked=$(docker run --rm --network container:stalwart -v "$cli:/usr/local/bin/stalwart-cli:ro" -e HOME=/tmp -e STALWART_URL=http://127.0.0.1:8081 \
  -e STALWART_USER=stalwart-admin@rustd.xyz -e STALWART_PASSWORD=admin-fixture-Pw-5519 --entrypoint stalwart-cli \
  "$(docker inspect -f '{{.Config.Image}}' stalwart)" --no-color query BlockedIp | awk 'NR > 1 && NF { print $2 }' | tr '\n' ' ')
check gateway_path_banned '[ "$gw_after" != ok ] && grep -qw "$GW" <<<"$blocked" && [ "$px_after" = 200 ]' \
  "docker-proxy path after 105 bad: $gw_after (want refused), blocked: ${blocked:-none} (want the stalwart gateway $GW), nginx-proxy network after 105 bad: $px_after (want 200)"
exit $FAILED
