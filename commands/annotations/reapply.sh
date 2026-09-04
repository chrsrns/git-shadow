#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow annotations reapply [path]
# Purpose: write stored markers back into the working tree as unstaged
#          changes. Resets each matching source file to the committed
#          clean version before inserting markers.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

enter_project '.'

CURRENT_BRANCH="$(current_branch)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  ui_error "Unable to determine current branch."
  exit 1
fi

if [[ ! "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
  ui_error "git shadow annotations reapply must be run from a branch ending with '${LOCAL_SUFFIX}'."
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PATH_ARG="${1:-}"

# Build the list of target source files.
declare -a TARGETS=()
if [[ -n "$PATH_ARG" ]]; then
  # Normalize relative to repo root.
  if [[ "$PATH_ARG" == .git-shadow/annotations/* ]]; then
    TARGETS+=("${PATH_ARG#.git-shadow/annotations/}")
  elif [[ -f ".git-shadow/annotations/$PATH_ARG" ]]; then
    TARGETS+=("$PATH_ARG")
  else
    ui_error "No annotation sidecar found for $PATH_ARG"
    exit 1
  fi
else
  if [[ -d .git-shadow/annotations ]]; then
    while IFS= read -r ann_file; do
      relpath="${ann_file#.git-shadow/annotations/}"
      relpath="${relpath#/}"
      [[ -n "$relpath" ]] && TARGETS+=("$relpath")
    done < <(find .git-shadow/annotations -type f)
  fi
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  ui_info "No annotation records to reapply."
  exit 0
fi

# Helper: determine if a working-tree file has non-marker changes vs HEAD.
_has_non_marker_changes() {
  local relpath="$1"
  # No diff -> no changes.
  if git diff --quiet -- "$relpath" 2>/dev/null; then
    return 1
  fi

  # Extract markers from the working tree and compare the clean result to HEAD.
  local wt_tmp clean_tmp meta_tmp
  wt_tmp="$TMP_DIR/wt_${relpath////_}"
  clean_tmp="$TMP_DIR/clean_${relpath////_}"
  meta_tmp="$TMP_DIR/meta_${relpath////_}"
  if [[ -f "$relpath" ]]; then
    cp "$relpath" "$wt_tmp"
  else
    # File missing from working tree but modified in index: treat as non-marker.
    return 0
  fi

  if [[ ! -s "$wt_tmp" ]]; then
    # File missing from index but modified in working tree: treat as non-marker.
    return 0
  fi

  # Reapply only the marker patterns; for this check we want to see if the
  # working tree differs from HEAD after marker removal.
  if annotations_extract "$wt_tmp" "$clean_tmp" "$TMP_DIR/discard.md" "$meta_tmp" 2>/dev/null; then
    : > "$TMP_DIR/discard.md"
  else
    return 0
  fi

  local head_tmp
  head_tmp="$TMP_DIR/head_${relpath////_}"
  if git show "HEAD:$relpath" > "$head_tmp" 2>/dev/null; then
    if diff -q "$head_tmp" "$clean_tmp" >/dev/null 2>&1; then
      # Only marker changes.
      return 1
    fi
  fi
  return 0
}

for relpath in "${TARGETS[@]}"; do
  ann_path=".git-shadow/annotations/$relpath"

  if [[ ! -f "$ann_path" ]]; then
    ui_warn "No annotation sidecar for $relpath"
    continue
  fi

  if _has_non_marker_changes "$relpath"; then
    ui_error "$relpath has unstaged non-marker changes. Commit or discard them first."
    exit 1
  fi

  head_tmp="$TMP_DIR/head_${relpath////_}"
  if ! git show "HEAD:$relpath" > "$head_tmp" 2>/dev/null; then
    # Source file not in HEAD; likely a new file. We cannot reapply to a base
    # that does not exist, so warn and continue.
    ui_warn "Source $relpath not found in HEAD; skipping reapply."
    continue
  fi

  if ! annotations_reapply "$head_tmp" "$ann_path" "$relpath"; then
    ui_error "Failed to reapply annotations to $relpath"
    exit 1
  fi
  ui_shadow "Reapplied markers to $relpath"
done

ui_ok "Annotations reapplied."
