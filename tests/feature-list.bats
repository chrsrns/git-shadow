#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Ensure tests use the toolkit under test.
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  git symbolic-ref HEAD refs/heads/develop
  echo "initial" > file.txt
  git add file.txt
  git commit -qm "initial"
  git shadow config set PUBLIC_BASE_BRANCH develop --project-config >/dev/null
  git checkout -q -b "develop@local"
  git checkout -q develop
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "feature list shows an open feature pair" {
  run git shadow feature start feat-a
  [ "$status" -eq 0 ]

  run git shadow feature list
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat-a"* ]]
  [[ "$output" == *"checkpoint"* ]]
  [[ "$output" == *"publishable"* ]]
}

@test "feature list --json emits an array with the feature fields" {
  run git shadow feature start feat-a
  [ "$status" -eq 0 ]

  run git shadow feature list --json
  [ "$status" -eq 0 ]
  [[ "$output" == "["* ]]
  [[ "$output" == *'"name":"feat-a"'* ]]
  # The just-started pair is checked out in the main worktree.
  [[ "$output" == *"\"worktree\":\"$TEST_DIR\""* ]]
  [[ "$output" == *'"checkpoint":"[CHECKPOINT] public:'* ]]
  [[ "$output" == *'"publishable":0'* ]]
}

@test "feature list reports - for a pair with no worktree and no checkpoint" {
  git checkout -q "develop@local"
  git branch "feat-b" develop
  git branch "feat-b@local"
  git checkout -q develop

  run git shadow feature list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name":"feat-b"'* ]]
  [[ "$output" == *'"worktree":"-"'* ]]
  [[ "$output" == *'"checkpoint":"-"'* ]]
  [[ "$output" == *'"publishable":0'* ]]
}

@test "feature list excludes the local base pair" {
  run git shadow feature list
  [ "$status" -eq 0 ]
  [[ "$output" != *"develop"* ]]

  run git shadow feature list --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "feature list ignores an orphan @local branch without its public pair" {
  git checkout -q "develop@local"
  git branch "orphan@local"
  git checkout -q develop

  run git shadow feature list --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "feature list prints [] with no feature pairs under --json" {
  run git shadow feature list --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "feature list prints nothing with no feature pairs" {
  run git shadow feature list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "feature list sorts pairs by ascending name" {
  run git shadow feature start b-feat
  [ "$status" -eq 0 ]
  git checkout -q "develop@local"
  run git shadow feature start a-feat
  [ "$status" -eq 0 ]

  run git shadow feature list
  [ "$status" -eq 0 ]
  a_line="$(printf '%s\n' "$output" | grep -n '^a-feat$' | cut -d: -f1)"
  b_line="$(printf '%s\n' "$output" | grep -n '^b-feat$' | cut -d: -f1)"
  [ -n "$a_line" ]
  [ -n "$b_line" ]
  [ "$a_line" -lt "$b_line" ]
}

@test "feature list does not mutate refs or state" {
  run git shadow feature start feat-a
  [ "$status" -eq 0 ]
  before="$(git for-each-ref --format='%(refname) %(objectname)' refs/heads/)"

  run git shadow feature list --json
  [ "$status" -eq 0 ]
  after="$(git for-each-ref --format='%(refname) %(objectname)' refs/heads/)"
  [ "$before" = "$after" ]
}
