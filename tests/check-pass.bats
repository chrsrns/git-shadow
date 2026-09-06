#!/usr/bin/env bats

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

  TOOLKIT_ROOT="${BATS_TEST_DIRNAME}/.."
  source "$TOOLKIT_ROOT/lib/common.sh"

  git checkout -q -b main@local
  _cp="$(checkpoint_create "$(git rev-parse main)" "$(git rev-parse main@local)")"

  # Add two public commits and one [MEMORY] commit.
  git checkout -q main@local
  echo "public line" >> file.txt
  git add file.txt
  git commit -q -m "public change"

  echo "memory note" > notes.md
  git add notes.md
  git commit -q -m "[MEMORY] scratch note"

  echo "another file" > extra.txt
  git add extra.txt
  git commit -q -m "add extra file"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "check pass passes for public commits with local-only [MEMORY]" {
  latest="$(checkpoint_latest main@local)"
  cp_public="$(checkpoint_public "$latest")"
  cp_local="$(checkpoint_local "$latest")"

  run check_pass "main" "main@local" "$cp_public" "$cp_local"
  [ "$status" -eq 0 ]
  # Output is the ordered public commit SHAs.
  line_count="$(printf '%s\n' "$output" | grep -c '^[0-9a-f]\{40\}$')"
  [ "$line_count" -eq 2 ]
}

@test "check pass fails when [MEMORY] modifies a public-tracked file" {
  git checkout -q main@local
  echo "memory override" > file.txt
  git add file.txt
  git commit -q -m "[MEMORY] should not touch public file"

  latest="$(checkpoint_latest main@local)"
  cp_public="$(checkpoint_public "$latest")"
  cp_local="$(checkpoint_local "$latest")"

  run check_pass "main" "main@local" "$cp_public" "$cp_local"
  [ "$status" -ne 0 ]
  # The error names the differing path.
  [[ "$output" == *"file.txt"* ]]
}

@test "check pass names commit and path when a public commit deletes a local-only file" {
  git checkout -q main@local
  mkdir -p notes
  echo "local note" > notes/local.md
  git add notes/local.md
  git commit -q -m "[MEMORY] local note"
  git rm -q notes/local.md
  git commit -q -m "public: delete local note"
  bad_sha="$(git rev-parse HEAD)"

  latest="$(checkpoint_latest main@local)"
  cp_public="$(checkpoint_public "$latest")"
  cp_local="$(checkpoint_local "$latest")"

  run check_pass "main" "main@local" "$cp_public" "$cp_local"
  [ "$status" -ne 0 ]
  [[ "$output" == *"notes/local.md"* ]]
  [[ "$output" == *"$bad_sha"* || "$output" == *"delete local note"* ]]
}

@test "check_missing_paths flags modify/delete of paths absent from the base tree" {
  git checkout -q main@local
  mkdir -p notes
  echo "local note" > notes/local.md
  git add notes/local.md
  git commit -q -m "[MEMORY] local note"
  git rm -q notes/local.md
  git commit -q -m "public: delete local note"
  bad_sha="$(git rev-parse HEAD)"

  base="$(git rev-parse main)"
  run check_missing_paths "$base" "$bad_sha"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$bad_sha"* ]]
  [[ "$output" == *"notes/local.md"* ]]
}

@test "check_missing_paths accepts add-then-delete within the same range" {
  git checkout -q main@local
  echo "tmp" > tmp.txt
  git add tmp.txt
  git commit -q -m "public: add tmp"
  add_sha="$(git rev-parse HEAD)"
  git rm -q tmp.txt
  git commit -q -m "public: delete tmp"
  del_sha="$(git rev-parse HEAD)"

  base="$(git rev-parse main)"
  run check_missing_paths "$base" "$add_sha" "$del_sha"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check_missing_paths ignores pure additions" {
  git checkout -q main@local
  echo "new" > brand-new.txt
  git add brand-new.txt
  git commit -q -m "public: add file"
  add_sha="$(git rev-parse HEAD)"

  base="$(git rev-parse main)"
  run check_missing_paths "$base" "$add_sha"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check pass returns nothing when there are no public commits" {
  git checkout -q main@local
  _cp="$(checkpoint_create "$(git rev-parse main)" "$(git rev-parse main@local)")"

  latest="$(checkpoint_latest main@local)"
  cp_public="$(checkpoint_public "$latest")"
  cp_local="$(checkpoint_local "$latest")"

  run check_pass "main" "main@local" "$cp_public" "$cp_local"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
