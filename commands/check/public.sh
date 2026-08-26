#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: commands/check/public.sh
# Purpose: audit a public branch for local-only contamination:
#          - [MEMORY] / shadow commits in its history
#          - files containing local comment markers
#          - files that originated in a [MEMORY] commit on the
#            local counterpart branch but were not promoted.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

enter_project "."

CURRENT_BRANCH="$(current_branch)"
ARG="${1:-}"

# ---------------------------------------------------------------------------
# Resolve the target public branch
# ---------------------------------------------------------------------------
if [[ -n "$ARG" ]]; then
  if [[ "$ARG" =~ ${LOCAL_SUFFIX}$ ]]; then
    TARGET_BRANCH="${ARG%"$LOCAL_SUFFIX"}"
    ui_warn "Resolved local branch '$ARG' to public branch '$TARGET_BRANCH'."
  else
    TARGET_BRANCH="$ARG"
  fi
else
  if [[ "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
    TARGET_BRANCH="${CURRENT_BRANCH%"$LOCAL_SUFFIX"}"
    ui_info "Checking public counterpart: $TARGET_BRANCH"
  else
    TARGET_BRANCH="$CURRENT_BRANCH"
  fi
fi

if ! git rev-parse --verify "refs/heads/$TARGET_BRANCH" >/dev/null 2>&1; then
  ui_error "Branch not found: $TARGET_BRANCH"
  exit 1
fi

ui_shadow "Auditing public branch: $TARGET_BRANCH"

has_violations=0
memory_commits=0
local_comment_files=0
unpromoted_files=0

# ---------------------------------------------------------------------------
# 1) Check for shadow/[MEMORY] commits in public branch history
# ---------------------------------------------------------------------------
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  sha="${line%% *}"
  subject="${line#* }"
  if [[ "$subject" =~ $SHADOW_COMMIT_FILTER ]]; then
    if [[ "$memory_commits" -eq 0 ]]; then
      ui_error "Shadow commits found on public branch '$TARGET_BRANCH':"
    fi
    ui_step "  $sha  $subject"
    memory_commits=$((memory_commits + 1))
    has_violations=1
  fi
done < <(git log --format='%H %s' --reverse "$TARGET_BRANCH" --)

# ---------------------------------------------------------------------------
# 2) Check for local comment markers in tracked files
# ---------------------------------------------------------------------------

# Return 0 if the file matches any glob in LOCAL_COMMENT_EXCLUDE, 1 otherwise.
_is_excluded() {
  local file="$1" pattern
  set -f
  for pattern in $LOCAL_COMMENT_EXCLUDE; do
    # shellcheck disable=SC2254
    case "$file" in
      $pattern) set +f; return 0 ;;
    esac
  done
  set +f
  return 1
}

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  _is_excluded "$(basename "$file")" && continue

  if git grep -nE "$LOCAL_COMMENT_PATTERN" "$TARGET_BRANCH" -- "$file" >/dev/null 2>&1; then
    if [[ "$local_comment_files" -eq 0 ]]; then
      ui_error "Files with local comments on public branch '$TARGET_BRANCH':"
    fi
    local_comment_files=$((local_comment_files + 1))
    ui_step "  $file"
    git grep -nE "$LOCAL_COMMENT_PATTERN" "$TARGET_BRANCH" -- "$file" | sed 's/^/    /' || true
    has_violations=1
  fi
done < <(git ls-tree -r --name-only "$TARGET_BRANCH" --)

# ---------------------------------------------------------------------------
# 3) Check for unpromoted / memory-first files
# ---------------------------------------------------------------------------
LOCAL_BRANCH="${TARGET_BRANCH}${LOCAL_SUFFIX}"

if git rev-parse --verify "refs/heads/$LOCAL_BRANCH" >/dev/null 2>&1; then
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue

    # First commit that added this file to the public branch
    public_first="$(git log --diff-filter=A --format='%H %s' --reverse "$TARGET_BRANCH" -- "$file" | head -1)"
    [[ -z "$public_first" ]] && continue

    public_sha="${public_first%% *}"
    public_subject="${public_first#* }"

    # Promoted files are OK: their first public commit is 'shadow: publish <path>'
    if [[ "$public_subject" == "shadow: publish $file" ]]; then
      continue
    fi

    # If the public first commit is itself a shadow commit, flag immediately
    if [[ "$public_subject" =~ $SHADOW_COMMIT_FILTER ]]; then
      if [[ "$unpromoted_files" -eq 0 ]]; then
        ui_error "Files introduced by shadow commits on public branch '$TARGET_BRANCH':"
      fi
      unpromoted_files=$((unpromoted_files + 1))
      ui_step "  $file (introduced by $public_sha $public_subject)"
      has_violations=1
      continue
    fi

    # First commit that added this file to the local counterpart branch
    local_first="$(git log --diff-filter=A --format='%H %s' --reverse "$LOCAL_BRANCH" -- "$file" | head -1)"
    [[ -z "$local_first" ]] && continue

    local_subject="${local_first#* }"

    if [[ "$local_subject" =~ $SHADOW_COMMIT_FILTER ]]; then
      if [[ "$unpromoted_files" -eq 0 ]]; then
        ui_error "Unpromoted local-only files on public branch '$TARGET_BRANCH':"
      fi
      unpromoted_files=$((unpromoted_files + 1))
      ui_step "  $file (first added on $LOCAL_BRANCH as: $local_subject)"
      has_violations=1
    fi
  done < <(git ls-tree -r --name-only "$TARGET_BRANCH" --)
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$has_violations" -eq 1 ]]; then
  echo
  ui_error "Public branch '$TARGET_BRANCH' is not clean:"
  ui_step "  - $memory_commits shadow commit(s)"
  ui_step "  - $local_comment_files file(s) with local comments"
  ui_step "  - $unpromoted_files unpromoted local-only file(s)"
  exit 1
fi

ui_ok "Public branch '$TARGET_BRANCH' is clean."
