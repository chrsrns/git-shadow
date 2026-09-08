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
