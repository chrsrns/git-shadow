#!/usr/bin/env bats

# Tests for lib/patches.sh: local patch sidecar helpers.

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

  # Source the toolkit libraries.
  source "$TOOLKIT_ROOT/lib/common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "patches_store writes a working tree delta sidecar" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt

  run patches_store "file.txt"
  [ "$status" -eq 0 ]
  [ -f .git-shadow/patches/file.txt.patch ]

  # The sidecar applies cleanly to HEAD and reproduces the working tree.
  git checkout -q HEAD -- file.txt
  run git apply .git-shadow/patches/file.txt.patch
  [ "$status" -eq 0 ]
  [ "$(cat file.txt)" = $'initial\nlocal edit' ]
}

@test "patches_store rejects an empty delta" {
  git checkout -q -b feature@local
  run patches_store "file.txt"
  [ "$status" -ne 0 ]
  [ ! -f .git-shadow/patches/file.txt.patch ]
}

@test "patches_store rejects a binary path" {
  printf '\x00\x01\x02' > binary.bin
  git add binary.bin
  git commit -qm "add binary"

  git checkout -q -b feature@local
  printf '\x00\x01\x02\x03' > binary.bin
  run patches_store "binary.bin"
  [ "$status" -ne 0 ]
  [ ! -f .git-shadow/patches/binary.bin.patch ]
}

@test "patches_store rejects a deleted file" {
  git checkout -q -b feature@local
  rm -f file.txt
  run patches_store "file.txt"
  [ "$status" -ne 0 ]
}

@test "patches_store rejects a non public-tracked new file" {
  git checkout -q -b feature@local
  echo "new" > new-file.txt
  run patches_store "new-file.txt"
  [ "$status" -ne 0 ]
  [ ! -f .git-shadow/patches/new-file.txt.patch ]
}

@test "patches_store rejects a path with staged changes" {
  git checkout -q -b feature@local
  echo "staged" >> file.txt
  git add file.txt
  echo "unstaged" >> file.txt
  run patches_store "file.txt"
  [ "$status" -ne 0 ]
}

@test "patches_overlay_clean accepts an applied overlay" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  run patches_overlay_clean
  [ "$status" -eq 0 ]
}

@test "patches_overlay_clean rejects unpatched working tree changes" {
  git checkout -q -b feature@local
  echo "unpatched" >> file.txt
  run patches_overlay_clean
  [ "$status" -ne 0 ]
}

@test "patches_overlay_clean rejects staged changes even with sidecar" {
  git checkout -q -b feature@local
  echo "local" >> file.txt
  patches_store "file.txt"
  git add file.txt

  run patches_overlay_clean
  [ "$status" -ne 0 ]
}

@test "patches_overlay_clean rejects untracked non-ignored files" {
  git checkout -q -b feature@local
  echo "orphan" > orphan.txt
  run patches_overlay_clean
  [ "$status" -ne 0 ]
}

@test "patches_strip reverse-applies the overlay and returns relpaths" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  run patches_strip
  [ "$status" -eq 0 ]
  [[ "$output" == *"file.txt"* ]]
  [ "$(cat file.txt)" = "initial" ]
}

@test "patches_strip skips sidecars already matching HEAD" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  # Manually restore the file to HEAD, leaving the orphan sidecar.
  git checkout -q HEAD -- file.txt

  run patches_strip
  [ "$status" -eq 0 ]
  [[ "$output" != *"file.txt"* ]]
}

@test "patches_reapply exact applies the stored sidecar" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  # Strip then reapply.
  patches_strip >/dev/null
  run patches_reapply
  [ "$status" -eq 0 ]
  [ "$(cat file.txt)" = $'initial\nlocal edit' ]
}

@test "patches_reapply rewrites sidecar after a degraded reapply" {
  # Main has a two-line file.
  printf 'initial\nsecond\n' > file.txt
  git add file.txt
  git commit -qm "two-line file"

  git checkout -q -b feature@local

  # Append a local line and store it as a sidecar.
  printf 'initial\nsecond\nlocal edit\n' > file.txt
  patches_store "file.txt"
  git add -f .git-shadow/patches/file.txt.patch
  git commit -qm "[MEMORY] local patch"

  # Strip before switching to main.
  patches_strip >/dev/null

  # Change the first public line on main (the second line stays unchanged,
  # so the sidecar still has a matchable context line).
  git checkout -q main
  printf 'public\nsecond\n' > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -qm "public change"

  # Merge the public change into the feature branch and reapply.
  git checkout -q feature@local
  git merge -q --no-edit main

  # The sidecar should apply via 3-way/relaxed context and be rewritten
  # as a diff against the new HEAD.
  run patches_reapply
  [ "$status" -eq 0 ]
  [ -f .git-shadow/patches/file.txt.patch ]
  [ "$(cat file.txt)" = $'public\nsecond\nlocal edit' ]
}

