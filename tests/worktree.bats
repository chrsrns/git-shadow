#!/usr/bin/env bats

# Unit and integration tests for lib/worktree.sh worktree helpers.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main
  echo "initial" > file.txt
  git add file.txt
  git commit -qm "initial"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"
  source "$TOOLKIT_ROOT/lib/common.sh"

  git branch "feat-x@local"
  WORKTREE_ROOT="$TEST_DIR/wts"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# worktree_sanitize_name
# ---------------------------------------------------------------------------

@test "worktree_sanitize_name replaces slashes with dashes" {
  run worktree_sanitize_name "feature/login"
  [ "$status" -eq 0 ]
  [ "$output" = "feature-login" ]
}

@test "worktree_sanitize_name handles nested slashes" {
  run worktree_sanitize_name "a/b/c"
  [ "$status" -eq 0 ]
  [ "$output" = "a-b-c" ]
}

@test "worktree_sanitize_name rejects empty result" {
  run worktree_sanitize_name ""
  [ "$status" -eq 1 ]
}

@test "worktree_sanitize_name rejects double dots" {
  run worktree_sanitize_name ".."
  [ "$status" -eq 1 ]
  run worktree_sanitize_name "a..b"
  [ "$status" -eq 1 ]
}

@test "worktree_sanitize_name rejects leading dash" {
  run worktree_sanitize_name "-x"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# worktree_path_for
# ---------------------------------------------------------------------------

@test "worktree_path_for aborts when WORKTREE_ROOT is unset" {
  unset WORKTREE_ROOT
  run worktree_path_for "feature/login"
  [ "$status" -eq 1 ]
  [[ "$output" == *"WORKTREE_ROOT"* ]]
  [[ "$output" == *"config set"* ]]
}

@test "worktree_path_for aborts on non-absolute WORKTREE_ROOT" {
  WORKTREE_ROOT="rel/dir"
  run worktree_path_for "feature/login"
  [ "$status" -eq 1 ]
  [[ "$output" == *"absolute"* ]]
}

@test "worktree_path_for expands leading tilde" {
  WORKTREE_ROOT="~/wts"
  run worktree_path_for "feature/login"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/wts/feature-login" ]
}

@test "worktree_path_for joins root and sanitized name" {
  run worktree_path_for "feature/login"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/wts/feature-login" ]
}

@test "worktree_path_for propagates invalid names" {
  run worktree_path_for ".."
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# worktree_validate_path
# ---------------------------------------------------------------------------

@test "worktree_validate_path accepts a nonexistent path" {
  run worktree_validate_path "$TEST_DIR/wts/feat-x" "feat-x@local"
  [ "$status" -eq 0 ]
}

@test "worktree_validate_path accepts an existing empty dir" {
  mkdir -p "$TEST_DIR/wts/feat-x"
  run worktree_validate_path "$TEST_DIR/wts/feat-x" "feat-x@local"
  [ "$status" -eq 0 ]
}

@test "worktree_validate_path rejects a non-empty dir" {
  mkdir -p "$TEST_DIR/wts/feat-x"
  echo "content" > "$TEST_DIR/wts/feat-x/file.txt"
  run worktree_validate_path "$TEST_DIR/wts/feat-x" "feat-x@local"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not empty"* ]]
}

@test "worktree_validate_path rejects a path already registered" {
  git worktree add -q "$TEST_DIR/wt1" "feat-x@local"
  run worktree_validate_path "$TEST_DIR/wt1" "other@local"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already"* ]]
}

@test "worktree_validate_path rejects a stale registered path" {
  git worktree add -q "$TEST_DIR/wt-stale" "feat-x@local"
  rm -rf "$TEST_DIR/wt-stale"
  run worktree_validate_path "$TEST_DIR/wt-stale" "other@local"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already"* ]]
}

@test "worktree_validate_path rejects an already-registered branch" {
  git worktree add -q "$TEST_DIR/wt1" "feat-x@local"
  run worktree_validate_path "$TEST_DIR/wt2" "feat-x@local"
  [ "$status" -eq 1 ]
  [[ "$output" == *"feat-x@local"* ]]
}

@test "worktree_validate_path skips branch check when branch not given" {
  git worktree add -q "$TEST_DIR/wt1" "feat-x@local"
  run worktree_validate_path "$TEST_DIR/wt2"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# worktree_add
# ---------------------------------------------------------------------------

@test "worktree_add creates a worktree on the @local branch" {
  run worktree_add "feat-x@local" "$TEST_DIR/wts/feat-x"
  [ "$status" -eq 0 ]
  [ -d "$TEST_DIR/wts/feat-x" ]
  current="$(git -C "$TEST_DIR/wts/feat-x" branch --show-current)"
  [ "$current" = "feat-x@local" ]
}

@test "worktree_add creates missing parent directories" {
  run worktree_add "feat-x@local" "$TEST_DIR/deep/nested/feat-x"
  [ "$status" -eq 0 ]
  [ -d "$TEST_DIR/deep/nested/feat-x" ]
}

@test "worktree_add resolves relative paths against cwd" {
  run worktree_add "feat-x@local" "wt-rel"
  [ "$status" -eq 0 ]
  [ -d "$TEST_DIR/wt-rel" ]
}

@test "worktree_add appends info/exclude for a path inside the main worktree" {
  run worktree_add "feat-x@local" "$TEST_DIR/wt-inner"
  [ "$status" -eq 0 ]
  grep -qxF "/wt-inner/" .git/info/exclude
}

@test "worktree_add uses deepest toplevel for nested worktree exclude" {
  git branch "feat-y@local"
  git worktree add -q "$TEST_DIR/wt1" "feat-x@local"
  run worktree_add "feat-y@local" "$TEST_DIR/wt1/sub"
  [ "$status" -eq 0 ]
  grep -qxF "/sub/" .git/info/exclude
  ! grep -qxF "/wt1/sub/" .git/info/exclude
}

@test "worktree_add does not touch info/exclude for outside paths" {
  run worktree_add "feat-x@local" "$TEST_DIR-outside/feat-x"
  [ "$status" -eq 0 ]
  if [[ -f .git/info/exclude ]]; then
    ! grep -qF "feat-x" .git/info/exclude
  fi
}

@test "worktree_add copies .git-shadow.env without symlink" {
  echo 'LOCAL_SUFFIX="@local"' > "$TEST_DIR/.git-shadow.env"
  run worktree_add "feat-x@local" "$TEST_DIR/wts/feat-x"
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/wts/feat-x/.git-shadow.env" ]
  [ ! -L "$TEST_DIR/wts/feat-x/.git-shadow.env" ]
  grep -q 'LOCAL_SUFFIX="@local"' "$TEST_DIR/wts/feat-x/.git-shadow.env"
}

@test "worktree_add succeeds without .git-shadow.env" {
  run worktree_add "feat-x@local" "$TEST_DIR/wts/feat-x"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_DIR/wts/feat-x/.git-shadow.env" ]
}

# ---------------------------------------------------------------------------
# worktree_is_dirty
# ---------------------------------------------------------------------------

@test "worktree_is_dirty returns 1 for a clean worktree" {
  git worktree add -q "$TEST_DIR/wt1" "feat-x@local"
  run worktree_is_dirty "$TEST_DIR/wt1"
  [ "$status" -eq 1 ]
}

@test "worktree_is_dirty detects untracked files" {
  git worktree add -q "$TEST_DIR/wt1" "feat-x@local"
  echo "junk" > "$TEST_DIR/wt1/untracked.txt"
  run worktree_is_dirty "$TEST_DIR/wt1"
  [ "$status" -eq 0 ]
}

@test "worktree_is_dirty detects modified tracked files" {
  git worktree add -q "$TEST_DIR/wt1" "feat-x@local"
  echo "changed" > "$TEST_DIR/wt1/file.txt"
  run worktree_is_dirty "$TEST_DIR/wt1"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# worktree_find_for_branch
# ---------------------------------------------------------------------------

@test "worktree_find_for_branch prints the registered path" {
  git worktree add -q "$TEST_DIR/wt1" "feat-x@local"
  run worktree_find_for_branch "feat-x@local"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/wt1" ]
}

@test "worktree_find_for_branch returns 1 when unregistered" {
  run worktree_find_for_branch "feat-x@local"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# worktree_remove
# ---------------------------------------------------------------------------

@test "worktree_remove removes a clean worktree" {
  git worktree add -q "$TEST_DIR/wt1" "feat-x@local"
  run worktree_remove "$TEST_DIR/wt1"
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_DIR/wt1" ]
  ! git worktree list --porcelain | grep -qxF "worktree $TEST_DIR/wt1"
}

@test "worktree_remove prunes a stale missing-dir registration" {
  git worktree add -q "$TEST_DIR/wt-stale" "feat-x@local"
  rm -rf "$TEST_DIR/wt-stale"
  run worktree_remove "$TEST_DIR/wt-stale"
  [ "$status" -eq 0 ]
  ! git worktree list --porcelain | grep -qxF "worktree $TEST_DIR/wt-stale"
}

@test "worktree_remove on an unregistered missing path is a no-op" {
  run worktree_remove "$TEST_DIR/never-existed"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# worktree_orphans
# ---------------------------------------------------------------------------

@test "worktree_orphans lists a worktree whose directory is missing" {
  git worktree add -q "$TEST_DIR/wt-stale" "feat-x@local"
  rm -rf "$TEST_DIR/wt-stale"
  run worktree_orphans
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_DIR/wt-stale"* ]]
  [[ "$output" == *"feat-x@local"* ]]
}

@test "worktree_orphans lists a worktree whose @local branch is gone" {
  git worktree add -q "$TEST_DIR/wt1" "feat-x@local"
  git update-ref -d "refs/heads/feat-x@local"
  run worktree_orphans
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_DIR/wt1"* ]]
}

@test "worktree_orphans prints nothing when all worktrees are healthy" {
  git worktree add -q "$TEST_DIR/wt1" "feat-x@local"
  run worktree_orphans
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# worktree_supported
# ---------------------------------------------------------------------------

@test "worktree_supported returns 0 on a modern git" {
  run worktree_supported
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# feature start --worktree / --worktree-dir
# ---------------------------------------------------------------------------

# Write a project config enabling WORKTREE_ROOT and ignore the env file so
# it never counts as worktree dirt.
_start_setup_env() {
  printf 'WORKTREE_ROOT="%s"\n' "$TEST_DIR/wts" > .git-shadow.env
  printf '.git-shadow.env\n' > .gitignore
  git add .gitignore
  git commit -qm "chore: ignore env file"
}

@test "feature start --worktree aborts when WORKTREE_ROOT is unset" {
  run git shadow feature start feat-wt --worktree
  [ "$status" -eq 1 ]
  [[ "$output" == *"WORKTREE_ROOT"* ]]
  [[ "$output" == *"config set"* ]]
  ! git show-ref --verify --quiet "refs/heads/feat-wt"
}

@test "feature start rejects --worktree and --worktree-dir together" {
  _start_setup_env
  run git shadow feature start feat-wt --worktree --worktree-dir "$TEST_DIR/x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "feature start --worktree requires a feature name" {
  _start_setup_env
  run git shadow feature start --worktree
  [ "$status" -eq 1 ]
}

@test "feature start --worktree creates worktree at root/sanitized on @local" {
  _start_setup_env
  run git shadow feature start feature/login --worktree
  [ "$status" -eq 0 ]
  [ -d "$TEST_DIR/wts/feature-login" ]
  current="$(git -C "$TEST_DIR/wts/feature-login" branch --show-current)"
  [ "$current" = "feature/login@local" ]
}

@test "feature start --worktree keeps the invoking checkout on the local base" {
  _start_setup_env
  run git shadow feature start feat-wt --worktree
  [ "$status" -eq 0 ]
  current="$(git branch --show-current)"
  [ "$current" = "main@local" ]
}

@test "feature start --worktree writes the initial checkpoint on the local feature" {
  _start_setup_env
  git shadow feature start feat-wt --worktree
  subject="$(git -C "$TEST_DIR/wts/feat-wt" log -1 --format='%s')"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "feature start --worktree-dir uses the path verbatim" {
  _start_setup_env
  run git shadow feature start feat-wt --worktree-dir "$TEST_DIR/custom-dir"
  [ "$status" -eq 0 ]
  [ -d "$TEST_DIR/custom-dir" ]
  current="$(git -C "$TEST_DIR/custom-dir" branch --show-current)"
  [ "$current" = "feat-wt@local" ]
}

@test "feature start --worktree-dir resolves a relative path against cwd" {
  _start_setup_env
  run git shadow feature start feat-wt --worktree-dir rel-wt
  [ "$status" -eq 0 ]
  [ -d "$TEST_DIR/rel-wt" ]
}

@test "feature start --worktree aborts on an existing non-empty dir" {
  _start_setup_env
  mkdir -p "$TEST_DIR/wts/feat-wt"
  echo "content" > "$TEST_DIR/wts/feat-wt/file.txt"
  run git shadow feature start feat-wt --worktree
  [ "$status" -eq 1 ]
  ! git show-ref --verify --quiet "refs/heads/feat-wt"
}

@test "feature start --worktree reuses an existing empty dir" {
  _start_setup_env
  mkdir -p "$TEST_DIR/wts/feat-wt"
  run git shadow feature start feat-wt --worktree
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/wts/feat-wt/file.txt" ]
}

@test "feature start --worktree-dir aborts on an already-registered path" {
  _start_setup_env
  git worktree add -q "$TEST_DIR/taken" "feat-x@local"
  run git shadow feature start feat-wt --worktree-dir "$TEST_DIR/taken"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already"* ]]
  ! git show-ref --verify --quiet "refs/heads/feat-wt"
}

@test "feature start --worktree inside the repo appends info/exclude" {
  _start_setup_env
  run git shadow feature start inner-wt --worktree-dir "$TEST_DIR/wt-inner"
  [ "$status" -eq 0 ]
  grep -qxF "/wt-inner/" .git/info/exclude
}

@test "feature start --worktree copies .git-shadow.env into the worktree" {
  _start_setup_env
  run git shadow feature start feat-wt --worktree
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/wts/feat-wt/.git-shadow.env" ]
  [ ! -L "$TEST_DIR/wts/feat-wt/.git-shadow.env" ]
  grep -q 'WORKTREE_ROOT=' "$TEST_DIR/wts/feat-wt/.git-shadow.env"
}

@test "feature start reports leftover branches when worktree creation fails" {
  _start_setup_env
  # A regular file where the parent dir should be: mkdir -p fails after
  # validation, exercising the post-branch-creation failure path.
  touch "$TEST_DIR/blocker"
  run git shadow feature start feat-wt --worktree-dir "$TEST_DIR/blocker/sub"
  [ "$status" -eq 1 ]
  git show-ref --verify --quiet "refs/heads/feat-wt"
  git show-ref --verify --quiet "refs/heads/feat-wt@local"
  [[ "$output" == *"feat-wt"* ]]
  [[ "$output" == *"feat-wt@local"* ]]
}

@test "feature start --worktree never checks out the public branch" {
  _start_setup_env
  git shadow feature start feat-wt --worktree
  ! git worktree list --porcelain | grep -qxF "branch refs/heads/feat-wt"
  current="$(git -C "$TEST_DIR/wts/feat-wt" branch --show-current)"
  [ "$current" = "feat-wt@local" ]
}

# ---------------------------------------------------------------------------
# feature finish worktree cleanup
# ---------------------------------------------------------------------------

# Build a merge-ready feature whose @local branch lives in a worktree:
# creates the pair, publishes a public commit, merges the public branch
# into main, and registers the worktree at $1. Leaves cwd on main@local.
_setup_finished_worktree_feature() {
  local wt_path="$1"
  git shadow feature start wt-feat >/dev/null
  echo "wf" > wf.txt
  git add wf.txt
  git commit -qm "feat: wf"
  git shadow feature publish >/dev/null
  git checkout -q main
  git merge -q --no-edit wt-feat
  git checkout -q "main@local"
  git worktree add -q "$wt_path" "wt-feat@local"
}

@test "feature finish <name> removes the feature worktree before deleting branches" {
  _setup_finished_worktree_feature "$TEST_DIR/wt-feat"
  run git shadow feature finish wt-feat --no-pull
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_DIR/wt-feat" ]
  ! git worktree list --porcelain | grep -qxF "worktree $TEST_DIR/wt-feat"
  ! git show-ref --verify --quiet "refs/heads/wt-feat"
  ! git show-ref --verify --quiet "refs/heads/wt-feat@local"
}

@test "feature finish --keep-worktree keeps worktree and @local, deletes public" {
  _setup_finished_worktree_feature "$TEST_DIR/wt-feat"
  run git shadow feature finish wt-feat --no-pull --keep-worktree
  [ "$status" -eq 0 ]
  [ -d "$TEST_DIR/wt-feat" ]
  current="$(git -C "$TEST_DIR/wt-feat" branch --show-current)"
  [ "$current" = "wt-feat@local" ]
  git show-ref --verify --quiet "refs/heads/wt-feat@local"
  ! git show-ref --verify --quiet "refs/heads/wt-feat"
}

@test "feature finish aborts on a dirty feature worktree and names recovery" {
  _setup_finished_worktree_feature "$TEST_DIR/wt-feat"
  echo "dirty" > "$TEST_DIR/wt-feat/dirty.txt"
  run git shadow feature finish wt-feat --no-pull
  [ "$status" -eq 1 ]
  [[ "$output" == *"$TEST_DIR/wt-feat"* ]]
  [[ "$output" == *"dirty.txt"* ]]
  [[ "$output" == *"--keep-worktree"* ]]
  # Nothing mutated: worktree still registered, branches still exist.
  git worktree list --porcelain | grep -qxF "worktree $TEST_DIR/wt-feat"
  git show-ref --verify --quiet "refs/heads/wt-feat"
  git show-ref --verify --quiet "refs/heads/wt-feat@local"
}

@test "bare feature finish inside a linked worktree refuses with cleanup steps" {
  _setup_finished_worktree_feature "$TEST_DIR/wt-feat"
  cd "$TEST_DIR/wt-feat"
  run git shadow feature finish
  [ "$status" -eq 1 ]
  [[ "$output" == *"worktree"* ]]
  [[ "$output" == *"git shadow feature finish wt-feat"* ]]
  git show-ref --verify --quiet "refs/heads/wt-feat@local"
}

@test "feature finish prunes a stale registration before branch deletion" {
  _setup_finished_worktree_feature "$TEST_DIR/wt-feat"
  rm -rf "$TEST_DIR/wt-feat"
  run git shadow feature finish wt-feat --no-pull
  [ "$status" -eq 0 ]
  ! git worktree list --porcelain | grep -qxF "worktree $TEST_DIR/wt-feat"
  ! git show-ref --verify --quiet "refs/heads/wt-feat@local"
}

@test "paused feature finish leaves the feature worktree in place" {
  _setup_finished_worktree_feature "$TEST_DIR/wt-feat"

  # A [MEMORY] on the feature that collides with an independent change on
  # main@local triggers the memory-replay pause.
  echo "feature memory" > "$TEST_DIR/wt-feat/file.txt"
  git -C "$TEST_DIR/wt-feat" add file.txt
  git -C "$TEST_DIR/wt-feat" commit -qm "[MEMORY] collide"
  echo "base memory" > file.txt
  git add file.txt
  git commit -qm "chore: independent base change"

  run git shadow feature finish wt-feat --no-pull
  [ "$status" -eq 1 ]
  [ -d "$TEST_DIR/wt-feat" ]
  git worktree list --porcelain | grep -qxF "worktree $TEST_DIR/wt-feat"
  git show-ref --verify --quiet "refs/heads/wt-feat@local"
}

@test "feature finish aborts when a base branch is held by another worktree" {
  _setup_finished_worktree_feature "$TEST_DIR/wt-feat"
  # Hold main@local in a second worktree; run finish from main.
  git checkout -q main
  git worktree add -q "$TEST_DIR/wt-base" "main@local"
  run git shadow feature finish wt-feat --no-pull
  [ "$status" -eq 1 ]
  [[ "$output" == *"$TEST_DIR/wt-base"* ]]
  [[ "$output" == *"git shadow feature finish wt-feat"* ]]
  git show-ref --verify --quiet "refs/heads/wt-feat@local"
}
