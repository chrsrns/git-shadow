#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/finish.sh
# Purpose: finalize a feature in the diff-sync model.
#
# Usage: git shadow feature finish [--no-pull] [--keep-branches]
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

NO_PULL=0
KEEP_BRANCHES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull)      NO_PULL=1      ;;
    --keep-branches) KEEP_BRANCHES=1 ;;
    *)
      ui_error "Unknown argument: $1"
      echo "Usage: git shadow feature finish [--no-pull] [--keep-branches]" >&2
      exit 1
      ;;
  esac
  shift
done

enter_project '.'
ensure_clean_repo

CURRENT_BRANCH="$(current_branch)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  ui_error "Unable to determine current branch."
  exit 1
fi

if [[ ! "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
  ui_error "feature finish must be run from a branch ending with '${LOCAL_SUFFIX}'."
  exit 1
fi

FEATURE_PUBLIC_BRANCH="$(public_branch_from_any "$CURRENT_BRANCH")"
FEATURE_LOCAL_BRANCH="$CURRENT_BRANCH"
PUBLIC_BASE="$PUBLIC_BASE_BRANCH"
LOCAL_BASE="${PUBLIC_BASE}${LOCAL_SUFFIX}"

if [[ "$FEATURE_PUBLIC_BRANCH" == "$PUBLIC_BASE" || "$FEATURE_LOCAL_BRANCH" == "$LOCAL_BASE" ]]; then
  ui_error "This command must be run from a feature branch, not from the base."
  exit 1
fi

for branch in "$FEATURE_PUBLIC_BRANCH" "$FEATURE_LOCAL_BRANCH" "$PUBLIC_BASE" "$LOCAL_BASE"; do
  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    ui_error "Branch does not exist locally: $branch"
    exit 1
  fi
done

ui_shadow "Finalizing feature '$FEATURE_PUBLIC_BRANCH'"
ui_git    "   Public base   : $PUBLIC_BASE"
ui_shadow "   Local base    : $LOCAL_BASE"

# ---------------------------------------------------------------------------
# Pull / refresh the public base
# ---------------------------------------------------------------------------
if [[ "$NO_PULL" -eq 0 ]]; then
  ui_git "Pulling latest changes for '$PUBLIC_BASE'"
  git checkout -q "$PUBLIC_BASE" >/dev/null 2>&1
  if ! git pull >/dev/null 2>&1; then
    ui_warn "Pull failed for '$PUBLIC_BASE'; continuing with local state."
  fi
fi

PUBLIC_BASE_HEAD="$(git rev-parse "$PUBLIC_BASE")"

# Verify the public feature branch has been merged into the public base.
if ! git merge-base --is-ancestor "$FEATURE_PUBLIC_BRANCH" "$PUBLIC_BASE"; then
  ui_error "Feature '$FEATURE_PUBLIC_BRANCH' is not merged into '$PUBLIC_BASE'. Merge it first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Apply the public base net diff to the local base.
# ---------------------------------------------------------------------------
ui_shadow "Checkout '$LOCAL_BASE'"
git checkout -q "$LOCAL_BASE" >/dev/null 2>&1

LATEST_CP="$(checkpoint_latest "$LOCAL_BASE")"
if [[ -z "$LATEST_CP" ]]; then
  ui_error "No checkpoint found on '$LOCAL_BASE'. Run 'git shadow base sync' first."
  exit 1
fi

CP_PUBLIC="$(checkpoint_public "$LATEST_CP")"
CP_LOCAL="$(checkpoint_local "$LATEST_CP")"
LOCAL_BASE_BEFORE="$(git rev-parse "$LOCAL_BASE")"

PIDS_BASE=""
if [[ "$CP_PUBLIC" != "$PUBLIC_BASE_HEAD" ]]; then
  if ! git merge-base --is-ancestor "$CP_PUBLIC" "$PUBLIC_BASE_HEAD"; then
    ui_error "Public base '$PUBLIC_BASE' has moved non-fast-forward from the local checkpoint."
    exit 1
  fi

  for pid in $(sync_patch_ids "$CP_PUBLIC" "$PUBLIC_BASE_HEAD"); do
    if [[ -n "$pid" ]]; then
      PIDS_BASE="$PIDS_BASE $pid"
    fi
  done
  PIDS_BASE="${PIDS_BASE# }"

  if ! sync_apply_range "$CP_PUBLIC" "$PUBLIC_BASE_HEAD"; then
    git reset --hard "$LOCAL_BASE_BEFORE"
    ui_error "Conflict applying public base net diff to '$LOCAL_BASE'. Resolve and run base sync, then retry."
    exit 1
  fi

  git add -A
  if sync_tree_changed; then
    git commit -q -m "sync $PUBLIC_BASE"
  fi
fi

# ---------------------------------------------------------------------------
# Cherry-pick [MEMORY] commits from the feature's @local branch.
# ---------------------------------------------------------------------------
ui_shadow "Cherry-picking [MEMORY] commits from '$FEATURE_LOCAL_BRANCH'"
MEMORY_SHAS=()
while IFS= read -r sha; do
  [[ -z "$sha" ]] && continue
  subject="$(git log -1 --format='%s' "$sha")"
  if [[ "$subject" == "[MEMORY]"* ]]; then
    MEMORY_SHAS+=("$sha")
  fi
done < <(git rev-list --reverse "$FEATURE_LOCAL_BRANCH")

if [[ ${#MEMORY_SHAS[@]} -gt 0 ]]; then
  LOCAL_BASE_HEAD_AFTER_SYNC="$(git rev-parse "$LOCAL_BASE")"
  for sha in "${MEMORY_SHAS[@]}"; do
    if ! git cherry-pick --quiet "$sha" >/dev/null 2>&1; then
      git cherry-pick --abort >/dev/null 2>&1 || true
      git reset --hard "$LOCAL_BASE_HEAD_AFTER_SYNC"
      KEEP_BRANCHES=1
      ui_error "Conflict cherry-picking [MEMORY] commit $sha. Feature branches preserved. Resolve manually if needed."
      exit 1
    fi
  done
fi

LOCAL_BASE_HEAD="$(git rev-parse "$LOCAL_BASE")"

# ---------------------------------------------------------------------------
# Final checkpoint on the local base
# ---------------------------------------------------------------------------
_new_checkpoint="$(checkpoint_create "$PUBLIC_BASE_HEAD" "$LOCAL_BASE_HEAD" $PIDS_BASE)"

# ---------------------------------------------------------------------------
# Branch cleanup
# ---------------------------------------------------------------------------
if [[ "$KEEP_BRANCHES" -eq 0 ]]; then
  git branch -D "$FEATURE_PUBLIC_BRANCH" >/dev/null 2>&1 || true
  git branch -D "$FEATURE_LOCAL_BRANCH" >/dev/null 2>&1 || true
  ui_info "Deleted feature branches '$FEATURE_PUBLIC_BRANCH' and '$FEATURE_LOCAL_BRANCH'."
fi

ui_ok "Feature finished successfully."
