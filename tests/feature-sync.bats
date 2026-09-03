#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  git symbolic-ref HEAD refs/heads/develop
  echo "v1" > app.ts
  git add app.ts
  git commit -qm "initial"

  # Create feature pair using git shadow so an initial checkpoint exists.
  git shadow feature start feature-foo

  # Add a local-only [MEMORY] commit.
  echo "/// local note" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] local notes"

  # Add a public commit on the local branch.
  echo "v2" > app.ts
  git add app.ts
  git commit -qm "feat: shadow app update"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "feature sync exits 1 when not on a shadow branch" {
  git checkout -q feature-foo
  run git shadow feature sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"@local"* ]]
}

@test "feature sync exits 1 when public branch does not exist" {
  git checkout -q -b "orphan@local"
  run git shadow feature sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "feature sync --abort exits 1 when no sync in progress" {
  git checkout -q "feature-foo@local"
  run git shadow feature sync --abort
  [ "$status" -eq 1 ]
  [[ "$output" == *"No sync"* ]]
}

@test "feature sync --continue exits 1 when no sync in progress" {
  git checkout -q "feature-foo@local"
  run git shadow feature sync --continue
  [ "$status" -eq 1 ]
  [[ "$output" == *"No sync"* ]]
}

@test "feature sync succeeds when public branch has new commits" {
  # Add a new commit on the public feature branch (simulates colleague work).
  git checkout -q feature-foo
  echo "v3" > extra.ts
  git add extra.ts
  git commit -qm "feat: add extra module"

  git checkout -q "feature-foo@local"
  run git shadow feature sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"synced"* ]]
}

@test "feature sync applies public diff to local tree" {
  git checkout -q feature-foo
  echo "v3" > extra.ts
  git add extra.ts
  git commit -qm "feat: add extra module"

  git checkout -q "feature-foo@local"
  git shadow feature sync
  [[ -f "extra.ts" ]]
}

@test "feature sync preserves [MEMORY] content" {
  git checkout -q feature-foo
  echo "v3" > extra.ts
  git add extra.ts
  git commit -qm "feat: add extra module"

  git checkout -q "feature-foo@local"
  git shadow feature sync
  result="$(cat notes.md)"
  [[ "$result" == *"/// local note"* ]]
}

@test "feature sync pauses on conflict and supports --continue" {
  git checkout -q "feature-foo@local"
  echo "shadow version" > app.ts
  git add app.ts
  git commit -qm "chore: shadow tweak"

  git checkout -q feature-foo
  echo "public version" > app.ts
  git add app.ts
  git commit -qm "feat: public update"

  git checkout -q "feature-foo@local"
  run git shadow feature sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"--continue"* ]]

  # Resolve and continue
  echo "resolved version" > app.ts
  git add app.ts
  run git shadow feature sync --continue
  [ "$status" -eq 0 ]
  result="$(cat app.ts)"
  [ "$result" = "resolved version" ]
}

@test "feature sync --abort restores local branch" {
  git checkout -q "feature-foo@local"
  echo "shadow version" > app.ts
  git add app.ts
  git commit -qm "chore: shadow tweak"

  git checkout -q feature-foo
  echo "public version" > app.ts
  git add app.ts
  git commit -qm "feat: public update"

  git checkout -q "feature-foo@local"
  before="$(git rev-parse HEAD)"
  run git shadow feature sync
  [ "$status" -eq 1 ]

  run git shadow feature sync --abort
  [ "$status" -eq 0 ]
  after="$(git rev-parse HEAD)"
  [ "$before" = "$after" ]
}

@test "feature sync exits with warning when run on the local base branch" {
  git shadow config set PUBLIC_BASE_BRANCH=develop --project-config >/dev/null
  git checkout -q "develop@local"
  run git shadow feature sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"base"* ]]
}
