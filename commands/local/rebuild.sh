#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: commands/local/rebuild.sh
# Purpose: rebuild a local shadow branch from its public counterpart,
#          keeping unique [MEMORY] commits and dropping duplicates.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/merge.sh"

enter_project "."

CURRENT_BRANCH="$(current_branch)"
FORCE=0

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
ARG="${ARGS[0]:-}"

# ---------------------------------------------------------------------------
# Resolve local and public branches
# ---------------------------------------------------------------------------
if [[ -n "$ARG" ]]; then
  if [[ "$ARG" =~ ${LOCAL_SUFFIX}$ ]]; then
    LOCAL_BRANCH="$ARG"
  else
    LOCAL_BRANCH="${ARG}${LOCAL_SUFFIX}"
  fi
else
  if [[ -z "$CURRENT_BRANCH" ]]; then
    ui_error "Unable to determine current branch."
    exit 1
  fi
  if [[ ! "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
    ui_error "Current branch '$CURRENT_BRANCH' is not a shadow branch."
    ui_step "Run from a shadow branch or pass the local branch name."
    exit 1
  fi
  LOCAL_BRANCH="$CURRENT_BRANCH"
fi

PUBLIC_BRANCH="$(public_branch_from_any "$LOCAL_BRANCH")"

if ! git rev-parse --verify "refs/heads/$LOCAL_BRANCH" >/dev/null 2>&1; then
  ui_error "Local branch not found: $LOCAL_BRANCH"
  exit 1
fi
if ! git rev-parse --verify "refs/heads/$PUBLIC_BRANCH" >/dev/null 2>&1; then
  ui_error "Public branch not found: $PUBLIC_BRANCH"
  exit 1
fi

NEW_BRANCH="${LOCAL_BRANCH}-rebuild"
BACKUP_BRANCH="${LOCAL_BRANCH}-old"

if git rev-parse --verify "refs/heads/$NEW_BRANCH" >/dev/null 2>&1; then
  ui_error "Rebuild branch already exists: $NEW_BRANCH"
  ui_step "Delete it first or choose another name."
  exit 1
fi

ui_shadow "Rebuilding '$LOCAL_BRANCH' from '$PUBLIC_BRANCH'"

# ---------------------------------------------------------------------------
# Collect unique [MEMORY] commits
# ---------------------------------------------------------------------------
declare -A seen_patch
declare -a memory_shas

while IFS='|' read -r sha ts subject; do
  [[ -z "$sha" ]] && continue
  [[ "$subject" =~ $SHADOW_COMMIT_FILTER ]] || continue

  patch_id="$(git diff-tree -p "$sha^!" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')"
  [[ -z "$patch_id" ]] && continue

  if [[ -z "${seen_patch[$patch_id]:-}" ]]; then
    seen_patch[$patch_id]=1
    memory_shas+=("$sha")
  else
    ui_skip "Skipping duplicate [MEMORY] commit: $sha $subject"
  fi
done < <(git log --format='%H|%ct|%s' --reverse "$LOCAL_BRANCH" --not "$PUBLIC_BRANCH" --)

if [[ ${#memory_shas[@]} -eq 0 ]]; then
  ui_info "No [MEMORY] commits to replay. '$LOCAL_BRANCH' already matches '$PUBLIC_BRANCH'."
  git checkout -q -b "$NEW_BRANCH" "$PUBLIC_BRANCH"
  ui_ok "Created '$NEW_BRANCH' at the current public tip."
  exit 0
fi

ui_info "Found ${#memory_shas[@]} unique [MEMORY] commit(s) to replay."

# ---------------------------------------------------------------------------
# Create the new branch and replay each unique [MEMORY] commit
# ---------------------------------------------------------------------------
git checkout -q -b "$NEW_BRANCH" "$PUBLIC_BRANCH"

for sha in "${memory_shas[@]}"; do
  subject="$(git log -1 --format='%s' "$sha")"
  author_name="$(git log -1 --format='%an' "$sha")"
  author_email="$(git log -1 --format='%ae' "$sha")"
  adate="$(git log -1 --format='%aI' "$sha")"
  committer_name="$(git log -1 --format='%cn' "$sha")"
  committer_email="$(git log -1 --format='%ce' "$sha")"
  cdate="$(git log -1 --format='%cI' "$sha")"

  ui_info "Replaying: $subject"

  if git merge --squash --no-commit "$sha" >/dev/null 2>&1; then
    if git diff --cached --quiet; then
      ui_skip "Empty squash, skipping"
      continue
    fi
  else
    resolve_merge_conflicts "theirs" "skip-continue"
    if git diff --cached --quiet; then
      ui_skip "Empty squash after conflict resolution, skipping"
      continue
    fi
  fi

  # Preserve the original author and committer so the replayed commit is
  # identical to the original when the parent tree has not changed.
  env \
    GIT_AUTHOR_NAME="$author_name" \
    GIT_AUTHOR_EMAIL="$author_email" \
    GIT_AUTHOR_DATE="$adate" \
    GIT_COMMITTER_NAME="$committer_name" \
    GIT_COMMITTER_EMAIL="$committer_email" \
    GIT_COMMITTER_DATE="$cdate" \
    git commit -m "$subject" --no-verify
  ui_ok "Replayed: $subject"
done

# ---------------------------------------------------------------------------
# Replace the original branch or leave the new branch for verification
# ---------------------------------------------------------------------------
if [[ "$FORCE" -eq 1 ]]; then
  # Find an available backup name
  backup_name="$BACKUP_BRANCH"
  n=1
  while git rev-parse --verify "refs/heads/${backup_name}" >/dev/null 2>&1; do
    backup_name="${BACKUP_BRANCH}-${n}"
    n=$((n + 1))
  done

  git branch -m "$LOCAL_BRANCH" "$backup_name"
  git branch -m "$NEW_BRANCH" "$LOCAL_BRANCH"
  git checkout -q "$LOCAL_BRANCH"

  ui_ok "Rebuilt '$LOCAL_BRANCH' (old branch saved as '$backup_name')"
else
  git checkout -q "$LOCAL_BRANCH" 2>/dev/null || true
  ui_ok "Created rebuild branch: $NEW_BRANCH"
  ui_step "Inspect it with: git log --oneline --graph $NEW_BRANCH"
  ui_step "Replace the old branch with:"
  ui_step "  git branch -D $LOCAL_BRANCH && git branch -m $NEW_BRANCH $LOCAL_BRANCH"
fi
