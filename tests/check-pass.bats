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

  run publish_replay_and_head "main" "main@local" "$cp_public" "$cp_local" tmp_branch
  [ "$status" -eq 0 ]
  # Output is the ordered public commit SHAs.
  line_count="$(printf '%s\n' "$output" | grep -c '^[0-9a-f]\{40\}$')"
  [ "$line_count" -eq 2 ]
  # Success leaves the temp branch for the caller.
  git show-ref --verify --quiet refs/heads/__shadow_check_tmp__
  git branch -D __shadow_check_tmp__ >/dev/null
}

@test "publish_replay_and_head sets the caller-named variable and prints only SHAs" {
  latest="$(checkpoint_latest main@local)"
  cp_public="$(checkpoint_public "$latest")"
  cp_local="$(checkpoint_local "$latest")"

  out_var="unset"
  shas_file="$TEST_DIR/shas.txt"
  publish_replay_and_head "main" "main@local" "$cp_public" "$cp_local" out_var >"$shas_file"
  [ "$out_var" = "__shadow_check_tmp__" ]
  line_count="$(grep -c '^[0-9a-f]\{40\}$' "$shas_file")"
  [ "$line_count" -eq 2 ]
  # Stdout holds no branch-name line.
  ! grep -q "$out_var" "$shas_file"
  git branch -D "$out_var" >/dev/null
}

@test "publish_replay_and_head sets the out variable empty with nothing to publish" {
  git checkout -q main@local
  _cp="$(checkpoint_create "$(git rev-parse main)" "$(git rev-parse main@local)")"

  latest="$(checkpoint_latest main@local)"
  cp_public="$(checkpoint_public "$latest")"
  cp_local="$(checkpoint_local "$latest")"

  out_var="unset"
  publish_replay_and_head "main" "main@local" "$cp_public" "$cp_local" out_var >"$TEST_DIR/shas.txt"
  [ -z "$out_var" ]
  [ ! -s "$TEST_DIR/shas.txt" ]
  ! git show-ref --verify --quiet refs/heads/__shadow_check_tmp__
}

@test "check pass fails when [MEMORY] modifies a public-tracked file" {
  git checkout -q main@local
  echo "memory override" > file.txt
  git add file.txt
  git commit -q -m "[MEMORY] should not touch public file"

  latest="$(checkpoint_latest main@local)"
  cp_public="$(checkpoint_public "$latest")"
  cp_local="$(checkpoint_local "$latest")"

  run publish_replay_and_head "main" "main@local" "$cp_public" "$cp_local" tmp_branch
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

  run publish_replay_and_head "main" "main@local" "$cp_public" "$cp_local" tmp_branch
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

  run publish_replay_and_head "main" "main@local" "$cp_public" "$cp_local" tmp_branch
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! git show-ref --verify --quiet refs/heads/__shadow_check_tmp__
}

@test "check_missing_paths fails on an invalid base tree" {
  NULL_SHA="0000000000000000000000000000000000000000"
  run check_missing_paths "$NULL_SHA" "$(git rev-parse main)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot list base tree"* ]]
}

@test "check_tree_matches fails on an invalid expected tree" {
  NULL_SHA="0000000000000000000000000000000000000000"
  run check_tree_matches "$NULL_SHA" "$(git rev-parse main)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot compare trees"* ]]
}

