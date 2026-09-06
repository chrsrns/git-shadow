#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/finish.sh
# Purpose: finalize a feature in the diff-sync model.
#
# Usage: git shadow feature finish [--no-pull] [--keep-branches]
#          [--continue|--abort] [--mark-applied <sha>]
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: git shadow feature finish [--no-pull] [--keep-branches] [--continue|--abort] [--mark-applied <sha>]
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Collect [MEMORY] provenance already recorded on the local base.
finish_collect_applied() {
  APPLIED_MEMORY_SHAS=()
  APPLIED_MEMORY_PIDS=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^git-shadow-source-memory:[[:space:]]*(.+)$ ]]; then
      APPLIED_MEMORY_SHAS+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ ^git-shadow-source-pid:[[:space:]]*(.+)$ ]]; then
      APPLIED_MEMORY_PIDS+=("${BASH_REMATCH[1]}")
    fi
  done < <(git log --grep='^\[MEMORY\]' --format='%b' "$LOCAL_BASE")
}

# Re-anchor and merge .git-shadow/annotations sidecars from a [MEMORY] commit
# onto the current base. The source for re-anchoring is the working-tree file
# (the resolved/applied source), not HEAD.
finish_merge_sidecars() {
  local sha="$1"
  local tmp_dir="$2"
  local status ann_path source_path
  local source_tmp base_ann_tmp feature_ann_tmp new_base_ann new_feature_ann merged_ann

  while IFS=$'\t' read -r status ann_path; do
    [[ -z "$status" ]] && continue
    [[ "$ann_path" == .git-shadow/annotations/* ]] || continue
    source_path="${ann_path#.git-shadow/annotations/}"

    source_tmp="$tmp_dir/source_${source_path////_}"
    base_ann_tmp="$tmp_dir/base_${source_path////_}"
    feature_ann_tmp="$tmp_dir/feature_${source_path////_}"
    new_base_ann="$tmp_dir/new_base_${source_path////_}"
    new_feature_ann="$tmp_dir/new_feature_${source_path////_}"
    merged_ann="$tmp_dir/merged_${source_path////_}"

    if [[ -e "$source_path" ]]; then
      cp "$source_path" "$source_tmp"

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
}

# Stage and commit the [MEMORY] replay, recording the source SHA and patch-id.
finish_commit_memory() {
  local sha="$1"
  local subject memory_pid
  subject="$(git log -1 --format='%s' "$sha")"
  memory_pid="$(patch_id_for "$sha")"

  git add -A -- . ':(exclude).git-shadow.env'
  if [[ -d .git-shadow/annotations ]]; then
    git add -f .git-shadow/annotations/
  fi

  local -a commit_args=(-m "$subject" -m "git-shadow-source-memory: $sha")
  if [[ -n "$memory_pid" ]]; then
    commit_args+=(-m "git-shadow-source-pid: $memory_pid")
  fi
  env GIT_SHADOW=1 git commit --allow-empty "${commit_args[@]}"
}

# Replay the given [MEMORY] SHAs onto the local base, pausing on conflict.
# Uses APPLIED_MEMORY_SHAS / APPLIED_MEMORY_PIDS for idempotency.
finish_memory_replay() {
  local -a shas=("$@")
  FINISH_TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$FINISH_TMP_DIR"' 0

  local i sha subject skip applied_sha applied_pid
  local -a remaining
  for i in "${!shas[@]}"; do
    sha="${shas[$i]}"
    skip=0
    for applied_sha in "${APPLIED_MEMORY_SHAS[@]}"; do
      if [[ "$applied_sha" == "$sha" ]]; then
        skip=1
        break
      fi
    done
    if [[ "$skip" -eq 0 ]]; then
      local pid
      pid="$(patch_id_for "$sha")"
      for applied_pid in "${APPLIED_MEMORY_PIDS[@]}"; do
        if [[ "$applied_pid" == "$pid" ]]; then
          skip=1
          break
        fi
      done
    fi
    if [[ "$skip" -eq 1 ]]; then
      continue
    fi

    subject="$(git log -1 --format='%s' "$sha")"
    remaining=("${shas[@]:$((i+1))}")

    # Write state before the apply so --continue is self-contained.
    finish_save_state \
      "$FEATURE_PUBLIC_BRANCH" "$FEATURE_LOCAL_BRANCH" "$LOCAL_BASE" \
      "$PRE_FINISH_HEAD" "memory-replay" "$sha" \
      "${remaining[*]}" "$RANGE_START" "$RANGE_END" "$PIDS_BASE"

    if ! git diff "$sha^" "$sha" -- . ':!.git-shadow/annotations/' | git apply --3way --allow-empty; then
      local conflicted
      conflicted="$(git ls-files -u | awk '{print $4}' | sort -u)"
      ui_error "Conflict applying [MEMORY] commit $sha to '$LOCAL_BASE'."
      [[ -n "$conflicted" ]] && ui_error "Conflicting paths: $(printf '%s\n' "$conflicted" | paste -sd' ' -)"
      ui_info "Resolve the conflicts, then run: git shadow feature finish --continue"
      ui_info "Or run: git shadow feature finish --abort"
      return 1
    fi

    finish_merge_sidecars "$sha" "$FINISH_TMP_DIR"
    finish_commit_memory "$sha"
    finish_clear_state

    APPLIED_MEMORY_SHAS+=("$sha")
    local memory_pid
    memory_pid="$(patch_id_for "$sha")"
    [[ -n "$memory_pid" ]] && APPLIED_MEMORY_PIDS+=("$memory_pid")
  done
  return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
NO_PULL=0
KEEP_BRANCHES=0
CONTINUE=0
ABORT=0
MARK_APPLIED=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull)       NO_PULL=1 ;;
    --keep-branches) KEEP_BRANCHES=1 ;;
    --continue)      CONTINUE=1 ;;
    --abort)         ABORT=1 ;;
    --mark-applied)
      shift
      if [[ $# -eq 0 ]]; then
        ui_error "--mark-applied requires a SHA."
        usage
        exit 1
      fi
      MARK_APPLIED="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ui_error "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ $((CONTINUE + ABORT)) -gt 1 || ( -n "$MARK_APPLIED" && $((CONTINUE + ABORT)) -gt 0 ) ]]; then
  ui_error "--continue, --abort, and --mark-applied are mutually exclusive."
  exit 1
fi

enter_project '.'

# V88: all feature finish modes refuse while a git-shadow sync is in progress.
if [[ -f "$(sync_state_file)" ]]; then
  ui_error "A git-shadow sync is in progress. Resolve it before running 'git shadow feature finish'."
  exit 1
fi

# ---------------------------------------------------------------------------
# --abort
# ---------------------------------------------------------------------------
if [[ "$ABORT" -eq 1 ]]; then
  if ! finish_load_state; then
    ui_error "No finish in progress."
    exit 1
  fi
  if [[ "$(current_branch)" != "$FINISH_LOCAL_BASE" ]]; then
    git checkout -q "$FINISH_LOCAL_BASE" >/dev/null 2>&1 || {
      ui_error "Cannot checkout '$FINISH_LOCAL_BASE'."
      exit 1
    }
  fi
  conflicted="$(git ls-files -u | awk '{print $4}' | sort -u)"
  git reset --hard "$FINISH_PRE_FINISH_HEAD"
  finish_clear_state
  ui_ok "Feature finish aborted. Restored '$FINISH_LOCAL_BASE' to pre-finish state."
  if [[ -n "$conflicted" ]]; then
    ui_info "Discarded conflicting paths: $(printf '%s\n' "$conflicted" | paste -sd' ' -)"
  fi
  ui_info "Restart with 'git shadow feature finish'; the paused state is cleared (--continue/--abort no longer apply)."
  exit 0
fi

# ---------------------------------------------------------------------------
# --mark-applied
# ---------------------------------------------------------------------------
if [[ -n "$MARK_APPLIED" ]]; then
  target_sha="$MARK_APPLIED"
  if ! git rev-parse --verify --quiet "$target_sha" >/dev/null; then
    ui_error "Invalid commit SHA: $target_sha"
    exit 1
  fi

  if finish_load_state; then
    local_base="$FINISH_LOCAL_BASE"
  else
    current="$(current_branch)"
    if [[ -z "$current" || ! "$current" =~ ${LOCAL_SUFFIX}$ ]]; then
      ui_error "feature finish --mark-applied must be run from a @local branch or while a finish is paused."
      exit 1
    fi
    public_base="$(public_branch_from_any "$current")"
    local_base="${PUBLIC_BASE_BRANCH}${LOCAL_SUFFIX}"
    if [[ "$public_base" == "$PUBLIC_BASE_BRANCH" ]]; then
      ui_error "feature finish --mark-applied cannot be run on the local base."
      exit 1
    fi
    ensure_clean_repo
  fi

  if [[ "$(current_branch)" != "$local_base" ]]; then
    git checkout -q "$local_base" >/dev/null 2>&1 || {
      ui_error "Cannot checkout '$local_base'."
      exit 1
    }
  fi

  subject="$(git log -1 --format='%s' "$target_sha")"
  pid="$(patch_id_for "$target_sha")"
  tree="$(git rev-parse "$local_base^{tree}")"
  parent="$(git rev-parse "$local_base")"

  commit_args=(-m "$subject" -m "git-shadow-source-memory: $target_sha")
  if [[ -n "$pid" ]]; then
    commit_args+=(-m "git-shadow-source-pid: $pid")
  fi
  new_sha="$(env GIT_SHADOW=1 git commit-tree "$tree" -p "$parent" "${commit_args[@]}")"
  git update-ref "refs/heads/$local_base" "$new_sha"

  if finish_load_state; then
    remaining=()
    for s in $FINISH_REMAINING_SHAS; do
      [[ "$s" != "$target_sha" ]] && remaining+=("$s")
    done
    conflicted="$FINISH_CONFLICTED_SHA"
    [[ "$conflicted" == "$target_sha" ]] && conflicted=""
    finish_save_state \
      "$FINISH_FEATURE_PUBLIC" "$FINISH_FEATURE_LOCAL" "$local_base" \
      "$new_sha" "$FINISH_PHASE" "$conflicted" \
      "${remaining[*]}" "$FINISH_RANGE_START" "$FINISH_RANGE_END" "$FINISH_PIDS"
    ui_ok "Recorded provenance for $target_sha and updated paused finish state."
  else
    ui_ok "Recorded provenance for $target_sha on '$local_base'."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --continue
# ---------------------------------------------------------------------------
if [[ "$CONTINUE" -eq 1 ]]; then
  if ! finish_load_state; then
    ui_error "No finish in progress."
    exit 1
  fi
  if [[ "$(current_branch)" != "$FINISH_LOCAL_BASE" ]]; then
    ui_error "finish --continue must be run on '$FINISH_LOCAL_BASE' (current: $(current_branch))."
    exit 1
  fi
  if sync_has_conflicts; then
    conflicted="$(git ls-files -u | awk '{print $4}' | sort -u | paste -sd' ' -)"
    ui_error "Working tree still has unresolved conflicts: $conflicted"
    exit 1
  fi

  FEATURE_PUBLIC_BRANCH="$FINISH_FEATURE_PUBLIC"
  FEATURE_LOCAL_BRANCH="$FINISH_FEATURE_LOCAL"
  LOCAL_BASE="$FINISH_LOCAL_BASE"
  PUBLIC_BASE="$(public_branch_from_any "$LOCAL_BASE")"
  PUBLIC_BASE_HEAD="$FINISH_RANGE_END"
  PRE_FINISH_HEAD="$FINISH_PRE_FINISH_HEAD"
  RANGE_START="$FINISH_RANGE_START"
  RANGE_END="$FINISH_RANGE_END"
  PIDS_BASE="$FINISH_PIDS"

  if [[ "$FINISH_PHASE" == "base-diff" ]]; then
    git add -A -- . ':(exclude).git-shadow.env'
    if sync_tree_changed; then
      sync_commit "$LOCAL_BASE" "$PUBLIC_BASE" "$RANGE_START" "$RANGE_END" "$FEATURE_PUBLIC_BRANCH"
    fi
    finish_clear_state
    MEMORY_SHAS=($FINISH_REMAINING_SHAS)
  elif [[ "$FINISH_PHASE" == "memory-replay" ]]; then
    # The conflicted [MEMORY] non-sidecar is already resolved in the working
    # tree. Re-run the sidecar merge from the resolved source and commit it,
    # unless --mark-applied has already recorded it (V102).
    finish_collect_applied
    if [[ -n "$FINISH_CONFLICTED_SHA" ]]; then
      FINISH_TMP_DIR="$(mktemp -d)"
      trap 'rm -rf "$FINISH_TMP_DIR"' 0
      finish_merge_sidecars "$FINISH_CONFLICTED_SHA" "$FINISH_TMP_DIR"
      finish_commit_memory "$FINISH_CONFLICTED_SHA"
      APPLIED_MEMORY_SHAS+=("$FINISH_CONFLICTED_SHA")
      pid="$(patch_id_for "$FINISH_CONFLICTED_SHA")"
      [[ -n "$pid" ]] && APPLIED_MEMORY_PIDS+=("$pid")
    fi
    finish_clear_state
    MEMORY_SHAS=($FINISH_REMAINING_SHAS)
  else
    ui_error "Unknown finish phase: $FINISH_PHASE"
    exit 1
  fi

  finish_collect_applied
  if [[ ${#MEMORY_SHAS[@]} -gt 0 ]]; then
    if ! finish_memory_replay "${MEMORY_SHAS[@]}"; then
      exit 1
    fi
  fi

  if ! _new_checkpoint="$(sync_reanchor_and_checkpoint "$LOCAL_BASE" "$PUBLIC_BASE_HEAD" $PIDS_BASE)"; then
    exit 1
  fi

  if [[ "$KEEP_BRANCHES" -eq 0 ]]; then
    git branch -D "$FEATURE_PUBLIC_BRANCH" >/dev/null 2>&1 || true
    git branch -D "$FEATURE_LOCAL_BRANCH" >/dev/null 2>&1 || true
    ui_info "Deleted feature branches '$FEATURE_PUBLIC_BRANCH' and '$FEATURE_LOCAL_BRANCH'."
  fi
  ui_ok "Feature finished successfully."
  exit 0
fi

# ---------------------------------------------------------------------------
# Normal start
# ---------------------------------------------------------------------------
if finish_state_active; then
  ui_error "A feature finish is already in progress. Use --continue or --abort."
  exit 1
fi

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
# Compute the feature [MEMORY] list before the base diff.
# ---------------------------------------------------------------------------
MERGE_BASE="$(git merge-base "$FEATURE_LOCAL_BRANCH" "$LOCAL_BASE")"
MEMORY_SHAS=()
while IFS= read -r sha; do
  [[ -z "$sha" ]] && continue
  subject="$(git log -1 --format='%s' "$sha")"
  if [[ "$subject" == "[MEMORY]"* ]]; then
    MEMORY_SHAS+=("$sha")
  fi
done < <(git rev-list --reverse "${MERGE_BASE}..$FEATURE_LOCAL_BRANCH")

finish_collect_applied
MEMORY_SHAS_UNIQUE=()
for sha in "${MEMORY_SHAS[@]}"; do
  skip=0
  for applied_sha in "${APPLIED_MEMORY_SHAS[@]}"; do
    if [[ "$applied_sha" == "$sha" ]]; then
      skip=1
      break
    fi
  done
  if [[ "$skip" -eq 0 ]]; then
    pid="$(patch_id_for "$sha")"
    for applied_pid in "${APPLIED_MEMORY_PIDS[@]}"; do
      if [[ "$applied_pid" == "$pid" ]]; then
        skip=1
        break
      fi
    done
  fi
  if [[ "$skip" -eq 0 ]]; then
    MEMORY_SHAS_UNIQUE+=("$sha")
  fi
done
MEMORY_SHAS=("${MEMORY_SHAS_UNIQUE[@]}")

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
PRE_FINISH_HEAD="$(git rev-parse "$LOCAL_BASE")"
RANGE_START="$CP_PUBLIC"
RANGE_END="$PUBLIC_BASE_HEAD"
PIDS_BASE=""

if [[ "$CP_PUBLIC" != "$PUBLIC_BASE_HEAD" ]]; then
  if ! git merge-base --is-ancestor "$CP_PUBLIC" "$PUBLIC_BASE_HEAD"; then
    ui_error "Public base '$PUBLIC_BASE' has moved non-fast-forward from the local checkpoint."
    exit 1
  fi

  # V14: skip the base net diff when the local base already contains the public
  # base tree (only local-only additions differ).
  if git diff-tree --no-renames -r "$PUBLIC_BASE_HEAD" "$PRE_FINISH_HEAD" | awk '$5 != "A" {exit 1}'; then
    :
  else
    PIDS_BASE="$(sync_patch_ids "$CP_PUBLIC" "$PUBLIC_BASE_HEAD" | tr '\n' ' ' | sed 's/ $//')"
    finish_save_state \
      "$FEATURE_PUBLIC_BRANCH" "$FEATURE_LOCAL_BRANCH" "$LOCAL_BASE" \
      "$PRE_FINISH_HEAD" "base-diff" "" \
      "${MEMORY_SHAS[*]}" "$RANGE_START" "$RANGE_END" "$PIDS_BASE"

    if ! sync_apply_and_commit "$LOCAL_BASE" "$PUBLIC_BASE" "$CP_PUBLIC" "$PUBLIC_BASE_HEAD" "$FEATURE_PUBLIC_BRANCH" >/dev/null; then
      conflicted="$(git ls-files -u | awk '{print $4}' | sort -u)"
      ui_error "Conflict applying public base net diff to '$LOCAL_BASE'."
      [[ -n "$conflicted" ]] && ui_error "Conflicting paths: $(printf '%s\n' "$conflicted" | paste -sd' ' -)"
      ui_info "Resolve the conflicts, then run: git shadow feature finish --continue"
      ui_info "Or run: git shadow feature finish --abort"
      exit 1
    fi
    finish_clear_state
  fi
fi

# ---------------------------------------------------------------------------
# Replay [MEMORY] commits from the feature's @local branch.
# ---------------------------------------------------------------------------
ui_shadow "Replaying [MEMORY] commits from '$FEATURE_LOCAL_BRANCH'"
if [[ ${#MEMORY_SHAS[@]} -gt 0 ]]; then
  if ! finish_memory_replay "${MEMORY_SHAS[@]}"; then
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Re-anchor any base sidecars not touched by the feature, then checkpoint.
# ---------------------------------------------------------------------------
if ! _new_checkpoint="$(sync_reanchor_and_checkpoint "$LOCAL_BASE" "$PUBLIC_BASE_HEAD" $PIDS_BASE)"; then
  exit 1
fi

# ---------------------------------------------------------------------------
# Branch cleanup
# ---------------------------------------------------------------------------
if [[ "$KEEP_BRANCHES" -eq 0 ]]; then
  git branch -D "$FEATURE_PUBLIC_BRANCH" >/dev/null 2>&1 || true
  git branch -D "$FEATURE_LOCAL_BRANCH" >/dev/null 2>&1 || true
  ui_info "Deleted feature branches '$FEATURE_PUBLIC_BRANCH' and '$FEATURE_LOCAL_BRANCH'."
fi

ui_ok "Feature finished successfully."
