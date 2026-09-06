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

  # Ensure tests use the toolkit under test.
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  git shadow feature start test-feature
  echo "feature code" > feature.txt
  git add feature.txt
  git commit -qm "feat: feature code"
  git shadow feature publish

  # Simulate the feature being merged into main
  git checkout -q main
  git merge -q --no-edit test-feature

  # Return to the local feature branch so feature finish can detect it
  git checkout -q "test-feature@local"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "feature finish exits 0 after feature is merged into develop" {
  run git shadow feature finish --no-pull
  [ "$status" -eq 0 ]
}

@test "feature finish outputs completion message" {
  run git shadow feature finish --no-pull
  [[ "$output" == *"Feature finished successfully"* ]]
}

@test "feature finish applies public base changes to main@local" {
  git shadow feature finish --no-pull
  git checkout -q "main@local"
  result="$(cat feature.txt)"
  [ "$result" = "feature code" ]
}

@test "feature finish creates a checkpoint on main@local" {
  git shadow feature finish --no-pull
  subject="$(git log -1 --format='%s' main@local)"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "feature finish deletes the public feature branch" {
  git shadow feature finish --no-pull
  run git branch --list "test-feature"
  [ -z "$output" ]
}

@test "feature finish deletes the local feature branch" {
  git shadow feature finish --no-pull
  run git branch --list "test-feature@local"
  [ -z "$output" ]
}

@test "feature finish exits 1 when run from the base branch" {
  git checkout -q main
  run git shadow feature finish --no-pull
  [ "$status" -eq 1 ]
}

@test "feature finish exits 1 when base sync has conflicts" {
  # Setup: public base and feature both modified the same file
  git checkout -q main
  git merge -q --no-edit test-feature

  # Commit a conflicting change on main AFTER the feature was merged
  git checkout -q main
  echo "conflicting main change" > feature.txt
  git add feature.txt
  GIT_SHADOW=1 git commit -qm "chore: post-merge change on main"

  # Also put the conflicting content on main@local
  git checkout -q "main@local"
  echo "conflicting local change" > feature.txt
  git add feature.txt
  git commit -qm "chore: conflicting local"

  # Return to feature branch and attempt finish
  git checkout -q "test-feature@local"
  run git shadow feature finish --no-pull
  [ "$status" -ne 0 ]
}

@test "feature finish exits 1 when cherry-picking [MEMORY] conflicts" {
  git checkout -q main
  git merge -q --no-edit test-feature

  # Create a [MEMORY] on the feature that touches a public-tracked file
  git checkout -q "test-feature@local"
  echo "local change" > feature.txt
  git add feature.txt
  git commit -qm "[MEMORY] local change"

  # Modify the same file on main@local independently
  git checkout -q "main@local"
  echo "local base independent" > feature.txt
  git add feature.txt
  git commit -qm "chore: independent change on main@local"

  # Return to feature and attempt finish
  git checkout -q "test-feature@local"
  run git shadow feature finish --no-pull
  [ "$status" -ne 0 ]
}

@test "feature finish merges hunk-key sidecars from base and feature" {
  git shadow config set ANNOTATION_FUZZY_THRESHOLD 0.5 --project-config >/dev/null

  # Public base and local base share a multi-line source.
  git checkout -q main
  cat > feature.txt <<-'EOF'
line1
feature code
line2
EOF
  git add feature.txt
  GIT_SHADOW=1 git commit -q -m "expand feature.txt"

  git checkout -q "main@local"
  git shadow base sync

  # Add a base marker on main@local.
  cat > feature.txt <<-'EOF'
line1
feature code
/// base note
line2
EOF
  git add feature.txt
  git shadow commit -q -m "base note"

  # Add a feature marker on the local feature branch.
  git checkout -q "test-feature@local"
  cat > feature.txt <<-'EOF'
line1
feature code
/// feature note
line2
EOF
  git add feature.txt
  git shadow commit -q -m "feature note"

  # Finish the feature: sidecars should merge by hunk key.
  run git shadow feature finish --no-pull
  [ "$status" -eq 0 ]

  git checkout -q "main@local"
  [ "$(cat feature.txt)" = $'line1\nfeature code\nline2' ]

  run git shadow show --with-annotations feature.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"/// base note"* ]]
  [[ "$output" == *"/// feature note"* ]]

  # Merged sidecar has two replace sections.
  [ "$(git show HEAD:.git-shadow/annotations/feature.txt | grep -c '### replace')" -eq 2 ]
}

