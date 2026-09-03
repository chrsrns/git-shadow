# Troubleshooting

This page covers failure recovery for the most common situations where git shadow operations go wrong.

> **Quick state check** — when something feels off, start here:
> ```bash
> git status          # what branch, what is staged
> git shadow status   # shadow/public pair health
> git log --oneline -5
> ```

---

## Table of contents

1. [`feature publish` check pass failed](#1-feature-publish-check-pass-failed)
2. [Conflicts during `feature sync` / `base sync`](#2-conflicts-during-feature-sync--base-sync)
3. [`[MEMORY]` cherry-pick conflict during `feature finish`](#3-memory-cherry-pick-conflict-during-feature-finish)
4. [Public branch is not an ancestor of the checkpoint](#4-public-branch-is-not-an-ancestor-of-the-checkpoint)
5. [`git shadow status` reports `diverged`](#5-git-shadow-status-reports-diverged)
6. [`git shadow check public` finds unpromoted files](#6-git-shadow-check-public-finds-unpromoted-files)
7. [When to use `--recover` vs `re-anchor`](#7-when-to-use---recover-vs-re-anchor)
8. [Removing git shadow hooks from a project](#8-removing-git-shadow-hooks-from-a-project)
9. [Adopting git shadow on an existing repo](#9-adopting-git-shadow-on-an-existing-repo)
10. [Binary not found after installation](#10-binary-not-found-after-installation)

---

## 1. `feature publish` check pass failed

**Symptom:** `git shadow feature publish` aborts with a message like:

```
Check pass failed: public diff does not match filtered local diff
```

**What happened:** `feature publish` replays the public commits (non-`[MEMORY]` and non-`[CHECKPOINT]`) from the `@local` branch onto the public checkpoint base, then compares the resulting diff to the public diff. A mismatch means the public branch and the `@local` branch do not have the same content for the files that should be public.

**Common causes:**

- A `[MEMORY]` commit modified a file that is also tracked by the public branch.
- A non-`[MEMORY]` commit contains local-only content in a public-tracked file.
- The public branch moved past the checkpoint SHA stored in the latest `[CHECKPOINT]`.
- A file was renamed or deleted on one side but not the other.

**Recovery:**

```bash
# 1. Check the branch-pair state
git shadow status

# 2. Compare the public and local trees
git diff feature/login feature/login@local
```

- If `git shadow status` shows `public-ahead` greater than zero, sync first:
  ```bash
  git shadow feature sync
  git shadow feature publish
  ```
- If the public *base* has moved, run `git shadow base sync` first.
- Inspect the diff for **public-tracked files**. If a `[MEMORY]` commit changed a tracked file, split the change:
  - Move the local-only content to a new local-only file.
  - Commit it as `[MEMORY] <subject>`.
  - Revert the tracked-file change (use `git rebase -i` or `git commit --amend`).
- Re-run `git shadow feature publish`.

---

## 2. Conflicts during `feature sync` / `base sync`

**Symptom:** `git shadow feature sync` or `git shadow base sync` stops with:

```
error: patch failed: src/auth.ts:12
error: src/auth.ts: patch does not apply
```

**What happened:** The command is applying the *net diff* from the checkpoint public SHA to the current public HEAD onto the `@local` branch. A hunk in that net diff overlaps with changes that are already on `@local`.

**Where you are:** You are on the `@local` branch with conflict markers in the working tree and a sync in progress.

**Recovery:**

```bash
# 1. See which files are conflicted
git status

# 2. Open each conflicting file and resolve the markers (<<<<, ====, >>>>)
# 3. Stage the resolved files
git add src/auth.ts

# 4. Continue the sync
git shadow feature sync --continue
# or, for the base:
git shadow base sync --continue
```

**To abort and return to the last checkpoint:**

```bash
git shadow feature sync --abort
# or
git shadow base sync --abort
```

**Prevention:** Sync regularly, especially before adding more local changes. Keep `[MEMORY]` commits limited to **new local-only files**; they must not modify files already tracked by the public branch.

---

## 3. `[MEMORY]` cherry-pick conflict during `feature finish`

**Symptom:** `git shadow feature finish` aborts with:

```
CONFLICT (content): Merge conflict in notes/feature-x.md
error: could not apply <sha>... [MEMORY] feature x notes
```

or a base net-diff conflict message.

**What happened:** `feature finish` does the following:

1. Pulls / fast-forwards the public base.
2. Applies the base net diff onto the `@local` base (without creating an intermediate checkpoint).
3. Cherry-picks each `[MEMORY]` commit from the feature's `@local` branch onto the `@local` base.
4. Creates one final `[CHECKPOINT]` and deletes the feature branches.

A conflict can happen in the base net diff or in any of the `[MEMORY]` cherry-picks.

**Where you are:** You are on the local base branch (e.g. `main@local`) with conflict markers or a cherry-pick in progress.

**Recovery:**

```bash
# 1. Check which files are in conflict
git status

# 2. Resolve each conflicting file
# 3. Stage and commit the resolved files
git add notes/feature-x.md
git commit -m "[MEMORY] resolved finish conflict"

# 4. Re-run finish — it skips already-applied base net diff and [MEMORY] commits
git shadow feature finish
```

If the conflict is in a `[MEMORY]` file that accidentally touched a public-tracked file, move the local-only content to a new file and re-run.

**Note:** `feature finish` aborts and **preserves both feature branches** on conflict, so no work is lost.

---

## 4. Public branch is not an ancestor of the checkpoint

**Symptom:** `git shadow feature sync`, `git shadow base sync`, `git shadow feature publish`, or `git shadow feature finish` aborts with:

```
checkpoint public SHA <sha> is not an ancestor of <public-branch>
```

**What happened:** The public branch was rewritten (rebase, squash, amend, or a history rewrite on the remote). The commit stored in the latest `[CHECKPOINT]` no longer appears in the public branch history, so the tool cannot safely apply the recorded diff range.

**Recovery:**

1. **Try `--recover`** if the public branch was only rebased on the same base with identical patches:
   ```bash
   git shadow feature sync --recover
   # or, for the base:
   git shadow base sync --recover
   ```
   `--recover` uses patch-id matching to find the most recent checkpointed patch in the new public history and applies the net diff from that commit to the new public HEAD. It then creates a new `[CHECKPOINT]`.

2. **Use `re-anchor`** if `--recover` cannot find a matching patch-id, or if the base changed, or the patches were squashed/rewritten:
   ```bash
   git shadow re-anchor feature/login@local
   # or, for the base:
   git shadow re-anchor main@local
   ```
   `re-anchor` fetches the remote for the corresponding public branch, fast-forwards/resets the public branch to the remote, verifies that the `@local` tree contains the new public tree for all public-tracked files, and creates a fresh `[CHECKPOINT]`. It intentionally discards the previous checkpoint.

   `re-anchor` requires a clean working tree and no in-progress sync/publish.

3. If `re-anchor` fails because the local tree is missing or differs on a public-tracked file, compare the trees:
   ```bash
   git diff feature/login feature/login@local
   ```
   Move local-only changes into new `[MEMORY]` files and then `re-anchor`.

---

## 5. `git shadow status` reports `diverged`

**Symptom:** `git shadow status` prints:

```
publishable: 0
public-ahead: 0
diverged: true
```

or a status line saying `diverged`.

**What it means:** The `@local` tree and the current public tree differ on at least one public-tracked file, but there are no public commits to sync. This usually means a `[MEMORY]` or other local commit modified a file that is also tracked by the public branch.

**Recovery:**

```bash
# Compare the public and local trees
git diff feature/login feature/login@local
```

- If the differences are only in files that were **created by `[MEMORY]` commits and do not exist on the public branch**, those are expected and ignored by `git shadow status`.
- If the differences are in public-tracked files, split them:
  - Move local-only content to a new local-only file.
  - Commit it as `[MEMORY] <subject>`.
  - Revert the change to the public-tracked file.
  - Run `git shadow feature sync` or `git shadow base sync` to rebuild the checkpoint.
- If `public-ahead` is greater than zero, sync first:
  ```bash
  git shadow feature sync
  git shadow status
  ```

---

## 6. `git shadow check public` finds unpromoted files

**Symptom:** `git shadow check public main` or `git shadow check public feature/x` exits non-zero and lists files:

```
Unpromoted local-only files on public branch 'main':
  src/scratchpad.ts (first added on main@local as: [MEMORY] scratch notes)
```

**What it means:** A file that appears on the public branch was first created in a `[MEMORY]` commit on the local counterpart. In the diff-sync model this is a leak: `[MEMORY]` commits must not modify files tracked by the public branch, and files that start as local-only should not end up on the public branch.

**Recovery:**

- If the file is truly local-only (notes, scratch, plans), remove it from the public branch and keep it only on `@local` in a `[MEMORY]` commit that **adds a new file**.
- If the file should be public, remove it from the public branch, add it as a normal public commit on `@local` (or commit it on the public branch with `GIT_SHADOW=1`), and re-publish/push.
- After fixing, re-run `git shadow check public <branch>`.

**Note:** The diff-sync model has no `shadow: promote` step and no `LOCAL_COMMENT_PATTERN`. Local-only content belongs in separate files and is committed manually as `[MEMORY]`.

---

## 7. When to use `--recover` vs `re-anchor`

Use **`--recover`** when:

- The public branch was rebased on the **same base**.
- The individual patches are **identical** (same `patch-id`s).
- The order may have been linearized, but the diffs are the same.

`--recover` is the safe, non-destructive option: it keeps your `@local` work untouched and creates a new `[CHECKPOINT]`.

Use **`re-anchor`** when:

- The public branch was **squashed** or otherwise rewritten.
- The **base** of the public branch changed.
- `--recover` could not find a checkpointed `patch-id`.
- You want a clean reset of the checkpoint range.

`re-anchor` discards the previous checkpoint and starts a new one from the current public and `@local` trees. It requires the `@local` tree to contain the new public tree for every public-tracked file; otherwise it aborts.

If both fail, the public and local lines have truly diverged. Resolve the content differences manually, then `re-anchor`.

---

## 8. Removing git shadow hooks from a project

**When to do this:** You want to stop using git shadow in a project, or you need to temporarily disable the hooks.

**Identify the hook files:**

```bash
git config --get core.hooksPath   # prints custom hook path if set, otherwise default is .git/hooks/
```

**Option A: remove only the git shadow block (recommended)**

The hooks installed by git shadow are delimited by a marker comment. Open the hook file and delete the git shadow section:

```bash
# pre-commit hook
nano .git/hooks/pre-commit   # or vim, or your editor
# Delete lines from "# git-shadow pre-commit hook" to "exit 0" (the git-shadow block)

# pre-push hook
nano .git/hooks/pre-push
# Delete lines from "# git-shadow pre-push hook" to "exit 0"
```

If the hook file only contained the git shadow block, you can delete it entirely:

```bash
rm .git/hooks/pre-commit
rm .git/hooks/pre-push
```

**Option B: bypass the hooks for one commit/push**

```bash
git commit --no-verify -m "your message"
git push --no-verify
```

Use this sparingly. The hooks in the diff-sync model protect public branches from accidentally receiving `[MEMORY]` or other local-only commits.

---

## 9. Adopting git shadow on an existing repo

**Scenario:** You have an existing project and want to adopt the shadow branch pattern.

**Step 1: install hooks**

```bash
git shadow install-hooks
```

**Step 2: ensure a shadow base branch exists**

For new features, `git shadow feature start` creates `main@local` from `main` and adds the first `[CHECKPOINT]` if it does not exist.

If you want to set it up manually:

```bash
git checkout main
git checkout -b main@local
```

**Step 3: create a feature pair and start working**

```bash
git shadow feature start feature/login
# work on feature/login@local
```

Use `git commit` for public commits and `git commit -m "[MEMORY] ..."` for local-only notes. `[MEMORY]` commits must add **new local-only files** (notes, scratch files, plans); they must not modify files already tracked by the public branch.

**Step 4: publish and sync**

```bash
git shadow feature publish
git shadow push feature/login
# after the PR is merged
git shadow feature finish
git shadow push main
```

**For an existing public branch without a shadow:**

Create the shadow branch at the same commit and bring it under checkpoint control:

```bash
git checkout feature/login
git checkout -b feature/login@local
git shadow re-anchor feature/login@local
```

`re-anchor` creates the first `[CHECKPOINT]` for the pair. The public branch must already contain the content you want the shadow branch to contain.

---

## 10. Binary not found after installation

**Symptom:** `git shadow` or `git-shadow` returns `command not found`.

**Curl / manual install:**

The binary is linked to `~/.local/bin`. Check if that directory is in your `PATH`:

```bash
echo $PATH | grep -o '\.local/bin'
```

If not, add this line to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then reload:

```bash
source ~/.bashrc   # or ~/.zshrc
```

**npm install:**

Check where npm places global binaries:

```bash
npm bin -g
```

Add that path to your `PATH` if it is not already there.

**Verify the installation:**

```bash
git-shadow version
git shadow help
```

If the binary exists but still fails with an error like `TOOLKIT_ROOT not found`, the symlink may be pointing to a deleted or moved installation directory. Re-run the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/filozofer/git-shadow/main/install.sh | bash
```
