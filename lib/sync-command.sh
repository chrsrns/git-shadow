#!/usr/bin/env bash
# -------------------------------------------------------------------
# Library: sync-command.sh
# Purpose: shared `git shadow (feature|base) sync` command flow.
# -------------------------------------------------------------------

# Run the full `git shadow feature sync` or `git shadow base sync` command.
#
# Usage: sync_command_run <mode> [--recover] [--continue|--abort]
#   mode is `feature` or `base`.
sync_command_run() {
  local mode="$1"
  shift

  if [[ "$mode" != "feature" && "$mode" != "base" ]]; then
    ui_error "Unknown sync mode: $mode"
    return 1
  fi

  local label="${mode^}"

  usage() {
    cat <<EOF
Usage: git shadow $mode sync [--recover] [--continue|--abort]
EOF
  }

  local RECOVER=0
  local CONTINUE=0
  local ABORT=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --recover)  RECOVER=1  ;;
      --continue) CONTINUE=1 ;;
      --abort)    ABORT=1    ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        ui_error "Unknown option: $1"
        usage
        return 1
        ;;
    esac
    shift
  done

  if [[ $CONTINUE -eq 1 && $ABORT -eq 1 ]]; then
    ui_error "--continue and --abort are mutually exclusive."
    return 1
  fi

  enter_project '.'

  # ---------------------------------------------------------------------------
  # --abort
  # ---------------------------------------------------------------------------
  if [[ $ABORT -eq 1 ]]; then
    if ! sync_load_state; then
      ui_error "No sync in progress."
      return 1
    fi
    if [[ "$SYNC_MODE" != "$mode" ]]; then
      ui_error "A sync is in progress, but it is not a $mode sync (mode=$SYNC_MODE)."
      return 1
    fi
    git checkout -q "$SYNC_LOCAL_BRANCH" >/dev/null 2>&1 || true
    git reset --hard "$SYNC_LOCAL_HEAD"
    sync_clear_state
    ui_ok "$label sync aborted."
    return 0
  fi

  # ---------------------------------------------------------------------------
  # --continue
  # ---------------------------------------------------------------------------
  if [[ $CONTINUE -eq 1 ]]; then
    if ! sync_load_state; then
      ui_error "No sync in progress."
      return 1
    fi
    if [[ "$SYNC_MODE" != "$mode" ]]; then
      ui_error "A sync is in progress, but it is not a $mode sync (mode=$SYNC_MODE)."
      return 1
    fi
    if sync_has_conflicts; then
      ui_error "Working tree still has unresolved conflicts. Resolve them and run --continue."
      return 1
    fi
    if ! sync_tree_changed; then
      ui_error "No resolved changes to commit. Resolve the conflicts and add them."
      return 1
    fi

    sync_commit "$SYNC_LOCAL_BRANCH" "$SYNC_PUBLIC_BRANCH" "$SYNC_CHECKPOINT_PUBLIC" "$SYNC_TARGET_PUBLIC"

    # Re-anchor local annotation sidecars to the updated source.
    annotations_reanchor_all_commit

    local new_local_head
    new_local_head="$(git rev-parse "$SYNC_LOCAL_BRANCH")"
    _new_checkpoint="$(checkpoint_create "$SYNC_TARGET_PUBLIC" "$new_local_head" $SYNC_PIDS)"
    sync_clear_state
    ui_ok "$label sync continued."
    return 0
  fi

  # ---------------------------------------------------------------------------
  # Validate environment for a new sync
  # ---------------------------------------------------------------------------
  ensure_clean_repo

  local local_branch
  local_branch="$(current_branch)"
  if [[ -z "$local_branch" ]]; then
    ui_error "Unable to determine current branch."
    return 1
  fi

  if [[ ! "$local_branch" =~ ${LOCAL_SUFFIX}$ ]]; then
    ui_error "$mode sync must be run from a branch ending with '${LOCAL_SUFFIX}'."
    return 1
  fi

  # Feature mode refuses to sync the local base branch.
  if [[ "$mode" == "feature" ]]; then
    local local_base_branch="${PUBLIC_BASE_BRANCH}${LOCAL_SUFFIX}"
    if [[ "$local_branch" == "$local_base_branch" ]]; then
      ui_error "'git shadow feature sync' is for feature shadow branches, not the local base branch '$local_base_branch'."
      return 1
    fi
  fi

  local public_branch
  public_branch="$(public_branch_from_any "$local_branch")"
  if ! git show-ref --verify --quiet "refs/heads/$public_branch"; then
    ui_error "Public branch does not exist: $public_branch"
    return 1
  fi

  # ---------------------------------------------------------------------------
  # Normal flow
  # ---------------------------------------------------------------------------
  local latest_cp
  latest_cp="$(checkpoint_latest "$local_branch")"
  if [[ -z "$latest_cp" ]]; then
    if [[ "$mode" == "base" ]]; then
      # No checkpoint yet: create an initial one.
      local public_head
      public_head="$(git rev-parse "$public_branch")"
      local local_head
      local_head="$(git rev-parse "$local_branch")"
      _new_checkpoint="$(checkpoint_create "$public_head" "$local_head")"
      ui_ok "Created initial checkpoint for '$local_branch'."
      return 0
    fi
    ui_error "No checkpoint found on '$local_branch'. Run 'git shadow feature start' or create one."
    return 1
  fi

  local cp_public cp_local cp_pids
  cp_public="$(checkpoint_public "$latest_cp")"
  cp_local="$(checkpoint_local "$latest_cp")"
  cp_pids="$(checkpoint_pids "$latest_cp")"

  local public_head local_head
  public_head="$(git rev-parse "$public_branch")"
  local_head="$(git rev-parse "$local_branch")"

  if [[ "$cp_public" == "$public_head" ]]; then
    _new_checkpoint="$(checkpoint_create "$public_head" "$local_head" $cp_pids)"
    ui_ok "$label '$local_branch' is already up to date."
    return 0
  fi

  local diff_start="$cp_public"

  if ! git merge-base --is-ancestor "$cp_public" "$public_head"; then
    if [[ $RECOVER -eq 0 ]]; then
      ui_error "Public branch '$public_branch' has moved non-fast-forward from the checkpoint. Run 'git shadow $mode sync --recover' or 'git shadow re-anchor $local_branch'."
      return 1
    fi

    ui_warn "Attempting to recover $mode sync from patch-id list."
    local pids_file
    pids_file="$(mktemp)"
    # shellcheck disable=SC2064
    trap 'rm -f "$pids_file"' RETURN
    printf '%s\n' $cp_pids | tr ' ' '\n' | grep -v '^$' > "$pids_file" || true

    local new_ancestor
    if ! new_ancestor="$(sync_recover_ancestor "$public_head" "$pids_file")"; then
      ui_error "Unable to recover: no checkpointed patch-id found in the new public history. Run 'git shadow re-anchor $local_branch'."
      return 1
    fi

    if [[ "$new_ancestor" == "$public_head" ]]; then
      _new_checkpoint="$(checkpoint_create "$public_head" "$local_head" $cp_pids)"
      ui_ok "$label '$local_branch' is already up to date (recovered)."
      return 0
    fi

    diff_start="$new_ancestor"
  fi

  # Collect patch-ids of the public commits in the sync range.
  local pids=""
  local pid
  for pid in $(sync_patch_ids "$diff_start" "$public_head"); do
    if [[ -n "$pid" ]]; then
      pids="$pids $pid"
    fi
  done
  pids="${pids# }"

  # Apply net diff to the local branch.
  if ! sync_apply_range "$diff_start" "$public_head"; then
    sync_save_state "$mode" "$public_branch" "$local_branch" "$cp_public" "$cp_local" "$public_head" "$local_head" "$pids"
    ui_error "Conflict applying $mode net diff. Resolve and run 'git shadow $mode sync --continue', or '--abort'."
    return 1
  fi

  git add -A -- . ':(exclude).git-shadow.env'

  if sync_tree_changed; then
    sync_commit "$local_branch" "$public_branch" "$diff_start" "$public_head"
  fi

  # Re-anchor local annotation sidecars to the updated source.
  annotations_reanchor_all_commit

  new_local_head="$(git rev-parse "$local_branch")"
  _new_checkpoint="$(checkpoint_create "$public_head" "$new_local_head" $pids)"
  ui_ok "$label '$local_branch' synced with '$public_branch'."
}
