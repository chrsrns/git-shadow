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

# Global transaction state.
PATCHES_TX_DEPTH=0
PATCHES_TX_SAVED_TRAP=""
PATCHES_TX_REAPPLIED=0

# -------------------------------------------------------------------
# Transaction helpers
# -------------------------------------------------------------------

# Internal EXIT handler for patches_transaction.
_patches_tx_exit() {
  if [[ "$PATCHES_TX_REAPPLIED" -eq 0 && "$PATCHES_TX_DEPTH" -gt 0 ]]; then
    PATCHES_REAPPLY_PAUSE=0
    patches_reapply >/dev/null 2>&1 || true
    PATCHES_TX_REAPPLIED=1
  fi
  if [[ -n "${PATCHES_TX_SAVED_TRAP:-}" ]]; then
    eval "$PATCHES_TX_SAVED_TRAP" || true
  fi
}

# Run a callback while the patch sidecar lifecycle is protected.
#
# Usage: patches_transaction <callback> [args...]
# Strip every stored sidecar, call <callback> [args...], and re-apply sidecars
# on every return or exit path. Saves/restores the existing EXIT trap and uses
# a per-process depth counter so nested transactions do not double-strip or
# double-reapply.
patches_transaction() {
  local callback="$1"
  shift

  PATCHES_TX_REAPPLIED=0
  PATCHES_TX_DEPTH=$((PATCHES_TX_DEPTH + 1))

  if [[ "$PATCHES_TX_DEPTH" -gt 1 ]]; then
    "$callback" "$@"
    return $?
  fi

  # Outermost transaction: save the existing EXIT trap and install ours.
  PATCHES_TX_SAVED_TRAP="$(trap -p EXIT 2>/dev/null || true)"
  trap '_patches_tx_exit' EXIT

  local status=0
  local cb_status=0
  if ! patches_strip >/dev/null; then
    status=1
  else
    if "$callback" "$@"; then
      cb_status=0
    else
      cb_status=$?
    fi
    if [[ "$PATCHES_TX_REAPPLIED" -eq 0 ]]; then
      if ! patches_reapply >/dev/null 2>&1; then
        status=$?
      fi
      PATCHES_TX_REAPPLIED=1
    fi
    if [[ "$status" -eq 0 ]]; then
      status=$cb_status
    fi
  fi

  # Restore the previous EXIT trap.
  if [[ -n "$PATCHES_TX_SAVED_TRAP" ]]; then
    eval "$PATCHES_TX_SAVED_TRAP" || true
  else
    trap - EXIT
  fi
  PATCHES_TX_DEPTH=0
  return "$status"
}

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

  # The path must be public-tracked: present in HEAD and introduced by at
  # least one non-[MEMORY] commit. On @local, HEAD alone is not the oracle —
  # [MEMORY]-only files live there too and must be rejected.
  if ! git rev-parse "HEAD:$relpath" >/dev/null 2>&1; then
    ui_error "patches_store: '$relpath' is not public-tracked. [MEMORY] commits are for new local files."
    return 1
  fi

  local add_subjects
  add_subjects="$(git log --diff-filter=A --format='%s' HEAD -- "$relpath" 2>/dev/null)"
  if [[ -z "$add_subjects" ]] || ! grep -qv '^\[MEMORY\]' <<< "$add_subjects"; then
    ui_error "patches_store: '$relpath' exists only via [MEMORY] commits. [MEMORY] commits are for new local files."
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