@test "patches_reapply restores to HEAD and warns on orphan sidecar" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  # Make the sidecar unapplicable by rewriting file.txt from scratch.
  echo "rewritten" > file.txt

  run patches_reapply
  [ "$status" -eq 0 ]
  [[ "$output" == *"orphan"* || "$output" == *"cannot reapply"* ]]
  [ "$(cat file.txt)" = "initial" ]
  [ -f .git-shadow/patches/file.txt.patch ]
}

@test "patches_subtract removes patch from staged blob" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  # Stage the overlaid file.
  git add file.txt
  local staged_file="$TEST_DIR/staged.txt"
  git show :file.txt > "$staged_file"

  # Output clean file should equal HEAD.
  local clean_out="$TEST_DIR/clean.txt"
  run patches_subtract "file.txt" "$staged_file" "$clean_out"
  [ "$status" -eq 0 ]
  [ "$(cat "$clean_out")" = "initial" ]

  # A staged HEAD blob has no patch applied: it passes through unchanged.
  local head_staged="$TEST_DIR/head-staged.txt"
  git show HEAD:file.txt > "$head_staged"
  run patches_subtract "file.txt" "$head_staged" "$clean_out"
  [ "$status" -eq 0 ]
  [ "$(cat "$clean_out")" = "initial" ]

  # Content matching neither the patch nor its reverse aborts (partial or
  # mixed staging).
  printf 'unrelated\ncontent\n' > "$TEST_DIR/mixed.txt"
  run patches_subtract "file.txt" "$TEST_DIR/mixed.txt" "$clean_out"
  [ "$status" -ne 0 ]
}

@test "patches_commit creates a [MEMORY] sidecar commit" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  run patches_commit "file.txt"
  [ "$status" -eq 0 ]

  subject="$(git log -1 --format='%s')"
  [[ "$subject" == "[MEMORY]"* ]]
  git show HEAD -- .git-shadow/patches/file.txt.patch >/dev/null
}

@test "patches_transaction wraps a callback and reapplies on return" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  run patches_store "file.txt"
  [ "$status" -eq 0 ]

  _tx_callback() {
    [ "$(cat file.txt)" = "initial" ]
  }

  status=0
  patches_transaction _tx_callback || status=$?
  [ "$status" -eq 0 ]
  [ "$(cat file.txt)" = $'initial\nlocal edit' ]
}

@test "patches_transaction reapplies on callback failure" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  _tx_fail_callback() {
    [ "$(cat file.txt)" = "initial" ]
    return 42
  }

  status=42
  patches_transaction _tx_fail_callback || status=$?
  [ "$status" -eq 42 ]
  [ "$(cat file.txt)" = $'initial\nlocal edit' ]
}

@test "patches_transaction nested does not double-strip or double-reapply" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  _tx_inner() {
    [ "$(cat file.txt)" = "initial" ]
    echo "inner ran" > "$TEST_DIR/inner.txt"
  }

  _tx_outer() {
    [ "$(cat file.txt)" = "initial" ]
    patches_transaction _tx_inner
    [ "$(cat file.txt)" = "initial" ]
  }

  status=0
  patches_transaction _tx_outer || status=$?
  [ "$status" -eq 0 ]
  [ "$(cat file.txt)" = $'initial\nlocal edit' ]
  [ -f "$TEST_DIR/inner.txt" ]
}

@test "patches_strip skips sidecars not applied to the working tree" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  # Replace the working tree content so the sidecar is no longer applied.
  printf 'other\nlocal edit\n' > file.txt

  run patches_strip
  [ "$status" -eq 0 ]
  [ "$(cat file.txt)" = $'other\nlocal edit' ]
}

@test "patches_check passes for applied overlay" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  run patches_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run patches_check --orphan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "patches_check lists stale sidecars that cannot apply to HEAD" {
  git checkout -q -b feature@local
  echo "local" >> file.txt
  patches_store "file.txt"

  # Rewrite the public file; the stored sidecar no longer applies.
  echo "rewritten" > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -qm "change"

  run patches_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot apply to HEAD"* ]]
}

@test "patches_check --orphan lists sidecars not applied to working tree" {
  git checkout -q -b feature@local
  echo "local edit" >> file.txt
  patches_store "file.txt"

  # Restore file to HEAD while keeping the sidecar.
  git checkout -q HEAD -- file.txt

  run patches_check
  [ "$status" -eq 0 ]

  run patches_check --orphan
  [ "$status" -ne 0 ]
  [[ "$output" == *"not applied to working tree"* ]]
}
