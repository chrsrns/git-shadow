#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "initial" > file.txt
  git add file.txt
  git commit -qm "initial"

  TOOLKIT_ROOT="${BATS_TEST_DIRNAME}/.."
  source "$TOOLKIT_ROOT/lib/checkpoint.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "checkpoint_summary produces expected format" {
  run checkpoint_summary "abc1234" "def5678"
  [ "$status" -eq 0 ]
  [ "$output" = "[CHECKPOINT] public:abc1234 local:def5678" ]
}

@test "checkpoint_body produces comma-joined patch-ids" {
  run checkpoint_body "p1" "p2" "p3"
  [ "$status" -eq 0 ]
  [ "$output" = "patches:p1,p2,p3" ]
}

@test "checkpoint_create makes an empty checkpoint commit" {
  run checkpoint_create "abc1234" "def5678" "p1" "p2"
  [ "$status" -eq 0 ]
  sha="$output"
  subject="$(git log -1 --format=%s "$sha")"
  body="$(git log -1 --format=%b "$sha")"
  [ "$subject" = "[CHECKPOINT] public:abc1234 local:def5678" ]
  [ "$body" = "patches:p1,p2" ]
}

@test "checkpoint_public extracts public sha" {
  sha="$(checkpoint_create "abc1234" "def5678" "p1" "p2")"
  run checkpoint_public "$sha"
  [ "$status" -eq 0 ]
  [ "$output" = "abc1234" ]
}

@test "checkpoint_local extracts local sha" {
  sha="$(checkpoint_create "abc1234" "def5678" "p1" "p2")"
  run checkpoint_local "$sha"
  [ "$status" -eq 0 ]
  [ "$output" = "def5678" ]
}

@test "checkpoint_pids extracts patch-ids" {
  sha="$(checkpoint_create "abc1234" "def5678" "p1" "p2" "p3")"
  run checkpoint_pids "$sha"
  [ "$status" -eq 0 ]
  [ "$output" = "p1 p2 p3" ]
}

@test "checkpoint_pids is empty when no patch-ids" {
  sha="$(checkpoint_create "abc1234" "def5678")"
  run checkpoint_pids "$sha"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "checkpoint_latest finds newest checkpoint on a branch" {
  sha1="$(checkpoint_create "abc0000" "def0000" "p1")"
  sha2="$(checkpoint_create "abc1111" "def1111" "p2")"
  run checkpoint_latest "HEAD"
  [ "$status" -eq 0 ]
  [ "$output" = "$sha2" ]
  run checkpoint_public "$sha2"
  [ "$output" = "abc1111" ]
}

@test "checkpoint_latest returns nothing when no checkpoint exists" {
  run checkpoint_latest "HEAD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
