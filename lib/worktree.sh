#!/usr/bin/env bash
# -------------------------------------------------------------------
# Library: worktree.sh
# Purpose: helpers for feature worktree lifecycle
#          (feature start --worktree / feature finish --keep-worktree).
# -------------------------------------------------------------------

# Resolve a path to absolute canonical form, tolerating components that do
# not exist yet (worktree targets are usually created by `git worktree add`).
_worktree_abs() {
  local path="$1"
  if [[ "$path" != /* ]]; then
    path="$PWD/$path"
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$path"
    return
  fi
  if command -v readlink >/dev/null 2>&1 && readlink -m / >/dev/null 2>&1; then
    readlink -m "$path"
    return
  fi
  printf '%s\n' "$path"
}

# Expand a leading ~ or ~/ in a configured path to $HOME.
_worktree_expand_tilde() {
  local path="$1"
  if [[ "$path" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ "$path" == "~/"* ]]; then
    printf '%s/%s\n' "$HOME" "${path#"~/"}"
  else
    printf '%s\n' "$path"
  fi
}

# Print the registered worktree paths, one per line, from
# `git worktree list --porcelain`.
_worktree_list_paths() {
  git worktree list --porcelain | sed -n 's/^worktree //p'
}

# Print the worktree dir name for a branch: every '/' replaced by '-'.
# Returns 1 on an empty result, a result containing '..', or a leading '-'.
worktree_sanitize_name() {
  local name="${1//\//-}"
  if [[ -z "$name" || "$name" == *..* || "$name" == -* ]]; then
    return 1
  fi
  printf '%s\n' "$name"
}

# Print the default worktree path <WORKTREE_ROOT>/<sanitized-name>.
# Requires WORKTREE_ROOT to be set and absolute after ~ expansion.
worktree_path_for() {
  local branch="$1"
  local root="${WORKTREE_ROOT:-}"
  if [[ -z "$root" ]]; then
    ui_error "WORKTREE_ROOT is not set. Run: git shadow config set WORKTREE_ROOT <path>"
    ui_info  "Or omit --worktree / use --worktree-dir <path> instead."
    return 1
  fi
  root="$(_worktree_expand_tilde "$root")"
  if [[ "$root" != /* ]]; then
    ui_error "WORKTREE_ROOT must be an absolute path (got: '${WORKTREE_ROOT}')."
    return 1
  fi
  local name
  if ! name="$(worktree_sanitize_name "$branch")"; then
    ui_error "Cannot derive a worktree directory name from branch '$branch'."
    return 1
  fi
  printf '%s/%s\n' "${root%/}" "$name"
}

# Abort when <path> cannot host a new worktree: an existing non-empty dir,
# a path already registered in `git worktree list --porcelain` (stale
# registrations included), or — when [branch] is given — a branch already
# checked out in a registered worktree. An existing empty dir is accepted.
worktree_validate_path() {
  local path="$1" branch="${2:-}"
  local abs
  abs="$(_worktree_abs "$path")"

  local wt
  while IFS= read -r wt; do
    [[ -z "$wt" ]] && continue
    if [[ "$wt" == "$abs" ]]; then
      ui_error "Path is already registered as a worktree: $abs"
      return 1
    fi
  done < <(_worktree_list_paths)

  if [[ -d "$abs" && -n "$(ls -A "$abs" 2>/dev/null)" ]]; then
    ui_error "Worktree path exists and is not empty: $abs"
    return 1
  fi
  if [[ -e "$abs" && ! -d "$abs" ]]; then
    ui_error "Worktree path exists and is not a directory: $abs"
    return 1
  fi

  if [[ -n "$branch" ]] && worktree_find_for_branch "$branch" >/dev/null; then
    ui_error "Branch '$branch' is already checked out in a worktree."
    return 1
  fi
  return 0
}

# Create a worktree at <path> hosting <local_branch>. When <path> lives
# inside any registered worktree's toplevel, append /<relpath>/ to the
# shared info/exclude so the inner checkout is never staged. Copies the
# main checkout's .git-shadow.env into the new worktree when present.
worktree_add() {
  local local_branch="$1" path="$2"
  local abs
  abs="$(_worktree_abs "$path")"

  mkdir -p "$(dirname "$abs")" || return 1
  git worktree add "$abs" "$local_branch" || return 1

  # The new worktree may sit inside any existing worktree's toplevel;
  # hide it from the innermost containing worktree via shared info/exclude.
  local container="" wt
  while IFS= read -r wt; do
    [[ -z "$wt" || "$wt" == "$abs" ]] && continue
    if [[ "$abs" == "$wt/"* && ${#wt} -gt ${#container} ]]; then
      container="$wt"
    fi
  done < <(_worktree_list_paths)

  if [[ -n "$container" ]]; then
    local relpath="${abs#"$container"/}"
    local exclude_file
    exclude_file="$(git rev-parse --git-path info/exclude)"
    mkdir -p "$(dirname "$exclude_file")"
    grep -qxF "/$relpath/" "$exclude_file" 2>/dev/null || \
      printf '/%s/\n' "$relpath" >> "$exclude_file"
  fi

  # Propagate the main checkout's project config so load_env finds it
  # inside the new worktree (the file is gitignored, never carried over).
  local main_wt
  main_wt="$(_worktree_list_paths | head -1)"
  if [[ -n "$main_wt" && -f "$main_wt/.git-shadow.env" && ! -e "$abs/.git-shadow.env" ]]; then
    cp "$main_wt/.git-shadow.env" "$abs/.git-shadow.env"
  fi
}

# Return 0 when the worktree at <path> has uncommitted or untracked files.
# A worktree with only applied local patch overlays is treated as clean.
worktree_is_dirty() {
  (
    cd "$1" || return 1
    if ! patches_overlay_clean; then
      return 0
    fi
    if ! git diff --cached --quiet; then
      return 0
    fi
    return 1
  )
}

# Print the registered worktree path for <local_branch>, or return 1.
worktree_find_for_branch() {
  local branch="$1"
  local path=""
  local line
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ refs/heads/*)
        if [[ "${line#branch refs/heads/}" == "$branch" ]]; then
          printf '%s\n' "$path"
          return 0
        fi
        ;;
      "") path="" ;;
    esac
  done < <(git worktree list --porcelain)
  return 1
}

# Remove the worktree at <path>. A registered worktree whose directory is
# missing is stale: `git worktree prune` clears the registration first.
# Caller guarantees a clean tree and cwd outside <path>.
worktree_remove() {
  local path="$1"
  local abs
  abs="$(_worktree_abs "$path")"

  if [[ ! -d "$abs" ]]; then
    if _worktree_list_paths | grep -qxF "$abs"; then
      git worktree prune
      if _worktree_list_paths | grep -qxF "$abs"; then
        ui_error "Stale worktree registration for '$abs' could not be cleared."
        ui_info  "Run 'git worktree prune' manually, then retry."
        return 1
      fi
    fi
    return 0
  fi
  git worktree remove "$abs"
}

# Emit one 'path<TAB>branch' line for a worktree_orphans candidate: a
# missing directory (stale, prune-able) or a registered @local branch
# that no longer exists.
_worktree_orphan_emit() {
  local path="$1" branch="$2"
  [[ -z "$path" ]] && return 0
  if [[ ! -d "$path" ]]; then
    printf '%s\t%s\n' "$path" "${branch:--}"
    return 0
  fi
  if [[ -n "$branch" && "$branch" != "-" && "$branch" == *"${LOCAL_SUFFIX:-@local}" ]]; then
    git show-ref --verify --quiet "refs/heads/$branch" || \
      printf '%s\t%s\n' "$path" "$branch"
  fi
}

# Print 'path<TAB>branch' for each registered worktree that is orphaned:
# its directory is missing, or its @local branch no longer exists.
# Read-only; used by `git shadow doctor`.
worktree_orphans() {
  local path="" branch="" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)         path="${line#worktree }"; branch="" ;;
      branch\ refs/heads/*) branch="${line#branch refs/heads/}" ;;
      detached)            branch="-" ;;
      "")
        _worktree_orphan_emit "$path" "$branch"
        path=""; branch=""
        ;;
    esac
  done < <(git worktree list --porcelain; printf '\n')
}

# git worktree remove requires git >= 2.17.
worktree_supported() {
  local ver major minor rest
  ver="$(git version 2>/dev/null | sed 's/^git version //' | cut -d' ' -f1)"
  major="${ver%%.*}"
  rest="${ver#*.}"
  minor="${rest%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  [[ "$major" -gt 2 || ( "$major" -eq 2 && "$minor" -ge 17 ) ]]
}
