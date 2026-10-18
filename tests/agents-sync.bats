#!/usr/bin/env bats

# Command tests for `git shadow agents sync`.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main
  echo "initial" > file.txt
  git add file.txt
  git commit -qm "initial"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Reconcile paths
# ---------------------------------------------------------------------------

@test "agents sync creates a missing AGENTS.local.md containing only the block" {
  run git shadow agents sync
  [ "$status" -eq 0 ]
  [ -f AGENTS.local.md ]
  [[ "$output" == *"created"* ]]
  [[ "$(head -1 AGENTS.local.md)" == "<!-- git-shadow:agents begin -->" ]]
  [[ "$(tail -1 AGENTS.local.md)" == "<!-- git-shadow:agents end -->" ]]
  [[ "$(cat AGENTS.local.md)" == *"## Git Shadow workflow for AI agents"* ]]
}

@test "agents sync names the untracked-file remedy" {
  run git shadow agents sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"untracked"* ]]
  [[ "$output" == *"MEMORY"* || "$output" == *".gitignore"* ]]
}

@test "agents sync appends the block to a markerless file preserving prior content" {
  printf 'my agent notes\n' > AGENTS.local.md
  run git shadow agents sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"appended"* ]]
  [[ "$(head -1 AGENTS.local.md)" == "my agent notes" ]]
  [[ "$(cat AGENTS.local.md)" == *"<!-- git-shadow:agents begin -->"* ]]
}

@test "agents sync regenerates a stale block preserving outside content" {
  git shadow agents sync >/dev/null
  { printf 'before prose\n'; cat AGENTS.local.md; printf 'after prose\n'; } > tmp && mv tmp AGENTS.local.md
  sed -i 's/## Git Shadow workflow for AI agents/## Tampered heading/' AGENTS.local.md
  run git shadow agents sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"refreshed"* ]]
  [[ "$(head -1 AGENTS.local.md)" == "before prose" ]]
  [[ "$(tail -1 AGENTS.local.md)" == "after prose" ]]
  [[ "$(cat AGENTS.local.md)" == *"## Git Shadow workflow for AI agents"* ]]
}

@test "agents sync reports already-current on a fresh block" {
  git shadow agents sync >/dev/null
  run git shadow agents sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
}

@test "agents sync exits 1 on malformed markers" {
  printf '<!-- git-shadow:agents begin -->\n<!-- git-shadow:agents begin -->\n' > AGENTS.local.md
  run git shadow agents sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed"* ]]
}

# ---------------------------------------------------------------------------
# Anchoring and branch behavior
# ---------------------------------------------------------------------------

@test "agents sync from a subdirectory updates the toplevel file" {
  mkdir -p docs
  cd docs
  run git shadow agents sync
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/AGENTS.local.md" ]
  [ ! -e "$TEST_DIR/docs/AGENTS.local.md" ]
}

@test "agents sync works on a public branch" {
  [ "$(git branch --show-current)" = "main" ]
  run git shadow agents sync
  [ "$status" -eq 0 ]
  [ -f AGENTS.local.md ]
}

@test "agents sync outside a git work tree exits 1" {
  cd "$(mktemp -d)"
  run git shadow agents sync
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Operation gates
# ---------------------------------------------------------------------------

@test "agents sync refuses while a sync is paused" {
  cat > .git/git-shadow-sync <<'EOF'
mode=feature
public_branch=main
local_branch=main@local
EOF
  run git shadow agents sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"sync is in progress"* ]]
  [ ! -e AGENTS.local.md ]
}

@test "agents sync refuses while a finish is paused" {
  cat > .git/git-shadow-finish <<'EOF'
phase=publish
local_base=main@local
EOF
  run git shadow agents sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"finish is in progress"* ]]
  [ ! -e AGENTS.local.md ]
}

@test "agents sync refuses during a native merge" {
  git rev-parse HEAD > .git/MERGE_HEAD
  run git shadow agents sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"merge is still in progress"* ]]
  [ ! -e AGENTS.local.md ]
}

@test "agents sync refuses during a native rebase" {
  mkdir -p .git/rebase-merge
  run git shadow agents sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"rebase is still in progress"* ]]
  [ ! -e AGENTS.local.md ]
}

@test "agents sync refuses during a native cherry-pick" {
  git rev-parse HEAD > .git/CHERRY_PICK_HEAD
  run git shadow agents sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"cherry-pick is still in progress"* ]]
  [ ! -e AGENTS.local.md ]
}

@test "agents sync refuses during a native revert" {
  git rev-parse HEAD > .git/REVERT_HEAD
  run git shadow agents sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"revert is still in progress"* ]]
  [ ! -e AGENTS.local.md ]
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

@test "agents sync --help prints usage" {
  run git shadow agents sync --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: git shadow agents sync"* ]]
}

@test "top-level help lists agents sync" {
  run git shadow help
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents sync"* ]]
}
