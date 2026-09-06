#!/usr/bin/env bats

# V93: sync pause/continue/abort messages must name the public branch, the
# actual diff range (diff_start..target_public), the conflicting paths, and
# the exact --continue/--abort commands. The sync state file records
# diff_start (checkpoint public SHA, or recovered ancestor under --recover).

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main
  echo "v1" > app.ts
  git add app.ts
  git commit -qm "initial"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  git shadow feature start feature-foo
  git checkout -q "feature-foo@local"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Put the feature pair into a conflicted sync: local and public both change
# app.ts. Sets DIFF_START and DIFF_END to the expected range.
make_feature_conflict() {
  echo "local version" > app.ts
  git add app.ts
  git commit -qm "chore: local tweak"

  DIFF_START="$(git rev-parse feature-foo)"
  git checkout -q feature-foo
  echo "public version" > app.ts
  git add app.ts
  GIT_SHADOW=1 git commit -qm "feat: public update"
  DIFF_END="$(git rev-parse feature-foo)"

  git checkout -q "feature-foo@local"
}

# Put the base pair into a conflicted sync.
make_base_conflict() {
  git checkout -q "main@local"
  echo "local change" > app.ts
  git add app.ts
  git commit -qm "chore: local change"

  DIFF_START="$(git rev-parse main)"
  git checkout -q main
  echo "public change" > app.ts
  git add app.ts
  GIT_SHADOW=1 git commit -qm "feat: public change"
  DIFF_END="$(git rev-parse main)"

  git checkout -q "main@local"
}

# ---------------------------------------------------------------------------
# Pause message on initial conflict
# ---------------------------------------------------------------------------

@test "feature sync pause message names branch, range, paths, and commands" {
  make_feature_conflict
  run git shadow feature sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"feature-foo"* ]]
  [[ "$output" == *"$DIFF_START..$DIFF_END"* ]]
  [[ "$output" == *"app.ts"* ]]
  [[ "$output" == *"git shadow feature sync --continue"* ]]
  [[ "$output" == *"git shadow feature sync --abort"* ]]
}

@test "base sync pause message names branch, range, paths, and commands" {
  make_base_conflict
  run git shadow base sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"main"* ]]
  [[ "$output" == *"$DIFF_START..$DIFF_END"* ]]
  [[ "$output" == *"app.ts"* ]]
  [[ "$output" == *"git shadow base sync --continue"* ]]
  [[ "$output" == *"git shadow base sync --abort"* ]]
}

# ---------------------------------------------------------------------------
# diff_start in the state file
# ---------------------------------------------------------------------------

@test "sync state file records diff_start equal to the checkpoint public SHA" {
  make_feature_conflict
  git shadow feature sync || true
  state_file="$(git rev-parse --git-dir)/git-shadow-sync"
  [ -f "$state_file" ]
  grep -q "^diff_start=$DIFF_START\$" "$state_file"
}

@test "feature sync --recover records the recovered ancestor as diff_start" {
  # Publish a public commit, then amend it on the public branch (same patch).
  echo "v2" >> app.ts
  git add app.ts
  git commit -qm "feat: app update"
  git shadow feature publish

  git checkout -q feature-foo
  GIT_SHADOW=1 git commit -q --amend -m "feat: app update (amended)"
  amended="$(git rev-parse feature-foo)"

  # A second public commit that conflicts with a local change.
  sed -i '1s/v1/public-v1/' app.ts
  git add app.ts
  GIT_SHADOW=1 git commit -qm "feat: public line1"

  git checkout -q "feature-foo@local"
  sed -i '1s/v1/local-v1/' app.ts
  git add app.ts
  git commit -qm "chore: local line1"

  run git shadow feature sync --recover
  [ "$status" -eq 1 ]

  state_file="$(git rev-parse --git-dir)/git-shadow-sync"
  [ -f "$state_file" ]
  grep -q "^diff_start=$amended\$" "$state_file"
}

# ---------------------------------------------------------------------------
# --continue conflict check message
# ---------------------------------------------------------------------------

@test "feature sync --continue with unresolved conflicts names paths and commands" {
  make_feature_conflict
  git shadow feature sync || true

  run git shadow feature sync --continue
  [ "$status" -eq 1 ]
  [[ "$output" == *"app.ts"* ]]
  [[ "$output" == *"feature-foo"* ]]
  [[ "$output" == *"$DIFF_START..$DIFF_END"* ]]
  [[ "$output" == *"git shadow feature sync --continue"* ]]
  [[ "$output" == *"git shadow feature sync --abort"* ]]
}

# ---------------------------------------------------------------------------
# --abort message
# ---------------------------------------------------------------------------

@test "feature sync --abort names branch, range, discarded paths, and restart" {
  make_feature_conflict
  git shadow feature sync || true

  run git shadow feature sync --abort
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature-foo"* ]]
  [[ "$output" == *"$DIFF_START..$DIFF_END"* ]]
  [[ "$output" == *"app.ts"* ]]
  [[ "$output" == *"git shadow feature sync"* ]]
}

@test "base sync --abort names branch, range, discarded paths, and restart" {
  make_base_conflict
  git shadow base sync || true

  run git shadow base sync --abort
  [ "$status" -eq 0 ]
  [[ "$output" == *"main"* ]]
  [[ "$output" == *"$DIFF_START..$DIFF_END"* ]]
  [[ "$output" == *"app.ts"* ]]
  [[ "$output" == *"git shadow base sync"* ]]
}
