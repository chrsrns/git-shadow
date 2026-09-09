#!/usr/bin/env bats

# Tests for git shadow local commands (add/rm/diff/apply).

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main

  # Ensure tests use the toolkit under test.
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  printf '%s\n' ".git-shadow/annotations/" ".git-shadow/patches/" > .gitignore
  echo "initial" > file.txt
  git add .gitignore file.txt
  git commit -qm "initial"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "local add requires a @local branch" {
  git checkout -q -b my-feature
  echo "local" >> file.txt
  run git shadow local add file.txt
  [ "$status" -ne 0 ]
  [[ "$output" == *"@local"* ]]
}

@test "local add creates a sidecar and a [MEMORY] commit" {
  git shadow feature start my-feature
  echo "local edit" >> file.txt
  run git shadow local add file.txt
  [ "$status" -eq 0 ]

  [ -f .git-shadow/patches/file.txt.patch ]
  [ "$(cat file.txt)" = $'initial\nlocal edit' ]

  subject="$(git log -1 --format='%s')"
  [[ "$subject" == "[MEMORY]"* ]]
}

@test "local add rejects an empty delta" {
  git shadow feature start my-feature
  run git shadow local add file.txt
  [ "$status" -ne 0 ]
}

@test "local add rejects a [MEMORY]-only file" {
  git shadow feature start my-feature
  echo "scratch" > scratch.txt
  git add scratch.txt
  git commit -qm "[MEMORY] scratch notes"
  echo "more" >> scratch.txt

  run git shadow local add scratch.txt
  [ "$status" -ne 0 ]
  [ ! -f .git-shadow/patches/scratch.txt.patch ]
}

@test "local add rejects a new non public-tracked file" {
  git shadow feature start my-feature
  echo "new" > new-file.txt
  run git shadow local add new-file.txt
  [ "$status" -ne 0 ]
  [ ! -f .git-shadow/patches/new-file.txt.patch ]
}

@test "local add rejects staged changes in the target path" {
  git shadow feature start my-feature
  echo "staged" >> file.txt
  git add file.txt
  echo "unstaged" >> file.txt
  run git shadow local add file.txt
  [ "$status" -ne 0 ]
}

@test "local add refresh replaces an existing sidecar" {
  git shadow feature start my-feature
  echo "first" >> file.txt
  git shadow local add file.txt

  # Change the local overlay again.
  echo "second" >> file.txt
  run git shadow local add file.txt
  [ "$status" -eq 0 ]

  # The sidecar should reflect the whole delta against HEAD.
  grep -q "second" .git-shadow/patches/file.txt.patch
}

@test "local diff prints the stored sidecar for a path" {
  git shadow feature start my-feature
  echo "local edit" >> file.txt
  git shadow local add file.txt

  run git shadow local diff file.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"local edit"* ]]
}

@test "local diff prints all sidecars when no path is given" {
  git shadow feature start my-feature
  echo "a" >> file.txt
  git shadow local add file.txt
  echo "b" > extra.txt
  git add extra.txt
  git commit -qm "add extra"
  echo "extra local" >> extra.txt
  git shadow local add extra.txt

  run git shadow local diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"file.txt"* ]]
  [[ "$output" == *"extra.txt"* ]]
}

@test "local rm removes the sidecar and records a [MEMORY] commit" {
  git shadow feature start my-feature
  echo "local edit" >> file.txt
  git shadow local add file.txt

  run git shadow local rm file.txt
  [ "$status" -eq 0 ]
  [ ! -f .git-shadow/patches/file.txt.patch ]

  subject="$(git log -1 --format='%s')"
  [[ "$subject" == "[MEMORY]"* ]]
}

@test "local rm --revert restores the source to HEAD" {
  git shadow feature start my-feature
  echo "local edit" >> file.txt
  git shadow local add file.txt

  run git shadow local rm --revert file.txt
  [ "$status" -eq 0 ]
  [ ! -f .git-shadow/patches/file.txt.patch ]
  [ "$(cat file.txt)" = "initial" ]
}

@test "local rm --revert on a non-applied sidecar notes the skipped revert" {
  git shadow feature start my-feature
  echo "local edit" >> file.txt
  git shadow local add file.txt

  # Restore the source to HEAD so the overlay is not applied.
  git checkout -q HEAD -- file.txt

  run git shadow local rm --revert file.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"not applied"* ]]
  [ ! -f .git-shadow/patches/file.txt.patch ]
}

@test "local rm --revert does not commit the source path in [MEMORY]" {
  git shadow feature start my-feature
  printf 'one\ntwo\nthree\nfour\n' > file.txt
  git add file.txt
  git commit -qm "expand file"
  echo "local edit" >> file.txt
  git shadow local add file.txt

  # An extra edit outside the overlay hunk's context: the revert removes the
  # overlay only, leaving this change in the working tree.
  sed -i 's/one/user change/' file.txt

  run git shadow local rm --revert file.txt
  [ "$status" -eq 0 ]
  [ "$(cat file.txt)" = $'user change\ntwo\nthree\nfour' ]

  # The [MEMORY] commit must not modify the public-tracked source file.
  [ "$(git diff-tree --no-commit-id --name-only -r HEAD | grep -cx 'file.txt')" = "0" ]
}

