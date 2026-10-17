#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow local status [--porcelain|--json] [<ignored>...]
# Purpose: report every dirty path classified (patch / patch-stale /
#          dirty / staged / untracked) plus unapplied sidecars.
# -------------------------------------------------------------------

_GS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/help.sh"
if gs_help_requested -- "$@"; then
  echo "Usage: git shadow local status [--porcelain|--json] [<ignored>...]"
  exit 0
fi

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/common.sh"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/config-utils.sh"

MODE="human"
for arg in "$@"; do
  case "$arg" in
    --porcelain) MODE="porcelain" ;;
    --json)      MODE="json" ;;
  esac
done

enter_project '.'
patches_require_no_paused_op

# Buffer the classified records so an enumeration failure is visible.
RECS="$(mktemp)"
trap 'rm -f "$RECS"' EXIT
if ! patches_dirty_records > "$RECS"; then
  ui_error "Unable to enumerate working tree status."
  exit 1
fi

UNAPPLIED="$(patches_unapplied_sidecars)" || {
  ui_error "Unable to enumerate working tree status."
  exit 1
}

case "$MODE" in
  porcelain)
    while IFS= read -r -d '' rec || [[ -n "$rec" ]]; do
      [[ -z "$rec" ]] && continue
      xy="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
      class="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
      printf '%s %s %s\n' "$xy" "$(patches_cquote "$path")" "$class"
    done < "$RECS"
    if [[ -n "$UNAPPLIED" ]]; then
      while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        printf -- '-  %s unapplied\n' "$(patches_cquote "$rel")"
      done <<< "$UNAPPLIED"
    fi
    ;;
  json)
    printf '{'
    printf '"entries":['
    first=1
    while IFS= read -r -d '' rec || [[ -n "$rec" ]]; do
      [[ -z "$rec" ]] && continue
      xy="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
      class="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
      [[ "$first" -eq 0 ]] && printf ','
      first=0
      printf '{"path":"%s","xy":"%s","class":"%s"}' \
        "$(json_escape "$path")" "$(json_escape "$xy")" "$(json_escape "$class")"
    done < "$RECS"
    printf '],'
    printf '"unapplied":['
    first=1
    if [[ -n "$UNAPPLIED" ]]; then
      while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        [[ "$first" -eq 0 ]] && printf ','
        first=0
        printf '"%s"' "$(json_escape "$rel")"
      done <<< "$UNAPPLIED"
    fi
    printf '],'
    # Counts: patch → local_patches; patch-stale/dirty/staged/untracked → unpatched_dirty.
    n_patch=0; n_dirty=0
    while IFS= read -r -d '' rec || [[ -n "$rec" ]]; do
      [[ -z "$rec" ]] && continue
      class="$(printf '%s' "$rec" | cut -f2)"
      if [[ "$class" == "patch" ]]; then
        n_patch=$((n_patch + 1))
      else
        n_dirty=$((n_dirty + 1))
      fi
    done < "$RECS"
    printf '"local_patches":%d,"unpatched_dirty":%d}\n' "$n_patch" "$n_dirty"
    ;;
  human|*)
    if [[ -s "$RECS" ]]; then
      while IFS= read -r -d '' rec || [[ -n "$rec" ]]; do
        [[ -z "$rec" ]] && continue
        xy="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
        class="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
        printf '%s %s [%s]\n' "$xy" "$path" "$class"
      done < "$RECS"
    fi
    if [[ -n "$UNAPPLIED" ]]; then
      echo "Unapplied patches:"
      while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        printf '  %s\n' "$rel"
      done <<< "$UNAPPLIED"
    fi
    if [[ ! -s "$RECS" && -z "$UNAPPLIED" ]]; then
      ui_info "No local changes."
    fi
    ;;
esac
