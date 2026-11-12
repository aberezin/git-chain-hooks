#!/usr/bin/env bash
# Site integration test: chain-hook + YOUR real global hooks (read-only copies)
# + a real repository's own pre-commit guard, in a throwaway clone.
#
#   ./test-site.sh [repo] [global-hooks-dir]
#
# Changes nothing outside $ROOT: no global git config is touched, nothing is
# written into the source repo or the global hooks dir.
#
# Unlike test-chain.sh (self-contained, portable), this one asserts against a
# specific repo's guard — a pre-commit that refuses commits on the default
# branch unless DRIDOCK_ALLOW_MASTER_COMMIT=1 — so sections 1-5 are the
# author's site. Adapt the assertions for your own repo's hooks.
set -u
HC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-${CHAIN_TEST_REPO:-$PWD}}"
DOTSRC="${2:-${CHAIN_TEST_GLOBAL_HOOKS:-$HOME/dotfiles/gitconfig/hooks}}"
[ -d "$DOTSRC" ] || { echo "no global hooks dir at $DOTSRC — pass one as \$2" >&2; exit 2; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 2; }
[ -x "$REPO/.git/hooks/pre-commit" ] || { echo "$REPO has no executable .git/hooks/pre-commit — nothing to chain to (run its hook installer first)" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/realchain.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
DOT="$ROOT/dotfiles-hooks"; mkdir -p "$DOT/global.d"
cp "$HC/chain-hook" "$DOT/chain-hook"; chmod +x "$DOT/chain-hook"
# Where the real global hook IMPLEMENTATIONS live. If $DOTSRC has already been
# chained by install-chain.sh, the originals are in its global.d/ and the top
# level holds only the dispatcher plus symlinks — copying those would nest
# chain-hook inside itself and silently test nothing.
HOOKSRC="$DOTSRC"
if [ -f "$DOTSRC/chain-hook" ] && [ -d "$DOTSRC/global.d" ]; then
    HOOKSRC="$DOTSRC/global.d"
    echo "     (source dir is already chained — reading originals from global.d/)"
fi

# The real global hooks, copied in as the global implementations (never modified).
for f in "$HOOKSRC"/*; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in chain-hook|*.sample|*.bak|*~) continue ;; esac
    [ -L "$f" ] && continue
    cp "$f" "$DOT/global.d/$b"; chmod +x "$DOT/global.d/$b"
    ln -sf chain-hook "$DOT/$b"
done
[ -n "$(ls -A "$DOT/global.d")" ] || { echo "copied no global hooks out of $HOOKSRC — nothing to test" >&2; exit 2; }
echo "--- chain-hook + the real global hooks + the real repo guard ---"
echo "     global.d/: $(cd "$DOT/global.d" && printf '%s ' *)"

git clone -q --local "$REPO" "$ROOT/clone"
cp "$REPO/.git/hooks/pre-commit" "$ROOT/clone/.git/hooks/pre-commit"
chmod +x "$ROOT/clone/.git/hooks/pre-commit"
cd "$ROOT/clone" || exit 1
git config core.hooksPath "$DOT"
git config user.email t@t; git config user.name t
git checkout -q master 2>/dev/null || git checkout -q -b master

# 1. the repo guard refuses master, through the chain
out="$(git commit --allow-empty -m "probe" 2>&1)"; rc=$?
chk "guard refuses a commit on master THROUGH the chain" \
    "$(printf '%s' "$out" | grep -c "refusing to commit directly to 'master'")" "1"
chk "rc is non-zero" "$([ $rc -ne 0 ] && echo yes || echo no)" "yes"
before="$(git rev-parse HEAD)"
chk "nothing was committed" "$(git rev-parse HEAD)" "$before"

# 2. a work branch commits fine — both hooks ran and allowed it
git checkout -q -b 999-probe
out="$(git commit --allow-empty -m "probe on a branch" 2>&1)"; rc=$?
chk "a <issue#>-slug branch still commits" "$([ $rc -eq 0 ] && echo yes || echo no)" "yes"

# 3. the global NO_GITCOMMIT check still bites (its own rule, via the chain)
# The marker is assembled at runtime so this file does not itself contain it.
printf 'x = 1 # %s\n' "$(printf 'NO_GITCOMMIT' | tr -d '_')" > probe.js
git add probe.js
out="$(git commit -m "should be refused by the global hook" 2>&1)"; rc=$?
chk "global NO-GITCOMMIT hook still refuses" \
    "$(printf '%s' "$out" | grep -c 'global pre-commit hook talking')" "1"
chk "and that refusal blocks the commit" "$([ $rc -ne 0 ] && echo yes || echo no)" "yes"
git reset -q HEAD probe.js; rm -f probe.js probe.js.bak

# 4. the override still works through the chain
out="$(DRIDOCK_ALLOW_MASTER_COMMIT=1 git -c core.hooksPath="$DOT" commit --allow-empty -m "override probe" 2>&1)"
git checkout -q master
out="$(DRIDOCK_ALLOW_MASTER_COMMIT=1 git commit --allow-empty -m "override probe" 2>&1)"; rc=$?
chk "DRIDOCK_ALLOW_MASTER_COMMIT=1 still works through the chain" \
    "$([ $rc -eq 0 ] && echo yes || echo no)" "yes"
chk "and it says so" "$(printf '%s' "$out" | grep -c 'committing directly')" "1"

# 5. install.sh's own hook check would now be happy about .git/hooks
chk "the repo's guard is the one that ran (not a copy in the dotfiles dir)" \
    "$([ -f "$DOT/global.d/pre-commit" ] && echo 1 || echo 0)" "1"

echo "  real-chain: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
