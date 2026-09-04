#!/usr/bin/env bats

# Tests for the lib/annotations.py local-comment engine.

setup() {
  TEST_DIR="$(mktemp -d)"
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TOOLKIT_ROOT
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  mkdir -p tmp
  SRC="$TEST_DIR/tmp/src.txt"
  CLEAN="$TEST_DIR/tmp/clean.txt"
  RECORDS="$TEST_DIR/tmp/records.md"
  META="$TEST_DIR/tmp/meta.txt"
  OUT="$TEST_DIR/tmp/out.txt"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "annotations extract: triple-slash marker is removed and recorded" {
  cat > "$SRC" <<-'EOF'
public before
/// local note
public after
EOF
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --clean-out "$CLEAN" --records-out "$RECORDS" --meta-out "$META"

  [ "$(cat "$CLEAN")" = $'public before\npublic after' ]
  grep -q '## hunk' "$RECORDS"
  source "$META"
  [ "$has_markers" = "true" ]
  [ "$record_count" = "1" ]
  [ "$marker_only" = "false" ]
}

@test "annotations extract: // @local marker is removed and recorded" {
  cat > "$SRC" <<-'EOF'
public before
// @local note
public after
EOF
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --clean-out "$CLEAN" --records-out "$RECORDS" --meta-out "$META"

  [ "$(cat "$CLEAN")" = $'public before\npublic after' ]
  grep -q '// @local note' "$RECORDS"
}

@test "annotations extract: triple-slash is kept when extract-triple is disabled" {
  cat > "$SRC" <<-'EOF'
public before
/// local note
public after
EOF
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 0 --extract-local 1 \
    --clean-out "$CLEAN" --records-out "$RECORDS" --meta-out "$META"

  grep -q '/// local note' "$CLEAN"
  [ -z "$(cat "$RECORDS")" ]
  source "$META"
  [ "$has_markers" = "false" ]
}

@test "annotations extract: marker-only file is detected" {
  cat > "$SRC" <<-'EOF'
/// note one
/// note two
EOF
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --clean-out "$CLEAN" --records-out "$RECORDS" --meta-out "$META"

  [ -z "$(cat "$CLEAN")" ]
  [ -z "$(cat "$RECORDS")" ]
  source "$META"
  [ "$marker_only" = "true" ]
}

@test "annotations render: recreates source with markers" {
  cat > "$SRC" <<-'EOF'
public before
/// local note
public after
EOF
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --clean-out "$CLEAN" --records-out "$RECORDS" --meta-out "$META"

  python3 "$TOOLKIT_ROOT/lib/annotations.py" render \
    --source "$CLEAN" --annotations "$RECORDS" --output "$OUT" \
    --pattern-triple '^\s*///' --pattern-local '^\s*// @local'

  diff "$SRC" "$OUT"
}

@test "annotations reapply: identical to render" {
  cat > "$SRC" <<-'EOF'
public before
/// local note
public after
EOF
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --clean-out "$CLEAN" --records-out "$RECORDS" --meta-out "$META"

  python3 "$TOOLKIT_ROOT/lib/annotations.py" reapply \
    --source "$CLEAN" --annotations "$RECORDS" --output "$OUT" \
    --pattern-triple '^\s*///' --pattern-local '^\s*// @local'

  diff "$SRC" "$OUT"
}

@test "annotations reanchor: updates hunk when one after line changes" {
  # Build a hunk whose minimal unique search block is 6 public lines.
  cat > "$SRC" <<-'EOF'
line1
a
b
c
/// local note
d
e
f
mid
a
b
c
/// other
x
y
z
line2
EOF
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --clean-out "$CLEAN" --records-out "$RECORDS" --meta-out "$META"

  cat > "$SRC" <<-'EOF'
line1
a
b
c
/// local note
d
e
f changed
mid
a
b
c
/// other
x
y
z
line2
EOF

  # One changed line in a 6-line hunk gives Jaccard 5/7≈0.71, so use 0.7.
  python3 "$TOOLKIT_ROOT/lib/annotations.py" reanchor \
    --source "$SRC" --annotations "$RECORDS" --output "$OUT" \
    --threshold 0.7 \
    --pattern-triple '^\s*///' --pattern-local '^\s*// @local'

  # The re-anchored records should not be empty and should render the markers
  [ -s "$OUT" ]
  python3 "$TOOLKIT_ROOT/lib/annotations.py" render \
    --source "$SRC" --annotations "$OUT" --output "${TEST_DIR}/tmp/rendered.txt" \
    --pattern-triple '^\s*///' --pattern-local '^\s*// @local'
  grep -q '/// local note' "${TEST_DIR}/tmp/rendered.txt"
}

@test "annotations key: returns stable SHA for a search block" {
  printf 'public before\npublic after\n' > "$CLEAN"
  key1=$(python3 "$TOOLKIT_ROOT/lib/annotations.py" key --search "$CLEAN")
  key2=$(python3 "$TOOLKIT_ROOT/lib/annotations.py" key --search "$CLEAN")
  [ "$key1" = "$key2" ]
  [ -n "$key1" ]
}

@test "annotations merge: appends feature replace sections" {
  cat > "$TEST_DIR/tmp/base.md" <<-'EOF'
## hunk abcdef
### search
public before
public after
### replace
public before
/// base note
public after
EOF
  cat > "$TEST_DIR/tmp/feature.md" <<-'EOF'
## hunk abcdef
### search
public before
public after
### replace
public before
/// feature note
public after
EOF

  python3 "$TOOLKIT_ROOT/lib/annotations.py" merge \
    --base "$TEST_DIR/tmp/base.md" --feature "$TEST_DIR/tmp/feature.md" --output "$OUT"

  grep -c '### replace' "$OUT" | grep -q '^2$'
  grep -q '/// base note' "$OUT"
  grep -q '/// feature note' "$OUT"
}

@test "annotations extract: aborts when search block cannot be made unique" {
  cat > "$SRC" <<-'EOF'
x
/// a
x
/// b
x
EOF
  run python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --clean-out "$CLEAN" --records-out "$RECORDS" --meta-out "$META"
  [ "$status" -ne 0 ]
}
