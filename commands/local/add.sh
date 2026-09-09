#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow local add <path>
# Purpose: capture the working-tree-vs-HEAD delta for a public-tracked
#          file as a .git-shadow/patches sidecar and commit it as [MEMORY].
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

enter_project '.'
require_local_branch
patches_require_no_paused_op

PATH_ARG="${1:-}"
if [[ -z "$PATH_ARG" ]]; then
  ui_error "Usage: git shadow local add <path>"
  exit 1
fi

# Normalize to a repository-relative path.
RELPATH="${PATH_ARG#./}"
if [[ -z "$RELPATH" ]]; then
  ui_error "Invalid path: $PATH_ARG"
  exit 1
fi

if ! patches_store "$RELPATH"; then
  exit 1
fi

patches_commit "$RELPATH"
ui_ok "Stored local patch for '$RELPATH'."
