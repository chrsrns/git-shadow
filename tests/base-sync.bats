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
  git commit -q -m "initial"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "base sync exits 1 when not on a local base branch" {
  run git shadow base sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"@local"* ]]
}

@test "base sync creates main@local with initial checkpoint" {
  git checkout -q -b main@local
  run git shadow base sync
  [ "$status" -eq 0 ]

  latest="$(git log -1 --format='%H' main@local)"
  subject="$(git log -1 --format='%s' "$latest")"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "base sync applies a new public commit to main@local" {
  git checkout -q -b main@local
  git shadow base sync

  # Add a public commit
  git checkout -q main
  echo "public change" >> file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -q -m "public change"

  git checkout -q main@local
  run git shadow base sync
  [ "$status" -eq 0 ]

  [ "$(cat file.txt)" = $'initial\npublic change' ]

  # Latest commit on main@local should be a checkpoint
  subject="$(git log -1 --format='%s' main@local)"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "base sync --recover handles an amended public commit" {
  git checkout -q -b main@local
  git shadow base sync

  git checkout -q main
  echo "public change" >> file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -q -m "public change"

  git checkout -q main@local
  git shadow base sync

  # Amend the public commit with the same diff
  git checkout -q main
  GIT_SHADOW=1 git commit -q --amend -m "public change (amended)"

  git checkout -q main@local
  run git shadow base sync --recover
  [ "$status" -eq 0 ]

  # Local base still has the public content
  [ "$(cat file.txt)" = $'initial\npublic change' ]
}

@test "base sync re-anchors annotation sidecars" {
  git shadow config set ANNOTATION_FUZZY_THRESHOLD 0.5 --project-config >/dev/null

  # Create a public base commit with the clean source.
  cat > file.txt <<-'EOF'
A
B
C
EOF
  git add file.txt
  GIT_SHADOW=1 git commit -q -m "add ABC"

  git checkout -q -b main@local
  git shadow base sync

  # Add a marker on the local branch and commit with git shadow.
  cat > file.txt <<-'EOF'
A
B
/// note
C
EOF
  git add file.txt
  git shadow commit -q -m "add note"

  # Public base changes a line inside the hunk.
  git checkout -q main
  cat > file.txt <<-'EOF'
A
B2
C
EOF
  git add file.txt
  GIT_SHADOW=1 git commit -q -m "change B"

  git checkout -q main@local
  run git shadow base sync
  [ "$status" -eq 0 ]

  # Source is clean but rendered view includes re-anchored marker.
  [ "$(cat file.txt)" = $'A\nB2\nC' ]
  run git shadow show --with-annotations file.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"B2"* ]]
  [[ "$output" == *"/// note"* ]]

  # A [MEMORY] re-anchor sidecar commit was created.
  git log --format='%s' -n 4 main@local | grep -q 're-anchor sidecars'
}

@test "base sync removes sidecar when public source is deleted" {
  cat > file.txt <<-'EOF'
A
B
C
EOF
  git add file.txt
  GIT_SHADOW=1 git commit -q -m "add ABC"

  git checkout -q -b main@local
  git shadow base sync

  cat > file.txt <<-'EOF'
A
B
/// note
C
EOF
  git add file.txt
  git shadow commit -q -m "add note"

  git checkout -q main
  git rm -q file.txt
  GIT_SHADOW=1 git commit -q -m "delete file"

  git checkout -q main@local
  run git shadow base sync
  [ "$status" -eq 0 ]

  [ ! -f file.txt ]
  [ ! -f .git-shadow/annotations/file.txt ]

  # A [MEMORY] re-anchor sidecar commit was created.
  git log --format='%s' -n 4 main@local | grep -q 're-anchor sidecars'
}

@test "base sync --abort restores local branch" {
  git checkout -q -b main@local
  git shadow base sync

  # Public and local diverge in a conflicting way
  git checkout -q main
  echo "public" > file.txt
  GIT_SHADOW=1 git add file.txt && GIT_SHADOW=1 git commit -q -m "public change"

  git checkout -q main@local
  echo "local" > file.txt
  git add file.txt
  git commit -q -m "local change"

  run git shadow base sync
  [ "$status" -ne 0 ]

  run git shadow base sync --abort
  [ "$status" -eq 0 ]
  [ "$(cat file.txt)" = "local" ]
  # The abort message names the discarded conflicting paths.
  [[ "$output" == *"file.txt"* ]]
}

@test "base sync refuses to run while a finish is paused" {
  echo "phase=base-diff" > .git/git-shadow-finish
  run git shadow base sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"finish"* ]]
}
