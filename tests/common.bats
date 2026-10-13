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

# Create a repo with a two-path merge conflict; one path contains a space.
# One unmerged path lives under a directory outside any invocation cwd
# subdirectory used by the tests below.
_setup_conflict() {
  git init -qb main repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  mkdir -p dir
  echo a > "f one.txt"
  echo b > "dir/g.txt"
  git add .
  git commit -qm base
  git checkout -qb side
  echo side-a > "f one.txt"
  echo side-b > "dir/g.txt"
  git commit -qam side
  git checkout -q main
  echo main-a > "f one.txt"
  echo main-b > "dir/g.txt"
  git commit -qam main
  git merge side >/dev/null 2>&1 || true
}

@test "conflicted_paths prints the sorted-unique unmerged set" {
  _setup_conflict
  run conflicted_paths
  [ "$status" -eq 0 ]
  [ "$output" = "dir/g.txt
f one.txt" ]
}

@test "conflicted_paths prints a space-containing path whole" {
  _setup_conflict
  run conflicted_paths
  [ "$status" -eq 0 ]
  [[ "$output" == *"f one.txt"* ]]
}

@test "conflicted_paths reports toplevel-relative paths from a subdirectory" {
  _setup_conflict
  mkdir -p sub
  cd sub
  run conflicted_paths
  [ "$status" -eq 0 ]
  [ "$output" = "dir/g.txt
f one.txt" ]
}
