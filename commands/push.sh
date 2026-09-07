#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: push.sh
# Purpose: push a public branch with GIT_SHADOW=1 so hooks allow it.
#
# Usage: git shadow push <public-branch>
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

if [[ $# -eq 0 ]]; then
  ui_error "Missing public branch name."
  echo "Usage: git shadow push <public-branch>" >&2
  exit 1
fi

BRANCH="$1"

if [[ "$BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
  ui_error "Cannot push a shadow branch with this command. Use: git shadow push <public-branch>"
  exit 1
fi

if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  ui_error "Branch does not exist locally: $BRANCH"
  exit 1
fi

enter_project '.'
ensure_clean_repo

UPSTREAM="$(git for-each-ref --format='%(upstream:short)' "refs/heads/$BRANCH")"
if [[ -z "$UPSTREAM" ]]; then
  mapfile -t REMOTES < <(git remote)
  if [[ "${#REMOTES[@]}" -eq 0 ]]; then
    ui_error "No remotes configured; cannot auto-set upstream for '$BRANCH'."
    exit 1
  fi
  if [[ "${#REMOTES[@]}" -gt 1 ]]; then
    ui_error "No upstream configured for '$BRANCH' and multiple remotes exist: ${REMOTES[*]}. Pick one with 'GIT_SHADOW=1 git push -u <remote> $BRANCH'."
    exit 1
  fi
  REMOTE="${REMOTES[0]}"
  ui_git "No upstream for '$BRANCH'; pushing to sole remote '$REMOTE'"
  GIT_SHADOW=1 git push -u "$REMOTE" "$BRANCH"
  ui_ok "Pushed '$BRANCH' to $REMOTE."
  exit 0
fi

REMOTE="${UPSTREAM%%/*}"
ui_git "Pushing '$BRANCH' to $REMOTE"
GIT_SHADOW=1 git push "$REMOTE" "$BRANCH"
ui_ok "Pushed '$BRANCH' to $REMOTE."
