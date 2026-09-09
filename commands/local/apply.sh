#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow local apply
# Purpose: re-apply every stored .git-shadow/patches sidecar.
#          Use as a recovery tool after a crash or manual checkout.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"

enter_project '.'
require_local_branch
patches_require_no_paused_op

patches_reapply
ui_ok "Local patches reapplied."
