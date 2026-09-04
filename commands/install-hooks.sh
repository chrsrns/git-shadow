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

pre_commit_file="$(detect_hook_file pre-commit)"
mkdir -p "$(dirname "$pre_commit_file")"

pre_commit_hook_template() {
  cat <<'HOOK'
#!/usr/bin/env bash
set -e
# Keep glob patterns in $EXCLUDE_TRIPLE literal when iterating; enable extglob
# so LOCAL_COMMENT_EXCLUDE patterns are matched with extended glob semantics.
set -f
shopt -s extglob

tmp_list="$(mktemp -t git-shadow-pre-commit.XXXXXX)"
trap 'rm -f "$tmp_list"' EXIT

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

TRIPLE_PATTERN='__TRIPLE_PATTERN__'
LOCAL_PATTERN='__LOCAL_PATTERN__'
EXCLUDE_TRIPLE='__EXCLUDE_TRIPLE__'

git diff --cached --name-only --diff-filter=ACMRT > "$tmp_list" 2>/dev/null || true
while IFS= read -r path; do
  [ -n "$path" ] || continue

  # Sidecar paths are local-only and never contain source markers.
  case "$path" in
    .git-shadow/annotations/*) continue ;;
  esac

  # Binary files cannot be scanned for marker lines.
  numstat="$(git diff --cached --numstat -- "$path" | head -1)"
  set -- $numstat
  [ "$1" = "-" ] && [ "$2" = "-" ] && continue

  # Skip /// extraction for excluded file patterns and all other .git-shadow paths.
  check_triple=1
  case "$path" in
    .git-shadow/*) check_triple=0 ;;
  esac
  if [ "$check_triple" = "1" ]; then
    for pat in $EXCLUDE_TRIPLE; do
      case "$path" in
        $pat) check_triple=0; break ;;
      esac
    done
  fi

  if [ "$check_triple" = "1" ] && git show :"$path" | grep -qE "$TRIPLE_PATTERN"; then
    echo "[git-shadow] Staged file $path contains local-only /// markers." >&2
    echo "Run 'git shadow commit' to split them into a [MEMORY] sidecar." >&2
    rm -f "$tmp_list"
    exit 1
  fi

  if git show :"$path" | grep -qE "$LOCAL_PATTERN"; then
    echo "[git-shadow] Staged file $path contains local-only // @local markers." >&2
    echo "Run 'git shadow commit' to split them into a [MEMORY] sidecar." >&2
    rm -f "$tmp_list"
    exit 1
  fi
done < "$tmp_list"
rm -f "$tmp_list"
HOOK
}

pre_commit_content="$(pre_commit_hook_template)"
pre_commit_content="${pre_commit_content//__LOCAL_SUFFIX__/$LOCAL_SUFFIX}"
pre_commit_content="${pre_commit_content//__TRIPLE_PATTERN__/$LOCAL_COMMENT_PATTERN_TRIPLE}"
pre_commit_content="${pre_commit_content//__LOCAL_PATTERN__/$LOCAL_COMMENT_PATTERN_LOCAL}"
pre_commit_content="${pre_commit_content//__EXCLUDE_TRIPLE__/$EXCLUDE_TRIPLE_LIST}"

if [[ -f "$pre_commit_file" ]] && grep -Fq "$HOOK_CHECK_MARKER" "$pre_commit_file"; then
  ui_info "pre-commit hook already installed in: $pre_commit_file"
else
  if [[ -f "$pre_commit_file" ]]; then
    {
      printf '\n%s\n%s\n' "$HOOK_CHECK_MARKER" "$pre_commit_content"
    } >> "$pre_commit_file"
  else
    {
      printf '%s\n%s\n' "$HOOK_CHECK_MARKER" "$pre_commit_content"
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
