# AGENTS.md

This repository uses **git shadow**.

If you are an AI coding agent, assistant, or automated contributor, you must follow the workflow described below.

---

## Core principle

```text
code for thinking  ≠  code for collaboration
```

This repository separates development into two layers:

feature/x@local   → thinking workspace
feature/x         → published branch

The @local branch is for exploration, reasoning, debug code, pseudo-code, and local-only comments.
The public branch is for clean, reviewable, shareable code.

## Local comments workflow

- Write local-only reasoning directly in source files with `///` or `// @local` markers.
- `.git-shadow/annotations/<relpath>` stores extracted markers and is gitignored; it is a local-only sidecar.
- Run `git shadow commit -m "<public message>"` on a `@local` branch to split staged changes into a clean public commit and a `[MEMORY]` sidecar.
- Use `git shadow show --with-annotations <file>` to view the committed source with markers overlaid.
- Use `git shadow annotations reapply [path]` to write markers back into the working tree for editing.
- Do not rely on publish-time stripping; always use `git shadow commit` to remove markers from public commits before `git shadow feature publish`.

## Agent behavior rules

1. Default to the shadow branch

Always prefer working in the @local branch when available.
Example: feature/login@local
Do not treat the public branch as the primary workspace for iterative reasoning.

2. Use @local as a cognitive workspace

In the shadow branch, you are encouraged to write and preserve:
- reasoning comments
- implementation plans
- pseudo-code
- temporary debug code
- intermediate refactors
- local-only TODO notes
- hypotheses and exploration artifacts

These artifacts are useful in @local and should not be removed prematurely.
Put them into separate `[MEMORY] <subject>` commits so they are filtered from the public branch.

3. Do not prematurely optimize for cleanliness in @local

When working in the shadow branch:
- prefer explicit reasoning over premature cleanup
- keep useful comments if they help thinking
- keep exploratory code while a task is still in progress
- do not erase cognitive context too early

In @local, clarity of thought is more important than polish.

4. Publish only clean code

Before publishing to the public branch, choose what to keep as local-only artifacts such as:
- reasoning notes
- debug logs
- temporary probes
- unfinished pseudo-code
- local-only planning notes
- architecture and design markdowns

Anything that helps later reasoning but is not ready to share must be committed in a separate `[MEMORY] <subject>` commit. `[MEMORY]` commits must not modify files already tracked by the public branch. Put reasoning in separate local-only files (e.g., `notes/`, `memory/`, `.ai/`). `git shadow` filters `[MEMORY]` commits during `feature publish`; public commits must not depend on them.

Published code must be:
- readable
- minimal
- production-ready
- suitable for code review

5. Preferred workflow

```bash
git shadow feature start <branch-name>
# THEN WORK
# Use `git commit` for public content
# Use `git commit -m "[MEMORY] ..."` for local-only reasoning
git shadow feature publish
git shadow push <branch-name>
```

If you are asked to finalize work, prefer publication through git shadow rather than manually copying noisy changes to the public branch.

6. Git shadow configuration

Use this command to retrieve all the git shadow config :
```bash
git shadow config show --json
```

7. Separation of responsibilities
Layer	Purpose
@local	think, explore, debug, iterate
public branch	publish, review, share
Agent decision rule

Use this rule at all times:

If a change helps thinking, it belongs in @local.
If a change is ready to be shared, it belongs in the public branch.

## Intent

The goal is not only to keep the repository clean.

The goal is to preserve a valuable truth:
how code is produced ≠ how code is shared

git shadow exists to protect both.

Short reminder
Use @local to think.
Use publish to share.