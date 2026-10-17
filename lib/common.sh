#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Library: common.sh
# Purpose: shared utilities for paths and Git repository sanity checks.
# -------------------------------------------------------------------

# Load environment config (three-tier: defaults / user / project)
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
load_env

# Load semantic UI helpers (colors, output functions)
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ui.sh"

# Load checkpoint parser / storage helpers
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/checkpoint.sh"

# Load paused-operation state-file helpers (before sync/finish-state, which delegate here)
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state-file.sh"

# Load diff-sync sync helpers
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sync.sh"

# Load feature/base sync command flow
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sync-command.sh"

# Load finish-state helpers
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/finish-state.sh"

# Load patch-id helpers
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch-id.sh"

# Load local annotation helpers
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/annotations.sh"

# Load local marker guard helpers
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guard.sh"

# Load git hook installer helpers
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hook-installer.sh"

# Load diff-sync check pass helpers
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check.sh"

# Load worktree lifecycle helpers
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree.sh"

# Load local patch sidecar helpers
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches.sh"

# Resolve absolute paths
abs_path() {
  local path="$1"

  # If already absolute (Unix or Windows drive path), return as-is.
  if [[ "$path" = /* || "$path" =~ ^[A-Za-z]:[\\/] ]]; then
    echo "$path"
    return
  fi

  # Prefer realpath when available.
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
    return
  fi

  # Prefer readlink -f on platforms that support it (Linux, Git Bash).
  if command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
    readlink -f "$path"
    return
  fi

  # Fallback: use POSIX shell only.
  local cwd
  cwd="$(pwd)"
  local dir
  dir="$(dirname "$path")"
  local base
  base="$(basename "$path")"
  if [[ -d "$dir" ]]; then
    cd "$dir"
    printf '%s/%s\n' "$(pwd)" "$base"
    cd "$cwd"
    return
  fi

  # If directory does not exist, resolve parent and append basename.
  cd "$dir" >/dev/null 2>&1 || return 1
  printf '%s/%s\n' "$(pwd)" "$base"
  cd "$cwd"
}

# Resolve a path to absolute canonical form, tolerating components that do
# not exist yet (worktree targets are usually created by `git worktree add`).
abs_path_m() {
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
expand_tilde() {
  local path="$1"
  # shellcheck disable=SC2088  # tildes are matched literally here and expanded manually below
  if [[ "$path" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ "$path" == "~/"* ]]; then
    printf '%s/%s\n' "$HOME" "${path#"~/"}"
  else
    printf '%s\n' "$path"
  fi
}

# Print the worktree toplevel (absolute). The single
# `git rev-parse --show-toplevel` oracle for toolkit code — every
# filesystem access and git pathspec anchors here. Returns 1 outside a
# worktree.
repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || return 1
}

# Print the worktree toplevel, else $PWD. For read-only checks that must
# tolerate a missing toplevel (doctor scans).
repo_root_or_pwd() {
  repo_root || printf '%s\n' "$PWD"
}

# Print the unmerged paths in the index, one per line, toplevel-relative,
# sorted and deduplicated. The single "which paths are conflicted" oracle;
# runs from the toplevel so the whole index is enumerated from any cwd.
# Stderr is propagated and a failed enumeration returns non-zero — an
# error must not look like an empty conflict set.
conflicted_paths() {
  local root
  root="$(repo_root)" || return 1
  git -C "$root" ls-files -u | cut -f2- | sort -u
}

# Return 0 iff local branch <name> exists. The single branch-existence
# oracle; <name> is a short branch name, not a full ref.
branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1"
}

# Return 0 iff object <rev>:<path> exists. An empty <rev> probes the
# staged index (":<path>").
rev_path_exists() {
  git cat-file -e "$1:$2" 2>/dev/null || return 1
}

# Write the <rev>:<path> blob to file <out>. Git's stderr is suppressed —
# a missing or unreadable object surfaces only as return 1. An empty
# <rev> reads the staged blob (":<path>").
rev_blob_to() {
  git show "$1:$2" > "$3" 2>/dev/null || return 1
}

# Print every local branch name ending with LOCAL_SUFFIX (short names,
# sorted). The single `git for-each-ref` glob oracle for shadow
# enumeration.
local_branch_refs() {
  git for-each-ref --format='%(refname:short)' "refs/heads/**/*${LOCAL_SUFFIX}" | sort
}

# Print every public branch name having a <name><LOCAL_SUFFIX>
# counterpart, sorted (derived from local_branch_refs + branch_exists).
# The local base pair is included; callers that exclude it filter by
# name.
paired_public_branches() {
  local ref name
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    name="${ref%${LOCAL_SUFFIX}}"
    branch_exists "$name" || continue
    printf '%s\n' "$name"
  done < <(local_branch_refs)
}

# Normalize the workspace path from config
resolve_workspace_dir() {
  if [[ "$WORKSPACE_DIR" = /* ]]; then
    printf '%s\n' "$WORKSPACE_DIR"
  else
    abs_path "$TOOLKIT_ROOT/$WORKSPACE_DIR"
  fi
}

# Resolve project relative path to absolute
resolve_project_path() {
  local project_arg="$1"

  if [[ -z "$project_arg" || "$project_arg" = "." ]]; then
    printf '%s\n' "$PWD"
    return
  fi

  local workspace
  workspace="$(resolve_workspace_dir)"

  if [[ "$project_arg" = /* ]]; then
    printf '%s\n' "$(abs_path "$project_arg")"
  else
    printf '%s\n' "$(abs_path "$workspace/$project_arg")"
  fi
}

# Verify the target directory exists and is a Git repository
enter_project() {
  local project_arg="$1"
  local project_path
  project_path="$(resolve_project_path "$project_arg")"

  if [[ ! -d "$project_path" ]]; then
    echo "❌ Project directory not found: $project_path" >&2
    exit 1
  fi

  cd "$project_path"

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "❌ Not a Git repository: $project_path" >&2
    exit 1
  fi
}

# Get currently checked-out Git branch name
current_branch() {
  git branch --show-current
}

# Branch suffix transform: strip or ensure LOCAL_SUFFIX.
_branch_transform() {
  local branch="$1"
  local mode="$2"

  if [[ "$mode" == "strip" ]]; then
    if [[ "$branch" =~ ${LOCAL_SUFFIX}$ ]]; then
      printf '%s\n' "${branch%"$LOCAL_SUFFIX"}"
    else
      printf '%s\n' "$branch"
    fi
  elif [[ "$mode" == "ensure" ]]; then
    if [[ "$branch" =~ ${LOCAL_SUFFIX}$ ]]; then
      printf '%s\n' "$branch"
    else
      printf '%s\n' "${branch}${LOCAL_SUFFIX}"
    fi
  else
    echo "_branch_transform: unknown mode '$mode'" >&2
    return 1
  fi
}

# Convert local branch name into public counterpart (strip suffix)
public_branch_from_any() {
  _branch_transform "$1" strip
}

# Convert any branch to its local shadow variant (add suffix if missing)
local_branch_from_any() {
  _branch_transform "$1" ensure
}

# Abort unless the current branch ends with LOCAL_SUFFIX. An optional
# label names the command in the refusal message (default "This command").
require_local_branch() {
  local label="${1:-This command}"
  local branch
  branch="$(current_branch)"
  if [[ -z "$branch" ]]; then
    ui_error "Unable to determine current branch."
    exit 1
  fi
  if [[ ! "$branch" =~ ${LOCAL_SUFFIX}$ ]]; then
    ui_error "$label must be run from a branch ending with '${LOCAL_SUFFIX}'."
    exit 1
  fi
}

# Abort when a cherry-pick, merge, or rebase is in progress; each state
# is named in the refusal. Used by ensure_clean_repo and by command
# leaves that tolerate a dirty tree but not a mid-operation repo.
require_no_in_progress_git_op() {
  local cherry_pick_head_file merge_head_file rebase_merge_dir rebase_apply_dir
  cherry_pick_head_file="$(git rev-parse --git-path CHERRY_PICK_HEAD)"
  merge_head_file="$(git rev-parse --git-path MERGE_HEAD)"
  rebase_merge_dir="$(git rev-parse --git-path rebase-merge)"
  rebase_apply_dir="$(git rev-parse --git-path rebase-apply)"

  if [[ -f "$cherry_pick_head_file" ]]; then
    ui_error "A cherry-pick is still in progress."
    exit 1
  fi

  if [[ -f "$merge_head_file" ]]; then
    ui_error "A merge is still in progress."
    exit 1
  fi

  if [[ -d "$rebase_merge_dir" || -d "$rebase_apply_dir" ]]; then
    ui_error "A rebase is still in progress."
    exit 1
  fi
}

# Ensure repo is in a clean state (no ongoing rebase/merge/cherry-pick, no dirty tree)
ensure_clean_repo() {
  require_no_in_progress_git_op

  if ! patches_overlay_clean; then
    if ! git diff --cached --quiet; then
      ui_error "Working tree contains staged but uncommitted changes."
    else
      ui_error "Working tree contains uncommitted changes."
    fi
    ui_info  "Refresh local patches with 'git shadow local add' or resolve the changes below."
    if ! patches_dirty_table >&2; then
      ui_error "Unable to enumerate working tree status."
    fi
    exit 1
  fi
}

# Exit 0 when the installed git version is >= <major>.<minor>; unparseable
# versions compare as too old.
git_version_at_least() {
  local want_major="$1" want_minor="$2"
  local ver major minor
  ver="$(git --version 2>/dev/null | sed -n 's/^git version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')"
  set -- $ver
  major="${1:-}"
  minor="${2:-}"
  if [[ -z "$major" || -z "$minor" ]]; then
    return 1
  fi
  if (( major > want_major )); then
    return 0
  fi
  if (( major < want_major )); then
    return 1
  fi
  if (( minor >= want_minor )); then
    return 0
  fi
  return 1
}

# Detect the location of the Git hooks file according to core.hooksPath and Husky conventions
detect_hook_file() {
  local hook_name="${1:-pre-commit}"
  local hooks_path

  hooks_path="$(git config --get core.hooksPath || true)"
  hooks_path="${hooks_path%/}"

  if [[ -z "$hooks_path" ]]; then
    # hooks/ is shared across worktrees; --git-path resolves it to the
    # common .git dir even inside a linked worktree, where .git is a file.
    local resolved
    resolved="$(git rev-parse --git-path "hooks/$hook_name" 2>/dev/null)" || resolved=""
    if [[ -n "$resolved" ]]; then
      printf '%s\n' "$resolved"
    else
      printf '%s\n' ".git/hooks/$hook_name"
    fi
    return
  fi

  # Husky uses .husky/_ as internal hooksPath, but project hooks live in .husky/
  if [[ "$hooks_path" == ".husky/_" ]]; then
    printf '%s\n' ".husky/$hook_name"
    return
  fi

  printf '%s\n' "$hooks_path/$hook_name"
}
