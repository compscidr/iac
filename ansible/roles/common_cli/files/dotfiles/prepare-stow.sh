#!/bin/bash
# Managed by ansible (roles/common_cli) - runs after ~/dotfiles is updated,
# before stow.
#
# Apps sometimes replace a stowed symlink with a regular file when they rewrite
# it (Variety rewrites ~/.config/autostart/variety.desktop on every upgrade).
# stow then refuses to run ("cannot stow ... over existing target ... since
# neither a link nor a directory"). For each tracked file of the given packages
# whose target is a regular file:
#   - same content as the repo copy: remove it, so stow can link it again;
#   - different content: keep the local file (something on this host changed
#     it) and print "keep: <repo path>" so stow can be told to skip it.
# Files whose parent directory is itself a link into the repo (a folded
# directory) are the repo copy, and are never touched.
#
# Args: <seed file>... -- <package>...   (seed files are local copies by design)
set -euo pipefail

repo="$HOME/dotfiles"
[ -d "$repo/.git" ] || exit 0
repo_real=$(cd "$repo" && pwd -P)
cd "$repo"

seeds=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    seeds+=("$1")
    shift
done
[ "${1:-}" = "--" ] && shift

is_seed() {
    local s
    for s in "${seeds[@]+"${seeds[@]}"}"; do
        [ "$s" = "$1" ] && return 0
    done
    return 1
}

for pkg in "$@"; do
    [ -d "$pkg" ] || continue
    while IFS= read -r -d '' rel; do
        is_seed "$rel" && continue
        target="$HOME/${rel#*/}"
        if [ ! -f "$target" ] || [ -L "$target" ]; then continue; fi
        parent=$(cd "$(dirname "$target")" && pwd -P)
        case "$parent/" in "$repo_real"/*) continue ;; esac
        if cmp -s "$rel" "$target"; then
            rm -f "$target"
            echo "changed: ~/${rel#*/} was a copy of the repo file; stow links it again"
        else
            echo "keep: $rel"
        fi
    done < <(git ls-files -z -- "$pkg")
done
