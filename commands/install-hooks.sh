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

# The generated pre-commit hook runs under bash with extglob enabled, so the
# full LOCAL_COMMENT_EXCLUDE list can be embedded verbatim.
EXCLUDE_TRIPLE_LIST="$LOCAL_COMMENT_EXCLUDE"

# ---------------------------------------------------------------------------
# pre-commit hook — rejects commits on public branches unless GIT_SHADOW=1,
# and rejects staged local-comment markers on @local branches unless
# GIT_SHADOW=1.
# ---------------------------------------------------------------------------

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

PRE_COMMIT_GUARD_FUNCS="$(declare -f annotations_triple_excluded guard_staged_files)"
# Escape '&' in the function text so the placeholder substitution does not
# interpret it as a back-reference to the matched placeholder.
PRE_COMMIT_GUARD_FUNCS="${PRE_COMMIT_GUARD_FUNCS//&/\\&}"
pre_commit_content="$(pre_commit_hook_template)"
pre_commit_content="${pre_commit_content//__LOCAL_SUFFIX__/$LOCAL_SUFFIX}"
pre_commit_content="${pre_commit_content//__TRIPLE_PATTERN__/$LOCAL_COMMENT_PATTERN_TRIPLE}"
pre_commit_content="${pre_commit_content//__LOCAL_PATTERN__/$LOCAL_COMMENT_PATTERN_LOCAL}"
pre_commit_content="${pre_commit_content//__EXCLUDE_TRIPLE__/$EXCLUDE_TRIPLE_LIST}"
pre_commit_content="${pre_commit_content//__GUARD_FUNCS__/$PRE_COMMIT_GUARD_FUNCS}"

install_hook_file pre-commit "$HOOK_CHECK_MARKER" "$pre_commit_content" bash

# ---------------------------------------------------------------------------
# pre-push hook — rejects pushes to public branches unless GIT_SHADOW=1
# ---------------------------------------------------------------------------

PRE_PUSH_MARKER="# git-shadow pre-push hook"
pre_push_content="$(cat <<HOOK
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
)"

install_hook_file pre-push "$PRE_PUSH_MARKER" "$pre_push_content" sh
