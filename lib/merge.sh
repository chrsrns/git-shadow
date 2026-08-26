#!/usr/bin/env bash
#
# Library: merge.sh
# Purpose: shared conflict resolution helpers for the merge workflow.
#
# Assumes lib/common.sh has already been sourced.

# Return 0 if the given merge stage of a file contains local comment markers.
merge_side_has_local_comments() {
  local stage="$1"
  local file="$2"
  git show "$stage:$file" 2>/dev/null | grep -qP "$LOCAL_COMMENT_PATTERN"
}

# Resolve an in-progress merge by choosing the side that carries local comments.
# If both or neither side has local comments, use the supplied preference.
# If $2 is "skip-continue", do not call "git merge --continue" afterwards
# (used when the resolver is invoked from a squash replay).
resolve_merge_conflicts() {
  local both_prefer="$1"
  local skip_continue=0
  if [[ "${2:-}" == "skip-continue" ]]; then
    skip_continue=1
  fi
  local file side
  local ours_has=0 theirs_has=0
  local conflicts

  conflicts="$(git diff --name-only --diff-filter=U)"
  if [[ -z "$conflicts" ]]; then
    if [[ "$skip_continue" -eq 0 && -f "$(git rev-parse --git-path MERGE_HEAD)" ]]; then
      GIT_EDITOR=true git merge --continue
    fi
    return 0
  fi

  while IFS= read -r file; do
    ours_has=0
    theirs_has=0
    ours_exists=0
    theirs_exists=0

    if git show ":2:$file" >/dev/null 2>&1; then
      ours_exists=1
      merge_side_has_local_comments ":2:" "$file" && ours_has=1
    fi
    if git show ":3:$file" >/dev/null 2>&1; then
      theirs_exists=1
      merge_side_has_local_comments ":3:" "$file" && theirs_has=1
    fi

    if [[ "$ours_has" -eq 1 && "$theirs_has" -eq 0 ]]; then
      side="ours"
    elif [[ "$theirs_has" -eq 1 && "$ours_has" -eq 0 ]]; then
      side="theirs"
    else
      side="$both_prefer"
    fi

    if [[ "$side" == "ours" && "$ours_exists" -eq 0 ]]; then
      ui_shadow "Auto-resolved (delete): $file"
      git rm -q -- "$file"
    elif [[ "$side" == "theirs" && "$theirs_exists" -eq 0 ]]; then
      ui_shadow "Auto-resolved (delete): $file"
      git rm -q -- "$file"
    else
      ui_shadow "Auto-resolved ($side): $file"
      git checkout --"$side" -- "$file"
      git add -- "$file"
    fi
  done <<< "$conflicts"

  if [[ "$skip_continue" -eq 0 ]]; then
    GIT_EDITOR=true git merge --continue
  fi
}
