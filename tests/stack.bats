#!/usr/bin/env bats

# Stack helpers (V294, V295, V297, V299): shadow-parent config read,
# effective-base resolution, cycle/depth failure, publish-range exclusion,
# and the publish pre-flight probe.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TOOLKIT_ROOT
  # shellcheck disable=SC1091
  source "$TOOLKIT_ROOT/lib/common.sh"

  git symbolic-ref HEAD refs/heads/main
  echo "initial" > file.txt
  git add file.txt
  git commit -q -m "initial"
  git checkout -q -b main@local
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Create a bare feature pair (both legs, pointing at HEAD).
make_pair() {
  git branch "$1"
  git branch "$1${LOCAL_SUFFIX}"
}

@test "stack_parent_for prints nothing when unset" {
  make_pair feature/a
  run stack_parent_for "feature/a@local"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stack_parent_for prints the configured parent" {
  make_pair feature/a
  git config "branch.feature/a@local.shadow-parent" "feature/x"
  run stack_parent_for "feature/a@local"
  [ "$status" -eq 0 ]
  [ "$output" = "feature/x" ]
}

@test "stack_local_base resolves to itself on the base pair" {
  git config "branch.main@local.shadow-parent" "feature/stray"
  run stack_local_base "main@local"
  [ "$status" -eq 0 ]
  [ "$output" = "main@local" ]
}

@test "stack_local_base resolves to base pair when shadow-parent unset" {
  make_pair feature/a
  run stack_local_base "feature/a@local"
  [ "$status" -eq 0 ]
  [ "$output" = "main@local" ]
}

@test "stack_local_base resolves to the live parent @local" {
  make_pair feature/a
  make_pair feature/b
  git config "branch.feature/b@local.shadow-parent" "feature/a"
  run stack_local_base "feature/b@local"
  [ "$status" -eq 0 ]
  [ "$output" = "feature/a@local" ]
}

@test "stack_local_base falls to base pair on a dangling parent" {
  make_pair feature/b
  git config "branch.feature/b@local.shadow-parent" "feature/ghost"
  run stack_local_base "feature/b@local"
  [ "$status" -eq 0 ]
  [ "$output" = "main@local" ]
}

@test "stack_local_base falls to base pair on a half-dead parent" {
  make_pair feature/b
  # Only the @local leg of the parent exists.
  git branch "feature/a@local"
  git config "branch.feature/b@local.shadow-parent" "feature/a"
  run stack_local_base "feature/b@local"
  [ "$status" -eq 0 ]
  [ "$output" = "main@local" ]
  # Only the public leg of the parent exists.
  git branch -D "feature/a@local" >/dev/null
  git branch "feature/a"
  run stack_local_base "feature/b@local"
  [ "$status" -eq 0 ]
  [ "$output" = "main@local" ]
}

@test "stack_local_base does not walk a dead link to a grandparent" {
  make_pair feature/b
  make_pair feature/c
  # feature/a is half-dead (@local only) but carries its own live parent.
  git branch "feature/a@local"
  git config "branch.feature/a@local.shadow-parent" "feature/c"
  git config "branch.feature/b@local.shadow-parent" "feature/a"
  run stack_local_base "feature/b@local"
  [ "$status" -eq 0 ]
  [ "$output" = "main@local" ]
}

@test "stack_local_base fails naming the cycle" {
  make_pair feature/a
  make_pair feature/b
  git config "branch.feature/a@local.shadow-parent" "feature/b"
  git config "branch.feature/b@local.shadow-parent" "feature/a"
  run stack_local_base "feature/b@local"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle"* ]]
  [[ "$output" == *"feature/b"* ]]
}

@test "stack_local_base fails past depth 8" {
  local i
  for i in $(seq 1 10); do
    make_pair "feature/f$i"
  done
  for i in $(seq 1 9); do
    git config "branch.feature/f${i}@local.shadow-parent" "feature/f$((i + 1))"
  done
  run stack_local_base "feature/f1@local"
  [ "$status" -ne 0 ]
  [[ "$output" == *"depth"* ]]
  # A chain of exactly 8 links still resolves.
  git config --unset "branch.feature/f9@local.shadow-parent"
  run stack_local_base "feature/f1@local"
  [ "$status" -eq 0 ]
  [ "$output" = "feature/f2@local" ]
}

@test "stack_local_base treats a base-valued shadow-parent as terminal" {
  make_pair feature/a
  git config "branch.feature/a@local.shadow-parent" "main"
  run stack_local_base "feature/a@local"
  [ "$status" -eq 0 ]
  [ "$output" = "main@local" ]
}

@test "check_public_commits excludes commits reachable from the effective local base" {
  # Parent feature/a gets a code commit on its @local line.
  git checkout -q -b "feature/a@local"
  git branch "feature/a"
  echo "parent work" > parent.txt
  git add parent.txt
  git commit -q -m "feat: parent work"
  PARENT_SHA="$(git rev-parse HEAD)"

  # Child feature/b starts on the parent's @local head.
  git checkout -q -b "feature/b@local"
  git branch "feature/b"
  echo "child work" > child.txt
  git add child.txt
  git commit -q -m "feat: child work"
  CHILD_SHA="$(git rev-parse HEAD)"
  CP_LOCAL="$(git rev-parse main@local)"

  git config "branch.feature/b@local.shadow-parent" "feature/a"

  run check_public_commits "feature/b@local" "$CP_LOCAL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CHILD_SHA"* ]]
  [[ "$output" != *"$PARENT_SHA"* ]]
}

@test "check_public_commits resolves a failed stack walk to the base pair" {
  make_pair feature/a
  make_pair feature/b
  git config "branch.feature/a@local.shadow-parent" "feature/b"
  git config "branch.feature/b@local.shadow-parent" "feature/a"

  git checkout -q "feature/b@local"
  echo "child work" > child.txt
  git add child.txt
  git commit -q -m "feat: child work"
  CHILD_SHA="$(git rev-parse HEAD)"
  CP_LOCAL="$(git rev-parse main@local)"

  run check_public_commits "feature/b@local" "$CP_LOCAL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CHILD_SHA"* ]]
}
