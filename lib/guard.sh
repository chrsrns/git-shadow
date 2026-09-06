#!/usr/bin/env bash
# -------------------------------------------------------------------
# Library: guard.sh
# Purpose: scan staged files or a tree for local-only marker leakage.
# -------------------------------------------------------------------

# Determine whether a path matches LOCAL_COMMENT_EXCLUDE for triple scanning.
# This function is intentionally written with no external lib dependencies
# because it may be embedded into the generated pre-commit hook.
# Paths under .git-shadow/annotations/ are never excluded.
annotations_triple_excluded() {
  local relpath="$1"

  if [[ "$relpath" == .git-shadow/annotations/* ]]; then
    return 1
  fi

  if [[ -z "${LOCAL_COMMENT_EXCLUDE:-}" ]]; then
    return 1
  fi

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

# Scan the staged index for local marker leakage.
#
# Usage: guard_staged_files
#
# Reads LOCAL_COMMENT_PATTERN_TRIPLE, LOCAL_COMMENT_PATTERN_LOCAL, and
# LOCAL_COMMENT_EXCLUDE from the environment. No other lib dependencies.
# Returns 0 if clean, 1 and prints an error if a marker is found.
guard_staged_files() {
  local triple_pattern="${LOCAL_COMMENT_PATTERN_TRIPLE:-^\\s*///}"
  local local_pattern="${LOCAL_COMMENT_PATTERN_LOCAL:-^\\s*// @local}"

  local tmp_list
  tmp_list="$(mktemp -t git-shadow-guard-staged.XXXXXX)"
  # shellcheck disable=SC2064
  trap 'rm -f "$tmp_list"; trap - RETURN' RETURN

  git diff --cached --name-only --diff-filter=ACMRT > "$tmp_list" 2>/dev/null || true

  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue

    # Sidecar paths are local-only and never contain source markers.
    case "$path" in
      .git-shadow/annotations/*) continue ;;
    esac

    # Binary files cannot be scanned for marker lines.
    local numstat
    numstat="$(git diff --cached --numstat -- "$path" | head -1)"
    set -- $numstat
    [[ "$1" = "-" && "$2" = "-" ]] && continue

    # Decide whether to scan for the triple pattern.
    local check_triple=1
    if annotations_triple_excluded "$path"; then
      check_triple=0
    fi

    if [[ "$check_triple" = "1" ]]; then
      if git show :"$path" | grep -qE "$triple_pattern"; then
        echo "[git-shadow] Staged file $path contains local-only /// markers." >&2
        echo "Run 'git shadow commit' to split them into a [MEMORY] sidecar." >&2
        return 1
      fi
    fi

    if git show :"$path" | grep -qE "$local_pattern"; then
      echo "[git-shadow] Staged file $path contains local-only // @local markers." >&2
      echo "Run 'git shadow commit' to split them into a [MEMORY] sidecar." >&2
      return 1
    fi
  done < "$tmp_list"

  return 0
}

# Scan a tree for local marker leakage and .git-shadow/annotations/ paths.
#
# Usage: guard_tree <tree>
#
# Reads LOCAL_COMMENT_PATTERN_TRIPLE, LOCAL_COMMENT_PATTERN_LOCAL, and
# LOCAL_COMMENT_EXCLUDE from the environment. Returns 0 if clean, 1 and
# prints an error if a sidecar or marker is found.
guard_tree() {
  local tree="$1"
  local triple_pattern="${LOCAL_COMMENT_PATTERN_TRIPLE:-^\\s*///}"
  local local_pattern="${LOCAL_COMMENT_PATTERN_LOCAL:-^\\s*// @local}"

  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue

    if [[ "$path" == .git-shadow/annotations/* || "$path" == .git-shadow/annotations ]]; then
      echo "[git-shadow] Refusing to publish: public tree contains local-only path '$path'." >&2
      return 1
    fi

    local check_triple=1
    if annotations_triple_excluded "$path"; then
      check_triple=0
    fi

    if [[ "$check_triple" = "1" ]]; then
      if git grep -I -q -E "$triple_pattern" "$tree" -- "$path"; then
        echo "[git-shadow] Refusing to publish: '$path' contains /// local-only markers." >&2
        return 1
      fi
    fi

    if git grep -I -q -E "$local_pattern" "$tree" -- "$path"; then
      echo "[git-shadow] Refusing to publish: '$path' contains // @local markers." >&2
      return 1
    fi
  done < <(git ls-tree -r --name-only "$tree")

  return 0
}
