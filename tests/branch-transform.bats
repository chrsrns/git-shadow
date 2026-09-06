#!/usr/bin/env bats

# Unit tests for lib/common.sh branch transform helpers.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export LOCAL_SUFFIX="@local"
  source "$TOOLKIT_ROOT/lib/common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "_branch_transform strip removes suffix" {
  run _branch_transform "feature@local" strip
  [ "$status" -eq 0 ]
  [ "$output" = "feature" ]
}

@test "_branch_transform strip leaves non-suffixed name" {
  run _branch_transform "feature" strip
  [ "$status" -eq 0 ]
  [ "$output" = "feature" ]
}

@test "_branch_transform ensure adds suffix" {
  run _branch_transform "feature" ensure
  [ "$status" -eq 0 ]
  [ "$output" = "feature@local" ]
}

@test "_branch_transform ensure leaves suffixed name" {
  run _branch_transform "feature@local" ensure
  [ "$status" -eq 0 ]
  [ "$output" = "feature@local" ]
}

@test "public_branch_from_any is a thin wrapper over strip" {
  [ "$(public_branch_from_any feature@local)" = "feature" ]
  [ "$(public_branch_from_any main)" = "main" ]
}

@test "local_branch_from_any is a thin wrapper over ensure" {
  [ "$(local_branch_from_any feature)" = "feature@local" ]
  [ "$(local_branch_from_any feature@local)" = "feature@local" ]
}
