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

# start
git shadow feature start feature/x

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

### Safety

- Run `git shadow check public feature/x` before push to audit local-only leaks.
- Pre-commit hook rejects public-tracked files with `///` or `// @local` markers unless `GIT_SHADOW=1` is set.
- `git shadow feature publish` runs diff-based check pass + scans replayed tree for local markers and `.git-shadow/annotations/` paths.

### Decision rule

Thinking → `feature/x@local` (usually `[MEMORY]`).
Ready for review → `feature/x`.
