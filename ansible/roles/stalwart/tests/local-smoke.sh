#!/usr/bin/env bash
# Local smoke test for the Stalwart role's apply plan.
#
#   bash ansible/roles/stalwart/tests/local-smoke.sh
#
# Renders the role's templates/plan.ndjson.j2 (role defaults + test vars, two domains)
# with `ansible localhost -m template`, then boots the pinned image the way the role
# does: recovery mode + the bootstrap plan, a normal start that downloads the stock
# spam rules, then the full plan through stalwart-cli in the container's netns (the
# `Apply Stalwart plan` handler's path). Checks mail flow, DKIM, TLS, spam, webmail,
# the admin restrictions and that a re-apply changes nothing. Local Docker only. Every secret is
# throwaway: passwords are fixture constants, the TLS and DKIM keys are generated
# per run and never written to the repo. Exit 0 = every assertion passed.
#
# Needs: docker, python3, openssl, curl, ansible. stalwart-cli is taken from $STALWART_CLI or
# PATH, else downloaded (pinned + sha256-checked) into ~/.cache/stalwart-smoke.
# SMOKE_KEEP=1 leaves the container running afterwards for poking at.
set -uo pipefail

ROLE=$(cd "$(dirname "$0")/.." && pwd)

IMAGE="stalwartlabs/stalwart:v0.16.27@sha256:c429b311c93db5606598abc1c68225a85a6953183848ae01bee9c6a98885836c"
CLI_VERSION="v1.0.13"
CLI_SHA256="689644a491c298b4916714a93a2a249ee2ea70f2f2c054991658c3e8f0f27c13"

RECOVERY_ADMIN="recovery:recovery-fixture-pw"
ADMIN_USER="stalwart-admin@rustd.xyz"
ADMIN_PASS="admin-fixture-Pw-5519"
JASON_PASS="jason-fixture-Pw-7731"
SAIR_PASS="sair-fixture-Pw-2208"
NOREPLY_PASS='pa"ss\wo%rd{x}'

NAME="stalwart-smoke-$$"
WORK=$(mktemp -d)
FAILED=0

cleanup() {
  if [ -n "${SMOKE_KEEP:-}" ]; then echo "SMOKE_KEEP: left $NAME running (files $WORK)"; return; fi
  docker rm -f "$NAME" "$NAME-rec" "$NAME-rst" >/dev/null 2>&1
  [ -n "${RSYNCD_PID:-}" ] && kill "$RSYNCD_PID" 2>/dev/null
  # data/ and restore/ hold files owned by UID 2000: remove them as root in a container
  docker run --rm --user 0 -v "$WORK:/w" --entrypoint rm "$IMAGE" -rf /w/opt/data /w/opt/backups /w/restore >/dev/null 2>&1
  docker network rm "$NAME-tn" "$NAME-px" "$NAME-nx" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+: $2}"; FAILED=1; }

# --- stalwart-cli --------------------------------------------------------------
CLI=${STALWART_CLI:-$(command -v stalwart-cli || true)}
if [ -z "$CLI" ]; then
  CLI="$HOME/.cache/stalwart-smoke/stalwart-cli-$CLI_VERSION"
  if [ ! -x "$CLI" ]; then
    mkdir -p "$(dirname "$CLI")"
    tarball="$WORK/cli.tar.xz"
    curl -fsSL -o "$tarball" "https://github.com/stalwartlabs/cli/releases/download/$CLI_VERSION/stalwart-cli-x86_64-unknown-linux-musl.tar.xz" \
      && echo "$CLI_SHA256  $tarball" | sha256sum -c --quiet \
      && tar -xJf "$tarball" -C "$WORK" \
      && install -m 0755 "$(find "$WORK" -type f -name stalwart-cli | head -1)" "$CLI" \
      || { echo "cannot fetch stalwart-cli $CLI_VERSION"; exit 2; }
  fi
fi

