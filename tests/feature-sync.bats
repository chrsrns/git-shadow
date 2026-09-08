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

  # Ensure tests use the toolkit under test.
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  # Create feature pair using git shadow so an initial checkpoint exists.
  git shadow feature start feature-foo

  # Add a local-only [MEMORY] commit (bypass the pre-commit marker guard).
  echo "/// local note" > notes.md
  git add notes.md
  GIT_SHADOW=1 git commit -qm "[MEMORY] local notes"

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
  GIT_SHADOW=1 git commit -qm "feat: add extra module"

  git checkout -q "feature-foo@local"
  run git shadow feature sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"synced"* ]]
}

@test "feature sync applies public diff to local tree" {
  git checkout -q feature-foo
  echo "v3" > extra.ts
  git add extra.ts
  GIT_SHADOW=1 git commit -qm "feat: add extra module"

  git checkout -q "feature-foo@local"
  git shadow feature sync
  [[ -f "extra.ts" ]]
}

@test "feature sync preserves [MEMORY] content" {
  git checkout -q feature-foo
  echo "v3" > extra.ts
  git add extra.ts
  GIT_SHADOW=1 git commit -qm "feat: add extra module"

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
  GIT_SHADOW=1 git commit -qm "feat: public update"

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
  GIT_SHADOW=1 git commit -qm "feat: public update"

  git checkout -q "feature-foo@local"
  before="$(git rev-parse HEAD)"
  run git shadow feature sync
  [ "$status" -eq 1 ]

  run git shadow feature sync --abort
  [ "$status" -eq 0 ]
  after="$(git rev-parse HEAD)"
  [ "$before" = "$after" ]
}

@test "feature sync --recover handles an amended public feature commit" {
  # Add a public commit on the local branch and publish it.
  git checkout -q feature-foo@local
  echo "v2" >> app.ts
  git add app.ts
  git commit -q -m "feat: app update"
  git shadow feature publish

  # Amend the public feature commit with the same diff.
  git checkout -q feature-foo
  GIT_SHADOW=1 git commit -q --amend -m "feat: app update (amended)"

  git checkout -q feature-foo@local
  run git shadow feature sync --recover
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
}

@test "feature sync re-anchors annotation sidecars" {
  git shadow config set ANNOTATION_FUZZY_THRESHOLD 0.5 --project-config >/dev/null

  # Add a marker on the local branch and publish the clean public commit.
  git checkout -q "feature-foo@local"
  cat > app.ts <<-'EOF'
A
B
/// note
C
EOF
  git add app.ts
  git shadow commit -q -m "add note"
  git shadow feature publish

  # Colleague adds a public commit that changes a line in the hunk.
  git checkout -q feature-foo
  cat > app.ts <<-'EOF'
A
B2
C
EOF
  git add app.ts
  GIT_SHADOW=1 git commit -q -m "change B"

  git checkout -q "feature-foo@local"
  run git shadow feature sync
  [ "$status" -eq 0 ]

  # Source is clean but rendered view includes re-anchored marker.
  [ "$(cat app.ts)" = $'A\nB2\nC' ]
  run git shadow show --with-annotations app.ts
  [ "$status" -eq 0 ]
  [[ "$output" == *"B2"* ]]
  [[ "$output" == *"/// note"* ]]
}

@test "feature sync --continue after --recover records diff_start in the [SYNC] range" {
  # Publish the local public commit so the checkpoint carries patch-ids.
  git checkout -q feature-foo@local
  git shadow feature publish
  cp_public="$(git rev-parse feature-foo)"

  # Local divergence that will conflict with the recovered public diff.
  echo "local divergence" >> app.ts
  git add app.ts
  git commit -qm "feat: local divergence"

  # Rewrite the public branch: amend (same diff, same patch-id, new SHA).
  git checkout -q feature-foo
  GIT_SHADOW=1 git commit -q --amend -m "feat: shadow app update (amended)"
  recovered_ancestor="$(git rev-parse HEAD)"

  # A second public commit that conflicts with the local divergence.
  echo "public divergence" >> app.ts
  git add app.ts
  GIT_SHADOW=1 git commit -qm "feat: public divergence"
  public_head="$(git rev-parse HEAD)"

  # Recover finds the amended commit as new ancestor; the net diff conflicts.
  git checkout -q feature-foo@local
  run git shadow feature sync --recover
  [ "$status" -eq 1 ]

  # Resolve and continue.
  echo "resolved" > app.ts
  git add app.ts
  run git shadow feature sync --continue
  [ "$status" -eq 0 ]

  # The [SYNC] commit must record the applied range: recovered ancestor,
  # not the (rewritten-away) checkpoint public SHA.
  sync_sha="$(git log -1 --format='%H' --grep='^\[SYNC\]')"
  body="$(git log -1 --format='%B' "$sync_sha")"
  [[ "$body" == *"Range: ${recovered_ancestor}..${public_head}"* ]]
  [[ "$body" != *"Range: ${cp_public}.."* ]]
}

@test "feature sync exits with warning when run on the local base branch" {
  git shadow config set PUBLIC_BASE_BRANCH=develop --project-config >/dev/null
  git checkout -q "develop@local"
  run git shadow feature sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"base"* ]]
}

@test "feature sync refuses to run while a finish is paused" {
  echo "phase=base-diff" > .git/git-shadow-finish
  run git shadow feature sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"finish"* ]]
}
