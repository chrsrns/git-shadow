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
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Aggregate / happy path
# ---------------------------------------------------------------------------

@test "doctor exits 0 on a healthy repository" {
  run git shadow doctor
  [ "$status" -eq 0 ]
}

@test "doctor is read-only and leaves paused state in place" {
  cat > .git/git-shadow-sync <<'EOF'
mode=feature
public_branch=test-feature
local_branch=test-feature@local
checkpoint_public=aaa
checkpoint_local=bbb
target_public=ccc
local_head=ddd
pids=
EOF
  before="$(git branch --show-current)"
  run git shadow doctor
  [ "$status" -eq 1 ]
  [ -f .git/git-shadow-sync ]
  [ "$(git branch --show-current)" = "$before" ]
}

# ---------------------------------------------------------------------------
# Version / toolkit root check
# ---------------------------------------------------------------------------

@test "doctor skips version check outside the toolkit repo" {
  run git shadow doctor
  [[ "$output" == *"version"* ]]
  [[ "$output" == *"skipp"* || "$output" == *"not the git-shadow toolkit"* ]]
}

@test "doctor warns when toolkit markers exist but PATH resolves elsewhere" {
  mkdir -p bin commands
  : > bin/git-shadow
  : > commands/version.sh
  echo "9.9.9" > VERSION
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"version"* ]]
}

# ---------------------------------------------------------------------------
# In-progress state check
# ---------------------------------------------------------------------------

@test "doctor warns on paused sync state and names mode and state file" {
  cat > .git/git-shadow-sync <<'EOF'
mode=feature
public_branch=test-feature
local_branch=test-feature@local
checkpoint_public=aaa
checkpoint_local=bbb
target_public=ccc
local_head=ddd
pids=
EOF
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"sync in progress"* ]]
  [[ "$output" == *"mode=feature"* ]]
  [[ "$output" == *"git-shadow-sync"* ]]
}

@test "doctor warns on paused finish state and names phase" {
  cat > .git/git-shadow-finish <<'EOF'
feature_public=test-feature
feature_local=test-feature@local
local_base=main@local
pre_finish_head=aaa
phase=base-diff
conflicted_sha=
remaining_shas=
range_start=bbb
range_end=ccc
pids=
EOF
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"finish in progress"* ]]
  [[ "$output" == *"base-diff"* ]]
  [[ "$output" == *"git-shadow-finish"* ]]
}

# ---------------------------------------------------------------------------
# Checkpoint check
# ---------------------------------------------------------------------------

@test "doctor checkpoint summary lists every @local branch" {
  run git shadow doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"main@local"* ]]
  [[ "$output" == *"test-feature@local"* ]]
  [[ "$output" == *"publishable"* ]]
  [[ "$output" == *"public-ahead"* ]]
  [[ "$output" == *"diverged"* ]]
}

@test "doctor warns for @local branch without checkpoint" {
  git checkout -q --orphan stale@local
  git rm -rf . >/dev/null 2>&1
  echo x > orphan.txt
  git add orphan.txt
  git commit -qm "orphan work"
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale@local"* ]]
  [[ "$output" == *"checkpoint"* ]]
}

@test "doctor reports publishable commit count per @local branch" {
  echo "new" > new.txt
  git add new.txt
  git commit -qm "feat: new work"
  run git shadow doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-feature@local"* ]]
  [[ "$output" == *"publishable:1"* ]]
}

# ---------------------------------------------------------------------------
# Hook check
# ---------------------------------------------------------------------------

@test "doctor warns when pre-commit hook is missing" {
  rm -f .git/hooks/pre-commit
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"pre-commit"* ]]
}

@test "doctor warns when pre-push hook lacks the git-shadow marker" {
  printf '#!/bin/sh\n# some other hook\n' > .git/hooks/pre-push
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"pre-push"* ]]
}

# ---------------------------------------------------------------------------
# Unpromoted files check
# ---------------------------------------------------------------------------

@test "doctor warns on unpromoted files and names them" {
  # A file first created by a [MEMORY] commit on the @local branch that also
  # exists on the public branch is unpromoted.
  echo "secret" > leak.txt
  git add leak.txt
  git commit -qm "[MEMORY] add leak"
  git checkout -q test-feature
  echo "secret" > leak.txt
  git add leak.txt
  GIT_SHADOW=1 git commit -qm "add leak"
  git checkout -q "test-feature@local"

  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"unpromoted"* ]]
  [[ "$output" == *"leak.txt"* ]]
}

# ---------------------------------------------------------------------------
# .gitattributes union-merge check
# ---------------------------------------------------------------------------

@test "doctor warns when SPEC.md exists without merge=union" {
  echo "# spec" > SPEC.md
  git add SPEC.md
  git commit -qm "spec: add"
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"gitattributes"* ]]
  [[ "$output" == *"merge=union"* ]]
}

@test "doctor accepts SPEC.md with merge=union declared" {
  echo "# spec" > SPEC.md
  echo "SPEC.md merge=union" > .gitattributes
  git add SPEC.md .gitattributes
  git commit -qm "spec: add with union"
  run git shadow doctor
  [ "$status" -eq 0 ]
}
