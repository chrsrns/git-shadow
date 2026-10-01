# Changelog

## [Unreleased]

## [1.5.1] — 2026-10-01

### Fixed

- Local patch and annotation sidecar paths resolve against the worktree toplevel, so commands behave the same from a subdirectory as from the repository root: `feature sync` no longer creates a checkpoint without a `[SYNC]` commit and a dirty tree, `feature finish` no longer drops local patch sidecars or `[MEMORY]` content, and `annotations reapply` collects its targets instead of reporting "No annotation records to reapply".
- `git shadow commit` writes annotation sidecars at the toplevel-relative path, refreshes the marker working tree, keeps local-only annotation sidecars out of the public commit, and no longer misclassifies a staged binary as text (which stripped marker-like bytes out of the committed blob) when run from a subdirectory.
- `feature finish` creates the annotation sidecar's parent directory before writing it, so a nested sidecar is inherited instead of being silently dropped when the base lacks that directory.
- `git shadow doctor` reports the same annotation-orphan, `SPEC.md` integrity, and base-drift results from any directory, instead of a false clean or a false drift warning.
- `local add|rm|diff` and `annotations reapply [path]` accept a cwd-relative or absolute path, normalize it to the toplevel, and reject a path that escapes the worktree.
- Patched paths containing spaces, quotes, or non-ASCII bytes are recognized by the clean-tree check (`git status --porcelain` is parsed NUL-delimited).

## [1.5.0] — 2026-09-28

### Added

- `-h`/`--help` is now a uniform contract across every command: leaf commands print their usage line before configuration is loaded, value-taking options (e.g. `-m`, `--worktree-dir`, `--mark-applied`) do not swallow a help token, and bash/zsh/fish completions are consistent with the contract.
- `git shadow doctor` reports `SPEC.md` integrity: duplicate `^V<n>:` / `^| T<n> |` / `^| B<n> |` row IDs, and a warning when the `SPEC.md` merge driver resolves to `union` via `git check-attr`. This replaces the former `.gitattributes` `merge=union` check.

### Changed

- `sync_save_state` and `finish_save_state` take `key=value` arguments forwarded verbatim to `state_save`, so call sites are self-describing and new state keys no longer require signature changes.
- `commands/feature/finish.sh` internal helpers read a single named finish context (script globals) instead of receiving the same values through long positional argument lists; only per-call varying data is passed as arguments.
- Paused-op state files (`git-shadow-sync`, `git-shadow-finish`) share one implementation in `lib/state-file.sh` (`state_file`, `state_save`, `state_load`, `state_clear`, `state_active`).

### Fixed

- `feature sync` no longer rewrites the checkpoint on the up-to-date path: the prior checkpoint's local pointer is kept, so unpublished commits stay publishable instead of being silently marked published.
- `feature publish` now warns and exits 1 when the publish range is empty yet the public tree differs from the `@local` head, instead of silently reporting "No publishable commits".
- TypeScript declaration files (`*.d.ts`) are excluded from the triple-slash marker scan by default, so `/// <reference ...>` directives no longer block the commit guard or publish.
- Publish replay skips empty cherry-picks (initially-empty commits and commits whose content already exists on the replay base) with a note instead of aborting on the raw git error; version-gated `--empty=drop` handling on git ≥ 2.45.
- The publish range excludes merge commits and commits reachable from `<public_base>@local` on feature branches, so base-derived commits no longer fail replay.
- `git shadow doctor` warns on doc-comment directives (e.g. `/// <reference`, `/// <summary`) in public trees or the staged index that are not covered by `LOCAL_COMMENT_EXCLUDE`, and warns on committed base/base@local drift without a patch sidecar.
- Tree comparison ignores the hook files `install-hooks` manages when the hooks dir is a working-tree directory (husky repos): `.husky/pre-commit` and `.husky/pre-push` divergence no longer blocks publish.

## [1.4.0] — 2026-09-26

### Added

- `git shadow feature list [--json]` — read-only inventory of open feature pairs: name, dedicated worktree path (`-` when the pair lives in the main checkout), checkpoint summary, and publishable count. Registered in the help text and in bash/zsh/fish completions.

### Fixed

- `feature start --worktree` now cleans up after a failed worktree creation: the leftover worktree (directory and registration) is force-removed and both feature branches created by that run are deleted together, instead of leaving the user manual `git branch -D` recovery steps.

### Changed

