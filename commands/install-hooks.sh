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
# pre-commit hook — rejects commits on public branches unless GIT_SHADOW=1,
# and rejects staged local-comment markers on @local branches unless
# GIT_SHADOW=1.
# ---------------------------------------------------------------------------

install_hook_file pre-commit "$HOOK_CHECK_MARKER" "$(hook_pre_commit_content)" bash

# ---------------------------------------------------------------------------
# pre-push hook — rejects pushes to public branches unless GIT_SHADOW=1
# ---------------------------------------------------------------------------

install_hook_file pre-push "$HOOK_PRE_PUSH_MARKER" "$(hook_pre_push_content)" sh
