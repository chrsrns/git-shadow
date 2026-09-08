#!/usr/bin/env bash
# -------------------------------------------------------------------
# Library: doctor.sh
# Purpose: read-only diagnostic checks for `git shadow doctor`.
#
# Each check emits one terse line. doctor_run prints the total number of
# warnings/errors to stdout and always returns 0; the caller exits 1 when
# DOCTOR_WARNINGS is non-zero (V101).
# -------------------------------------------------------------------

DOCTOR_WARNINGS=0

_doctor_tally() {
  "$@" || DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1))
}

# Installed-version vs repo-version skew. Runs only when the current repo is
# the git-shadow toolkit repo (bin/git-shadow, commands/version.sh and VERSION
# at the toplevel); skipped otherwise (V96).
doctor_version_check() {
  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$toplevel" || ! -f "$toplevel/bin/git-shadow" \
     || ! -f "$toplevel/commands/version.sh" || ! -f "$toplevel/VERSION" ]]; then
    ui_info "version: skipped (not the git-shadow toolkit repo)"
    return 0
  fi

  local repo_version installed_version
  repo_version="$(cat "$toplevel/VERSION" 2>/dev/null || true)"
  installed_version="$(git shadow version 2>/dev/null || true)"
  if [[ -z "$installed_version" && -f "$HOME/.local/share/git-shadow/VERSION" ]]; then
    installed_version="$(cat "$HOME/.local/share/git-shadow/VERSION" 2>/dev/null || true)"
  fi

  if [[ -z "$repo_version" || -z "$installed_version" ]]; then
    ui_warn "version: unable to detect installed or repo version"
    return 1
  fi
  if [[ "$installed_version" != "$repo_version" ]]; then
    ui_warn "version: installed '$installed_version' differs from repo '$repo_version'"
    return 1
  fi
  ui_ok "version: $repo_version"
  return 0
}

# Report .git/git-shadow-sync and .git/git-shadow-finish state files, naming
# the mode/branches and the exact --continue / --abort commands.
doctor_state_check() {
  local found=0
  local sync_file finish_file
  sync_file="$(sync_state_file)"
  finish_file="$(finish_state_file)"

  if [[ -f "$sync_file" ]]; then
    local mode="" pub="" loc=""
    if sync_load_state; then
      mode="${SYNC_MODE:-?}"
      pub="${SYNC_PUBLIC_BRANCH:-?}"
      loc="${SYNC_LOCAL_BRANCH:-?}"
    fi
    ui_warn "state: sync in progress ($sync_file, mode=${mode:-?}, $loc <- $pub); resume with 'git shadow ${mode:-feature} sync --continue' or abort with 'git shadow ${mode:-feature} sync --abort'"
    found=1
  fi
  if [[ -f "$finish_file" ]]; then
    local phase="" local_base=""
    if finish_load_state; then
      phase="${FINISH_PHASE:-?}"
      local_base="${FINISH_LOCAL_BASE:-?}"
    fi
    ui_warn "state: finish in progress ($finish_file, phase=${phase:-?}, base=${local_base:-?}); resume with 'git shadow feature finish --continue' or abort with 'git shadow feature finish --abort'"
    found=1
  fi
  if [[ $found -eq 0 ]]; then
    ui_ok "state: no sync or finish in progress"
    return 0
  fi
  return 1
}

