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
    if [[ "$subject" != "[MEMORY]"* && "$subject" != "[CHECKPOINT]"* && "$subject" != "[SYNC]"* ]]; then
      printf '%s\n' "$sha"
    fi
  done
}

# Print the number of publishable commits between <checkpoint_local> and
# <local_branch>, counted from check_public_commits output so the subject
# filter lives in exactly one place.  Returns 1 when the range cannot be
# listed; consumers treat that as a count of 0.
check_publishable_count() {
  local local_branch="$1"
  local checkpoint_local="$2"

  local commits
  if ! commits="$(check_public_commits "$local_branch" "$checkpoint_local")"; then
    return 1
  fi

  if [[ -z "$commits" ]]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$commits" | wc -l
}

# Print "<sha>\t<path>" for every M/D/T diff entry in <sha>... whose path is
# absent from the evolving path set seeded from <base_tree>.  Commits are
# applied in order: additions insert into the set, deletions remove from it.
# Returns 1 when at least one missing path is found, 0 otherwise.
# Returns 1 if `git ls-tree` or `git diff-tree` fails.
# Merge commits yield no diff entries and are skipped.
check_missing_paths() {
  local base_tree="$1"
  shift

  local base_paths base_status
  base_paths="$(git ls-tree -r --name-only "$base_tree" 2>/dev/null)"
  base_status=$?
  if [[ $base_status -ne 0 ]]; then
    ui_error "check_missing_paths: cannot list base tree $base_tree"
    return 1
  fi

  local -A present=()
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] && present["$path"]=1
  done < <(printf '%s\n' "$base_paths")

  local missing=0
  local sha status diff_output diff_status
  for sha in "$@"; do
    diff_output="$(git diff-tree --no-renames -r --name-status --no-commit-id "$sha" 2>/dev/null)"
    diff_status=$?
    if [[ $diff_status -ne 0 ]]; then
      ui_error "check_missing_paths: cannot diff commit $sha"
      return 1
    fi
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
    done < <(printf '%s\n' "$diff_output")
  done

  return $missing
}

# Create a temporary branch from <checkpoint_public> and cherry-pick the given
# public commits onto it.  Prints the applied commit SHAs (one per line) —
# empty commits are skipped with a note and never printed.  Returns 1 on
# failure after emitting an error naming the offending commit and paths.
check_replay_public() {
  local checkpoint_public="$1"
  local tmp_branch="$2"
  shift 2

  git checkout -q -b "$tmp_branch" "$checkpoint_public" >/dev/null 2>&1

  local sha pick_output conflicted before_tree
  for sha in "$@"; do
    # Initially-empty commits (tree == parent) have nothing to replay and
    # would fail as empty picks; skip them up front.
    if git diff-tree -r --no-commit-id --quiet "$sha" >/dev/null 2>&1; then
      ui_info "Check pass: skipping initially-empty public commit $sha ($(git log -1 --format='%s' "$sha" 2>/dev/null))." >&2
      continue
    fi

    before_tree="$(git rev-parse HEAD^{tree})"
    if git_version_at_least 2 45; then
      # --empty=drop silently drops picks that become empty on the base.
      if ! pick_output="$(git cherry-pick --quiet --empty=drop "$sha" 2>&1 >/dev/null)"; then
        _check_replay_fail "$sha" "$tmp_branch"
        return 1
      fi
    else
      if ! pick_output="$(git cherry-pick --quiet "$sha" 2>&1 >/dev/null)"; then
        # A stopped pick with no staged or unstaged changes is an empty pick
        # (content already present); skip it instead of failing. Detected via
        # CHERRY_PICK_HEAD + empty diffs, not message text (localizable).
        if [[ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]] \
           && git diff --quiet && git diff --cached --quiet; then
          ui_info "Check pass: skipping empty public commit $sha ($(git log -1 --format='%s' "$sha" 2>/dev/null))." >&2
          if git_version_at_least 2 33; then
            git cherry-pick --skip >/dev/null 2>&1 || true
          else
            git cherry-pick --quit >/dev/null 2>&1 || true
            git reset --hard HEAD >/dev/null 2>&1
          fi
          continue
        fi
        _check_replay_fail "$sha" "$tmp_branch"
        return 1
      fi
    fi
    # --empty=drop gives no signal, so compare trees: an unchanged tree means
    # the pick was dropped as empty. Only applied commits are printed.
    if [[ "$(git rev-parse HEAD^{tree})" != "$before_tree" ]]; then
      printf '%s\n' "$sha"
    else
      ui_info "Check pass: skipping empty public commit $sha ($(git log -1 --format='%s' "$sha" 2>/dev/null))." >&2
    fi
  done
}

# Emit the replay failure diagnostic for <sha> and clean up the temp branch.
# Raw git cherry-pick output is never printed.
_check_replay_fail() {
  local sha="$1"
  local tmp_branch="$2"
  ui_error "Check pass: failed to replay public commit $sha ($(git log -1 --format='%s' "$sha" 2>/dev/null))."
  # Unmerged paths cover real conflicts; an empty pick leaves none, so
  # fall back to the paths the offending commit itself touches.
  local conflicted
  conflicted="$(git diff --name-only --diff-filter=U 2>/dev/null)"
  if [[ -z "$conflicted" ]]; then
    local conflicted_out conflicted_status
    conflicted_out="$(git diff-tree --no-renames -r --name-only --no-commit-id "$sha" 2>/dev/null)"
    conflicted_status=$?
    if [[ $conflicted_status -eq 0 ]]; then
      conflicted="$conflicted_out"
    fi
  fi
  [[ -n "$conflicted" ]] && ui_error "Check pass: path(s) involved: $(printf '%s\n' "$conflicted" | paste -sd' ' -)"
  git cherry-pick --abort >/dev/null 2>&1 || true
  git checkout -q "-" >/dev/null 2>&1 || true
  git branch -D "$tmp_branch" >/dev/null 2>&1 || true
}

