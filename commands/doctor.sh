#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Script: doctor.sh
# Purpose: run a suite of Git-shadow self-checks for the environment and repo.
# -------------------------------------------------------------------

# Environment setup
TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$TOOLKIT_ROOT/lib/common.sh"

ui_info "git-shadow doctor check"

# 1) toolkit core sanity
if [[ ! -d "$TOOLKIT_ROOT" ]]; then
  ui_error "TOOLKIT_ROOT not found: $TOOLKIT_ROOT"
  exit 1
fi

needed=(
  "bin/git-shadow"
  "lib/common.sh"
  "lib/config-utils.sh"
  "lib/env.sh"
  "lib/ui.sh"
  "config/defaults.env"
  "commands/version.sh"
  "commands/doctor.sh"
  "commands/install-hooks.sh"
  "commands/completion/install.sh"
  "commands/config/get.sh"
  "commands/config/list.sh"
  "commands/config/set.sh"
  "commands/config/show.sh"
  "commands/config/unset.sh"
  "commands/feature/finish.sh"
  "commands/feature/publish.sh"
  "commands/feature/start.sh"
  "commands/feature/sync.sh"
)

for path in "${needed[@]}"; do
  if [[ ! -f "$TOOLKIT_ROOT/$path" ]]; then
    ui_error "Missing required file: $path"
    exit 1
  fi
done

ui_ok "Toolkit files present"

# 2) built-in config defaults
if [[ ! -f "$TOOLKIT_ROOT/config/defaults.env" ]]; then
  ui_error "config/defaults.env missing"
  exit 1
fi
if ! grep -q '^SHADOW_COMMIT_PREFIX=' "$TOOLKIT_ROOT/config/defaults.env"; then
  ui_error "SHADOW_COMMIT_PREFIX not set in config/defaults.env"
  exit 1
fi
if ! grep -q '^SHADOW_COMMIT_FILTER=' "$TOOLKIT_ROOT/config/defaults.env"; then
  ui_error "SHADOW_COMMIT_FILTER not set in config/defaults.env"
  exit 1
fi

ui_ok "Configuration template valid"

# 3) shell command availability
if ! command -v git >/dev/null 2>&1; then
  ui_error "git is not installed"
  exit 1
fi
ui_ok "git CLI available"

if command -v git-shadow >/dev/null 2>&1; then
  ui_ok "git-shadow CLI available"
else
  ui_warn "git-shadow not in PATH (usage: export PATH=\"$TOOLKIT_ROOT/bin:\$PATH\")"
fi

# 4) optional alias check
if git config --global alias.shadow >/dev/null 2>&1; then
  ui_ok "git shadow alias set"
else
  ui_warn "git shadow alias not set (optional)"
fi

# 5) repository state (current project only)
if [[ $# -gt 0 ]]; then
  echo "Usage: $0" >&2
  exit 1
fi

project_path='.'
if [[ -d "$project_path" ]]; then
  ui_info "Checking project: $project_path"
  enter_project "."
  ui_ok "Inside Git repository: $(git rev-parse --is-inside-work-tree 2>/dev/null)"
  ui_shadow "Current branch: $(git branch --show-current)"
  if ! git diff --quiet; then
    ui_warn "Uncommitted working tree changes"
  else
    ui_ok "Working tree clean"
  fi
  if ! git diff --cached --quiet; then
    ui_warn "Staged changes present"
  else
    ui_ok "No staged changes"
  fi
else
  ui_warn "Project path not found (skipping repo checks): $project_path"
fi

ui_ok "git-shadow doctor completed"
