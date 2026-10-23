#!/usr/bin/env bash
# Local test of the role's nginx-proxy side, in front of a real Stalwart.
#
#   bash ansible/roles/stalwart/tests/local-nginx.sh
#
# Runs local-smoke.sh with SMOKE_KEEP=1 for a Stalwart with the role's plan (its -px network
# is the ban-exempt one, as nginx-proxy's is in production), renders the role's vhost.d and
# conf.d templates, and starts a throwaway jwilder/nginx-proxy (the production image) on that
# network with per-host self-signed certs, so the HTTPS server blocks are generated. A relay
# container carries VIRTUAL_HOST for the four mail.* names and forwards to Stalwart's 8080.
# Every request is pinned to the local proxy (curl --connect-to / --resolve), never DNS.
# Local Docker only; passwords are the smoke's fixture constants. Exit 0 = all pass.
set -uo pipefail

ROLE=$(cd "$(dirname "$0")/.." && pwd)
IMG=jwilder/nginx-proxy
HOSTS="mail.jasonernst.com mail.sair.run mail.rustd.xyz mail.darksearch.xyz"
JASON_PASS="jason-fixture-Pw-7731" # local-smoke.sh's
WORK=$(mktemp -d)
ST=; SMOKE_FILES=

cleanup() {
  docker rm -f "np-proxy-$$" "np-relay-$$" >/dev/null 2>&1
  if [ -n "$ST" ]; then
    docker rm -f "$ST" >/dev/null 2>&1; docker volume rm "$ST-data" >/dev/null 2>&1
    docker network rm "$ST-tn" "$ST-px" "$ST-nx" >/dev/null 2>&1
  fi
  [ -n "$SMOKE_FILES" ] && rm -rf "$SMOKE_FILES"
  rm -rf "$WORK"
}
trap cleanup EXIT

SMOKE_KEEP=1 bash "$ROLE/tests/local-smoke.sh" > "$WORK/smoke.log" 2>&1
read -r ST SMOKE_FILES < <(sed -n 's/^SMOKE_KEEP: left \(stalwart-smoke-[0-9]*\) running .*files \([^)]*\))$/\1 \2/p' "$WORK/smoke.log")
grep -q '^ALL PASS' "$WORK/smoke.log" && [ -n "$ST" ] || { echo "smoke failed:"; grep -E '^(FAIL|SOME)' "$WORK/smoke.log"; exit 2; }
NET="$ST-px"

# --- the role's files, rendered with its defaults --------------------------------
mkdir -p "$WORK/vhost.d" "$WORK/certs"
render() { # template dest [item]
  ANSIBLE_LOCALHOST_WARNING=false ansible localhost -c local -i localhost, -m ansible.builtin.template \
    -a "src=$ROLE/templates/$1 dest=$2 mode=0644" -e "@$ROLE/defaults/main.yml" ${3:+-e item=$3} >/dev/null 2>&1 \
    || { echo "cannot render $1"; exit 2; }
}
for h in $HOSTS; do
  render "vhost-$([ "$h" = mail.jasonernst.com ] && echo primary || echo secondary).conf.j2" "$WORK/vhost.d/$h" "$h"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$h" -keyout "$WORK/certs/$h.key" -out "$WORK/certs/$h.crt" 2>/dev/null
