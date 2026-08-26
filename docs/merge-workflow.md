# Merge-Only Workflow

The default `git shadow` workflow uses `git rebase` to keep a linear history. The merge-only workflow is an alternative that uses `git merge` instead. It preserves the original commit sequence and avoids rewriting `[MEMORY]` commits.

## When to use the merge workflow

Use the merge workflow when you:

- want to keep a visible merge history instead of a rebased linear history
- prefer not to rewrite `[MEMORY]` commits during `feature sync`
- collaborate on shadow branches that are pushed to a remote

## Commands

The merge workflow provides three commands that mirror the default `feature` workflow:

| Command | Purpose |
| --- | --- |
| `git shadow merge publish` | Cherry-pick clean code commits from `feature/x@local` to `feature/x` |
| `git shadow merge sync` | Merge the public branch into the shadow branch (`feature/x` → `feature/x@local`) |
| `git shadow merge finish` | Merge `main` into `main@local`, then merge `feature/x@local` into `main@local` |

## Workflow

```bash
# 1. Start a feature pair
git shadow feature start feature/x

# 2. Work on the shadow branch; use /// or ## for local reasoning comments
printf '/// validate token\nauth code\n' > src/auth.ts
git add src/auth.ts
git shadow commit -m "feat(auth): token validation"

# 3. Publish the clean commit to the public branch
git shadow merge publish

# 4. Open a PR and merge the public branch into main
#    (or merge it locally)
git checkout main
git merge --no-edit -m "feat: merge auth" feature/x

# 5. Sync the public branch into the shadow branch
git checkout feature/x@local
git shadow merge sync

# 6. Finish: integrate the feature into main@local
git shadow merge finish
```

## What each step does

### `git shadow merge publish`

Finds the non-`[MEMORY]` commits on the current `@local` branch and cherry-picks them to the public branch. It leaves the shadow branch unchanged.

### `git shadow merge sync`

Merges the public branch into the shadow branch and resolves conflicts automatically:

- If the local (`ours`) version of a file contains local comments, keep it.
- Otherwise, take the public (`theirs`) version.

This means new files that only exist on the public branch are added to the shadow branch, while local comments are preserved.

### `git shadow merge finish`

Runs two merges:

1. `main` → `main@local`
2. `feature/x@local` → `main@local`

For the first merge, the local base (`main@local`) wins when it contains local comments. For the second merge, the feature shadow branch (`feature/x@local`) wins when it contains local comments. This keeps local reasoning notes from both the base and the feature.

After the merges, the `feature/x` and `feature/x@local` branches are deleted by default. Use `--keep-branches` to preserve them.

## Conflict resolution

The merge workflow uses a shared resolver that checks each conflicted file for local comment markers:

- A side with local comments beats a side without.
- When both sides have local comments, the merge keeps the version that belongs to the side whose merge it is:
  - `merge sync` and the first `merge finish` merge prefer `ours`.
  - The final `merge finish` merge prefers `theirs` (the feature shadow branch).

If two branches have changed the same local-only file (for example `SPEC.md`) in incompatible ways, the resolver may pause or pick one side. Resolve these manually and run `git merge --continue`.

## Options

```bash
git shadow merge finish --keep-branches   # do not delete feature/x and feature/x@local
git shadow merge finish --no-pull         # skip git pull on main and main@local
git shadow merge finish --force           # delete branches even if not fully merged
```

## Differences from the default rebase workflow

| Default (`feature`) | Merge (`merge`) |
| --- | --- |
| `feature sync` rebases `feature/x@local` onto `feature/x` | `merge sync` merges `feature/x` into `feature/x@local` |
| `[MEMORY]` commits are rewritten | `[MEMORY]` commits stay in place |
| Linear public history | Merge commits appear in shadow and local base history |
| `feature finish` relies on a direct ancestor relationship | `merge finish` relies on merge-base resolution |

## Caveats

- `merge publish` is currently a wrapper around `feature publish` because the cherry-pick logic is identical.
- `merge finish` requires that the public branch has already been merged into `main`. It does not merge `feature/x` into `main` for you.
- If the shadow branch has not been synced with `merge sync` before `merge finish`, the final merge may produce `CONFLICT (add/add)` on new files.
