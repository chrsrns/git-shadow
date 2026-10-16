#!/usr/bin/env bats

# Tests for git shadow local status.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  printf '%s\n' ".git-shadow/annotations/" ".git-shadow/patches/" > .gitignore
  echo "initial" > file.txt
  echo "tracked" > real.txt
  git add .gitignore file.txt real.txt
  git commit -qm "initial"

  git shadow feature start my-feature >/dev/null
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "local status prints the classified table" {
  echo "local edit" >> file.txt
  git shadow local add file.txt >/dev/null
  echo "dirt" >> real.txt
  echo "new" > untracked.txt

  run git shadow local status
  [ "$status" -eq 0 ]
  [[ "$output" == *" M file.txt [patch]"* ]]
  [[ "$output" == *" M real.txt [dirty]"* ]]
  [[ "$output" == *"?? untracked.txt [untracked]"* ]]
}

@test "local status labels a drifted overlay patch-stale" {
  echo "local edit" >> file.txt
  git shadow local add file.txt >/dev/null
  echo "extra" >> file.txt

  run git shadow local status
  [ "$status" -eq 0 ]
  [[ "$output" == *"file.txt [patch-stale]"* ]]
}

@test "local status prints No local changes on a fully clean tree" {
  run git shadow local status
  [ "$status" -eq 0 ]
  [[ "$output" == *"No local changes."* ]]
}

@test "local status lists unapplied sidecars on an otherwise clean tree" {
  echo "local edit" >> file.txt
  git shadow local add file.txt >/dev/null
  git checkout -q HEAD -- file.txt

  run git shadow local status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unapplied patches:"* ]]
  [[ "$output" == *"file.txt"* ]]
  [[ "$output" != *"No local changes."* ]]
}

@test "local status --porcelain prints class records and unapplied last" {
  echo "local edit" >> file.txt
  git shadow local add file.txt >/dev/null
  echo "dirt" >> real.txt
  echo "other" > real2.txt
  git add real2.txt && git commit -qm "add real2"
  echo "sidecar" >> real2.txt
  git shadow local add real2.txt >/dev/null
  git checkout -q HEAD -- real2.txt

  run git shadow local status --porcelain
  [ "$status" -eq 0 ]
  [[ "$output" == *" M file.txt patch"$'\n'* || "$output" == *$'\n'" M file.txt patch"* ]]
  [[ "$output" == *" M real.txt dirty"* ]]
  [[ "$output" == *"-  real2.txt unapplied"* ]]
  # Unapplied record sorts after the dirty records.
  [[ "$output" =~ " M real.txt dirty".*"-  real2.txt unapplied" ]]
}

@test "local status --json prints entries, unapplied set, and counts" {
  echo "local edit" >> file.txt
  git shadow local add file.txt >/dev/null
  echo "dirt" >> real.txt

  run git shadow local status --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"path":"file.txt","xy":" M","class":"patch"'* ]]
  [[ "$output" == *'"class":"dirty"'* ]]
  [[ "$output" == *'"unapplied":[]'* ]]
  [[ "$output" == *'"local_patches":1'* ]]
  [[ "$output" == *'"unpatched_dirty":1'* ]]
}

@test "local status --json escapes quote-bearing paths" {
  echo 'x' > 'we"ird.txt'
  echo "dirt" >> 'we"ird.txt' 2>/dev/null || true
  # untracked is enough — still carries a quote byte.
  run git shadow local status --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'we\"ird.txt'* ]]
}

@test "local status --porcelain C-quotes a newline-bearing path" {
  printf 'x\n' > $'nl\nname.txt'

  run git shadow local status --porcelain
  [ "$status" -eq 0 ]
  [[ "$output" == *'"nl\nname.txt" untracked'* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

@test "local status combines modes last-wins" {
  echo "dirt" >> real.txt
  run git shadow local status --porcelain --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"entries"'* ]]
  run git shadow local status --json --porcelain
  [ "$status" -eq 0 ]
  [[ "$output" == *" M real.txt dirty"* ]]
  [[ "$output" != *'"entries"'* ]]
}

@test "local status works from a subdirectory" {
  echo "dirt" >> real.txt
  mkdir -p sub && cd sub
  run git shadow local status
  [ "$status" -eq 0 ]
  [[ "$output" == *" M real.txt [dirty]"* ]]
}

@test "local status refuses during a paused sync" {
  : > .git/git-shadow-sync
  run git shadow local status
  [ "$status" -ne 0 ]
  [[ "$output" == *"sync is in progress"* ]]
}

@test "local status errors instead of claiming clean when enumeration fails" {
  # Corrupt the index: rev-parse still resolves the toplevel, status fails.
  printf 'corrupt' > .git/index

  run git shadow local status
  [ "$status" -eq 1 ]
  [[ "$output" != *"No local changes."* ]]
}
