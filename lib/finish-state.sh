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

# Write the paused-finish state file.
finish_save_state() {
  state_save "$(finish_state_file)" \
    "feature_public=$1" \
    "feature_local=$2" \
    "local_base=$3" \
    "pre_finish_head=$4" \
    "phase=$5" \
    "conflicted_sha=$6" \
    "remaining_shas=$7" \
    "range_start=$8" \
    "range_end=$9" \
    "pids=${10}" \
    "keep_worktree=${11}" \
    "keep_branches=${12}"
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
