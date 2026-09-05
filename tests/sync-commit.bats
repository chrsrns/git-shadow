#!/usr/bin/env bats

# Verify that net-diff sync commands create [SYNC] commits with provenance.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  git symbolic-ref HEAD refs/heads/main
  echo "initial" > file.txt
  git add file.txt
  git commit -q -m "initial"

  # Bootstrap main@local
  git checkout -q -b main@local
  git shadow base sync
}

teardown() {
  rm -rf "$TEST_DIR"
}

_get_sync_subject() {
  git log -1 --format='%s' --grep='^\[SYNC\]' "$1"
}

_get_sync_body() {
  git log -1 --format='%b' --grep='^\[SYNC\]' "$1"
}

@test "base sync creates a [SYNC] commit with provenance" {
  git checkout -q main
  echo "public v2" > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -q -m "feat: public v2"
  local public_head
  public_head="$(git rev-parse main)"

  git checkout -q main@local
  git shadow base sync

  local subject
  subject="$(_get_sync_subject main@local)"
  [[ "$subject" == "[SYNC] main@local: net diff from main"*".."* ]]

  local body
  body="$(_get_sync_body main@local)"
  [[ "$body" == *"Source: main"* ]]
  [[ "$body" == *"Range:"*"$public_head"* ]]
  [[ "$body" == *"Patch-ids:"* ]]
}

@test "feature sync creates a [SYNC] commit with provenance" {
  git shadow feature start feature-foo

  # Public work on the feature branch
  git checkout -q feature-foo
  echo "feature code" > feature.txt
  git add feature.txt
  GIT_SHADOW=1 git commit -q -m "feat: feature code"
  local public_head
  public_head="$(git rev-parse feature-foo)"

  git checkout -q "feature-foo@local"
  git shadow feature sync

  local subject
  subject="$(_get_sync_subject feature-foo@local)"
  [[ "$subject" == "[SYNC] feature-foo@local: net diff from feature-foo"*".."* ]]

  local body
  body="$(_get_sync_body feature-foo@local)"
  [[ "$body" == *"Source: feature-foo"* ]]
  [[ "$body" == *"Range:"*"$public_head"* ]]
  [[ "$body" == *"Patch-ids:"* ]]
  [[ "$body" != *"Finished feature"* ]]
}

@test "feature finish creates a [SYNC] commit with finished feature" {
  git shadow feature start feature-foo

  # Public work and publish
  git checkout -q "feature-foo@local"
  echo "feature code" > feature.txt
  git add feature.txt
  git commit -q -m "feat: feature code"
  git shadow feature publish

  # Merge the public feature into main
  git checkout -q main
  GIT_SHADOW=1 git merge -q --no-edit feature-foo
  local public_head
  public_head="$(git rev-parse main)"

  # Finish from the local feature branch
  git checkout -q "feature-foo@local"
  git shadow feature finish --no-pull

  local subject
  subject="$(_get_sync_subject main@local)"
  [[ "$subject" == "[SYNC] main@local: net diff from main"*".."* ]]

  local body
  body="$(_get_sync_body main@local)"
  [[ "$body" == *"Source: main"* ]]
  [[ "$body" == *"Range:"*"$public_head"* ]]
  [[ "$body" == *"Patch-ids:"* ]]
  [[ "$body" == *"Finished feature: feature-foo"* ]]
}
