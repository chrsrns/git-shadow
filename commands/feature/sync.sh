#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: feature/sync.sh
# Purpose: thin wrapper around lib/sync-command.sh:sync_command_run.
#
# Usage: git shadow feature sync [--recover] [--continue|--abort]
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

sync_command_run feature "$@"
