#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/start.sh
# Purpose: create a feature branch and corresponding @local shadow branch
#          from the current base checkpoint pair.
# -------------------------------------------------------------------

_GS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/help.sh"
if gs_help_requested --worktree-dir --onto -- "$@"; then
  echo "Usage: git shadow feature start [<name> [--onto <parent>] [--worktree|--worktree-dir <path>]]"
  exit 0
fi

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/common.sh"

# ---------------------------------------------------------------------------
# No argument: smart detection based on current branch
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
  enter_project '.'
  patches_require_no_paused_op
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

  # Only the configured public base may start a base pair.
  if [[ "$CURRENT_BRANCH" != "$PUBLIC_BASE_BRANCH" ]]; then
    ui_error "'git shadow feature start' must run from '$PUBLIC_BASE_BRANCH' or '${PUBLIC_BASE_BRANCH}${LOCAL_SUFFIX}' (current: '$CURRENT_BRANCH')."
    exit 1
  fi

  # Current branch is the public base: ensure its local base exists and sync it.
  PUBLIC_BASE="$CURRENT_BRANCH"
  LOCAL_BASE="${CURRENT_BRANCH}${LOCAL_SUFFIX}"

  if ! branch_exists "$PUBLIC_BASE"; then
    ui_error "Public base branch does not exist: $PUBLIC_BASE"
    exit 1
  fi

  if ! branch_exists "$LOCAL_BASE"; then
    ui_info "Creating local base '$LOCAL_BASE' from '$PUBLIC_BASE'."
    git branch "$LOCAL_BASE" "$PUBLIC_BASE"
  fi

  _feature_start_noarg_body() {
    checkout_branch_verified "$LOCAL_BASE" || return 1
    "$TOOLKIT_ROOT/commands/base/sync.sh"
  }

  if ! patches_transaction _feature_start_noarg_body; then
    exit 1
  fi
  ui_ok "Switched to local base '$LOCAL_BASE'."
  exit 0
fi

# ---------------------------------------------------------------------------
# Argument provided: standard feature creation
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: git shadow feature start [<name> [--onto <parent>] [--worktree|--worktree-dir <path>]]
EOF
}