@test "feature finish re-anchors merged sidecars to the final base source" {
  git shadow config set ANNOTATION_FUZZY_THRESHOLD 0.5 --project-config >/dev/null

  # Public base gets a multi-line source.
  git checkout -q main
  cat > feature.txt <<-'EOF'
line1
feature code
line2
EOF
  git add feature.txt
  GIT_SHADOW=1 git commit -q -m "expand feature.txt"

  git checkout -q "main@local"
  git shadow base sync

  # Add a base marker on main@local.
  cat > feature.txt <<-'EOF'
line1
feature code
/// base note
line2
EOF
  git add feature.txt
  git shadow commit -q -m "base note"

  # Public base changes a line inside the hunk.
  git checkout -q main
  cat > feature.txt <<-'EOF'
line1
feature code 2
line2
EOF
  git add feature.txt
  GIT_SHADOW=1 git commit -q -m "change feature code"

  # Feature has a marker on the same hunk.
  git checkout -q "test-feature@local"
  cat > feature.txt <<-'EOF'
line1
feature code
/// feature note
line2
EOF
  git add feature.txt
  git shadow commit -q -m "feature note"

  # Finish the feature: base sync applies the public change and merges sidecars.
  run git shadow feature finish --no-pull
  [ "$status" -eq 0 ]

  git checkout -q "main@local"
  [ "$(cat feature.txt)" = $'line1\nfeature code 2\nline2' ]

  run git shadow show --with-annotations feature.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature code 2"* ]]
  [[ "$output" == *"/// base note"* ]]
  [[ "$output" == *"/// feature note"* ]]
}

@test "feature finish is safe to re-run" {
  git shadow config set ANNOTATION_FUZZY_THRESHOLD 0.5 --project-config >/dev/null

  # Public base gets a multi-line source.
  git checkout -q main
  cat > feature.txt <<-'EOF'
line1
feature code
line2
EOF
  git add feature.txt
  GIT_SHADOW=1 git commit -q -m "expand feature.txt"

  git checkout -q "main@local"
  git shadow base sync

  # Add a base marker on main@local.
  cat > feature.txt <<-'EOF'
line1
feature code
/// base note
line2
EOF
  git add feature.txt
  git shadow commit -q -m "base note"

  # Add a feature marker on the local feature branch.
  git checkout -q "test-feature@local"
  cat > feature.txt <<-'EOF'
line1
feature code
/// feature note
line2
EOF
  git add feature.txt
  git shadow commit -q -m "feature note"

  # Finish once, keeping branches for the re-run.
  run git shadow feature finish --no-pull --keep-branches
  [ "$status" -eq 0 ]

  # Finish again from the same feature branch; should be idempotent.
  git checkout -q "test-feature@local"
  run git shadow feature finish --no-pull --keep-branches
  [ "$status" -eq 0 ]

  git checkout -q "main@local"
  [ "$(cat feature.txt)" = $'line1\nfeature code\nline2' ]

  # The sidecar still has exactly two replace sections, not duplicated.
  [ "$(git show HEAD:.git-shadow/annotations/feature.txt | grep -c '### replace')" -eq 2 ]

  # Only one replayed [MEMORY] for the feature note plus the base [MEMORY].
  [ "$(git log --grep='^\[MEMORY\]' main@local --format='%H' | wc -l)" -eq 2 ]
}

@test "feature finish preserves branches on [MEMORY] conflict" {
  git checkout -q main
  git merge -q --no-edit test-feature

  git checkout -q "test-feature@local"
  echo "local change" > feature.txt
  git add feature.txt
  git commit -qm "[MEMORY] local change"

  git checkout -q "main@local"
  echo "local base independent" > feature.txt
  git add feature.txt
  git commit -qm "chore: independent change on main@local"

  git checkout -q "test-feature@local"
  git shadow feature finish --no-pull 2>/dev/null || true

  git show-ref --verify --quiet "refs/heads/test-feature"
  git show-ref --verify --quiet "refs/heads/test-feature@local"
}

# --- Resumable finish tests (T43) ---------------------------------------------

