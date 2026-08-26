#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Public base
  git symbolic-ref HEAD refs/heads/main
  echo "app code" > app.ts
  git add app.ts
  git commit -qm "initial"

  # Local counterpart
  git checkout -q -b "main@local"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Shadow commits
# ---------------------------------------------------------------------------

@test "check public exits 1 when [MEMORY] commit is on public branch" {
  git checkout -q main
  echo "x" >> app.ts
  git add app.ts
  git commit -qm "[MEMORY] local note"
  git checkout -q main@local

  run git shadow check public main
  [ "$status" -ne 0 ]
  [[ "$output" == *"[MEMORY]"* ]]
}

@test "check public exits 0 on a clean public branch" {
  git checkout -q main
  run git shadow check public main
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]] || [[ "$output" == *"ok"* ]]
}

# ---------------------------------------------------------------------------
# Local comments in tree
# ---------------------------------------------------------------------------

@test "check public exits 1 when a file with local comments is on public branch" {
  git checkout -q main
  printf "/// local note\napp code\n" > app.ts
  git add app.ts
  git commit -qm "feat: update app"
  git checkout -q main@local

  run git shadow check public main
  [ "$status" -ne 0 ]
  [[ "$output" == *"local comments"* ]] || [[ "$output" == *"app.ts"* ]]
}

@test "check public respects LOCAL_COMMENT_EXCLUDE" {
  git checkout -q main
  printf "## heading\n" > notes.md
  git add notes.md
  git commit -qm "docs: notes"
  git checkout -q main@local

  run git shadow check public main
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Branch resolution
# ---------------------------------------------------------------------------

@test "check public from a shadow branch resolves to its public counterpart" {
  git checkout -q main@local
  run git shadow check public
  [ "$status" -eq 0 ]
  [[ "$output" == *"main"* ]]
}

@test "check public with a local branch argument resolves to its public counterpart" {
  git checkout -q main
  run git shadow check public main@local
  [ "$status" -eq 0 ]
  [[ "$output" == *"main"* ]] || [[ "$output" == *"clean"* ]]
}

# ---------------------------------------------------------------------------
# Unpromoted / memory-first files
# ---------------------------------------------------------------------------

@test "check public exits 1 when a file originated from a [MEMORY] commit on the local branch but was not promoted" {
  # Public branch adds leaked.md with a normal commit
  git checkout -q main
  echo "leaked content" > leaked.md
  git add leaked.md
  git commit -qm "feat: add leaked.md"

  # Local counterpart adds the same file in a [MEMORY] commit
  git checkout -q main@local
  echo "leaked content" > leaked.md
  git add leaked.md
  git commit -qm "[MEMORY] leaked notes"

  run git shadow check public main
  [ "$status" -ne 0 ]
  [[ "$output" == *"leaked.md"* ]] || [[ "$output" == *"unpromoted"* ]] || [[ "$output" == *"[MEMORY]"* ]]
}

@test "check public passes when a file was promoted via shadow: publish" {
  # Create a feature pair
  git checkout -q main
  git checkout -q -b feature/foo
  git checkout -q -b feature/foo@local

  # Add a memory-first file and promote it
  echo "promoted content" > promoted.md
  git add promoted.md
  git commit -qm "[MEMORY] add promoted.md"
  git shadow promote promoted.md

  # Publish the promoted file
  git shadow feature publish

  # The public branch should be clean
  run git shadow check public feature/foo
  [ "$status" -eq 0 ]
}
