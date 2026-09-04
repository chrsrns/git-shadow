# Shadow Branch Pattern

## Intent

Separate **development scaffolding** from **published code** by maintaining a local shadow branch alongside a public branch.

This pattern allows developers to keep personal reasoning structures (comments, notes, temporary code) locally while publishing only clean commits to the shared repository.

---

## Motivation

When developing complex features, developers often rely on temporary structures to reason about the code:

* exploratory comments
* pseudo-code
* debug logs
* TODO notes
* intermediate refactors
* structural hints for algorithm steps

These elements help structure thinking and reduce cognitive load during development. However, they do not always belong in the shared codebase.

Teams often prefer to keep repository history clean and focused on the final implementation. This can create friction between:

* **individual development practices**
* **team repository conventions**

The Shadow Branch Pattern resolves this tension by separating the **thinking layer** from the **published layer**.

---

## Structure

For each public branch, maintain a corresponding **shadow branch**.

Example:

```
feature/login         → public branch
feature/login@local   → shadow branch
```

Typical base branches:

```
main               → public base branch
main@local         → shadow base branch
```

The shadow branch may contain development scaffolding that is not intended to be shared.

The public branch contains only the commits intended for collaboration.

---

## Workflow

1. Create both a public branch and its shadow counterpart.

```
feature/x
feature/x@local
```

2. Perform development work on the shadow branch.

```
feature/x@local
```

3. Keep development scaffolding locally.

- Use `///` or `// @local` markers in source files for local-only reasoning.
- Run `git shadow commit -m "<public message>"` on a `@local` branch to split staged changes into a clean public commit and a `[MEMORY]` sidecar stored under `.git-shadow/annotations/<relpath>`.
- Use `git shadow show --with-annotations <file>` to view the committed source with markers overlaid.
- Use `git shadow annotations reapply [path]` to write markers back into the working tree for editing.

```bash
# Edit source with /// or // @local markers, then stage
git shadow commit -m "add auth flow"
```

`[MEMORY]` commits, including `.git-shadow/annotations/` sidecars, are kept only on the shadow branch and are filtered out when publishing to the public branch.

4. Publish clean commits to the public branch.

```
feature/x
```

5. Push the public branch to the shared repository and follow the normal team workflow (pull request, merge request, etc.).

6. Finish the feature with `git shadow feature finish`.

```
main@local
```

This applies the base net diff and cherry-picks each `[MEMORY]` commit from the feature's shadow branch onto the shadow base branch, then creates a final `[CHECKPOINT]`. This preserves the local reasoning structures for future work.

---

## Benefits

**Cleaner repository history**

The shared repository contains only the code intended for collaboration.

**Reduced team friction**

Developers can use their preferred reasoning structures without forcing them into the shared codebase.

**Improved cognitive workflow**

Temporary scaffolding can remain available during development without polluting commit history.

**Clear separation of concerns**

```
shadow branch → thinking layer
public branch → collaboration layer
```

---

## Trade-offs

The pattern introduces additional complexity.

**More branches**

Each feature requires both a public branch and a shadow branch.

**Workflow discipline**

Developers must consistently publish from the shadow branch to the public branch.

**Tooling recommended**

Automation tools can simplify the workflow and reduce errors.

---

## When to Use This Pattern

The Shadow Branch Pattern works well when:

* developers keep reasoning notes, design docs, or pseudo-code in separate local files
* teams prefer a clean shared repository history
* development scaffolding is useful locally but undesirable in shared code
* the team is comfortable with slightly more advanced Git workflows

---

## When Not to Use This Pattern

This pattern may be unnecessary when:

* the team already accepts development comments in the repository
* the project uses extremely simple workflows (e.g., trunk-based development without feature branches)
* the team prefers minimal Git workflow complexity

---

## Related Concepts

The Shadow Branch Pattern shares ideas with several existing practices:

* **Stacked branches** (Graphite, ghstack)
* **Patch stack workflows** (StGit)
* **Debug vs release builds**
* **Exploratory notebooks vs production scripts**

In all cases, the underlying idea is similar:

> separate the environment used for exploration from the environment used for publication.

---

## Reference Implementation

The CLI tool **git shadow** implements this workflow and automates the operations required to manage shadow branches.

Example usage:

```bash
git shadow feature start feature/login
# work on feature/login@local; use `git shadow commit -m "..."` to split
# public work from `///` and `// @local` markers stored in .git-shadow/annotations/
# use `git shadow show --with-annotations <file>` to review annotated source
# use `git shadow annotations reapply [path]` to edit with markers again
git shadow feature publish
git shadow push feature/login
# after PR merge
git shadow feature finish
git shadow push main
```

The tool handles:

* shadow branch creation
* `[MEMORY]` commit filtering
* commit publication
* checkpoint-based net-diff synchronization

---

## Summary

The Shadow Branch Pattern introduces a simple idea:

```
keep the structures that help you think
publish only the code your team needs to read
```

By separating local reasoning scaffolding from shared repository history, teams can maintain clean codebases while allowing developers to work in the way that suits them best.
