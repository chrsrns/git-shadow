# AGENTS.md template for projects using git shadow

Copy below section into `AGENTS.md` of project that uses git shadow.

## Git Shadow workflow for AI agents

**git shadow** separates thinking (`@local`) from public work.

### Branch model

- `feature/x` — public review branch.
- `feature/x@local` — thinking branch.
- `main` / `main@local` — base public / local branches.
- Run `git shadow config show --json` to confirm `LOCAL_SUFFIX` and `PUBLIC_BASE_BRANCH`.

### Commit rules

- Public code with `///` or `// @local` markers: `git shadow commit -m "..."`.
  Extracts markers to `.git-shadow/annotations/<relpath>`; clean public commit + `[MEMORY]` sidecar.
- Public code without markers: `git commit`.
- Local notes / scratch / debug: `git commit -m "[MEMORY] <subject>"`.
  `[MEMORY]` commits must not modify public-tracked files already tracked by the public branch.

### Typical workflow

```bash
# keep local base current
git shadow base sync

# start (or in a worktree)
git shadow feature start feature/x
# git shadow feature start feature/x --worktree          # under WORKTREE_ROOT
# git shadow feature start feature/x --worktree-dir <dir>

# work on feature/x@local
#   - `git shadow commit -m "..."` if files contain `///` or `// @local`
#   - `git commit` if no markers
#   - `git commit -m "[MEMORY] ..."` for local-only reasoning files

# check publishable count
git shadow status

# publish and push
git shadow feature publish
git shadow push feature/x
```

### Local patch workflow

- `git shadow local add <path>` — store local-only edits to a public-tracked file as `.git-shadow/patches/<relpath>.patch`; sidecar committed as `[MEMORY]`, source file stays modified.
- `git shadow local apply` — reapply all sidecars after sync, re-anchor, or checkout.
- `git shadow local rm [--revert] <path>` — remove sidecar; `--revert` restores source to `HEAD`.
- `git shadow local diff [path]` — print one or all sidecars.
- `git shadow local apply` orphan warning → refresh with `local add` or remove sidecar.
- `git shadow commit` subtracts the stored patch from staged public-tracked files before marker extraction.

### When public branch changes

- Identical rebase on remote: `git shadow feature sync --recover`.
- Sync conflict: resolve, then `git shadow feature sync --continue`.
- Abort: `git shadow feature sync --abort`.
- Public base force-pushed/rewritten, patch-ids differ: `git shadow re-anchor feature/x@local`.
- Release/hotfix directly on public branch: `GIT_SHADOW=1 git commit` on `main`, `git shadow push main`, then `git shadow base sync`.

No base publish path; do not commit on `<base>@local` first.

### After merge

```bash
git shadow feature finish
git shadow push main
```

If the feature is in a worktree, `git shadow feature finish` removes it before deleting branches.
Use `--keep-worktree` to keep both the worktree and `feature/x@local`.
A dirty worktree or `cwd` inside the worktree aborts `finish` before any change.

`WORKTREE_ROOT` is the parent directory for `--worktree` worktrees and is empty by default.
Configure it with `git shadow config set WORKTREE_ROOT <absolute-path> --project-config`.

### Safety

- Run `git shadow check public feature/x` before push to audit local-only leaks.
- Pre-commit hook rejects public-tracked files with `///` or `// @local` markers and staged paths with a `.git-shadow/patches/` sidecar, unless `GIT_SHADOW=1` is set.
- `git shadow feature publish` runs diff-based check pass + scans replayed tree for local markers and `.git-shadow/annotations/` or `.git-shadow/patches/` paths.
- `git shadow doctor` — read-only diagnostic: version skew, paused sync/finish, `@local` checkpoints, hooks (install status and freshness), orphan `.git-shadow/annotations/` records, orphan `.git-shadow/patches/` sidecars, unpromoted files, `SPEC.md merge=union`, worktree health (`WORKTREE_ROOT` validity, stale or orphaned worktree registrations, base branches held by other worktrees). Exits 1 on warning.

### Decision rule

Thinking → `feature/x@local` (usually `[MEMORY]`).
Ready for review → `feature/x`.