# Print the repo-relative hook files that install-hooks manages when the
# hooks dir is a working-tree (tracked) directory — e.g. .husky/pre-commit
# and .husky/pre-push. When core.hooksPath is unset the hooks live under the
# git dir and are never part of a tracked tree, so nothing is printed.
# Absolute hooks paths that cannot be expressed repo-relative are skipped.
_hook_tree_excluded_paths() {
  local hooks_path
  hooks_path="$(git config --get core.hooksPath || true)"
  hooks_path="${hooks_path%/}"
  [[ -z "$hooks_path" ]] && return 0

  local hook_name hook_path
  for hook_name in pre-commit pre-push; do
    hook_path="$(detect_hook_file "$hook_name")"
    case "$hook_path" in
      .git/*) continue ;;
    esac
    if [[ "$hook_path" == /* ]]; then
      hook_path="${hook_path#$PWD/}"
      [[ "$hook_path" == /* ]] && continue
    fi
    printf '%s\n' "${hook_path#./}"
  done
}

# Compare two tree-ishs.  For every file in <expected_tree>, the same file must
# exist in <actual_tree> with the same blob.  Local-only additions are ignored.
# Returns 0 if the public-tracked files match, 1 otherwise.
# Returns 1 if `git diff-tree` fails.
check_tree_matches() {
  local expected_tree="$1"
  local actual_tree="$2"

  local diff_output diff_status
  diff_output="$(git diff-tree --no-renames -r "$expected_tree" "$actual_tree" 2>/dev/null)"
  diff_status=$?
  if [[ $diff_status -ne 0 ]]; then
    ui_error "check_tree_matches: cannot compare trees $expected_tree and $actual_tree"
    return 1
  fi

  # Hook files install-hooks manages in a working-tree hooks dir may differ
  # between the trees without being a publication problem.
  local -a excluded=()
  local excl
  while IFS= read -r excl; do
    [[ -n "$excl" ]] && excluded+=("$excl")
  done < <(_hook_tree_excluded_paths)

  local result=0
  local line status path e
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # diff-tree --no-renames -r output format:
    # :<old-mode> <new-mode> <old-sha> <new-sha> <status>\t<path>
    # We only care about status (5th awk field) and whether any non-A status
    # appears for a path in the expected tree.
    status="$(printf '%s\n' "$line" | awk '{print $5}')"
    path="$(printf '%s\n' "$line" | awk -F'\t' '{print $2}')"
    if [[ "$status" != "A" ]]; then
      for e in "${excluded[@]}"; do
        [[ "$path" == "$e" ]] && continue 2
      done
      ui_error "Check pass: public tree differs at '$path' (status $status)."
      result=1
    fi
  done < <(printf '%s\n' "$diff_output")

  return $result
}

# Replay public commits from <local_branch> onto a temporary branch rooted at
# <checkpoint_public>, verify the replayed tree matches <local_branch>, and on
# success set the variable named by <out_branch_var> to the temp branch name
# and print the public commit SHAs (one per line) to stdout.  The temp branch
# name must not travel on stdout: callers invoke this outside command
# substitution, redirecting stdout to a file, so the printf -v assignment
# survives in the caller's scope.  <out_branch_var> is set empty when there is
# nothing to publish.  Returns 1 on pre-flight, replay, or tree mismatch
# failure and cleans up the temp branch.  The temp branch is left in place for
# the caller on success.
publish_replay_and_head() {
  # shellcheck disable=SC2034  # part of the documented argument list; kept for call-site symmetry
  local public_branch="$1"
  local local_branch="$2"
  local checkpoint_public="$3"
  local checkpoint_local="$4"
  local out_branch_var="$5"

  printf -v "$out_branch_var" ''

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

  # The replay runs in the current shell (the checkout to the temp branch
  # must survive); its stdout carries the applied commit SHAs. The caller's
  # stdout stays clean for the final SHA list.
  local applied_file
  applied_file="$(mktemp)"
  if ! check_replay_public "$checkpoint_public" "$tmp_branch" $public_commits >"$applied_file"; then
    rm -f "$applied_file"
    git checkout -q "${original_branch}" >/dev/null 2>&1 || true
    return 1
  fi

  local tmp_head local_head
  tmp_head="$(git rev-parse "$tmp_branch")"
  local_head="$(git rev-parse "$local_branch")"

  if ! check_tree_matches "$tmp_head" "$local_head"; then
    rm -f "$applied_file"
    git checkout -q "${original_branch}" >/dev/null 2>&1 || true
    git branch -D "$tmp_branch" >/dev/null 2>&1 || true
    return 1
  fi

  # Return to the original branch but leave the temp branch for the caller.
  git checkout -q "${original_branch}" >/dev/null 2>&1 || true

  cat "$applied_file"
  rm -f "$applied_file"
  printf -v "$out_branch_var" '%s' "$tmp_branch"
}
