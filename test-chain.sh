#!/usr/bin/env bash
# Tests chain-hook in throwaway repos. Touches NO global git config and NO
# dotfiles: each repo sets core.hooksPath LOCALLY at a fake dotfiles dir.
set -u
CHAIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/chain-hook"
PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chaintest.XXXXXX")"
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

# --- the fake "dotfiles" hooks dir: chain-hook + symlinks per hook name -----
DOT="$ROOT/dotfiles-hooks"; mkdir -p "$DOT/global.d"
cp "$CHAIN" "$DOT/chain-hook"; chmod +x "$DOT/chain-hook"
for h in pre-commit commit-msg pre-push post-commit post-checkout post-merge post-rewrite prepare-commit-msg; do
    ln -s chain-hook "$DOT/$h"
done

# global pre-commit WITHOUT a shebang — real-world global hooks often have none
cat > "$DOT/global.d/pre-commit" <<'G'
# no shebang on purpose
echo "GLOBAL pre-commit ran" >> "$LOG"
G
chmod +x "$DOT/global.d/pre-commit"
# global pre-push: needs stdin, like git-lfs does
cat > "$DOT/global.d/pre-push" <<'G'
#!/bin/sh
echo "GLOBAL pre-push args=[$*] stdin=[$(cat)]" >> "$LOG"
G
chmod +x "$DOT/global.d/pre-push"
cat > "$DOT/global.d/commit-msg" <<'G'
#!/bin/sh
echo "GLOBAL commit-msg arg1=$1" >> "$LOG"
G
chmod +x "$DOT/global.d/commit-msg"

newrepo() {                       # newrepo <name> → path, hooksPath set locally
    local r="$ROOT/$1"; mkdir -p "$r"; git init -q "$r"
    git -C "$r" config core.hooksPath "$DOT"
    git -C "$r" config user.email t@t; git -C "$r" config user.name t
    echo "$r"
}
hook() {                          # hook <repo> <name> <body...>
    local r="$1" n="$2"; shift 2
    mkdir -p "$r/.git/hooks"; printf '%s\n' "$@" > "$r/.git/hooks/$n"
    chmod +x "$r/.git/hooks/$n"
}

echo "--- chain-hook ---"

# 1. both global and local pre-commit run, global first, local second
R="$(newrepo both)"; export LOG="$R/log"; : > "$LOG"
hook "$R" pre-commit '#!/bin/sh' 'echo "LOCAL pre-commit ran" >> "$LOG"'
(cd "$R" && git commit -q --allow-empty -m one 2>/dev/null)
chk "global hook runs (shebang-less, via sh ENOEXEC fallback)" \
    "$(grep -c 'GLOBAL pre-commit ran' "$LOG")" "1"
chk "local .git/hooks hook runs too" "$(grep -c 'LOCAL pre-commit ran' "$LOG")" "1"
chk "order is global then local" \
    "$(awk '/pre-commit ran/{printf "%s", substr($1,1,1)}' "$LOG")" "GL"

# 2. a failing LOCAL hook aborts the commit (secretlint's bug)
R="$(newrepo localfail)"; export LOG="$R/log"; : > "$LOG"
hook "$R" pre-commit '#!/bin/sh' 'echo "LOCAL refusing" >&2' 'exit 1'
out="$( (cd "$R" && git commit --allow-empty -m nope 2>&1) )"; rc=$?
chk "failing local hook → git aborts (rc != 0)" "$([ $rc -ne 0 ] && echo yes || echo no)" "yes"
chk "its stderr reaches the user" "$(printf '%s' "$out" | grep -c 'LOCAL refusing')" "1"
chk "no commit was created" "$(git -C "$R" rev-list --count --all)" "0"

# 3. a failing GLOBAL hook stops before the local one
R="$(newrepo globalfail)"; export LOG="$R/log"; : > "$LOG"
mkdir -p "$DOT/global.d.bak"; cp "$DOT/global.d/pre-commit" "$DOT/global.d.bak/"
printf '#!/bin/sh\necho "GLOBAL refusing" >&2\nexit 3\n' > "$DOT/global.d/pre-commit"
hook "$R" pre-commit '#!/bin/sh' 'echo "LOCAL ran anyway" >> "$LOG"'
(cd "$R" && git commit -q --allow-empty -m nope 2>/dev/null)
chk "failing global hook stops the chain" "$(grep -c 'LOCAL ran anyway' "$LOG" || true)" "0"
cp "$DOT/global.d.bak/pre-commit" "$DOT/global.d/pre-commit"

# 4. pre-push: BOTH hooks get the same stdin and the same args
R="$(newrepo push)"; export LOG="$R/log"; : > "$LOG"
hook "$R" pre-push '#!/bin/sh' 'echo "LOCAL pre-push args=[$*] stdin=[$(cat)]" >> "$LOG"'
REMOTE="$ROOT/remote.git"; git init -q --bare "$REMOTE"
(cd "$R" && git commit -q --allow-empty -m c1 && git remote add origin "$REMOTE" && git push -q origin HEAD:refs/heads/main 2>/dev/null)
g_stdin="$(sed -n 's/^GLOBAL pre-push .*stdin=\[\(.*\)\]$/\1/p' "$LOG")"
l_stdin="$(sed -n 's/^LOCAL pre-push .*stdin=\[\(.*\)\]$/\1/p' "$LOG")"
chk "global pre-push received its stdin refs"  "$([ -n "$g_stdin" ] && echo yes || echo no)" "yes"
chk "local pre-push received stdin TOO (replayed, not consumed)" "$([ -n "$l_stdin" ] && echo yes || echo no)" "yes"
chk "both saw identical stdin" "$([ "$g_stdin" = "$l_stdin" ] && echo same || echo "differ")" "same"
chk "args forwarded to both" \
    "$(grep -c 'args=\[origin ' "$LOG")" "2"

