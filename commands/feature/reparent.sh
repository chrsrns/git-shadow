#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/reparent.sh
# Purpose: rewrite a feature pair's shadow-parent — a config-only
#          operation performing no branch, tree, or state mutation
#          beyond branch.<name><LOCAL_SUFFIX>.shadow-parent.
# -------------------------------------------------------------------

_GS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/help.sh"
if gs_help_requested --onto -- "$@"; then
  echo "Usage: git shadow feature reparent <name> --onto <parent>"
  exit 0
fi

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/common.sh"

enter_project '.'

FEATURE_NAME_ARG=""
ONTO_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --onto)
      shift
      if [[ $# -eq 0 ]]; then
        ui_error "--onto requires a parent branch name."
        exit 1
      fi
      ONTO_ARG="$1"
      ;;
    -*)
      ui_error "Unknown option: $1"
      echo "Usage: git shadow feature reparent <name> --onto <parent>" >&2
      exit 1
      ;;
    *)
      if [[ -n "$FEATURE_NAME_ARG" ]]; then
        ui_error "feature reparent accepts a single feature name."
        echo "Usage: git shadow feature reparent <name> --onto <parent>" >&2
        exit 1
      fi
      FEATURE_NAME_ARG="$1"
      ;;
  esac
  shift
done

if [[ -z "$FEATURE_NAME_ARG" ]]; then
  ui_error "feature reparent requires a feature name."
  echo "Usage: git shadow feature reparent <name> --onto <parent>" >&2
  exit 1
fi
if [[ -z "$ONTO_ARG" ]]; then
  ui_error "feature reparent requires '--onto <parent>'."
  echo "Usage: git shadow feature reparent <name> --onto <parent>" >&2
  exit 1
fi

FEATURE_PUBLIC="$(public_branch_from_any "$FEATURE_NAME_ARG")"
FEATURE_LOCAL="${FEATURE_PUBLIC}${LOCAL_SUFFIX}"

if [[ "$FEATURE_PUBLIC" == "$PUBLIC_BASE_BRANCH" ]]; then
  ui_error "Cannot reparent the base pair '$PUBLIC_BASE_BRANCH'."
  exit 1
fi
if ! branch_exists "$FEATURE_PUBLIC" || ! branch_exists "$FEATURE_LOCAL"; then
  ui_error "Feature pair does not exist: '$FEATURE_PUBLIC' (needs both '$FEATURE_PUBLIC' and '$FEATURE_LOCAL')."
  exit 1
fi

PARENT_PUBLIC="$(public_branch_from_any "$ONTO_ARG")"
CONFIG_KEY="branch.${FEATURE_LOCAL}.shadow-parent"

# Targeting the base pair — either spelling — clears the link and
# unstacks the feature.
if [[ "$PARENT_PUBLIC" == "$PUBLIC_BASE_BRANCH" ]]; then
  git config --unset "$CONFIG_KEY" 2>/dev/null || true
  ui_ok "Unstacked '$FEATURE_PUBLIC' — effective base is now the base pair."
  exit 0
fi

if [[ "$PARENT_PUBLIC" == "$FEATURE_PUBLIC" ]]; then
  ui_error "Cannot stack '$FEATURE_PUBLIC' on itself."
  exit 1
fi
if ! branch_exists "$PARENT_PUBLIC" || ! branch_exists "${PARENT_PUBLIC}${LOCAL_SUFFIX}"; then
  ui_error "Stack parent pair does not exist: '$PARENT_PUBLIC' (needs both '$PARENT_PUBLIC' and '${PARENT_PUBLIC}${LOCAL_SUFFIX}')."
  exit 1
fi

# Pending-edge validation: cycle and own-chain depth abort before the
# config write; _STACK_DEPTH holds the new chain length on success.
stack_validate_edge "$FEATURE_LOCAL" "$PARENT_PUBLIC" || exit 1
new_depth="${_STACK_DEPTH:-0}"

# Descendant depth: any @local whose chain reaches this pair gains the
# new link count — abort naming the pair pushed past the cap.
_desc="" links=""
while IFS= read -r _desc; do
  [[ -z "$_desc" || "$_desc" == "$FEATURE_LOCAL" ]] && continue
  links="$(_stack_links_to "$_desc" "$FEATURE_LOCAL")" || continue
  if (( links + new_depth > 8 )); then
    ui_error "Reparenting '$FEATURE_PUBLIC' would push '${_desc%${LOCAL_SUFFIX}}' past stack depth 8 (chain: ${_desc} -> $FEATURE_LOCAL -> ${PARENT_PUBLIC}${LOCAL_SUFFIX})."
    exit 1
  fi
done < <(local_branch_refs)

git config "$CONFIG_KEY" "$PARENT_PUBLIC"
ui_ok "Reparented '$FEATURE_PUBLIC' onto '$PARENT_PUBLIC'."
