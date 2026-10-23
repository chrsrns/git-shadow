#!/usr/bin/env bash

# -------------------------------------------------------------------
# Library: checkpoint.sh
# Purpose: parse, create, and find [CHECKPOINT] commits.
#
# Checkpoint summary format:
#   [CHECKPOINT] public:<sha> local:<sha>
#
# Optional body line:
#   patches:<pid1>,<pid2>,...
# -------------------------------------------------------------------

# Echo the standardized checkpoint summary line.
checkpoint_summary() {
  local public_sha="$1"
  local local_sha="$2"
  printf '[CHECKPOINT] public:%s local:%s\n' "$public_sha" "$local_sha"
}

# Echo the standardized checkpoint body line.
checkpoint_body() {
  local pids
  pids="$(printf '%s,' "$@")"
  printf 'patches:%s\n' "${pids%,}"
}

# Create an empty checkpoint commit on the current branch.
# Arguments: <public_sha> <local_sha> [pid ...]
# Prints the new commit SHA.
checkpoint_create() {
  local public_sha="$1"
  local local_sha="$2"
  shift 2

  local summary
  summary="$(checkpoint_summary "$public_sha" "$local_sha")"

  local body
  if [[ $# -gt 0 ]]; then
    body="$(checkpoint_body "$@")"
    env GIT_SHADOW=1 git commit --allow-empty -m "$summary" -m "$body" --quiet
  else
    env GIT_SHADOW=1 git commit --allow-empty -m "$summary" --quiet
  fi

  git rev-parse HEAD
}

# Parse the subject of a checkpoint commit in a single git log pass.
# Prints "<public_sha> <local_sha>", or nothing for a non-checkpoint
# subject.
checkpoint_parse() {
  git log -1 --format='%s' "$1" | sed -n 's/^\[CHECKPOINT\] public:\([0-9a-fA-F]\{1,\}\) local:\([0-9a-fA-F]\{1,\}\).*/\1 \2/p'
}

# Print the patch-ids stored in the checkpoint body, space separated.
checkpoint_pids() {
  local sha="$1"
  local raw
  raw="$(git log -1 --format='%b' "$sha" | sed -n 's/^patches://p' | head -n1)"
  if [[ -n "$raw" ]]; then
    printf '%s\n' "$raw" | tr ',' ' '
  fi
}

# Find the newest checkpoint commit reachable from a ref.
# Prints the SHA, or nothing if none is found.
checkpoint_latest() {
  local ref="$1"
  local sha
  # Walk [CHECKPOINT]-led candidates newest-first; return the first whose
  # subject checkpoint_parse accepts (V289) — a malformed or colliding
  # commit is skipped, never terminal.
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    if [[ -n "$(checkpoint_parse "$sha")" ]]; then
      printf '%s\n' "$sha"
      return 0
    fi
  done < <(git log --format='%H' --extended-regexp --grep='^\[CHECKPOINT\]' "$ref" 2>/dev/null)
}
