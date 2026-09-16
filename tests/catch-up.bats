#!/usr/bin/env bats

# Regression tests for the manual catch-up recipe of a long-lived feature
# whose base has advanced.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main

  printf 'base\n' > base.txt
  printf 'overlay-target\n' > app.ts
  git add base.txt app.ts
  git commit -q -m "initial"

  # Ensure tests use the toolkit under test.
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  PATCH_BACKUP="$(mktemp -t catch-up-overlay-XXXXXX.patch)"
}

teardown() {
  rm -rf "$TEST_DIR"
  rm -f "$PATCH_BACKUP"
}

@test "catch-up recipe works without active local patch overlay" {
  git shadow feature start feature/x

  # Public feature work on a file the base does not touch.
  echo "feature work" > feature.txt
  git add feature.txt
  git commit -q -m "feat: add feature"

  git shadow feature publish

  # Advance the public base.
  git checkout -q main
  echo "main advance" >> base.txt
  git add base.txt
  GIT_SHADOW=1 git commit -q -m "main advance"

  # Manual catch-up recipe.
  git checkout -q main@local
  run git shadow base sync
  [ "$status" -eq 0 ]

  git checkout -q feature/x
  git rebase main

  git checkout -q feature/x@local
  git rebase main@local

  git shadow re-anchor feature/x@local

  # Verify final state.
  [ "$(cat base.txt)" = $'base\nmain advance' ]
  [ "$(cat feature.txt)" = "feature work" ]
  [ "$(cat app.ts)" = "overlay-target" ]

  run git shadow status
  [ "$status" -eq 0 ]
  [[ "$output" == *"publishable  : 0"* ]]
  [[ "$output" == *"public-ahead : 0"* ]]
  [[ "$output" == *"diverged     : false"* ]]

  run git shadow feature publish
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
}

@test "catch-up recipe works with active local patch overlay" {
  git shadow feature start feature/x

  # Apply, save, and remove a local patch overlay before any public commit.
  echo "local debug" >> app.ts
  git shadow local add app.ts
  cp .git-shadow/patches/app.ts.patch "$PATCH_BACKUP"
  git shadow local rm --revert app.ts

  # Public feature work on a file the base does not touch.
  echo "feature work" > feature.txt
  git add feature.txt
  git commit -q -m "feat: add feature"

  git shadow feature publish

  # Advance the public base on a file the overlay does not touch.
  git checkout -q main
  echo "main advance" >> base.txt
  git add base.txt
  GIT_SHADOW=1 git commit -q -m "main advance"

  # Manual catch-up recipe.
  git checkout -q main@local
  run git shadow base sync
  [ "$status" -eq 0 ]

  git checkout -q feature/x
  git rebase main

  git checkout -q feature/x@local
  git rebase main@local

  git shadow re-anchor feature/x@local

  # Re-apply the saved overlay and re-capture it as a local patch.
  git apply "$PATCH_BACKUP"
  git shadow local add app.ts

  # Verify final state.
  [ "$(cat base.txt)" = $'base\nmain advance' ]
  [ "$(cat feature.txt)" = "feature work" ]
  [ "$(cat app.ts)" = $'overlay-target\nlocal debug' ]
  [ -f .git-shadow/patches/app.ts.patch ]

  run git shadow status
  [ "$status" -eq 0 ]
  [[ "$output" == *"publishable  : 0"* ]]
  [[ "$output" == *"public-ahead : 0"* ]]
  [[ "$output" == *"diverged     : false"* ]]

  run git shadow feature publish
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
}
