#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: doctor.sh
# Purpose: run git-shadow diagnostics for the current repo.
#
# Usage: git shadow doctor [--fix]
# -------------------------------------------------------------------

# Environment setup
TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$TOOLKIT_ROOT/lib/common.sh"
# shellcheck disable=SC1091  # resolved relative to this script location at runtime
source "$TOOLKIT_ROOT/lib/doctor.sh"

usage() {
  cat <<'EOF'
Usage: git shadow doctor [--fix]
EOF
}

FIX=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix) FIX=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ui_error "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

enter_project '.'

if [[ "$FIX" -eq 1 ]]; then
  doctor_fix
else
  doctor_run
fi
if [[ ${DOCTOR_WARNINGS:-0} -gt 0 ]]; then
  exit 1
fi
exit 0
