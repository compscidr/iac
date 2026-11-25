#!/usr/bin/env bash
# Tests for roles/dev_gui/files/orca-update. Runs as a normal user: the root
# commands the script calls are stubbed on PATH, and GitHub is a file:// tree.
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../files/orca-update
arch=$(dpkg --print-architecture)
yml=latest-linux.yml
[ "$arch" = arm64 ] && yml=latest-linux-arm64.yml
user=$(id -un)

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
cases=0
failed=0
t=
out=
rc=0

stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$t/bin/$1"
  chmod +x "$t/bin/$1"
}

# A fresh sandbox per case, with every stub knob back at its default.
setup() {
  cases=$((cases + 1))
  case_name=$1
  case_failed=0
  t=$root/$cases
  mkdir -p "$t/bin" "$t/pending" "$t/releases/latest/download"
  export STUB_DIR=$t STUB_LOG=$t/log
  export STUB_INSTALLED=1.4.272 STUB_APT_RC=0 STUB_PGREP_RCS=1 STUB_SERVE_ACTIVE_RC=3
  export ORCA_UPDATE_PENDING_DIR=$t/pending
  export ORCA_UPDATE_RELEASES_URL=file://$t/releases
  : >"$STUB_LOG"
  # shellcheck disable=SC2016  # the stub bodies expand when the stubs run
  {
    stub dpkg-query '[ -n "$STUB_INSTALLED" ] || exit 1; printf "%s" "$STUB_INSTALLED"'
    stub apt-get 'echo "apt-get $*" >>"$STUB_LOG"; exit "$STUB_APT_RC"'
    # One return code is consumed per call; the last one repeats.
    stub pgrep 'n=$(cat "$STUB_DIR/pgrep.n" 2>/dev/null || echo 0)
read -r -a rcs <<<"$STUB_PGREP_RCS"
i=$n; [ "$i" -ge "${#rcs[@]}" ] && i=$((${#rcs[@]} - 1))
echo $((n + 1)) >"$STUB_DIR/pgrep.n"
exit "${rcs[$i]}"'
    stub runuser 'echo "runuser $*" >>"$STUB_LOG"
case " $* " in *" is-active "*) exit "$STUB_SERVE_ACTIVE_RC" ;; esac
exit 0'
  }
}

deb_name() { echo "orca-ide_$1_$arch.deb"; }

sha512_b64() { openssl dgst -sha512 -binary "$1" | base64 -w0; }

# What the Orca app leaves behind after downloading version $1.
pending() {
  local name
  name=$(deb_name "$1")
  echo "deb $1" >"$t/pending/$name"
  printf '{"fileName":"%s","sha512":"%s","isAdminRightsRequired":false}\n' \
    "$name" "$(sha512_b64 "$t/pending/$name")" >"$t/pending/update-info.json"
}

# Publishes version $1 as a release, and as the latest one. The AppImage entry
# comes first, as upstream has it, so a parser that takes the first sha512 fails.
publish() {
  local name dir
  name=$(deb_name "$1")
  dir=$t/releases/download/v$1
  mkdir -p "$dir"
  echo "deb $1" >"$dir/$name"
  cat >"$dir/$yml" <<EOF
version: $1
files:
  - url: orca-linux.AppImage
    sha512: QXBwSW1hZ2U=
    size: 285743504
    blockMapSize: 298900
  - url: $name
    sha512: $(sha512_b64 "$dir/$name")
    size: 7
  - url: orca-ide-$1.x86_64.rpm
    sha512: cnBt
    size: 3
path: orca-linux.AppImage
sha512: QXBwSW1hZ2U=
releaseDate: '2026-11-24T22:39:41.464Z'
EOF
  cp "$dir/$yml" "$t/releases/latest/download/$yml"
}

run() {
  out=$(PATH="$t/bin:$PATH" "$script" "$@" 2>&1)
  rc=$?
}

fail() {
  [ "$case_failed" = 0 ] && failed=$((failed + 1))
  case_failed=1
  echo "FAIL: $case_name: $1"
  echo "  rc=$rc"
  echo "  out: ${out//$'\n'/$'\n'       }"
  echo "  log: $(tr '\n' '|' <"$STUB_LOG")"
}

expect_rc() { [ "$rc" = "$1" ] || fail "expected exit $1"; }
expect_out() { grep -qF -- "$1" <<<"$out" || fail "expected output: $1"; }
expect_log() { grep -qF -- "$1" "$STUB_LOG" || fail "expected call: $1"; }
expect_no_log() { ! grep -qF -- "$1" "$STUB_LOG" || fail "unexpected call: $1"; }
# The calls matching any of the given words, in order, must be exactly those words.
expect_order() {
  local got
  got=$(grep -oE -- "$(IFS='|'; echo "$*")" "$STUB_LOG" | tr '\n' ' ')
  [ "$got" = "$* " ] || fail "expected call order: $* (got: $got)"
}

# --- desktop mode ---------------------------------------------------------

setup "desktop: installs a pending update"
pending 1.4.274
publish 1.4.274
run desktop "$user"
expect_rc 0
expect_log "apt-get install -y"
expect_no_log "$t/pending"
expect_out "orca-update: installed orca-ide 1.4.274 (was 1.4.272)"

setup "desktop: nothing pending"
run desktop "$user"
expect_rc 0
expect_no_log "apt-get"

setup "desktop: pending update is not newer"
pending 1.4.272
publish 1.4.272
run desktop "$user"
expect_rc 0
expect_no_log "apt-get"
expect_out "orca-update: up to date (1.4.272)"

setup "desktop: skips while Orca is running"
pending 1.4.274
publish 1.4.274
STUB_PGREP_RCS=0
run desktop "$user"
expect_rc 0
expect_no_log "apt-get"
expect_out "orca-update: skip: Orca is running"

setup "desktop: skips when Orca starts during the run"
pending 1.4.274
publish 1.4.274
STUB_PGREP_RCS="1 0"
run desktop "$user"
expect_rc 0
expect_no_log "apt-get"

setup "desktop: rejects a pending deb that differs from upstream"
pending 1.4.274
publish 1.4.274
echo x >>"$t/pending/$(deb_name 1.4.274)"
run desktop "$user"
expect_rc 1
expect_no_log "apt-get"
expect_out "orca-update: checksum mismatch for $(deb_name 1.4.274)"

setup "desktop: rejects a file name outside the pending directory"
pending 1.4.274
publish 1.4.274
echo '{"fileName":"../../tmp/x.deb","sha512":"eA==","isAdminRightsRequired":false}' \
  >"$t/pending/update-info.json"
run desktop "$user"
expect_rc 1
expect_no_log "apt-get"
expect_out "orca-update: rejected pending file name: ../../tmp/x.deb"

setup "desktop: GitHub unreachable"
pending 1.4.274
ORCA_UPDATE_RELEASES_URL=file:///nonexistent
run desktop "$user"
expect_rc 0
expect_no_log "apt-get"
expect_out "orca-update: cannot fetch file:///nonexistent/download/v1.4.274/$yml"

setup "desktop: install fails"
pending 1.4.274
publish 1.4.274
STUB_APT_RC=100
run desktop "$user"
expect_rc 1
expect_out "orca-update: install failed"

setup "desktop: orca-ide is not installed"
pending 1.4.274
publish 1.4.274
STUB_INSTALLED=
run desktop "$user"
expect_rc 0
expect_no_log "apt-get"

setup "desktop: dry run"
pending 1.4.274
publish 1.4.274
run desktop "$user" --dry-run
expect_rc 0
expect_no_log "apt-get"
expect_out "orca-update: would install orca-ide 1.4.274 (installed 1.4.272)"

setup "rejects an unknown mode"
run bogus "$user"
expect_rc 1
expect_no_log "apt-get"

setup "rejects a missing user"
run desktop
expect_rc 1
expect_no_log "apt-get"

echo "$((cases - failed))/$cases passed"
[ "$failed" = 0 ]
