#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: install-hooks.sh
# Purpose: install git-shadow hooks (pre-commit and pre-push).
# -------------------------------------------------------------------

# Environment setup
TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLKIT_ROOT/lib/common.sh"

# Install hooks in current repository only
enter_project "."

# ---------------------------------------------------------------------------
# pre-commit hook — rejects commits on public branches unless GIT_SHADOW=1
# ---------------------------------------------------------------------------

pre_commit_file="$(detect_hook_file pre-commit)"
mkdir -p "$(dirname "$pre_commit_file")"

if [[ -f "$pre_commit_file" ]] && grep -Fq "$HOOK_CHECK_MARKER" "$pre_commit_file"; then
  ui_info "pre-commit hook already installed in: $pre_commit_file"
else
  if [[ -f "$pre_commit_file" ]]; then
    {
      printf '\n%s\n' "$HOOK_CHECK_MARKER"
      cat <<HOOK
# Reject commits on public branches unless GIT_SHADOW=1 is set.
# Public = any branch whose name does not end with the configured local suffix.
[ "\${GIT_SHADOW:-0}" = "1" ] && exit 0
branch="\$(git branch --show-current 2>/dev/null || true)"
if [ -n "\$branch" ] && [ "\${branch%${LOCAL_SUFFIX}}" = "\$branch" ]; then
  echo "[git-shadow] Refusing to commit on public branch '\$branch'." >&2
  echo "Set GIT_SHADOW=1 to bypass, or commit from a branch ending with '${LOCAL_SUFFIX}'." >&2
  exit 1
fi
HOOK
    } >> "$pre_commit_file"
  else
    {
      printf '#!/usr/bin/env sh\n%s\n' "$HOOK_CHECK_MARKER"
      cat <<HOOK
# Reject commits on public branches unless GIT_SHADOW=1 is set.
# Public = any branch whose name does not end with the configured local suffix.
[ "\${GIT_SHADOW:-0}" = "1" ] && exit 0
branch="\$(git branch --show-current 2>/dev/null || true)"
if [ -n "\$branch" ] && [ "\${branch%${LOCAL_SUFFIX}}" = "\$branch" ]; then
  echo "[git-shadow] Refusing to commit on public branch '\$branch'." >&2
  echo "Set GIT_SHADOW=1 to bypass, or commit from a branch ending with '${LOCAL_SUFFIX}'." >&2
  exit 1
fi
HOOK
    } > "$pre_commit_file"
    chmod +x "$pre_commit_file"
  fi

  ui_ok "pre-commit hook installed in: $pre_commit_file"
fi

# ---------------------------------------------------------------------------
# pre-push hook — rejects pushes to public branches unless GIT_SHADOW=1
# ---------------------------------------------------------------------------

PRE_PUSH_MARKER="# git-shadow pre-push hook"
pre_push_file="$(detect_hook_file pre-push)"
mkdir -p "$(dirname "$pre_push_file")"

if [[ -f "$pre_push_file" ]] && grep -Fq "$PRE_PUSH_MARKER" "$pre_push_file"; then
  ui_info "pre-push hook already installed in: $pre_push_file"
else
  if [[ -f "$pre_push_file" ]]; then
    {
      printf '\n%s\n' "$PRE_PUSH_MARKER"
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
    } >> "$pre_push_file"
  else
    {
      printf '#!/usr/bin/env sh\n%s\n' "$PRE_PUSH_MARKER"
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
    } > "$pre_push_file"
    chmod +x "$pre_push_file"
  fi

  ui_ok "pre-push hook installed in: $pre_push_file"
fi
