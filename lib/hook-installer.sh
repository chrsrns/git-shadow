#!/usr/bin/env bash
# -------------------------------------------------------------------
# Library: hook-installer.sh
# Purpose: install git hooks with idempotent markers.
# -------------------------------------------------------------------

# Install a git hook file.
#
# Usage: install_hook_file <hook_name> <marker> <content> [shebang]
#
# The caller passes the <content> with no shebang. When a new hook is created,
# the shebang line is prepended exactly once. When the hook already exists, the
# marker and content are appended, keeping the existing shebang.
install_hook_file() {
  local hook_name="$1"
  local marker="$2"
  local content="$3"
  local shebang="${4:-sh}"

  local hook_file
  hook_file="$(detect_hook_file "$hook_name")"
  mkdir -p "$(dirname "$hook_file")"

  if [[ -f "$hook_file" ]] && grep -Fq "$marker" "$hook_file"; then
    ui_info "$hook_name hook already installed in: $hook_file"
    return 0
  fi

  if [[ -f "$hook_file" ]]; then
    {
      printf '\n%s\n%s\n' "$marker" "$content"
    } >> "$hook_file"
  else
    {
      printf '#!/usr/bin/env %s\n%s\n%s\n' "$shebang" "$marker" "$content"
    } > "$hook_file"
    chmod +x "$hook_file"
  fi

  ui_ok "$hook_name hook installed in: $hook_file"
}
