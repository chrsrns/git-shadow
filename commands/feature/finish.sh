#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/finish.sh
# Purpose: finalize a feature in the diff-sync model.
#
# Usage: git shadow feature finish [<name>] [--no-pull] [--keep-branches]
#          [--keep-worktree] [--continue|--abort] [--mark-applied <sha>]
# -------------------------------------------------------------------

_GS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/help.sh"
if gs_help_requested --mark-applied -- "$@"; then
  echo "Usage: git shadow feature finish ([<name>]|--continue|--abort|--mark-applied <sha>) [--no-pull] [--keep-branches] [--keep-worktree]"
  exit 0
fi

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/common.sh"

usage() {
  cat <<'EOF'
Usage: git shadow feature finish ([<name>]|--continue|--abort|--mark-applied <sha>) [--no-pull] [--keep-branches] [--keep-worktree]
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
  current_top="$(abs_path_m "$(repo_root)")"
  local path held rec_locked
  # shellcheck disable=SC2034  # third record field consumed by other readers; required so the branch field does not fold
  while IFS=$'\t' read -r path held rec_locked; do
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
# Reads the finish-context global FEATURE_LOCAL_BRANCH.
finish_resolve_worktree() {
  FINISH_WORKTREE=""
  local wt current_top
  wt="$(worktree_find_for_branch "$FEATURE_LOCAL_BRANCH")" || return 0
  current_top="$(abs_path_m "$(repo_root)")"
  if [[ "$wt" != "$current_top" ]]; then
    FINISH_WORKTREE="$wt"
  fi
}

# Pre-mutation worktree guards. A registered worktree whose directory is
# missing is stale, not dirty; removal handles it later. A dirty worktree
# or a cwd inside the target worktree aborts before any change.
# Reads the finish-context globals (FEATURE_PUBLIC_BRANCH, PUBLIC_BASE,
# LOCAL_BASE).
finish_check_feature_worktree() {
  finish_resolve_worktree
  [[ -z "$FINISH_WORKTREE" ]] && return 0
  [[ "$KEEP_WORKTREE" -eq 1 ]] && return 0

  # The main worktree is never a removal candidate: `git worktree remove`
  # refuses it and the revert/env-deletion machinery must never touch the
  # user's primary checkout. FINISH_WORKTREE already excludes the invoking
  # toplevel, so equality here means a named finish from another checkout.
  local main_top
  main_top="$(worktree_paths | head -1)"
  if [[ -n "$main_top" && "$FINISH_WORKTREE" == "$main_top" ]]; then
    ui_error "Cannot remove worktree '$FINISH_WORKTREE': it is the main worktree ('$FEATURE_LOCAL_BRANCH' is checked out there)."
    ui_info  "Free '$FEATURE_LOCAL_BRANCH' in the main checkout (git checkout --detach), then re-run 'git shadow feature finish $FEATURE_PUBLIC_BRANCH'."
    return 1
  fi

  if worktree_is_locked "$FINISH_WORKTREE"; then
    ui_error "Feature worktree '$FINISH_WORKTREE' is locked."
    ui_info  "Run 'git worktree unlock \"$FINISH_WORKTREE\"', or keep it with --keep-worktree."
    return 1
  fi
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
    ( cd "$FINISH_WORKTREE" && patches_dirty_table >&2 ) \
      || ui_error "Unable to enumerate worktree status for '$FINISH_WORKTREE'."
    ui_info  "Commit or stash the work, then retry; or keep it with --keep-worktree."
    ui_info  "Or run 'git shadow feature finish $FEATURE_PUBLIC_BRANCH' from a checkout of '$PUBLIC_BASE' or '$LOCAL_BASE'."
    return 1
  fi

  # Enumerate ?? records directly — the classifier exempts .git-shadow.env,
  # .gitignore and registered-worktree dirs, but `git worktree remove`
  # refuses them identically. Fail closed on enumeration failure. Runs in
  # a subshell inside the target worktree (V235).
  local untracked_enum
  untracked_enum="$(mktemp)" || return 1
  if ! ( cd "$FINISH_WORKTREE" && patches_untracked_records ) > "$untracked_enum"; then
    rm -f "$untracked_enum"
    ui_error "Unable to enumerate untracked files in '$FINISH_WORKTREE'."
    return 1
  fi
  local urec
  local -a untracked_paths=()
  while IFS= read -r -d '' urec || [[ -n "$urec" ]]; do
    [[ -z "$urec" || "$urec" == .git-shadow.env ]] && continue
    untracked_paths+=("$urec")
  done < "$untracked_enum"
  rm -f "$untracked_enum"
  if [[ ${#untracked_paths[@]} -gt 0 ]]; then
    ui_error "Feature worktree '$FINISH_WORKTREE' contains untracked files 'git worktree remove' refuses:"
    printf '  ?? %s\n' "${untracked_paths[@]}" >&2
    ui_info  "Commit, move, or delete them, then retry; or keep it with --keep-worktree."
    return 1
  fi
  return 0
}

# Restore every `patch`-classed source file inside <worktree> to HEAD so a
# plain `git worktree remove` is not refused by an applied overlay. The
# overlay content is already preserved on the base by the [MEMORY] replay.
# `patch`-class only: at-HEAD paths skip as no-ops and `patch-stale` paths
# stay, so a mid-run edit still blocks removal instead of being clobbered
# (V276). Runs inside the target worktree so path classification resolves
# against it (V220/V235).
finish_revert_worktree_overlays() {
  local worktree="$1"
  local rec status class path
  while IFS= read -r -d '' rec || [[ -n "$rec" ]]; do
    [[ -z "$rec" ]] && continue
    status="${rec%%$'\t'*}"
    class="$(printf '%s' "$rec" | cut -f2)"
    [[ "$class" != "patch" ]] && continue
    path="$(printf '%s' "$rec" | cut -f3)"
    if ! git -C "$worktree" checkout -q HEAD -- "$path"; then
      ui_error "Failed to revert patch overlay on '$path' in '$worktree'."
      return 1
    fi
  done < <(cd "$worktree" && patches_dirty_records)
  return 0
}

# Success-path cleanup: remove the feature worktree (unless kept) before
# deleting the feature branches. --keep-worktree preserves the worktree
# and <name>@local; --keep-branches preserves both branches.
# Reads the finish-context globals FEATURE_PUBLIC_BRANCH, FEATURE_LOCAL_BRANCH
# and FINISH_WORKTREE.
finish_cleanup_feature() {
  local worktree="$FINISH_WORKTREE"
  if [[ -n "$worktree" && "$KEEP_WORKTREE" -eq 0 ]]; then
    # Re-probe the main-worktree exclusion — a mid-run relocation of
    # <name>@local into the main checkout, or the --continue path that
    # bypasses finish_check_feature_worktree, must not run the revert,
    # env deletion, or removal against the user's primary checkout.
    local main_top
    main_top="$(worktree_paths | head -1)"
    if [[ -n "$main_top" && "$worktree" == "$main_top" ]]; then
      ui_error "Cannot remove worktree '$worktree': it is the main worktree ('$FEATURE_LOCAL_BRANCH' is checked out there)."
      ui_info  "Free '$FEATURE_LOCAL_BRANCH' in the main checkout (git checkout --detach), then re-run 'git shadow feature finish $FEATURE_PUBLIC_BRANCH'."
      return 1
    fi
    # Re-probe the lock before removal regardless of directory presence: a
    # mid-run lock must not reach the prune path (prune skips locked
    # registrations) and a locked live tree must not reach `git worktree
    # remove`.
    if worktree_is_locked "$worktree"; then
      ui_error "Feature worktree '$worktree' is locked."
      ui_info  "Run 'git worktree unlock \"$worktree\"', then retry."
      return 1
    fi
    if [[ -d "$worktree" ]] && ! finish_revert_worktree_overlays "$worktree"; then
      return 1
    fi
    if [[ -d "$worktree" ]] && worktree_is_dirty "$worktree"; then
      ui_error "Feature worktree '$worktree' is dirty; refusing to remove it."
      ( cd "$worktree" && patches_dirty_table >&2 ) \
        || ui_error "Unable to enumerate worktree status for '$worktree'."
      ui_info  "Commit or stash the work, then run: git worktree remove '$worktree'"
      return 1
    fi
    # Drop the toolkit-owned .git-shadow.env copy (worktree_add recreates
    # it) — untracked files refuse `git worktree remove`. Only when the
    # path is untracked here; a tracked or modified copy stays for the
    # dirt gate. Runs after the re-check so an abort leaves the worktree
    # fully configured.
    if [[ -f "$worktree/.git-shadow.env" ]] &&
       ! git -C "$worktree" ls-files --error-unmatch -- .git-shadow.env >/dev/null 2>&1; then
      rm -f -- "$worktree/.git-shadow.env" || return 1
    fi
    ui_shadow "Removing feature worktree '$worktree'"
    worktree_remove "$worktree" || return 1
  fi
  if [[ "$KEEP_BRANCHES" -eq 0 ]]; then
    # A still-existing branch after a failed delete is a real failure; a
    # missing one is a legitimate partial-retry state.
    local deleted_public=0 deleted_local=0
    if git branch -D "$FEATURE_PUBLIC_BRANCH" >/dev/null 2>&1; then
      deleted_public=1
    elif git show-ref --verify --quiet "refs/heads/$FEATURE_PUBLIC_BRANCH"; then
      ui_warn "Could not delete public feature branch '$FEATURE_PUBLIC_BRANCH'."
    fi
    if [[ "$KEEP_WORKTREE" -eq 0 ]]; then
      if git branch -D "$FEATURE_LOCAL_BRANCH" >/dev/null 2>&1; then
        deleted_local=1
      elif git show-ref --verify --quiet "refs/heads/$FEATURE_LOCAL_BRANCH"; then
        ui_warn "Could not delete local feature branch '$FEATURE_LOCAL_BRANCH'."
      fi
      [[ "$deleted_public" -eq 1 && "$deleted_local" -eq 1 ]] && \
        ui_info "Deleted feature branches '$FEATURE_PUBLIC_BRANCH' and '$FEATURE_LOCAL_BRANCH'."
    else
      [[ "$deleted_public" -eq 1 ]] && \
        ui_info "Deleted public feature branch '$FEATURE_PUBLIC_BRANCH' (kept '$FEATURE_LOCAL_BRANCH')."
    fi
  fi
}

# Collect [MEMORY] provenance already recorded on the local base.
# Reads the finish-context global LOCAL_BASE.
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

    if [[ -e "$REPO_ROOT/$source_path" ]]; then
      cp "$REPO_ROOT/$source_path" "$source_tmp"

      # Re-anchor the current base sidecar (if any).
      if rev_blob_to HEAD "$ann_path" "$base_ann_tmp"; then
        annotations_reanchor "$source_tmp" "$base_ann_tmp" "$new_base_ann" 2>/dev/null || true
      else
        : > "$new_base_ann"
      fi

      mkdir -p "$REPO_ROOT/$(dirname "$ann_path")"
      if [[ "$status" != "D" ]]; then
        # Re-anchor the feature sidecar and merge with the base sidecar.
        if rev_blob_to "$sha" "$ann_path" "$feature_ann_tmp"; then
          annotations_reanchor "$source_tmp" "$feature_ann_tmp" "$new_feature_ann" 2>/dev/null || true
          annotations_merge "$new_base_ann" "$new_feature_ann" "$merged_ann" append --warn-differing
          cp "$merged_ann" "$REPO_ROOT/$ann_path"
        else
          # Feature sidecar missing: keep the re-anchored base sidecar.
          cp "$new_base_ann" "$REPO_ROOT/$ann_path"
        fi
      else
        # Feature deleted its sidecar: keep the re-anchored base sidecar.
        cp "$new_base_ann" "$REPO_ROOT/$ann_path"
      fi
    else
      # Source file no longer exists on the base: the sidecar is stale.
      rm -f "$REPO_ROOT/$ann_path"
    fi
  done < <(git -C "$REPO_ROOT" diff --name-status "$sha^" "$sha" -- .git-shadow/annotations/)
}

# Stage and commit the [MEMORY] replay, recording the source SHA and patch-id.
finish_commit_memory() {
  local sha="$1"
  local subject memory_pid
  subject="$(git log -1 --format='%s' "$sha")"
  memory_pid="$(patch_id_for "$sha")"

  sync_stage_all
  if [[ -d "$REPO_ROOT/.git-shadow/annotations" ]]; then
    git -C "$REPO_ROOT" add -f .git-shadow/annotations/
  fi
  if [[ -d "$REPO_ROOT/.git-shadow/patches" ]]; then
    git -C "$REPO_ROOT" add -f .git-shadow/patches/
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
  if ! git -C "$REPO_ROOT" diff "$sha^" "$sha" -- .git-shadow/patches/ | git -C "$REPO_ROOT" apply --allow-empty; then
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
# Arguments: <sha...> — the only per-call varying input.
# Reads the finish-context globals; KEEP_WORKTREE/KEEP_BRANCHES are parsed
# flags (allowed globals).
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
    finish_save_phase memory-replay "$sha" "${remaining[*]}"

    if ! git -C "$REPO_ROOT" diff "$sha^" "$sha" -- . ':!.git-shadow/annotations/' ':!.git-shadow/patches/' | git -C "$REPO_ROOT" apply --3way --allow-empty; then
      local conflicted
      conflicted="$(conflicted_paths || true)"
      ui_error "Conflict applying [MEMORY] commit $sha to '$LOCAL_BASE'."
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
# Reads the finish-context globals.
finish_base_diff_commit() {
  sync_stage_all
  if index_dirty; then
    sync_commit "$LOCAL_BASE" "$PUBLIC_BASE" "$RANGE_START" "$RANGE_END" "$FEATURE_PUBLIC_BRANCH"
  fi
}

# Fresh base-diff phase: record pause state, apply the public net diff, and
# commit it via sync_apply_and_commit. On conflict the state stays written
# so --continue can resume.
# Arguments: <remaining_shas> — the space-separated unapplied [MEMORY] list,
# the only per-call varying input.
# Reads the finish-context globals; KEEP_WORKTREE/KEEP_BRANCHES are parsed
# flags (allowed globals).
finish_base_diff_apply() {
  local remaining_shas="$1"

  finish_save_phase base-diff "" "$remaining_shas"

  if ! sync_apply_and_commit "$LOCAL_BASE" "$PUBLIC_BASE" "$RANGE_START" "$RANGE_END" "$FEATURE_PUBLIC_BRANCH" >/dev/null; then
    local conflicted
    conflicted="$(conflicted_paths || true)"
    ui_error "Conflict applying public base net diff to '$LOCAL_BASE'."
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
# Arguments: [sha...] — remaining [MEMORY] commits, the only per-call varying
# input. Reads the finish-context globals.
finish_finalize() {
  local -a memory_shas=("$@")

  ui_shadow "Replaying [MEMORY] commits from '$FEATURE_LOCAL_BRANCH'"
  finish_collect_applied
  if [[ ${#memory_shas[@]} -gt 0 ]]; then
    if ! finish_memory_replay "${memory_shas[@]}"; then
      return 1
    fi
  fi

  local -a pids=()
  [[ -n "$PIDS_BASE" ]] && read -ra pids <<< "$PIDS_BASE"
  # Skip the final checkpoint when the local base tip already IS the
  # checkpoint covering RANGE_END — e.g. a retry after a post-checkpoint
  # cleanup failure. Any commit above it ([SYNC], replayed or recorded
  # [MEMORY]) makes the tip non-checkpoint and the checkpoint is written.
  local tip_cp tip_public _
  tip_cp="$(checkpoint_latest "$LOCAL_BASE")"
  tip_public=""
  if [[ -n "$tip_cp" && "$tip_cp" == "$(git rev-parse "$LOCAL_BASE")" ]]; then
    read -r tip_public _ <<< "$(checkpoint_parse "$tip_cp")"
  fi
  if [[ "$tip_public" != "$RANGE_END" ]]; then
    if ! sync_reanchor_and_checkpoint "$LOCAL_BASE" "$PUBLIC_BASE_HEAD" "${pids[@]}" >/dev/null; then
      return 1
    fi
  fi

  finish_resolve_worktree
  if ! finish_cleanup_feature; then
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

REPO_ROOT="$(repo_root)"

# Clean FINISH_TMP_DIR on exit. Patch overlay reapply is handled by
# `patches_transaction` around each mutating block; this trap must only
# manage the temporary directory so it is not clobbered by inner `trap 0`
# calls.
trap 'if [[ -n "${FINISH_TMP_DIR:-}" ]]; then rm -rf "$FINISH_TMP_DIR"; fi' EXIT

# V88: all feature finish modes refuse while a git-shadow sync is in progress.
if state_active "$(sync_state_file)"; then
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
  conflicted="$(conflicted_paths || true)"

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
    LOCAL_BASE="$FINISH_LOCAL_BASE"
  else
    current="$(current_branch)"
    if [[ -z "$current" || ! "$current" =~ ${LOCAL_SUFFIX}$ ]]; then
      ui_error "feature finish --mark-applied must be run from a @local branch or while a finish is paused."
      exit 1
    fi
    public_base="$(public_branch_from_any "$current")"
    LOCAL_BASE="${PUBLIC_BASE_BRANCH}${LOCAL_SUFFIX}"
    if [[ "$public_base" == "$PUBLIC_BASE_BRANCH" ]]; then
      ui_error "feature finish --mark-applied cannot be run on the local base."
      exit 1
    fi
    ensure_clean_repo
  fi

  _finish_mark_applied_body() {
    local target_sha="$MARK_APPLIED"
    local subject pid tree parent
    if [[ "$(current_branch)" != "$LOCAL_BASE" ]]; then
      finish_check_base_exclusivity \
        "$(public_branch_from_any "$LOCAL_BASE")" "$LOCAL_BASE" || return 1
      git checkout -q "$LOCAL_BASE" >/dev/null 2>&1 || {
        ui_error "Cannot checkout '$LOCAL_BASE'."
        return 1
      }
    fi

    subject="$(git log -1 --format='%s' "$target_sha")"
    pid="$(patch_id_for "$target_sha")"
    tree="$(git rev-parse "$LOCAL_BASE^{tree}")"
    parent="$(git rev-parse "$LOCAL_BASE")"

    local commit_args=(-m "$subject" -m "git-shadow-source-memory: $target_sha")
    if [[ -n "$pid" ]]; then
      commit_args+=(-m "git-shadow-source-pid: $pid")
    fi
    local new_sha
    new_sha="$(env GIT_SHADOW=1 git commit-tree "$tree" -p "$parent" "${commit_args[@]}")"
    git update-ref "refs/heads/$LOCAL_BASE" "$new_sha"

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
        "feature_public=$FINISH_FEATURE_PUBLIC" "feature_local=$FINISH_FEATURE_LOCAL" \
        "local_base=$LOCAL_BASE" "pre_finish_head=$new_sha" \
        "phase=$FINISH_PHASE" "conflicted_sha=$conflicted" \
        "remaining_shas=${remaining[*]}" "range_start=$FINISH_RANGE_START" \
        "range_end=$FINISH_RANGE_END" "pids=$FINISH_PIDS" \
        "keep_worktree=$keep_wt" "keep_branches=$keep_br"
      ui_ok "Recorded provenance for $target_sha and updated paused finish state."
    else
      ui_ok "Recorded provenance for $target_sha on '$LOCAL_BASE'."
    fi
    return 0
  }

  if ! patches_transaction _finish_mark_applied_body; then
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
    conflicted="$(conflicted_paths | paste -sd' ' - || true)"
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
    local -a memory_shas=()

    if [[ "$FINISH_PHASE" == "base-diff" ]]; then
      if ! finish_base_diff_commit; then
        return 1
      fi
      finish_clear_state
      read -ra memory_shas <<< "$FINISH_REMAINING_SHAS"
    elif [[ "$FINISH_PHASE" == "memory-replay" ]]; then
      # The conflicted [MEMORY] non-sidecar is already resolved in the working
      # tree. Re-run the sidecar merge from the resolved source and commit it,
      # unless --mark-applied has already recorded it (V102).
      finish_collect_applied
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

    if ! finish_finalize "${memory_shas[@]}"; then
      return 1
    fi
    return 0
  }

  # shellcheck disable=SC2034  # read by lib/patches.sh during the transaction
  PATCHES_REAPPLY_PAUSE=1
  if ! patches_transaction _finish_continue_body; then
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
    ui_info  "Commit or stash your work in '$(repo_root)', then run:"
    ui_info  "  git shadow feature finish $(public_branch_from_any "$CURRENT_BRANCH")"
    ui_info  "from a checkout of '$PUBLIC_BASE' or '$LOCAL_BASE'."
    ui_info  "Or remove the worktree manually: git worktree remove '$(repo_root)'"
    exit 1
  fi
  require_local_branch "feature finish"
  FEATURE_PUBLIC_BRANCH="$(public_branch_from_any "$CURRENT_BRANCH")"
  FEATURE_LOCAL_BRANCH="$CURRENT_BRANCH"
  if [[ "$FEATURE_PUBLIC_BRANCH" == "$PUBLIC_BASE" || "$FEATURE_LOCAL_BRANCH" == "$LOCAL_BASE" ]]; then
    ui_error "This command must be run from a feature branch, not from the base."
    exit 1
  fi
fi

for branch in "$FEATURE_PUBLIC_BRANCH" "$FEATURE_LOCAL_BRANCH" "$PUBLIC_BASE" "$LOCAL_BASE"; do
  if ! branch_exists "$branch"; then
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

_finish_normal_body() {
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
  # An ancestry check alone misses squash merges (a new commit whose tree
  # contains the feature changes but whose history does not include the
  # feature commits), so fall back to checking that the feature's public
  # tree is contained in the base tree.
  if ! git merge-base --is-ancestor "$FEATURE_PUBLIC_BRANCH" "$PUBLIC_BASE" \
     && ! check_tree_matches "$FEATURE_PUBLIC_BRANCH" "$PUBLIC_BASE" 2>/dev/null; then
    ui_error "Feature '$FEATURE_PUBLIC_BRANCH' is not merged into '$PUBLIC_BASE' (or '$PUBLIC_BASE' has since modified the same paths). Merge it first."
    return 1
  fi

  # ---------------------------------------------------------------------------
  # Compute the feature [MEMORY] list before the base diff.
  # ---------------------------------------------------------------------------
  local merge_base
  merge_base="$(git merge-base "$FEATURE_LOCAL_BRANCH" "$LOCAL_BASE")"
  local -a memory_shas=()
  local sha subject pid skip applied_sha applied_pid
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    subject="$(git log -1 --format='%s' "$sha")"
    if [[ "$subject" == "[MEMORY]"* ]]; then
      memory_shas+=("$sha")
    fi
  done < <(git rev-list --reverse "${merge_base}..$FEATURE_LOCAL_BRANCH")

  finish_collect_applied
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
  ui_shadow "Checkout '$LOCAL_BASE'"
  git checkout -q "$LOCAL_BASE" >/dev/null 2>&1

  local latest_cp cp_public
  latest_cp="$(checkpoint_latest "$LOCAL_BASE")"
  if [[ -z "$latest_cp" ]]; then
    ui_error "No checkpoint found on '$LOCAL_BASE'. Run 'git shadow base sync' first."
    return 1
  fi

  read -r cp_public _ <<< "$(checkpoint_parse "$latest_cp")"
  PRE_FINISH_HEAD="$(git rev-parse "$LOCAL_BASE")"
  RANGE_START="$cp_public"
  RANGE_END="$PUBLIC_BASE_HEAD"
  PIDS_BASE=""

  if [[ "$cp_public" != "$PUBLIC_BASE_HEAD" ]]; then
    if ! git merge-base --is-ancestor "$cp_public" "$PUBLIC_BASE_HEAD"; then
      ui_error "Public base '$PUBLIC_BASE' has moved non-fast-forward from the local checkpoint."
      return 1
    fi

    # V14: skip the base net diff when the local base already contains the public
    # base tree (only local-only additions differ).
    if git diff-tree --no-renames -r "$PUBLIC_BASE_HEAD" "$PRE_FINISH_HEAD" | awk '$5 != "A" {exit 1}'; then
      :
    else
      PIDS_BASE="$(sync_patch_ids "$cp_public" "$PUBLIC_BASE_HEAD" | tr '\n' ' ' | sed 's/ $//')"
      if ! finish_base_diff_apply "${memory_shas[*]}"; then
        return 1
      fi
    fi
  fi

  if ! finish_finalize "${memory_shas[@]}"; then
    return 1
  fi
  return 0
}

# shellcheck disable=SC2034  # read by lib/patches.sh during the transaction
PATCHES_REAPPLY_PAUSE=1
if ! patches_transaction _finish_normal_body; then
  exit 1
fi

ui_ok "Feature finished successfully."
