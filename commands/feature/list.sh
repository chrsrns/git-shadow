#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/list.sh
# Purpose: list every open feature pair — a public <name> plus its
#          <name>@local — with worktree, checkpoint, and publishable
#          count. Read-only; emits no check-pass diagnostics.
# -------------------------------------------------------------------

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: git shadow feature list [--json]
EOF
}

JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ui_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

enter_project '.'

PUBLIC_BASE="${PUBLIC_BASE_BRANCH:-main}"

# A pair is listed only when both branches exist; an orphan <name>@local
# without its public counterpart is not a feature. The local base pair is
# never a feature.
names=()
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  name="${ref%${LOCAL_SUFFIX}}"
  [[ "$name" == "$PUBLIC_BASE" ]] && continue
  git show-ref --verify --quiet "refs/heads/$name" || continue
  names+=("$name")
done < <(git for-each-ref --format='%(refname:short)' "refs/heads/*${LOCAL_SUFFIX}" | sort)

# The field reports only a dedicated worktree; a pair checked out in the
# main worktree shows -.
main_worktree="$(git rev-parse --show-toplevel)"

json_items=()
for name in "${names[@]}"; do
  local_ref="${name}${LOCAL_SUFFIX}"

  worktree_path="$(worktree_find_for_branch "$local_ref" 2>/dev/null)" || worktree_path=""
  if [[ -z "$worktree_path" || "$worktree_path" == "$main_worktree" ]]; then
    worktree_path="-"
  fi

  cp="$(checkpoint_latest "$local_ref")"
  if [[ -z "$cp" ]]; then
    checkpoint_str="-"
    publishable=0
  else
    checkpoint_str="$(git log -1 --format='%s' "$cp")"
    cp_local="$(checkpoint_local "$cp")"
    if ! publishable="$(check_publishable_count "$local_ref" "$cp_local" 2>/dev/null)"; then
      publishable=0
    fi
  fi

  if [[ "$JSON" -eq 0 ]]; then
    printf '%s\n' "$name"
    printf '  worktree   : %s\n' "$worktree_path"
    printf '  checkpoint : %s\n' "$checkpoint_str"
    printf '  publishable: %s\n' "$publishable"
  else
    json_items+=("{\"name\":\"$name\",\"worktree\":\"$worktree_path\",\"checkpoint\":\"$checkpoint_str\",\"publishable\":$publishable}")
  fi
done

if [[ "$JSON" -eq 1 ]]; then
  if [[ ${#json_items[@]} -eq 0 ]]; then
    printf '[]\n'
  else
    joined="$(printf '%s,' "${json_items[@]}")"
    printf '[%s]\n' "${joined%,}"
  fi
fi
