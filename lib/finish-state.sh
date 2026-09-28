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
