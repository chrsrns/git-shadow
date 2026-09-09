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

### Local patch workflow

- Use `git shadow local add <path>` to store local-only edits to a public-tracked file as a unified-diff sidecar under `.git-shadow/patches/<relpath>.patch`.
- The sidecar is committed as `[MEMORY]` and the source file in the working tree keeps the local change applied.
- Use `git shadow local apply` to reapply every stored sidecar after sync, re-anchor, or checkout.
- Use `git shadow local rm [--revert] <path>` to remove a sidecar; `--revert` also restores the source file to `HEAD`.
- Use `git shadow local diff [path]` to print one sidecar or all sidecars.
- If `git shadow local apply` warns that a sidecar is an orphan, the source no longer matches. Refresh the sidecar with `git shadow local add <path>` or remove it.
- `git shadow commit` subtracts the stored patch from staged public-tracked files before marker extraction, so the public commit never contains the local overlay.

### Typical workflow

```bash
# keep the local base current
git shadow base sync

# start work
git shadow feature start feature/x

#    Or start it in a dedicated worktree on feature/x@local:
git shadow feature start feature/x --worktree          # under WORKTREE_ROOT
git shadow feature start feature/x --worktree-dir <dir>

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

If the feature lives in a worktree, `git shadow feature finish` removes the worktree before deleting
the feature branches — use `--keep-worktree` to keep both it and `feature/x@local`.
A dirty worktree or a `cd` inside it aborts `finish` before any change.

`WORKTREE_ROOT` is the parent directory for `--worktree` worktrees and is empty by default.
Configure it once per project or user:

```bash
git shadow config set WORKTREE_ROOT <absolute-path> --project-config
```

### Safety and verification

- Run `git shadow check public feature/x` before push to audit leaked local-only content.
- The pre-commit hook rejects public-tracked files that contain `///` or `// @local` markers and rejects staged paths that have a `.git-shadow/patches/` sidecar, unless `GIT_SHADOW=1` is set.
- `git shadow feature publish` runs a diff-based check pass and also scans the replayed tree for local markers and `.git-shadow/annotations/` or `.git-shadow/patches/` paths.
- Run `git shadow doctor` for a read-only repo diagnostic: version skew, paused sync/finish state, per-`@local` checkpoint summary, hooks (install status and freshness), orphan `.git-shadow/annotations/` records, orphan `.git-shadow/patches/` sidecars, unpromoted files, `SPEC.md merge=union` in `.gitattributes`, and worktree health (`WORKTREE_ROOT` validity, stale or orphaned worktree registrations, base branches held by other worktrees). Exits 1 on any warning.

### Agent decision rule

If change helps thinking, keep in `feature/x@local` (usually `[MEMORY]`).
If change ready for review, publish to `feature/x`.
