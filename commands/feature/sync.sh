#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/sync.sh
# Purpose: thin wrapper around lib/sync-command.sh:sync_command_run.
#
# Usage: git shadow feature sync [--recover] [--continue|--abort]
# -------------------------------------------------------------------

_GS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/help.sh"
if gs_help_requested -- "$@"; then
  echo "Usage: git shadow feature sync [--recover] [--continue|--abort]"
  exit 0
fi

# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$_GS_LIB/common.sh"

sync_command_run feature "$@"
