#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/publish.sh
# Purpose: publish public commits from a @local feature branch to the
#          corresponding public feature branch using the diff-sync model.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

enter_project '.'

if finish_state_active; then
  ui_error "A feature finish is in progress. Resolve it before running 'feature publish'."
  exit 1
fi

ensure_clean_repo

CURRENT_BRANCH="$(current_branch)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  ui_error "Unable to determine current branch."
  exit 1
fi

if [[ ! "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
  ui_error "feature publish must be run from a branch ending with '${LOCAL_SUFFIX}'."
  exit 1
fi

PUBLIC_BRANCH="$(public_branch_from_any "$CURRENT_BRANCH")"
if ! git show-ref --verify --quiet "refs/heads/$PUBLIC_BRANCH"; then
  ui_error "Public feature branch does not exist: $PUBLIC_BRANCH"
  exit 1
fi

# Find the latest checkpoint on the local branch.
LATEST_CP="$(checkpoint_latest "$CURRENT_BRANCH")"
if [[ -z "$LATEST_CP" ]]; then
  ui_error "No checkpoint found on '$CURRENT_BRANCH'. Run 'git shadow feature sync' first."
  exit 1
fi

CP_PUBLIC="$(checkpoint_public "$LATEST_CP")"
CP_LOCAL="$(checkpoint_local "$LATEST_CP")"

# The public branch HEAD must be the checkpointed public SHA.
PUBLIC_HEAD="$(git rev-parse "$PUBLIC_BRANCH")"
if [[ "$PUBLIC_HEAD" != "$CP_PUBLIC" ]]; then
  ui_error "Public branch '$PUBLIC_BRANCH' has moved since the last checkpoint. Run 'git shadow feature sync' first."
  exit 1
fi

# Run the diff-based check pass, replay public commits onto a temp branch, and
# compare the replayed tree to the local tree.  On success, the first line of
# output is the temp branch name; the remaining lines are the public commits.
PIDS=""
LOCAL_HEAD_BEFORE="$(git rev-parse "$CURRENT_BRANCH")"

replay_output=""
if ! replay_output="$(publish_replay_and_head "$PUBLIC_BRANCH" "$CURRENT_BRANCH" "$CP_PUBLIC" "$CP_LOCAL")"; then
  ui_error "Check pass failed; '$CURRENT_BRANCH' cannot be published to '$PUBLIC_BRANCH'."
  exit 1
fi

if [[ -z "$replay_output" ]]; then
  ui_info "No publishable commits. '$PUBLIC_BRANCH' is already up to date."
  exit 0
fi

PUBLISH_TMP_BRANCH="$(head -n1 <<< "$replay_output")"
PUBLIC_COMMITS="$(tail -n +2 <<< "$replay_output")"
NEW_PUBLIC_HEAD="$(git rev-parse "$PUBLISH_TMP_BRANCH")"

# Guard: the replayed public tree must not contain local-only artifacts.
if ! guard_tree "$NEW_PUBLIC_HEAD"; then
  git branch -D "$PUBLISH_TMP_BRANCH" >/dev/null 2>&1 || true
  ui_error "Publication aborted due to leaked local-only markers."
  exit 1
fi

# Fast-forward the public branch to the already-replayed head.
if ! git update-ref "refs/heads/$PUBLIC_BRANCH" "$NEW_PUBLIC_HEAD" "$CP_PUBLIC"; then
  git branch -D "$PUBLISH_TMP_BRANCH" >/dev/null 2>&1 || true
  ui_error "Could not update public branch '$PUBLIC_BRANCH' (it may have moved)."
  exit 1
fi

git branch -D "$PUBLISH_TMP_BRANCH" >/dev/null 2>&1 || true

while IFS= read -r sha; do
  if [[ -z "$sha" ]]; then
    continue
  fi
  pid=""
  if ! pid="$(patch_id_for "$sha")"; then
    ui_error "Could not compute patch-id for commit $sha during publish."
    exit 1
  fi
  if [[ -n "$pid" ]]; then
    PIDS="$PIDS $pid"
  fi
done <<< "$PUBLIC_COMMITS"

PIDS="${PIDS# }"

_new_checkpoint="$(checkpoint_create "$NEW_PUBLIC_HEAD" "$LOCAL_HEAD_BEFORE" $PIDS)"

ui_ok "Published to '$PUBLIC_BRANCH'."
