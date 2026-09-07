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
  git commit -q -m "initial"

  # Create a bare remote
  ORIGIN_DIR="$(mktemp -d)"
  git clone -q --bare . "$ORIGIN_DIR"
  git remote add origin "$ORIGIN_DIR"

  # Ensure tests use the toolkit under test.
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  git shadow feature start test-feature
  echo "feature code" > feature.txt
  git add feature.txt
  git commit -q -m "feat: feature code"
  git shadow feature publish

  git checkout -q test-feature
  GIT_SHADOW=1 git push -q -u origin test-feature
}

teardown() {
  rm -rf "$TEST_DIR" "$ORIGIN_DIR"
}

@test "push requires a branch name" {
  run git shadow push
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing"* ]]
}

@test "push rejects a @local branch" {
  git checkout -q test-feature@local
  run git shadow push test-feature@local
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot push a shadow branch"* ]]
}

@test "push exits 1 when branch does not exist" {
  run git shadow push nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "push auto-sets upstream via sole remote when none configured" {
  git checkout -q main
  git checkout -q -b orphan-feature
  echo "orphan" > orphan.txt
  git add orphan.txt
  GIT_SHADOW=1 git commit -q -m "feat: orphan"

  run git shadow push orphan-feature
  [ "$status" -eq 0 ]

  upstream="$(git for-each-ref --format='%(upstream:short)' refs/heads/orphan-feature)"
  [ "$upstream" = "origin/orphan-feature" ]

  local_sha="$(git rev-parse orphan-feature)"
  remote_sha="$(git -C "$ORIGIN_DIR" rev-parse refs/heads/orphan-feature)"
  [ "$local_sha" = "$remote_sha" ]
}

@test "push aborts when no upstream and multiple remotes exist" {
  SECOND_DIR="$(mktemp -d)"
  git clone -q --bare . "$SECOND_DIR"
  git remote add upstream "$SECOND_DIR"

  git checkout -q main
  git checkout -q -b orphan-feature
  run git shadow push orphan-feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"multiple remotes"* ]]
  # upstream must not be set implicitly
  [ -z "$(git for-each-ref --format='%(upstream:short)' refs/heads/orphan-feature)" ]

  git remote remove upstream
  rm -rf "$SECOND_DIR"
}

@test "push aborts when no upstream and no remotes exist" {
  git remote remove origin

  git checkout -q main
  git checkout -q -b orphan-feature
  run git shadow push orphan-feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"No remotes"* ]]
}

@test "push pushes a public branch to its upstream" {
  # Add a new commit to the public branch
  echo "extra" >> feature.txt
  git add feature.txt
  GIT_SHADOW=1 git commit -q -m "fix: more feature code"

  before="$(git rev-parse test-feature)"

  run git shadow push test-feature
  [ "$status" -eq 0 ]

  cd "$ORIGIN_DIR"
  after="$(git rev-parse test-feature)"
  cd "$TEST_DIR"
  [ "$before" = "$after" ]
}