# Check whether every stored sidecar applies cleanly to HEAD. With --orphan,
# also verify the working tree equals HEAD plus the patch.
#
# Usage: patches_check [--orphan]
# Prints failing sidecar paths to stdout; returns 0 when all pass.
patches_check() {
  local check_applied=0
  if [[ "${1:-}" == "--orphan" ]]; then
    check_applied=1
    shift
  fi

  local sidecar relpath
  local -a sidecars=()
  while IFS= read -r -d '' sidecar; do
    sidecars+=("$sidecar")
  done < <(find "$PATCHES_DIR" -type f -name '*.patch' -print0 2>/dev/null)

  if [[ ${#sidecars[@]} -eq 0 ]]; then
    return 0
  fi

  local issues=0
  local probe
  probe="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap 'rm -rf "$probe"; trap - RETURN' RETURN

  for sidecar in "${sidecars[@]}"; do
    relpath="$(patches_relpath_from_sidecar "$sidecar")"
    [[ -z "$relpath" ]] && continue

    rm -rf "$probe/tree"
    mkdir -p "$probe/tree/$(dirname "$relpath")"
    if ! git show "HEAD:$relpath" > "$probe/tree/$relpath" 2>/dev/null; then
      printf '%s\t%s\n' "$sidecar" "source missing from HEAD"
      issues=1
      continue
    fi
    cp "$sidecar" "$probe/tree/patch.patch"
    if ! git -C "$probe/tree" apply --check patch.patch >/dev/null 2>&1; then
      printf '%s\t%s\n' "$sidecar" "cannot apply to HEAD"
      issues=1
      continue
    fi

    if [[ "$check_applied" -eq 1 ]]; then
      if ! _patches_path_is_applied_overlay "$relpath"; then
        printf '%s\t%s\n' "$sidecar" "not applied to working tree"
        issues=1
      fi
    fi
  done

  return "$issues"
}

# Reverse-apply every stored sidecar from the working tree.
# Prints the relpath of each stripped sidecar.
# Aborts (returns 1) if any sidecar is neither at HEAD nor can be
# reverse-applied, leaving the working tree untouched.
patches_strip() {
  local sidecar relpath
  local -a strip_relpaths=()
  local -a strip_sidecars=()

  while IFS= read -r -d '' sidecar; do
    relpath="$(patches_relpath_from_sidecar "$sidecar")"
    [[ -z "$relpath" ]] && continue

    # Skip sidecars for paths currently involved in a merge conflict; the
    # working tree content is not in a state we can reverse-apply from.
    if [[ -n $(git ls-files -u "$relpath" 2>/dev/null) ]]; then
      continue
    fi

    # Only strip sidecars that are currently applied to the working tree.
    if ! _patches_path_is_applied_overlay "$relpath"; then
      continue
    fi

    if ! git apply -R --check < "$sidecar" 2>/dev/null; then
      ui_warn "patches_strip: cannot reverse-apply patch for '$relpath'."
      return 1
    fi

    strip_relpaths+=("$relpath")
    strip_sidecars+=("$sidecar")
  done < <(find "$PATCHES_DIR" -type f -name '*.patch' -print0 2>/dev/null)

  local i
  for i in "${!strip_relpaths[@]}"; do
    relpath="${strip_relpaths[$i]}"
    sidecar="${strip_sidecars[$i]}"
    git apply -R < "$sidecar"
    printf '%s\n' "$relpath"
  done
}

# Re-apply every stored sidecar to the working tree. Uses an exact/3way/
# relaxed-context ladder. On degraded success the sidecar is rewritten as a
# diff against the new HEAD and committed as [MEMORY].
# When PATCHES_REAPPLY_PAUSE=1, a 3-way conflict leaves conflict markers and
# the function returns 1 (for resumable operations to pause); otherwise an
# orphan sidecar is restored to HEAD and warned.
patches_reapply() {
  local sidecar relpath
  local -a rewritten=()
  local -a orphans=()

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
    local pause="${PATCHES_REAPPLY_PAUSE:-0}"

    # Exact apply.
    if git apply --check < "$sidecar" 2>/dev/null; then
      git apply < "$sidecar"
      applied=1
      method="exact"
    else
      # 3-way. Keep a copy of the pre-3way content: a failed or conflicted
      # attempt can leave unmerged index entries and conflict markers, which
      # must be undone before the relaxed ladder without touching the real
      # worktree content the relaxed apply is meant to work against.
      local pre_3way
      pre_3way="$(mktemp)"
      cp "$relpath" "$pre_3way" 2>/dev/null || true

      if git apply --3way < "$sidecar" 2>/dev/null; then
        if [[ -z $(git ls-files -u "$relpath" 2>/dev/null) ]]; then
          applied=1
          method="3way"
        elif [[ "$pause" -eq 1 ]]; then
          # Resumable operation: leave 3-way conflict markers and pause.
          rm -f "$pre_3way"
          orphans+=("$relpath")
          continue
        else
          # 3-way conflict but not pausing: reset and fall through to relaxed.
          git reset -q HEAD -- "$relpath" 2>/dev/null || true
          cp "$pre_3way" "$relpath" 2>/dev/null || true
        fi
      else
        git reset -q HEAD -- "$relpath" 2>/dev/null || true
        cp "$pre_3way" "$relpath" 2>/dev/null || true
      fi
      rm -f "$pre_3way"

      # Relaxed context (but never zero; zero context can match the wrong file).
      if [[ $applied -eq 0 ]]; then
        local ctx
        for ctx in 2 1; do
          if git apply -C"$ctx" --check < "$sidecar" 2>/dev/null; then
            git apply -C"$ctx" < "$sidecar"
            applied=1
            method="relaxed -C$ctx"
            break
          fi
        done
      fi
    fi

    if [[ $applied -eq 0 ]]; then
      if [[ "$pause" -eq 1 ]]; then
        orphans+=("$relpath")
        continue
      fi
      # Orphan: restore to HEAD, warn, keep the sidecar.
      ui_warn "patches_reapply: cannot reapply patch for '$relpath' (orphan). Restore with 'git shadow local add'."
      if git checkout -q HEAD -- "$relpath" 2>/dev/null; then
        :
      elif git show "HEAD:$relpath" > "$relpath" 2>/dev/null; then
        :
      fi
      continue
    fi

    # Degraded reapply: log the method, then rewrite the sidecar so overlay
    # checks and subtraction stay consistent against the new HEAD.
    if [[ "$method" != "exact" ]]; then
      ui_warn "patches_reapply: '$relpath' reapplied via degraded method ($method); sidecar refreshed."
      git diff --no-ext-diff --no-color HEAD -- "$relpath" > "$sidecar"
      rewritten+=("$relpath")
    fi
  done < <(find "$PATCHES_DIR" -type f -name '*.patch' -print0 2>/dev/null)

  if [[ ${#rewritten[@]} -gt 0 ]]; then
    patches_commit "[MEMORY] reapply local patches" "${rewritten[@]}"
  fi

  if [[ ${#orphans[@]} -gt 0 ]]; then
    for relpath in "${orphans[@]}"; do
      ui_warn "patches_reapply: cannot reapply patch for '$relpath' (orphan); paused for resolution."
    done
    return 1
  fi
}

# Remove the stored patch from staged content.
#
# Usage: patches_subtract <relpath> <staged_file> <out>
# Decides from the staged blob alone: if the sidecar would apply to the
# staged content, the patch is absent and the content passes through
# unchanged; if it reverse-applies, the patch is present and is subtracted;
# if neither check passes, returns 1 (partial or mixed staging).
# The sidecar is read from the worktree, falling back to the committed copy
# in HEAD when the worktree file is missing.
# Sets PATCHES_SUBTRACT_REMOVED_TRIPLE and PATCHES_SUBTRACT_REMOVED_LOCAL to
# 1 when subtraction removes the corresponding marker lines.
patches_subtract() {
  local relpath="${1#./}"
  local staged_file="$2"
  local out="$3"

  local sidecar
  sidecar="$(patches_sidecar_for "$relpath")"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap 'rm -rf "$tmp_dir"; trap - RETURN' RETURN

  local sidecar_file="$sidecar"
  if [[ ! -f "$sidecar_file" ]]; then
    # The sidecar may exist only in HEAD (deleted in the worktree, not yet
    # committed); use the committed copy so subtraction still happens.
    if git cat-file -e "HEAD:$sidecar" 2>/dev/null; then
      sidecar_file="$tmp_dir/head_sidecar.patch"
      if ! git show "HEAD:$sidecar" > "$sidecar_file" 2>/dev/null; then
        return 1
      fi
    else
      # No sidecar for this path; no subtraction needed.
      cp "$staged_file" "$out"
      PATCHES_SUBTRACT_REMOVED_TRIPLE=0
      PATCHES_SUBTRACT_REMOVED_LOCAL=0
      return 0
    fi
  fi

  mkdir -p "$tmp_dir/$(dirname "$relpath")"
  cp "$staged_file" "$tmp_dir/$relpath"
  cp "$sidecar_file" "$tmp_dir/patch.patch"

  # The patch is absent from the staged blob: pass it through unchanged.
  if git -C "$tmp_dir" apply --check patch.patch 2>/dev/null; then
    cp "$staged_file" "$out"
    PATCHES_SUBTRACT_REMOVED_TRIPLE=0
    PATCHES_SUBTRACT_REMOVED_LOCAL=0
    return 0
  fi

  # The patch is present: subtract it.
  if ! git -C "$tmp_dir" apply -R --check patch.patch 2>/dev/null; then
    return 1
  fi

  git -C "$tmp_dir" apply -R patch.patch
  cp "$tmp_dir/$relpath" "$out"

  # Signal whether subtraction removed local markers.
  PATCHES_SUBTRACT_REMOVED_TRIPLE=0
  PATCHES_SUBTRACT_REMOVED_LOCAL=0
  local before after
  before="$(grep -cE "$LOCAL_COMMENT_PATTERN_TRIPLE" "$staged_file" 2>/dev/null || true)"
  after="$(grep -cE "$LOCAL_COMMENT_PATTERN_TRIPLE" "$out" 2>/dev/null || true)"
  if [[ "$before" -gt "$after" ]]; then
    PATCHES_SUBTRACT_REMOVED_TRIPLE=1
  fi
  before="$(grep -cE "$LOCAL_COMMENT_PATTERN_LOCAL" "$staged_file" 2>/dev/null || true)"
  after="$(grep -cE "$LOCAL_COMMENT_PATTERN_LOCAL" "$out" 2>/dev/null || true)"
  if [[ "$before" -gt "$after" ]]; then
    PATCHES_SUBTRACT_REMOVED_LOCAL=1
  fi
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