- `lib/patches.sh`: all sidecar check/apply/reverse paths share one internal apply ladder; `patches_strip` included.
- `lib/check.sh`: publishable-commit counting centralized in one helper used by `status`, `doctor`, and `feature list`; the publish check returns its temporary branch via a caller-named variable instead of encoding it on stdout.
- CI: shellcheck gate now covers `install.sh` and `completions/git-shadow.bash`; completion `COMPREPLY` assignments use `mapfile` (SC2207).
- `package.json`: dropped the stale `scripts/` entry from `files`.


## [1.3.5] — 2026-09-10

### Fixed

- `git shadow check public` no longer rejects public `.git-shadow/` paths such as `.git-shadow/agent-policy.yaml`. It now only fails on the local-only subtrees `.git-shadow/annotations/` and `.git-shadow/patches/`, matching V50 and V51.

## [1.3.4] — 2026-09-10

### Fixed

- `commands/feature/finish.sh` + `lib/finish-state.sh`: `--keep-worktree` and `--keep-branches` are now persisted through a paused `feature finish`. `feature finish --continue` and `feature finish --mark-applied` restore the stored values, and re-supplying a keep flag widens the stored value to `1` without ever narrowing it.

### Changed

- `AGENTS.md`, `AGENTS.template.md`, `AGENTS.template.ultra.md`: updated after-merge finish workflow to document the `feature finish <name>` variant and keep-flag persistence semantics.

## [1.3.3] — 2026-09-10

### Added

- **Local patch sidecar transaction** — `patches_transaction` wraps every command that mutates the working tree or checks out a branch, so `.git-shadow/patches/` sidecars are always stripped before the operation and re-applied on every exit path, including nested calls and resumable pause paths.
- **`patches_check`** — `git shadow doctor` and `git shadow local apply` now verify sidecars against `HEAD` content and warn when an overlay is stale or orphaned.
- **`git shadow commit` patch+marker guard** — rejects a staged file that has both a `.git-shadow/patches/` sidecar and active `///` or `// @local` markers, preventing ambiguous public commits.

### Fixed

- `lib/patches.sh`: `patches_reapply` no longer has its `stderr` hidden inside `patches_transaction`, so degraded reapply methods and orphan warnings remain visible.
- `lib/patches.sh`: `patches_transaction` now correctly propagates a failing `patches_reapply` status.

## [1.3.0] — 2026-09-08

### Added

- **Diff-sync model** — public and `@local` branches are now independent history lines synchronized by net diffs and `[CHECKPOINT]` commits instead of merges and cherry-picks. Public branch SHAs are never rewritten, and merge, rebase, and squash public workflows are all supported.
- **Resumable sync and finish** — `feature sync`, `base sync`, and `feature finish` pause with conflict markers on apply conflicts and support `--continue` / `--abort`; `feature finish --mark-applied <sha>` records already-applied `[MEMORY]` commits.
- **`git shadow feature start --worktree|--worktree-dir <path>`** — create a git worktree hosting `<name>@local` under `WORKTREE_ROOT` or an explicit path. In-repo worktrees are hidden via shared `info/exclude` and `.git-shadow.env` is copied in.
- **`git shadow feature finish [<name>]`** — named finish from a base checkout, `--keep-worktree`, dirty-worktree and cwd-inside guards, and feature worktree cleanup before branch deletion.
- **`git shadow doctor`** — read-only diagnostics: version skew, in-progress sync/finish state, per-`@local` checkpoint summary, hook status, unpromoted files, `.gitattributes`, and worktree checks (`WORKTREE_ROOT` validity, stale/orphaned registrations, base-branch holders).
- **`git shadow push <branch>`** — push helper that sets `GIT_SHADOW=1` and auto-configures upstream on first push.
- **`git shadow check public <branch>`** — audit a public branch for unpromoted local-only files.
- **`WORKTREE_ROOT` config key** — parent directory for `--worktree` feature worktrees.

### Fixed

- `patch_ids_for` no longer returns failure when a range ends in a merge or empty-diff commit; previously `feature finish` and sync could abort silently under `set -e`/`pipefail`.
- `sync --continue` records the actual `diff_start` in the `[SYNC]` range and patch-ids.
- Sync/finish state files and hook detection resolve via `--git-common-dir` / `--git-path`, so state is shared across linked worktrees.

## [1.2.0] — 2026-09-06

### Added