# 5. commit-msg: the file argument is forwarded
R="$(newrepo msg)"; export LOG="$R/log"; : > "$LOG"
hook "$R" commit-msg '#!/bin/sh' 'echo "LOCAL commit-msg arg1=$1" >> "$LOG"' 'grep -q . "$1" || exit 1'
(cd "$R" && git commit -q --allow-empty -m hello 2>/dev/null)
chk "commit-msg arg reaches global" "$(grep -c 'GLOBAL commit-msg arg1=.*COMMIT_EDITMSG' "$LOG")" "1"
chk "commit-msg arg reaches local"  "$(grep -c 'LOCAL commit-msg arg1=.*COMMIT_EDITMSG' "$LOG")" "1"

# 6. <hook>.d/ directory: every script runs, in sorted order, .sample skipped
R="$(newrepo multi)"; export LOG="$R/log"; : > "$LOG"
mkdir -p "$R/.git/hooks/pre-commit.d"
for n in 20-second 10-first; do
    printf '#!/bin/sh\necho "D %s" >> "$LOG"\n' "$n" > "$R/.git/hooks/pre-commit.d/$n"
    chmod +x "$R/.git/hooks/pre-commit.d/$n"
done
printf '#!/bin/sh\necho "D sample" >> "$LOG"\n' > "$R/.git/hooks/pre-commit.d/99-x.sample"
chmod +x "$R/.git/hooks/pre-commit.d/99-x.sample"
(cd "$R" && git commit -q --allow-empty -m d 2>/dev/null)
chk "pre-commit.d scripts all run, sorted" "$(grep '^D ' "$LOG" | tr '\n' ',')" "D 10-first,D 20-second,"
chk ".sample in pre-commit.d is skipped" "$(grep -c 'D sample' "$LOG" || true)" "0"

# 7. worktree: the LINKED worktree still finds the repo's hooks
R="$(newrepo wt)"; export LOG="$R/log"; : > "$LOG"
hook "$R" pre-commit '#!/bin/sh' 'echo "LOCAL in worktree" >> "$LOG"'
(cd "$R" && git commit -q --allow-empty -m base 2>/dev/null)
: > "$LOG"
(cd "$R" && git worktree add -q "$ROOT/wt-linked" HEAD --detach 2>/dev/null)
(cd "$ROOT/wt-linked" && git commit -q --allow-empty -m fromwt 2>/dev/null)
chk "local hook runs from a linked worktree" "$(grep -c 'LOCAL in worktree' "$LOG")" "1"

# 8. recursion guard: .git/hooks/pre-commit symlinked back at the dispatcher
R="$(newrepo recurse)"; export LOG="$R/log"; : > "$LOG"
mkdir -p "$R/.git/hooks"; ln -s "$DOT/chain-hook" "$R/.git/hooks/pre-commit"
timeout 20 git -C "$R" commit -q --allow-empty -m rec >/dev/null 2>&1; rc=$?
chk "a hook symlinked back at the dispatcher does not loop" "$([ $rc -ne 124 ] && echo no-loop || echo HUNG)" "no-loop"
chk "the commit still succeeded" "$(git -C "$R" rev-list --count --all)" "1"

# 9. a non-executable local hook is reported, not silently skipped
R="$(newrepo noexec)"; export LOG="$R/log"; : > "$LOG"
mkdir -p "$R/.git/hooks"; printf '#!/bin/sh\necho nope\n' > "$R/.git/hooks/pre-commit"; chmod -x "$R/.git/hooks/pre-commit"
out="$( (cd "$R" && git commit --allow-empty -m noexec 2>&1) )"
chk "non-executable local hook is reported on stderr" \
    "$(printf '%s' "$out" | grep -c 'is not executable')" "1"
chk "and the commit is not blocked by it" "$(git -C "$R" rev-list --count --all)" "1"

# 10. a repo with NO local hooks still runs the global one, and exits clean
R="$(newrepo globalonly)"; export LOG="$R/log"; : > "$LOG"
(cd "$R" && git commit -q --allow-empty -m g 2>/dev/null)
chk "global-only repo: global runs, nothing errors" "$(grep -c 'GLOBAL pre-commit ran' "$LOG")" "1"

# 11. post-* hooks chain too (LFS's live here)
R="$(newrepo posthook)"; export LOG="$R/log"; : > "$LOG"
printf '#!/bin/sh\necho "GLOBAL post-commit" >> "$LOG"\n' > "$DOT/global.d/post-commit"; chmod +x "$DOT/global.d/post-commit"
hook "$R" post-commit '#!/bin/sh' 'echo "LOCAL post-commit" >> "$LOG"'
(cd "$R" && git commit -q --allow-empty -m p 2>/dev/null)
chk "post-commit: both run" "$(grep -c 'post-commit' "$LOG")" "2"

# 12. GIT_CHAIN_HOOKS=0 disables everything
R="$(newrepo optout)"; export LOG="$R/log"; : > "$LOG"
hook "$R" pre-commit '#!/bin/sh' 'echo "LOCAL optout" >> "$LOG"'
(cd "$R" && GIT_CHAIN_HOOKS=0 git commit -q --allow-empty -m o 2>/dev/null)
chk "GIT_CHAIN_HOOKS=0 runs no hooks at all" "$(wc -c < "$LOG" | tr -d ' ')" "0"

echo "  chain-hook: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
