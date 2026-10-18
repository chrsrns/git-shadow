#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow agents sync
# Purpose: create or refresh the managed git-shadow block in
#          AGENTS.local.md at the invoking worktree's repository root.
#          Writes the working tree only — nothing is staged or
#          committed, and no particular branch is required.
# -------------------------------------------------------------------

_GS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/help.sh"
if gs_help_requested -- "$@"; then
  echo "Usage: git shadow agents sync [<ignored>...]"
  exit 0
fi

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/common.sh"

enter_project '.'

# A working-tree write while a sync/finish resolution or a native
# merge/rebase/cherry-pick/revert is open would be swept into that
# resolution commit by an `add -A` — refuse instead.
patches_require_no_paused_op
require_no_in_progress_git_op

root="$(repo_root)"
target="$root/$AGENTS_LOCAL_FILE"

state="$(agents_block_state "$target")" || exit 1

case "$state" in
  malformed)
    ui_error "$AGENTS_LOCAL_FILE has malformed git-shadow markers — fix or remove them manually."
    exit 1
    ;;
  current)
    ui_ok "agents: $AGENTS_LOCAL_FILE is up to date"
    exit 0
    ;;
esac

agents_block_install "$target" || exit 1

case "$state" in
  missing) ui_ok "agents: created $AGENTS_LOCAL_FILE" ;;
  absent)  ui_ok "agents: appended managed block to $AGENTS_LOCAL_FILE" ;;
  stale)   ui_ok "agents: refreshed managed block in $AGENTS_LOCAL_FILE" ;;
esac

# The file is not exempt from dirt checks — name the remedy by
# trackedness before the next mutating op trips over it: public-tracked
# takes a public commit, anything else takes [MEMORY] or .gitignore.
if ! git -C "$root" ls-files --error-unmatch "$AGENTS_LOCAL_FILE" >/dev/null 2>&1; then
  ui_info "$AGENTS_LOCAL_FILE is untracked — 'git commit -m \"[MEMORY] ...\"' it on a @local branch or add it to .gitignore before the next mutating op."
else
  public_branch="$(public_branch_from_any "$(current_branch || true)")"
  if [[ -n "$public_branch" ]] && git -C "$root" cat-file -e "$public_branch:$AGENTS_LOCAL_FILE" 2>/dev/null; then
    ui_info "$AGENTS_LOCAL_FILE is public-tracked — commit the update as a public commit, not [MEMORY]."
  else
    ui_info "$AGENTS_LOCAL_FILE is tracked — re-commit the update with 'git commit -m \"[MEMORY] ...\"'."
  fi
fi
