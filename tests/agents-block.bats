#!/usr/bin/env bats

# Unit tests for lib/agents-block.sh: template rendering, block state
# classification, and install paths for the managed AGENTS.local.md block.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"
  REAL_TOOLKIT_ROOT="$TOOLKIT_ROOT"
}

teardown() {
  rm -rf "$TEST_DIR"
}

_gs_source() {
  # shellcheck disable=SC1090
  source "$REAL_TOOLKIT_ROOT/lib/common.sh"
}

_gs_write_fake_toolkit() {
  # $1 = template filename, stdin = template body
  FAKE_TOOLKIT_ROOT="$TEST_DIR/fake-toolkit"
  mkdir -p "$FAKE_TOOLKIT_ROOT"
  cat > "$FAKE_TOOLKIT_ROOT/$1"
  TOOLKIT_ROOT="$FAKE_TOOLKIT_ROOT"
}

# ---------------------------------------------------------------------------
# agents_template_body
# ---------------------------------------------------------------------------

@test "agents_template_body excludes the template preamble" {
  _gs_source
  run agents_template_body
  [ "$status" -eq 0 ]
  [[ "$output" == "## Git Shadow workflow for AI agents"* ]]
  [[ "$output" != *"Copy below"* ]]
  [[ "$output" != *"AGENTS.template"* ]]
}

@test "agents_template_body renders different bodies for full and ultra" {
  printf 'AGENTS_TEMPLATE="full"\n' > .git-shadow.env
  _gs_source
  run agents_template_body
  [ "$status" -eq 0 ]
  local full_body="$output"

  printf 'AGENTS_TEMPLATE="ultra"\n' > .git-shadow.env
  _gs_source
  run agents_template_body
  [ "$status" -eq 0 ]
  [ "$output" != "$full_body" ]
  [[ "$output" == "## Git Shadow workflow for AI agents"* ]]
}

@test "agents_template_body rejects an invalid AGENTS_TEMPLATE naming both valid values" {
  printf 'AGENTS_TEMPLATE="bogus"\n' > .git-shadow.env
  _gs_source
  run agents_template_body
  [ "$status" -eq 1 ]
  [[ "$output" == *"full"* ]]
  [[ "$output" == *"ultra"* ]]
}

@test "agents_template_body fails when the template file is missing" {
  _gs_source
  TOOLKIT_ROOT="$TEST_DIR/empty-toolkit"
  mkdir -p "$TOOLKIT_ROOT"
  run agents_template_body
  [ "$status" -eq 1 ]
}

@test "agents_template_body fails when the anchor heading is absent" {
  _gs_source
  _gs_write_fake_toolkit AGENTS.template.md <<'EOF'
# Fake template
## Some other section
body
EOF
  run agents_template_body
  [ "$status" -eq 1 ]
}

