#!/usr/bin/env bash

# -------------------------------------------------------------------
# Library: patches.sh
# Purpose: local patch sidecar helpers for local-only edits to
#          public-tracked files.
#
# Sidecar path: .git-shadow/patches/<relpath>.patch
# Stored as a unified diff of the working tree vs HEAD for <relpath>.
# -------------------------------------------------------------------

PATCHES_DIR=".git-shadow/patches"

# Abort if a paused sync or finish state exists.
patches_require_no_paused_op() {
  local sync_file finish_file
  sync_file="$(sync_state_file)"
  finish_file="$(finish_state_file)"
  if [[ -f "$sync_file" ]]; then
    ui_error "A sync is in progress. Resolve or run 'git shadow feature sync --abort' / 'git shadow base sync --abort'."
    exit 1
  fi
  if [[ -f "$finish_file" ]]; then
    ui_error "A finish is in progress. Resolve or run 'git shadow feature finish --abort'."
    exit 1
  fi
}

# Print the sidecar path for a repository-relative source path.
patches_sidecar_for() {
  local relpath="${1#./}"
  if [[ -n "$relpath" ]]; then
    printf '%s/%s.patch\n' "$PATCHES_DIR" "$relpath"
  fi
}

# Print the source relpath for a sidecar file path (or empty if not a sidecar).
patches_relpath_from_sidecar() {
  local sidecar="$1"
  sidecar="${sidecar#./$PATCHES_DIR/}"
  sidecar="${sidecar#$PATCHES_DIR/}"
  if [[ -n "$sidecar" && "$sidecar" == *.patch ]]; then
    printf '%s\n' "${sidecar%.patch}"
  fi
}

# List all existing sidecar relpaths, one per line, sorted.
patches_list_sidecars() {
  if [[ ! -d "$PATCHES_DIR" ]]; then
    return 0
  fi
  local sidecar
  find "$PATCHES_DIR" -type f -name '*.patch' -print0 2>/dev/null | \
    while IFS= read -r -d '' sidecar; do
      patches_relpath_from_sidecar "$sidecar"
    done | sort
}

# Store the current working-tree-vs-HEAD delta for <relpath> as a sidecar.
#
# Usage: patches_store <relpath>
# Returns 0 on success, 1 on empty diff, binary file, deletion, new file
# (not public-tracked), or staged changes.
patches_store() {
  local relpath="${1#./}"
  if [[ -z "$relpath" ]]; then
    return 1
  fi

  # The path must already be tracked by the public branch (in HEAD).
  if ! git rev-parse "HEAD:$relpath" >/dev/null 2>&1; then
    ui_error "patches_store: '$relpath' is not public-tracked. [MEMORY] commits are for new local files."
    return 1
  fi

  # Reject deleted files.
  if [[ ! -e "$relpath" ]]; then
    ui_error "patches_store: '$relpath' has been deleted. Delete sidecars are not supported."
    return 1
  fi

  # Reject paths with staged changes.
  if ! git diff --cached --quiet -- "$relpath" 2>/dev/null; then
    ui_error "patches_store: '$relpath' has staged changes. Stage only public work, then re-run."
    return 1
  fi

  # Reject binary files.
  local numstat
  numstat="$(git diff --numstat HEAD -- "$relpath" 2>/dev/null | head -1)"
  set -- $numstat
  if [[ "$1" = "-" && "$2" = "-" ]]; then
    ui_error "patches_store: '$relpath' is binary. Binary patches are not supported."
    return 1
  fi

  local sidecar
  sidecar="$(patches_sidecar_for "$relpath")"
  mkdir -p "$(dirname "$sidecar")"

  git diff --no-ext-diff --no-color HEAD -- "$relpath" > "$sidecar"
  if [[ ! -s "$sidecar" ]]; then
    rm -f "$sidecar"
    rmdir "$(dirname "$sidecar")" 2>/dev/null || true
    ui_error "patches_store: no working-tree delta for '$relpath'."
    return 1
  fi

  return 0
}

