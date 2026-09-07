#!/usr/bin/env bats

# Regression test for git shadow push with branch names that contain a slash
# (e.g., feature/re-anchor-migration).

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

  # Create a namespaced feature branch
  git shadow feature start feature/slash
  echo "feature code" > feature.txt
  git add feature.txt
  git commit -q -m "feat: slash feature code"
  git shadow feature publish

  git checkout -q feature/slash
  GIT_SHADOW=1 git push -q -u origin feature/slash
}

teardown() {
  rm -rf "$TEST_DIR" "$ORIGIN_DIR"
}

@test "push pushes a namespaced public branch to its upstream" {
  # Add a new commit to the namespaced public branch
  echo "extra" >> feature.txt
  git add feature.txt
  GIT_SHADOW=1 git commit -q -m "fix: more slash feature code"

  before="$(git rev-parse feature/slash)"

  run git shadow push feature/slash
  [ "$status" -eq 0 ]

  cd "$ORIGIN_DIR"
  after="$(git rev-parse feature/slash)"
  cd "$TEST_DIR"
  [ "$before" = "$after" ]
}
