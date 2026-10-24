#!/usr/bin/env bats

# Unit tests for lib/config-utils.sh helpers.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$TOOLKIT_ROOT/lib/config-utils.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "_config_unquote strips outer double quotes" {
  run _config_unquote '"hello world"'
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "_config_unquote strips outer single quotes" {
  run _config_unquote "'hello world'"
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "_config_unquote leaves unquoted values unchanged" {
  run _config_unquote "hello"
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "_config_unquote leaves mismatched quotes unchanged" {
  run _config_unquote "'hello\""
  [ "$status" -eq 0 ]
  [ "$output" = "'hello\"" ]
}

@test "config_value_in_file strips quotes" {
  cat > .git-shadow.env <<'EOF'
LOCAL_SUFFIX="@local"
EOF
  run config_value_in_file ".git-shadow.env" "LOCAL_SUFFIX"
  [ "$status" -eq 0 ]
  [ "$output" = "@local" ]
}

@test "config_default_value strips quotes" {
  run config_default_value "LOCAL_SUFFIX"
  [ "$status" -eq 0 ]
  [ "$output" = "@local" ]
}

@test "json_escape escapes double quotes" {
  run json_escape 'a"b'
  [ "$status" -eq 0 ]
  [ "$output" = 'a\"b' ]
}

@test "json_escape escapes backslashes" {
  run json_escape 'a\b'
  [ "$status" -eq 0 ]
  [ "$output" = 'a\\b' ]
}

@test "json_escape passes non-ASCII bytes through" {
  run json_escape 'café'
  [ "$status" -eq 0 ]
  [ "$output" = 'café' ]
}

@test "json_escape emits control bytes as \\uXXXX" {
  run json_escape "$(printf 'a\tb\nc\rd')"
  [ "$status" -eq 0 ]
  [ "$output" = 'a\u0009b\u000ac\u000dd' ]
  # parseable JSON
  printf '"%s"' "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin) == "a\tb\nc\rd"'
}
