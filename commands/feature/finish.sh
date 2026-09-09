#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/finish.sh
# Purpose: finalize a feature in the diff-sync model.
#
# Usage: git shadow feature finish [<name>] [--no-pull] [--keep-branches]
#          [--keep-worktree] [--continue|--abort] [--mark-applied <sha>]
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: git shadow feature finish [<name>] [--no-pull] [--keep-branches] [--keep-worktree] [--continue|--abort] [--mark-applied <sha>]
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Return 0 when the current checkout is a linked worktree (its .git dir has
# a commondir file pointing at the shared admin dir).
_in_linked_worktree() {
  local git_dir
  git_dir="$(git rev-parse --git-dir 2>/dev/null)" || return 1
  [[ -f "$git_dir/commondir" ]]
}

# Abort when the public or local base branch is checked out in another
# worktree — a base checkout here would fail halfway through finish.
finish_check_base_exclusivity() {
  local public_base="$1" local_base="$2" feature_name="${3:-<name>}"
  local current_top
  current_top="$(_worktree_abs "$(git rev-parse --show-toplevel)")"
  local path="" line
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ refs/heads/*)
        local held="${line#branch refs/heads/}"
        if [[ "$path" != "$current_top" \
           && ( "$held" == "$public_base" || "$held" == "$local_base" ) ]]; then
          ui_error "Base branch '$held' is checked out in another worktree: $path"
          ui_info  "Run 'git shadow feature finish $feature_name' from that checkout, or free the branch first."
          return 1
        fi
        ;;
      "") path="" ;;
    esac
  done < <(git worktree list --porcelain)
  return 0
}

# Resolve the worktree hosting the feature's @local branch into
# FINISH_WORKTREE. The current toplevel is never the feature worktree in
# the removal sense: bare finish stands on <name>@local itself.
finish_resolve_worktree() {
  FINISH_WORKTREE=""
  local wt current_top
  wt="$(worktree_find_for_branch "$FEATURE_LOCAL_BRANCH")" || return 0
  current_top="$(_worktree_abs "$(git rev-parse --show-toplevel)")"
  if [[ "$wt" != "$current_top" ]]; then
    FINISH_WORKTREE="$wt"
  fi
}

# Pre-mutation worktree guards. A registered worktree whose directory is
# missing is stale, not dirty; removal handles it later. A dirty worktree
# or a cwd inside the target worktree aborts before any change.
finish_check_feature_worktree() {
  finish_resolve_worktree
  [[ -z "$FINISH_WORKTREE" ]] && return 0
  [[ "$KEEP_WORKTREE" -eq 1 ]] && return 0
  [[ ! -d "$FINISH_WORKTREE" ]] && return 0   # stale registration

  local cwd
  cwd="$(pwd -P)"
  if [[ "$cwd" == "$FINISH_WORKTREE" || "$cwd" == "$FINISH_WORKTREE/"* ]]; then
    ui_error "Cannot remove worktree '$FINISH_WORKTREE': the current directory is inside it."
    ui_info  "Run 'git shadow feature finish $FEATURE_PUBLIC_BRANCH' from a checkout of '$PUBLIC_BASE' or '$LOCAL_BASE'."
    return 1
  fi

  if worktree_is_dirty "$FINISH_WORKTREE"; then
    ui_error "Feature worktree '$FINISH_WORKTREE' is dirty."
    git -C "$FINISH_WORKTREE" status --porcelain >&2
    ui_info  "Commit or stash the work, then retry; or keep it with --keep-worktree."
    ui_info  "Or run 'git shadow feature finish $FEATURE_PUBLIC_BRANCH' from a checkout of '$PUBLIC_BASE' or '$LOCAL_BASE'."
    return 1
  fi
  return 0
}

# Success-path cleanup: remove the feature worktree (unless kept) before
# deleting the feature branches. --keep-worktree preserves the worktree
# and <name>@local; --keep-branches preserves both branches.
finish_cleanup_feature() {
  if [[ -n "$FINISH_WORKTREE" && "$KEEP_WORKTREE" -eq 0 ]]; then
    if [[ -d "$FINISH_WORKTREE" ]] && worktree_is_dirty "$FINISH_WORKTREE"; then
      ui_error "Feature worktree '$FINISH_WORKTREE' is dirty; refusing to remove it."
      git -C "$FINISH_WORKTREE" status --porcelain >&2
      ui_info  "Commit or stash the work, then run: git worktree remove '$FINISH_WORKTREE'"
      return 1
    fi
    ui_shadow "Removing feature worktree '$FINISH_WORKTREE'"
    worktree_remove "$FINISH_WORKTREE" || return 1
  fi
  if [[ "$KEEP_BRANCHES" -eq 0 ]]; then
    git branch -D "$FEATURE_PUBLIC_BRANCH" >/dev/null 2>&1 || true
    if [[ "$KEEP_WORKTREE" -eq 0 ]]; then
      git branch -D "$FEATURE_LOCAL_BRANCH" >/dev/null 2>&1 || true
      ui_info "Deleted feature branches '$FEATURE_PUBLIC_BRANCH' and '$FEATURE_LOCAL_BRANCH'."
    else
      ui_info "Deleted public feature branch '$FEATURE_PUBLIC_BRANCH' (kept '$FEATURE_LOCAL_BRANCH')."
    fi
  fi
}

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

  sync_stage_all
  if [[ -d .git-shadow/annotations ]]; then
    git add -f .git-shadow/annotations/
  fi
  if [[ -d .git-shadow/patches ]]; then
    git add -f .git-shadow/patches/
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
  # FINISH_TMP_DIR is cleaned by the global EXIT trap — a `trap ... 0` here
  # would replace it (bash traps are global, not function-local).
  FINISH_TMP_DIR="$(mktemp -d)"

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

    if ! git diff "$sha^" "$sha" -- . ':!.git-shadow/annotations/' ':!.git-shadow/patches/' | git apply --3way --allow-empty; then
      local conflicted
      conflicted="$(git ls-files -u | awk '{print $4}' | sort -u)"
      ui_error "Conflict applying [MEMORY] commit $sha to '$LOCAL_BASE'."
      [[ -n "$conflicted" ]] && ui_error "Conflicting paths: $(printf '%s\n' "$conflicted" | paste -sd' ' -)"
      ui_info "Resolve the conflicts, then run: git shadow feature finish --continue"
      ui_info "Or run: git shadow feature finish --abort"
      return 1
    fi

    # Patch sidecars are local-only whole-file sidecars: apply them separately
    # so they do not participate in the generic 3-way merge of source files.
    if ! git diff "$sha^" "$sha" -- .git-shadow/patches/ | git apply --allow-empty; then
      ui_error "Failed to apply patch sidecars from [MEMORY] commit $sha."
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
KEEP_WORKTREE=0
CONTINUE=0
ABORT=0
MARK_APPLIED=""
FEATURE_NAME_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull)       NO_PULL=1 ;;
    --keep-branches) KEEP_BRANCHES=1 ;;
    --keep-worktree) KEEP_WORKTREE=1 ;;
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
    --*)
      ui_error "Unknown argument: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -n "$FEATURE_NAME_ARG" ]]; then
        ui_error "Unexpected argument: $1"
        usage
        exit 1
      fi
      FEATURE_NAME_ARG="$1"
      ;;
  esac
  shift
done

if [[ $((CONTINUE + ABORT)) -gt 1 || ( -n "$MARK_APPLIED" && $((CONTINUE + ABORT)) -gt 0 ) ]]; then
  ui_error "--continue, --abort, and --mark-applied are mutually exclusive."
  exit 1
fi

if [[ -n "$FEATURE_NAME_ARG" && ( "$CONTINUE" -eq 1 || "$ABORT" -eq 1 || -n "$MARK_APPLIED" ) ]]; then
  ui_error "A feature name cannot be combined with --continue, --abort, or --mark-applied."
  exit 1
fi

enter_project '.'

# Restore local patch overlays at the end of every non-paused exit.
# Also cleans FINISH_TMP_DIR; keep this the only EXIT trap so nothing below
# replaces it.
PAUSED=0
trap 'if [[ "$PAUSED" -eq 0 ]]; then patches_reapply >/dev/null 2>&1 || true; fi; if [[ -n "${FINISH_TMP_DIR:-}" ]]; then rm -rf "$FINISH_TMP_DIR"; fi' EXIT

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
    finish_check_base_exclusivity \
      "$(public_branch_from_any "$FINISH_LOCAL_BASE")" "$FINISH_LOCAL_BASE" || exit 1
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
    finish_check_base_exclusivity \
      "$(public_branch_from_any "$local_base")" "$local_base" || exit 1
    patches_strip >/dev/null
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
    PAUSED=1
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
    patches_strip >/dev/null
    sync_stage_all
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
      # FINISH_TMP_DIR is cleaned by the global EXIT trap — a `trap ... 0`
      # here would replace it (bash traps are global).
      FINISH_TMP_DIR="$(mktemp -d)"
      finish_merge_sidecars "$FINISH_CONFLICTED_SHA" "$FINISH_TMP_DIR"
      # Apply only the patch sidecars from the conflicted commit; the source
      # diff is already resolved in the working tree.
      git diff "$FINISH_CONFLICTED_SHA^" "$FINISH_CONFLICTED_SHA" -- .git-shadow/patches/ | git apply --allow-empty
      finish_commit_memory "$FINISH_CONFLICTED_SHA"
      APPLIED_MEMORY_SHAS+=("$FINISH_CONFLICTED_SHA")
      pid="$(patch_id_for "$FINISH_CONFLICTED_SHA")"
      [[ -n "$pid" ]] && APPLIED_MEMORY_PIDS+=("$pid")
    fi
    finish_clear_state
    MEMORY_SHAS=($FINISH_REMAINING_SHAS)
  else
    ui_error "Unknown finish phase: $FINISH_PHASE"
    PAUSED=1
    exit 1
  fi

  finish_collect_applied
  if [[ ${#MEMORY_SHAS[@]} -gt 0 ]]; then
    if ! finish_memory_replay "${MEMORY_SHAS[@]}"; then
      PAUSED=1
      exit 1
    fi
  fi

  if ! _new_checkpoint="$(sync_reanchor_and_checkpoint "$LOCAL_BASE" "$PUBLIC_BASE_HEAD" $PIDS_BASE)"; then
    exit 1
  fi

  finish_resolve_worktree
  if ! finish_cleanup_feature; then
    exit 1
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

PUBLIC_BASE="$PUBLIC_BASE_BRANCH"
LOCAL_BASE="${PUBLIC_BASE}${LOCAL_SUFFIX}"

if [[ -n "$FEATURE_NAME_ARG" ]]; then
  # Named mode: run from a checkout of the public or local base branch.
  if [[ "$CURRENT_BRANCH" != "$PUBLIC_BASE" && "$CURRENT_BRANCH" != "$LOCAL_BASE" ]]; then
    ui_error "feature finish <name> must be run from '$PUBLIC_BASE' or '$LOCAL_BASE' (recommended: '$LOCAL_BASE')."
    ui_info  "On a feature branch, run bare: git shadow feature finish"
    exit 1
  fi
  if [[ "$CURRENT_BRANCH" == "$PUBLIC_BASE" ]]; then
    ui_info "Running from the public base; '$LOCAL_BASE' is the recommended checkout."
  fi
  FEATURE_PUBLIC_BRANCH="$FEATURE_NAME_ARG"
  FEATURE_LOCAL_BRANCH="${FEATURE_NAME_ARG}${LOCAL_SUFFIX}"
  if [[ "$FEATURE_PUBLIC_BRANCH" == "$PUBLIC_BASE" ]]; then
    ui_error "Cannot finish the base branch."
    exit 1
  fi
else
  # Bare mode: derive the feature from the current @local branch.
  if _in_linked_worktree; then
    ui_error "Bare 'feature finish' cannot run inside a linked worktree."
    ui_info  "Commit or stash your work in '$(git rev-parse --show-toplevel)', then run:"
    ui_info  "  git shadow feature finish $(public_branch_from_any "$CURRENT_BRANCH")"
    ui_info  "from a checkout of '$PUBLIC_BASE' or '$LOCAL_BASE'."
    ui_info  "Or remove the worktree manually: git worktree remove '$(git rev-parse --show-toplevel)'"
    exit 1
  fi
  if [[ ! "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
    ui_error "feature finish must be run from a branch ending with '${LOCAL_SUFFIX}'."
    exit 1
  fi
  FEATURE_PUBLIC_BRANCH="$(public_branch_from_any "$CURRENT_BRANCH")"
  FEATURE_LOCAL_BRANCH="$CURRENT_BRANCH"
  if [[ "$FEATURE_PUBLIC_BRANCH" == "$PUBLIC_BASE" || "$FEATURE_LOCAL_BRANCH" == "$LOCAL_BASE" ]]; then
    ui_error "This command must be run from a feature branch, not from the base."
    exit 1
  fi
fi

for branch in "$FEATURE_PUBLIC_BRANCH" "$FEATURE_LOCAL_BRANCH" "$PUBLIC_BASE" "$LOCAL_BASE"; do
  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    ui_error "Branch does not exist locally: $branch"
    exit 1
  fi
done

# Worktree guards before any mutation: a needed base checkout must not be
# blocked by another worktree, and a feature worktree slated for removal
# must be clean and not contain the cwd.
finish_check_base_exclusivity "$PUBLIC_BASE" "$LOCAL_BASE" "$FEATURE_PUBLIC_BRANCH" || exit 1
finish_check_feature_worktree || exit 1

ui_shadow "Finalizing feature '$FEATURE_PUBLIC_BRANCH'"
ui_git    "   Public base   : $PUBLIC_BASE"
ui_shadow "   Local base    : $LOCAL_BASE"

# ---------------------------------------------------------------------------
# Pull / refresh the public base
# ---------------------------------------------------------------------------
if [[ "$NO_PULL" -eq 0 ]]; then
  ui_git "Pulling latest changes for '$PUBLIC_BASE'"
  patches_strip >/dev/null
  git checkout -q "$PUBLIC_BASE" >/dev/null 2>&1
  if ! git pull >/dev/null 2>&1; then
    ui_warn "Pull failed for '$PUBLIC_BASE'; continuing with local state."
  fi
fi

PUBLIC_BASE_HEAD="$(git rev-parse "$PUBLIC_BASE")"

# Verify the public feature branch has been merged into the public base.
# An ancestry check alone misses squash merges (a new commit whose tree
# contains the feature changes but whose history does not include the
# feature commits), so fall back to checking that the feature's public
# tree is contained in the base tree.
if ! git merge-base --is-ancestor "$FEATURE_PUBLIC_BRANCH" "$PUBLIC_BASE" \
   && ! check_tree_matches "$FEATURE_PUBLIC_BRANCH" "$PUBLIC_BASE" 2>/dev/null; then
  ui_error "Feature '$FEATURE_PUBLIC_BRANCH' is not merged into '$PUBLIC_BASE' (or '$PUBLIC_BASE' has since modified the same paths). Merge it first."
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
patches_strip >/dev/null
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
      PAUSED=1
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
    PAUSED=1
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
# Worktree + branch cleanup
# ---------------------------------------------------------------------------
if ! finish_cleanup_feature; then
  exit 1
fi

ui_ok "Feature finished successfully."