# Print the latest checkpoint public/local SHAs and the publishable /
# public-ahead / diverged counts for a single @local branch (V97).
doctor_checkpoint_summary() {
  local local_branch="$1"
  local public_branch
  public_branch="$(public_branch_from_any "$local_branch")"

  local cp
  cp="$(checkpoint_latest "$local_branch")"
  if [[ -z "$cp" ]]; then
    ui_warn "checkpoints: '$local_branch' has no [CHECKPOINT]"
    return 1
  fi

  local cp_public cp_local
  cp_public="$(checkpoint_public "$cp")"
  cp_local="$(checkpoint_local "$cp")"

  if ! git show-ref --verify --quiet "refs/heads/$public_branch"; then
    ui_warn "checkpoints: '$local_branch' public:${cp_public:0:7} local:${cp_local:0:7} — public branch '$public_branch' missing"
    return 1
  fi

  local public_head local_head publishable=0 public_ahead=0 diverged=false
  public_head="$(git rev-parse "$public_branch")"
  local_head="$(git rev-parse "$local_branch")"

  if [[ "$cp_local" != "$local_head" ]]; then
    local sha subject
    while IFS= read -r sha; do
      [[ -z "$sha" ]] && continue
      subject="$(git log -1 --format='%s' "$sha")"
      if [[ "$subject" != "[MEMORY]"* && "$subject" != "[CHECKPOINT]"* ]]; then
        publishable=$((publishable + 1))
      fi
    done < <(git rev-list "${cp_local}..${local_head}")
  fi

  if [[ "$cp_public" != "$public_head" ]]; then
    if git merge-base --is-ancestor "$cp_public" "$public_head"; then
      public_ahead="$(git rev-list --count "${cp_public}..${public_head}")"
    else
      public_ahead="?"
    fi
  fi

  if ! check_tree_matches "$public_head" "$local_head" 2>/dev/null; then
    diverged=true
  fi

  ui_ok "checkpoints: $local_branch public:${cp_public:0:7} local:${cp_local:0:7} publishable:$publishable public-ahead:$public_ahead diverged:$diverged"
  return 0
}

# Verify the pre-commit and pre-push hooks exist and contain the git-shadow
# marker block (V98).
doctor_hooks_check() {
  local issues=0 pc pp
  pc="$(detect_hook_file pre-commit)"
  pp="$(detect_hook_file pre-push)"

  if [[ ! -f "$pc" ]] || ! grep -Fq "$HOOK_CHECK_MARKER" "$pc" 2>/dev/null; then
    ui_warn "hooks: pre-commit hook missing or lacks git-shadow marker ($pc)"
    issues=1
  fi
  if [[ ! -f "$pp" ]] || ! grep -Fq "# git-shadow pre-push hook" "$pp" 2>/dev/null; then
    ui_warn "hooks: pre-push hook missing or lacks git-shadow marker ($pp)"
    issues=1
  fi
  if [[ $issues -eq 0 ]]; then
    ui_ok "hooks: pre-commit and pre-push installed"
  fi
  return $issues
}

# Run `git shadow check public <branch>` and report results (V99).
doctor_unpromoted_files() {
  local public_branch="$1"
  local out
  if out="$("$TOOLKIT_ROOT/bin/git-shadow" check public "$public_branch" 2>&1)"; then
    ui_ok "unpromoted: '$public_branch' clean"
    return 0
  fi
  ui_warn "unpromoted: 'check public $public_branch' failed"
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && printf '  %s\n' "$line"
  done <<< "$out"
  return 1
}

# Warn when SPEC.md exists but .gitattributes does not declare
# `SPEC.md merge=union` (V100).
doctor_gitattributes_check() {
  if [[ ! -f "SPEC.md" ]]; then
    ui_info "gitattributes: skipped (no SPEC.md)"
    return 0
  fi
  if [[ -f ".gitattributes" ]] && grep -qE '^SPEC\.md[[:space:]]+merge=union' .gitattributes; then
    ui_ok "gitattributes: SPEC.md merge=union declared"
    return 0
  fi
  ui_warn "gitattributes: SPEC.md exists but .gitattributes lacks 'SPEC.md merge=union'"
  return 1
}

