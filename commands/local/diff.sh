#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow local diff [path]
# Purpose: print the stored .git-shadow/patches sidecar for a path,
#          or all sidecars if no path is given.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

enter_project '.'

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
