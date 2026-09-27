#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow local diff [path]
# Purpose: print the stored .git-shadow/patches sidecar for a path,
#          or all sidecars if no path is given.
# -------------------------------------------------------------------

_GS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/help.sh"
if gs_help_requested -- "$@"; then
  echo "Usage: git shadow local diff [path] [<ignored>...]"
  exit 0
fi

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/common.sh"

enter_project '.'
patches_require_no_paused_op

PATH_ARG="${1:-}"

if [[ -n "$PATH_ARG" ]]; then
  RELPATH="${PATH_ARG#./}"
  SIDECAR="$(patches_sidecar_for "$RELPATH")"
  if [[ ! -f "$SIDECAR" ]]; then
    ui_error "No sidecar found for '$RELPATH'."
    exit 1
  fi
  cat "$SIDECAR"
else
  if [[ ! -d "$PATCHES_DIR" ]]; then
    ui_info "No local patches."
    exit 0
  fi

  sidecar=""
  relpath=""
  found=0
  while IFS= read -r -d '' sidecar; do
    found=1
    relpath="$(patches_relpath_from_sidecar "$sidecar")"
    printf -- '--- %s ---\n' "$relpath"
    cat "$sidecar"
  done < <(find "$PATCHES_DIR" -type f -name '*.patch' -print0 2>/dev/null | sort -z)

  if [[ $found -eq 0 ]]; then
    ui_info "No local patches."
  fi
fi
