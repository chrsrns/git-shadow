#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/finish.sh
# Purpose: finalize a feature in the diff-sync model.
#
# Usage: git shadow feature finish [<name>] [--no-pull] [--keep-branches]
#          [--keep-worktree] [--continue|--abort] [--mark-applied <sha>]
# -------------------------------------------------------------------

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
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
  local path held
  while IFS=$'\t' read -r path held; do
    [[ -z "$path" ]] && continue
    if [[ "$path" != "$current_top" \
       && ( "$held" == "$public_base" || "$held" == "$local_base" ) ]]; then
      ui_error "Base branch '$held' is checked out in another worktree: $path"
      ui_info  "Run 'git shadow feature finish $feature_name' from that checkout, or free the branch first."
      return 1
    fi
  done < <(worktree_records)
  return 0
}

# Resolve the worktree hosting the feature's @local branch into
# FINISH_WORKTREE. The current toplevel is never the feature worktree in
# the removal sense: bare finish stands on <name>@local itself.
# Arguments: <feature_local_branch>
finish_resolve_worktree() {
  local feature_local="$1"
  FINISH_WORKTREE=""
  local wt current_top
  wt="$(worktree_find_for_branch "$feature_local")" || return 0
  current_top="$(_worktree_abs "$(git rev-parse --show-toplevel)")"
  if [[ "$wt" != "$current_top" ]]; then
    FINISH_WORKTREE="$wt"
  fi
}

# Pre-mutation worktree guards. A registered worktree whose directory is
# missing is stale, not dirty; removal handles it later. A dirty worktree
# or a cwd inside the target worktree aborts before any change.
# Arguments: <feature_public_branch> <feature_local_branch> <public_base> <local_base>
finish_check_feature_worktree() {
  local feature_public="$1" feature_local="$2"
  local public_base="$3" local_base="$4"
  finish_resolve_worktree "$feature_local"
  [[ -z "$FINISH_WORKTREE" ]] && return 0
  [[ "$KEEP_WORKTREE" -eq 1 ]] && return 0
  [[ ! -d "$FINISH_WORKTREE" ]] && return 0   # stale registration

  local cwd
  cwd="$(pwd -P)"
  if [[ "$cwd" == "$FINISH_WORKTREE" || "$cwd" == "$FINISH_WORKTREE/"* ]]; then
    ui_error "Cannot remove worktree '$FINISH_WORKTREE': the current directory is inside it."
    ui_info  "Run 'git shadow feature finish $feature_public' from a checkout of '$public_base' or '$local_base'."
    return 1
  fi

  if worktree_is_dirty "$FINISH_WORKTREE"; then
    ui_error "Feature worktree '$FINISH_WORKTREE' is dirty."
    git -C "$FINISH_WORKTREE" status --porcelain >&2
    ui_info  "Commit or stash the work, then retry; or keep it with --keep-worktree."
    ui_info  "Or run 'git shadow feature finish $feature_public' from a checkout of '$public_base' or '$local_base'."
    return 1
  fi
  return 0
}

# Success-path cleanup: remove the feature worktree (unless kept) before
# deleting the feature branches. --keep-worktree preserves the worktree
# and <name>@local; --keep-branches preserves both branches.
# Arguments: <feature_public_branch> <feature_local_branch> <worktree_path>
finish_cleanup_feature() {
  local feature_public="$1" feature_local="$2" worktree="$3"
  if [[ -n "$worktree" && "$KEEP_WORKTREE" -eq 0 ]]; then
    if [[ -d "$worktree" ]] && worktree_is_dirty "$worktree"; then
      ui_error "Feature worktree '$worktree' is dirty; refusing to remove it."
      git -C "$worktree" status --porcelain >&2
      ui_info  "Commit or stash the work, then run: git worktree remove '$worktree'"
      return 1
    fi
    ui_shadow "Removing feature worktree '$worktree'"
    worktree_remove "$worktree" || return 1
  fi
  if [[ "$KEEP_BRANCHES" -eq 0 ]]; then
    git branch -D "$feature_public" >/dev/null 2>&1 || true
    if [[ "$KEEP_WORKTREE" -eq 0 ]]; then
      git branch -D "$feature_local" >/dev/null 2>&1 || true
      ui_info "Deleted feature branches '$feature_public' and '$feature_local'."
    else
      ui_info "Deleted public feature branch '$feature_public' (kept '$feature_local')."
    fi
  fi
}

