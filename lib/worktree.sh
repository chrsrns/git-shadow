#!/usr/bin/env bash
# -------------------------------------------------------------------
# Library: worktree.sh
# Purpose: helpers for feature worktree lifecycle
#          (feature start --worktree / feature finish --keep-worktree).
# -------------------------------------------------------------------

# Print one `path<TAB>branch<TAB>locked` record per registered worktree from
# a single `git worktree list --porcelain` parse. `branch` is `-` for a
# detached or bare entry; `locked` is `1` on a `locked`/`locked <reason>`
# record, else `-`. Every registry consumer builds on these records so the
# porcelain format is known in exactly one place (V168).
worktree_records() {
  local path="" branch="" locked="-" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)          path="${line#worktree }" ;;
      branch\ refs/heads/*) branch="${line#branch refs/heads/}" ;;
      detached)             branch="-" ;;
      bare)                 branch="-" ;;
      locked|locked\ *)     locked="1" ;;
      "")
        if [[ -n "$path" ]]; then
          printf '%s\t%s\t%s\n' "$path" "${branch:--}" "$locked"
        fi
        path=""; branch=""; locked="-"
        ;;
    esac
  done < <(git worktree list --porcelain; printf '\n')
}

# Return 0 when the worktree registered at <path> is locked.
worktree_is_locked() {
  local target
  target="$(abs_path_m "$1")" || return 1
  local rec_path rec_branch rec_locked
  while IFS=$'\t' read -r rec_path rec_branch rec_locked; do
    [[ "$rec_path" == "$target" && "$rec_locked" == "1" ]] && return 0
  done < <(worktree_records)
  return 1
}

# Print the registered worktree paths, one per line, from worktree_records.
worktree_paths() {
  worktree_records | cut -f1
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
  root="$(expand_tilde "$root")"
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
  abs="$(abs_path_m "$path")"

  local wt
  while IFS= read -r wt; do
    [[ -z "$wt" ]] && continue
    if [[ "$wt" == "$abs" ]]; then
      ui_error "Path is already registered as a worktree: $abs"
      return 1
    fi
  done < <(worktree_paths)

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
  abs="$(abs_path_m "$path")"

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
  done < <(worktree_paths)

  if [[ -n "$container" ]]; then
    local relpath="${abs#"$container"/}"
    local exclude_file
    exclude_file="$(git rev-parse --git-path info/exclude)"
    mkdir -p "$(dirname "$exclude_file")"
    grep -qxF "/$relpath/" "$exclude_file" 2>/dev/null || \
      printf '/%s/\n' "$relpath" >> "$exclude_file"
  fi

  # Propagate project config so load_env finds it inside the new worktree
  # (the file is gitignored, never carried over). Source order: invoking
  # checkout's toplevel, then the main checkout's (V286).
  local main_wt inv_top env_src
  main_wt="$(worktree_paths | head -1)"
  inv_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  env_src=""
  if [[ -n "$inv_top" && -f "$inv_top/.git-shadow.env" ]]; then
    env_src="$inv_top"
  elif [[ -n "$main_wt" && -f "$main_wt/.git-shadow.env" ]]; then
    env_src="$main_wt"
  fi
  if [[ -n "$env_src" && ! -e "$abs/.git-shadow.env" ]]; then
    cp "$env_src/.git-shadow.env" "$abs/.git-shadow.env"
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
    return 1
  )
}

# Print the registered worktree path for <local_branch>, or return 1.
worktree_find_for_branch() {
  local branch="$1"
  # shellcheck disable=SC2034  # third record field consumed by other readers; required so the branch field does not fold
  local path rec_branch rec_locked
  while IFS=$'\t' read -r path rec_branch rec_locked; do
    if [[ "$rec_branch" == "$branch" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(worktree_records)
  return 1
}

# Remove the worktree at <path>. With --force, pass --force to
# `git worktree remove` (the `feature start` failure cleanup must drop a
# worktree that `worktree_add` left behind mid-failure). A registered
# worktree whose directory is missing is stale: `git worktree prune`
# clears the registration first. Caller guarantees a clean tree — unless
# --force — and cwd outside <path>.
worktree_remove() {
  local path="$1"
  local force="${2:-}"
  local abs
  abs="$(abs_path_m "$path")"

  if [[ ! -d "$abs" ]]; then
    if worktree_paths | grep -qxF "$abs"; then
      git worktree prune
      if worktree_paths | grep -qxF "$abs"; then
        ui_error "Stale worktree registration for '$abs' could not be cleared."
        ui_info  "Run 'git worktree prune' manually, then retry."
        return 1
      fi
    fi
    return 0
  fi
  if [[ "$force" == "--force" ]]; then
    git worktree remove --force "$abs"
  else
    git worktree remove "$abs"
  fi
}

# Print 'path<TAB>branch' for each registered worktree that is orphaned:
# its directory is missing, or its @local branch no longer exists.
# Read-only; used by `git shadow doctor`.
worktree_orphans() {
  local path branch rec_locked
  while IFS=$'\t' read -r path branch rec_locked; do
    [[ -z "$path" ]] && continue
    if [[ ! -d "$path" ]]; then
      printf '%s\t%s\n' "$path" "$branch"
      continue
    fi
    if [[ "$branch" != "-" && "$branch" == *"${LOCAL_SUFFIX:-@local}" ]]; then
      branch_exists "$branch" || \
        printf '%s\t%s\n' "$path" "$branch"
    fi
  done < <(worktree_records)
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
