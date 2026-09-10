#!/usr/bin/env bash

# -------------------------------------------------------------------
# Library: finish-state.sh
# Purpose: save/load/clear the resumable `git shadow feature finish` state.
# -------------------------------------------------------------------

FINISH_STATE_FILE_NAME="git-shadow-finish"

# The finish state file lives in the common .git dir so a paused finish is
# visible from every worktree. --git-path would resolve unknown names to
# the per-worktree admin dir; --git-common-dir is required.
finish_state_file() {
  local git_dir
  git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || true
  if [[ -z "$git_dir" ]]; then
    printf '%s\n' ".git/$FINISH_STATE_FILE_NAME"
  else
    printf '%s/%s\n' "$git_dir" "$FINISH_STATE_FILE_NAME"
  fi
}

# Write the paused-finish state file.
finish_save_state() {
  local file
  file="$(finish_state_file)"
  {
    echo "feature_public=$1"
    echo "feature_local=$2"
    echo "local_base=$3"
    echo "pre_finish_head=$4"
    echo "phase=$5"
    echo "conflicted_sha=$6"
    echo "remaining_shas=$7"
    echo "range_start=$8"
    echo "range_end=$9"
    echo "pids=${10}"
    echo "keep_worktree=${11}"
    echo "keep_branches=${12}"
  } > "$file"
}

# Load the finish state file into FINISH_* variables.
finish_load_state() {
  local file
  file="$(finish_state_file)"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    case "$key" in
      feature_public)  FINISH_FEATURE_PUBLIC="$value" ;;
      feature_local)   FINISH_FEATURE_LOCAL="$value" ;;
      local_base)      FINISH_LOCAL_BASE="$value" ;;
      pre_finish_head) FINISH_PRE_FINISH_HEAD="$value" ;;
      phase)           FINISH_PHASE="$value" ;;
      conflicted_sha)  FINISH_CONFLICTED_SHA="$value" ;;
      remaining_shas)  FINISH_REMAINING_SHAS="$value" ;;
      range_start)     FINISH_RANGE_START="$value" ;;
      range_end)       FINISH_RANGE_END="$value" ;;
      pids)            FINISH_PIDS="$value" ;;
      keep_worktree)   FINISH_KEEP_WORKTREE="$value" ;;
      keep_branches)   FINISH_KEEP_BRANCHES="$value" ;;
    esac
  done < "$file"
  return 0
}

finish_clear_state() {
  local file
  file="$(finish_state_file)"
  rm -f "$file"
}

finish_state_active() {
  [[ -f "$(finish_state_file)" ]]
}
