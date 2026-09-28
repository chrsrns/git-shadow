#!/usr/bin/env bats

# Unit tests for lib/state-file.sh — the single owner of paused-op state
# files (path under the common git dir, key=value format, prefixed loads).
# Also covers the sync_*/finish_* wrappers, which must stay byte-compatible
# with the state format callers already rely on.

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
  source "$TOOLKIT_ROOT/lib/state-file.sh"
  source "$TOOLKIT_ROOT/lib/sync.sh"
  source "$TOOLKIT_ROOT/lib/finish-state.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- state_file -------------------------------------------------------------

@test "state_file resolves under the common git dir" {
  run state_file "git-shadow-sync"
  [ "$status" -eq 0 ]
  [ "$output" = "$(git rev-parse --git-common-dir)/git-shadow-sync" ]
}

@test "state_file inside a linked worktree resolves the shared common dir" {
  git worktree add -q "$TEST_DIR/wt" -b wt-branch
  run bash -c "cd '$TEST_DIR/wt' && source '$TOOLKIT_ROOT/lib/state-file.sh' && state_file git-shadow-sync"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$TEST_DIR" && git rev-parse --absolute-git-dir)/git-shadow-sync" ]
}

@test "state_file falls back to .git/<name> outside a repository" {
  local outside
  outside="$(mktemp -d)"
  run bash -c "cd '$outside' && source '$TOOLKIT_ROOT/lib/state-file.sh' && state_file foo-state"
  [ "$status" -eq 0 ]
  [ "$output" = ".git/foo-state" ]
  rm -rf "$outside"
}

# --- state_save / state_load -------------------------------------------------

@test "state_save writes one key=value line per argument in order" {
  state_save "$TEST_DIR/s" "alpha=1" "beta=two words" "gamma="
  [ "$(cat "$TEST_DIR/s")" = "$(printf 'alpha=1\nbeta=two words\ngamma=')" ]
}

@test "state_load maps keys to PREFIX_UPPER variables" {
  printf 'mode=feature\npre_finish_head=abc123\npids=p1 p2\n' > "$TEST_DIR/s"
  state_load "$TEST_DIR/s" FINISH
  [ "$FINISH_MODE" = "feature" ]
  [ "$FINISH_PRE_FINISH_HEAD" = "abc123" ]
  [ "$FINISH_PIDS" = "p1 p2" ]
}

@test "state_load returns 1 when the file is absent" {
  run state_load "$TEST_DIR/missing" SYNC
  [ "$status" -eq 1 ]
}

@test "state_load skips blank and comment lines" {
  printf '# comment\n\nmode=base\n' > "$TEST_DIR/s"
  state_load "$TEST_DIR/s" SYNC
  [ "$SYNC_MODE" = "base" ]
  [ -z "${SYNC__:-}" ]
}

# --- state_clear / state_active ----------------------------------------------

@test "state_active reports existence and state_clear removes the file" {
  run state_active "$TEST_DIR/s"
  [ "$status" -eq 1 ]
  state_save "$TEST_DIR/s" "k=v"
  run state_active "$TEST_DIR/s"
  [ "$status" -eq 0 ]
  state_clear "$TEST_DIR/s"
  [ ! -f "$TEST_DIR/s" ]
  run state_active "$TEST_DIR/s"
  [ "$status" -eq 1 ]
}

# --- sync_* wrappers delegate ------------------------------------------------

@test "sync_state_file resolves git-shadow-sync under the common dir" {
  [ "$(sync_state_file)" = "$(git rev-parse --git-common-dir)/git-shadow-sync" ]
}

@test "sync_save_state writes the documented key set and sync_load_state restores it" {
  # Keys passed out of declared order on purpose — the key=value interface is order-free.
  sync_save_state pids="p1 p2" mode=feature local_head=lh public_branch=pub \
    checkpoint_local=cp_loc diff_start=ds target_public=tp \
    local_branch=loc checkpoint_public=cp_pub
  local file
  file="$(sync_state_file)"
  grep -qx 'mode=feature' "$file"
  grep -qx 'public_branch=pub' "$file"
  grep -qx 'local_branch=loc' "$file"
  grep -qx 'checkpoint_public=cp_pub' "$file"
  grep -qx 'checkpoint_local=cp_loc' "$file"
  grep -qx 'diff_start=ds' "$file"
  grep -qx 'target_public=tp' "$file"
  grep -qx 'local_head=lh' "$file"
  grep -qx 'pids=p1 p2' "$file"

  sync_load_state
  [ "$SYNC_MODE" = "feature" ]
  [ "$SYNC_PUBLIC_BRANCH" = "pub" ]
  [ "$SYNC_LOCAL_BRANCH" = "loc" ]
  [ "$SYNC_CHECKPOINT_PUBLIC" = "cp_pub" ]
  [ "$SYNC_CHECKPOINT_LOCAL" = "cp_loc" ]
  [ "$SYNC_DIFF_START" = "ds" ]
  [ "$SYNC_TARGET_PUBLIC" = "tp" ]
  [ "$SYNC_LOCAL_HEAD" = "lh" ]
  [ "$SYNC_PIDS" = "p1 p2" ]

  sync_clear_state
  [ ! -f "$file" ]
  run sync_load_state
  [ "$status" -eq 1 ]
}

# --- finish_* wrappers delegate ----------------------------------------------

@test "finish_save_state writes all twelve keys and finish_load_state restores them" {
  # Keys passed out of declared order on purpose — the key=value interface is order-free.
  finish_save_state keep_branches=0 feature_public=fpub phase=memory-replay \
    range_end=re conflicted_sha=csha local_base=lbase \
    pids=p1 pre_finish_head=prehead feature_local=floc \
    remaining_shas="r1 r2" keep_worktree=1 range_start=rs
  local file
  file="$(finish_state_file)"
  [ "$file" = "$(git rev-parse --git-common-dir)/git-shadow-finish" ]
  grep -qx 'feature_public=fpub' "$file"
  grep -qx 'feature_local=floc' "$file"
  grep -qx 'local_base=lbase' "$file"
  grep -qx 'pre_finish_head=prehead' "$file"
  grep -qx 'phase=memory-replay' "$file"
  grep -qx 'conflicted_sha=csha' "$file"
  grep -qx 'remaining_shas=r1 r2' "$file"
  grep -qx 'range_start=rs' "$file"
  grep -qx 'range_end=re' "$file"
  grep -qx 'pids=p1' "$file"
  grep -qx 'keep_worktree=1' "$file"
  grep -qx 'keep_branches=0' "$file"

  finish_load_state
  [ "$FINISH_FEATURE_PUBLIC" = "fpub" ]
  [ "$FINISH_FEATURE_LOCAL" = "floc" ]
  [ "$FINISH_LOCAL_BASE" = "lbase" ]
  [ "$FINISH_PRE_FINISH_HEAD" = "prehead" ]
  [ "$FINISH_PHASE" = "memory-replay" ]
  [ "$FINISH_CONFLICTED_SHA" = "csha" ]
  [ "$FINISH_REMAINING_SHAS" = "r1 r2" ]
  [ "$FINISH_RANGE_START" = "rs" ]
  [ "$FINISH_RANGE_END" = "re" ]
  [ "$FINISH_PIDS" = "p1" ]
  [ "$FINISH_KEEP_WORKTREE" = "1" ]
  [ "$FINISH_KEEP_BRANCHES" = "0" ]

  run finish_state_active
  [ "$status" -eq 0 ]
  finish_clear_state
  run finish_state_active
  [ "$status" -eq 1 ]
  run finish_load_state
  [ "$status" -eq 1 ]
}
