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
  # Add a publishable public commit and a [MEMORY] commit
  echo "feature code" > feature.txt
  git add feature.txt
  git commit -q -m "feat: feature code"

  echo "memory" > notes.md
  git add notes.md
  git commit -q -m "[MEMORY] agent context"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "status exits 1 on unknown branch" {
  git checkout -q main
  git checkout -q -b unrelated
  run git shadow status
  [ "$status" -eq 1 ]
  [[ "$output" == *"Not a Git Shadow branch"* ]]
}

@test "status exits 1 in detached HEAD" {
  sha="$(git rev-parse HEAD)"
  git checkout -q "$sha"
  run git shadow status
  [ "$status" -eq 1 ]
}

@test "status exits 0 from shadow branch" {
  run git shadow status
  [ "$status" -eq 0 ]
  [[ "$output" == *"publishable"* ]]
}

@test "status exits 0 from public branch" {
  git checkout -q test-feature
  run git shadow status
  [ "$status" -eq 0 ]
  [[ "$output" == *"publishable"* ]]
}

@test "status reports branch type shadow" {
  run git shadow status
  [[ "$output" == *"Branch type    : shadow"* ]]
}

@test "status reports branch type public" {
  git checkout -q test-feature
  run git shadow status
  [[ "$output" == *"Branch type    : public"* ]]
}

@test "status reports 1 publishable commit pending" {
  run git shadow status
  [[ "$output" == *"publishable  : 1"* ]]
}

@test "status reports 0 publishable commits after publish" {
  git shadow feature publish
  git checkout -q test-feature@local
  run git shadow status
  [[ "$output" == *"publishable  : 0"* ]]
}

@test "status reports public branch not ahead when in sync" {
  run git shadow status
  [[ "$output" == *"public-ahead : 0"* ]]
}

@test "status reports public branch ahead" {
  git shadow feature publish
  git checkout -q test-feature
  echo "extra" > extra.txt
  git add extra.txt
  GIT_SHADOW=1 git commit -q -m "fix: extra on public"
  git checkout -q test-feature@local
  run git shadow status
  [[ "$output" == *"public-ahead : 1"* ]]
}

@test "status reports diverged" {
  git shadow feature publish
  git checkout -q test-feature
  echo "extra" > extra.txt
  git add extra.txt
  GIT_SHADOW=1 git commit -q -m "fix: extra on public"
  git checkout -q test-feature@local
  echo "shadow extra" > shadow.txt
  git add shadow.txt
  git commit -q -m "feat: shadow extra"
  run git shadow status
  [[ "$output" == *"diverged     : true"* ]]
}

@test "status reports public branch missing" {
  git branch -D test-feature
  run git shadow status
  [ "$status" -eq 0 ]
  [[ "$output" == *"public branch missing"* ]]
}

@test "status --json exits 0" {
  run git shadow status --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"publishable\""* ]]
  [[ "$output" == *"\"public_ahead\""* ]]
  [[ "$output" == *"\"diverged\""* ]]
}

@test "status --json reports 1 publishable" {
  run git shadow status --json
  [[ "$output" == *'"publishable":1'* ]]
}

@test "status --json reports 0 public-ahead" {
  run git shadow status --json
  [[ "$output" == *'"public_ahead":0'* ]]
}