# Collect [MEMORY] provenance already recorded on the local base.
# Arguments: <local_base>
finish_collect_applied() {
  local local_base="$1"
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
  done < <(git log --grep='^\[MEMORY\]' --format='%b' "$local_base")
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

# Apply the .git-shadow/patches sidecars of one [MEMORY] commit, merge its
# annotation sidecars, record the commit, and mark it applied. Shared by the
# replay loop and the --continue resume of a conflicted SHA (whose source
# diff is already resolved in the working tree).
# Arguments: <sha> <tmp_dir>
finish_memory_commit_sidecars() {
  local sha="$1" tmp_dir="$2"

  # Patch sidecars are local-only whole-file sidecars: apply them separately
  # so they do not participate in the generic 3-way merge of source files.
  if ! git diff "$sha^" "$sha" -- .git-shadow/patches/ | git apply --allow-empty; then
    ui_error "Failed to apply patch sidecars from [MEMORY] commit $sha."
    return 1
  fi

  finish_merge_sidecars "$sha" "$tmp_dir"
  finish_commit_memory "$sha"

  APPLIED_MEMORY_SHAS+=("$sha")
  local memory_pid
  memory_pid="$(patch_id_for "$sha")"
  [[ -n "$memory_pid" ]] && APPLIED_MEMORY_PIDS+=("$memory_pid")
  return 0
}

# Replay the given [MEMORY] SHAs onto the local base, pausing on conflict.
# Arguments: <feature_public> <feature_local> <local_base> <pre_finish_head>
#            <range_start> <range_end> <pids_base> <sha...>
# KEEP_WORKTREE/KEEP_BRANCHES are parsed flags (allowed globals).
# Uses APPLIED_MEMORY_SHAS / APPLIED_MEMORY_PIDS for idempotency.
finish_memory_replay() {
  local feature_public="$1" feature_local="$2" local_base="$3"
  local pre_finish_head="$4" range_start="$5" range_end="$6" pids_base="$7"
  shift 7
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
      "$feature_public" "$feature_local" "$local_base" \
      "$pre_finish_head" "memory-replay" "$sha" \
      "${remaining[*]}" "$range_start" "$range_end" "$pids_base" \
      "$KEEP_WORKTREE" "$KEEP_BRANCHES"

    if ! git diff "$sha^" "$sha" -- . ':!.git-shadow/annotations/' ':!.git-shadow/patches/' | git apply --3way --allow-empty; then
      local conflicted
      conflicted="$(git ls-files -u | awk '{print $4}' | sort -u)"
      ui_error "Conflict applying [MEMORY] commit $sha to '$local_base'."
      [[ -n "$conflicted" ]] && ui_error "Conflicting paths: $(printf '%s\n' "$conflicted" | paste -sd' ' -)"
      ui_info "Resolve the conflicts, then run: git shadow feature finish --continue"
      ui_info "Or run: git shadow feature finish --abort"
      return 1
    fi

    if ! finish_memory_commit_sidecars "$sha" "$FINISH_TMP_DIR"; then
      return 1
    fi
    finish_clear_state
  done
  return 0
}

# Stage the working tree and commit the public→local base diff when the tree
# changed. Used by the --continue resume of a paused base-diff phase, where the
# diff was already applied and conflicts resolved manually.
# Arguments: <local_base> <public_base> <range_start> <range_end> [source_branch]
finish_base_diff_commit() {
  local local_base="$1" public_base="$2" range_start="$3" range_end="$4"
  local source_branch="${5:-}"
  sync_stage_all
  if sync_tree_changed; then
    sync_commit "$local_base" "$public_base" "$range_start" "$range_end" "$source_branch"
  fi
}

# Fresh base-diff phase: record pause state, apply the public net diff, and
# commit it via sync_apply_and_commit. On conflict the state stays written
# so --continue can resume.
# Arguments: <feature_public> <feature_local> <local_base> <public_base>
#            <pre_finish_head> <range_start> <range_end> <pids_base>
#            <remaining_shas>
# KEEP_WORKTREE/KEEP_BRANCHES are parsed flags (allowed globals).
finish_base_diff_apply() {
  local feature_public="$1" feature_local="$2" local_base="$3"
  local public_base="$4" pre_finish_head="$5" range_start="$6" range_end="$7"
  local pids_base="$8" remaining_shas="$9"

  finish_save_state \
    "$feature_public" "$feature_local" "$local_base" \
    "$pre_finish_head" "base-diff" "" \
    "$remaining_shas" "$range_start" "$range_end" "$pids_base" \
    "$KEEP_WORKTREE" "$KEEP_BRANCHES"

  if ! sync_apply_and_commit "$local_base" "$public_base" "$range_start" "$range_end" "$feature_public" >/dev/null; then
    local conflicted
    conflicted="$(git ls-files -u | awk '{print $4}' | sort -u)"
    ui_error "Conflict applying public base net diff to '$local_base'."
    [[ -n "$conflicted" ]] && ui_error "Conflicting paths: $(printf '%s\n' "$conflicted" | paste -sd' ' -)"
    ui_info "Resolve the conflicts, then run: git shadow feature finish --continue"
    ui_info "Or run: git shadow feature finish --abort"
    return 1
  fi
  finish_clear_state
}

# Shared tail of the normal and --continue paths: replay the remaining
# [MEMORY] commits, create the checkpoint, and clean up the feature
# worktree and branches.
# Arguments: <feature_public> <feature_local> <local_base> <pre_finish_head>
#            <range_start> <range_end> <pids_base> <public_base_head> [sha...]
finish_finalize() {
  local feature_public="$1" feature_local="$2" local_base="$3"
  local pre_finish_head="$4" range_start="$5" range_end="$6"
  local pids_base="$7" public_base_head="$8"
  shift 8
  local -a memory_shas=("$@")

  ui_shadow "Replaying [MEMORY] commits from '$feature_local'"
  finish_collect_applied "$local_base"
  if [[ ${#memory_shas[@]} -gt 0 ]]; then
    if ! finish_memory_replay "$feature_public" "$feature_local" "$local_base" \
        "$pre_finish_head" "$range_start" "$range_end" "$pids_base" \
        "${memory_shas[@]}"; then
      return 1
    fi
  fi

  local -a pids=()
  [[ -n "$pids_base" ]] && read -ra pids <<< "$pids_base"
  if ! sync_reanchor_and_checkpoint "$local_base" "$public_base_head" "${pids[@]}" >/dev/null; then
    return 1
  fi

  finish_resolve_worktree "$feature_local"
  if ! finish_cleanup_feature "$feature_public" "$feature_local" "$FINISH_WORKTREE"; then
    return 1
  fi
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

# Clean FINISH_TMP_DIR on exit. Patch overlay reapply is handled by
# `patches_transaction` around each mutating block; this trap must only
# manage the temporary directory so it is not clobbered by inner `trap 0`
# calls.
trap 'if [[ -n "${FINISH_TMP_DIR:-}" ]]; then rm -rf "$FINISH_TMP_DIR"; fi' EXIT

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
  conflicted="$(git ls-files -u | awk '{print $4}' | sort -u)"

  _finish_abort_body() {
    local conflicted="$1"
    if [[ "$(current_branch)" != "$FINISH_LOCAL_BASE" ]]; then
      finish_check_base_exclusivity \
        "$(public_branch_from_any "$FINISH_LOCAL_BASE")" "$FINISH_LOCAL_BASE" || return 1
      git checkout -q "$FINISH_LOCAL_BASE" >/dev/null 2>&1 || {
        ui_error "Cannot checkout '$FINISH_LOCAL_BASE'."
        return 1
      }
    fi
    git reset --hard "$FINISH_PRE_FINISH_HEAD"
    finish_clear_state
    ui_ok "Feature finish aborted. Restored '$FINISH_LOCAL_BASE' to pre-finish state."
    if [[ -n "$conflicted" ]]; then
      ui_info "Discarded conflicting paths: $(printf '%s\n' "$conflicted" | paste -sd' ' -)"
    fi
    ui_info "Restart with 'git shadow feature finish'; the paused state is cleared (--continue/--abort no longer apply)."
    return 0
  }

  if ! patches_transaction _finish_abort_body "$conflicted"; then
    exit 1
  fi
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

  _finish_mark_applied_body() {
    local local_base="$1" target_sha="$2"
    local subject pid tree parent
    if [[ "$(current_branch)" != "$local_base" ]]; then
      finish_check_base_exclusivity \
        "$(public_branch_from_any "$local_base")" "$local_base" || return 1
      git checkout -q "$local_base" >/dev/null 2>&1 || {
        ui_error "Cannot checkout '$local_base'."
        return 1
      }
    fi

    subject="$(git log -1 --format='%s' "$target_sha")"
    pid="$(patch_id_for "$target_sha")"
    tree="$(git rev-parse "$local_base^{tree}")"
    parent="$(git rev-parse "$local_base")"

    local commit_args=(-m "$subject" -m "git-shadow-source-memory: $target_sha")
    if [[ -n "$pid" ]]; then
      commit_args+=(-m "git-shadow-source-pid: $pid")
    fi
    local new_sha
    new_sha="$(env GIT_SHADOW=1 git commit-tree "$tree" -p "$parent" "${commit_args[@]}")"
    git update-ref "refs/heads/$local_base" "$new_sha"

    if finish_load_state; then
      local remaining=()
      local s
      for s in $FINISH_REMAINING_SHAS; do
        [[ "$s" != "$target_sha" ]] && remaining+=("$s")
      done
      local conflicted="$FINISH_CONFLICTED_SHA"
      [[ "$conflicted" == "$target_sha" ]] && conflicted=""
      local keep_wt=0 keep_br=0
      [[ "${FINISH_KEEP_WORKTREE:-0}" == "1" ]] && keep_wt=1
      [[ "$KEEP_WORKTREE" -eq 1 ]] && keep_wt=1
      [[ "${FINISH_KEEP_BRANCHES:-0}" == "1" ]] && keep_br=1
      [[ "$KEEP_BRANCHES" -eq 1 ]] && keep_br=1
      finish_save_state \
        "$FINISH_FEATURE_PUBLIC" "$FINISH_FEATURE_LOCAL" "$local_base" \
        "$new_sha" "$FINISH_PHASE" "$conflicted" \
        "${remaining[*]}" "$FINISH_RANGE_START" "$FINISH_RANGE_END" "$FINISH_PIDS" \
        "$keep_wt" "$keep_br"
      ui_ok "Recorded provenance for $target_sha and updated paused finish state."
    else
      ui_ok "Recorded provenance for $target_sha on '$local_base'."
    fi
    return 0
  }

  if ! patches_transaction _finish_mark_applied_body "$local_base" "$target_sha"; then
    exit 1
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

  # Widen stored keep flags with any flags re-supplied on --continue.
  [[ "${FINISH_KEEP_WORKTREE:-0}" == "1" ]] && KEEP_WORKTREE=1
  [[ "${FINISH_KEEP_BRANCHES:-0}" == "1" ]] && KEEP_BRANCHES=1

  _finish_continue_body() {
    local local_base="$1" public_base="$2" public_base_head="$3"
    local pre_finish_head="$4" range_start="$5" range_end="$6"
    local pids_base="$7" feature_public="$8" feature_local="$9"
    local -a memory_shas=()

    if [[ "$FINISH_PHASE" == "base-diff" ]]; then
      if ! finish_base_diff_commit "$local_base" "$public_base" \
          "$range_start" "$range_end" "$feature_public"; then
        return 1
      fi
      finish_clear_state
      read -ra memory_shas <<< "$FINISH_REMAINING_SHAS"
    elif [[ "$FINISH_PHASE" == "memory-replay" ]]; then
      # The conflicted [MEMORY] non-sidecar is already resolved in the working
      # tree. Re-run the sidecar merge from the resolved source and commit it,
      # unless --mark-applied has already recorded it (V102).
      finish_collect_applied "$local_base"
      if [[ -n "$FINISH_CONFLICTED_SHA" ]]; then
        # FINISH_TMP_DIR is cleaned by the global EXIT trap — a `trap ... 0`
        # here would replace it (bash traps are global).
        FINISH_TMP_DIR="$(mktemp -d)"
        if ! finish_memory_commit_sidecars "$FINISH_CONFLICTED_SHA" "$FINISH_TMP_DIR"; then
          return 1
        fi
      fi
      finish_clear_state
      read -ra memory_shas <<< "$FINISH_REMAINING_SHAS"
    else
      ui_error "Unknown finish phase: $FINISH_PHASE"
      return 1
    fi

    if ! finish_finalize "$feature_public" "$feature_local" "$local_base" \
        "$pre_finish_head" "$range_start" "$range_end" "$pids_base" \
        "$public_base_head" "${memory_shas[@]}"; then
      return 1
    fi
    return 0
  }

  # shellcheck disable=SC2034  # read by lib/patches.sh during the transaction
  PATCHES_REAPPLY_PAUSE=1
  if ! patches_transaction _finish_continue_body \
      "$LOCAL_BASE" "$PUBLIC_BASE" "$PUBLIC_BASE_HEAD" "$PRE_FINISH_HEAD" \
      "$RANGE_START" "$RANGE_END" "$PIDS_BASE" \
      "$FEATURE_PUBLIC_BRANCH" "$FEATURE_LOCAL_BRANCH"; then
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
finish_check_feature_worktree "$FEATURE_PUBLIC_BRANCH" "$FEATURE_LOCAL_BRANCH" "$PUBLIC_BASE" "$LOCAL_BASE" || exit 1

ui_shadow "Finalizing feature '$FEATURE_PUBLIC_BRANCH'"
ui_git    "   Public base   : $PUBLIC_BASE"
ui_shadow "   Local base    : $LOCAL_BASE"

_finish_normal_body() {
  local public_base="$1" local_base="$2"
  local feature_public="$3" feature_local="$4"

  # ---------------------------------------------------------------------------
  # Pull / refresh the public base
  # ---------------------------------------------------------------------------
  if [[ "$NO_PULL" -eq 0 ]]; then
    ui_git "Pulling latest changes for '$public_base'"
    git checkout -q "$public_base" >/dev/null 2>&1
    if ! git pull >/dev/null 2>&1; then
      ui_warn "Pull failed for '$public_base'; continuing with local state."
    fi
  fi

  local public_base_head
  public_base_head="$(git rev-parse "$public_base")"

  # Verify the public feature branch has been merged into the public base.
  # An ancestry check alone misses squash merges (a new commit whose tree
  # contains the feature changes but whose history does not include the
  # feature commits), so fall back to checking that the feature's public
  # tree is contained in the base tree.
  if ! git merge-base --is-ancestor "$feature_public" "$public_base" \
     && ! check_tree_matches "$feature_public" "$public_base" 2>/dev/null; then
    ui_error "Feature '$feature_public' is not merged into '$public_base' (or '$public_base' has since modified the same paths). Merge it first."
    return 1
  fi

  # ---------------------------------------------------------------------------
  # Compute the feature [MEMORY] list before the base diff.
  # ---------------------------------------------------------------------------
  local merge_base
  merge_base="$(git merge-base "$feature_local" "$local_base")"
  local -a memory_shas=()
  local sha subject pid skip applied_sha applied_pid
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    subject="$(git log -1 --format='%s' "$sha")"
    if [[ "$subject" == "[MEMORY]"* ]]; then
      memory_shas+=("$sha")
    fi
  done < <(git rev-list --reverse "${merge_base}..$feature_local")

  finish_collect_applied "$local_base"
  local -a memory_shas_unique=()
  for sha in "${memory_shas[@]}"; do
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
      memory_shas_unique+=("$sha")
    fi
  done
  memory_shas=("${memory_shas_unique[@]}")

  # ---------------------------------------------------------------------------
  # Apply the public base net diff to the local base.
  # ---------------------------------------------------------------------------
  ui_shadow "Checkout '$local_base'"
  git checkout -q "$local_base" >/dev/null 2>&1

  local latest_cp cp_public pre_finish_head range_start range_end pids_base
  latest_cp="$(checkpoint_latest "$local_base")"
  if [[ -z "$latest_cp" ]]; then
    ui_error "No checkpoint found on '$local_base'. Run 'git shadow base sync' first."
    return 1
  fi

  cp_public="$(checkpoint_public "$latest_cp")"
  pre_finish_head="$(git rev-parse "$local_base")"
  range_start="$cp_public"
  range_end="$public_base_head"
  pids_base=""

  if [[ "$cp_public" != "$public_base_head" ]]; then
    if ! git merge-base --is-ancestor "$cp_public" "$public_base_head"; then
      ui_error "Public base '$public_base' has moved non-fast-forward from the local checkpoint."
      return 1
    fi

    # V14: skip the base net diff when the local base already contains the public
    # base tree (only local-only additions differ).
    if git diff-tree --no-renames -r "$public_base_head" "$pre_finish_head" | awk '$5 != "A" {exit 1}'; then
      :
    else
      pids_base="$(sync_patch_ids "$cp_public" "$public_base_head" | tr '\n' ' ' | sed 's/ $//')"
      if ! finish_base_diff_apply "$feature_public" "$feature_local" \
          "$local_base" "$public_base" "$pre_finish_head" \
          "$range_start" "$range_end" "$pids_base" "${memory_shas[*]}"; then
        return 1
      fi
    fi
  fi

  if ! finish_finalize "$feature_public" "$feature_local" "$local_base" \
      "$pre_finish_head" "$range_start" "$range_end" "$pids_base" \
      "$public_base_head" "${memory_shas[@]}"; then
    return 1
  fi
  return 0
}

# shellcheck disable=SC2034  # read by lib/patches.sh during the transaction
PATCHES_REAPPLY_PAUSE=1
if ! patches_transaction _finish_normal_body \
    "$PUBLIC_BASE" "$LOCAL_BASE" "$FEATURE_PUBLIC_BRANCH" "$FEATURE_LOCAL_BRANCH"; then
  exit 1
fi

ui_ok "Feature finished successfully."
