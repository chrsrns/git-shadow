#!/usr/bin/env bats

# Unit tests for lib/ui.sh semantic output helpers.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$TOOLKIT_ROOT/lib/ui.sh"
  # Force color off so we can compare plain output.
  export NO_COLOR=1
  source "$TOOLKIT_ROOT/lib/ui.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "ui_emit prints correct prefix for each level" {
  [[ "$(ui_emit git "msg")" == *"🌿 msg"* ]]
  [[ "$(ui_emit shadow "msg")" == *"🧠 msg"* ]]
  [[ "$(ui_emit ok "msg")" == *"✅ msg"* ]]
  [[ "$(ui_emit info "msg")" == *"ℹ️  msg"* ]]
  [[ "$(ui_emit step "msg")" == "   msg" ]]
  [[ "$(ui_emit skip "msg")" == *"⏭️  msg"* ]]
}

@test "ui_warn and ui_error go to stderr" {
  run ui_warn "warning"
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠️  warning"* ]]

  run ui_error "error"
  [ "$status" -eq 0 ]
  [[ "$output" == *"❌ error"* ]]
}

@test "NO_COLOR disables color escapes" {
  run ui_git "msg"
  [[ "$output" != *"[38;2"* ]]
}

@test "ui wrappers call ui_emit" {
  [[ "$(ui_git "msg")" == *"🌿 msg"* ]]
  [[ "$(ui_shadow "msg")" == *"🧠 msg"* ]]
  [[ "$(ui_ok "msg")" == *"✅ msg"* ]]
  [[ "$(ui_info "msg")" == *"ℹ️  msg"* ]]
  [[ "$(ui_step "msg")" == "   msg" ]]
  [[ "$(ui_skip "msg")" == *"⏭️  msg"* ]]
}
