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

@test "annotations extract: uniqueness test normalizes trailing whitespace" {
  # 'foo   ' and 'foo' normalize to the same line, so the 2-line block
  # 'foo/bar' is NOT unique after normalization. Extraction must expand the
  # search block to include 'top' (3 lines) instead of stopping at 2.
  printf 'top\nfoo   \n/// note\nbar\nmid\nfoo\nbar\nbottom\n' > "$SRC"
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --clean-out "$CLEAN" --records-out "$RECORDS" --meta-out "$META"

  search_lines=$(awk '/### search/{f=1; next} /### replace/{f=0} f' "$RECORDS" | wc -l)
  [ "$search_lines" -eq 3 ]
}

@test "annotations extract: keys absent from source are marked orphan" {
  printf 'aaa\n/// note one\nbbb\nccc\n/// note two\nddd\n' > "$SRC"
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --clean-out "$CLEAN" --records-out "$RECORDS" --meta-out "$META"

  # Remove the second marker and re-extract against the existing sidecar.
  printf 'aaa\n/// note one\nbbb\nccc\nddd\n' > "$SRC"
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --existing-annotations "$RECORDS" \
    --clean-out "$CLEAN" --records-out "$OUT" --meta-out "$META"

  # Both records are kept; only the absent key is flagged orphan.
  [ "$(grep -c '## hunk' "$OUT")" -eq 2 ]
  [ "$(grep -c '### orphan' "$OUT")" -eq 1 ]

  # The orphan record is skipped on render: the removed marker is not
  # resurrected.
  run python3 "$TOOLKIT_ROOT/lib/annotations.py" render \
    --source "$CLEAN" --annotations "$OUT" --output "${TEST_DIR}/tmp/rendered.txt" \
    --pattern-triple '^\s*///' --pattern-local '^\s*// @local'
  [ "$status" -eq 0 ]
  grep -q '/// note one' "${TEST_DIR}/tmp/rendered.txt"
  run grep -q '/// note two' "${TEST_DIR}/tmp/rendered.txt"
  [ "$status" -ne 0 ]
}

@test "annotations extract: removing all markers orphans every existing record" {
  printf 'aaa\n/// note one\nbbb\n' > "$SRC"
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --clean-out "$CLEAN" --records-out "$RECORDS" --meta-out "$META"

  printf 'aaa\nbbb\n' > "$SRC"
  python3 "$TOOLKIT_ROOT/lib/annotations.py" extract \
    --source "$SRC" --pattern-triple '^\s*///' --pattern-local '^\s*// @local' \
    --extract-triple 1 --extract-local 1 \
    --existing-annotations "$RECORDS" \
    --clean-out "$CLEAN" --records-out "$OUT" --meta-out "$META"

  # The record is kept in the sidecar but flagged orphan.
  [ "$(grep -c '## hunk' "$OUT")" -eq 1 ]
  [ "$(grep -c '### orphan' "$OUT")" -eq 1 ]
  source "$META"
  [ "$record_count" = "1" ]
  [ "$has_markers" = "false" ]
}
