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
  git checkout -q -b "main@local"
  git checkout -q main

  # Create feature, add code with a local comment
  git shadow feature start test-feature
  printf '/// local comment\nreal code\n' > feature.txt
  git add feature.txt
  git shadow commit -m "feat: real code"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "merge publish exits 1 when not on a @local branch" {
  git checkout -q test-feature
  run git shadow merge publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"@local"* ]]
}

@test "merge publish cherry-picks the code commit to the public branch" {
  git checkout -q test-feature@local
  run git shadow merge publish
  [ "$status" -eq 0 ]

  git checkout -q test-feature
  result="$(git log --oneline)"
  [[ "$result" == *"feat: real code"* ]]
  [[ "$result" != *"[MEMORY]"* ]]
}

@test "merge sync merges public branch into @local without losing local comments" {
  git checkout -q test-feature@local
  git shadow merge publish
  run git shadow merge sync
  [ "$status" -eq 0 ]

  git checkout -q test-feature@local
  [ -f feature.txt ]
  [ "$(cat feature.txt)" = $'/// local comment\nreal code' ]
}

@test "merge finish integrates the feature into main@local" {
  git checkout -q test-feature@local
  git shadow merge publish
  git shadow merge sync

  # Simulate the public feature being merged into main
  git checkout -q main
  git merge -q --no-edit -m "feat: merge test-feature" test-feature

  git checkout -q test-feature@local
  run git shadow merge finish --no-pull
  [ "$status" -eq 0 ]

  git checkout -q main@local
  [ -f feature.txt ]
  [ "$(cat feature.txt)" = $'/// local comment\nreal code' ]
}

@test "merge finish deletes the public and local feature branches" {
  git checkout -q test-feature@local
  git shadow merge publish
  git shadow merge sync

  git checkout -q main
  git merge -q --no-edit -m "feat: merge test-feature" test-feature

  git checkout -q test-feature@local
  run git shadow merge finish --no-pull
  [ "$status" -eq 0 ]

  run git branch --list "test-feature"
  [ -z "$output" ]
  run git branch --list "test-feature@local"
  [ -z "$output" ]
}
