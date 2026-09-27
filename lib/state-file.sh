#!/usr/bin/env bash

# -------------------------------------------------------------------
# Library: state-file.sh
# Purpose: single implementation for paused-operation state files
#          (git-shadow-sync, git-shadow-finish).
#
# A state file is a flat list of `key=value` lines living in the common
# .git dir so a paused operation is visible from every worktree.
# -------------------------------------------------------------------

# Print the absolute path of state file <name> under the common git dir.
# --git-path would resolve unknown names to the per-worktree admin dir;
# --git-common-dir is required (V123). Falls back to .git/<name> when the
# common dir cannot be resolved.
state_file() {
  local name="$1"
  local git_dir
  git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || true
  if [[ -z "$git_dir" ]]; then
    printf '%s\n' ".git/$name"
  else
    printf '%s/%s\n' "$git_dir" "$name"
  fi
}

# Write each key=value argument as its own line to <file>.
state_save() {
  local file="$1"
  shift
  printf '%s\n' "$@" > "$file"
}

# Load <file> into shell variables named <PREFIX>_<UPPER-KEY>:
# `pre_finish_head=x` loaded with prefix FINISH sets $FINISH_PRE_FINISH_HEAD.
# Blank lines and #-comments are skipped. Returns 1 when <file> is absent.
state_load() {
  local file="$1"
  local prefix="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local key value var
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    var="${prefix}_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
    printf -v "$var" '%s' "$value"
  done < "$file"
  return 0
}

# Remove <file>.
state_clear() {
  rm -f "$1"
}

# Return 0 when <file> exists.
state_active() {
  [[ -f "$1" ]]
}
