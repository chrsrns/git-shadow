#!/usr/bin/env bats

# Regression tests for V106: git range walkers must not silently swallow
# invalid or non-ancestor ranges and return empty output.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck disable=SC1091
  source "$TOOLKIT_ROOT/lib/common.sh"

  git symbolic-ref HEAD refs/heads/main
  echo "initial" > file.txt
  git add file.txt
  git commit -q -m "initial"
  INITIAL_SHA="$(git rev-parse HEAD)"

  git checkout -q -b branch-a
  echo "a" >> file.txt
  git add file.txt
  git commit -q -m "branch-a change"
  BRANCH_A_SHA="$(git rev-parse HEAD)"

  git checkout -q -b branch-b "$INITIAL_SHA"
  echo "b" > other.txt
  git add other.txt
  git commit -q -m "branch-b change"
  BRANCH_B_SHA="$(git rev-parse HEAD)"

  NULL_SHA="0000000000000000000000000000000000000000"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "sync_patch_ids fails on invalid start sha" {
  run sync_patch_ids "$NULL_SHA" "$BRANCH_B_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot list commits"* ]]
}

@test "check_public_commits fails on invalid checkpoint sha" {
  run check_public_commits "$BRANCH_B_SHA" "$NULL_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot list commits"* ]]
}
