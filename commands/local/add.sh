#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow local add <path>
# Purpose: capture the working-tree-vs-HEAD delta for a public-tracked
#          file as a .git-shadow/patches sidecar and commit it as [MEMORY].
# -------------------------------------------------------------------

_GS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/help.sh"
if gs_help_requested -- "$@"; then
  echo "Usage: git shadow local add <path> [<ignored>...]"
  exit 0
fi

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/common.sh"

enter_project '.'
require_local_branch
patches_require_no_paused_op

PATH_ARG="${1:-}"
if [[ -z "$PATH_ARG" ]]; then
  ui_error "Usage: git shadow local add <path>"
  exit 1
fi

# Normalize to a toplevel-relative path; reject paths escaping the worktree.
if ! RELPATH="$(patches_normalize_path "$PATH_ARG")"; then
  ui_error "Path escapes the worktree toplevel: $PATH_ARG"
  exit 1
fi

if ! patches_store "$RELPATH"; then
  exit 1
fi

patches_commit "$RELPATH"
ui_ok "Stored local patch for '$RELPATH'."
