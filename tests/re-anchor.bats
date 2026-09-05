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

  # Create a public base and a feature using git shadow
  git symbolic-ref HEAD refs/heads/main
  echo "initial" > file.txt
  git add file.txt
  git commit -qm "initial"

  git shadow feature start feature-foo
  echo "v2" > file.txt
  git add file.txt
  git commit -qm "feat: update file"
  git shadow feature publish

  # Simulate the public feature branch being merged and then rewritten on main
  git checkout -q main
  git merge -q --no-edit feature-foo

  # Set up an "origin" remote clone
  ORIGIN_DIR="$(mktemp -d)"
  git clone -q --bare . "$ORIGIN_DIR"
  git remote add origin "$ORIGIN_DIR"
  git push -q origin main
  git push -q origin feature-foo

  # Rewrite feature-foo on the remote: checkout, amend the last commit, force push
  REMOTE_WORK="$(mktemp -d)"
  git clone -q "$ORIGIN_DIR" "$REMOTE_WORK"
  cd "$REMOTE_WORK"
  git checkout -q feature-foo
  echo "v2" > file.txt
  git add file.txt
  git commit -q --amend -m "feat: update file (amended)"
  git push -q --force-with-lease origin feature-foo

  cd "$TEST_DIR"
  git fetch -q origin

  # Put a local-only file on the shadow branch
  git checkout -q feature-foo@local
  echo "local note" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] notes"
}

teardown() {
  rm -rf "$TEST_DIR" "$ORIGIN_DIR" "$REMOTE_WORK"
}

@test "re-anchor requires a @local branch" {
  git checkout -q main
  run git shadow re-anchor main
  [ "$status" -eq 1 ]
  [[ "$output" == *"@local"* ]]
}

@test "re-anchor updates public branch to fetched head" {
  git checkout -q feature-foo@local
  before="$(git rev-parse feature-foo)"
  run git shadow re-anchor feature-foo@local
  [ "$status" -eq 0 ]
  after="$(git rev-parse feature-foo)"
  [ "$before" != "$after" ]
}

@test "re-anchor creates a checkpoint with the new public head" {
  git checkout -q feature-foo@local
  git shadow re-anchor feature-foo@local
  subject="$(git log -1 --format='%s' feature-foo@local)"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "re-anchor fails when local tree is missing public files" {
  # Delete the public file from the shadow branch
  git checkout -q feature-foo@local
  git rm -q file.txt
  git commit -q -m "[MEMORY] remove file"

  run git shadow re-anchor feature-foo@local
  [ "$status" -ne 0 ]
}

@test "re-anchor re-anchors sidecars when public source changes" {
  git shadow config set ANNOTATION_FUZZY_THRESHOLD 0.5 --project-config >/dev/null

  # Create a sidecar on the local base.
  git checkout -q main@local
  cat > file.txt <<-'EOF'
A
B
/// note
C
EOF
  git add file.txt
  git shadow commit -q -m "add note"

  # Public base gets an additional commit that changes a line in the hunk.
  git checkout -q main
  cat > file.txt <<-'EOF'
A
B2
C
EOF
  git add file.txt
  GIT_SHADOW=1 git commit -q -m "change B"
  git push -q origin main

  # Update the local source to match the new public tree.
  git checkout -q main@local
  cat > file.txt <<-'EOF'
A
B2
C
EOF
  git add file.txt
  git commit -q -m "update source"

  run git shadow re-anchor main@local
  [ "$status" -eq 0 ]

  [ "$(cat file.txt)" = $'A\nB2\nC' ]
  run git shadow show --with-annotations file.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"B2"* ]]
  [[ "$output" == *"/// note"* ]]

  # Checkpoint should record patch-ids for all public commits (M7).
  body="$(git log -1 --format='%b' main@local)"
  [[ "$body" == *"patches:"* ]]
}

@test "re-anchor removes sidecar when public source is deleted" {
  # Create a sidecar on the local base.
  git checkout -q main@local
  cat > file.txt <<-'EOF'
A
B
/// note
C
EOF
  git add file.txt
  git shadow commit -q -m "add note"

  # Public base deletes the source file.
  git checkout -q main
  git rm -q file.txt
  GIT_SHADOW=1 git commit -q -m "delete file"
  git push -q origin main

  # Local base mirrors the deletion.
  git checkout -q main@local
  git rm -q file.txt
  git commit -q -m "delete file"

  run git shadow re-anchor main@local
  [ "$status" -eq 0 ]

  [ ! -f file.txt ]
  [ ! -f .git-shadow/annotations/file.txt ]
}

@test "re-anchor refuses to run while a sync is in progress" {
  # Force a sync state file.
  mkdir -p .git
  echo "base main@local" > .git/git-shadow-sync

  git checkout -q "feature-foo@local"
  run git shadow re-anchor feature-foo@local
  [ "$status" -ne 0 ]
  [[ "$output" == *"sync is in progress"* ]]
}

@test "re-anchor works when local tree only adds local-only files" {
  git checkout -q feature-foo@local
  run git shadow re-anchor feature-foo@local
  [ "$status" -eq 0 ]
  result="$(cat notes.md)"
  [ "$result" = "local note" ]
}