- **`git shadow commit -m "<message>"`** — split staged source into a clean public commit and a `[MEMORY]` sidecar. Extracts `///` and `// @local` markers into `.git-shadow/annotations/<relpath>` and re-anchors existing records by hunk key.
- **`git shadow show --with-annotations <file>`** — render the committed source file with stored markers overlaid without modifying the working tree.
- **`git shadow annotations reapply [path]`** — write markers from `.git-shadow/annotations/` back into the working tree as unstaged changes, refusing to overwrite non-marker changes.
- **Local-comment guards** — the pre-commit hook on `@local` branches, `git shadow feature publish`, and `git shadow check public` now reject `///`, `// @local`, and `.git-shadow/annotations/` paths in public-tracked content.
- **Updated docs and completions** — help, shell completions, and AGENTS.md reflect the in-source marker workflow.

### Changed

- Consolidated shared helpers in `lib/`: single `sync_command_run` for feature/base sync, `sync_apply_and_commit`, `sync_reanchor_and_checkpoint`, `guard_staged_files`/`guard_tree`, `install_hook_file`, `_config_unquote`, `_load_config_file`, `ui_emit`, and `_branch_transform`.
- Updated AGENTS.md and added workflow templates.

### Fixed

- `git shadow feature publish` now aborts with an error naming the offending commit and path when the check pass fails, instead of reporting "No publishable commits". Added a `check_missing_paths` pre-flight that flags public commits modifying or deleting paths absent from the public tree being replayed.

## [1.1.1] — 2026-03-23

### Added

- **`git shadow feature sync --merge`** — alternative sync mode for shared shadow branches (pushed to a remote, where rebase would rewrite history).
  Merges the public branch into the shadow branch with per-file conflict handling: files without local comment markers are auto-resolved in favour of the public branch; files containing local comments pause for manual resolution so annotations are never silently overwritten.

### Fixed

- `feature/sync.sh` — `--abort` now correctly handles both rebase-in-progress and merge-in-progress states.
- `feature/sync.sh` — `--continue` now correctly handles both rebase and merge in-progress states.

---

## [1.1.0] — 2026-03-23

### Added

- **`git shadow feature sync`** — rebase the shadow branch onto its public counterpart.
  Auto-resolves code conflicts in favour of the public branch; pauses for manual resolution on `[MEMORY]` commits so local AI context is never silently overwritten.
  Supports `--continue` and `--abort` to drive the underlying rebase.

- **`git shadow feature sync --merge`** — alternative sync mode for shared shadow branches (pushed to a remote, where rebase would rewrite history).
  Merges the public branch into the shadow branch with per-file conflict handling: files without local comment markers are auto-resolved in favour of the public branch; files containing local comments pause for manual resolution so annotations are never silently overwritten.

- **`git shadow feature start` (no argument)** — smart context detection when invoked without a branch name.
  - On a public branch with no existing shadow: creates the shadow branch and switches to it.
  - On a public branch with an existing shadow: warns and prints the checkout command.
  - On a shadow branch: exits with an error.

- **`git shadow commit` auto-`[MEMORY]`** — when all staged content consists of local comment markers, automatically creates a `[MEMORY]` commit with the original files instead of silently doing nothing.

- **`git shadow feature publish --push`** — optional flag to push the public branch to `origin` immediately after publishing.

- **`git shadow feature publish` always returns to shadow branch** — after publish completes (with or without `--push`), the command always switches back to the originating `@local` branch.

### Fixed

- `strip-local-comments.sh` — new files whose entire content is local comment markers were left as empty blobs in the index, blocking the auto-`[MEMORY]` path. Empty new files are now removed from the index with `git rm --cached`.
- `commit.sh` — `git add .` was replaced with a targeted add of the originally staged files to avoid staging unrelated working-tree changes.
- `feature/sync.sh` — `[MEMORY]` prefix detection used `grep -qE "^[MEMORY]"` which treated the brackets as a regex character class. Replaced with a bash `==` glob match.
- `feature/sync.sh` — empty commits (code conflicts resolved to the public branch version) caused an infinite loop. Detected via `git diff --cached --quiet` and skipped with `git rebase --skip`.
- `feature/sync.sh` — `git rebase --continue --no-edit` is not accepted by the apply rebase backend. Replaced with `GIT_EDITOR=true git rebase --continue`.
- `feature/sync.sh` — `--continue` failed with "unable to determine current branch" because git operates in detached HEAD during a rebase. Branch name is now read from `.git/rebase-merge/head-name`.

## [1.0.4] — 2026-03-09

- feat(promote): add `git shadow promote` command + publish-time detection
- feat(ui): add semantic colour design system

## [1.0.3] and earlier

See git log.
