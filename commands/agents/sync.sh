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

agents_block_dirt_remedy "$root"
