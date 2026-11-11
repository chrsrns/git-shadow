#!/usr/bin/env bats

# Stacked feature pairs: `feature start` on a feature @local or with
# --onto creates a child pair off the parent pair's heads (V293, V296,
# V297).

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  git symbolic-ref HEAD refs/heads/develop
  echo "initial" > file.txt
  git add file.txt
  git commit -qm "initial"
  git shadow config set PUBLIC_BASE_BRANCH develop --project-config >/dev/null
  git checkout -q -b "develop@local"
  git checkout -q develop
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Create a feature pair via the toolkit; ends on <name>@local.
start_pair() {
  git checkout -q develop
  git shadow feature start "$1" >/dev/null
}

@test "feature start on a feature @local creates a stacked pair" {
  start_pair parent-feature
  git shadow feature start child-feature
  git show-ref --verify --quiet "refs/heads/child-feature"
  git show-ref --verify --quiet "refs/heads/child-feature@local"
  [ "$(git config --get branch.child-feature@local.shadow-parent)" = "parent-feature" ]
}

@test "stacked start derives the child public branch from the parent public head" {
  start_pair parent-feature
  git shadow feature start child-feature
  [ "$(git rev-parse child-feature)" = "$(git rev-parse parent-feature)" ]
  [ "$(git log -1 --format='%H' "child-feature@local^")" = "$(git rev-parse parent-feature@local)" ]
}

@test "stacked start writes an initial checkpoint recording the parent heads" {
  start_pair parent-feature
  git shadow feature start child-feature >/dev/null
  cp_subject="$(git log -1 --format='%s' child-feature@local)"
  [[ "$cp_subject" == *"public:$(git rev-parse parent-feature)"* ]]
  [[ "$cp_subject" == *"local:$(git rev-parse parent-feature@local)"* ]]
}

@test "stacked start ends checked out on the child @local" {
  start_pair parent-feature
  git shadow feature start child-feature >/dev/null
  [ "$(git branch --show-current)" = "child-feature@local" ]
}

@test "feature start --onto creates a stacked pair from an unrelated checkout" {
  start_pair parent-feature
  git checkout -q develop
  git shadow feature start child-feature --onto parent-feature
  [ "$(git config --get branch.child-feature@local.shadow-parent)" = "parent-feature" ]
  [ "$(git rev-parse child-feature)" = "$(git rev-parse parent-feature)" ]
}

@test "feature start --onto accepts an @local-suffixed parent name" {
  start_pair parent-feature
  git checkout -q develop
  git shadow feature start child-feature --onto parent-feature@local
  [ "$(git config --get branch.child-feature@local.shadow-parent)" = "parent-feature" ]
}

@test "feature start --onto the base pair refuses naming the unstacked path" {
  run git shadow feature start child-feature --onto develop
  [ "$status" -eq 1 ]
  [[ "$output" == *"develop"* ]]
  ! git show-ref --verify --quiet "refs/heads/child-feature"

  run git shadow feature start child-feature --onto develop@local
  [ "$status" -eq 1 ]
  ! git show-ref --verify --quiet "refs/heads/child-feature"
}

@test "feature start on an orphan @local refuses" {
  git checkout -q -b "ghost@local" develop
  run git shadow feature start child-feature
  [ "$status" -eq 1 ]
  ! git show-ref --verify --quiet "refs/heads/child-feature"
}

@test "feature start on a public feature branch refuses" {
  start_pair parent-feature
  git checkout -q parent-feature
  run git shadow feature start child-feature
  [ "$status" -eq 1 ]
  ! git show-ref --verify --quiet "refs/heads/child-feature"
}

@test "feature start --onto self refuses" {
  run git shadow feature start child-feature --onto child-feature
  [ "$status" -eq 1 ]
  ! git show-ref --verify --quiet "refs/heads/child-feature"
}

@test "feature start --onto a nonexistent pair refuses" {
  run git shadow feature start child-feature --onto ghost
  [ "$status" -eq 1 ]
  [[ "$output" == *"ghost"* ]]
  ! git show-ref --verify --quiet "refs/heads/child-feature"
}

@test "feature start --onto aborts on a pending-edge cycle" {
  start_pair parent-feature
  # A stored link from the target back to the not-yet-created child is a
  # cycle once the child exists.
  git config "branch.parent-feature@local.shadow-parent" "child-feature"
  git checkout -q develop
  run git shadow feature start child-feature --onto parent-feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"cycle"* ]]
  ! git show-ref --verify --quiet "refs/heads/child-feature"
}

@test "feature start --onto aborts past depth 8" {
  local i
  for i in $(seq 1 9); do
    git branch "feature/f$i"
    git branch "feature/f$i@local"
  done
  for i in $(seq 1 8); do
    git config "branch.feature/f${i}@local.shadow-parent" "feature/f$((i + 1))"
  done
  run git shadow feature start deep --onto feature/f1
  [ "$status" -eq 1 ]
  [[ "$output" == *"depth"* ]]
  ! git show-ref --verify --quiet "refs/heads/deep"
}

@test "feature start --onto a cyclical chain aborts naming the loop" {
  start_pair feature-a
  git checkout -q develop
  start_pair feature-b
  git config "branch.feature-a@local.shadow-parent" "feature-b"
  git config "branch.feature-b@local.shadow-parent" "feature-a"
  git checkout -q develop
  run git shadow feature start child-feature --onto feature-a
  [ "$status" -eq 1 ]
  [[ "$output" == *"cycle"* ]]
  ! git show-ref --verify --quiet "refs/heads/child-feature"
}

@test "feature start refuses an existing pair in stacked mode" {
  start_pair parent-feature
  git checkout -q develop
  git shadow feature start child-feature >/dev/null
  git checkout -q parent-feature@local
  run git shadow feature start child-feature
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}
