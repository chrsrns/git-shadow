#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow version
# Purpose: print the current version of git-shadow.
# -------------------------------------------------------------------

TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$TOOLKIT_ROOT/lib/help.sh"
if gs_help_requested -- "$@"; then
  echo "Usage: git shadow version [<ignored>...]"
  exit 0
fi
cat "$TOOLKIT_ROOT/VERSION"
