#!/usr/bin/env bash

# -------------------------------------------------------------------
# Library: check.sh
# Purpose: diff-based check pass for the diff-sync model.
#
# The check pass builds a temporary public tree by replaying public commits
# (non-[MEMORY] and non-[CHECKPOINT]) from a @local branch onto the public
# checkpoint base, then verifies that tree matches the @local tree for every
# public-tracked file.
# -------------------------------------------------------------------

# Print the public commit SHAs between a checkpoint and a local branch head,
# in chronological order.  [MEMORY] and [CHECKPOINT] commits are skipped.
check_public_commits() {
  local local_branch="$1"
  local checkpoint_local="$2"

  git rev-list --reverse "${checkpoint_local}..${local_branch}" 2>/dev/null | while IFS= read -r sha; do
    local subject
    subject="$(git log -1 --format='%s' "$sha")"
    if [[ "$subject" != "[MEMORY]"* && "$subject" != "[CHECKPOINT]"* ]]; then
      printf '%s\n' "$sha"
    fi
  done
}

# Create a temporary branch from <checkpoint_public> and cherry-pick the given
# public commits onto it.  Prints the temp branch name, or returns 1 on failure.
check_replay_public() {
  local checkpoint_public="$1"
  local tmp_branch="$2"
  shift 2

  git checkout -q -b "$tmp_branch" "$checkpoint_public"

  for sha in "$@"; do
    if ! git cherry-pick --quiet "$sha" 2>/dev/null; then
      git cherry-pick --abort 2>/dev/null || true
      git checkout -q "-"
      git branch -D "$tmp_branch" 2>/dev/null || true
      return 1
    fi
  done

  printf '%s\n' "$tmp_branch"
}

# Compare two tree-ishs.  For every file in <expected_tree>, the same file must
# exist in <actual_tree> with the same blob.  Local-only additions are ignored.
# Returns 0 if the public-tracked files match, 1 otherwise.
check_tree_matches() {
  local expected_tree="$1"
  local actual_tree="$2"

  while IFS= read -r line; do
    # diff-tree --no-renames -r output format:
    # :<old-mode> <new-mode> <old-sha> <new-sha> <status>\t<path>
    # We only care about status (5th awk field) and whether any non-A status
    # appears for a path in the expected tree.
    local status
    status="$(printf '%s\n' "$line" | awk '{print $5}')"
    if [[ "$status" != "A" ]]; then
      return 1
    fi
  done < <(git diff-tree --no-renames -r "$expected_tree" "$actual_tree" 2>/dev/null)

  return 0
}

# Run the full check pass for a public/@local branch pair.
# Arguments: <public_branch> <local_branch> <checkpoint_public> <checkpoint_local>
# Prints the public commit SHAs (one per line) to stdout and returns 0 on pass.
# Returns 1 if the replayed public tree does not match the local tree or if a
# cherry-pick conflict occurs.
check_pass() {
  local public_branch="$1"
  local local_branch="$2"
  local checkpoint_public="$3"
  local checkpoint_local="$4"

  local public_commits
  public_commits="$(check_public_commits "$local_branch" "$checkpoint_local" | tr '\n' ' ')"
  public_commits="${public_commits% }"

  if [[ -z "$public_commits" ]]; then
    # Nothing to publish; nothing to verify.
    return 0
  fi

  local tmp_branch
  tmp_branch="__shadow_check_tmp__"

  # Remove any leftover temp branch from an aborted previous run.
  git show-ref --verify --quiet "refs/heads/$tmp_branch" && git branch -D "$tmp_branch" 2>/dev/null || true

  local original_branch
  original_branch="$(git branch --show-current)"

  if ! check_replay_public "$checkpoint_public" "$tmp_branch" $public_commits; then
    git checkout -q "${original_branch}" 2>/dev/null || true
    return 1
  fi

  local tmp_head local_head
  tmp_head="$(git rev-parse "$tmp_branch")"
  local_head="$(git rev-parse "$local_branch")"

  local result=0
  if ! check_tree_matches "$tmp_head" "$local_head"; then
    result=1
  fi

  # Cleanup temp branch.
  git checkout -q "${original_branch}" 2>/dev/null || true
  git branch -D "$tmp_branch" 2>/dev/null || true

  if [[ $result -eq 0 ]]; then
    printf '%s\n' $public_commits | tr ' ' '\n' | grep -v '^$'
  fi

  return $result
}
