#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Command: git shadow commit -m <message>
# Purpose: split staged source into a clean public commit and a [MEMORY]
#          sidecar containing .git-shadow/annotations/ records.
# -------------------------------------------------------------------

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

enter_project '.'

CURRENT_BRANCH="$(current_branch)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  ui_error "Unable to determine current branch."
  exit 1
fi

if [[ ! "$CURRENT_BRANCH" =~ ${LOCAL_SUFFIX}$ ]]; then
  ui_error "git shadow commit must be run from a branch ending with '${LOCAL_SUFFIX}'."
  exit 1
fi

# Abort on in-progress operations.
cherry_pick_head_file="$(git rev-parse --git-path CHERRY_PICK_HEAD)"
merge_head_file="$(git rev-parse --git-path MERGE_HEAD)"
rebase_merge_dir="$(git rev-parse --git-path rebase-merge)"
rebase_apply_dir="$(git rev-parse --git-path rebase-apply)"

if [[ -f "$cherry_pick_head_file" ]]; then
  ui_error "A cherry-pick is still in progress."
  exit 1
fi
if [[ -f "$merge_head_file" ]]; then
  ui_error "A merge is still in progress."
  exit 1
fi
if [[ -d "$rebase_merge_dir" || -d "$rebase_apply_dir" ]]; then
  ui_error "A rebase is still in progress."
  exit 1
fi

# Parse arguments.
PUBLIC_MESSAGE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message)
      if [[ -z "${2:-}" ]]; then
        ui_error "Missing value for $1."
        exit 1
      fi
      PUBLIC_MESSAGE="$2"
      shift 2
      ;;
    -m*)
      PUBLIC_MESSAGE="${1#-m}"
      shift
      ;;
    *)
      if [[ -z "$PUBLIC_MESSAGE" ]]; then
        PUBLIC_MESSAGE="$1"
        shift
      else
        ui_error "Unknown argument: $1"
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$PUBLIC_MESSAGE" ]]; then
  ui_error "A public commit message is required. Use: git shadow commit -m <message>"
  exit 1
fi

# Disallow public messages that match the shadow commit filter.
if [[ "$PUBLIC_MESSAGE" =~ $SHADOW_COMMIT_FILTER ]]; then
  ui_error "Public commit message matches shadow commit filter ($SHADOW_COMMIT_FILTER)."
  exit 1
fi

if git diff --cached --quiet; then
  ui_error "No staged changes to commit."
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Collect staged paths.
mapfile -t STAGED < <(git diff --cached --name-only --diff-filter=ACMRT)
mapfile -t DELETED < <(git diff --cached --name-only --diff-filter=D)

# Abort if staged content contains conflict markers.
conflict_output="$(git diff --cached --check 2>&1 || true)"
if [[ -n "$conflict_output" ]] && grep -q "conflict marker" <<< "$conflict_output"; then
  ui_error "Staged content contains conflict markers."
  echo "$conflict_output" >&2
  exit 1
fi

# Arrays for bookkeeping.
declare -a PUBLIC_PATHS=()
declare -a CHECKOUT_PATHS=()
declare -a MEMORY_PATHS=()
declare -a ANNOTATION_PATHS=()

# Helper: determine whether a staged file is binary.
_is_binary() {
  local path="$1"
  local first_line
  first_line="$(git diff --cached --numstat -- "$path" | head -1)"
  [[ "$first_line" == $'-\t-'* ]]
}

# Helper: determine if a file exists in HEAD.
_in_head() {
  local path="$1"
  git rev-parse "HEAD:$path" >/dev/null 2>&1
}

