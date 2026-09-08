#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow local rm [--revert] <path>
# Purpose: remove the .git-shadow/patches sidecar for a path.
#          With --revert, reverse-apply the overlay before removing it.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

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

RELPATH="${PATH_ARG#./}"
if [[ -z "$RELPATH" ]]; then
  ui_error "Invalid path: $PATH_ARG"
  exit 1
fi

SIDECAR="$(patches_sidecar_for "$RELPATH")"
if [[ ! -f "$SIDECAR" ]]; then
  ui_error "No sidecar found for '$RELPATH'."
  exit 1
fi

if [[ $REVERT -eq 1 ]]; then
  # Reverse-apply the overlay only if it is currently applied.
  if ! git diff --quiet HEAD -- "$RELPATH" 2>/dev/null; then
    if git apply -R --check < "$SIDECAR" 2>/dev/null; then
      git apply -R < "$SIDECAR"
    else
      ui_warn "Could not reverse-apply overlay for '$RELPATH'."
    fi
  fi
  # Stage the reverted source.
  git add -f -- "$RELPATH"
fi

# Stage the sidecar deletion.
if git ls-files --error-unmatch "$SIDECAR" >/dev/null 2>&1; then
  git rm -q -- "$SIDECAR"
else
  rm -f "$SIDECAR"
fi

if ! git diff --cached --quiet; then
  env GIT_SHADOW=1 git commit -m "[MEMORY] remove local patch for $RELPATH" -- "$RELPATH" "$SIDECAR" >/dev/null
fi

rmdir "$(dirname "$SIDECAR")" 2>/dev/null || true

ui_ok "Removed local patch for '$RELPATH'."
