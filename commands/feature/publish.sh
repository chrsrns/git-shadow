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

# Run the diff-based check pass and collect public commits.
PIDS=""
PUBLIC_COMMITS=""
check_output=""
if ! check_output="$(check_pass "$PUBLIC_BRANCH" "$CURRENT_BRANCH" "$CP_PUBLIC" "$CP_LOCAL")"; then
  ui_error "Check pass failed; '$CURRENT_BRANCH' cannot be published to '$PUBLIC_BRANCH'."
  exit 1
fi
while IFS= read -r sha; do
  if [[ -z "$sha" ]]; then
    continue
  fi
  PUBLIC_COMMITS="$PUBLIC_COMMITS $sha"
  pid="$(patch_id_for "$sha")"
  if [[ -n "$pid" ]]; then
    PIDS="$PIDS $pid"
  fi
done <<< "$check_output"

PUBLIC_COMMITS="${PUBLIC_COMMITS# }"
PIDS="${PIDS# }"

if [[ -z "$PUBLIC_COMMITS" ]]; then
  ui_info "No publishable commits. '$PUBLIC_BRANCH' is already up to date."
  exit 0
fi

# Replay public commits onto the public branch.
LOCAL_HEAD_BEFORE="$(git rev-parse "$CURRENT_BRANCH")"
git checkout -q "$PUBLIC_BRANCH"

publish_failed=0
for sha in $PUBLIC_COMMITS; do
  if ! git cherry-pick --quiet "$sha"; then
    publish_failed=1
    break
  fi
done

if [[ $publish_failed -eq 1 ]]; then
  git cherry-pick --abort 2>/dev/null || true
  git reset --hard "$CP_PUBLIC"
  git checkout -q "$CURRENT_BRANCH"
  ui_error "Replay failed while publishing to '$PUBLIC_BRANCH'. Public branch has been reset."
  exit 1
fi

NEW_PUBLIC_HEAD="$(git rev-parse "$PUBLIC_BRANCH")"

# Guard: the replayed public tree must not contain local-only artifacts.
if ! guard_tree "$NEW_PUBLIC_HEAD"; then
  git reset --hard "$CP_PUBLIC"
  git checkout -q "$CURRENT_BRANCH"
  ui_error "Publication aborted due to leaked local-only markers."
  exit 1
fi

# Return to the local branch and create a checkpoint.
git checkout -q "$CURRENT_BRANCH"
_new_checkpoint="$(checkpoint_create "$NEW_PUBLIC_HEAD" "$LOCAL_HEAD_BEFORE" $PIDS)"

ui_ok "Published to '$PUBLIC_BRANCH'."
