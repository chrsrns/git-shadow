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
resolve_merge_conflicts() {
  local both_prefer="$1"
  local file side
  local ours_has=0 theirs_has=0
  local conflicts

  conflicts="$(git diff --name-only --diff-filter=U)"
  if [[ -z "$conflicts" ]]; then
    if [[ -f "$(git rev-parse --git-path MERGE_HEAD)" ]]; then
      GIT_EDITOR=true git merge --continue
    fi
    return 0
  fi

  while IFS= read -r file; do
    ours_has=0
    theirs_has=0
    merge_side_has_local_comments ":2:" "$file" && ours_has=1
    merge_side_has_local_comments ":3:" "$file" && theirs_has=1

    if [[ "$ours_has" -eq 1 && "$theirs_has" -eq 0 ]]; then
      side="ours"
    elif [[ "$theirs_has" -eq 1 && "$ours_has" -eq 0 ]]; then
      side="theirs"
    else
      side="$both_prefer"
    fi

    ui_shadow "Auto-resolved ($side): $file"
    git checkout --"$side" -- "$file"
    git add -- "$file"
  done <<< "$conflicts"

  GIT_EDITOR=true git merge --continue
}
