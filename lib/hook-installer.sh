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
# marker and content are appended, keeping the existing shebang. When the hook
# already contains <marker>, the installed block (marker line through EOF — the
# block is always appended last by this tool) is compared against the freshly
# rendered marker+content: identical means "already installed"; different means
# the block is regenerated in place so config changes (e.g.
# LOCAL_COMMENT_EXCLUDE) propagate without manual hook deletion. Content above
# the marker is preserved and the shebang is normalized to line 1.
install_hook_file() {
  local hook_name="$1"
  local marker="$2"
  local content="$3"
  local shebang="${4:-sh}"

  local hook_file
  hook_file="$(detect_hook_file "$hook_name")"
  mkdir -p "$(dirname "$hook_file")"

  if [[ -f "$hook_file" ]] && grep -Fq "$marker" "$hook_file"; then
    local marker_line installed desired
    marker_line="$(grep -nFm1 "$marker" "$hook_file" | cut -d: -f1)"
    installed="$(tail -n "+$marker_line" "$hook_file")"
    desired="$(printf '%s\n%s' "$marker" "$content")"

    if [[ "$installed" == "$desired" ]]; then
      ui_info "$hook_name hook already installed in: $hook_file"
      return 0
    fi

    local tmp
    tmp="$(mktemp -t git-shadow-hook-install.XXXXXX)"
    if (( marker_line > 1 )); then
      head -n "$((marker_line - 1))" "$hook_file" > "$tmp"
    fi
    printf '%s\n%s\n' "$marker" "$content" >> "$tmp"

    # Normalize: the shebang must be the first line (legacy installs placed
    # the marker before it).
    if [[ "$(head -n 1 "$tmp")" != '#!'* ]]; then
      local tmp_shebang
      tmp_shebang="$(mktemp -t git-shadow-hook-install.XXXXXX)"
      { printf '#!/usr/bin/env %s\n' "$shebang"; cat "$tmp"; } > "$tmp_shebang"
      cat "$tmp_shebang" > "$tmp"
      rm -f "$tmp_shebang"
    fi

    cat "$tmp" > "$hook_file"
    rm -f "$tmp"
    chmod +x "$hook_file"
    ui_ok "$hook_name hook refreshed in: $hook_file"
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
