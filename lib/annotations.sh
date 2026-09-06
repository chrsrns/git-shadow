#!/usr/bin/env bash

# -------------------------------------------------------------------
# Library: annotations.sh
# Purpose: thin wrappers around lib/annotations.py for hunk-keyed
#          local comment extraction, rendering, re-anchoring, and merge.
# -------------------------------------------------------------------

# Ensure TOOLKIT_ROOT is set. When sourced from lib/common.sh, env.sh already
# sets it. When sourced independently, compute it from this file's location.
if [[ -z "${TOOLKIT_ROOT:-}" ]]; then
  TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

ANNOTATIONS_PY="$TOOLKIT_ROOT/lib/annotations.py"

# Return 0 if python3 is available, 1 otherwise.
_annotations_python_available() {
  command -v python3 >/dev/null 2>&1
}

# Internal helper: check python availability and run a Python subcommand with
# the configured pattern defaults. Only subcommands that need pattern defaults
# get --pattern-triple and --pattern-local appended.
_annotations_py() {
  local subcommand="$1"
  shift

  if ! _annotations_python_available; then
    echo "python3 is required for annotation $subcommand" >&2
    return 1
  fi

  local -a extra_args=()
  case "$subcommand" in
    extract|render|reapply|reanchor)
      extra_args+=(--pattern-triple "${LOCAL_COMMENT_PATTERN_TRIPLE:-^\\s*///}")
      extra_args+=(--pattern-local "${LOCAL_COMMENT_PATTERN_LOCAL:-^\\s*// @local}")
      ;;
  esac

  python3 "$ANNOTATIONS_PY" "$subcommand" "$@" "${extra_args[@]}"
}

# Extract local markers from a source file.
#
# Usage: annotations_extract <source> <clean_out> <records_out> <meta_out> [existing_ann] [skip_triple]
#
# Writes:
#   <clean_out>     source with active marker lines removed
#   <records_out>   markdown records for .git-shadow/annotations/<relpath>
#   <meta_out>      key=value pairs: has_markers, record_count, marker_only
annotations_extract() {
  local source="$1"
  local clean_out="$2"
  local records_out="$3"
  local meta_out="$4"
  local existing_ann="${5:-}"
  local skip_triple="${6:-0}"

  local -a existing_arg=()
  if [[ -n "$existing_ann" && -f "$existing_ann" ]]; then
    existing_arg=(--existing-annotations "$existing_ann")
  fi

  _annotations_py extract \
    --source "$source" \
    --clean-out "$clean_out" \
    --records-out "$records_out" \
    --meta-out "$meta_out" \
    --extract-triple "$((skip_triple ? 0 : 1))" \
    --extract-local "1" \
    "${existing_arg[@]}"
}

# Print the stable hunk key for a search block.
#
# Usage: annotations_key <search_file>
annotations_key() {
  _annotations_py key --search "$1"
}

# Render an annotated view of a source file to stdout.
#
# Usage: annotations_render <source> <annotations>
annotations_render() {
  _annotations_py render \
    --source "$1" --annotations "$2" --output /dev/stdout
}

# Re-apply annotations to a source file.
#
# Usage: annotations_reapply <source> <annotations> <output>
annotations_reapply() {
  _annotations_py reapply \
    --source "$1" --annotations "$2" --output "$3"
}

# Re-anchor annotations against a changed source file.
#
# Usage: annotations_reanchor <source> <annotations> <output>
annotations_reanchor() {
  _annotations_py reanchor \
    --source "$1" --annotations "$2" --output "$3" \
    --threshold "${ANNOTATION_FUZZY_THRESHOLD:-0.80}"
}

# Merge feature annotation records into base records.
#
# Usage: annotations_merge <base> <feature> <output> [mode] [--warn-differing]
#   mode is 'append' (default) or 'replace'.
#   Pass --warn-differing as the 5th argument to emit warnings when a feature
#   replace section differs from all base replace sections for the same hunk.
annotations_merge() {
  local base="$1"
  local feature="$2"
  local output="$3"
  local mode="${4:-append}"
  local -a args=(--base "$base" --feature "$feature" --output "$output" --mode "$mode")
  if [[ "${5:-}" == "--warn-differing" ]]; then
    args+=(--warn-differing)
  fi
  _annotations_py merge "${args[@]}"
}

