#!/usr/bin/env bats

# Unit tests for lib/common.sh repository-probe helpers.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$TOOLKIT_ROOT/lib/common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "repo_root prints the worktree toplevel" {
  git init -q repo
  cd repo
  run repo_root
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/repo" ]
}

@test "repo_root returns 1 outside a repo" {
  run repo_root
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "repo_root prints the toplevel from a subdirectory" {
  git init -q repo
  mkdir -p repo/sub/dir
  cd repo/sub/dir
  run repo_root
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/repo" ]
}

@test "repo_root_or_pwd prints $PWD outside a repo" {
  run repo_root_or_pwd
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR" ]
}

@test "repo_root_or_pwd prints the toplevel inside a repo" {
  git init -q repo
  cd repo
  run repo_root_or_pwd
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/repo" ]
}
