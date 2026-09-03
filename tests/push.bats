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

@test "push exits 1 when no upstream is configured" {
  git checkout -q main
  git checkout -q -b orphan-feature
  run git shadow push orphan-feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"No upstream"* ]]
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
