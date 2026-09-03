#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  git symbolic-ref HEAD refs/heads/main
  echo "app code" > app.ts
  git add app.ts
  git commit -qm "initial"

  git checkout -q -b "main@local"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "local rebuild creates a rebuild branch with deduplicated memory commits" {
  # Add a memory-only file
  git checkout -q main@local
  echo "note 1" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] first note"

  # Cherry-pick it to create an identical duplicate on the same branch
  original_sha="$(git rev-parse HEAD)"
  git cherry-pick -m 1 "$original_sha" --allow-empty || true
  git commit -qm "[MEMORY] duplicated note" --allow-empty

  run git shadow local rebuild
  [ "$status" -eq 0 ]

  # The new branch should exist
  git rev-parse --verify main@local-rebuild

  # The new branch should only contain one [MEMORY] commit for the same note
  memory_count="$(git log --format='%s' main@local-rebuild -- | grep -c '^\[MEMORY\]' || true)"
  [ "$memory_count" -eq 1 ]

  # The new branch tip should contain the notes file
  git cat-file -e "main@local-rebuild:notes.md"
}

@test "local rebuild without --force leaves the original branch unchanged" {
  git checkout -q main@local
  echo "note 1" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] first note"

  original_tip="$(git rev-parse main@local)"
  run git shadow local rebuild
  [ "$status" -eq 0 ]

  [ "$(git rev-parse main@local)" = "$original_tip" ]
  git rev-parse --verify main@local-rebuild
}

@test "local rebuild --force replaces the local branch and keeps a backup" {
  git checkout -q main@local
  echo "note 1" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] first note"

  run git shadow local rebuild --force
  [ "$status" -eq 0 ]

  # Original is renamed to main@local-old
  git rev-parse --verify main@local-old

  # main@local is now the new linear branch
  git rev-parse --verify main@local
  git rev-parse --verify main@local-old

  # The current branch is the rebuilt one
  [ "$(git branch --show-current)" = "main@local" ]

  # main@local contains the notes file
  git cat-file -e "main@local:notes.md"
}

@test "local rebuild resolves a public branch argument to its local counterpart" {
  git checkout -q main@local
  echo "note 1" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] first note"

  git checkout -q main
  run git shadow local rebuild main
  [ "$status" -eq 0 ]

  git rev-parse --verify main@local-rebuild
}
