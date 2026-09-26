#!/usr/bin/env bash
# -------------------------------------------------------------------
# Library: help.sh
# Purpose: pre-config -h|--help detection for leaf commands. Safe to
#          source before lib/common.sh — it loads no configuration,
#          reads no repository state, and performs no I/O.
# -------------------------------------------------------------------

# gs_help_requested [<value-option>...] -- <argv>
#
# Returns 0 when argv contains an unconsumed -h or --help token.
# <value-option> entries name options that consume the following token
# as their value (e.g. -m, --message, --worktree-dir, --mark-applied);
# a -h|--help in that value position is data, not a help request.
# Positional slots and tolerated surplus operands never consume a help
# token, and tokens after the first recognized help token are ignored.
gs_help_requested() {
  local skip_next=0 arg
  local -A _value_opts=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    _value_opts["$1"]=1
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  for arg in "$@"; do
    if [[ "$skip_next" -eq 1 ]]; then
      skip_next=0
      continue
    fi
    if [[ -n "${_value_opts[$arg]:-}" ]]; then
      skip_next=1
      continue
    fi
    case "$arg" in
      -h|--help) return 0 ;;
    esac
  done
  return 1
}
