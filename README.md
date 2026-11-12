# git-chain-hooks

One dispatcher that makes a **global** `core.hooksPath` and a repository's own
`.git/hooks/` both run, instead of the first silently replacing the second.

## The problem

`core.hooksPath` is the only way to share git hooks across every repo you own.
It is also documented, in one short sentence, to **replace** `.git/hooks`:

> `core.hooksPath` — By default Git will look for your hooks in the
> `$GIT_DIR/hooks` directory. Set this to different path […] to tell Git to look
> elsewhere. — [git config docs](https://git-scm.com/docs/git-config#Documentation/git-config.txt-corehooksPath)

So the moment you set it globally, every per-repo hook on your machine stops
running. Nothing warns you. A pre-commit guard a project installs for itself —
"refuse a direct commit on the default branch", "run the linter on staged
files", "check the commit message" — is simply never invoked again, and the
project's own installer still reports success, because the file is where the
project put it. The failure has no symptom: hooks are quiet by nature, and a
hook that does not run looks exactly like a hook that passed.

`chain-hook` is a ~110-line POSIX `sh` script that sits in the global hooks dir
and runs both.

## How it works

Installed as `core.hooksPath/<hook-name>` — one symlink per hook name, all
pointing at the same script — it dispatches on its own `$0`:

```
git fires pre-commit
        │
        ▼
<hooks-dir>/pre-commit  ──symlink──▶  <hooks-dir>/chain-hook
                                              │
         1. ─────────────────────────────────▶ <hooks-dir>/global.d/pre-commit
         2. ─────────────────────────────────▶ <repo>/.git/hooks/pre-commit
         3. ─────────────────────────────────▶ <repo>/.git/hooks/pre-commit.d/*   (sorted)
```

Each step runs only if the previous one exited 0; a non-zero exit stops the
chain and becomes the hook's own exit status, so a guard that refuses a commit
still refuses it.

**The symlink-per-name part is load-bearing** and the thing that is easy to get
wrong: git looks up hooks *by name* and only in `core.hooksPath`. If there is no
`commit-msg` there, git finds nothing to run and a repo-local `commit-msg` stays
dead no matter what the dispatcher would have done. `install-chain.sh` therefore
symlinks every common client-side hook name, not just the ones you had.

### Four details that are easy to get wrong

1. **Finding the repo's hooks.** It is
   `$(git rev-parse --git-common-dir)/hooks`.
   - **Not** `--git-path hooks`: that resolves *through* `core.hooksPath`, so the
     dispatcher finds itself and recurses.
   - **Not** `--git-dir/hooks`: wrong directory inside a linked worktree
     (`git worktree add`), where `.git` is a file and `--git-dir` points at
     `.git/worktrees/<name>`.
   - **Not** `$(git rev-parse --show-toplevel)/.git/hooks`: wrong for worktrees,
     submodules, and any repo with a separate git dir.
2. **stdin is a single stream.** `pre-push`, `pre-receive`, `post-receive`,
   `proc-receive`, `post-rewrite` and `reference-transaction` are handed data on
   stdin — `pre-push` gets the ref list, which is exactly what git-lfs's
   `pre-push` reads. Whichever hook reads it first consumes it and the next one
   sees EOF. `chain-hook` buffers stdin once and replays it to each hook, and
   does so **only** for those six: reading stdin in, say, `pre-commit` would
   block, because git leaves a terminal attached there.
3. **Exit codes propagate.** Several published chainers run the hooks in a loop
   and ignore the result, which turns every guard in every repo into a no-op
   that prints.
4. **A non-executable hook is reported, not skipped.** A hook file without
   `+x` is the classic lost hour; `chain-hook` prints a `⚠️` line naming the
   file instead of passing over it in silence.

Also handled: linked worktrees, `*.sample` / `*~` / `*.bak` skipping in
`<hook>.d/`, a hook symlinked back at the dispatcher (recursion guard), and
shebang-less global hooks (they work via `sh`'s `ENOEXEC` fallback — many
hand-written global hooks have no shebang).

## Install

```sh
git clone <this repo> ~/Development/git-chain-hooks
cd ~/Development/git-chain-hooks

# 1. Dry run — prints every action, changes nothing. This is the default.
./install-chain.sh ~/dotfiles/gitconfig/hooks

# 2. Do it.
./install-chain.sh ~/dotfiles/gitconfig/hooks --apply
```

`chain-hook` must sit next to `install-chain.sh`; the installer resolves it as a
sibling and refuses to run otherwise.

`--apply`:

- copies the directory to `<dir>.bak-pre-chain-<timestamp>` first,
- moves the hook scripts already there into `<dir>/global.d/`,
- copies `chain-hook` in,
- symlinks the 15 client-side hook names at it.

It is idempotent: a second `--apply` moves nothing and relinks nothing (it
recognises an existing `-> chain-hook` symlink).

If `core.hooksPath` is not set yet:

```sh
git config --global core.hooksPath ~/dotfiles/gitconfig/hooks
```

### Layout afterwards

```
~/dotfiles/gitconfig/hooks/
├── chain-hook              the dispatcher (a real file)
├── global.d/
│   ├── pre-commit          your global hooks, unchanged
│   ├── pre-push
│   └── …
├── pre-commit -> chain-hook
├── commit-msg -> chain-hook
└── …                       one symlink per client-side hook name
```

`install-chain.sh` **copies** `chain-hook` into the hooks dir rather than
symlinking to the clone, so the installed copy is what runs. After pulling an
update here, re-run `--apply` to refresh it.

### Verify

```sh
GIT_CHAIN_HOOKS_DEBUG=1 git -C <some-repo-with-its-own-hook> commit --allow-empty -m probe
```

```
chain-hook[pre-commit]: running …/global.d/pre-commit
chain-hook[pre-commit]: repo hooks dir: …/some-repo/.git/hooks
chain-hook[pre-commit]: running …/some-repo/.git/hooks/pre-commit
```

## Using it

- **A global hook** → `global.d/<hook-name>`, `chmod +x`. If it is a hook name
  that was not symlinked at install time, add the symlink:
  `ln -sfn chain-hook <hooks-dir>/<hook-name>`.
- **A repo-local hook** → `.git/hooks/<hook-name>`, as usual. Nothing to
  configure; it just runs again.
- **Several hooks for one event in one repo** → drop them in
  `.git/hooks/<hook-name>.d/`. They run in sorted order, so `10-lint`,
  `20-tests` works.

### Environment variables

| Variable | Effect |
| --- | --- |
| `GIT_CHAIN_HOOKS=0` | Skip everything — no hook runs. The escape hatch for a bulk rebase or a scripted rewrite. |
| `GIT_CHAIN_HOOKS_DEBUG=1` | Trace what the dispatcher resolves and runs, on stderr. |

Note the asymmetry with `git commit --no-verify`: that bypasses the hook
entirely (git never calls the dispatcher), so it needs nothing from here.

### Which hook names are symlinked

`applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit
prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge
pre-push post-rewrite pre-auto-gc sendemail-validate`

Deliberately excluded: `reference-transaction` and `post-index-change` (they
fire on nearly every git operation, so dispatching them costs more than it
gives), `fsmonitor-watchman`, and the `p4-*` family (invoked only via explicit
config). The server-side hooks (`pre-receive`, `update`, `post-receive`,
`proc-receive`, `post-update`, `push-to-checkout`) are supported by the
dispatcher — including their stdin — but are not symlinked by the installer,
since a global client hooksPath is not where they live. Add any of these to
`HOOKS` in `install-chain.sh` if you want them.

## Uninstall

```sh
rm -rf ~/dotfiles/gitconfig/hooks
mv ~/dotfiles/gitconfig/hooks.bak-pre-chain-<timestamp> ~/dotfiles/gitconfig/hooks
```

Or, keeping the current global hooks: move `global.d/*` back up to the hooks
dir, then delete `chain-hook` and the symlinks.

## Tests

```sh
./test-chain.sh      # 23 checks, self-contained and portable
./test-site.sh       # integration against YOUR real global hooks + a real repo
```

`test-chain.sh` builds throwaway repos in `$TMPDIR` with a fake dotfiles dir and
sets `core.hooksPath` **locally** in each. It touches no global config and no
dotfiles. It covers: ordering, shebang-less global hooks, exit-code propagation
from both sides, stdin replay (asserting both hooks see byte-identical input),
argument forwarding, `commit-msg`'s path argument, `<hook>.d/` ordering and
`.sample` skipping, linked worktrees, the recursion guard (under `timeout`), the
non-executable report, and `GIT_CHAIN_HOOKS=0`.

`test-site.sh [repo] [global-hooks-dir]` copies your real global hooks into a
throwaway dir and runs them against a throwaway clone of a real repo, to prove
the chain works on the hooks you actually have. It writes nothing outside its
temp dir. Its assertions name one specific repo guard (a `pre-commit` that
refuses commits on the default branch unless an override env var is set) — adapt
them to your own. It detects an already-chained source dir and reads the
originals out of `global.d/`, so it stays runnable after you install.

## Known interactions

A tool that checks whether its own hook is active may warn on *any* set
`core.hooksPath`, because "hooksPath is set" is normally indistinguishable from
"my hook is dead". Those warnings become false positives once hooks are chained.
If you maintain such a check, the cheap discriminator is: hooksPath is set
**and** the file there mentions `--git-common-dir` / `.git/hooks` → chaining is
in play, so verify by running the hook rather than by reading the config.

## Prior art

The dispatcher-plus-`<hook>.d` shape is well-trodden; the differences are in the
details above. Observed at the time of writing:

- **[onsi/git-hooks-core](https://github.com/onsi/git-hooks-core)** — the
  closest in spirit: a global hooksPath dispatcher that also calls the repo's
  own hooks. Resolves them via `git rev-parse --git-dir`/hooks, which is wrong
  inside a linked worktree, and forwards `$@` unquoted.
- **[secretlint/git-hooks](https://github.com/secretlint/git-hooks)** — same
  idea, via `$(git rev-parse --show-toplevel)/.git/hooks`; does not check the
  local hook's exit status and forwards no arguments, so `commit-msg` loses its
  message-file path.
- **[git-hook/captain-hook](https://github.com/git-hook/captain-hook)** —
  dispatcher + `<hook>.d/` directories, per-repo rather than global chaining.
- **[slavcodev/git-hooks](https://github.com/slavcodev/git-hooks)** — the same
  `<hook>.d/` convention, installed per repo.
- **[fireflycons/git-hook-dispatcher](https://github.com/fireflycons/git-hook-dispatcher)**
  — dispatcher for multiple handlers per hook.
- **[git-multi-hook](https://www.codeofhonor.com/projects/git-multi-hook/)** —
  the early writeup of the dispatcher + `<hook>.d` pattern.
- **[sleeplessbeastie: sharing git hooks between repositories](https://sleeplessbeastie.eu/2020/05/04/how-to-share-git-hooks-between-multiple-repositories/)**
  — the `core.hooksPath` approach, and where its replace-not-supplement
  behaviour bites.

Adjacent but different: hook *managers* own `.git/hooks` per repo and run
configured commands, rather than chaining a global dir with whatever a repo
already ships —
[evilmartians/lefthook](https://github.com/evilmartians/lefthook),
[pre-commit/pre-commit](https://github.com/pre-commit/pre-commit),
[typicode/husky](https://github.com/typicode/husky).
They solve "run my configured checks"; this solves "stop my global hooksPath
from deleting everyone else's hooks".

## References

- [githooks(5)](https://git-scm.com/docs/githooks) — every hook name, its
  arguments, and which ones receive stdin.
- [git-config: `core.hooksPath`](https://git-scm.com/docs/git-config#Documentation/git-config.txt-corehooksPath)
  — the one sentence this project exists because of.
- [git-hook(1)](https://git-scm.com/docs/git-hook) — git's own hook runner;
  its `--to-stdin` option exists precisely because hooks may need stdin.
- [git-rev-parse(1)](https://git-scm.com/docs/git-rev-parse) —
  `--git-common-dir` vs `--git-dir` vs `--git-path`.
