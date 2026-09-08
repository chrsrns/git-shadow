#!/usr/bin/env bats

# Cross-worktree shared-state and hook-path tests: git-shadow state files
# and hooks live in the common .git dir, visible from every worktree.

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

  # Feature pair; free the @local branch, then host it in a worktree.
  git shadow feature start feat-foo >/dev/null
  git checkout -q "main@local"
  git worktree add -q "$TEST_DIR/wt" "feat-foo@local"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "sync paused inside a worktree blocks feature finish from the main checkout" {
  # Diverging change on the local branch inside the worktree.
  echo "local v" > "$TEST_DIR/wt/file.txt"
  git -C "$TEST_DIR/wt" add file.txt
  git -C "$TEST_DIR/wt" commit -qm "chore: local change"

  # Conflicting public change on the feature's public branch.
  git checkout -q feat-foo
  echo "public v" > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -qm "feat: public change"
  git checkout -q "main@local"

  # The sync pauses inside the worktree; the state lands in the common dir.
  run git -C "$TEST_DIR/wt" shadow feature sync
  [ "$status" -eq 1 ]
  [ -f ".git/git-shadow-sync" ]

  run git shadow feature finish
  [ "$status" -eq 1 ]
  [[ "$output" == *"sync is in progress"* ]]
}

@test "paused finish in the common dir blocks feature sync inside a worktree" {
  printf 'phase=base-diff\n' > "$(git rev-parse --git-common-dir)/git-shadow-finish"
  run git -C "$TEST_DIR/wt" shadow feature sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"finish"* ]]
}

@test "install-hooks inside a worktree installs into the shared hooks dir" {
  rm -rf .git/hooks
  run git -C "$TEST_DIR/wt" shadow install-hooks
  [ "$status" -eq 0 ]
  [ -f ".git/hooks/pre-commit" ]
  [ -f ".git/hooks/pre-push" ]
}

@test "detect_hook_file inside a worktree resolves the shared hooks dir" {
  run bash -c "cd '$TEST_DIR/wt' && git rev-parse --git-path hooks/pre-commit"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/.git/hooks/pre-commit" ]
}
