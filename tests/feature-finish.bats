#!/usr/bin/env bats

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

  git shadow feature start test-feature
  echo "feature code" > feature.txt
  git add feature.txt
  git commit -qm "feat: feature code"
  git shadow feature publish

  # Simulate the feature being merged into main
  git checkout -q main
  git merge -q --no-edit test-feature

  # Return to the local feature branch so feature finish can detect it
  git checkout -q "test-feature@local"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "feature finish exits 0 after feature is merged into develop" {
  run git shadow feature finish --no-pull
  [ "$status" -eq 0 ]
}

@test "feature finish outputs completion message" {
  run git shadow feature finish --no-pull
  [[ "$output" == *"Feature finished successfully"* ]]
}

@test "feature finish applies public base changes to main@local" {
  git shadow feature finish --no-pull
  git checkout -q "main@local"
  result="$(cat feature.txt)"
  [ "$result" = "feature code" ]
}

@test "feature finish creates a checkpoint on main@local" {
  git shadow feature finish --no-pull
  subject="$(git log -1 --format='%s' main@local)"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "feature finish deletes the public feature branch" {
  git shadow feature finish --no-pull
  run git branch --list "test-feature"
  [ -z "$output" ]
}

@test "feature finish deletes the local feature branch" {
  git shadow feature finish --no-pull
  run git branch --list "test-feature@local"
  [ -z "$output" ]
}

@test "feature finish exits 1 when run from the base branch" {
  git checkout -q main
  run git shadow feature finish --no-pull
  [ "$status" -eq 1 ]
}

@test "feature finish exits 1 when base sync has conflicts" {
  # Setup: public base and feature both modified the same file
  git checkout -q main
  git merge -q --no-edit test-feature

  # Commit a conflicting change on main AFTER the feature was merged
  git checkout -q main
  echo "conflicting main change" > feature.txt
  git add feature.txt
  git commit -qm "chore: post-merge change on main"

  # Also put the conflicting content on main@local
  git checkout -q "main@local"
  echo "conflicting local change" > feature.txt
  git add feature.txt
  git commit -qm "chore: conflicting local"

  # Return to feature branch and attempt finish
  git checkout -q "test-feature@local"
  run git shadow feature finish --no-pull
  [ "$status" -ne 0 ]
}

@test "feature finish exits 1 when cherry-picking [MEMORY] conflicts" {
  git checkout -q main
  git merge -q --no-edit test-feature

  # Create a [MEMORY] on the feature that touches a public-tracked file
  git checkout -q "test-feature@local"
  echo "local change" > feature.txt
  git add feature.txt
  git commit -qm "[MEMORY] local change"

  # Modify the same file on main@local independently
  git checkout -q "main@local"
  echo "local base independent" > feature.txt
  git add feature.txt
  git commit -qm "chore: independent change on main@local"

  # Return to feature and attempt finish
  git checkout -q "test-feature@local"
  run git shadow feature finish --no-pull
  [ "$status" -ne 0 ]
}

@test "feature finish preserves branches on [MEMORY] conflict" {
  git checkout -q main
  git merge -q --no-edit test-feature

  git checkout -q "test-feature@local"
  echo "local change" > feature.txt
  git add feature.txt
  git commit -qm "[MEMORY] local change"

  git checkout -q "main@local"
  echo "local base independent" > feature.txt
  git add feature.txt
  git commit -qm "chore: independent change on main@local"

  git checkout -q "test-feature@local"
  git shadow feature finish --no-pull 2>/dev/null || true

  git show-ref --verify --quiet "refs/heads/test-feature"
  git show-ref --verify --quiet "refs/heads/test-feature@local"
}
