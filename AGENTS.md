# AGENTS.md

This repository uses **git shadow**.

If you are an AI coding agent, assistant, or automated contributor, you must follow the workflow described below.

---

## Core principle

```text
code for thinking  ≠  code for collaboration
```

This repository separates development into two layers:

```text
feature/x@local   → thinking workspace
feature/x         → published branch
```

The `@local` branch is for exploration, reasoning, debug code, pseudo-code, and local-only comments.
The public branch is for clean, reviewable, shareable code.

## Commit types on `@local`

### Public work

Use `git shadow commit -m "<public message>"` whenever a staged public file contains local-only markers (`///` or `// @local`).
This command:

- extracts the marked blocks into `.git-shadow/annotations/<relpath>`,
- writes a clean public commit with the markers removed,
- writes a `[MEMORY]` sidecar commit that stores the extracted annotations.

`///` and `// @local` are **never** stripped automatically during `feature publish`; they must be extracted first by `git shadow commit`.

### Public work without local markers

If the staged files contain no local markers, a plain `git commit` is allowed.

### Local-only reasoning

Use `git commit -m "[MEMORY] <subject>"` for notes, scratch files, plans, debug logs, and anything that should stay on `@local` only.

`[MEMORY]` commits must not modify files already tracked by the public branch. Put reasoning in separate local-only files (for example, `notes/`, `memory/`, `.ai/`). `git shadow` filters `[MEMORY]` commits during `feature publish`; public commits must not depend on them.

## Local annotations workflow

- Write local-only reasoning directly in source files with `///` or `// @local` markers.
- `.git-shadow/annotations/<relpath>` stores extracted markers and is gitignored; it is a local-only sidecar.
- Run `git shadow commit -m "<public message>"` on a `@local` branch to split staged changes into a clean public commit and a `[MEMORY]` sidecar.
- Use `git shadow show --with-annotations <file>` to view the committed source with markers overlaid.
- Use `git shadow annotations reapply [path]` to write markers back into the working tree for editing.
- Do not rely on publish-time stripping; always use `git shadow commit` to remove markers from public commits before `git shadow feature publish`.

## Agent behavior rules

1. Default to the shadow branch

Always prefer working in the `@local` branch when available. Example: `feature/login@local`.
Do not treat the public branch as the primary workspace for iterative reasoning.

2. Use `@local` as a cognitive workspace

In the shadow branch, you are encouraged to write and preserve:

- reasoning comments,
- implementation plans,
- pseudo-code,
- temporary debug code,
- intermediate refactors,
- local-only TODO notes,
- hypotheses and exploration artifacts.

These artifacts are useful in `@local` and should not be removed prematurely.
Put them into separate `[MEMORY] <subject>` commits so they are filtered from the public branch.

3. Do not prematurely optimize for cleanliness in `@local`

When working in the shadow branch:

- prefer explicit reasoning over premature cleanup,
- keep useful comments if they help thinking,
- keep exploratory code while a task is still in progress,
- do not erase cognitive context too early.

In `@local`, clarity of thought is more important than polish.

4. Publish only clean code

Before publishing to the public branch, choose what to keep as local-only artifacts such as:

- reasoning notes,
- debug logs,
- temporary probes,
- unfinished pseudo-code,
- local-only planning notes,
- architecture and design markdowns.

Anything that helps later reasoning but is not ready to share must be committed in a separate `[MEMORY] <subject>` commit.
`[MEMORY]` commits must not modify files already tracked by the public branch.

Published code must be:

- readable,
- minimal,
- production-ready,
- suitable for code review.

## Preferred workflow

```bash
# 1. Keep the local base up to date
git shadow base sync

# 2. Start a feature
git shadow feature start <branch-name>

# 3. Work on <branch-name>@local
#    - Use `git shadow commit -m "..."` for public code that contains `///` or `// @local` markers.
#    - Use `git commit` for public code without markers.
#    - Use `git commit -m "[MEMORY] ..."` for local-only reasoning files.

# 4. Check status before publishing
git shadow status

# 5. Publish public commits and create a new checkpoint
git shadow feature publish

# 6. Push the public branch
git shadow push <branch-name>
```

If the remote public branch moves while you are still working on `@local`, run `git shadow feature sync [--recover|--continue|--abort]`.
Use `--recover` when the public branch was rebased but the patches are identical.
Use `--continue` after resolving a conflict.
Use `--abort` to stop an in-progress sync.

If the public branch was force-pushed or rewritten and patch-id recovery cannot match, use `git shadow re-anchor <branch@local>`.

After the PR is merged:

```bash
git shadow feature finish
git shadow push <public-base-branch>
```

### Direct commits on public branches

For release chores or hotfixes that should not go through a feature pair, commit directly on the public branch and let `base sync` absorb it:

```bash
git checkout main
GIT_SHADOW=1 git commit -m "chore(release): ..."
git shadow push main
git shadow base sync
```

The pre-commit hook requires `GIT_SHADOW=1` on public branches. Do not commit on `<base>@local` first — there is no base publish path; publishing exists only for feature branches.

If you are asked to finalize work, prefer publication through git shadow rather than manually copying noisy changes to the public branch.

## Safety checks

- Run `git shadow check public <branch>` to audit a public branch for unpromoted files or leaked local-only content.
- The pre-commit hook rejects public-tracked files that contain `///` or `// @local` markers unless `GIT_SHADOW=1` is set.
- `git shadow feature publish` runs a diff-based check pass and also scans the replayed tree for local markers and `.git-shadow/annotations/` paths.

## Git shadow configuration

Use this command to retrieve the effective git shadow configuration:

```bash
git shadow config show --json
```

## Separation of responsibilities

| Layer            | Purpose                          |
|------------------|----------------------------------|
| `@local`         | think, explore, debug, iterate   |
| public branch    | publish, review, share           |

### Agent decision rule

Use this rule at all times:

If a change helps thinking, it belongs in `@local`.
If a change is ready to be shared, it belongs in the public branch.

## Intent

The goal is not only to keep the repository clean.

The goal is to preserve a valuable truth:

```text
how code is produced ≠ how code is shared
```

git shadow exists to protect both.

Short reminder:

Use `@local` to think.
Use publish to share.
