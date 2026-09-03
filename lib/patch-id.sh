#!/usr/bin/env bash

# -------------------------------------------------------------------
# Library: patch-id.sh
# Purpose: stable patch-id helpers for the diff-sync model.
#
# The stable patch-id is computed from the email-format diff of a commit
# using `git patch-id --stable`. Callers should not know the exact pipeline.
# -------------------------------------------------------------------

# Print the stable patch-id for a single commit, or nothing if the SHA is
# empty or the commit cannot be shown.
patch_id_for() {
  local sha="$1"
  if [[ -z "$sha" ]]; then
    return 0
  fi
  git show --format=email --no-color "$sha" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}'
}

# Print one stable patch-id per line for each given commit SHA.
# Empty arguments are skipped.
patch_ids_for() {
  local sha
  for sha in "$@"; do
    if [[ -n "$sha" ]]; then
      patch_id_for "$sha"
    fi
  done
}
