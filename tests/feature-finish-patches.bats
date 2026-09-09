#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main
  printf 'A\nB\nC\n' > file.txt
  git add file.txt
  git commit -qm "initial"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TOOLKIT_ROOT
  export PATH="$TOOLKIT_ROOT/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "feature finish inherits .git-shadow/patches sidecars" {
  git shadow feature start inherited >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null
  git reset --hard HEAD >/dev/null
  printf 'feature\n' > feature.txt
  git add feature.txt
  git commit -qm "feat: add feature"
  git shadow feature publish >/dev/null
  git checkout -q main
  git merge -q --no-edit inherited
  git checkout -q main@local
  printf 'base\n' > base.txt
  git add base.txt
  git commit -qm "chore: base change"
  git checkout -q inherited@local
  run git shadow feature finish --no-pull
  [ "$status" -eq 0 ]
  [ -f "${TEST_DIR}/.git-shadow/patches/file.txt.patch" ]
}

@test "doctor reports no orphan sidecar when a patch overlay is applied" {
  git shadow feature start healthy >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null

  # An applied overlay is the normal state; doctor must not flag it.
  run git shadow doctor
  [[ "$output" == *"patches: no orphan sidecars"* ]]
}

@test "doctor warns about orphan patch sidecar" {
  git shadow feature start warned >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null
  git reset --hard HEAD >/dev/null
  git checkout -q main
  printf 'A\nB2\nC\n' > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -qm "chore: change B"
  git checkout -q warned@local
  # Make the sidecar unappliable to HEAD by deleting B entirely.
  # Bypass the sidecar guard: this synthetic orphan setup diverges the
  # source on purpose and is not a user-facing commit path.
  printf 'A\nC\n' > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -qm "[MEMORY] orphan patch"
  git shadow local apply >/dev/null 2>&1 || true
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"orphan sidecar"* ]]
}
