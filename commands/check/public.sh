#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: check/public.sh
# Purpose: audit a public branch for files that came only from [MEMORY].
#
# Usage: git shadow check public [<public-branch>]
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

enter_project '.'
ensure_clean_repo

if [[ $# -gt 0 ]]; then
  PUBLIC_BRANCH="$1"
  shift
else
  PUBLIC_BRANCH="$(current_branch)"
fi

if [[ -z "$PUBLIC_BRANCH" ]]; then
  ui_error "Unable to determine current branch."
  exit 1
fi

if [[ "$PUBLIC_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
  ui_error "check public requires a public branch, not a shadow branch."
  exit 1
fi

LOCAL_BRANCH="${PUBLIC_BRANCH}${LOCAL_SUFFIX}"

if ! git show-ref --verify --quiet "refs/heads/$PUBLIC_BRANCH"; then
  ui_error "Public branch does not exist: $PUBLIC_BRANCH"
  exit 1
fi

if ! git show-ref --verify --quiet "refs/heads/$LOCAL_BRANCH"; then
  ui_error "Shadow branch does not exist: $LOCAL_BRANCH"
  exit 1
fi

LATEST_CP="$(checkpoint_latest "$LOCAL_BRANCH")"
if [[ -z "$LATEST_CP" ]]; then
  ui_error "No checkpoint found on '$LOCAL_BRANCH'."
  exit 1
fi

CP_PUBLIC="$(checkpoint_public "$LATEST_CP")"
CP_LOCAL="$(checkpoint_local "$LATEST_CP")"
PUBLIC_HEAD="$(git rev-parse "$PUBLIC_BRANCH")"
LOCAL_HEAD="$(git rev-parse "$LOCAL_BRANCH")"

if git ls-tree -r --name-only "$PUBLIC_HEAD" | grep -q '^\.git-shadow/annotations'; then
  ui_error "Public branch '$PUBLIC_BRANCH' contains .git-shadow/annotations/ paths."
  exit 1
fi

UNPROMOTED=()

while IFS= read -r file; do
  [[ -z "$file" ]] && continue

  # Public blob
  public_blob="$(git rev-parse "$PUBLIC_HEAD:$file")" || continue

  # Skip files not present in the local tree (public-only addition)
  if ! git cat-file -e "$LOCAL_HEAD:$file" 2>/dev/null; then
    continue
  fi

  local_blob="$(git rev-parse "$LOCAL_HEAD:$file")" || continue

  # If public and local differ, it is a normal divergence, not an unpromoted
  # [MEMORY] file.
  if [[ "$public_blob" != "$local_blob" ]]; then
    continue
  fi

  # If the public blob matches the checkpoint public blob, nothing changed.
  if git cat-file -e "$CP_PUBLIC:$file" 2>/dev/null; then
    cp_blob="$(git rev-parse "$CP_PUBLIC:$file")"
    if [[ "$public_blob" == "$cp_blob" ]]; then
      continue
    fi
  fi

  # Find the most recent local commit after the checkpoint that touched this file.
  last_subject="$(git log -1 --format='%s' "${CP_LOCAL}..${LOCAL_HEAD}" -- "$file" 2>/dev/null)" || true
  if [[ -n "$last_subject" && "$last_subject" == "[MEMORY]"* ]]; then
    UNPROMOTED+=("$file")
  fi
done < <(git ls-tree -r --name-only "$PUBLIC_HEAD")

if [[ ${#UNPROMOTED[@]} -gt 0 ]]; then
  ui_error "Unpromoted files found on '$PUBLIC_BRANCH' (came from [MEMORY] on '$LOCAL_BRANCH'):"
  for f in "${UNPROMOTED[@]}"; do
    echo "  $f"
  done
  exit 1
fi

ui_ok "No unpromoted files on '$PUBLIC_BRANCH'."
