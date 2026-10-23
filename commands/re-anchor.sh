#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: re-anchor.sh
# Purpose: re-anchor a @local branch to a rewritten public branch.
#
# Usage: git shadow re-anchor [<branch@local>]
# -------------------------------------------------------------------

_GS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/help.sh"
if gs_help_requested -- "$@"; then
  echo "Usage: git shadow re-anchor [<branch@local>] [<ignored>...]"
  exit 0
fi

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/common.sh"

enter_project '.'

# Guard: do not re-anchor while a git-shadow sync is in progress.
if state_active "$(sync_state_file)"; then
  ui_error "A git-shadow sync is in progress. Resolve it before re-anchoring."
  exit 1
fi

# Guard: do not re-anchor while a feature finish is paused.
if finish_state_active; then
  ui_error "A feature finish is in progress. Resolve it before re-anchoring."
  exit 1
fi

ensure_clean_repo

if [[ $# -gt 0 ]]; then
  LOCAL_BRANCH="$1"
  shift
else
  LOCAL_BRANCH="$(current_branch)"
fi

if [[ -z "$LOCAL_BRANCH" ]]; then
  ui_error "Unable to determine current branch."
  exit 1
fi

if [[ ! "$LOCAL_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
  ui_error "re-anchor requires a branch ending with '${LOCAL_SUFFIX}'."
  exit 1
fi

PUBLIC_BRANCH="$(public_branch_from_any "$LOCAL_BRANCH")"

if ! branch_exists "$PUBLIC_BRANCH"; then
  ui_error "Public branch does not exist: $PUBLIC_BRANCH"
  exit 1
fi

LOCAL_HEAD="$(git rev-parse "$LOCAL_BRANCH")"

# Re-anchor body: executed inside patches_transaction so sidecars are stripped
# before any checkout and re-applied on every return/exit path.
_reanchor_body() {
  # Worktree-aware ref move (V282): the public branch checked out in a
  # worktree other than this one cannot be moved — merge/reset would corrupt
  # that worktree's view — so abort naming it before any mutation.
  local held_path invoking_top
  held_path="$(worktree_find_for_branch "$PUBLIC_BRANCH" 2>/dev/null || true)"
  invoking_top="$(git rev-parse --show-toplevel)"
  if [[ -n "$held_path" && "$held_path" != "$invoking_top" ]]; then
    ui_error "Public branch '$PUBLIC_BRANCH' is checked out in worktree '$held_path'."
    ui_info  "Detach it there first (git -C \"$held_path\" checkout --detach), then re-run re-anchor."
    return 1
  fi

  # ---------------------------------------------------------------------------
  # Fetch and fast-forward / reset the public branch
  # ---------------------------------------------------------------------------
  NEW_PUBLIC_HEAD=""
  if git remote >/dev/null 2>&1; then
    if git fetch origin "$PUBLIC_BRANCH" >/dev/null 2>&1; then
      remote_ref="origin/$PUBLIC_BRANCH"
      if git rev-parse --verify --quiet "$remote_ref" >/dev/null 2>&1; then
        NEW_PUBLIC_HEAD="$(git rev-parse "$remote_ref")"
        if git merge-base --is-ancestor "$NEW_PUBLIC_HEAD" "$(git rev-parse "$PUBLIC_BRANCH")"; then
          # Local public is ahead of or equal to remote; keep it.
          NEW_PUBLIC_HEAD="$(git rev-parse "$PUBLIC_BRANCH")"
        elif [[ -n "$held_path" ]]; then
          # The invoking checkout holds the branch: merge/reset moves ref and
          # worktree atomically (we are already on it).
          if git merge --ff-only --no-edit "$NEW_PUBLIC_HEAD" >/dev/null 2>&1; then
            :
          else
            git reset --hard "$NEW_PUBLIC_HEAD" >/dev/null 2>&1
          fi
        else
          # Checked out nowhere: move the ref itself — never merge/reset into
          # an unrelated checkout.
          git branch -f "$PUBLIC_BRANCH" "$NEW_PUBLIC_HEAD" >/dev/null 2>&1 \
            || git update-ref "refs/heads/$PUBLIC_BRANCH" "$NEW_PUBLIC_HEAD"
        fi
      fi
    fi
  fi

  if [[ -z "$NEW_PUBLIC_HEAD" ]]; then
    NEW_PUBLIC_HEAD="$(git rev-parse "$PUBLIC_BRANCH")"
  fi

  PUBLIC_HEAD="$(git rev-parse "$PUBLIC_BRANCH")"

  # ---------------------------------------------------------------------------
  # Verify the local tree contains the public tree
  # ---------------------------------------------------------------------------
  if ! check_tree_matches "$PUBLIC_HEAD" "$LOCAL_HEAD"; then
    ui_error "The local tree on '$LOCAL_BRANCH' does not contain the public tree on '$PUBLIC_BRANCH'. Resolve conflicts before re-anchoring."
    git checkout -q "$LOCAL_BRANCH" >/dev/null 2>&1 || true
    return 1
  fi

  # ---------------------------------------------------------------------------
  # Create a fresh checkpoint
  # ---------------------------------------------------------------------------
  # V10: store patch-ids for all public commits reachable from the new head.
  PIDS=""
  for sha in $(git rev-list --reverse "$PUBLIC_HEAD"); do
    pid="$(patch_id_for "$sha")"
    if [[ -n "$pid" ]]; then
      PIDS="$PIDS $pid"
    fi
  done
  PIDS="${PIDS# }"

  git checkout -q "$LOCAL_BRANCH" >/dev/null 2>&1

  if ! _new_checkpoint="$(sync_reanchor_and_checkpoint "$LOCAL_BRANCH" "$PUBLIC_HEAD" $PIDS)"; then
    return 1
  fi
  return 0
}

if ! patches_transaction _reanchor_body; then
  exit 1
fi
ui_ok "Re-anchored '$LOCAL_BRANCH' to '$PUBLIC_BRANCH'."
