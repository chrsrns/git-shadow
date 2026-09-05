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

  git symbolic-ref HEAD refs/heads/main
  echo "initial" > file.txt
  git add file.txt
  git commit -q -m "initial"

  git shadow feature start test-feature
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "check public requires a public branch" {
  git checkout -q test-feature@local
  run git shadow check public test-feature@local
  [ "$status" -eq 1 ]
  [[ "$output" == *"public branch"* ]]
}

@test "check public exits 0 when no unpromoted files" {
  echo "feature code" > feature.txt
  git add feature.txt
  git commit -q -m "feat: feature code"
  git shadow feature publish

  run git shadow check public test-feature
  [ "$status" -eq 0 ]
}

@test "check public flags a file added by [MEMORY] and pushed to public" {
  # Add a [MEMORY] file on the local branch
  echo "local note" > notes.md
  git add notes.md
  git commit -q -m "[MEMORY] local note"

  # Simulate the same file leaking to the public branch
  git checkout -q test-feature
  echo "local note" > notes.md
  git add notes.md
  GIT_SHADOW=1 git commit -q -m "feat: add notes"

  run git shadow check public test-feature
  [ "$status" -ne 0 ]
  [[ "$output" == *"notes.md"* ]]
}

@test "check public exits 0 when a public-tracked file was modified by [MEMORY]" {
  echo "feature code" > feature.txt
  git add feature.txt
  git commit -q -m "feat: feature code"
  git shadow feature publish

  # [MEMORY] modifies the public-tracked file
  git checkout -q test-feature@local
  echo "modified" > feature.txt
  git add feature.txt
  git commit -q -m "[MEMORY] tweak feature"

  # Simulate the same content leaking to the public branch
  git checkout -q test-feature
  echo "modified" > feature.txt
  git add feature.txt
  GIT_SHADOW=1 git commit -q -m "feat: update feature"

  run git shadow check public test-feature
  [ "$status" -eq 0 ]
}

@test "check public flags a file created by [MEMORY] even when later modified by a public commit" {
  # Add a [MEMORY] file on the local branch
  git checkout -q test-feature@local
  echo "local note" > notes.md
  git add notes.md
  git commit -q -m "[MEMORY] local note"

  # Later modify it with a public commit on the local branch
  echo "local note updated" > notes.md
  git add notes.md
  git commit -q -m "docs: update note"

  # Simulate the same updated content leaking to the public branch
  git checkout -q test-feature
  echo "local note updated" > notes.md
  git add notes.md
  GIT_SHADOW=1 git commit -q -m "feat: add notes"

  run git shadow check public test-feature
  [ "$status" -ne 0 ]
  [[ "$output" == *"notes.md"* ]]
}

@test "check public exits 0 when public and local differ" {
  echo "feature code" > feature.txt
  git add feature.txt
  git commit -q -m "feat: feature code"
  git shadow feature publish

  git checkout -q test-feature@local
  echo "local version" > feature.txt
  git add feature.txt
  git commit -q -m "[MEMORY] tweak feature"

  git checkout -q test-feature
  echo "public version" > feature.txt
  git add feature.txt
  GIT_SHADOW=1 git commit -q -m "feat: update feature"

  run git shadow check public test-feature
  [ "$status" -eq 0 ]
}
