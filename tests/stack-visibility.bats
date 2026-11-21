#!/usr/bin/env bats

# Stack visibility: feature list parent field, status parent line/key,
# doctor stack checks (V300, V301).

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

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TOOLKIT_ROOT
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  git shadow feature start parent-feature >/dev/null
  git shadow feature start child-feature >/dev/null
  git checkout -q main
  git shadow feature start unstacked-feature >/dev/null
  git checkout -q main
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "feature list shows the parent for a stacked pair" {
  run git shadow feature list
  [ "$status" -eq 0 ]
  [[ "$output" == *"child-feature"* ]]
  [[ "$output" == *"parent     : parent-feature"* ]]
  [[ "$output" == *"parent     : -"* ]]
}

@test "feature list --json emits the parent key" {
  run git shadow feature list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"parent":"parent-feature"'* ]]
  [[ "$output" == *'"parent":"-"'* ]]
}

@test "status prints the parent line on a stacked @local" {
  git checkout -q "child-feature@local"
  run git shadow status
  [ "$status" -eq 0 ]
  [[ "$output" == *"parent : parent-feature"* ]]
}

@test "status omits the parent line on an unstacked pair" {
  git checkout -q "unstacked-feature@local"
  run git shadow status
  [ "$status" -eq 0 ]
  [[ "$output" != *"parent"* ]]
}

@test "status --json emits parent on a stacked pair" {
  git checkout -q "child-feature@local"
  run git shadow status --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"parent":"parent-feature"'* ]]
}

@test "status --json omits parent on an unstacked pair" {
  git checkout -q "unstacked-feature@local"
  run git shadow status --json
  [ "$status" -eq 0 ]
  [[ "$output" != *'"parent"'* ]]
}

@test "status prints a dangling shadow-parent verbatim" {
  git update-ref -d "refs/heads/parent-feature@local"
  git update-ref -d "refs/heads/parent-feature"
  git checkout -q "child-feature@local"
  run git shadow status
  [ "$status" -eq 0 ]
  [[ "$output" == *"parent : parent-feature"* ]]
}

@test "status --json emits parent on the missing-public path" {
  git update-ref -d "refs/heads/child-feature"
  git checkout -q "child-feature@local"
  run git shadow status --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"parent":"parent-feature"'* ]]
}

@test "doctor warns on a dangling shadow-parent" {
  git update-ref -d "refs/heads/parent-feature@local"
  git update-ref -d "refs/heads/parent-feature"
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"child-feature@local"* ]]
  [[ "$output" == *"parent-feature"* ]]
  [[ "$output" == *"dangling"* ]]
}

@test "doctor warns on orphan shadow-parent config naming git config --unset" {
  git update-ref -d "refs/heads/child-feature@local"
  git update-ref -d "refs/heads/child-feature"
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"orphan"* ]]
  [[ "$output" == *"git config --unset"* ]]
}

@test "doctor warns on a shadow-parent cycle naming members" {
  git config branch.parent-feature@local.shadow-parent child-feature
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"cycle"* ]]
  [[ "$output" == *"parent-feature@local"* ]]
  [[ "$output" == *"child-feature@local"* ]]
}

@test "doctor warns on a shadow-parent chain past depth 8" {
  # feature start refuses depth 9 — hand-build the ninth link.
  prev="child-feature"
  for i in 1 2 3 4 5 6 7; do
    git shadow feature start "d$i" --onto "$prev" >/dev/null
    prev="d$i"
  done
  git branch d9 "d7"
  git branch "d9@local" "d7@local"
  git config branch.d9@local.shadow-parent d7
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"depth"* ]]
}

@test "doctor warns when the base pair @local carries shadow-parent" {
  git config branch.main@local.shadow-parent parent-feature
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"main@local"* ]]
}

@test "doctor warns on a shadow-parent key under a non-@local branch" {
  git config branch.child-feature.shadow-parent parent-feature
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid placement"* || "$output" == *"child-feature"* ]]
}

@test "doctor warns on an @local-suffixed shadow-parent value" {
  git config branch.child-feature@local.shadow-parent "parent-feature@local"
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid"* ]]
}

@test "doctor does not warn on a hand-written base-valued shadow-parent" {
  git config branch.child-feature@local.shadow-parent main
  run git shadow doctor
  [[ "$output" == *"stack: no shadow-parent problems"* ]]
}

@test "doctor does not clear stack config" {
  git config branch.child-feature@local.shadow-parent "parent-feature@local"
  git shadow doctor >/dev/null 2>&1 || true
  [ "$(git config --get branch.child-feature@local.shadow-parent)" = "parent-feature@local" ]
}