# Validate WORKTREE_ROOT when configured: absolute after ~ expansion, and
# either an existing directory or a path under a writable parent. Also
# warns when git is too old for 'git worktree remove' (< 2.17).
doctor_worktree_root_check() {
  local issues=0

  if ! worktree_supported; then
    ui_warn "worktree: git < 2.17 lacks 'git worktree remove'"
    issues=1
  fi

  local root="${WORKTREE_ROOT:-}"
  if [[ -z "$root" ]]; then
    ui_info "worktree-root: not configured"
  else
    root="$(_worktree_expand_tilde "$root")"
    if [[ "$root" != /* ]]; then
      ui_warn "worktree-root: WORKTREE_ROOT must be absolute (got: '${WORKTREE_ROOT}')"
      issues=1
    elif [[ -d "$root" ]]; then
      ui_ok "worktree-root: $root"
    else
      # Read-only probe: find the nearest existing ancestor and check that
      # it is writable, without creating anything.
      local probe="$root"
      while [[ ! -d "$probe" && "$probe" != "/" ]]; do
        probe="$(dirname "$probe")"
      done
      if [[ -d "$probe" && -w "$probe" ]]; then
        ui_ok "worktree-root: $root (will be created on use)"
      else
        ui_warn "worktree-root: '$root' does not exist and has no writable parent"
        issues=1
      fi
    fi
  fi
  return $issues
}

# Warn on stale or orphaned worktree registrations, and on linked
# worktrees that hold the public or local base branch (a base checkout by
# feature finish is blocked there). Read-only: reports, never prunes.
doctor_worktree_check() {
  local issues=0
  local public_base="${PUBLIC_BASE_BRANCH:-main}"
  local local_base="${public_base}${LOCAL_SUFFIX:-@local}"
  local current_top
  current_top="$(_worktree_abs "$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")")"

  local orphans wt_path wt_branch
  orphans="$(worktree_orphans)"
  if [[ -n "$orphans" ]]; then
    while IFS=$'\t' read -r wt_path wt_branch; do
      [[ -z "$wt_path" ]] && continue
      if [[ ! -d "$wt_path" ]]; then
        ui_warn "worktree: stale registration '$wt_path' (branch '$wt_branch') — run 'git worktree prune'"
      else
        ui_warn "worktree: '$wt_path' holds missing branch '$wt_branch' (orphaned)"
      fi
      issues=1
    done <<< "$orphans"
  fi

  local path="" line
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ refs/heads/*)
        local held="${line#branch refs/heads/}"
        if [[ "$path" != "$current_top" && -d "$path" \
           && ( "$held" == "$public_base" || "$held" == "$local_base" ) ]]; then
          ui_warn "worktree: '$path' holds base branch '$held'; base checkouts (feature finish) are blocked"
          issues=1
        fi
        ;;
      "") path="" ;;
    esac
  done < <(git worktree list --porcelain)

  if [[ $issues -eq 0 ]]; then
    ui_ok "worktree: no stale or orphaned registrations"
  fi
  return $issues
}

# Execute all checks in order, emit one line per check, print the total
# warning/error count, and return 0. The caller exits 1 when the printed
# count is non-zero (V101).
doctor_run() {
  DOCTOR_WARNINGS=0

  _doctor_tally doctor_version_check
  _doctor_tally doctor_state_check

  # Checkpoint summary for every @local branch (V97).
  local ref seen=0
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    seen=$((seen + 1))
    _doctor_tally doctor_checkpoint_summary "$ref"
  done < <(git for-each-ref --format='%(refname:short)' "refs/heads/*${LOCAL_SUFFIX}")
  if [[ $seen -eq 0 ]]; then
    ui_ok "checkpoints: no ${LOCAL_SUFFIX} branches found"
  fi

  _doctor_tally doctor_hooks_check

  # Unpromoted files for every public branch with a local counterpart (V99).
  while IFS= read -r ref; do
    [[ -z "$ref" || "$ref" =~ ${LOCAL_SUFFIX}$ ]] && continue
    git show-ref --verify --quiet "refs/heads/${ref}${LOCAL_SUFFIX}" || continue
    _doctor_tally doctor_unpromoted_files "$ref"
  done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/')

  _doctor_tally doctor_gitattributes_check
  _doctor_tally doctor_worktree_root_check
  _doctor_tally doctor_worktree_check

  printf 'doctor: %d warning(s)/error(s)\n' "$DOCTOR_WARNINGS"
  return 0
}