@test "agents_template_body fails when the body after the heading is empty" {
  _gs_source
  _gs_write_fake_toolkit AGENTS.template.md <<'EOF'
# Fake template
## Git Shadow workflow for AI agents

EOF
  run agents_template_body
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# agents_block_state classification
# ---------------------------------------------------------------------------

@test "agents_block_state reports missing when the file is absent" {
  _gs_source
  TOOLKIT_ROOT="$TEST_DIR/empty-toolkit"  # classify without a render oracle
  mkdir -p "$TOOLKIT_ROOT"
  run agents_block_state AGENTS.local.md
  [ "$status" -eq 0 ]
  [ "$output" = "missing" ]
}

@test "agents_block_state reports absent when the file has no markers" {
  _gs_source
  TOOLKIT_ROOT="$TEST_DIR/empty-toolkit"
  mkdir -p "$TOOLKIT_ROOT"
  printf 'user prose\nmore prose\n' > AGENTS.local.md
  run agents_block_state AGENTS.local.md
  [ "$status" -eq 0 ]
  [ "$output" = "absent" ]
}

@test "agents_block_state reports malformed for an unpaired begin marker" {
  _gs_source
  TOOLKIT_ROOT="$TEST_DIR/empty-toolkit"
  mkdir -p "$TOOLKIT_ROOT"
  printf 'prose\n<!-- git-shadow:agents begin -->\nbody\n' > AGENTS.local.md
  run agents_block_state AGENTS.local.md
  [ "$status" -eq 0 ]
  [ "$output" = "malformed" ]
}

@test "agents_block_state reports malformed for reversed markers" {
  _gs_source
  TOOLKIT_ROOT="$TEST_DIR/empty-toolkit"
  mkdir -p "$TOOLKIT_ROOT"
  printf '<!-- git-shadow:agents end -->\nbody\n<!-- git-shadow:agents begin -->\n' > AGENTS.local.md
  run agents_block_state AGENTS.local.md
  [ "$status" -eq 0 ]
  [ "$output" = "malformed" ]
}

@test "agents_block_state reports malformed for duplicated markers" {
  _gs_source
  TOOLKIT_ROOT="$TEST_DIR/empty-toolkit"
  mkdir -p "$TOOLKIT_ROOT"
  printf '<!-- git-shadow:agents begin -->\n<!-- git-shadow:agents begin -->\nbody\n<!-- git-shadow:agents end -->\n' > AGENTS.local.md
  run agents_block_state AGENTS.local.md
  [ "$status" -eq 0 ]
  [ "$output" = "malformed" ]
}

@test "agents_block_state treats mid-line marker text as prose" {
  _gs_source
  TOOLKIT_ROOT="$TEST_DIR/empty-toolkit"
  mkdir -p "$TOOLKIT_ROOT"
  printf 'the marker is <!-- git-shadow:agents begin --> inline\n' > AGENTS.local.md
  run agents_block_state AGENTS.local.md
  [ "$status" -eq 0 ]
  [ "$output" = "absent" ]
}

@test "agents_block_state reports current for a fresh block" {
  _gs_source
  agents_block_install AGENTS.local.md
  run agents_block_state AGENTS.local.md
  [ "$status" -eq 0 ]
  [ "$output" = "current" ]
}

@test "agents_block_state reports stale when the block body differs" {
  _gs_source
  agents_block_install AGENTS.local.md
  sed -i 's/## Git Shadow workflow for AI agents/## Tampered heading/' AGENTS.local.md
  run agents_block_state AGENTS.local.md
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "agents_block_state propagates render failure instead of classifying" {
  _gs_source
  agents_block_install AGENTS.local.md
  TOOLKIT_ROOT="$TEST_DIR/empty-toolkit"
  mkdir -p "$TOOLKIT_ROOT"
  run agents_block_state AGENTS.local.md
  [ "$status" -eq 1 ]
}

@test "fresh renders carry no whole-line agent markers or local comment markers" {
  local flavor
  for flavor in full ultra; do
    printf 'AGENTS_TEMPLATE="%s"\n' "$flavor" > .git-shadow.env
    _gs_source
    run agents_template_body
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
      [ "$line" != "<!-- git-shadow:agents begin -->" ]
      [ "$line" != "<!-- git-shadow:agents end -->" ]
      [[ ! "$line" =~ ^[[:space:]]*/// ]]
      [[ ! "$line" =~ ^[[:space:]]*//[[:space:]]*@local ]]
    done <<< "$output"
  done
}

@test "no ## heading follows the anchor in either template" {
  local template
  for template in AGENTS.template.md AGENTS.template.ultra.md; do
    local after
    after="$(sed -n '/^## Git Shadow workflow for AI agents$/,$p' "$REAL_TOOLKIT_ROOT/$template" | tail -n +2)"
    ! grep -q '^## ' <<< "$after"
  done
}

# ---------------------------------------------------------------------------
# agents_block_install
# ---------------------------------------------------------------------------

@test "agents_block_install creates a missing file containing only the block" {
  _gs_source
  agents_block_install AGENTS.local.md
  [ -f AGENTS.local.md ]
  run agents_block_fresh
  [ "$status" -eq 0 ]
  [ "$(cat AGENTS.local.md)" = "$output" ]
}

@test "agents_block_install appends the block at EOF with a blank separator" {
  _gs_source
  printf 'my notes\nmore notes\n' > AGENTS.local.md
  agents_block_install AGENTS.local.md
  [[ "$(cat AGENTS.local.md)" == "my notes
more notes

<!-- git-shadow:agents begin -->"* ]]
  [[ "$(tail -1 AGENTS.local.md)" == "<!-- git-shadow:agents end -->" ]]
}

@test "agents_block_install terminates an unterminated final line" {
  _gs_source
  printf 'unterminated' > AGENTS.local.md
  agents_block_install AGENTS.local.md
  [[ "$(cat AGENTS.local.md)" == "unterminated

<!-- git-shadow:agents begin -->"* ]]
}

@test "agents_block_install on an empty file writes just the block" {
  _gs_source
  : > AGENTS.local.md
  agents_block_install AGENTS.local.md
  run agents_block_fresh
  [ "$(cat AGENTS.local.md)" = "$output" ]
}

@test "agents_block_install regenerates a stale block preserving outside content" {
  _gs_source
  agents_block_install AGENTS.local.md
  # Plant prose around the block and tamper inside it.
  { printf 'before prose\n'; cat AGENTS.local.md; printf 'after prose\n'; } > tmp && mv tmp AGENTS.local.md
  sed -i 's/## Git Shadow workflow for AI agents/## Tampered heading/' AGENTS.local.md
  agents_block_install AGENTS.local.md
  [[ "$(head -1 AGENTS.local.md)" == "before prose" ]]
  [[ "$(tail -1 AGENTS.local.md)" == "after prose" ]]
  [[ "$(cat AGENTS.local.md)" == *"## Git Shadow workflow for AI agents"* ]]
  run agents_block_state AGENTS.local.md
  [ "$output" = "current" ]
}

@test "agents_block_install is a no-op on a current block" {
  _gs_source
  agents_block_install AGENTS.local.md
  local before
  before="$(cat AGENTS.local.md)"
  agents_block_install AGENTS.local.md
  [ "$(cat AGENTS.local.md)" = "$before" ]
}

@test "agents_block_install refuses malformed markers" {
  _gs_source
  printf 'prose\n<!-- git-shadow:agents begin -->\n<!-- git-shadow:agents begin -->\n' > AGENTS.local.md
  local before
  before="$(cat AGENTS.local.md)"
  run agents_block_install AGENTS.local.md
  [ "$status" -eq 1 ]
  [ "$(cat AGENTS.local.md)" = "$before" ]
}

@test "agents_block_state tolerates CRLF marker lines and compares current" {
  _gs_source
  agents_block_install AGENTS.local.md
  sed -i 's/$/\r/' AGENTS.local.md
  run agents_block_state AGENTS.local.md
  [ "$status" -eq 0 ]
  [ "$output" = "current" ]
}

@test "agents_block_state reports malformed for a dangling symlink" {
  _gs_source
  TOOLKIT_ROOT="$TEST_DIR/empty-toolkit"
  mkdir -p "$TOOLKIT_ROOT"
  ln -s nonexistent-target AGENTS.local.md
  run agents_block_state AGENTS.local.md
  [ "$status" -eq 0 ]
  [ "$output" = "malformed" ]
}

@test "agents_block_install refuses a symlinked target" {
  _gs_source
  printf 'real content\n' > real.md
  ln -s real.md AGENTS.local.md
  run agents_block_install AGENTS.local.md
  [ "$status" -eq 1 ]
  [ "$(cat real.md)" = "real content" ]
  [ -L AGENTS.local.md ]
}

@test "agents_block_install leaves the file byte-identical on write failure" {
  _gs_source
  printf 'prose\n' > AGENTS.local.md
  local before
  before="$(cat AGENTS.local.md)"
  chmod 555 "$TEST_DIR"
  run agents_block_install AGENTS.local.md
  [ "$status" -eq 1 ]
  [ "$(cat AGENTS.local.md)" = "$before" ]
  chmod 755 "$TEST_DIR"
}

@test "agents_block_install fails on render failure without touching the file" {
  _gs_source
  printf 'prose\n<!-- git-shadow:agents begin -->\nold body\n<!-- git-shadow:agents end -->\n' > AGENTS.local.md
  local before
  before="$(cat AGENTS.local.md)"
  TOOLKIT_ROOT="$TEST_DIR/empty-toolkit"
  mkdir -p "$TOOLKIT_ROOT"
  run agents_block_install AGENTS.local.md
  [ "$status" -eq 1 ]
  [ "$(cat AGENTS.local.md)" = "$before" ]
}
