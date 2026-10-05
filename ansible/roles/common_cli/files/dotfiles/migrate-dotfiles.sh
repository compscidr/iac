#!/bin/bash
# Managed by ansible (roles/common_cli) - runs before ~/dotfiles is updated.
#
# Tools write to files that used to be stow symlinks into ~/dotfiles: installers
# append to ~/.bashrc and ~/.profile, Claude Code rewrites its settings. Those
# writes land in the repo and make the next `git` update fail ("Local
# modifications exist"). This moves each such file out of the repo, keeping the
# local content, and resets the repo copy:
#
#   loader       ~/.bashrc becomes a real file that sources the repo copy;
#                lines a tool appended to the repo copy are kept below it.
#   materialize  the file becomes a real local copy of its current content
#                (app-owned config such as Claude Code's settings.json).
#
# Args: one "repo_path|home_path|mode" spec per file, relative to ~/dotfiles
# and ~. Prints "changed: ..." for anything it did. Exits 3, changing nothing
# further, if the repo has edits it can't move safely.
set -euo pipefail

repo="$HOME/dotfiles"
[ -d "$repo/.git" ] || exit 0
repo_real=$(cd "$repo" && pwd -P)
cd "$repo"

begin_marker="# >>> common_cli dotfiles (managed by ansible) >>>"
end_marker="# <<< common_cli dotfiles (managed by ansible) <<<"

# Resolve a symlink's target to an absolute physical path (portable: no
# readlink -f / realpath on older macOS).
resolve() {
    local l
    l=$(readlink "$1") || return 1
    case $l in /*) ;; *) l="$(dirname "$1")/$l" ;; esac
    (cd "$(dirname "$l")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$l")")
}

is_dirty() { ! git diff --quiet -- "$1" || ! git diff --cached --quiet -- "$1"; }

loader_file() {
    printf '%s\n' "$begin_marker" \
        "# Shared config lives in ~/dotfiles/bashrc/.bashrc. Everything below the" \
        "# end marker is local to this machine: installers that append to ~/.bashrc" \
        "# land there and never touch the dotfiles repo." \
        "[ -f \"\$HOME/dotfiles/bashrc/.bashrc\" ] && . \"\$HOME/dotfiles/bashrc/.bashrc\"" \
        "$end_marker"
}

# Old stow runs "folded" directories that didn't exist yet into a single link
# (e.g. ~/.claude -> dotfiles/claude/.claude), so everything an app writes there
# lands in the repo. Turn such a link back into a real directory: move the
# untracked (app) files out of the repo into it, and leave tracked files for
# `stow --no-folding` to link one by one.
unfold_parents() {
    local home=$1 dir="" part src tmpd f
    local IFS=/
    for part in $(dirname "$home"); do
        [ "$part" = "." ] && continue
        dir="${dir:+$dir/}$part"
        [ -L "$HOME/$dir" ] || continue
        src=$(resolve "$HOME/$dir" || true)
        case $src in "$repo_real"/*) ;; *) continue ;; esac
        tmpd="$HOME/$dir.common_cli.$$"
        mkdir "$tmpd"
        (cd "$src" && git ls-files --others -z .) | while IFS= read -r -d '' f; do
            mkdir -p "$tmpd/$(dirname "$f")"
            mv "$src/$f" "$tmpd/$f"
        done
        rm "$HOME/$dir"
        mv "$tmpd" "$HOME/$dir"
        echo "changed: ~/$dir is now a real directory (was a link into ~/dotfiles); moved its untracked files out of the repo"
    done
}

for spec in "$@"; do
    IFS='|' read -r rel home mode <<<"$spec"
    target="$HOME/$home"
    [ -e "$rel" ] || continue
    unfold_parents "$home"

    linked=no
    if [ -L "$target" ] && [ "$(resolve "$target" || true)" = "$repo_real/$rel" ]; then
        linked=yes
    fi
    dirty=no
    is_dirty "$rel" && dirty=yes
    [ "$linked" = no ] && [ "$dirty" = no ] && continue

    case $mode in
    loader)
        if [ "$linked" = no ]; then
            # The repo copy was edited but ~/<file> isn't linked to it: we can't
            # tell where those edits belong. Leave it for the final check.
            continue
        fi
        added=""
        if [ "$dirty" = yes ]; then
            if [ "$(git diff --numstat -- "$rel" | cut -f2)" != "0" ]; then
                echo "$rel: local edits change or remove lines (not just append); move them by hand" >&2
                exit 3
            fi
            added=$(git diff -U0 -- "$rel" | grep -E '^\+[^+]|^\+$' | cut -c2-)
        fi
        tmp="$target.common_cli.$$"
        {
            loader_file
            if [ -n "$added" ]; then
                printf '\n# moved from ~/dotfiles/%s on %s (appended by a tool)\n%s\n' "$rel" "$(date +%F)" "$added"
            fi
        } >"$tmp"
        mv -f "$tmp" "$target"
        [ "$dirty" = yes ] && git checkout -q -- "$rel"
        echo "changed: ~/$home is now a local file that sources ~/dotfiles/$rel${added:+ (kept $(printf '%s\n' "$added" | grep -c '') appended line(s))}"
        ;;
    materialize)
        if [ "$linked" = yes ]; then
            # The repo copy holds the current (possibly edited) content.
            tmp="$target.common_cli.$$"
            cp -p "$rel" "$tmp"
            mv -f "$tmp" "$target"
            echo "changed: ~/$home is now a local copy (was a link into ~/dotfiles)"
        elif [ ! -e "$target" ] && { [ "$dirty" = yes ] || [ -d "$(dirname "$target")" ]; }; then
            # Edited repo copy with no local file, or a parent directory that
            # was just unfolded: keep the repo's current content as the local copy.
            mkdir -p "$(dirname "$target")"
            cp -p "$rel" "$target"
            echo "changed: ~/$home created from the repo copy"
        fi
        # ~/<file> is now the real, authoritative copy; the repo keeps the seed.
        if [ "$dirty" = yes ]; then
            git checkout -q -- "$rel"
            echo "changed: reset ~/dotfiles/$rel"
        fi
        ;;
    *)
        echo "unknown mode '$mode' for $rel" >&2
        exit 2
        ;;
    esac
done

left=$( { git diff --name-only; git diff --cached --name-only; } | sort -u)
if [ -n "$left" ]; then
    echo "$repo has local edits this role doesn't know how to move:" >&2
    printf '%s\n' "$left" | sed 's/^/  /' >&2
    echo "Commit them to the dotfiles repo, or move them out (e.g. ~/.bashrc.local) and 'git checkout' the files." >&2
    exit 3
fi