@test "annotations reapply abort keeps the patch overlay applied" {
  git shadow feature start my-feature
  printf 'public one\n/// local note\npublic two\npublic three\npublic four\n' > file.txt
  git add file.txt
  git shadow commit -m "add note"
  git checkout -q -- file.txt

  echo "local tweak" >> file.txt
  git shadow local add file.txt

  # A non-marker change far from the overlay forces annotations reapply to
  # abort after the strip succeeds.
  sed -i 's/public one/user change/' file.txt
  run git shadow annotations reapply file.txt
  [ "$status" -ne 0 ]

  # The overlay must still be applied after the abort.
  [[ "$(cat file.txt)" == *"local tweak"* ]]
}

@test "local rm errors when no sidecar exists" {
  git shadow feature start my-feature
  run git shadow local rm file.txt
  [ "$status" -ne 0 ]
}

@test "local apply logs the degraded reapply method" {
  git shadow feature start degraded >/dev/null
  seq 1 20 > file.txt
  git add file.txt
  git commit -qm "feat: expand file"

  echo "LOCAL" >> file.txt
  git shadow local add file.txt >/dev/null

  # Drift a hunk context line in HEAD so the exact apply fails but a
  # three-way merge can still place the appended line.
  git checkout -q HEAD -- file.txt
  sed -i 's/^19$/nineteen/' file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -qm "feat: rename nineteen"

  run git shadow local apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"3way"* ]]
  [ "$(tail -1 file.txt)" = "LOCAL" ]
  [ "$(git log -1 --format='%s')" = "[MEMORY] reapply local patches" ]
}

@test "feature publish failure leaves the patch overlay applied" {
  git shadow feature start pub-fail >/dev/null
  echo "local edit" >> file.txt
  git shadow local add file.txt >/dev/null

  # A public commit that leaks a local-only marker: the publish guard aborts
  # after the overlay has been stripped for the check-pass replay.
  printf 'pub\n/// secret note\n' > leaked.txt
  git add leaked.txt
  GIT_SHADOW=1 git commit -qm "feat: leaked marker"

  run git shadow feature publish
  [ "$status" -ne 0 ]
  [ "$(cat file.txt)" = $'initial\nlocal edit' ]
}

@test "feature start checkout failure reapplies patch overlays" {
  git shadow feature start first >/dev/null
  echo "local edit" >> file.txt
  git shadow local add file.txt >/dev/null
  cp .git-shadow/patches/file.txt.patch "$TEST_DIR/side.patch"

  # Carry the applied overlay onto the public branch and plant the
  # (gitignored) sidecar there, so the strip before checkout does work.
  git checkout -q first
  mkdir -p .git-shadow/patches
  cp "$TEST_DIR/side.patch" .git-shadow/patches/file.txt.patch

  # Hold the landing branch in a linked worktree so the checkout fails.
  git worktree add -q "$TEST_DIR/wt" first@local

  run git shadow feature start second
  [ "$status" -ne 0 ]
  [ "$(git branch --show-current)" = "first" ]
  [ "$(cat file.txt)" = $'initial\nlocal edit' ]
}

@test "local apply reapplies all stored sidecars" {
  git shadow feature start my-feature
  echo "local edit" >> file.txt
  git shadow local add file.txt

  # Strip the overlay manually.
  source "$TOOLKIT_ROOT/lib/common.sh"
  patches_strip >/dev/null
  [ "$(cat file.txt)" = "initial" ]

  run git shadow local apply
  [ "$status" -eq 0 ]
  [ "$(cat file.txt)" = $'initial\nlocal edit' ]
}

@test "local apply aborts during a paused sync" {
  git shadow feature start my-feature
  echo "local edit" >> file.txt
  git shadow local add file.txt

  touch .git/git-shadow-sync
  run git shadow local apply
  [ "$status" -ne 0 ]
  rm -f .git/git-shadow-sync
}

@test "local add aborts during a paused finish" {
  git shadow feature start my-feature
  echo "local edit" >> file.txt
  touch .git/git-shadow-finish

  run git shadow local add file.txt
  [ "$status" -ne 0 ]
  rm -f .git/git-shadow-finish
}

@test "help lists the local command group" {
  run git shadow help
  [ "$status" -eq 0 ]
  [[ "$output" == *"local"* ]]
}

@test "completions include the local group" {
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  grep -q "local" "$TOOLKIT_ROOT/completions/git-shadow.bash"
  grep -q "local" "$TOOLKIT_ROOT/completions/git-shadow.zsh"
  grep -q "local" "$TOOLKIT_ROOT/completions/git-shadow.fish"
}
