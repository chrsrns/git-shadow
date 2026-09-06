#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: doctor.sh
# Purpose: run read-only git-shadow diagnostics for the current repo.
#
# Usage: git shadow doctor
# -------------------------------------------------------------------

# Environment setup
TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLKIT_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$TOOLKIT_ROOT/lib/doctor.sh"

enter_project '.'

doctor_run
if [[ ${DOCTOR_WARNINGS:-0} -gt 0 ]]; then
  exit 1
fi
exit 0
