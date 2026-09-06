#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Library: env.sh
# Purpose: load configuration using a three-tier hierarchy.
#
# Priority (highest to lowest):
#   1. Project-level : .git-shadow.env  (in $PWD when command runs)
#   2. User-level    : ~/.config/git-shadow/config.env  (XDG-aware)
#   3. Built-in defaults : config/defaults.env  (shipped with the tool)
# -------------------------------------------------------------------

TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Warn about any key in FILE that is not declared in config/defaults.env.
_check_unknown_keys() {
  local file="$1"
  local line key
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]] || continue
    key="${BASH_REMATCH[1]}"
    if ! grep -qE "^${key}=" "$TOOLKIT_ROOT/config/defaults.env"; then
      printf '⚠️  [git-shadow] Unknown config key "%s" in: %s\n' "$key" "$file" >&2
    fi
  done < "$file"
}

# Source a single config file and optionally warn on unknown keys.
_load_config_file() {
  local file="$1"
  local check_unknown="${2:-0}"

  [[ -f "$file" ]] || return 0

  set -a
  # shellcheck disable=SC1090,SC1091
  source "$file"
  set +a

  if [[ "$check_unknown" == "1" ]]; then
    _check_unknown_keys "$file"
  fi
}

load_env() {
  # 1. Built-in defaults (always present, shipped with the tool)
  _load_config_file "$TOOLKIT_ROOT/config/defaults.env" 0

  # 2. User-level config (XDG-aware, optional)
  local user_config="${XDG_CONFIG_HOME:-$HOME/.config}/git-shadow/config.env"
  _load_config_file "$user_config" 1

  # 3. Project-level config (optional, from current working directory)
  _load_config_file "$PWD/.git-shadow.env" 1
}
