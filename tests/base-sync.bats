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
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "base sync exits 1 when not on a local base branch" {
  run git shadow base sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"@local"* ]]
}

@test "base sync creates main@local with initial checkpoint" {
  git checkout -q -b main@local
  run git shadow base sync
  [ "$status" -eq 0 ]

  latest="$(git log -1 --format='%H' main@local)"
  subject="$(git log -1 --format='%s' "$latest")"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "base sync applies a new public commit to main@local" {
  git checkout -q -b main@local
  git shadow base sync

  # Add a public commit
  git checkout -q main
  echo "public change" >> file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -q -m "public change"

  git checkout -q main@local
  run git shadow base sync
  [ "$status" -eq 0 ]

  [ "$(cat file.txt)" = $'initial\npublic change' ]

  # Latest commit on main@local should be a checkpoint
  subject="$(git log -1 --format='%s' main@local)"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "base sync --abort restores local branch" {
  git checkout -q -b main@local
  git shadow base sync

  # Public and local diverge in a conflicting way
  git checkout -q main
  echo "public" > file.txt
  GIT_SHADOW=1 git add file.txt && GIT_SHADOW=1 git commit -q -m "public change"

  git checkout -q main@local
  echo "local" > file.txt
  git add file.txt
  git commit -q -m "local change"

  run git shadow base sync
  [ "$status" -ne 0 ]

  run git shadow base sync --abort
  [ "$status" -eq 0 ]
  [ "$(cat file.txt)" = "local" ]
  [[ "$output" != *"conflict"* ]]
}