done
render nginx-stalwart.conf.j2 "$WORK/stalwart.conf"
chmod 0755 "$WORK" "$WORK/vhost.d" "$WORK/certs"; chmod 0644 "$WORK"/certs/* "$WORK"/vhost.d/* "$WORK/stalwart.conf"

SIP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$ST")
printf 'events{} http{ server { listen 8080; location / { proxy_pass http://%s:8080; proxy_set_header Host $host; } } }\n' "$SIP" > "$WORK/relay.conf"
chmod 0644 "$WORK/relay.conf"
docker run -d --name "np-relay-$$" --network "$NET" -e VIRTUAL_HOST="${HOSTS// /,}" -e VIRTUAL_PORT=8080 \
  -v "$WORK/relay.conf:/r.conf:ro" --entrypoint nginx "$IMG" -c /r.conf -g 'daemon off;' >/dev/null
docker run -d --name "np-proxy-$$" --network "$NET" -p 127.0.0.1::443 -p 127.0.0.1::80 \
  -v "$WORK/vhost.d:/etc/nginx/vhost.d:ro" -v "$WORK/stalwart.conf:/etc/nginx/conf.d/stalwart.conf:ro" \
  -v "$WORK/certs:/etc/nginx/certs:ro" -v /var/run/docker.sock:/tmp/docker.sock:ro "$IMG" >/dev/null
for _ in $(seq 30); do docker exec "np-proxy-$$" grep -q 'server_name mail.darksearch.xyz' /etc/nginx/conf.d/default.conf 2>/dev/null && break; sleep 1; done
P=$(docker port "np-proxy-$$" 443 | head -1 | sed 's/.*://'); P80=$(docker port "np-proxy-$$" 80 | head -1 | sed 's/.*://')
# An empty port would let curl fall through to public DNS, i.e. the real hosts.
[ -n "$P" ] && [ -n "$P80" ] || { echo "no proxy port; stopping before any request"; docker logs "np-proxy-$$" 2>&1 | tail -5; exit 2; }
docker exec "np-proxy-$$" nginx -t >/dev/null 2>&1 && echo "PASS nginx_config_valid" || { echo "FAIL nginx_config_valid"; exit 1; }

F=0
t() { # host path want-code [curl-args] [body-or-header grep]
  local out code
  out=$(curl -sk --connect-to "::127.0.0.1:$P" -o "$WORK/body" -D "$WORK/hdr" -w '%{http_code} %{redirect_url}' ${4:+$4} "https://$1$2")
  code=${out%% *}
  if [ "$code" = "$3" ] && { [ -z "${5:-}" ] || grep -qi -- "$5" "$WORK/body" "$WORK/hdr"; }; then echo "PASS $1$2 -> $out"
  else echo "FAIL $1$2 -> $out (want $3${5:+, matching $5})"; F=1; fi
}
for h in $HOSTS; do
  # nginx's own 403 page: the vhost.d layer, not Stalwart's rule behind it.
  for u in /admin /admin/ /ADMIN /Admin/ /account/ /ACCOUNT /Account /%61dmin/ //admin/; do t "$h" "$u" 403 "" "<center>nginx/"; done
  t "$h" /jmap/session 200 "" '"capabilities"'
  t "$h" /jmap/session 200 "-u jason@rustd.xyz:$JASON_PASS" '"apiUrl"'
  t "$h" /.well-known/jmap 307
  if [ "$h" = mail.jasonernst.com ]; then t "$h" /webmail/ 200 "" bulwark
  else
    t "$h" /webmail/ 302 "" '^location: https://mail.jasonernst.com/webmail/'
    t "$h" /webmail 302 "" '^location: https://mail.jasonernst.com/webmail/'
  fi
done

# Logins through the proxy. Client A: 105 bad Basic logins paced under the limit (all reach
# Stalwart: more than its authBanRate of 100), then 100 in parallel (past the burst: 429),
# then Bearer and anonymous bursts (not counted), then the right password after a pause.
# Client B logs in too. So nginx limits A alone and Stalwart never banned the proxy network.
cat > "$WORK/client.sh" <<'EOF'
R="--resolve mail.jasonernst.com:443:$1"; U=https://mail.jasonernst.com
one() { curl -sk $R -o /dev/null -w '%{http_code}\n' "$@"; }
par() { seq 100 | xargs -P 10 -I{} curl -sk $R -o /dev/null -w '%{http_code}\n' "$@"; }
sum() { sort | uniq -c | tr '\n' ' '; echo '|'; }
for i in $(seq 105); do one -u jason@rustd.xyz:wrong $U/jmap/session; sleep 0.4; done | sum
par -u jason@rustd.xyz:wrong $U/jmap/session | sum
par -H 'Authorization: Bearer x' $U/jmap/session | sum
par $U/webmail/ | sum
sleep 3; one -u "jason@rustd.xyz:$2" $U/jmap/session
EOF
chmod 0644 "$WORK/client.sh"
PIP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "np-proxy-$$")
A=$(docker run --rm --network "$NET" -v "$WORK/client.sh:/c.sh:ro" --entrypoint sh "$IMG" /c.sh "$PIP" "$JASON_PASS" | tr -d '\n')
B=$(docker run --rm --network "$NET" --entrypoint curl "$IMG" -sk --resolve "mail.jasonernst.com:443:$PIP" -o /dev/null -w '%{http_code}' \
  -u "jason@rustd.xyz:$JASON_PASS" https://mail.jasonernst.com/jmap/session)
IFS='|' read -r paced fast bearer anon goodA <<<"$A"
if [[ "$paced" =~ ^\ *105\ 401\ *$ ]] && [[ "$fast" == *429* ]] && [[ "$bearer" != *429* ]] && [[ "$anon" =~ ^\ *100\ 200\ *$ ]] \
   && [ "$(echo $goodA)" = 200 ] && [ "$B" = 200 ]; then echo "PASS proxy_logins_limited_not_banned"
else echo "FAIL proxy_logins_limited_not_banned: A paced|fast|bearer|anonymous|good = $A; B good = $B"; F=1; fi

code=$(curl -s --connect-to "::127.0.0.1:$P80" -o /dev/null -w '%{http_code} %{redirect_url}' http://mail.sair.run/admin)
[ "$code" = "301 https://mail.sair.run/admin" ] && echo "PASS http_redirects_to_https" || { echo "FAIL http_redirects_to_https: $code"; F=1; }

if [ $F = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit $F
