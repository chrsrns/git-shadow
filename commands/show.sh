#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow show --with-annotations <file>
# Purpose: render an annotated view of a committed source file without
#          touching the working tree.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

enter_project '.'

CURRENT_BRANCH="$(current_branch)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  ui_error "Unable to determine current branch."
  exit 1
fi

if [[ ! "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
  ui_error "git shadow show must be run from a branch ending with '${LOCAL_SUFFIX}'."
  exit 1
fi

WITH_ANNOTATIONS=false
FILE=""

for arg in "$@"; do
  case "$arg" in
    --with-annotations) WITH_ANNOTATIONS=true ;;
    --color) ;; # accepted, but output stays plain in this version
    -*) ui_error "Unknown option: $arg"; exit 1 ;;
    *)
      if [[ -z "$FILE" ]]; then
        FILE="$arg"
      else
        ui_error "Only one file may be shown at a time."
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$FILE" ]]; then
  ui_error "Usage: git shadow show --with-annotations <file>"
  exit 1
fi

if ! $WITH_ANNOTATIONS; then
  ui_error "Usage: git shadow show --with-annotations <file>"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source_tmp="$TMP_DIR/source"
if ! git show "HEAD:$FILE" > "$source_tmp" 2>/dev/null; then
  ui_error "File not found in HEAD: $FILE"
  exit 1
fi

ann_path=".git-shadow/annotations/$FILE"
if git rev-parse "HEAD:$ann_path" >/dev/null 2>&1; then
  ann_tmp="$TMP_DIR/annotations"
  git show "HEAD:$ann_path" > "$ann_tmp" 2>/dev/null || true
  if ! annotations_render "$source_tmp" "$ann_tmp"; then
    ui_error "Failed to render annotations for $FILE"
    exit 1
  fi
else
  cat "$source_tmp"
fi
