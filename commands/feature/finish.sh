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

  git add -A -- . ':(exclude).git-shadow.env'
  if sync_tree_changed; then
    sync_commit "$LOCAL_BASE" "$PUBLIC_BASE" "$CP_PUBLIC" "$PUBLIC_BASE_HEAD" "$FEATURE_PUBLIC_BRANCH"
  fi
fi

# ---------------------------------------------------------------------------
# Replay [MEMORY] commits from the feature's @local branch.
# Apply non-sidecar changes with git apply, then merge .git-shadow/annotations
# sidecars by hunk key and re-anchor them to the final base source. Use the
# merge-base with the local base so we do not re-apply base [MEMORY] commits
# that are already on main@local.
# ---------------------------------------------------------------------------
ui_shadow "Replaying [MEMORY] commits from '$FEATURE_LOCAL_BRANCH'"
MEMORY_SHAS=()
MERGE_BASE="$(git merge-base "$FEATURE_LOCAL_BRANCH" "$LOCAL_BASE")"
while IFS= read -r sha; do
  [[ -z "$sha" ]] && continue
  subject="$(git log -1 --format='%s' "$sha")"
  if [[ "$subject" == "[MEMORY]"* ]]; then
    MEMORY_SHAS+=("$sha")
  fi
done < <(git rev-list --reverse "${MERGE_BASE}..$FEATURE_LOCAL_BRANCH")

if [[ ${#MEMORY_SHAS[@]} -gt 0 ]]; then
  LOCAL_BASE_HEAD_AFTER_SYNC="$(git rev-parse "$LOCAL_BASE")"
  FINISH_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$FINISH_TMP_DIR"' 0

  for sha in "${MEMORY_SHAS[@]}"; do
    subject="$(git log -1 --format='%s' "$sha")"

    # Apply everything except .git-shadow/annotations/ sidecars.
    if ! git diff "$sha^" "$sha" -- . ':!.git-shadow/annotations/' | git apply --3way --allow-empty; then
      git reset --hard "$LOCAL_BASE_HEAD_AFTER_SYNC"
      KEEP_BRANCHES=1
      ui_error "Conflict applying [MEMORY] commit $sha to '$LOCAL_BASE'. Feature branches preserved."
      exit 1
    fi

    # Re-anchor and merge sidecars by hunk key.
    while IFS=$'\t' read -r status ann_path; do
      [[ -z "$status" ]] && continue
      [[ "$ann_path" == .git-shadow/annotations/* ]] || continue
      source_path="${ann_path#.git-shadow/annotations/}"

      source_tmp="$FINISH_TMP_DIR/source_${source_path////_}"
      base_ann_tmp="$FINISH_TMP_DIR/base_${source_path////_}"
      feature_ann_tmp="$FINISH_TMP_DIR/feature_${source_path////_}"
      new_base_ann="$FINISH_TMP_DIR/new_base_${source_path////_}"
      new_feature_ann="$FINISH_TMP_DIR/new_feature_${source_path////_}"
      merged_ann="$FINISH_TMP_DIR/merged_${source_path////_}"

      if git show "HEAD:$source_path" > "$source_tmp" 2>/dev/null; then
        # Re-anchor the current base sidecar (if any).
        if git show "HEAD:$ann_path" > "$base_ann_tmp" 2>/dev/null; then
          annotations_reanchor "$source_tmp" "$base_ann_tmp" "$new_base_ann" 2>/dev/null || true
        else
          : > "$new_base_ann"
        fi

        if [[ "$status" != "D" ]]; then
          # Re-anchor the feature sidecar and merge with the base sidecar.
          if git show "$sha:$ann_path" > "$feature_ann_tmp" 2>/dev/null; then
            annotations_reanchor "$source_tmp" "$feature_ann_tmp" "$new_feature_ann" 2>/dev/null || true
            annotations_merge "$new_base_ann" "$new_feature_ann" "$merged_ann" append --warn-differing
            cp "$merged_ann" "$ann_path"
          else
            # Feature sidecar missing: keep the re-anchored base sidecar.
            cp "$new_base_ann" "$ann_path"
          fi
        else
          # Feature deleted its sidecar: keep the re-anchored base sidecar.
          cp "$new_base_ann" "$ann_path"
        fi
      else
        # Source file no longer exists on the base: the sidecar is stale.
        rm -f "$ann_path"
      fi
    done < <(git diff --name-status "$sha^" "$sha" -- .git-shadow/annotations/)

    # Stage and commit the merged [MEMORY] replay.
    git add -A -- . ':(exclude).git-shadow.env'
    git add -f .git-shadow/annotations/
    if ! git diff --cached --quiet; then
      env GIT_SHADOW=1 git commit -m "$subject"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Re-anchor any base sidecars not touched by the feature, then checkpoint.
# ---------------------------------------------------------------------------
annotations_reanchor_all_commit

LOCAL_BASE_HEAD="$(git rev-parse "$LOCAL_BASE")"
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
