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
