#!/usr/bin/env bats

# Tests for lib/guard.sh:guard_staged_files and guard_tree.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  echo "initial" > file.txt
  git add file.txt
  git commit -qm "initial"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"
  source "$TOOLKIT_ROOT/lib/common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "guard_staged_files rejects staged /// markers" {
  printf 'public\n/// local note\n' > file.txt
  git add file.txt
  run guard_staged_files
  [ "$status" -ne 0 ]
  [[ "$output" == *"/// markers"* ]]
}

@test "guard_staged_files rejects staged // @local markers" {
  printf 'public\n// @local note\n' > file.txt
  git add file.txt
  run guard_staged_files
  [ "$status" -ne 0 ]
  [[ "$output" == *"// @local markers"* ]]
}

@test "guard_staged_files skips .git-shadow/annotations" {
  mkdir -p .git-shadow/annotations
  printf '/// note\n' > .git-shadow/annotations/file.txt
  git add .git-shadow/annotations/file.txt
  run guard_staged_files
  [ "$status" -eq 0 ]
}

@test "guard_staged_files honors LOCAL_COMMENT_EXCLUDE for triple pattern" {
  export LOCAL_COMMENT_EXCLUDE="*.md"
  printf 'public\n/// docs note\n' > docs.md
  git add docs.md
  run guard_staged_files
  [ "$status" -eq 0 ]
}

@test "guard_tree rejects a tree with .git-shadow/annotations" {
  mkdir -p .git-shadow/annotations
  printf '/// note\n' > .git-shadow/annotations/file.txt
  git add .git-shadow/annotations/file.txt
  git commit -qm "sidecar"
  run guard_tree HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"local-only path"* ]]
}

@test "guard_tree rejects a tree with leaked // @local markers" {
  printf 'public\n// @local note\n' > file.txt
  git add file.txt
  git commit -qm "bad public"
  run guard_tree HEAD
  [ "$status" -ne 0 ]
  [[ "$output" == *"// @local markers"* ]]
}

@test "guard_tree accepts a clean tree" {
  printf 'public only\n' > file.txt
  git add file.txt
  git commit -qm "clean public"
  run guard_tree HEAD
  [ "$status" -eq 0 ]
}

@test "generated pre-commit hook embeds guard logic and needs no toolkit" {
  git shadow install-hooks
  ! grep -qE "TOOLKIT_ROOT|/run/media|lib/common\.sh|lib/guard\.sh" .git/hooks/pre-commit
  grep -q "guard_staged_files ()" .git/hooks/pre-commit
}