@test "feature finish pauses on base-diff conflict and supports --continue" {
  # Public base and local base both change the same file after the feature merge.
  git checkout -q main
  echo "public base change" > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -qm "chore: public base change"

  git checkout -q "main@local"
  echo "local base change" > file.txt
  git add file.txt
  git commit -qm "chore: local base change"

  git checkout -q "test-feature@local"
  run git shadow feature finish --no-pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"--continue"* ]]
  [[ "$output" == *"--abort"* ]]

  state_file="$(git rev-parse --git-dir)/git-shadow-finish"
  [ -f "$state_file" ]
  grep -q "phase=base-diff" "$state_file"

  # Resolve the conflict and continue.
  echo "resolved" > file.txt
  git add file.txt
  run git shadow feature finish --continue
  [ "$status" -eq 0 ]
  [ ! -f "$state_file" ]

  subject="$(git log -1 --format='%s' main@local)"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "feature finish pauses on [MEMORY] conflict and supports --continue" {
  # The base diff applies cleanly; only the [MEMORY] conflicts.
  git checkout -q "test-feature@local"
  echo "memory change" > file.txt
  git add file.txt
  git commit -qm "[MEMORY] memory change"

  git checkout -q "main@local"
  echo "local base change" > file.txt
  git add file.txt
  git commit -qm "chore: local base change"

  git checkout -q "test-feature@local"
  run git shadow feature finish --no-pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"--continue"* ]]

  state_file="$(git rev-parse --git-dir)/git-shadow-finish"
  [ -f "$state_file" ]
  grep -q "phase=memory-replay" "$state_file"
  grep -q "conflicted_sha=" "$state_file"

  # Resolve and continue.
  echo "resolved" > file.txt
  git add file.txt
  run git shadow feature finish --continue
  [ "$status" -eq 0 ]
  [ ! -f "$state_file" ]

  subject="$(git log -1 --format='%s' main@local)"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "feature finish --abort restores pre-finish head and preserves branches" {
  git checkout -q main
  echo "public base change" > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -qm "chore: public base change"

  git checkout -q "main@local"
  echo "local base change" > file.txt
  git add file.txt
  git commit -qm "chore: local base change"
  before="$(git rev-parse HEAD)"

  git checkout -q "test-feature@local"
  run git shadow feature finish --no-pull
  [ "$status" -ne 0 ]

  state_file="$(git rev-parse --git-dir)/git-shadow-finish"
  [ -f "$state_file" ]

  run git shadow feature finish --abort
  [ "$status" -eq 0 ]
  [ ! -f "$state_file" ]
  [ "$(git rev-parse main@local)" = "$before" ]

  git show-ref --verify --quiet "refs/heads/test-feature"
  git show-ref --verify --quiet "refs/heads/test-feature@local"
}

@test "feature finish pause message names conflicting paths and commands" {
  git checkout -q main
  echo "public base change" > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -qm "chore: public base change"

  git checkout -q "main@local"
  echo "local base change" > file.txt
  git add file.txt
  git commit -qm "chore: local base change"

  git checkout -q "test-feature@local"
  run git shadow feature finish --no-pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"file.txt"* ]]
  [[ "$output" == *"git shadow feature finish --continue"* ]]
  [[ "$output" == *"git shadow feature finish --abort"* ]]
}

# --- --mark-applied tests (T44) ------------------------------------------------

@test "feature finish --mark-applied creates provenance-only commit" {
  git checkout -q "test-feature@local"
  echo "local note" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] local note"
  sha="$(git rev-parse HEAD)"

  run git shadow feature finish --mark-applied "$sha"
  [ "$status" -eq 0 ]

  body="$(git log -1 --format='%b' main@local)"
  [[ "$body" == *"git-shadow-source-memory: $sha"* ]]
  [[ "$body" == *"git-shadow-source-pid:"* ]]

  # The commit is empty: no tree changes relative to its parent.
  diff="$(git diff-tree --no-commit-id -r HEAD main@local | wc -l)"
  [ "$diff" -eq 0 ]
}

@test "feature finish --mark-applied updates paused state" {
  git checkout -q "test-feature@local"
  echo "memory change" > file.txt
  git add file.txt
  git commit -qm "[MEMORY] memory change"
  sha="$(git rev-parse HEAD)"

  git checkout -q "main@local"
  echo "local base change" > file.txt
  git add file.txt
  git commit -qm "chore: local base change"

  git checkout -q "test-feature@local"
  git shadow feature finish --no-pull 2>/dev/null || true

  state_file="$(git rev-parse --git-dir)/git-shadow-finish"
  [ -f "$state_file" ]
  grep -q "conflicted_sha=$sha" "$state_file"

  run git shadow feature finish --mark-applied "$sha"
  [ "$status" -eq 0 ]

  # The marker commit is the new pre-finish head and the sha is removed.
  new_head="$(git rev-parse main@local)"
  grep -q "pre_finish_head=$new_head" "$state_file"
  ! grep -q "conflicted_sha=$sha" "$state_file"
  ! grep -q "remaining_shas=$sha" "$state_file"
}

@test "feature finish refuses to run while a sync is paused" {
  echo "mode=feature" > .git/git-shadow-sync
  run git shadow feature finish --no-pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"sync"* ]]
}