# Internal: return 0 when the working tree file for <relpath> equals
# HEAD:<relpath> plus the stored patch applied.
_patches_path_is_applied_overlay() {
  local relpath="$1"
  local sidecar
  sidecar="$(patches_sidecar_for "$relpath")"
  [[ -f "$sidecar" ]] || return 1

  # HEAD must contain the file.
  if ! git rev-parse "HEAD:$relpath" >/dev/null 2>&1; then
    return 1
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap 'rm -rf "$tmp_dir"; trap - RETURN' RETURN

  mkdir -p "$tmp_dir/$(dirname "$relpath")"
  if ! git show "HEAD:$relpath" > "$tmp_dir/$relpath" 2>/dev/null; then
    return 1
  fi
  cp "$sidecar" "$tmp_dir/patch.patch"

  if ! git -C "$tmp_dir" apply patch.patch 2>/dev/null; then
    return 1
  fi

  diff -q "$tmp_dir/$relpath" "$relpath" >/dev/null 2>&1
}

# Return 0 iff every dirty tracked path has a stored sidecar and the file
# content equals HEAD plus the patch applied. Staged changes and untracked
# non-ignored files always return 1.
patches_overlay_clean() {
  local line status path
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    status="${line:0:2}"
    path="${line:3}"

    # Untracked non-ignored file.
    if [[ "$status" == "??" ]]; then
      # Local-only config/setup files that are normally gitignored may be
      # present while the repo is being configured; treat them as clean.
      if [[ "$path" == .git-shadow.env || "$path" == */.git-shadow.env ||
           "$path" == .gitignore || "$path" == */.gitignore ]]; then
        continue
      fi
      # A registered worktree directory looks like an untracked path in the
      # main checkout; it is not worktree dirt we care about here.
      local abs_path
      abs_path="$(_worktree_abs "$path")"
      if _worktree_list_paths | grep -qxF "$abs_path" 2>/dev/null; then
        continue
      fi
      return 1
    fi

    # Staged change.
    if [[ "${status:0:1}" != " " && "${status:0:1}" != "?" ]]; then
      return 1
    fi

    # Unstaged change.
    if [[ "${status:1:1}" != " " && "${status:1:1}" != "?" ]]; then
      if ! _patches_path_is_applied_overlay "$path"; then
        return 1
      fi
    fi
  done < <(git status --porcelain --untracked-files=all --no-renames 2>/dev/null)

  return 0
}

# Reverse-apply every stored sidecar from the working tree.
# Prints the relpath of each stripped sidecar.
patches_strip() {
  local sidecar relpath
  while IFS= read -r -d '' sidecar; do
    relpath="$(patches_relpath_from_sidecar "$sidecar")"
    [[ -z "$relpath" ]] && continue

    # Already at HEAD (orphan or not-applied): nothing to strip.
    if git diff --quiet HEAD -- "$relpath" 2>/dev/null; then
      continue
    fi

    if ! git apply -R --check < "$sidecar" 2>/dev/null; then
      ui_warn "patches_strip: cannot reverse-apply patch for '$relpath'."
      continue
    fi

    git apply -R < "$sidecar"
    printf '%s\n' "$relpath"
  done < <(find "$PATCHES_DIR" -type f -name '*.patch' -print0 2>/dev/null)
}

