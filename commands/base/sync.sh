#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: base/sync.sh
# Purpose: sync the local base branch with the public base branch.
#
# Usage: git shadow base sync [--recover] [--continue|--abort]
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

usage() {
  cat <<EOF
Usage: git shadow base sync [--recover] [--continue|--abort]
EOF
}

RECOVER=0
CONTINUE=0
ABORT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recover) RECOVER=1 ;;
    --continue) CONTINUE=1 ;;
    --abort) ABORT=1 ;;
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
  if [[ "$SYNC_MODE" != "base" ]]; then
    ui_error "A sync is in progress, but it is not a base sync (mode=$SYNC_MODE)."
    exit 1
  fi
  git checkout -q "$SYNC_LOCAL_BRANCH" || true
  git reset --hard "$SYNC_LOCAL_HEAD"
  sync_clear_state
  ui_ok "Base sync aborted."
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
  if [[ "$SYNC_MODE" != "base" ]]; then
    ui_error "A sync is in progress, but it is not a base sync (mode=$SYNC_MODE)."
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

  # The resolved tree is the post-sync tree on the local branch.
  git commit -q -m "sync $SYNC_PUBLIC_BRANCH"

  NEW_LOCAL_HEAD="$(git rev-parse "$SYNC_LOCAL_BRANCH")"
  _new_checkpoint="$(checkpoint_create "$SYNC_TARGET_PUBLIC" "$NEW_LOCAL_HEAD" $SYNC_PIDS)"
  sync_clear_state
  ui_ok "Base sync continued."
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
  ui_error "base sync must be run from a branch ending with '${LOCAL_SUFFIX}' (got '$LOCAL_BRANCH')."
  exit 1
fi

PUBLIC_BRANCH="$(public_branch_from_any "$LOCAL_BRANCH")"

if ! git show-ref --verify --quiet "refs/heads/$PUBLIC_BRANCH"; then
  ui_error "Public base branch does not exist: $PUBLIC_BRANCH"
  exit 1
fi

# ---------------------------------------------------------------------------
# Normal flow
# ---------------------------------------------------------------------------
LATEST_CP="$(checkpoint_latest "$LOCAL_BRANCH")"
if [[ -z "$LATEST_CP" ]]; then
  # No checkpoint yet: create an initial one.
  PUBLIC_HEAD="$(git rev-parse "$PUBLIC_BRANCH")"
  LOCAL_HEAD="$(git rev-parse "$LOCAL_BRANCH")"
  _new_checkpoint="$(checkpoint_create "$PUBLIC_HEAD" "$LOCAL_HEAD")"
  ui_ok "Created initial checkpoint for '$LOCAL_BRANCH'."
  exit 0
fi

CP_PUBLIC="$(checkpoint_public "$LATEST_CP")"
CP_LOCAL="$(checkpoint_local "$LATEST_CP")"
CP_PIDS="$(checkpoint_pids "$LATEST_CP")"

PUBLIC_HEAD="$(git rev-parse "$PUBLIC_BRANCH")"
LOCAL_HEAD="$(git rev-parse "$LOCAL_BRANCH")"

if [[ "$CP_PUBLIC" == "$PUBLIC_HEAD" ]]; then
  _new_checkpoint="$(checkpoint_create "$PUBLIC_HEAD" "$LOCAL_HEAD" $CP_PIDS)"
  ui_ok "Base '$LOCAL_BRANCH' is already up to date."
  exit 0
fi

# If the checkpointed public SHA is not an ancestor of current public HEAD,
# either try --recover or fail.
if ! git merge-base --is-ancestor "$CP_PUBLIC" "$PUBLIC_HEAD"; then
  if [[ $RECOVER -eq 0 ]]; then
    ui_error "Public branch '$PUBLIC_BRANCH' has moved non-fast-forward from the checkpoint. Use --recover or re-anchor."
    exit 1
  fi
  ui_warn "Attempting to recover base sync from patch-id list."
  PIDS_FILE="$(mktemp)"
  trap 'rm -f "$PIDS_FILE"' EXIT
  printf '%s\n' $CP_PIDS | tr ' ' '\n' | grep -v '^$' > "$PIDS_FILE" || true
  if ! NEW_ANCESTOR="$(sync_recover_ancestor "$PUBLIC_HEAD" "$PIDS_FILE")"; then
    ui_error "Unable to recover: no checkpointed patch-id found in the new public history. Run 'git shadow re-anchor $LOCAL_BRANCH'."
    exit 1
  fi
  if [[ "$NEW_ANCESTOR" == "$PUBLIC_HEAD" ]]; then
    # No net diff to apply, just move the checkpoint forward.
    _new_checkpoint="$(checkpoint_create "$PUBLIC_HEAD" "$LOCAL_HEAD" $CP_PIDS)"
    ui_ok "Base sync recovered (no net diff to apply)."
    exit 0
  fi
  DIFF_START="$NEW_ANCESTOR"
else
  DIFF_START="$CP_PUBLIC"
fi

# Collect patch-ids of the public commits in the sync range.
PIDS=""
for pid in $(sync_patch_ids "$DIFF_START" "$PUBLIC_HEAD"); do
  if [[ -n "$pid" ]]; then
    PIDS="$PIDS $pid"
  fi
done
PIDS="${PIDS# }"

# Apply net diff to the local branch.
if ! sync_apply_range "$DIFF_START" "$PUBLIC_HEAD"; then
  sync_save_state "base" "$PUBLIC_BRANCH" "$LOCAL_BRANCH" "$CP_PUBLIC" "$CP_LOCAL" "$PUBLIC_HEAD" "$LOCAL_HEAD" "$PIDS"
  ui_error "Conflict applying base net diff. Resolve and run 'git shadow base sync --continue', or '--abort'."
  exit 1
fi

git add -A

# Create a sync commit only when the applied tree differs from the parent.
if sync_tree_changed; then
  git commit -q -m "sync $PUBLIC_BRANCH"
fi

NEW_LOCAL_HEAD="$(git rev-parse "$LOCAL_BRANCH")"
_new_checkpoint="$(checkpoint_create "$PUBLIC_HEAD" "$NEW_LOCAL_HEAD" $PIDS)"
ui_ok "Base '$LOCAL_BRANCH' synced with '$PUBLIC_BRANCH'."
