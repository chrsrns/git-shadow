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

  git shadow feature start test-feature >/dev/null
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "commit subtracts a local patch from the staged public file" {
  # Overlay a local-only patch without adding local markers.
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null

  # Stage the patched file as public work.
  git add file.txt

  # git shadow commit should create a clean public commit without the overlay.
  run git shadow commit -m "update file"
  [ "$status" -eq 0 ]

  # Public tree has the original content.
  run git show HEAD:file.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *$'A\nB\nC'* ]]

  # [MEMORY] commit keeps the patch sidecar.
  [ -f .git-shadow/patches/file.txt.patch ]
}

@test "commit routes a staged .git-shadow/patches sidecar to [MEMORY]" {
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null
  git add .git-shadow/patches/file.txt.patch

  # A pre-existing public change is needed so there is a public index.
  git add file.txt

  run git shadow commit -m "route sidecar"
  [ "$status" -eq 0 ]

  # The patch sidecar is committed in the [MEMORY] commit.
  git log -1 --format='%s' HEAD | grep -q '^\[MEMORY\]'
}
