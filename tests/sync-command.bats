#!/usr/bin/env bats

# Tests for lib/sync-command.sh:sync_command_run.

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
  export PATH="$TOOLKIT_ROOT/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "feature sync wrapper is a thin shell around sync_command_run" {
  [[ "$(cat "$BATS_TEST_DIRNAME/../commands/feature/sync.sh")" == *"sync_command_run feature"* ]]
}

@test "base sync wrapper is a thin shell around sync_command_run" {
  [[ "$(cat "$BATS_TEST_DIRNAME/../commands/base/sync.sh")" == *"sync_command_run base"* ]]
}

@test "sync --abort rejects an in-progress sync of a different mode" {
  git checkout -q -b main@local
  git shadow base sync

  # Fake a base sync in progress.
  git_dir="$(git rev-parse --git-dir)"
  cat > "$git_dir/git-shadow-sync" <<'EOF'
mode=base
public_branch=main
local_branch=main@local
checkpoint_public=0000000000000000000000000000000000000000
checkpoint_local=0000000000000000000000000000000000000000
target_public=0000000000000000000000000000000000000000
local_head=0000000000000000000000000000000000000000
pids=
EOF

  run git shadow feature sync --abort
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a feature sync"* ]]
}

@test "base sync creates an initial checkpoint when none exists" {
  git checkout -q -b main@local
  run git shadow base sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"initial checkpoint"* ]]
}

@test "sync_reanchor_and_checkpoint requires checkout on the local branch" {
  git checkout -q -b main@local
  git shadow base sync

  git checkout -q main
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  run sync_reanchor_and_checkpoint main@local "$(git rev-parse main)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires checkout on 'main@local'"* ]]
}

@test "sync conflict saves collected patch-ids to state for --continue" {
  git checkout -q -b main@local
  git shadow base sync

  # Public side makes an unrelated change.
  git checkout -q main
  echo "public change" > other.txt
  git add other.txt
  GIT_SHADOW=1 git commit -qm "feat: public change"

  # Local side changes the same file in an incompatible way.
  git checkout -q main@local
  echo "local conflict" > other.txt
  git add other.txt
  git commit -qm "feat: local change"

  # Another public change that will conflict when applied.
  git checkout -q main
  echo "public conflict" > other.txt
  git add other.txt
  GIT_SHADOW=1 git commit -qm "feat: public conflict"

  git checkout -q main@local
  run git shadow base sync
  [ "$status" -eq 1 ]

  # The state file must contain the patch-ids collected before the apply.
  state_file="$(git rev-parse --git-dir)/git-shadow-sync"
  [ -f "$state_file" ]
  state_pids="$(grep '^pids=' "$state_file" | cut -d= -f2)"
  [ -n "$state_pids" ]
}
