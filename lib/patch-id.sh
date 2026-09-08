#!/usr/bin/env bash

# -------------------------------------------------------------------
# Library: patch-id.sh
# Purpose: stable patch-id helpers for the diff-sync model.
#
# The stable patch-id is computed from the email-format diff of a commit
# using `git patch-id --stable`. Callers should not know the exact pipeline.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ui.sh"

# Print the stable patch-id for a single commit.
# Returns 0 and prints the patch-id, or prints nothing for an empty SHA.
# Returns 1 if the commit cannot be shown or `git patch-id` fails, and
# emits an error message so callers can distinguish failure from an empty patch.
patch_id_for() {
  local sha="$1"
  if [[ -z "$sha" ]]; then
    return 0
  fi

  local diff
  if ! diff="$(git show --format=email --no-color "$sha" 2>/dev/null)"; then
    ui_error "patch_id_for: cannot show commit $sha"
    return 1
  fi

  local patchid
  if ! patchid="$(printf '%s\n' "$diff" | git patch-id --stable 2>/dev/null)"; then
    ui_error "patch_id_for: cannot compute patch-id for $sha"
    return 1
  fi

  printf '%s\n' "$patchid" | awk '{print $1}'
}

# Print one stable patch-id per line for each given commit SHA.
# Empty arguments are skipped. Returns 1 if any commit fails.
patch_ids_for() {
  local sha pid
  for sha in "$@"; do
    if [[ -n "$sha" ]]; then
      if ! pid="$(patch_id_for "$sha")"; then
        return 1
      fi
      [[ -n "$pid" ]] && printf '%s\n' "$pid"
    fi
  done
  # An empty patch-id (merge or empty-diff commit) is skipped, not an
  # error — return 0 so pipefail callers do not treat it as failure.
  return 0
}
