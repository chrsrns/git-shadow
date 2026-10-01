#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow local rm [--revert] <path>
# Purpose: remove the .git-shadow/patches sidecar for a path.
#          With --revert, reverse-apply the overlay before removing it.
# -------------------------------------------------------------------

_GS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/help.sh"
if gs_help_requested -- "$@"; then
  echo "Usage: git shadow local rm [--revert] <path> [<ignored>...]"
  exit 0
fi

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/common.sh"

enter_project '.'
require_local_branch
patches_require_no_paused_op

REVERT=0
if [[ "${1:-}" == "--revert" ]]; then
  REVERT=1
  shift
fi

PATH_ARG="${1:-}"
if [[ -z "$PATH_ARG" ]]; then
  ui_error "Usage: git shadow local rm [--revert] <path>"
  exit 1
fi

if ! RELPATH="$(patches_normalize_path "$PATH_ARG")"; then
  ui_error "Path escapes the worktree toplevel: $PATH_ARG"
  exit 1
fi

REPO_ROOT="$(patches_repo_root)"
SIDECAR="$(patches_sidecar_for "$RELPATH")"
SIDECAR_ABS="$REPO_ROOT/$SIDECAR"
if [[ ! -f "$SIDECAR_ABS" ]]; then
  ui_error "No sidecar found for '$RELPATH'."
  exit 1
fi

if [[ $REVERT -eq 1 ]]; then
  # Reverse-apply the overlay only if it is currently applied. The reverted
  # source is left in the working tree; it is never staged — a [MEMORY]
  # commit must not modify public-tracked files.
  if git -C "$REPO_ROOT" diff --quiet HEAD -- "$RELPATH" 2>/dev/null; then
    ui_info "Patch for '$RELPATH' is not applied; skipping revert."
  elif git -C "$REPO_ROOT" apply -R --check < "$SIDECAR_ABS" 2>/dev/null; then
    git -C "$REPO_ROOT" apply -R < "$SIDECAR_ABS"
  else
    ui_warn "Could not reverse-apply overlay for '$RELPATH'."
  fi
fi

# Stage the sidecar deletion.
if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$SIDECAR" >/dev/null 2>&1; then
  git -C "$REPO_ROOT" rm -q -- "$SIDECAR"
else
  rm -f "$SIDECAR_ABS"
fi

if ! git -C "$REPO_ROOT" diff --cached --quiet; then
  env GIT_SHADOW=1 git -C "$REPO_ROOT" commit -m "[MEMORY] remove local patch for $RELPATH" -- "$SIDECAR" >/dev/null
fi

rmdir "$(dirname "$SIDECAR_ABS")" 2>/dev/null || true

ui_ok "Removed local patch for '$RELPATH'."
