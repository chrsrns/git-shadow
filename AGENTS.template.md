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
  `[MEMORY]` commits must not modify files already tracked by the public branch.

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
- Release/hotfix directly on a public branch: `GIT_SHADOW=1 git commit` on `main`, `git shadow push main`, then `git shadow base sync` absorbs it onto `main@local`.

Do not commit on `<base>@local` first — there is no base publish path; publishing exists only for feature branches.

### After merge

```bash
git shadow feature finish
git shadow push main
```

### Safety and verification

- Run `git shadow check public feature/x` before push to audit leaked local-only content.
- The pre-commit hook rejects public-tracked files that contain `///` or `// @local` markers unless `GIT_SHADOW=1` is set.
- `git shadow feature publish` runs a diff-based check pass and also scans the replayed tree for local markers and `.git-shadow/annotations/` paths.

### Agent decision rule

If change helps thinking, keep in `feature/x@local` (usually `[MEMORY]`).
If change ready for review, publish to `feature/x`.
