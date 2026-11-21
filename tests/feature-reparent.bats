#!/usr/bin/env bats

# feature reparent: config-only shadow-parent rewrite with pending-edge
# validation (V302, V297, V294).

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
  git checkout -q main
  git shadow feature start other-feature >/dev/null
  git checkout -q main
  git shadow feature start child-feature --onto parent-feature >/dev/null
  git checkout -q main
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "feature reparent rewrites shadow-parent to a live pair" {
  run git shadow feature reparent child-feature --onto other-feature
  [ "$status" -eq 0 ]
  [ "$(git config --get branch.child-feature@local.shadow-parent)" = "other-feature" ]
}

@test "feature reparent --onto accepts the @local spelling" {
  run git shadow feature reparent child-feature --onto "other-feature@local"
  [ "$status" -eq 0 ]
  [ "$(git config --get branch.child-feature@local.shadow-parent)" = "other-feature" ]
}

@test "feature reparent --onto the base pair clears shadow-parent" {
  run git shadow feature reparent child-feature --onto main
  [ "$status" -eq 0 ]
  ! git config --get branch.child-feature@local.shadow-parent >/dev/null
}

@test "feature reparent --onto base @local also clears shadow-parent" {
  run git shadow feature reparent child-feature --onto "main@local"
  [ "$status" -eq 0 ]
  ! git config --get branch.child-feature@local.shadow-parent >/dev/null
}

@test "feature reparent unstacks a hand-written base-valued parent" {
  git config branch.child-feature@local.shadow-parent main
  run git shadow feature reparent child-feature --onto other-feature
  [ "$status" -eq 0 ]
  [ "$(git config --get branch.child-feature@local.shadow-parent)" = "other-feature" ]
}

@test "feature reparent requires --onto" {
  run git shadow feature reparent child-feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"--onto"* ]]
}

@test "feature reparent refuses an unknown feature pair" {
  run git shadow feature reparent missing-feature --onto parent-feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing-feature"* ]]
}

@test "feature reparent refuses a half-dead feature pair" {
  git update-ref -d "refs/heads/child-feature@local"
  run git shadow feature reparent child-feature --onto parent-feature
  [ "$status" -eq 1 ]
}

@test "feature reparent refuses the base pair as <name>" {
  run git shadow feature reparent main --onto parent-feature
  [ "$status" -eq 1 ]
}

@test "feature reparent refuses self-parent" {
  run git shadow feature reparent child-feature --onto child-feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"itself"* ]]
}

@test "feature reparent refuses a missing parent pair" {
  run git shadow feature reparent child-feature --onto ghost-feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"ghost-feature"* ]]
}

@test "feature reparent refuses a half-dead parent pair" {
  git update-ref -d "refs/heads/other-feature@local"
  run git shadow feature reparent child-feature --onto other-feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"other-feature"* ]]
}

@test "feature reparent refuses a cycle naming the leg" {
  # child -> parent already; reparenting parent onto child closes a loop.
  run git shadow feature reparent parent-feature --onto child-feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"cycle"* ]]
}

@test "feature reparent refuses a depth-9 chain" {
  # Build d1..d9 stacked linearly; reparenting d9's root under an
  # unstacked pair would push depth past 8. Build the chain directly.
  prev="child-feature"
  for i in 1 2 3 4 5 6 7; do
    git shadow feature start "d$i" --onto "$prev" >/dev/null
    prev="d$i"
  done
  # child->parent is depth1; d7 is depth 8 — legal. Another level under
  # child-feature would make d7's chain depth 9.
  run git shadow feature reparent parent-feature --onto other-feature
  # parent->other is still depth-legal everywhere (d7 sees +1 → 9? no:
  # reparenting parent adds one link for the whole d-chain).
  # The chain d7->...->child->parent->other->... is depth 8→9 — abort.
  [ "$status" -eq 1 ]
  [[ "$output" == *"depth"* ]]
}

@test "feature reparent succeeds while a sync is paused" {
  # Config-only write; paused sync state does not gate it.
  git checkout -q "other-feature@local"
  git rev-parse --git-dir > /dev/null
  mkdir -p "$(git rev-parse --git-common-dir)"
  printf 'mode=feature\nlocal_branch=other-feature@local\n' \
    > "$(git rev-parse --git-common-dir)/git-shadow-sync"
  run git shadow feature reparent child-feature --onto other-feature
  [ "$status" -eq 0 ]
  [ "$(git config --get branch.child-feature@local.shadow-parent)" = "other-feature" ]
  rm -f "$(git rev-parse --git-common-dir)/git-shadow-sync"
}

@test "feature reparent help prints usage" {
  run git shadow feature reparent --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: git shadow feature reparent <name> --onto <parent>"* ]]
}
