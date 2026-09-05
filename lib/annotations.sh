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

# Normalize LOCAL_COMMENT_EXCLUDE patterns to an array.
_annotations_exclude_patterns() {
  local -a patterns=()
  if [[ -n "${LOCAL_COMMENT_EXCLUDE:-}" ]]; then
    # shellcheck disable=SC2206
    patterns=($LOCAL_COMMENT_EXCLUDE)
  fi
  printf '%s\n' "${patterns[@]}"
}

# Check whether a repository-relative path matches the LOCAL_COMMENT_EXCLUDE
# patterns. Uses Bash extglob semantics. Paths under .git-shadow/annotations/
# are never excluded for LOCAL_COMMENT_PATTERN_TRIPLE.
annotations_triple_excluded() {
  local relpath="$1"

  # Paths under .git-shadow/annotations/ are local sidecars, not source.
  if [[ "$relpath" == .git-shadow/annotations/* ]]; then
    return 1
  fi

  # No patterns means nothing is excluded.
  if [[ -z "${LOCAL_COMMENT_EXCLUDE:-}" ]]; then
    return 1
  fi

  # Patterns are Bash extended globs. Disable pathname expansion so patterns
  # like .git-shadow/!(annotations) are not expanded to concrete files before
  # case can match them; keep extglob on so the patterns work in case.
  local pattern
  local old_flags="$-"
  local extglob_restore
  extglob_restore="$(shopt -p extglob)"
  set -f
  shopt -s extglob
  # shellcheck disable=SC2206
  for pattern in $LOCAL_COMMENT_EXCLUDE; do
    case "$relpath" in
      $pattern) 
        if [[ "$old_flags" != *f* ]]; then
          set +f
        fi
        $extglob_restore
        return 0 
        ;;
    esac
  done
  if [[ "$old_flags" != *f* ]]; then
    set +f
  fi
  $extglob_restore
  return 1
}

# Internal helper: run the Python extract subcommand.
_annotations_run_extract() {
  local source="$1"
  local clean_out="$2"
  local records_out="$3"
  local meta_out="$4"
  local existing_ann="$5"

  local triple="${LOCAL_COMMENT_PATTERN_TRIPLE:-^\\s*///}"
  local localpat="${LOCAL_COMMENT_PATTERN_LOCAL:-^\\s*// @local}"
  local extract_triple=1
  local extract_local=1

  if [[ "${LOCAL_COMMENT_EXCLUDE_TRIPLE:-0}" == "1" ]]; then
    extract_triple=0
  fi

  local existing_arg=""
  if [[ -n "$existing_ann" && -f "$existing_ann" ]]; then
    existing_arg="--existing-annotations $existing_ann"
  fi

  python3 "$ANNOTATIONS_PY" extract \
    --source "$source" \
    --pattern-triple "$triple" \
    --pattern-local "$localpat" \
    --extract-triple "$extract_triple" \
    --extract-local "$extract_local" \
    --clean-out "$clean_out" \
    --records-out "$records_out" \
    --meta-out "$meta_out" \
    $existing_arg
}

# Extract local markers from a source file.
#
# Usage: annotations_extract <source> <clean_out> <records_out> <meta_out> [existing_ann]
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

  if ! _annotations_python_available; then
    echo "python3 is required for annotation extraction" >&2
    return 1
  fi

  _annotations_run_extract "$source" "$clean_out" "$records_out" "$meta_out" "$existing_ann"
}

# Print the stable hunk key for a search block.
#
# Usage: annotations_key <search_file>
annotations_key() {
  local search_file="$1"
  if ! _annotations_python_available; then
    echo "python3 is required for annotation keying" >&2
    return 1
  fi
  python3 "$ANNOTATIONS_PY" key --search "$search_file"
}

# Render an annotated view of a source file to stdout.
#
# Usage: annotations_render <source> <annotations>
annotations_render() {
  local source="$1"
  local annotations="$2"
  if ! _annotations_python_available; then
    echo "python3 is required for annotation rendering" >&2
    return 1
  fi
  local triple="${LOCAL_COMMENT_PATTERN_TRIPLE:-^\\s*///}"
  local localpat="${LOCAL_COMMENT_PATTERN_LOCAL:-^\\s*// @local}"
  python3 "$ANNOTATIONS_PY" render \
    --source "$source" --annotations "$annotations" --output /dev/stdout \
    --pattern-triple "$triple" --pattern-local "$localpat"
}

# Re-apply annotations to a source file.
#
# Usage: annotations_reapply <source> <annotations> <output>
annotations_reapply() {
  local source="$1"
  local annotations="$2"
  local output="$3"
  if ! _annotations_python_available; then
    echo "python3 is required for annotation reapply" >&2
    return 1
  fi
  local triple="${LOCAL_COMMENT_PATTERN_TRIPLE:-^\\s*///}"
  local localpat="${LOCAL_COMMENT_PATTERN_LOCAL:-^\\s*// @local}"
  python3 "$ANNOTATIONS_PY" reapply \
    --source "$source" --annotations "$annotations" --output "$output" \
    --pattern-triple "$triple" --pattern-local "$localpat"
}

# Re-anchor annotations against a changed source file.
#
# Usage: annotations_reanchor <source> <annotations> <output>
annotations_reanchor() {
  local source="$1"
  local annotations="$2"
  local output="$3"
  if ! _annotations_python_available; then
    echo "python3 is required for annotation re-anchoring" >&2
    return 1
  fi
  local triple="${LOCAL_COMMENT_PATTERN_TRIPLE:-^\\s*///}"
  local localpat="${LOCAL_COMMENT_PATTERN_LOCAL:-^\\s*// @local}"
  python3 "$ANNOTATIONS_PY" reanchor \
    --source "$source" --annotations "$annotations" --output "$output" \
    --threshold "${ANNOTATION_FUZZY_THRESHOLD:-0.80}" \
    --pattern-triple "$triple" --pattern-local "$localpat"
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
  local warn_arg=""
  if [[ "${5:-}" == "--warn-differing" ]]; then
    warn_arg="--warn-differing"
  fi
  if ! _annotations_python_available; then
    echo "python3 is required for annotation merge" >&2
    return 1
  fi
  python3 "$ANNOTATIONS_PY" merge --base "$base" --feature "$feature" --output "$output" --mode "$mode" ${warn_arg:+$warn_arg}
}

# Re-anchor every tracked .git-shadow/annotations sidecar against the current
# HEAD source. Removes sidecars whose source file no longer exists. Stages
# changed/deleted sidecars in the index.
#
# Usage: annotations_reanchor_all
# Returns 0 after staging; the caller should check git diff --cached and
# commit sidecar updates if any.
annotations_reanchor_all() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local -a changed=()

  local sidecar source_path source_tmp ann_tmp new_tmp
  while IFS= read -r -d '' sidecar; do
    source_path="${sidecar#.git-shadow/annotations/}"
    [[ -z "$source_path" ]] && continue

    source_tmp="$tmp_dir/source_${source_path////_}"
    ann_tmp="$tmp_dir/ann_${sidecar////_}"
    new_tmp="$tmp_dir/new_${sidecar////_}"

    if git show "HEAD:$source_path" > "$source_tmp" 2>/dev/null; then
      # Skip binary files; they never have sidecars.
      if ! tr -d '\0' < "$source_tmp" | diff -q - "$source_tmp" >/dev/null 2>&1; then
        continue
      fi
      if git show "HEAD:$sidecar" > "$ann_tmp" 2>/dev/null; then
        : > "$new_tmp"
        if annotations_reanchor "$source_tmp" "$ann_tmp" "$new_tmp" 2>/dev/null; then
          if [[ ! -s "$new_tmp" ]]; then
            # Re-anchored sidecar is empty: remove it.
            if [[ -e "$sidecar" ]]; then
              git rm -q -- "$sidecar" 2>/dev/null || rm -f "$sidecar"
            fi
            changed+=("$sidecar")
          elif ! diff -q "$ann_tmp" "$new_tmp" >/dev/null 2>&1; then
            cp "$new_tmp" "$sidecar"
            git add -f -- "$sidecar"
            changed+=("$sidecar")
          fi
        fi
      fi
    else
      # Source file is gone: delete the orphaned sidecar.
      if [[ -e "$sidecar" ]]; then
        git rm -q -- "$sidecar" 2>/dev/null || rm -f "$sidecar"
      fi
      changed+=("$sidecar")
    fi
  done < <(git ls-tree -r -z --name-only HEAD -- .git-shadow/annotations/)

  rm -rf "$tmp_dir"
}

# Re-anchor all tracked sidecars and, if any changed, commit the updates as a
# local sidecar commit with the configured shadow commit prefix.
#
# Usage: annotations_reanchor_all_commit
annotations_reanchor_all_commit() {
  annotations_reanchor_all
  if ! git diff --cached --quiet; then
    env GIT_SHADOW=1 git commit -m "${SHADOW_COMMIT_PREFIX} re-anchor sidecars"
  fi
}
