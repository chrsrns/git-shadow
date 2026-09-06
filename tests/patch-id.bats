#!/usr/bin/env bats

# Tests for lib/patch-id.sh helpers.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  source "$BATS_TEST_DIRNAME/../lib/patch-id.sh"

  echo "first" > file.txt
  git add file.txt
  git commit -q -m "first"
  FIRST_SHA="$(git rev-parse HEAD)"

  echo "second" >> file.txt
  git add file.txt
  git commit -q -m "second"
  SECOND_SHA="$(git rev-parse HEAD)"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "patch_id_for returns a stable patch-id for a commit" {
  pid="$(patch_id_for "$FIRST_SHA")"
  [ -n "$pid" ]
  [[ "$pid" =~ ^[a-f0-9]{40}$ ]]
}

@test "patch_id_for matches the manual git patch-id pipeline" {
  pid="$(patch_id_for "$SECOND_SHA")"
  manual="$(git show --format=email --no-color "$SECOND_SHA" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')"
  [ "$pid" = "$manual" ]
}

@test "patch_id_for empty sha returns nothing" {
  pid="$(patch_id_for "")"
  [ -z "$pid" ]
}

@test "patch_id_for invalid sha returns 1 with an error" {
  run patch_id_for "0000000000000000000000000000000000000000"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot show commit"* ]]
  [ -z "$output" ] || [[ "$output" != *^[0-9a-f]\{40\}$* ]]
}

@test "patch_ids_for returns one patch-id per commit" {
  output="$(patch_ids_for "$FIRST_SHA" "$SECOND_SHA")"
  count="$(printf '%s\n' "$output" | grep -c '^[a-f0-9]\{40\}$')"
  [ "$count" -eq 2 ]
}

@test "patch_ids_for skips empty arguments" {
  output="$(patch_ids_for "" "$FIRST_SHA" "" "$SECOND_SHA" "")"
  count="$(printf '%s\n' "$output" | grep -c '^[a-f0-9]\{40\}$')"
  [ "$count" -eq 2 ]
}

@test "patch_ids_for fails when any commit is invalid" {
  run patch_ids_for "$FIRST_SHA" "0000000000000000000000000000000000000000" "$SECOND_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot show commit"* ]]
}