@test "check_publishable_count counts only non-marker commits" {
  latest="$(checkpoint_latest main@local)"
  cp_local="$(checkpoint_local "$latest")"

  run check_publishable_count "main@local" "$cp_local"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "check_publishable_count returns 1 when the range cannot be listed" {
  NULL_SHA="0000000000000000000000000000000000000000"
  run check_publishable_count "main@local" "$NULL_SHA"
  [ "$status" -ne 0 ]
}

@test "publish_replay_and_head fails on an invalid checkpoint public sha" {
  NULL_SHA="0000000000000000000000000000000000000000"
  git checkout -q main@local
  cp_local="$(git rev-parse main@local)"
  echo "extra" >> file.txt
  git add file.txt
  git commit -q -m "public: extra"
  run publish_replay_and_head "main" "main@local" "$NULL_SHA" "$cp_local" tmp_branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot list base tree"* ]]
}

@test "check_tree_matches ignores husky-managed hook files" {
  git config core.hooksPath .husky/_
  # Hook files tracked on the public side, guard block added on the @local
  # side — the husky divergence scenario.
  git branch husky-base
  git branch husky-base@local
  git checkout -q husky-base
  mkdir -p .husky
  printf '#!/bin/sh\n# husky original\n' > .husky/pre-commit
  printf '#!/bin/sh\n# husky original\n' > .husky/pre-push
  git add .husky/pre-commit .husky/pre-push
  git commit -qm "add husky hooks"
  git checkout -q husky-base@local
  mkdir -p .husky
  printf '#!/bin/sh\n# husky original\n# git-shadow pre-commit hook\n' > .husky/pre-commit
  printf '#!/bin/sh\n# husky original\n# git-shadow pre-push hook\n' > .husky/pre-push
  git add .husky/pre-commit .husky/pre-push
  git commit -qm "install guard into hooks"

  run check_tree_matches husky-base husky-base@local
  [ "$status" -eq 0 ]
}

@test "check_tree_matches still fails on non-hook divergence with husky hooks" {
  git config core.hooksPath .husky/_
  git branch husky-base
  git branch husky-base@local
  git checkout -q husky-base
  mkdir -p .husky
  printf '#!/bin/sh\n# husky original\n' > .husky/pre-commit
  git add .husky/pre-commit
  git commit -qm "add husky pre-commit"
  git checkout -q husky-base@local
  mkdir -p .husky
  printf '#!/bin/sh\n# husky original\n# git-shadow pre-commit hook\n' > .husky/pre-commit
  git add .husky/pre-commit
  git commit -qm "install guard"
  echo "local change" >> file.txt
  git add file.txt
  git commit -qm "public: change file"

  run check_tree_matches husky-base husky-base@local
  [ "$status" -ne 0 ]
  [[ "$output" == *"file.txt"* ]]
}

@test "replay skips an initially-empty commit" {
  git checkout -q main@local
  git commit -q --allow-empty -m "public: empty commit"
  empty_sha="$(git rev-parse HEAD)"
  latest="$(checkpoint_latest main@local)"
  cp_public="$(checkpoint_public "$latest")"
  cp_local="$(checkpoint_local "$latest")"

  out_var="unset"
  shas_file="$TEST_DIR/empty-shas.txt"
  notes_file="$TEST_DIR/empty-notes.txt"
  publish_replay_and_head "main" "main@local" "$cp_public" "$cp_local" out_var \
    >"$shas_file" 2>"$notes_file"
  # A git-shadow note is emitted and the empty commit is not published.
  grep -q "empty" "$notes_file"
  ! grep -q "$empty_sha" "$shas_file"
  git branch -D "$out_var" >/dev/null 2>&1 || true
}

@test "replay skips a commit that becomes empty on the replay base" {
  git checkout -q main@local
  # A [MEMORY] commit (subject-filtered, never replayed) rewrites a public
  # file; the following public commit restores it to the checkpoint base
  # content, so the pick's result equals the replay state and is empty.
  echo "local only" > file.txt
  git add file.txt
  git commit -q -m "[MEMORY] modify public file"
  git checkout -q "HEAD~1" -- file.txt
  git commit -q -m "public: restore file"
  latest="$(checkpoint_latest main@local)"
  cp_public="$(checkpoint_public "$latest")"
  cp_local="$(checkpoint_local "$latest")"

  run publish_replay_and_head "main" "main@local" "$cp_public" "$cp_local" tmp_branch
  [ "$status" -eq 0 ]
  # No raw git cherry-pick error text leaks.
  [[ "$output" != *"The previous cherry-pick"* ]]
  git branch -D __shadow_check_tmp__ >/dev/null 2>&1 || true
}

@test "check_public_commits excludes merge commits on a feature branch" {
  git checkout -q main@local
  git checkout -q -b feat@local
  _cp="$(checkpoint_create "$(git rev-parse main)" "$(git rev-parse feat@local)")"
  git checkout -q -b side
  echo side > side.txt
  git add side.txt
  git commit -qm "feat: side work"
  git checkout -q feat@local
  echo feat > feat.txt
  git add feat.txt
  git commit -qm "feat: main work"
  git merge -q --no-ff side -m "merge side"
  merge_sha="$(git rev-parse HEAD)"

  latest="$(checkpoint_latest feat@local)"
  cp_local="$(checkpoint_local "$latest")"
  run check_public_commits "feat@local" "$cp_local"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$merge_sha"* ]]
}

@test "check_public_commits excludes commits reachable from base@local" {
  git checkout -q main@local
  echo base2 > base.txt
  git add base.txt
  git commit -qm "public: base work"
  git checkout -q -b feat@local
  _cp="$(checkpoint_create "$(git rev-parse main)" "$(git rev-parse feat@local)")"
  echo feat > feat.txt
  git add feat.txt
  git commit -qm "feat: work"
  # Advance the local base, then manually merge it into the feature.
  git checkout -q main@local
  echo base3 > base3.txt
  git add base3.txt
  git commit -qm "public: more base work"
  base_sha="$(git rev-parse main@local)"
  git checkout -q feat@local
  git merge -q --no-ff "main@local" -m "merge base into feature"

  latest="$(checkpoint_latest feat@local)"
  cp_local="$(checkpoint_local "$latest")"
  run check_public_commits "feat@local" "$cp_local"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$base_sha"* ]]
}

@test "check_public_commits keeps merge exclusion when base@local is missing" {
  git checkout -q main@local
  git checkout -q -b feat@local
  git branch -D main@local >/dev/null 2>&1
  _cp="$(checkpoint_create "$(git rev-parse main)" "$(git rev-parse feat@local)")"
  git checkout -q -b side
  echo side > side.txt
  git add side.txt
  git commit -qm "feat: side work"
  git checkout -q feat@local
  echo feat > feat.txt
  git add feat.txt
  git commit -qm "feat: main work"
  git merge -q --no-ff side -m "merge side"
  merge_sha="$(git rev-parse HEAD)"

  latest="$(checkpoint_latest feat@local)"
  cp_local="$(checkpoint_local "$latest")"
  run check_public_commits "feat@local" "$cp_local"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$merge_sha"* ]]
}

@test "check_tree_matches flags hook-path divergence when hooksPath is unset" {
  git branch husky-base
  git branch husky-base@local
  git checkout -q husky-base
  mkdir -p .husky
  printf '#!/bin/sh\n# husky original\n' > .husky/pre-commit
  git add .husky/pre-commit
  git commit -qm "add husky pre-commit"
  git checkout -q husky-base@local
  mkdir -p .husky
  printf '#!/bin/sh\n# husky original\n# git-shadow pre-commit hook\n' > .husky/pre-commit
  git add .husky/pre-commit
  git commit -qm "install guard"

  run check_tree_matches husky-base husky-base@local
  [ "$status" -ne 0 ]
  [[ "$output" == *".husky/pre-commit"* ]]
}
