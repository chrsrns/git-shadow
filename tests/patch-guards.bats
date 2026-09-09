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
  source "$TOOLKIT_ROOT/lib/common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "guard_tree rejects a tree with .git-shadow/patches" {
  git shadow feature start guarded >/dev/null
  mkdir -p .git-shadow/patches
  printf -- '---\n+++\n@@ -1,3 +1,3 @@\n A\n-B\n+B local\n C\n' > .git-shadow/patches/file.txt.patch
  git add -f .git-shadow/patches/file.txt.patch
  GIT_SHADOW=1 git commit -qm "[MEMORY] patch"
  run guard_tree "guarded@local"
  [ "$status" -eq 1 ]
  [[ "$output" == *".git-shadow"* ]]
}

@test "guard_staged_files skips .git-shadow/patches" {
  git shadow feature start staged >/dev/null
  mkdir -p .git-shadow/patches
  printf 'patch\n' > .git-shadow/patches/file.txt.patch
  git add .git-shadow/patches/file.txt.patch
  run guard_staged_files
  [ "$status" -eq 0 ]
}

@test "check public flags .git-shadow/patches on public branch" {
  git shadow feature start checked >/dev/null
  git checkout -q checked
  mkdir -p .git-shadow/patches
  printf 'patch\n' > .git-shadow/patches/file.txt.patch
  git add -f .git-shadow/patches/file.txt.patch
  GIT_SHADOW=1 git commit -qm "add patch sidecar"
  run git shadow check public checked
  [ "$status" -eq 1 ]
  [[ "$output" == *".git-shadow"* ]]
}

@test "guard_staged_files rejects a staged file that has a patch sidecar" {
  git shadow feature start sidecar-guard >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null
  git add file.txt
  run guard_staged_files
  [ "$status" -eq 1 ]
  [[ "$output" == *"sidecar"* ]]
  [[ "$output" == *"git shadow commit"* ]]
}

@test "pre-commit hook rejects a staged file with a patch sidecar" {
  git shadow feature start hook-guard >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null
  git add file.txt
  run git commit -qm "leak attempt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sidecar"* ]]
}

@test "git shadow commit succeeds on a staged file that has a patch sidecar" {
  git shadow feature start own-op >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null
  git add file.txt
  run git shadow commit -m "public work"
  [ "$status" -eq 0 ]
  run git show HEAD:file.txt
  [[ "$output" == *$'A\nB\nC'* ]]
}

@test "local diff refuses to run while a sync is paused" {
  git shadow feature start diff-paused >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null
  echo "mode=feature" > .git/git-shadow-sync
  run git shadow local diff file.txt
  [ "$status" -eq 1 ]
  [[ "$output" == *"sync"* ]]
}

@test "local diff refuses to run while a finish is paused" {
  git shadow feature start diff-paused2 >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null
  echo "phase=base-diff" > .git/git-shadow-finish
  run git shadow local diff
  [ "$status" -eq 1 ]
  [[ "$output" == *"finish"* ]]
}
