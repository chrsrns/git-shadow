#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: status.sh
# Purpose: report the diff-sync state of the current branch using checkpoints.
#
# Usage: git shadow status [--json]
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1 ;;
    -h|--help)
      echo "Usage: git shadow status [--json]"
      exit 0
      ;;
    *)
      ui_error "Unknown option: $1"
      echo "Usage: git shadow status [--json]"
      exit 1
      ;;
  esac
  shift
done

enter_project '.'

CURRENT_BRANCH="$(current_branch)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  if [[ "$JSON" -eq 1 ]]; then
    printf '{"current_branch":null,"error":"Detached HEAD"}\n'
  else
    ui_error "Detached HEAD."
  fi
  exit 1
fi

if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  if [[ "$JSON" -eq 1 ]]; then
    printf '{"current_branch":null,"error":"Empty repository"}\n'
  else
    ui_error "Repository has no commits."
  fi
  exit 1
fi

# Branch type detection
PUBLIC_BRANCH=""
SHADOW_BRANCH=""
BRANCH_TYPE="unknown"

if [[ "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
  BRANCH_TYPE="shadow"
  SHADOW_BRANCH="$CURRENT_BRANCH"
  PUBLIC_BRANCH="$(public_branch_from_any "$CURRENT_BRANCH")"
else
  candidate="${CURRENT_BRANCH}${LOCAL_SUFFIX}"
  if git show-ref --verify --quiet "refs/heads/$candidate"; then
    BRANCH_TYPE="public"
    PUBLIC_BRANCH="$CURRENT_BRANCH"
    SHADOW_BRANCH="$candidate"
  fi
fi

if [[ "$BRANCH_TYPE" == "unknown" ]]; then
  if [[ "$JSON" -eq 1 ]]; then
    printf '{"current_branch":"%s","branch_type":"unknown","error":"Not a Git Shadow branch"}\n' "$CURRENT_BRANCH"
  else
    ui_error "Not a Git Shadow branch: '$CURRENT_BRANCH'."
  fi
  exit 1
fi

# If the public branch does not exist, report missing.
if ! git show-ref --verify --quiet "refs/heads/$PUBLIC_BRANCH"; then
  if [[ "$JSON" -eq 1 ]]; then
    printf '{"current_branch":"%s","branch_type":"%s","public_branch":"%s","shadow_branch":"%s","publishable":0,"public_ahead":0,"diverged":false,"status":"public branch missing"}\n' \
      "$CURRENT_BRANCH" "$BRANCH_TYPE" "$PUBLIC_BRANCH" "$SHADOW_BRANCH"
  else
    ui_shadow "Current branch: $CURRENT_BRANCH"
    ui_git    "Branch type   : $BRANCH_TYPE"
    ui_shadow "Public branch : $PUBLIC_BRANCH (missing)"
    ui_git    "Shadow branch : $SHADOW_BRANCH"
    echo
    ui_warn "Status    : public branch missing"
    echo "publishable : 0"
    echo "public-ahead: 0"
    echo "diverged    : false"
  fi
  exit 0
fi

LATEST_CP="$(checkpoint_latest "$SHADOW_BRANCH")"

if [[ -z "$LATEST_CP" ]]; then
  if [[ "$JSON" -eq 1 ]]; then
    printf '{"current_branch":"%s","branch_type":"%s","public_branch":"%s","shadow_branch":"%s","status":"uninitialized"}\n' \
      "$CURRENT_BRANCH" "$BRANCH_TYPE" "$PUBLIC_BRANCH" "$SHADOW_BRANCH"
  else
    ui_shadow "Current branch: $CURRENT_BRANCH"
    ui_git    "Branch type   : $BRANCH_TYPE"
    ui_shadow "Public branch : $PUBLIC_BRANCH"
    ui_git    "Shadow branch : $SHADOW_BRANCH"
    echo
    ui_warn "Status    : uninitialized (no checkpoint found)"
  fi
  exit 0
fi

CP_PUBLIC="$(checkpoint_public "$LATEST_CP")"
CP_LOCAL="$(checkpoint_local "$LATEST_CP")"
PUBLIC_HEAD="$(git rev-parse "$PUBLIC_BRANCH")"
LOCAL_HEAD="$(git rev-parse "$SHADOW_BRANCH")"

# Publishable public commits on shadow since checkpoint local (non-MEMORY, non-CHECKPOINT)
PUBLISHABLE=0
if [[ "$CP_LOCAL" != "$LOCAL_HEAD" ]]; then
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    subject="$(git log -1 --format='%s' "$sha")"
    if [[ ! "$subject" == "[MEMORY]"* && ! "$subject" == "[CHECKPOINT]"* ]]; then
      ((PUBLISHABLE++)) || true
    fi
  done < <(git rev-list --reverse "${CP_LOCAL}..${LOCAL_HEAD}")
fi

# Public commits on public branch since checkpoint public
PUBLIC_AHEAD=0
if [[ "$CP_PUBLIC" != "$PUBLIC_HEAD" ]]; then
  if git merge-base --is-ancestor "$CP_PUBLIC" "$PUBLIC_HEAD"; then
    PUBLIC_AHEAD="$(git rev-list --count "${CP_PUBLIC}..${PUBLIC_HEAD}")"
  else
    PUBLIC_AHEAD="?"
  fi
fi

# Diverged if the local tree does not contain the public tree.
DIVERGED="false"
if ! check_tree_matches "$PUBLIC_HEAD" "$LOCAL_HEAD" 2>/dev/null; then
  DIVERGED="true"
fi

if [[ "$JSON" -eq 1 ]]; then
  public_ahead_json="$PUBLIC_AHEAD"
  printf '{"current_branch":"%s","branch_type":"%s","public_branch":"%s","shadow_branch":"%s","publishable":%d,"public_ahead":%s,"diverged":%s,"checkpoint_public":"%s","checkpoint_local":"%s"}\n' \
    "$CURRENT_BRANCH" "$BRANCH_TYPE" "$PUBLIC_BRANCH" "$SHADOW_BRANCH" \
    "$PUBLISHABLE" "$public_ahead_json" "$DIVERGED" "$CP_PUBLIC" "$CP_LOCAL"
else
  ui_shadow "Current branch : $CURRENT_BRANCH"
  ui_git    "Branch type    : $BRANCH_TYPE"
  ui_shadow "Public branch  : $PUBLIC_BRANCH"
  ui_git    "Shadow branch  : $SHADOW_BRANCH"
  echo
  if [[ "$PUBLIC_AHEAD" == "?" ]]; then
    ui_warn "public-ahead : public branch has moved non-fast-forward"
  else
    ui_shadow "publishable  : $PUBLISHABLE"
    ui_shadow "public-ahead : $PUBLIC_AHEAD"
    ui_shadow "diverged     : $DIVERGED"
  fi
fi
