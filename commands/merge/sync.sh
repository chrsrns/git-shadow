#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: merge/sync.sh
# Purpose: merge the public feature branch into its @local shadow branch,
#          preserving local comments during conflict resolution.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/merge.sh"

enter_project "."
ensure_clean_repo

CURRENT_BRANCH="$(current_branch)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  ui_error "Unable to determine current branch."
  exit 1
fi

if [[ ! "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
  ui_error "git shadow merge sync must be run from a shadow branch (ending with '$LOCAL_SUFFIX')."
  ui_step "Current branch: $CURRENT_BRANCH"
  exit 1
fi

PUBLIC_BRANCH="$(public_branch_from_any "$CURRENT_BRANCH")"

if ! git show-ref --verify --quiet "refs/heads/$PUBLIC_BRANCH"; then
  ui_error "Public branch does not exist: $PUBLIC_BRANCH"
  exit 1
fi

ui_shadow "Merging '$PUBLIC_BRANCH' into '$CURRENT_BRANCH'..."

sync_message="$(printf "$SYNC_MERGE_MESSAGE_TEMPLATE" "$PUBLIC_BRANCH" "$CURRENT_BRANCH")"

if ! GIT_EDITOR=true git merge --no-edit -m "$sync_message" "$PUBLIC_BRANCH"; then
  resolve_merge_conflicts "ours"
fi

ui_ok "Merge sync completed: '$CURRENT_BRANCH' now includes '$PUBLIC_BRANCH'."