# Process staged source files.
for path in "${STAGED[@]}"; do
  relpath="$path"

  # Sidecar files are not source; they belong to [MEMORY].
  if [[ "$relpath" == .git-shadow/annotations/* ]]; then
    MEMORY_PATHS+=("$relpath")
    # Merge the staged sidecar with the committed one by hunk key when the
    # sidecar is already tracked. The staged version wins for keys it
    # contains; committed-only records are kept.
    committed_ann="$TMP_DIR/committed_ann_${relpath////_}.md"
    if [[ -f "$relpath" ]] && git show "HEAD:$relpath" > "$committed_ann" 2>/dev/null; then
      staged_ann="$TMP_DIR/staged_ann_${relpath////_}.md"
      merged_ann="$TMP_DIR/merged_ann_${relpath////_}.md"
      git show ":$relpath" > "$staged_ann"
      if annotations_merge "$committed_ann" "$staged_ann" "$merged_ann" replace; then
        cp "$merged_ann" "$relpath"
      fi
    fi
    # Make sure it is not in the public index.
    git reset -q HEAD -- "$relpath" 2>/dev/null || true
    continue
  fi

  if [[ "$relpath" == .git-shadow/patches/* ]]; then
    MEMORY_PATHS+=("$relpath")
    git reset -q HEAD -- "$relpath" 2>/dev/null || true
    continue
  fi

  # Export staged content to a temp file.
  staged_tmp="$TMP_DIR/staged_${relpath////_}"
  git show :"$relpath" > "$staged_tmp"

  # If a local patch is stored for this path, subtract it from the staged
  # blob before marker extraction so the public commit contains clean source.
  work_tmp="$staged_tmp"
  if [[ -f ".git-shadow/patches/$relpath.patch" ]] || \
     git cat-file -e "HEAD:.git-shadow/patches/$relpath.patch" 2>/dev/null; then
    public_tmp="$TMP_DIR/public_${relpath////_}"
    if ! patches_subtract "$relpath" "$staged_tmp" "$public_tmp"; then
      ui_error "Staged content for '$relpath' does not match the stored local patch. Refresh with 'git shadow local add'."
      exit 1
    fi
    work_tmp="$public_tmp"
  fi

  binary=false
  if _is_binary "$relpath"; then
    binary=true
  fi

  # Decide whether to skip /// extraction.
  skip_triple=0
  if $binary; then
    skip_triple=0
  elif annotations_triple_excluded "$relpath"; then
    skip_triple=1
  else
    skip_triple=0
  fi

  clean_tmp="$TMP_DIR/clean_${relpath////_}"
  records_tmp="$TMP_DIR/records_${relpath////_}.md"
  meta_tmp="$TMP_DIR/meta_${relpath////_}"
  : > "$records_tmp"

  existing_ann=""
  # If the user staged an annotation sidecar for this source, use it.
  if [[ -f ".git-shadow/annotations/$relpath" ]]; then
    existing_ann=".git-shadow/annotations/$relpath"
  # Otherwise, try the committed version and re-anchor it.
  elif git show "HEAD:.git-shadow/annotations/$relpath" > "$TMP_DIR/existing_${relpath////_}.md" 2>/dev/null; then
    reanchored_tmp="$TMP_DIR/reanchored_${relpath////_}.md"
    if annotations_reanchor "$work_tmp" "$TMP_DIR/existing_${relpath////_}.md" "$reanchored_tmp" 2>/dev/null; then
      existing_ann="$reanchored_tmp"
    else
      existing_ann="$TMP_DIR/existing_${relpath////_}.md"
    fi
  fi

  if $binary; then
    # Binary files are included unchanged; no annotation extraction and no
    # working-tree update (unstaged binary changes are preserved).
    PUBLIC_PATHS+=("$relpath")
    continue
  fi

  if ! annotations_extract "$work_tmp" "$clean_tmp" "$records_tmp" "$meta_tmp" "$existing_ann" "$skip_triple" 2>&1; then
    ui_error "Failed to extract annotations from $relpath."
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$meta_tmp"

  marker_only="${marker_only:-false}"
  record_count="${record_count:-0}"

  # Public-tracked test:
  #   - binary files are always public
  #   - non-empty clean content makes a file public
  #   - existing files in HEAD are public
  public=false
  if _in_head "$relpath"; then
    public=true
  elif [[ -s "$clean_tmp" ]]; then
    public=true
  fi

  if [[ "$marker_only" == "true" ]]; then
    # Marker-only file.
    if $public; then
      # Public-tracked marker-only file: remove it from the public index so the
      # public commit deletes it, then commit the marker content in [MEMORY] as
      # a local-only file.  Do not write an empty public blob and do not store
      # the markers in .git-shadow/annotations (there is no public context).
      git rm -q --cached "$relpath" 2>/dev/null || true
      MEMORY_PATHS+=("$relpath")
    else
      # Not public-tracked: remove from index, commit as-is in [MEMORY].
      git reset -q HEAD -- "$relpath" 2>/dev/null || true
      MEMORY_PATHS+=("$relpath")
    fi
    continue
  fi

  if $public; then
    # Replace staged content with the clean version in the index.
    clean_blob="$(git hash-object -w -- "$clean_tmp")"
    git update-index --add --cacheinfo 100644 "$clean_blob" "$relpath"
    PUBLIC_PATHS+=("$relpath")
    CHECKOUT_PATHS+=("$relpath")
  else
    # Clean content is empty and not in HEAD: local-only, but not marker-only?
    # This should not happen because marker_only would be true when clean empty.
    # Treat as local-only and keep original staged content.
    git reset -q HEAD -- "$relpath" 2>/dev/null || true
    MEMORY_PATHS+=("$relpath")
    continue
  fi

  if [[ "$record_count" -gt 0 ]]; then
    ann_path=".git-shadow/annotations/$relpath"
    ann_dir="$(dirname "$ann_path")"
    mkdir -p "$ann_dir"
    cp "$records_tmp" "$ann_path"
    ANNOTATION_PATHS+=("$ann_path")
    MEMORY_PATHS+=("$ann_path")
  fi
done

# Process deletions.
for path in "${DELETED[@]}"; do
  relpath="$path"
  # Deletions are public (or local if path is in .git-shadow/annotations/).
  if [[ "$relpath" == .git-shadow/annotations/* ]]; then
    # The [MEMORY] sidecar should record the deletion.
    MEMORY_PATHS+=("$relpath")
    # git reset the deletion so public commit does not delete it.
    git reset -q HEAD -- "$relpath" 2>/dev/null || true
  else
    PUBLIC_PATHS+=("$relpath")
  fi
done

# Public commit, if the public index now differs from HEAD.
PUBLIC_SHA=""
if ! git diff --cached --quiet; then
  PUBLIC_SHA="$(env GIT_SHADOW=1 git commit -m "$PUBLIC_MESSAGE" | awk '/\[/{print $2; exit}' | tr -d '])')" || true
  if [[ -z "$PUBLIC_SHA" ]]; then
    PUBLIC_SHA="$(git rev-parse HEAD)"
  fi
  ui_git "Public commit: $PUBLIC_SHA"
else
  ui_info "No public changes to commit."
fi

# Update the working tree for public source files that are not marker-only.
# Preserve unstaged non-marker changes by applying the staged→clean diff via
# a three-way merge; on conflict the working tree is left unchanged.
if [[ ${#CHECKOUT_PATHS[@]} -gt 0 ]]; then
  for path in "${CHECKOUT_PATHS[@]}"; do
    relpath="$path"
    staged_tmp="$TMP_DIR/staged_${relpath////_}"
    clean_tmp="$TMP_DIR/clean_${relpath////_}"
    merged_tmp="$TMP_DIR/merged_${relpath////_}"
    if [[ -f "$staged_tmp" && -f "$clean_tmp" && -f "$relpath" ]]; then
      if git merge-file -p "$relpath" "$staged_tmp" "$clean_tmp" > "$merged_tmp" 2>/dev/null; then
        cp "$merged_tmp" "$relpath"
      else
        ui_warn "Unstaged changes in $relpath conflict with marker removal; working tree left unchanged."
      fi
    fi
  done
fi

# Stage [MEMORY] content.
if [[ ${#MEMORY_PATHS[@]} -gt 0 ]]; then
  # Add annotation and marker-only files, ignoring .gitignore.
  for mp in "${MEMORY_PATHS[@]}"; do
    if [[ -e "$mp" || -L "$mp" ]]; then
      git add -f -- "$mp"
    elif [[ "$mp" == .git-shadow/annotations/* ]]; then
      # File was deleted; remove it from the index and working tree.
      git rm -q -- "$mp" 2>/dev/null || true
    fi
  done

  # Build a memory commit message.
  MEMORY_MSG="${SHADOW_COMMIT_PREFIX} local comments"
  if [[ -n "$PUBLIC_SHA" ]]; then
    MEMORY_MSG="${SHADOW_COMMIT_PREFIX} local comments for ${PUBLIC_SHA:0:7}"
  fi

  if ! git diff --cached --quiet; then
    env GIT_SHADOW=1 git commit -m "$MEMORY_MSG" -- "${MEMORY_PATHS[@]}"
    ui_shadow "Memory sidecar committed."
  else
    ui_info "No memory changes to commit."
  fi
else
  ui_info "No memory changes to commit."
fi

ui_ok "git shadow commit complete."
