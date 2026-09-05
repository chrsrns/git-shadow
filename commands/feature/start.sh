#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/start.sh
# Purpose: create a feature branch and corresponding @local shadow branch
#          from the current base checkpoint pair.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# No argument: smart detection based on current branch
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
  enter_project '.'
  ensure_clean_repo

  CURRENT_BRANCH="$(current_branch)"
  if [[ -z "$CURRENT_BRANCH" ]]; then
    ui_error "Unable to determine current branch."
    exit 1
  fi

  # Case 1: already on a @local branch (other than base) — ask for a name
  if [[ "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
    ui_error "You are already on a shadow branch ('$CURRENT_BRANCH')."
    ui_info  "Provide a feature name to create a new feature branch."
    exit 1
  fi

  # Current branch is a public branch: ensure its local base exists and sync it.
  PUBLIC_BASE="$CURRENT_BRANCH"
  LOCAL_BASE="${CURRENT_BRANCH}${LOCAL_SUFFIX}"

  if ! git show-ref --verify --quiet "refs/heads/$PUBLIC_BASE"; then
    ui_error "Public base branch does not exist: $PUBLIC_BASE"
    exit 1
  fi

  if ! git show-ref --verify --quiet "refs/heads/$LOCAL_BASE"; then
    ui_info "Creating local base '$LOCAL_BASE' from '$PUBLIC_BASE'."
    git branch "$LOCAL_BASE" "$PUBLIC_BASE"
  fi

  git checkout "$LOCAL_BASE"
  "$TOOLKIT_ROOT/commands/base/sync.sh"
  ui_ok "Switched to local base '$LOCAL_BASE'."
  exit 0
fi

# ---------------------------------------------------------------------------
# Argument provided: standard feature creation
# ---------------------------------------------------------------------------
FEATURE_NAME="$1"
PUBLIC_FEATURE="$FEATURE_NAME"
LOCAL_FEATURE="${FEATURE_NAME}${LOCAL_SUFFIX}"

# Validate branch name before doing any git operations
if ! git check-ref-format --branch "$FEATURE_NAME" >/dev/null 2>&1; then
  ui_error "Invalid branch name: '$FEATURE_NAME'"
  exit 1
fi

enter_project '.'
ensure_clean_repo

CURRENT_BRANCH="$(current_branch)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  ui_error "Unable to determine current branch."
  exit 1
fi

# Determine the base pair from the current branch.
PUBLIC_BASE="$(public_branch_from_any "$CURRENT_BRANCH")"
LOCAL_BASE="$(local_branch_from_any "$CURRENT_BRANCH")"

if ! git show-ref --verify --quiet "refs/heads/$PUBLIC_BASE"; then
  ui_error "Public base branch does not exist: $PUBLIC_BASE"
  exit 1
fi

if ! git show-ref --verify --quiet "refs/heads/$LOCAL_BASE"; then
  ui_info "Local base branch '$LOCAL_BASE' not found, creating from '$PUBLIC_BASE'."
  git branch "$LOCAL_BASE" "$PUBLIC_BASE"
fi

# Run base sync from the local base.
if [[ "$CURRENT_BRANCH" != "$LOCAL_BASE" ]]; then
  git checkout "$LOCAL_BASE"
fi
"$TOOLKIT_ROOT/commands/base/sync.sh"

# The latest checkpoint on the local base is the branch point.
LATEST_CP="$(checkpoint_latest "$LOCAL_BASE")"
if [[ -z "$LATEST_CP" ]]; then
  ui_error "No checkpoint found on local base '$LOCAL_BASE' after sync."
  exit 1
fi

PUBLIC_CP="$(checkpoint_public "$LATEST_CP")"
LOCAL_CP="$(checkpoint_local "$LATEST_CP")"

if git show-ref --verify --quiet "refs/heads/$PUBLIC_FEATURE"; then
  ui_error "Branch already exists: $PUBLIC_FEATURE"
  exit 1
fi
if git show-ref --verify --quiet "refs/heads/$LOCAL_FEATURE"; then
  ui_error "Branch already exists: $LOCAL_FEATURE"
  exit 1
fi

ui_git "Creating public feature branch '$PUBLIC_FEATURE' from '$PUBLIC_BASE'"
git branch "$PUBLIC_FEATURE" "$PUBLIC_CP"

ui_shadow "Creating local feature branch '$LOCAL_FEATURE' from '$LOCAL_BASE'"
git branch "$LOCAL_FEATURE" "$LOCAL_CP"

ui_shadow "Switching to local working branch '$LOCAL_FEATURE'"
git checkout "$LOCAL_FEATURE"

ui_shadow "Adding initial checkpoint to '$LOCAL_FEATURE'"
_new_checkpoint="$(checkpoint_create "$PUBLIC_CP" "$LOCAL_CP")"

"$TOOLKIT_ROOT/commands/install-hooks.sh"

ui_ok "Created '$PUBLIC_FEATURE' and '$LOCAL_FEATURE'."