FEATURE_NAME=""
WANT_WORKTREE=0
WORKTREE_DIR_ARG=""
ONTO_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree)
      WANT_WORKTREE=1
      ;;
    --onto)
      shift
      if [[ $# -eq 0 || -z "$1" ]]; then
        ui_error "--onto requires a parent branch name."
        usage
        exit 1
      fi
      ONTO_ARG="$1"
      ;;
    --worktree-dir)
      shift
      if [[ $# -eq 0 || -z "$1" ]]; then
        ui_error "--worktree-dir requires a non-empty path."
        usage
        exit 1
      fi
      WORKTREE_DIR_ARG="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      ui_error "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -n "$FEATURE_NAME" ]]; then
        ui_error "Unexpected argument: $1"
        usage
        exit 1
      fi
      FEATURE_NAME="$1"
      ;;
  esac
  shift
done

if [[ "$WANT_WORKTREE" -eq 1 && -n "$WORKTREE_DIR_ARG" ]]; then
  ui_error "--worktree and --worktree-dir are mutually exclusive."
  exit 1
fi

if [[ -z "$FEATURE_NAME" ]]; then
  ui_error "Missing feature name."
  usage
  exit 1
fi

USE_WORKTREE=0
if [[ "$WANT_WORKTREE" -eq 1 || -n "$WORKTREE_DIR_ARG" ]]; then
  USE_WORKTREE=1
fi

PUBLIC_FEATURE="$FEATURE_NAME"
LOCAL_FEATURE="${FEATURE_NAME}${LOCAL_SUFFIX}"

# Validate branch name before doing any git operations
if ! git check-ref-format --branch "$FEATURE_NAME" >/dev/null 2>&1; then
  ui_error "Invalid branch name: '$FEATURE_NAME'"
  exit 1
fi

enter_project '.'
patches_require_no_paused_op
ensure_clean_repo

CURRENT_BRANCH="$(current_branch)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  ui_error "Unable to determine current branch."
  exit 1
fi

# Resolve the stacked parent: explicit --onto wins from any checkout; an
# invoking feature @local implies stacking on its pair. Anything else
# must run from the base pair.
PARENT_PUBLIC=""
if [[ -n "$ONTO_ARG" ]]; then
  PARENT_PUBLIC="$(public_branch_from_any "$ONTO_ARG")"
elif [[ "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ &&
        "$CURRENT_BRANCH" != "${PUBLIC_BASE_BRANCH}${LOCAL_SUFFIX}" ]]; then
  PARENT_PUBLIC="$(public_branch_from_any "$CURRENT_BRANCH")"
elif [[ "$CURRENT_BRANCH" != "$PUBLIC_BASE_BRANCH" &&
        "$CURRENT_BRANCH" != "${PUBLIC_BASE_BRANCH}${LOCAL_SUFFIX}" ]]; then
  ui_error "'git shadow feature start' must run from '$PUBLIC_BASE_BRANCH', '${PUBLIC_BASE_BRANCH}${LOCAL_SUFFIX}', or a feature '${LOCAL_SUFFIX}' branch — or pass '--onto' (current: '$CURRENT_BRANCH')."
  exit 1
fi

if [[ -n "$PARENT_PUBLIC" ]]; then
  if [[ "$PARENT_PUBLIC" == "$FEATURE_NAME" ]]; then
    ui_error "Cannot stack '$FEATURE_NAME' on itself."
    exit 1
  fi
  if [[ "$PARENT_PUBLIC" == "$PUBLIC_BASE_BRANCH" ]]; then
    ui_error "Cannot stack onto the base pair '$PUBLIC_BASE_BRANCH' — run 'git shadow feature start $FEATURE_NAME' from a base checkout instead."
    exit 1
  fi
  if ! branch_exists "$PARENT_PUBLIC" || ! branch_exists "${PARENT_PUBLIC}${LOCAL_SUFFIX}"; then
    ui_error "Stack parent pair does not exist: '$PARENT_PUBLIC' (needs both '$PARENT_PUBLIC' and '${PARENT_PUBLIC}${LOCAL_SUFFIX}')."
    exit 1
  fi
  stack_validate_edge "$LOCAL_FEATURE" "$PARENT_PUBLIC" || exit 1
fi

# Resolve and validate the worktree target before any mutation.
WORKTREE_PATH=""
if [[ "$USE_WORKTREE" -eq 1 ]]; then
  if ! worktree_supported; then
    ui_error "Feature worktrees require git >= 2.17 (git worktree remove)."
    exit 1
  fi
  if [[ -n "$WORKTREE_DIR_ARG" ]]; then
    WORKTREE_PATH="$WORKTREE_DIR_ARG"
  else
    WORKTREE_PATH="$(worktree_path_for "$FEATURE_NAME")" || exit 1
  fi
  worktree_validate_path "$WORKTREE_PATH" "$LOCAL_FEATURE" || exit 1
fi

if [[ -n "$PARENT_PUBLIC" ]]; then
  # Stacked mode derives the child from the parent's heads — no base
  # sync and no base checkout; the base pair may be worktree-held.
  PUBLIC_CP="$(git rev-parse "$PARENT_PUBLIC")"
  LOCAL_CP="$(git rev-parse "${PARENT_PUBLIC}${LOCAL_SUFFIX}")"
  CP_SOURCE="$PARENT_PUBLIC"
else
  PUBLIC_BASE="$PUBLIC_BASE_BRANCH"
  LOCAL_BASE="${PUBLIC_BASE_BRANCH}${LOCAL_SUFFIX}"

  if ! branch_exists "$PUBLIC_BASE"; then
    ui_error "Public base branch does not exist: $PUBLIC_BASE"
    exit 1
  fi

  if ! branch_exists "$LOCAL_BASE"; then
    ui_info "Local base branch '$LOCAL_BASE' not found, creating from '$PUBLIC_BASE'."
    git branch "$LOCAL_BASE" "$PUBLIC_BASE"
  fi

  # Run base sync from the local base.
  _feature_start_base_body() {
    checkout_branch_verified "$LOCAL_BASE" || return 1
    "$TOOLKIT_ROOT/commands/base/sync.sh"
  }

  patches_transaction _feature_start_base_body

  # The latest checkpoint on the local base is the branch point.
  LATEST_CP="$(checkpoint_latest "$LOCAL_BASE")"
  if [[ -z "$LATEST_CP" ]]; then
    ui_error "No checkpoint found on local base '$LOCAL_BASE' after sync."
    exit 1
  fi

  read -r PUBLIC_CP LOCAL_CP <<< "$(checkpoint_parse "$LATEST_CP")"
  CP_SOURCE="$PUBLIC_BASE"
fi

if branch_exists "$PUBLIC_FEATURE"; then
  ui_error "Branch already exists: $PUBLIC_FEATURE"
  exit 1
fi
if branch_exists "$LOCAL_FEATURE"; then
  ui_error "Branch already exists: $LOCAL_FEATURE"
  exit 1
fi

ui_git "Creating public feature branch '$PUBLIC_FEATURE' from '$CP_SOURCE'"
git branch "$PUBLIC_FEATURE" "$PUBLIC_CP"

ui_shadow "Creating local feature branch '$LOCAL_FEATURE' from '${CP_SOURCE}${LOCAL_SUFFIX}'"
git branch "$LOCAL_FEATURE" "$LOCAL_CP"

# Record the stack parent before any other mutation writes history; a
# failed worktree path deletes both branches and the config with them.
if [[ -n "$PARENT_PUBLIC" ]]; then
  git config "branch.${LOCAL_FEATURE}.shadow-parent" "$PARENT_PUBLIC"
fi

_feature_start_feature_body() {
  if [[ "$USE_WORKTREE" -eq 1 ]]; then
    # Write the initial checkpoint onto the local feature without checking it
    # out in the invoking checkout — the worktree add below checks it out
    # there instead.
    ui_shadow "Adding initial checkpoint to '$LOCAL_FEATURE'"
    _cp_summary="$(checkpoint_summary "$PUBLIC_CP" "$LOCAL_CP")"
    _new_cp="$(env GIT_SHADOW=1 git commit-tree \
      "$(git rev-parse "$LOCAL_FEATURE^{tree}")" -p "$LOCAL_FEATURE" -m "$_cp_summary")"
    git update-ref "refs/heads/$LOCAL_FEATURE" "$_new_cp"

    if ! worktree_add "$LOCAL_FEATURE" "$WORKTREE_PATH"; then
      ui_error "Failed to create the worktree for '$LOCAL_FEATURE'."
      # worktree_add can fail after `git worktree add` succeeded, leaving a
      # registered worktree whose directory still exists. `git worktree
      # prune` does not clear that state and `git branch -D` refuses while
      # the branch is checked out there, so force-remove it first.
      worktree_remove "$WORKTREE_PATH" --force 2>/dev/null || true
      if ! git branch -D "$LOCAL_FEATURE" >/dev/null 2>&1; then
        ui_error "Leftover worktree at '$WORKTREE_PATH' and branch '$LOCAL_FEATURE'."
        ui_info  "Recover with: git worktree remove --force '$WORKTREE_PATH' && git branch -D '$LOCAL_FEATURE' '$PUBLIC_FEATURE'"
        return 1
      fi
      git branch -D "$PUBLIC_FEATURE" >/dev/null 2>&1 || true
      ui_info  "Rolled back '$PUBLIC_FEATURE' and '$LOCAL_FEATURE'."
      return 1
    fi
    _wt_abs="$(abs_path_m "$WORKTREE_PATH")"
  else
    ui_shadow "Switching to local working branch '$LOCAL_FEATURE'"
    checkout_branch_verified "$LOCAL_FEATURE" || return 1

    ui_shadow "Adding initial checkpoint to '$LOCAL_FEATURE'"
    _new_checkpoint="$(checkpoint_create "$PUBLIC_CP" "$LOCAL_CP")"
  fi
  return 0
}

if ! patches_transaction _feature_start_feature_body; then
  exit 1
fi

"$TOOLKIT_ROOT/commands/install-hooks.sh"

if [[ "$USE_WORKTREE" -eq 1 ]]; then
  ui_ok "Created '$PUBLIC_FEATURE' and '$LOCAL_FEATURE' with worktree at '$_wt_abs'."
  ui_info "Work in: cd '$_wt_abs'"
  # Apply any local patch sidecars that were inherited from the base.
  git -C "$_wt_abs" shadow local apply >/dev/null 2>&1 || true
else
  ui_ok "Created '$PUBLIC_FEATURE' and '$LOCAL_FEATURE'."
fi