# Re-anchor every tracked .git-shadow/annotations sidecar against the current
# HEAD source. Removes sidecars whose source file no longer exists. Stages
# changed/deleted sidecars in the index.
#
# Usage: annotations_reanchor_all
# Returns 0 after staging; the caller should check git diff --cached and
# commit sidecar updates if any. Returns 1 if any re-anchor step fails.
annotations_reanchor_all() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local -a changed=()
  local failed=0

  local sidecar source_path source_tmp ann_tmp new_tmp
  while IFS= read -r -d '' sidecar; do
    source_path="${sidecar#.git-shadow/annotations/}"
    [[ -z "$source_path" ]] && continue

    source_tmp="$tmp_dir/source_${source_path////_}"
    ann_tmp="$tmp_dir/ann_${sidecar////_}"
    new_tmp="$tmp_dir/new_${sidecar////_}"

    if git cat-file -e "HEAD:$source_path" 2>/dev/null; then
      if ! git show "HEAD:$source_path" > "$source_tmp" 2>/dev/null; then
        ui_error "annotations_reanchor_all: cannot read source '$source_path' at HEAD"
        failed=1
        break
      fi
      # Skip binary files; they never have sidecars.
      if ! tr -d '\0' < "$source_tmp" | diff -q - "$source_tmp" >/dev/null 2>&1; then
        continue
      fi
      if git cat-file -e "HEAD:$sidecar" 2>/dev/null; then
        if ! git show "HEAD:$sidecar" > "$ann_tmp" 2>/dev/null; then
          ui_error "annotations_reanchor_all: cannot read sidecar '$sidecar' at HEAD"
          failed=1
          break
        fi
        : > "$new_tmp"
        if ! annotations_reanchor "$source_tmp" "$ann_tmp" "$new_tmp"; then
          ui_error "annotations_reanchor_all: cannot re-anchor sidecar '$sidecar' against '$source_path'"
          failed=1
          break
        fi
        if [[ ! -s "$new_tmp" ]]; then
          # Re-anchored sidecar is empty: remove it.
          if [[ -e "$sidecar" ]]; then
            if ! git rm -q -- "$sidecar" 2>/dev/null && ! rm -f "$sidecar"; then
              ui_error "annotations_reanchor_all: cannot remove empty sidecar '$sidecar'"
              failed=1
              break
            fi
          fi
          changed+=("$sidecar")
        elif ! diff -q "$ann_tmp" "$new_tmp" >/dev/null 2>&1; then
          cp "$new_tmp" "$sidecar"
          git add -f -- "$sidecar"
          changed+=("$sidecar")
        fi
      else
        # The sidecar exists in the index/working tree but not at HEAD.
        # Re-anchoring is impossible; treat it as an error.
        ui_error "annotations_reanchor_all: sidecar '$sidecar' is not in HEAD"
        failed=1
        break
      fi
    else
      # Source file is gone: delete the orphaned sidecar.
      if [[ -e "$sidecar" ]]; then
        if ! git rm -q -- "$sidecar" 2>/dev/null && ! rm -f "$sidecar"; then
          ui_error "annotations_reanchor_all: cannot remove orphaned sidecar '$sidecar'"
          failed=1
          break
        fi
      fi
      changed+=("$sidecar")
    fi
  done < <(git ls-tree -r -z --name-only HEAD -- .git-shadow/annotations/)

  rm -rf "$tmp_dir"
  return $failed
}

# Re-anchor all tracked sidecars and, if any changed, commit the updates as a
# local sidecar commit with the configured shadow commit prefix.
#
# Usage: annotations_reanchor_all_commit
# Returns 1 if re-anchoring failed; otherwise creates a commit only when staged
# sidecars changed.
annotations_reanchor_all_commit() {
  if ! annotations_reanchor_all; then
    return 1
  fi
  if ! git diff --cached --quiet; then
    env GIT_SHADOW=1 git commit -m "${SHADOW_COMMIT_PREFIX} re-anchor sidecars"
  fi
}
