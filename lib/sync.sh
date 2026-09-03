#!/usr/bin/env bash

# -------------------------------------------------------------------
# Library: sync.sh
# Purpose: shared helpers for diff-sync apply/continue/abort/recover.
# -------------------------------------------------------------------

SYNC_STATE_FILE_NAME="git-shadow-sync"

sync_state_file() {
  local git_dir
  git_dir="$(git rev-parse --git-dir 2>/dev/null)" || true
  if [[ -z "$git_dir" ]]; then
    printf '%s\n' ".git/$SYNC_STATE_FILE_NAME"
  else
    printf '%s/%s\n' "$git_dir" "$SYNC_STATE_FILE_NAME"
  fi
}

sync_has_conflicts() {
  git ls-files -u >/dev/null 2>&1 && [[ -n "$(git ls-files -u)" ]]
}

sync_tree_changed() {
  ! git diff --cached --quiet
}

# Print the patch-ids of the public commits in start..end, one per line.
sync_patch_ids() {
  local start="$1"
  local end="$2"
  git rev-list --reverse "${start}..${end}" 2>/dev/null | while IFS= read -r sha; do
    git show --format=email --no-color "$sha" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}'
  done
}

# Apply the net diff from start..end to the current working tree using a
# 3-way merge. Returns the same exit code as git apply.
sync_apply_range() {
  local start="$1"
  local end="$2"
  git diff "$start".."$end" | git apply --3way
}

# Try to find a new ancestor in the rewritten public history.
# Arguments: <end_public_sha> <pids_file>
# Prints the matching commit SHA, or returns 1 if none found.
sync_recover_ancestor() {
  local end_public="$1"
  local pids_file="$2"
  while IFS= read -r sha; do
    local pid
    pid="$(git show --format=email --no-color "$sha" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')"
    if [[ -n "$pid" ]] && grep -qxF "$pid" "$pids_file" 2>/dev/null; then
      printf '%s\n' "$sha"
      return 0
    fi
  done < <(git rev-list "$end_public")
  return 1
}

# Write the sync state file.
sync_save_state() {
  local file
  file="$(sync_state_file)"
  {
    echo "mode=$1"
    echo "public_branch=$2"
    echo "local_branch=$3"
    echo "checkpoint_public=$4"
    echo "checkpoint_local=$5"
    echo "target_public=$6"
    echo "local_head=$7"
    echo "pids=$8"
  } > "$file"
}

# Load the sync state file into shell variables.
sync_load_state() {
  local file
  file="$(sync_state_file)"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    case "$key" in
      mode)               SYNC_MODE="$value" ;;
      public_branch)      SYNC_PUBLIC_BRANCH="$value" ;;
      local_branch)       SYNC_LOCAL_BRANCH="$value" ;;
      checkpoint_public)  SYNC_CHECKPOINT_PUBLIC="$value" ;;
      checkpoint_local)   SYNC_CHECKPOINT_LOCAL="$value" ;;
      target_public)      SYNC_TARGET_PUBLIC="$value" ;;
      local_head)         SYNC_LOCAL_HEAD="$value" ;;
      pids)               SYNC_PIDS="$value" ;;
    esac
  done < "$file"
  return 0
}

sync_clear_state() {
  local file
  file="$(sync_state_file)"
  rm -f "$file"
}
