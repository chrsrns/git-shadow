#!/usr/bin/env bats

# Unit tests for lib/annotations.sh:annotations_extract skip_triple behavior.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  export TOOLKIT_ROOT="$BATS_TEST_DIRNAME/.."
  source "$TOOLKIT_ROOT/lib/annotations.sh"

  export LOCAL_COMMENT_PATTERN_TRIPLE='^///'
  export LOCAL_COMMENT_PATTERN_LOCAL='^// @local'
  LOCAL_MARKER='// @local'

  mkdir -p out
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "annotations_extract extracts both triple and local markers by default" {
  cat > source.txt <<EOF
public before
/// triple note
${LOCAL_MARKER} note
public after
EOF

  run annotations_extract source.txt out/clean.txt out/records.md out/meta.txt
  [ "$status" -eq 0 ]

  [[ "$(cat out/clean.txt)" == *"public before"* ]]
  [[ "$(cat out/clean.txt)" == *"public after"* ]]
  [[ "$(cat out/clean.txt)" != *"/// triple note"* ]]
  [[ "$(cat out/clean.txt)" != *"// @local note"* ]]
  [[ "$(cat out/records.md)" == *"### search"* ]]

  source out/meta.txt
  [ "${has_markers}" == "true" ]
  [ "${record_count}" -ge 1 ]
}

@test "annotations_extract skip_triple=1 leaves triple markers and extracts local markers" {
  cat > source.txt <<EOF
public before
/// triple note
${LOCAL_MARKER} note
public after
EOF

  run annotations_extract source.txt out/clean.txt out/records.md out/meta.txt "" 1
  [ "$status" -eq 0 ]

  [[ "$(cat out/clean.txt)" == *"/// triple note"* ]]
  [[ "$(cat out/clean.txt)" != *"// @local note"* ]]
  [[ "$(cat out/records.md)" == *"### search"* ]]

  source out/meta.txt
  [ "${has_markers}" == "true" ]
}

@test "annotations_extract ignores LOCAL_COMMENT_EXCLUDE_TRIPLE env flag" {
  cat > source.txt <<EOF
public before
/// triple note
${LOCAL_MARKER} note
public after
EOF

  # Old side-channel env flag should have no effect when skip_triple arg is absent.
  export LOCAL_COMMENT_EXCLUDE_TRIPLE=1
  run annotations_extract source.txt out/clean.txt out/records.md out/meta.txt
  [ "$status" -eq 0 ]

  # If the env flag were honored, the /// line would remain in the clean output.
  [[ "$(cat out/clean.txt)" != *"/// triple note"* ]]
  [[ "$(cat out/records.md)" == *"### search"* ]]

  unset LOCAL_COMMENT_EXCLUDE_TRIPLE
}
