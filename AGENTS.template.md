# AGENTS.md template for projects using git shadow

Copy below section into `AGENTS.md` of project that uses git shadow.

## Git Shadow workflow for AI agents

Use **git shadow** to keep thinking work in `@local` and clean work in public branch.

### Branch model

- `feature/x` — public branch for review.
- `feature/x@local` — local thinking branch; work here.
- `main` / `main@local` — public / local base branches.
- Run `git shadow config show --json` to confirm `LOCAL_SUFFIX` and `PUBLIC_BASE_BRANCH`.

### Commit rules

- Public code with `///` or `// @local` markers: `git shadow commit -m "..."`.
  Extracts markers to `.git-shadow/annotations/<relpath>`, writes clean public commit + `[MEMORY]` sidecar.
- Public code without markers: `git commit`.
- Local notes, scratch files, debug logs: `git commit -m "[MEMORY] <subject>"`.
  `[MEMORY]` commits must not modify files tracked by public branch.

### Typical workflow

```bash
# keep the local base current
git shadow base sync

# start work
git shadow feature start feature/x

# work on feature/x@local
#   - `git shadow commit -m "..."` if files contain `///` or `// @local`
#   - `git commit` if no markers
#   - `git commit -m "[MEMORY] ..."` for local-only reasoning files

# check what is publishable
git shadow status

# publish and push
git shadow feature publish
git shadow push feature/x
```

### When the public branch changes

- Remote feature branch rebased with identical patches: `git shadow feature sync --recover`.
- Conflict during sync: resolve, then `git shadow feature sync --continue`.
- Abort sync: `git shadow feature sync --abort`.
- Public base force-pushed or rewritten, patch-ids do not match: `git shadow re-anchor feature/x@local`.

### After merge

```bash
git shadow feature finish
git shadow push main
```

### Safety and verification

- Run `git shadow check public feature/x` before push to audit leaked local-only content.
- Pre-commit hook blocks public-tracked files with `///` or `// @local` unless `GIT_SHADOW=1`.
- `git shadow feature publish` aborts if any `.git-shadow/annotations/` path or local marker would enter public branch.

### Agent decision rule

If change helps thinking, keep in `feature/x@local` (usually `[MEMORY]`).
If change ready for review, publish to `feature/x`.
