#!/usr/bin/env bash

# -------------------------------------------------------------------
# Library: finish-state.sh
# Purpose: save/load/clear the resumable `git shadow feature finish` state.
#          Path resolution and the key=value format live in state-file.sh.
# -------------------------------------------------------------------

FINISH_STATE_FILE_NAME="git-shadow-finish"

# The finish state file lives in the common .git dir so a paused finish is
# visible from every worktree.
finish_state_file() {
  state_file "$FINISH_STATE_FILE_NAME"
}

# Write the paused-finish state file. Arguments are `key=value` pairs
# forwarded verbatim to state_save; the key set is named at the call site.
finish_save_state() {
  state_save "$(finish_state_file)" "$@"
}

# Write a fresh pause point with the full V85 key set serialized from the
# finish-context globals (FEATURE_PUBLIC_BRANCH, FEATURE_LOCAL_BRANCH,
# LOCAL_BASE, PRE_FINISH_HEAD, RANGE_START, RANGE_END, PIDS_BASE,
# KEEP_WORKTREE, KEEP_BRANCHES). Callers pass only the fields that vary per
# pause point: <phase>, [conflicted_sha], [remaining_shas], [pre_finish_head].
# An empty [pre_finish_head] defaults to $PRE_FINISH_HEAD.
finish_save_phase() {
  local phase="${1:?finish_save_phase: phase required}"
  local conflicted_sha="${2:-}"
  local remaining_shas="${3:-}"
  local pre_finish_head="${4:-$PRE_FINISH_HEAD}"
  finish_save_state \
    "feature_public=$FEATURE_PUBLIC_BRANCH" "feature_local=$FEATURE_LOCAL_BRANCH" \
    "local_base=$LOCAL_BASE" "pre_finish_head=$pre_finish_head" \
    "phase=$phase" "conflicted_sha=$conflicted_sha" \
    "remaining_shas=$remaining_shas" "range_start=$RANGE_START" \
    "range_end=$RANGE_END" "pids=$PIDS_BASE" \
    "keep_worktree=$KEEP_WORKTREE" "keep_branches=$KEEP_BRANCHES"
}

# Load the finish state file into FINISH_* variables.
finish_load_state() {
  state_load "$(finish_state_file)" FINISH
}

finish_clear_state() {
  state_clear "$(finish_state_file)"
}

finish_state_active() {
  state_active "$(finish_state_file)"
}
