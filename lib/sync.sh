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

# Create a well-formed sync commit from a staged net diff.
#
# Arguments:
#   <local_branch>  name of the local branch receiving the sync
#   <public_branch> name of the public branch the diff came from
#   <start_sha>     start of the public diff range
#   <end_sha>       end of the public diff range
#   [source_branch] optional feature branch that produced the diff (for feature finish)
#
# The caller must stage the diff before calling. This function only runs
# `git commit` with a [SYNC] subject and a body describing the provenance.
sync_commit() {
  local local_branch="$1"
  local public_branch="$2"
  local start_sha="$3"
  local end_sha="$4"
  local source_branch="${5:-}"

  local short_start short_end
  short_start="$(git rev-parse --short "$start_sha")"
  short_end="$(git rev-parse --short "$end_sha")"

  local subject="[SYNC] $local_branch: net diff from $public_branch ($short_start..$short_end)"

  local -a body_args=()
  body_args+=(-m "Source: $public_branch")
  body_args+=(-m "Range: $start_sha..$end_sha")

  if [[ -n "$source_branch" ]]; then
    body_args+=(-m "Finished feature: $source_branch")
  fi

  local pids
  pids="$(sync_patch_ids "$start_sha" "$end_sha" | tr '\n' ' ' | sed 's/ $//')"
  if [[ -n "$pids" ]]; then
    body_args+=(-m "Patch-ids: $pids")
  fi

  env GIT_SHADOW=1 git commit --quiet -m "$subject" "${body_args[@]}"
}

# Print the patch-ids of the public commits in start..end, one per line.
sync_patch_ids() {
  local start="$1"
  local end="$2"
  local shas
  shas="$(git rev-list --reverse "${start}..${end}" 2>/dev/null | tr '\n' ' ')"
  if [[ -n "$shas" ]]; then
    patch_ids_for $shas
  fi
}

# Apply the net diff from start..end to the current working tree using a
# 3-way merge. Returns the same exit code as git apply.
sync_apply_range() {
  local start="$1"
  local end="$2"
  git diff "$start".."$end" | git apply --3way
}

# Apply the net diff from start..end, stage the changes (excluding
# .git-shadow.env), and create a [SYNC] commit when the tree changed.
#
# Prints the collected patch-ids (space-separated) on stdout before attempting
# the apply, so callers can save them to sync state when the apply conflicts.
#
# Returns 0 on success and 1 on conflict; the caller decides whether to save
# sync state, reset, or abort.
sync_apply_and_commit() {
  local local_branch="$1"
  local public_branch="$2"
  local start_sha="$3"
  local end_sha="$4"
  local source_branch="${5:-}"

  # Collect and print patch-ids first (V80).
  local pids
  pids="$(sync_patch_ids "$start_sha" "$end_sha" | tr '\n' ' ' | sed 's/ $//')"
  if [[ -n "$pids" ]]; then
    printf '%s\n' "$pids"
  fi

  # Apply net diff to the current working tree.
  if ! sync_apply_range "$start_sha" "$end_sha"; then
    return 1
  fi

  git add -A -- . ':(exclude).git-shadow.env'

  if sync_tree_changed; then
    sync_commit "$local_branch" "$public_branch" "$start_sha" "$end_sha" "$source_branch"
  fi
}

# Re-anchor local annotation sidecars, commit any updates as a [MEMORY] commit,
# and create a [CHECKPOINT].
#
# Usage: sync_reanchor_and_checkpoint <local_branch> <public_head> [pids...]
#
# The current checkout must be <local_branch> (V81). Prints the new checkpoint
# SHA on stdout.
sync_reanchor_and_checkpoint() {
  local local_branch="$1"
  local public_head="$2"
  shift 2

  local current_branch
  current_branch="$(current_branch)"
  if [[ "$current_branch" != "$local_branch" ]]; then
    ui_error "sync_reanchor_and_checkpoint requires checkout on '$local_branch' (current: '$current_branch')."
    return 1
  fi

  # Re-anchor local annotation sidecars to the updated source.
  annotations_reanchor_all_commit

  local new_local_head
  new_local_head="$(git rev-parse "$local_branch")"
  checkpoint_create "$public_head" "$new_local_head" "$@"
}

# Try to find a new ancestor in the rewritten public history.
# Arguments: <end_public_sha> <pids_file>
# Prints the matching commit SHA, or returns 1 if none found.
sync_recover_ancestor() {
  local end_public="$1"
  local pids_file="$2"
  while IFS= read -r sha; do
    local pid
    pid="$(patch_id_for "$sha")"
    if [[ -n "$pid" ]] && grep -qxF "$pid" "$pids_file" 2>/dev/null; then
      printf '%s\n' "$sha"
      return 0
    fi
  done < <(git rev-list "$end_public")
  return 1
}

# Write the sync state file.
#
# Arguments: <mode> <public_branch> <local_branch> <checkpoint_public>
#            <checkpoint_local> <diff_start> <target_public> <local_head> <pids>
# <diff_start> is the actual start of the applied net diff; it equals
# <checkpoint_public> unless --recover found a new-ancestor.
sync_save_state() {
  local file
  file="$(sync_state_file)"
  {
    echo "mode=$1"
    echo "public_branch=$2"
    echo "local_branch=$3"
    echo "checkpoint_public=$4"
    echo "checkpoint_local=$5"
    echo "diff_start=$6"
    echo "target_public=$7"
    echo "local_head=$8"
    echo "pids=$9"
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
      diff_start)         SYNC_DIFF_START="$value" ;;
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
