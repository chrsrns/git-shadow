#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: status.sh
# Purpose: report the diff-sync state of the current branch using checkpoints.
#
# Usage: git shadow status [--json]
# -------------------------------------------------------------------

_GS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/help.sh"
if gs_help_requested -- "$@"; then
  echo "Usage: git shadow status [--json]"
  exit 0
fi

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/common.sh"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/config-utils.sh"

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

# Dirt counts from the shared classifier records; `?`/`null` when the
# enumeration itself fails (a silent zero would mask a failed probe).
DIRT_RECS="$(mktemp)"
trap 'rm -f "$DIRT_RECS"' EXIT
if patches_dirty_records > "$DIRT_RECS"; then
  LOCAL_PATCHES=0
  UNPATCHED_DIRTY=0
  while IFS= read -r -d '' _rec || [[ -n "$_rec" ]]; do
    [[ -z "$_rec" ]] && continue
    _class="$(printf '%s' "$_rec" | cut -f2)"
    if [[ "$_class" == "patch" ]]; then
      LOCAL_PATCHES=$((LOCAL_PATCHES + 1))
    else
      UNPATCHED_DIRTY=$((UNPATCHED_DIRTY + 1))
    fi
  done < "$DIRT_RECS"
  unset _rec _class
  DIRTY_FAILED=0
else
  LOCAL_PATCHES="?"
  UNPATCHED_DIRTY="?"
  DIRTY_FAILED=1
fi

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
  if branch_exists "$candidate"; then
    BRANCH_TYPE="public"
    PUBLIC_BRANCH="$CURRENT_BRANCH"
    SHADOW_BRANCH="$candidate"
  fi
fi

if [[ "$BRANCH_TYPE" == "unknown" ]]; then
  if [[ "$JSON" -eq 1 ]]; then
    printf '{"current_branch":"%s","branch_type":"unknown","error":"Not a Git Shadow branch"}\n' \
      "$(json_escape "$CURRENT_BRANCH")"
  else
    ui_error "Not a Git Shadow branch: '$CURRENT_BRANCH'."
  fi
  exit 1
fi

# Dirt fields render as null in --json when the enumeration failed.
if [[ "$DIRTY_FAILED" -eq 1 ]]; then
  LP_JSON=null; UD_JSON=null
else
  LP_JSON="$LOCAL_PATCHES"; UD_JSON="$UNPATCHED_DIRTY"
fi

# If the public branch does not exist, report missing.
if ! branch_exists "$PUBLIC_BRANCH"; then
  if [[ "$JSON" -eq 1 ]]; then
    printf '{"current_branch":"%s","branch_type":"%s","public_branch":"%s","shadow_branch":"%s","publishable":0,"public_ahead":0,"diverged":false,"local_patches":%s,"unpatched_dirty":%s,"status":"public branch missing"}\n' \
      "$(json_escape "$CURRENT_BRANCH")" "$(json_escape "$BRANCH_TYPE")" \
      "$(json_escape "$PUBLIC_BRANCH")" "$(json_escape "$SHADOW_BRANCH")" \
      "$LP_JSON" "$UD_JSON"
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
    echo "local-patches : $LOCAL_PATCHES"
    echo "unpatched-dirty : $UNPATCHED_DIRTY"
  fi
  exit 0
fi

LATEST_CP="$(checkpoint_latest "$SHADOW_BRANCH")"

if [[ -z "$LATEST_CP" ]]; then
  if [[ "$JSON" -eq 1 ]]; then
    printf '{"current_branch":"%s","branch_type":"%s","public_branch":"%s","shadow_branch":"%s","status":"uninitialized"}\n' \
      "$(json_escape "$CURRENT_BRANCH")" "$(json_escape "$BRANCH_TYPE")" \
      "$(json_escape "$PUBLIC_BRANCH")" "$(json_escape "$SHADOW_BRANCH")"
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

# Publishable public commits on shadow since checkpoint local. A failed
# range listing reports 0, matching the previous inline loop's behavior.
if ! PUBLISHABLE="$(check_publishable_count "$SHADOW_BRANCH" "$CP_LOCAL" 2>/dev/null)"; then
  PUBLISHABLE=0
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
  if [[ "$PUBLIC_AHEAD" == "?" ]]; then
    public_ahead_json='"?"'
  else
    public_ahead_json="$PUBLIC_AHEAD"
  fi
  printf '{"current_branch":"%s","branch_type":"%s","public_branch":"%s","shadow_branch":"%s","publishable":%d,"public_ahead":%s,"diverged":%s,"local_patches":%s,"unpatched_dirty":%s,"checkpoint_public":"%s","checkpoint_local":"%s"}\n' \
    "$(json_escape "$CURRENT_BRANCH")" "$(json_escape "$BRANCH_TYPE")" \
    "$(json_escape "$PUBLIC_BRANCH")" "$(json_escape "$SHADOW_BRANCH")" \
    "$PUBLISHABLE" "$public_ahead_json" "$DIVERGED" "$LP_JSON" "$UD_JSON" "$CP_PUBLIC" "$CP_LOCAL"
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
    ui_shadow "local-patches : $LOCAL_PATCHES"
    ui_shadow "unpatched-dirty : $UNPATCHED_DIRTY"
  fi
fi
