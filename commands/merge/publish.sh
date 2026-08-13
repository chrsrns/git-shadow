#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: merge/publish.sh
# Purpose: cherry-pick clean commits from a shadow branch to its public
#          counterpart. This is the publish step of the merge-only workflow.
#
# The cherry-pick logic is identical to `git shadow feature publish`, so
# this script delegates to the existing implementation.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

exec "$TOOLKIT_ROOT/commands/feature/publish.sh" "$@"
