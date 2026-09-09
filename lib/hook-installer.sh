#!/usr/bin/env bash
# -------------------------------------------------------------------
# Library: hook-installer.sh
# Purpose: install git hooks with idempotent markers.
# -------------------------------------------------------------------

# Marker used inside the generated pre-commit hook.
HOOK_PRE_COMMIT_MARKER="# git-shadow pre-commit hook"

# Marker used inside the generated pre-push hook.
HOOK_PRE_PUSH_MARKER="# git-shadow pre-push hook"

# Return the guard functions embedded in the pre-commit hook.
# The rendered hook must be self-contained, so the body of
# annotations_triple_excluded and guard_staged_files is copied in.
# '&' is escaped so the placeholder substitution treats it literally.
_hook_pre_commit_guard_funcs() {
  local funcs
  funcs="$(declare -f annotations_triple_excluded guard_staged_files)"
  printf '%s' "${funcs//&/\\&}"
}

# Template for the pre-commit hook. Placeholders are replaced from the
# current toolkit's configuration and guard functions.
pre_commit_hook_template() {
  cat <<'HOOK'
# If the hook runner is not bash (e.g. husky runs .husky/pre-commit via sh),
# re-exec only this git-shadow block (marker line through EOF) under bash.
# Re-running the whole file would also re-run hook content above the marker
# that the user added before installing git-shadow.
if [ -z "${BASH_VERSION:-}" ]; then
  _gs_block=""
  if command -v bash >/dev/null 2>&1 && [ -f "$0" ]; then
    _gs_block="$(sed -n '/^# git-shadow pre-commit hook$/,$p' "$0" 2>/dev/null)"
  fi
  if [ -n "$_gs_block" ]; then
    exec bash -c "$_gs_block" "$0" "$@"
  fi
  echo "[git-shadow] pre-commit hook requires bash" >&2
  exit 1
fi

set -e
# Keep glob patterns in LOCAL_COMMENT_EXCLUDE literal when iterating; enable
# extglob so the patterns are matched with extended glob semantics.
set -f
shopt -s extglob

# Reject commits on public branches unless GIT_SHADOW=1 is set.
# Public = any branch whose name does not end with the configured local suffix.
[ "${GIT_SHADOW:-0}" = "1" ] && exit 0
branch="$(git branch --show-current 2>/dev/null || true)"
if [ -n "$branch" ] && [ "${branch%__LOCAL_SUFFIX__}" = "$branch" ]; then
  echo "[git-shadow] Refusing to commit on public branch '$branch'." >&2
  echo "Set GIT_SHADOW=1 to bypass, or commit from a branch ending with '__LOCAL_SUFFIX__'." >&2
  exit 1
fi

# On @local branches, reject staged public-tracked source files that still
# contain local-comment markers. Users should run 'git shadow commit'.
[ -n "$branch" ] && [ "${branch%__LOCAL_SUFFIX__}" != "$branch" ] || exit 0

LOCAL_COMMENT_PATTERN_TRIPLE='__TRIPLE_PATTERN__'
LOCAL_COMMENT_PATTERN_LOCAL='__LOCAL_PATTERN__'
LOCAL_COMMENT_EXCLUDE='__EXCLUDE_TRIPLE__'

__GUARD_FUNCS__

guard_staged_files
HOOK
}

# Render the current pre-commit hook content.
hook_pre_commit_content() {
  local content
  content="$(pre_commit_hook_template)"
  content="${content//__LOCAL_SUFFIX__/$LOCAL_SUFFIX}"
  content="${content//__TRIPLE_PATTERN__/$LOCAL_COMMENT_PATTERN_TRIPLE}"
  content="${content//__LOCAL_PATTERN__/$LOCAL_COMMENT_PATTERN_LOCAL}"
  content="${content//__EXCLUDE_TRIPLE__/$LOCAL_COMMENT_EXCLUDE}"
  content="${content//__GUARD_FUNCS__/$(_hook_pre_commit_guard_funcs)}"
  printf '%s' "$content"
}

# Render the current pre-push hook content.
hook_pre_push_content() {
  cat <<HOOK
# Reject pushes to public branches unless GIT_SHADOW=1 is set.
[ "\${GIT_SHADOW:-0}" = "1" ] && exit 0
while IFS=' ' read -r local_ref _local_sha _remote_ref _remote_sha; do
  [ "\$local_ref" = "(delete)" ] && continue
  branch="\${local_ref#refs/heads/}"
  [ "\$branch" = "\$local_ref" ] && continue
  if [ "\${branch%${LOCAL_SUFFIX}}" = "\$branch" ]; then
    echo "[git-shadow] Refusing to push public branch '\$branch'." >&2
    echo "Use 'git shadow push \$branch' to push public branches." >&2
    exit 1
  fi
done
HOOK
}

# Extract the installed git-shadow block from <hook_file>, starting at the
# line containing <marker> through EOF. Returns 1 if the file is missing or
# the marker is not found.
hook_block_extract() {
  local hook_file="$1"
  local marker="$2"
  local marker_line

  [[ -f "$hook_file" ]] || return 1
  marker_line="$(grep -nFm1 "$marker" "$hook_file" | cut -d: -f1)" || return 1
  [[ -n "$marker_line" ]] || return 1

  tail -n "+$marker_line" "$hook_file"
}

# Render the desired git-shadow block (marker + content) for comparison.
hook_block_fresh() {
  local marker="$1"
  local content="$2"
  printf '%s\n%s' "$marker" "$content"
}

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
    local installed desired
    installed="$(hook_block_extract "$hook_file" "$marker")"
    desired="$(hook_block_fresh "$marker" "$content")"

    if [[ "$installed" == "$desired" ]]; then
      ui_info "$hook_name hook already installed in: $hook_file"
      return 0
    fi

    local marker_line
    marker_line="$(grep -nFm1 "$marker" "$hook_file" | cut -d: -f1)"

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
