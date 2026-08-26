#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Public base
  printf "public content\n" > file.txt
  git add file.txt
  git commit -qm "base"
  base_sha=$(git rev-parse HEAD)

  # Ours modifies the public file
  git checkout -q -b ours
  printf "modified content\n" > file.txt
  git add file.txt
  git commit -qm "ours"

  # Theirs deletes the file
  git checkout -q "$base_sha"
  git checkout -q -b theirs
  git rm -q file.txt
  git commit -qm "theirs delete"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "resolve_merge_conflicts deletes a file when the chosen side has no version" {
  cd "$TEST_DIR"
  git checkout -q ours
  run git merge --no-commit theirs
  [ "$status" -ne 0 ]

  # Source the shared conflict resolver
  source "${BATS_TEST_DIRNAME}/../lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../lib/merge.sh"

  resolve_merge_conflicts "theirs" "skip-continue"

  # The resolver should have chosen deletion
  [ ! -f file.txt ]
  [ "$(git diff --cached --name-status -- file.txt | cut -f1)" = "D" ]

  git commit -qm "resolved"

  # Resolved tree has no file
  [ ! -f file.txt ]
}