# Re-apply every stored sidecar to the working tree. Uses an exact/3way/
# relaxed-context ladder. On final failure the file is restored to HEAD and
# the sidecar is kept as an orphan. On degraded success the sidecar is
# rewritten as a diff against the new HEAD and committed as [MEMORY].
patches_reapply() {
  local sidecar relpath
  local -a rewritten=()

  while IFS= read -r -d '' sidecar; do
    relpath="$(patches_relpath_from_sidecar "$sidecar")"
    [[ -z "$relpath" ]] && continue

    # Skip if already applied.
    if _patches_path_is_applied_overlay "$relpath"; then
      continue
    fi

    # Skip if the source file no longer exists in HEAD (public-tracked).
    if ! git rev-parse "HEAD:$relpath" >/dev/null 2>&1; then
      ui_warn "patches_reapply: source '$relpath' no longer in HEAD; skipping."
      continue
    fi

    local applied=0
    local method=""

    # Exact apply.
    if git apply --check < "$sidecar" 2>/dev/null; then
      git apply < "$sidecar"
      applied=1
      method="exact"
    # 3-way.
    elif git apply --3way < "$sidecar" 2>/dev/null; then
      if [[ -n $(git ls-files -u "$relpath" 2>/dev/null) ]]; then
        # 3-way produced conflicts; restore to HEAD and continue to relaxed/orphan.
        git checkout -q HEAD -- "$relpath" 2>/dev/null || \
          git show "HEAD:$relpath" > "$relpath" 2>/dev/null
      else
        applied=1
        method="3way"
      fi
    # Relaxed context (but never zero; zero context can match the wrong file).
    else
      local ctx
      for ctx in 2 1; do
        if git apply -C"$ctx" --check < "$sidecar" 2>/dev/null; then
          git apply -C"$ctx" < "$sidecar"
          applied=1
          method="relaxed C$ctx"
          break
        fi
      done
    fi

    if [[ $applied -eq 0 ]]; then
      # Orphan: restore to HEAD, warn, keep the sidecar.
      ui_warn "patches_reapply: cannot reapply patch for '$relpath' (orphan). Restore with 'git shadow local add'."
      if git checkout -q HEAD -- "$relpath" 2>/dev/null; then
        :
      elif git show "HEAD:$relpath" > "$relpath" 2>/dev/null; then
        :
      fi
      continue
    fi

    # Degraded reapply: rewrite the sidecar so overlay checks and subtraction
    # stay consistent against the new HEAD.
    if [[ "$method" != "exact" ]]; then
      git diff --no-ext-diff --no-color HEAD -- "$relpath" > "$sidecar"
      rewritten+=("$relpath")
    fi
  done < <(find "$PATCHES_DIR" -type f -name '*.patch' -print0 2>/dev/null)

  if [[ ${#rewritten[@]} -gt 0 ]]; then
    patches_commit "[MEMORY] reapply local patches" "${rewritten[@]}"
  fi
}

# Remove the stored patch from staged content.
#
# Usage: patches_subtract <relpath> <staged_file> <out>
# Returns 0 and writes the clean content to <out> if the sidecar can be
# reverse-applied. Returns 1 if the sidecar is not present in <staged_file>.
patches_subtract() {
  local relpath="${1#./}"
  local staged_file="$2"
  local out="$3"

  local sidecar
  sidecar="$(patches_sidecar_for "$relpath")"
  if [[ ! -f "$sidecar" ]]; then
    # No sidecar for this path; no subtraction needed.
    cp "$staged_file" "$out"
    return 0
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap 'rm -rf "$tmp_dir"; trap - RETURN' RETURN

  mkdir -p "$tmp_dir/$(dirname "$relpath")"
  cp "$staged_file" "$tmp_dir/$relpath"
  cp "$sidecar" "$tmp_dir/patch.patch"

  if ! git -C "$tmp_dir" apply -R --check patch.patch 2>/dev/null; then
    return 1
  fi

  git -C "$tmp_dir" apply -R patch.patch
  cp "$tmp_dir/$relpath" "$out"
}

# Force-add sidecars and create a [MEMORY] commit.
#
# Usage: patches_commit [message] <relpath>...
# Default message: [MEMORY] local patches
patches_commit() {
  local msg="[MEMORY] local patches"
  if [[ "${1:-}" == "[MEMORY]"* ]]; then
    # Optional [MEMORY] message supplied first.
    msg="$1"
    shift
  fi

  if [[ $# -eq 0 ]]; then
    return 1
  fi

  local relpath sidecar added=0
  for relpath in "$@"; do
    sidecar="$(patches_sidecar_for "$relpath")"
    if [[ -f "$sidecar" ]]; then
      git add -f -- "$sidecar"
      added=1
    else
      # Sidecar was deleted (e.g. local rm); stage the deletion if tracked.
      if git ls-files --error-unmatch "$sidecar" >/dev/null 2>&1; then
        git rm -q -- "$sidecar"
        added=1
      fi
    fi
  done

  if [[ $added -eq 0 ]]; then
    return 1
  fi

  if ! git diff --cached --quiet; then
    env GIT_SHADOW=1 git commit -m "$msg" >/dev/null
  fi
}
