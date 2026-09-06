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

  local revlist
  if ! revlist="$(git rev-list --reverse "${checkpoint_local}..${local_branch}" 2>/dev/null)"; then
    ui_error "check_public_commits: cannot list commits from $checkpoint_local to $local_branch"
    return 1
  fi

  local sha subject
  for sha in $revlist; do
    subject="$(git log -1 --format='%s' "$sha")"
    if [[ "$subject" != "[MEMORY]"* && "$subject" != "[CHECKPOINT]"* ]]; then
      printf '%s\n' "$sha"
    fi
  done
}

# Print "<sha>\t<path>" for every M/D/T diff entry in <sha>... whose path is
# absent from the evolving path set seeded from <base_tree>.  Commits are
# applied in order: additions insert into the set, deletions remove from it.
# Returns 1 when at least one missing path is found, 0 otherwise.
# Merge commits yield no diff entries and are skipped.
check_missing_paths() {
  local base_tree="$1"
  shift

  local -A present=()
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] && present["$path"]=1
  done < <(git ls-tree -r --name-only "$base_tree" 2>/dev/null)

  local missing=0
  local sha status
  for sha in "$@"; do
    while IFS=$'\t' read -r status path; do
      [[ -z "$status" || -z "$path" ]] && continue
      case "$status" in
        A*)
          present["$path"]=1
          ;;
        D*)
          if [[ -z "${present[$path]:-}" ]]; then
            printf '%s\t%s\n' "$sha" "$path"
            missing=1
          else
            unset 'present[$path]'
          fi
          ;;
        M*|T*)
          if [[ -z "${present[$path]:-}" ]]; then
            printf '%s\t%s\n' "$sha" "$path"
            missing=1
          fi
          ;;
      esac
    done < <(git diff-tree --no-renames -r --name-status --no-commit-id "$sha" 2>/dev/null)
  done

  return $missing
}

# Create a temporary branch from <checkpoint_public> and cherry-pick the given
# public commits onto it.  Prints the temp branch name, or returns 1 on failure
# after emitting an error naming the offending commit and involved paths.
check_replay_public() {
  local checkpoint_public="$1"
  local tmp_branch="$2"
  shift 2

  git checkout -q -b "$tmp_branch" "$checkpoint_public" >/dev/null 2>&1

  local sha pick_output conflicted
  for sha in "$@"; do
    if ! pick_output="$(git cherry-pick --quiet "$sha" 2>&1 >/dev/null)"; then
      ui_error "Check pass: failed to replay public commit $sha ($(git log -1 --format='%s' "$sha" 2>/dev/null))."
      [[ -n "$pick_output" ]] && printf '%s\n' "$pick_output" >&2
      # Unmerged paths cover real conflicts; an empty pick leaves none, so
      # fall back to the paths the offending commit itself touches.
      conflicted="$(git diff --name-only --diff-filter=U 2>/dev/null)"
      if [[ -z "$conflicted" ]]; then
        conflicted="$(git diff-tree --no-renames -r --name-only --no-commit-id "$sha" 2>/dev/null)"
      fi
      [[ -n "$conflicted" ]] && ui_error "Check pass: path(s) involved: $(printf '%s\n' "$conflicted" | paste -sd' ' -)"
      git cherry-pick --abort >/dev/null 2>&1 || true
      git checkout -q "-" >/dev/null 2>&1 || true
      git branch -D "$tmp_branch" >/dev/null 2>&1 || true
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

  local result=0
  local line status path
  while IFS= read -r line; do
    # diff-tree --no-renames -r output format:
    # :<old-mode> <new-mode> <old-sha> <new-sha> <status>\t<path>
    # We only care about status (5th awk field) and whether any non-A status
    # appears for a path in the expected tree.
    status="$(printf '%s\n' "$line" | awk '{print $5}')"
    path="$(printf '%s\n' "$line" | awk -F'\t' '{print $2}')"
    if [[ "$status" != "A" ]]; then
      ui_error "Check pass: public tree differs at '$path' (status $status)."
      result=1
    fi
  done < <(git diff-tree --no-renames -r "$expected_tree" "$actual_tree" 2>/dev/null)

  return $result
}

# Replay public commits from <local_branch> onto a temporary branch rooted at
# <checkpoint_public>, verify the replayed tree matches <local_branch>, and on
# success print the temp branch name on the first line followed by the public
# commit SHAs (one per line).  Returns 1 on pre-flight, replay, or tree mismatch
# failure and cleans up the temp branch.  The temp branch is left in place for
# the caller on success.
publish_replay_and_head() {
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

  # Pre-flight: a public commit may not modify or delete a path that is
  # absent from the public tree being replayed (e.g. a local-only file).
  local missing m_sha m_path
  if ! missing="$(check_missing_paths "$checkpoint_public" $public_commits)"; then
    while IFS=$'\t' read -r m_sha m_path; do
      [[ -z "$m_sha" ]] && continue
      ui_error "Check pass: public commit $m_sha touches '$m_path', which is absent from the public tree being replayed."
    done <<< "$missing"
    return 1
  fi

  local tmp_branch
  tmp_branch="__shadow_check_tmp__"

  # Remove any leftover temp branch from an aborted previous run.
  git show-ref --verify --quiet "refs/heads/$tmp_branch" && git branch -D "$tmp_branch" >/dev/null 2>&1 || true

  local original_branch
  original_branch="$(git branch --show-current)"

  local replayed_branch
  if ! replayed_branch="$(check_replay_public "$checkpoint_public" "$tmp_branch" $public_commits)"; then
    git checkout -q "${original_branch}" >/dev/null 2>&1 || true
    return 1
  fi

  local tmp_head local_head
  tmp_head="$(git rev-parse "$tmp_branch")"
  local_head="$(git rev-parse "$local_branch")"

  if ! check_tree_matches "$tmp_head" "$local_head"; then
    git checkout -q "${original_branch}" >/dev/null 2>&1 || true
    git branch -D "$tmp_branch" >/dev/null 2>&1 || true
    return 1
  fi

  # Return to the original branch but leave the temp branch for the caller.
  git checkout -q "${original_branch}" >/dev/null 2>&1 || true

  printf '%s\n' "$tmp_branch"
  printf '%s\n' $public_commits | tr ' ' '\n' | grep -v '^$'
}

# Run the full check pass for a public/@local branch pair.
# Arguments: <public_branch> <local_branch> <checkpoint_public> <checkpoint_local>
# Prints the public commit SHAs (one per line) to stdout and returns 0 on pass.
# Returns 1 if the replayed public tree does not match the local tree or if a
# cherry-pick conflict occurs.
check_pass() {
  local replay_output
  if ! replay_output="$(publish_replay_and_head "$@")"; then
    return 1
  fi
  if [[ -z "$replay_output" ]]; then
    return 0
  fi

  local tmp_branch
  tmp_branch="$(head -n1 <<< "$replay_output")"
  local public_commits
  public_commits="$(tail -n +2 <<< "$replay_output")"

  # Cleanup temp branch.
  git branch -D "$tmp_branch" >/dev/null 2>&1 || true

  printf '%s\n' "$public_commits"
  return 0
}
