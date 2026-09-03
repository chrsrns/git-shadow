#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/sync.sh
# Purpose: sync a @local feature branch with its public counterpart.
#
# Usage: git shadow feature sync [--continue|--abort]
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

usage() {
  cat <<EOF
Usage: git shadow feature sync [--continue|--abort]
EOF
}

CONTINUE=0
ABORT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --continue) CONTINUE=1 ;;
    --abort)    ABORT=1    ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ui_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ $CONTINUE -eq 1 && $ABORT -eq 1 ]]; then
  ui_error "--continue and --abort are mutually exclusive."
  exit 1
fi

enter_project '.'

# ---------------------------------------------------------------------------
# --abort
# ---------------------------------------------------------------------------
if [[ $ABORT -eq 1 ]]; then
  if ! sync_load_state; then
    ui_error "No sync in progress."
    exit 1
  fi
  if [[ "$SYNC_MODE" != "feature" ]]; then
    ui_error "A sync is in progress, but it is not a feature sync (mode=$SYNC_MODE)."
    exit 1
  fi
  git checkout -q "$SYNC_LOCAL_BRANCH" >/dev/null 2>&1 || true
  git reset --hard "$SYNC_LOCAL_HEAD"
  sync_clear_state
  ui_ok "Feature sync aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# --continue
# ---------------------------------------------------------------------------
if [[ $CONTINUE -eq 1 ]]; then
  if ! sync_load_state; then
    ui_error "No sync in progress."
    exit 1
  fi
  if [[ "$SYNC_MODE" != "feature" ]]; then
    ui_error "A sync is in progress, but it is not a feature sync (mode=$SYNC_MODE)."
    exit 1
  fi
  if sync_has_conflicts; then
    ui_error "Working tree still has unresolved conflicts. Resolve them and run --continue."
    exit 1
  fi
  if ! sync_tree_changed; then
    ui_error "No resolved changes to commit. Resolve the conflicts and add them."
    exit 1
  fi

  git commit -q -m "sync $SYNC_PUBLIC_BRANCH"

  NEW_LOCAL_HEAD="$(git rev-parse "$SYNC_LOCAL_BRANCH")"
  _new_checkpoint="$(checkpoint_create "$SYNC_TARGET_PUBLIC" "$NEW_LOCAL_HEAD" $SYNC_PIDS)"
  sync_clear_state
  ui_ok "Feature sync continued."
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate environment for a new sync
# ---------------------------------------------------------------------------
ensure_clean_repo

LOCAL_BRANCH="$(current_branch)"
if [[ -z "$LOCAL_BRANCH" ]]; then
  ui_error "Unable to determine current branch."
  exit 1
fi

if [[ ! "$LOCAL_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
  ui_error "feature sync must be run from a branch ending with '${LOCAL_SUFFIX}'."
  exit 1
fi

# Guard: do not sync the local base branch.
LOCAL_BASE_BRANCH="${PUBLIC_BASE_BRANCH}${LOCAL_SUFFIX}"
if [[ "$LOCAL_BRANCH" == "$LOCAL_BASE_BRANCH" ]]; then
  ui_error "'git shadow feature sync' is for feature shadow branches, not the local base branch '$LOCAL_BASE_BRANCH'."
  exit 1
fi

PUBLIC_BRANCH="$(public_branch_from_any "$LOCAL_BRANCH")"
if ! git show-ref --verify --quiet "refs/heads/$PUBLIC_BRANCH"; then
  ui_error "Public branch does not exist: $PUBLIC_BRANCH"
  exit 1
fi

# ---------------------------------------------------------------------------
# Normal flow
# ---------------------------------------------------------------------------
LATEST_CP="$(checkpoint_latest "$LOCAL_BRANCH")"
if [[ -z "$LATEST_CP" ]]; then
  ui_error "No checkpoint found on '$LOCAL_BRANCH'. Run 'git shadow feature start' or create one."
  exit 1
fi

CP_PUBLIC="$(checkpoint_public "$LATEST_CP")"
CP_LOCAL="$(checkpoint_local "$LATEST_CP")"
CP_PIDS="$(checkpoint_pids "$LATEST_CP")"

PUBLIC_HEAD="$(git rev-parse "$PUBLIC_BRANCH")"
LOCAL_HEAD="$(git rev-parse "$LOCAL_BRANCH")"

if [[ "$CP_PUBLIC" == "$PUBLIC_HEAD" ]]; then
  _new_checkpoint="$(checkpoint_create "$PUBLIC_HEAD" "$LOCAL_HEAD" $CP_PIDS)"
  ui_ok "Feature '$LOCAL_BRANCH' is already up to date."
  exit 0
fi

if ! git merge-base --is-ancestor "$CP_PUBLIC" "$PUBLIC_HEAD"; then
  ui_error "Public branch '$PUBLIC_BRANCH' has moved non-fast-forward from the checkpoint. Run 'git shadow re-anchor $LOCAL_BRANCH'."
  exit 1
fi

# Collect patch-ids of the public commits in the sync range.
PIDS=""
for pid in $(sync_patch_ids "$CP_PUBLIC" "$PUBLIC_HEAD"); do
  if [[ -n "$pid" ]]; then
    PIDS="$PIDS $pid"
  fi
done
PIDS="${PIDS# }"

# Apply net diff to the local branch.
if ! sync_apply_range "$CP_PUBLIC" "$PUBLIC_HEAD"; then
  sync_save_state "feature" "$PUBLIC_BRANCH" "$LOCAL_BRANCH" "$CP_PUBLIC" "$CP_LOCAL" "$PUBLIC_HEAD" "$LOCAL_HEAD" "$PIDS"
  ui_error "Conflict applying feature net diff. Resolve and run 'git shadow feature sync --continue', or '--abort'."
  exit 1
fi

git add -A

if sync_tree_changed; then
  git commit -q -m "sync $PUBLIC_BRANCH"
fi

NEW_LOCAL_HEAD="$(git rev-parse "$LOCAL_BRANCH")"
_new_checkpoint="$(checkpoint_create "$PUBLIC_HEAD" "$NEW_LOCAL_HEAD" $PIDS)"
ui_ok "Feature '$LOCAL_BRANCH' synced with '$PUBLIC_BRANCH'."
