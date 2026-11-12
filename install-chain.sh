#!/usr/bin/env bash
# Install chain-hook into a core.hooksPath directory.
#
#   ./install-chain.sh <hooks-dir>            # show what it WOULD do (default)
#   ./install-chain.sh <hooks-dir> --apply    # do it
#
# It moves the existing hook scripts into <hooks-dir>/global.d/ and replaces
# them with symlinks to chain-hook, plus a symlink for every other common
# client-side hook name — that last part matters: without it, a repo-local
# `commit-msg` still never runs, because git only looks in core.hooksPath and
# finds nothing there to dispatch from.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/chain-hook"
DIR="${1:?usage: install-chain.sh <hooks-dir> [--apply]}"
APPLY=0; [ "${2:-}" = "--apply" ] && APPLY=1

# Hooks git looks up by name on the client side. Deliberately NOT included:
# reference-transaction and post-index-change (fire on nearly every operation,
# so dispatching them costs more than it gives), fsmonitor-watchman and the
# p4-* family (only invoked via explicit config). Add a name here to cover it.
HOOKS="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit
prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge
pre-push post-rewrite pre-auto-gc sendemail-validate"

say() { if [ "$APPLY" = 1 ]; then echo "  $*"; else echo "  would: $*"; fi; }
run() { if [ "$APPLY" = 1 ]; then "$@"; fi; }

[ -d "$DIR" ] || { echo "❌ not a directory: $DIR" >&2; exit 1; }
[ -f "$SRC" ] || { echo "❌ chain-hook not found next to this script" >&2; exit 1; }

echo "chain-hook → $DIR  ($([ "$APPLY" = 1 ] && echo APPLYING || echo "dry run — pass --apply to act"))"

BACKUP="$DIR.bak-pre-chain-$(date +%Y%m%d%H%M%S)"
say "back up $DIR → $BACKUP"
run cp -a "$DIR" "$BACKUP"

say "mkdir -p $DIR/global.d"
run mkdir -p "$DIR/global.d"

# Move real hook scripts (not the dispatcher, not global.d, not samples) down.
moved=0
for f in "$DIR"/*; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    [ -d "$f" ] && continue
    case "$b" in chain-hook|*.sample|*.bak|*~) continue ;; esac
    if [ -L "$f" ] && [ "$(readlink "$f")" = "chain-hook" ]; then
        say "keep symlink $b → chain-hook (already chained)"
        continue
    fi
    say "git mv-style: $b → global.d/$b"
    run mv "$f" "$DIR/global.d/$b"
    moved=$((moved+1))
done
say "moved $moved existing hook(s) into global.d/"

say "install $DIR/chain-hook"
run cp "$SRC" "$DIR/chain-hook"
run chmod +x "$DIR/chain-hook"

for h in $HOOKS; do
    if [ -L "$DIR/$h" ] && [ "$(readlink "$DIR/$h")" = "chain-hook" ]; then continue; fi
    say "ln -s chain-hook $DIR/$h"
    run ln -sfn chain-hook "$DIR/$h"
done

if [ "$APPLY" = 1 ]; then
    echo
    echo "✅ installed. Verify with:"
    echo "     ls -l $DIR | head"
    echo "     GIT_CHAIN_HOOKS_DEBUG=1 git -C <some-repo> commit --allow-empty -m probe"
    echo "   Backup of the previous state: $BACKUP"
else
    echo
    echo "Nothing changed. Re-run with --apply to perform the above."
fi