# --- keys generated per run, mounted like production (/certs, /dkim read-only) ---
# One SAN cert for the four mail.* names; RSA DKIM keys in PKCS#8 form like Mailu's
# production keys (BEGIN PRIVATE KEY).
mkdir -p "$WORK/etc" "$WORK/certs" "$WORK/dkim"
echo '{"@type":"RocksDb","path":"/var/lib/stalwart/"}' > "$WORK/etc/config.json"
# Laid out like the certs volume on www: mail.<host>.crt/.key are symlinks to the
# acme-companion's real files in <host>/ (README "Certificate reload"); renewal rewrites those.
HOST=mail.jasonernst.com; CERTDIR="$WORK/certs/$HOST"
CERT="$CERTDIR/fullchain.pem"; DKIM_PUB="$WORK/rustd.xyz.dkim.pub"
mkdir -p "$CERTDIR"
newcert() { # cert-file key-file
  openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=$HOST" \
    -addext "subjectAltName=DNS:$HOST,DNS:mail.sair.run,DNS:mail.rustd.xyz,DNS:mail.darksearch.xyz" \
    -keyout "$2" -out "$1" 2>/dev/null
}
newcert "$CERT" "$CERTDIR/key.pem"
ln -s "./$HOST/fullchain.pem" "$WORK/certs/$HOST.crt"; ln -s "./$HOST/key.pem" "$WORK/certs/$HOST.key"
for d in rustd.xyz sair.run; do openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/dkim/$d.dkim.key" 2>/dev/null; done
[ "$(head -1 "$WORK/dkim/rustd.xyz.dkim.key")" = "-----BEGIN PRIVATE KEY-----" ] || { echo "DKIM fixture is not PKCS#8"; exit 2; }
openssl rsa -in "$WORK/dkim/rustd.xyz.dkim.key" -pubout -out "$DKIM_PUB" 2>/dev/null
chmod 0755 "$WORK" "$WORK"/etc "$WORK"/certs "$CERTDIR" "$WORK"/dkim
chmod 0644 "$WORK"/etc/* "$CERTDIR"/* "$WORK"/dkim/*
# data/ is a bind mount owned by UID 2000, as on the droplet: the backup reads it by path.
mkdir -p "$WORK/opt/data"
docker run --rm --user 0 -v "$WORK/opt/data:/d" --entrypoint sh "$IMAGE" -c 'chown 2000:2000 /d && chmod 0700 /d'
# Fixed subnets: -px is exempt from bans in the plan (as nginx-proxy's network is), -nx is not.
docker network create --subnet 172.30.251.0/24 "$NAME-px" >/dev/null && docker network create --subnet 172.30.252.0/24 "$NAME-nx" >/dev/null \
  || { echo "cannot create test networks 172.30.251.0/24, 172.30.252.0/24 (in use?)"; exit 2; }

# --- render the role's plan: role defaults, overridden by two test domains --------
# Both variants: the bootstrap plan (no SpamRule, so the first normal start still
# downloads the stock rules) and the full plan the handler applies.
python3 -I - "$WORK/vars.json" "$ADMIN_PASS" "$JASON_PASS" "$NOREPLY_PASS" "$SAIR_PASS" <<'PYEOF'
import json, sys
out, admin, jason, noreply, sair = sys.argv[1:6]
json.dump({
    "stalwart_domain": "rustd.xyz",
    "stalwart_domains": [
        {"domain": "rustd.xyz", "users": [{"user": "jason", "password": jason},
                                           {"user": "noreply", "password": noreply}]},
        {"domain": "sair.run", "users": [{"user": "jason", "password": sair}]},
    ],
    "stalwart_aliases": [
        {"local": "contact", "domain": "rustd.xyz", "destination": "jason@rustd.xyz"},
        {"local": "postmaster", "domain": "rustd.xyz", "destination": "jason@rustd.xyz"},
        {"local": "postmaster", "domain": "sair.run", "destination": "jason@sair.run"},
    ],
    "stalwart_admin_password": admin,
    "stalwart_ban_exempt_networks": ["172.30.251.0/24"],  # $NAME-px, plays nginx-proxy's network
}, open(out, "w"))
PYEOF
render() { # dest extra-vars-json
  (cd "$WORK" && ANSIBLE_LOCALHOST_WARNING=false ansible localhost -c local -i localhost, -m ansible.builtin.template \
    -a "src=$ROLE/templates/plan.ndjson.j2 dest=$1 mode=0644" \
    -e "@$ROLE/defaults/main.yml" -e "@$WORK/vars.json" -e "$2" >"$WORK/render.log" 2>&1) \
    || { echo "cannot render plan.ndjson.j2:"; sed 's/^/  /' "$WORK/render.log"; exit 2; }
  python3 -I -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]' "$1" \
    || { echo "rendered $1 is not NDJSON"; exit 2; }
}
render "$WORK/bootstrap.ndjson" '{"stalwart_plan_bootstrap": true}'
render "$WORK/plan.ndjson" '{}'

chmod 0644 "$WORK"/*.ndjson
MOUNTS=(-v "$WORK/opt/data:/var/lib/stalwart" -v "$WORK/etc:/etc/stalwart:ro"
        -v "$WORK/certs:/certs:ro" -v "$WORK/dkim:/dkim:ro")

hostport() { docker port "$1" "$2" | head -1 | sed 's/.*://'; }
# Run a command inside the Stalwart container's network namespace: it reaches the
# listeners on 127.0.0.1 and arrives from 127.0.0.1, the only address the admin
# credential accepts. This is how Ansible on the droplet runs stalwart-cli (it needs a
# writable HOME for its schema cache; the image user's HOME is not).
ns() { docker run --rm --network "container:$NAME" "$@"; }
ns_curl() { ns --entrypoint curl "$IMAGE" -s "$@"; }
wait_http() { # url seconds -> 0 once any HTTP answer arrives
  local i
  for ((i = 0; i < $2; i++)); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" != "000" ] && return 0
    sleep 1
  done
  return 1
}

# --- phase 1: recovery mode + apply --------------------------------------------
docker run -d --name "$NAME-rec" "${MOUNTS[@]}" \
  -e STALWART_RECOVERY_MODE=1 -e STALWART_RECOVERY_ADMIN="$RECOVERY_ADMIN" \
  -p 127.0.0.1::8080 "$IMAGE" >/dev/null
REC_URL="http://127.0.0.1:$(hostport "$NAME-rec" 8080)"
if wait_http "$REC_URL/jmap/session" 60; then pass container_start; else fail container_start; fi

STALWART_URL="$REC_URL" STALWART_USER="${RECOVERY_ADMIN%%:*}" STALWART_PASSWORD="${RECOVERY_ADMIN#*:}" \
  "$CLI" --no-color apply --file "$WORK/bootstrap.ndjson" > "$WORK/apply.log" 2>&1 \
  && pass bootstrap_apply || fail bootstrap_apply "$(tail -3 "$WORK/apply.log")"
docker rm -f "$NAME-rec" >/dev/null

# --- phase 2: normal start, no recovery variables ------------------------------
# STALWART_PUBLIC_URL as in production, but unresolvable: discovery documents would
# otherwise publish https://mail.jasonernst.com and a JMAP client pointed at this
# container (vandelay, Bulwark) would follow them to the real server.
docker run -d --name "$NAME" "${MOUNTS[@]}" -e STALWART_PUBLIC_URL=https://smoke.invalid \
  -p 127.0.0.1::25 -p 127.0.0.1::465 -p 127.0.0.1::993 -p 127.0.0.1::8080 -p 127.0.0.1::8081 \
  "$IMAGE" >/dev/null
P_SMTP=$(hostport "$NAME" 25); P_SUBS=$(hostport "$NAME" 465); P_IMAPS=$(hostport "$NAME" 993)
PUB="http://127.0.0.1:$(hostport "$NAME" 8080)"; ADM="http://127.0.0.1:$(hostport "$NAME" 8081)"
CIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")
docker network connect "$NAME-px" "$NAME"; docker network connect "$NAME-nx" "$NAME"
wait_http "$PUB/healthz/live" 30 || true

# Straight after the normal start the full plan goes in the way the role's handler sends
# it: stalwart-cli in the container's netns, as the admin, against 127.0.0.1:8081. It
# adds IAC_JUNK_PROBE, runs Task/SpamFilterMaintenance updateRules (the stock rules) and
# reloads settings. Then wait, as the role does, for the stock rules to be there.
ns_apply() { # plan-file log-file
  ns -v "$CLI:/usr/local/bin/stalwart-cli:ro" -v "$1:/plan.ndjson:ro" \
     -e HOME=/tmp -e STALWART_URL=http://127.0.0.1:8081 -e STALWART_USER="$ADMIN_USER" -e STALWART_PASSWORD="$ADMIN_PASS" \
     --entrypoint stalwart-cli "$IMAGE" --no-color apply --file /plan.ndjson > "$2" 2>&1
}
cli_q() { ns -v "$CLI:/usr/local/bin/stalwart-cli:ro" -e HOME=/tmp -e STALWART_URL=http://127.0.0.1:8081 \
  -e STALWART_USER="$ADMIN_USER" -e STALWART_PASSWORD="$ADMIN_PASS" --entrypoint stalwart-cli "$IMAGE" --no-color query "$@"; }
if ns_apply "$WORK/plan.ndjson" "$WORK/plan-apply.log"; then pass admin_cli_netns
else fail admin_cli_netns "full plan through stalwart-cli in the container namespace: $(tail -3 "$WORK/plan-apply.log")"; fi
for _ in $(seq 1 60); do [ "$(cli_q SpamRule | grep -c STWT_)" -gt 10 ] && break; sleep 2; done
sleep 5 # the first start's own download and the plan's updateRules may both land
cli_q SpamRule | awk 'NR > 1 && NF { print $2 }' > "$WORK/rules.txt"
if [ "$(grep -c STWT_ "$WORK/rules.txt")" -gt 10 ] && grep -qx IAC_JUNK_PROBE "$WORK/rules.txt" \
   && [ -z "$(sort "$WORK/rules.txt" | uniq -d)" ]; then pass stock_rules_loaded
else fail stock_rules_loaded "$(grep -c STWT_ "$WORK/rules.txt") stock rules, duplicates: $(sort "$WORK/rules.txt" | uniq -d | head -3 | tr '\n' ' ')"; fi

# Lab-only overlay: mail from the reserved sender.test domain plays a reputable sender
# (lab mail scores ~11 on missing rDNS/SPF/DMARC alone, i.e. Junk), so the routing
# checks can expect INBOX while strangers still get scored normally.
cat > "$WORK/overlay.ndjson" <<'EOF'
{"@type":"upsert","object":"SpamRule","matchOn":["name"],"value":{"r-lab":{"@type":"Any","name":"SMOKE_LAB_SENDER","priority":5000,"condition":{"match":{"0":{"if":"from.domain == 'sender.test'","then":"'SMOKE_LAB_SENDER'"}},"else":"false"}}}}
{"@type":"upsert","object":"SpamTag","matchOn":["tag"],"value":{"t-lab":{"@type":"Score","tag":"SMOKE_LAB_SENDER","score":-50.0}}}
{"@type":"create","object":"Action","value":{"reload":{"@type":"ReloadSettings"}}}
EOF
chmod 0644 "$WORK/overlay.ndjson"
ns_apply "$WORK/overlay.ndjson" "$WORK/overlay.log" || { echo "lab overlay failed:"; sed 's/^/  /' "$WORK/overlay.log"; }

# --- mail-flow assertions (python stdlib + openssl) ----------------------------
python3 -I - "$P_SMTP" "$P_SUBS" "$P_IMAPS" "$DKIM_PUB" \
  "$NOREPLY_PASS" "$JASON_PASS" <<'PYEOF' || FAILED=1
import base64, hashlib, imaplib, re, secrets, smtplib, ssl, subprocess, sys, tempfile, time
from email.utils import formatdate, make_msgid

p_smtp, p_subs, p_imaps, pubkey, noreply_pw, jason_pw = sys.argv[1:7]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
failed = False

def report(name, ok, why=""):
    global failed
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else ": " + why))
    failed |= not ok

def run(name, fn):
    try:
        ok, why = fn()
    except Exception as e:  # any connection/protocol error is a failure of that check
        ok, why = False, f"{type(e).__name__}: {e}"
    report(name, ok, why)

def msg(frm, to, subject, body="Hello, this is an ordinary test message.\r\n"):
    return (f"From: <{frm}>\r\nTo: <{to}>\r\nSubject: {subject}\r\nDate: {formatdate()}\r\n"
            f"Message-ID: {make_msgid(domain='sender.test')}\r\n\r\n{body}").encode()

def inbound(to, subject, frm="someone@sender.test"):  # unauthenticated, like a remote MTA on port 25
    s = smtplib.SMTP("127.0.0.1", int(p_smtp), local_hostname="client.sender.test", timeout=30)
    try:
        s.sendmail(frm, [to], msg(frm, to, subject))
    finally:
        s.quit()

def find(folder, token, wait=30):  # raw message whose Subject contains token, or None
    for _ in range(wait):
        m = imaplib.IMAP4_SSL("127.0.0.1", int(p_imaps), ssl_context=ctx, timeout=30)
        m.login("jason@rustd.xyz", jason_pw)
        typ, _ = m.select(folder, readonly=True)
        if typ == "OK":
            _, d = m.search(None, "SUBJECT", token)
            if d[0]:
                raw = m.fetch(d[0].split()[-1], "(BODY.PEEK[])")[1][0][1]
                m.logout(); return raw
        m.logout(); time.sleep(1)
    return None

def smtp_auth():
    s = smtplib.SMTP_SSL("127.0.0.1", int(p_subs), context=ctx, timeout=30)
    code, _ = s.login("noreply@rustd.xyz", noreply_pw); s.quit()
    return code == 235, f"AUTH answered {code}"

def imap_login():
    m = imaplib.IMAP4_SSL("127.0.0.1", int(p_imaps), ssl_context=ctx, timeout=30)
    typ, _ = m.login("jason@rustd.xyz", jason_pw); m.logout()
    return typ == "OK", typ

def lands(to):
    def check():
        tok = "smoke-" + secrets.token_hex(4)
        inbound(to, tok)
        return find("INBOX", tok) is not None, f"{tok} to {to} not in jason@rustd.xyz INBOX"
    return check

def dkim_verify(raw, pub):
    head, _, body = raw.partition(b"\r\n\r\n")
    hdrs = [h for h in re.split(rb"\r\n(?![ \t])", head) if h]
    sig_hdr = next(h for h in hdrs if h.lower().startswith(b"dkim-signature:"))
    tags = dict(t.strip().split("=", 1) for t in re.sub(r"\s+", "", sig_hdr.split(b":", 1)[1].decode()).split(";") if t)
    want = {"s": "dkim", "d": "rustd.xyz", "a": "rsa-sha256", "c": "relaxed/relaxed"}
    if any(tags.get(k) != v for k, v in want.items()):
        return False, f"tags {tags}"
    def relax_hdr(h):
        k, v = h.split(b":", 1)
        return k.strip().lower() + b":" + re.sub(rb"[ \t]+", b" ", re.sub(rb"\r\n", b"", v)).strip() + b"\r\n"
    lines = [re.sub(rb"[ \t]+", b" ", l).rstrip(b" \t") for l in body.split(b"\r\n")]
    while lines and lines[-1] == b"": lines.pop()
    cbody = b"".join(l + b"\r\n" for l in lines)
    if base64.b64encode(hashlib.sha256(cbody).digest()).decode() != tags["bh"]:
        return False, "body hash mismatch"
    data, pool = b"", list(hdrs)
    for name in tags["h"].split(":"):
        for h in reversed(pool):
            if h.split(b":", 1)[0].strip().lower() == name.lower().encode():
                data += relax_hdr(h); pool.remove(h); break
    data += relax_hdr(re.sub(rb"(\bb=)[^;]*", rb"\1", sig_hdr)).rstrip(b"\r\n")
    with tempfile.TemporaryDirectory() as t:
        open(f"{t}/d", "wb").write(data); open(f"{t}/s", "wb").write(base64.b64decode(tags["b"]))
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", f"{t}/s", f"{t}/d"],
                           capture_output=True)
    return r.returncode == 0, "signature does not verify against fixture public key"

def dkim_signed():
    tok = "smoke-dkim-" + secrets.token_hex(4)
    s = smtplib.SMTP_SSL("127.0.0.1", int(p_subs), context=ctx, timeout=30)
    s.login("noreply@rustd.xyz", noreply_pw)
    s.sendmail("noreply@rustd.xyz", ["jason@rustd.xyz"], msg("noreply@rustd.xyz", "jason@rustd.xyz", tok))
    s.quit()
    raw = find("INBOX", tok)
    if raw is None:
        return False, "submitted message not delivered"
    return dkim_verify(raw, pubkey)

def junk_probe():  # a stranger's lab mail scores between scoreSpam and scoreReject
    tok = "smoke-junk-" + secrets.token_hex(4)
    inbound("jason@rustd.xyz", tok, frm="stranger@other.test")
    raw = find("Junk", tok)
    if raw is None:
        return False, f"{tok} not filed in Junk"
    score = float(re.search(rb"X-Spam-Score: spam, score=([-\d.]+)", raw).group(1))
    return 5.0 <= score < 15.0, f"score {score} outside [scoreSpam 5, scoreReject 15)"

def gtube_reject():  # high confidence -> refused at SMTP time (GTUBE is matched on Subject)
    try:
        inbound("jason@rustd.xyz", "XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X",
                frm="stranger@other.test")
    except smtplib.SMTPDataError as e:
        return 500 <= e.smtp_code < 600, f"DATA answered {e.smtp_code}"
    return False, "GTUBE was accepted"

run("smtp_auth", smtp_auth)
run("imap_login", imap_login)
run("catchall", lands(f"nobody-{secrets.token_hex(4)}@rustd.xyz"))
run("alias", lands("contact@rustd.xyz"))
run("dkim_signed", dkim_signed)
run("junk_probe", junk_probe)
run("gtube_reject", gtube_reject)
sys.exit(1 if failed else 0)
PYEOF

# --- TLS: served cert for SNI mail.rustd.xyz is the fixture --------------------
want=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256)
got=$(openssl s_client -connect "127.0.0.1:$P_IMAPS" -servername mail.rustd.xyz </dev/null 2>/dev/null \
      | openssl x509 -noout -fingerprint -sha256 2>/dev/null)
if [ -n "$got" ] && [ "$got" = "$want" ]; then pass cert_file; else fail cert_file "${got:-no certificate}"; fi

# --- cert_renewal: a renewal (new files swapped in under the symlinks, as acme-companion
# does) reaches 465 and 993 without a restart. The local smoke cannot run systemd, so this
# runs the exact ExecStart of the role's rendered stalwart-cert-reload.service (the CLI
# container in the Stalwart netns, credentials from cli.env) and validates the units.
mkdir -p "$WORK/opt/etc" "$WORK/systemd"
cp "$WORK/plan.ndjson" "$WORK/opt/etc/plan.ndjson"
printf 'STALWART_USER=%s\nSTALWART_PASSWORD=%s\n' "$ADMIN_USER" "$ADMIN_PASS" > "$WORK/opt/cli.env"
for u in service path; do
  (cd "$WORK" && ANSIBLE_LOCALHOST_WARNING=false ansible localhost -c local -i localhost, -m ansible.builtin.template \
    -a "src=$ROLE/templates/stalwart-cert-reload.$u.j2 dest=$WORK/systemd/stalwart-cert-reload.$u mode=0644" \
    -e "@$ROLE/defaults/main.yml" -e "stalwart_install_path=$WORK/opt" -e "stalwart_cli_path=$CLI" \
    -e "stalwart_certs_dir=$WORK/certs" >"$WORK/render.log" 2>&1) || { echo "cannot render the $u unit"; exit 2; }
done
RELOAD=$(sed -n 's/^ExecStart=//p' "$WORK/systemd/stalwart-cert-reload.service")
# The Stalwart container here is not named `stalwart`, as it is on the droplet.
RELOAD=${RELOAD//container:stalwart /container:$NAME }
fp() { openssl s_client -connect "127.0.0.1:$1" -servername mail.rustd.xyz </dev/null 2>/dev/null \
       | openssl x509 -noout -fingerprint -sha256 2>/dev/null; }
before_imaps=$(fp "$P_IMAPS"); before_subs=$(fp "$P_SUBS")
newcert "$CERTDIR/fullchain.pem.new" "$CERTDIR/key.pem.new"
chmod 0644 "$CERTDIR"/*.new
mv "$CERTDIR/fullchain.pem.new" "$CERTDIR/fullchain.pem"; mv "$CERTDIR/key.pem.new" "$CERTDIR/key.pem"
want=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256)
$RELOAD >/dev/null 2>&1 || echo "note: the unit's ExecStart exited $?"
ok=0
for _ in $(seq 1 120); do
  [ "$(fp "$P_IMAPS")" = "$want" ] && [ "$(fp "$P_SUBS")" = "$want" ] && { ok=1; break; }
  sleep 1
done
if [ $ok = 1 ] && [ -n "$before_imaps" ] && [ "$before_imaps" = "$before_subs" ] && [ "$before_imaps" != "$want" ]; then pass cert_renewal
else fail cert_renewal "993=$(fp "$P_IMAPS") 465=$(fp "$P_SUBS") want=$want"; fi
# The units must be valid and the .path must watch the real files, not the symlinks.
if [ "$(grep -c '^PathChanged=' "$WORK/systemd/stalwart-cert-reload.path")" = 2 ] \
   && grep -qx "PathChanged=$CERTDIR/fullchain.pem" "$WORK/systemd/stalwart-cert-reload.path" \
   && grep -qx "PathChanged=$CERTDIR/key.pem" "$WORK/systemd/stalwart-cert-reload.path" \
   && { ! command -v systemd-analyze >/dev/null || systemd-analyze verify --man=no \
        "$WORK/systemd/stalwart-cert-reload.path" "$WORK/systemd/stalwart-cert-reload.service" 2>"$WORK/verify.log" \
        || ! grep -v 'docker.service\|not-found' "$WORK/verify.log" | grep -q .; }; then pass cert_units
else fail cert_units "$(cat "$WORK/verify.log" 2>/dev/null)"; fi

# --- webmail: Bulwark's index.html under /webmail/ (Stalwart fetches the zip at start)
ok=0
for _ in $(seq 1 90); do
  if curl -fs "$PUB/webmail/" -o "$WORK/webmail.html" && grep -qi 'bulwark' "$WORK/webmail.html"; then ok=1; break; fi
  sleep 2
done
if [ $ok = 1 ]; then pass webmail; else fail webmail "GET /webmail/ is not Bulwark's index.html"; fi

# --- no_recovery: the recovery credential is refused (an HTTP 401, not a dead port)
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$RECOVERY_ADMIN" "$PUB/jmap/session")
if [ "$code" = 401 ]; then pass no_recovery; else fail no_recovery "HTTP $code"; fi

# --- admin restriction ----------------------------------------------------------
# The admin credential's allowedIps is 127.0.0.1 only. A sidecar container plays
# nginx-proxy (public traffic on 8080), and the host's published port plays anything
# arriving through docker's gateway (docker-proxy, hairpin, IPv6 without NAT): both
# must be refused. Only the container's own namespace (ns) gets in.
sidecar() { docker run --rm --entrypoint curl "$IMAGE" -s -o /dev/null -w '%{http_code}' "$@"; }
adm=$(ns_curl -o /dev/null -w '%{http_code}' -u "$ADMIN_USER:$ADMIN_PASS" http://127.0.0.1:8081/jmap/session)
gw=$(curl -s -o /dev/null -w '%{http_code}' -u "$ADMIN_USER:$ADMIN_PASS" "$ADM/jmap/session")
pub=$(sidecar -u "$ADMIN_USER:$ADMIN_PASS" "http://$CIP:8080/jmap/session")
usr=$(sidecar -u "jason@rustd.xyz:$JASON_PASS" "http://$CIP:8080/jmap/session")
if [ "$adm" = 200 ] && [ "$gw" = 403 ] && [ "$pub" = 403 ] && [ "$usr" = 200 ]; then pass admin_ip_restricted
else fail admin_ip_restricted "admin in-namespace=$adm (want 200), via docker gateway=$gw (want 403), via proxy=$pub (want 403), jason via proxy=$usr (want 200)"; fi

# allowedIps is per credential. App passwords and API keys would be credentials
# without it, so the plan gives the admin quotas of 0 for both (and a Password
# credential is the only other kind; an account can hold just one).
extra=$(ns_curl -u "$ADMIN_USER:$ADMIN_PASS" -H 'Content-Type: application/json' -d '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:AppPassword/set",{"create":{"k":{"description":"smoke","permissions":{"@type":"Inherit"}}}},"0"],["x:ApiKey/set",{"create":{"k":{"description":"smoke","permissions":{"@type":"Inherit"}}}},"1"]]}' http://127.0.0.1:8081/jmap)
if [ "$(grep -o '"type":"overQuota"' <<<"$extra" | wc -l)" = 2 ] && ! grep -q '"created"' <<<"$extra"; then pass admin_no_extra_credentials
else fail admin_no_extra_credentials "${extra:0:300}"; fi

# The web admin loads on the 8081 listener only; the public 8080 listener (nginx-proxy's
# upstream) refuses it by path, and refuses the admin's login by source IP ($pub above).
ui_pub=$(for u in /admin /ADMIN /Admin/ /account/ /ACCOUNT; do printf '%s=%s ' "$u" "$(sidecar "http://$CIP:8080$u")"; done)
ui_adm=$(curl -s -o /dev/null -w '%{http_code}' "$ADM/admin/") # /admin 302s here
if [ "$ui_pub" = "/admin=403 /ADMIN=403 /Admin/=403 /account/=403 /ACCOUNT=403 " ] && [ "$ui_adm" = 200 ] && [ "$pub" = 403 ]; then pass admin_listener
else fail admin_listener "public: ${ui_pub}(want all 403), admin listener=$ui_adm (want 200), admin login via 8080=$pub (want 403)"; fi

# A human on the tailnet: allowedIps carries 100.64.0.0/10. A sidecar with a 100.64/10
# address on a bridge shared with the container (L2, no NAT) plays a tailnet client that
# reached 8081 with its source intact; the same login from the docker gateway is refused.
docker network create --subnet 100.126.250.0/24 "$NAME-tn" >/dev/null && docker network connect "$NAME-tn" "$NAME"
TIP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NAME-tn\").IPAddress}}" "$NAME")
tn=$(docker run --rm --network "$NAME-tn" --entrypoint curl "$IMAGE" -s -o /dev/null -w '%{http_code}' -u "$ADMIN_USER:$ADMIN_PASS" "http://$TIP:8081/jmap/session")
if [ "$tn" = 200 ] && [ "$gw" = 403 ]; then pass admin_tailnet_range
else fail admin_tailnet_range "admin from 100.126.250.x=$tn (want 200), via docker gateway=$gw (want 403)"; fi

# The plan's IAC_JUNK_PROBE rule fires (on top of the stock rules) for its Subject token
# and not without it. ClassifySpam reports the tags; the CLI's `create` cannot show them.
classify() { # subject -> JSON response
  ns_curl -u "$ADMIN_USER:$ADMIN_PASS" -H 'Content-Type: application/json' -d "$(python3 -I -c '
import json, sys
m = "From: <a@other.test>\r\nTo: <jason@rustd.xyz>\r\nSubject: " + sys.argv[1] + "\r\n\r\nhi\r\n"
print(json.dumps({"using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"], "methodCalls": [["x:Action/set", {"create": {"c": {
    "@type": "ClassifySpam", "message": m, "remoteIp": "203.0.113.9", "ehloDomain": "mx.other.test",
    "envFrom": "a@other.test", "envRcptTo": {"jason@rustd.xyz": True}, "isTls": False}}}, "0"]]}))' "$1")" http://127.0.0.1:8081/jmap
}
probe=$(classify "Weekly iac-junk-probe 1234"); control=$(classify "Weekly report 1234")
if grep -q '"IAC_JUNK_PROBE":{"score":8.0' <<<"${probe// /}" && grep -q '"MISSING_MID"' <<<"$probe" \
   && grep -q '"created"' <<<"$control" && ! grep -q IAC_JUNK_PROBE <<<"$control"; then pass junk_probe_rule
else fail junk_probe_rule "probe=${probe:0:200} control=${control:0:200}"; fi

# Re-applying the unchanged plan creates nothing but its updateRules task and ReloadSettings action, and
# leaves every object it names with the same ids (no duplicates). Ids only: the CLI's
# column headers vary between runs.
snap() { for o in Domain Certificate DkimSignature Account NetworkListener Tracer MtaInboundThrottle SpamRule SpamTag; do
  cli_q "$o" | awk -v o="$o" 'NR > 1 && NF { print o, $1 }'
done; }
snap > "$WORK/before.txt" 2>&1
ns_apply "$WORK/plan.ndjson" "$WORK/reapply.log"; rc=$?
sleep 5 # let updateRules finish: re-downloaded stock rules must keep their ids
snap > "$WORK/after.txt" 2>&1
creates=$(grep -c '"@type": "create"' "$WORK/plan.ndjson") # Task + Action, new every apply
if [ $rc = 0 ] && grep -q ", $creates created (0 failed)" "$WORK/reapply.log" && cmp -s "$WORK/before.txt" "$WORK/after.txt" \
   && [ "$(grep -c . "$WORK/before.txt")" -gt 9 ]; then pass reapply_idempotent
else fail reapply_idempotent "rc=$rc $(tail -1 "$WORK/reapply.log"); $(diff "$WORK/before.txt" "$WORK/after.txt" | head -5)"; fi

# --- backup_restore: the role's nightly script, run for real ------------------------
# The script is rendered from templates/stalwart-backup.sh.j2 with only paths, the container
# name and the NAS coordinates substituted (a local rsync daemon plays the NAS). A message
# is delivered first; the script pauses the container, tars data/, pushes etc/ and dkim/
# and then the snapshot; a second container started from that snapshot must still log
# jason@rustd.xyz in and hold the message. The etc/ mirror must carry no password-bearing
# file, and the snapshot must be the last thing uploaded.
bk_tok="smoke-backup-$RANDOM$RANDOM"
bk_py() { # mode smtp-port imaps-port token password: log in as jason, wait for the token in INBOX
  python3 -I - "$@" <<'PYEOF'
import imaplib, smtplib, ssl, sys, time
mode, smtp, imaps, tok, pw = sys.argv[1:6]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
if mode == "send":
    s = smtplib.SMTP("127.0.0.1", int(smtp), local_hostname="client.sender.test", timeout=30)
    s.sendmail("someone@sender.test", ["jason@rustd.xyz"],
               f"From: <someone@sender.test>\r\nTo: <jason@rustd.xyz>\r\nSubject: {tok}\r\n\r\nbackup test\r\n".encode())
    s.quit()
for _ in range(90):
    try:
        m = imaplib.IMAP4_SSL("127.0.0.1", int(imaps), ssl_context=ctx, timeout=30)
        m.login("jason@rustd.xyz", pw)
        if m.select("INBOX", readonly=True)[0] == "OK" and m.search(None, "SUBJECT", tok)[1][0]:
            sys.exit(0)
        m.logout()
    except Exception:
        pass
    time.sleep(1)
sys.exit(1)
PYEOF
}
BK_OK=1
bk_fail() { fail backup_restore "$1"; BK_OK=0; }
bk_py send "$P_SMTP" "$P_IMAPS" "$bk_tok" "$JASON_PASS" || bk_fail "test message never reached the live server"
mkdir -p "$WORK/opt/etc" "$WORK/opt/dkim" "$WORK/opt/backups" "$WORK/nas"
# backups/ is owned by UID 2000 like the role makes it (the tar runs as that user); 0777 here
# only so this non-root test can also write it, where the real script runs as root.
bk_mode() { docker run --rm --user 0 -v "$WORK/opt/backups:/d" --entrypoint chmod "$IMAGE" "$1" /d; }
docker run --rm --user 0 -v "$WORK/opt/backups:/d" --entrypoint chown "$IMAGE" 2000:2000 /d; bk_mode 0777
cp "$WORK"/etc/config.json "$WORK/opt/etc/"; cp "$WORK"/dkim/* "$WORK/opt/dkim/"
# Things that must never reach the NAS: the plans hold every mailbox password, env files and
# logs may. Decoys sit in etc/ (mirrored); the cli env files sit beside it (not mirrored).
cp "$WORK/plan.ndjson" "$WORK/opt/etc/plan.ndjson"; cp "$WORK/bootstrap.ndjson" "$WORK/opt/etc/bootstrap.ndjson"
echo "STALWART_PASSWORD=$ADMIN_PASS" > "$WORK/opt/etc/decoy.env"; echo "password $ADMIN_PASS" > "$WORK/opt/etc/decoy.log"
echo "STALWART_PASSWORD=$ADMIN_PASS" > "$WORK/opt/cli.env"; echo "STALWART_PASSWORD=$ADMIN_PASS" > "$WORK/opt/bootstrap-cli.env"
echo "kept" > "$WORK/opt/etc/plan.applied.sha256"
# A local rsync daemon as the NAS: module `storage`, user svcbackup, transfers logged in order.
NAS_PORT=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
echo "svcbackup:nas-fixture-pw" > "$WORK/rsyncd.secrets"; echo "nas-fixture-pw" > "$WORK/rsync.pass"
chmod 0600 "$WORK/rsyncd.secrets" "$WORK/rsync.pass"
cat > "$WORK/rsyncd.conf" <<EOF
address = 127.0.0.1
port = $NAS_PORT
pid file = $WORK/rsyncd.pid
log file = $WORK/rsyncd.log
transfer logging = yes
log format = %f
use chroot = no
[storage]
path = $WORK/nas
read only = no
auth users = svcbackup
secrets file = $WORK/rsyncd.secrets
EOF
rsync --daemon --config="$WORK/rsyncd.conf" --no-detach >/dev/null 2>&1 &
RSYNCD_PID=$!
sleep 1
bk_render() { # dest [extra ansible -e args]: only paths, names and the NAS coordinates differ from the role's
  local dest=$1; shift
  (cd "$WORK" && ANSIBLE_LOCALHOST_WARNING=false ansible localhost -c local -i localhost, -m ansible.builtin.template \
    -a "src=$ROLE/templates/stalwart-backup.sh.j2 dest=$dest mode=0700" \
    -e "@$ROLE/defaults/main.yml" -e "stalwart_install_path=$WORK/opt" -e "stalwart_backup_container=$NAME" \
    -e "stalwart_backup_nas_keep=30" -e "stalwart_backup_nas_host=127.0.0.1" -e "stalwart_backup_nas_rsync_port=$NAS_PORT" \
    -e "stalwart_backup_rsync_password_file=$WORK/rsync.pass" "$@" >"$WORK/render.log" 2>&1)
}
bk_render "$WORK/stalwart-backup.sh" || bk_fail "cannot render stalwart-backup.sh.j2: $(tail -3 "$WORK/render.log")"

# A failed or hung snapshot must never leave stalwart paused (a total mail outage), the
# throwaway container running, or a .tmp file on disk. Each case: non-zero exit, container
# running and not paused, no snapshot container, no .tmp. Nothing may have reached the NAS.
bk_aftermath() { # case-name exit-code
  local st
  st=$(docker inspect -f '{{.State.Running}} {{.State.Paused}}' "$NAME")
  [ "$2" != 0 ] || bk_fail "$1: the script exited 0"
  [ "$st" = "true false" ] || bk_fail "$1: stalwart is '$st' (want running, not paused)"
  [ -z "$(docker ps -aq --filter name=stalwart-backup-)" ] || bk_fail "$1: the snapshot container is still there"
  [ -z "$(ls "$WORK"/opt/backups/*.tmp 2>/dev/null)" ] || bk_fail "$1: left $(ls "$WORK"/opt/backups | tr '\n' ' ')"
  [ ! -e "$WORK/nas/backups" ] || bk_fail "$1: pushed to the NAS after a failed snapshot"
}
if [ $BK_OK = 1 ]; then
  # tar fails inside the pause: backups/ is not writable for UID 2000
  bk_mode 0555; bash "$WORK/stalwart-backup.sh" >"$WORK/backup-fail.log" 2>&1; rc=$?; bk_mode 0777
  bk_aftermath tar_fails $rc
  # tar hangs past the bound: a 0.05 s timeout cannot even start the container
  bk_render "$WORK/stalwart-backup-slow.sh" -e stalwart_backup_pause_timeout=0.05 || bk_fail "cannot render the timeout variant"
  bash "$WORK/stalwart-backup-slow.sh" >"$WORK/backup-slow.log" 2>&1; rc=$?
  bk_aftermath tar_times_out $rc
  # tar hangs for real and ignores TERM: a `docker` shim turns the snapshot `docker run` into
  # `sleep 600` as PID 1 (no init, so TERM is ignored), under a 3 s bound. The script must
  # still get out (timeout -k), thaw and clean up; the outer timeout makes a regression fail
  # this check instead of hanging the suite.
  mkdir -p "$WORK/dshim"
  printf '#!/bin/sh\nif [ "$1" = run ]; then\n  for a in "$@"; do [ "$p" = --name ] && n=$a; p=$a; done\n  exec %s run --rm --name "$n" --entrypoint sleep "%s" 600\nfi\nexec %s "$@"\n' \
    "$(command -v docker)" "$IMAGE" "$(command -v docker)" > "$WORK/dshim/docker"
  chmod +x "$WORK/dshim/docker"
  bk_render "$WORK/stalwart-backup-hang.sh" -e stalwart_backup_pause_timeout=3 || bk_fail "cannot render the hang variant"
  t0=$SECONDS
  PATH="$WORK/dshim:$PATH" timeout -k 5 60 bash "$WORK/stalwart-backup-hang.sh" >"$WORK/backup-hang.log" 2>&1; rc=$?
  [ $((SECONDS - t0)) -lt 30 ] || bk_fail "tar_hangs: the script took $((SECONDS - t0)) s to give up (want < 30)"
  bk_aftermath tar_hangs $rc
  # hygiene only: after a regression the next cases still run
  docker rm -f $(docker ps -aq --filter name=stalwart-backup-) >/dev/null 2>&1
  docker unpause "$NAME" >/dev/null 2>&1
  # gzip dies partway after the thaw (a full disk): a shim leaves a partial .tmp behind
  mkdir -p "$WORK/shim"; printf '#!/bin/sh\nhead -c 1000 /dev/zero\nexit 1\n' > "$WORK/shim/gzip"; chmod +x "$WORK/shim/gzip"
  PATH="$WORK/shim:$PATH" bash "$WORK/stalwart-backup.sh" >"$WORK/backup-gzip.log" 2>&1; rc=$?
  bk_aftermath gzip_fails $rc
fi
if [ $BK_OK = 1 ]; then
  bash "$WORK/stalwart-backup.sh" > "$WORK/backup.log" 2>&1 || bk_fail "script exited $?: $(tail -5 "$WORK/backup.log")"
  [ "$(docker inspect -f '{{.State.Paused}}' "$NAME")" = false ] || bk_fail "container left paused"
fi
if [ $BK_OK = 1 ]; then
  SNAP=$(ls "$WORK"/nas/backups/stalwart/db/stalwart-*.tar.gz 2>/dev/null | head -1)
  [ -n "$SNAP" ] || bk_fail "no stalwart-*.tar.gz under <module>/backups/stalwart/db/"
fi
if [ $BK_OK = 1 ]; then
  # Restore: extract as UID 2000 into a fresh dir, boot a second container on it.
  mkdir -p "$WORK/restore"
  docker run --rm --user 0 -v "$WORK/restore:/d" -v "$SNAP:/snap.tar.gz:ro" --entrypoint sh "$IMAGE" -c \
    'tar xzf /snap.tar.gz -C /d && chown -R 2000:2000 /d' || bk_fail "cannot extract $SNAP"
  docker run -d --name "$NAME-rst" -v "$WORK/restore:/var/lib/stalwart" -v "$WORK/etc:/etc/stalwart:ro" \
    -v "$WORK/certs:/certs:ro" -v "$WORK/dkim:/dkim:ro" -e STALWART_PUBLIC_URL=https://smoke.invalid \
    -p 127.0.0.1::993 "$IMAGE" >/dev/null
  bk_py check x "$(hostport "$NAME-rst" 993)" "$bk_tok" "$JASON_PASS" \
    || bk_fail "restored server: jason@rustd.xyz login or the message ($bk_tok) is missing"
fi
if [ $BK_OK = 1 ]; then
  leaked=$(find "$WORK/nas" \( -name '*.ndjson' -o -name '*.env' -o -name '*.log' \) | head -3 | tr '\n' ' ')
  if grep -rlF "$ADMIN_PASS" "$WORK/nas" >/dev/null 2>&1; then leaked="$leaked(admin password found) "; fi
  [ -z "$leaked" ] || bk_fail "password-bearing files reached the NAS: $leaked"
  [ -f "$WORK/nas/backups/stalwart/etc/config.json" ] && [ -f "$WORK/nas/backups/stalwart/etc/plan.applied.sha256" ] \
    && [ -f "$WORK/nas/backups/stalwart/dkim/rustd.xyz.dkim.key" ] || bk_fail "etc/ or dkim/ mirror is incomplete"
  last=$(grep 'backups/stalwart/' "$WORK/rsyncd.log" | tail -1)
  grep -q 'backups/stalwart/db/stalwart-.*\.tar\.gz$' <<<"$last" || bk_fail "the snapshot was not the last transfer: $last"
fi
[ $BK_OK = 1 ] && pass backup_restore

# Last, because it bans an address for good. 105 bad logins (authBanRate 100/day) and 31
# *.php requests (scanBanRate 30/day), then a good login, from each network: the exempt one
# (nginx-proxy's) must still get in; the other must be banned (connection refused), so
# direct clients are still throttled by Stalwart.
hammer() { # network -> HTTP code of a good login after the burst
  local ip; ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$1\").IPAddress}}" "$NAME")
  docker run --rm --network "$1" --entrypoint sh "$IMAGE" -c '
    for i in $(seq 105); do curl -s -o /dev/null -u jason@rustd.xyz:wrong "http://$0:8080/jmap/session"; done
    for i in $(seq 31); do curl -s -o /dev/null "http://$0:8080/x$i.php"; done
    curl -s -o /dev/null -w "%{http_code}" -u "jason@rustd.xyz:$1" "http://$0:8080/jmap/session"' "$ip" "$JASON_PASS"
}
px=$(hammer "$NAME-px"); nx=$(hammer "$NAME-nx")
if [ "$px" = 200 ] && [ "$nx" = 000 ]; then pass ban_exempt_proxy
else fail ban_exempt_proxy "good login after the burst: proxy network=$px (want 200), other network=$nx (want 000, banned)"; fi

if [ $FAILED = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; docker logs "$NAME" 2>&1 | tail -40; fi
exit $FAILED
