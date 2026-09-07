#!/usr/bin/env bats

# Integration tests for the git-shadow local-comment workflow.

setup() {
  TEST_DIR="$(mktemp -d)"
  XDG_DIR="$(mktemp -d)"
  export XDG_CONFIG_HOME="$XDG_DIR"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "initial" > file.txt
  git add file.txt
  git commit -qm "initial"
  # Ensure tests use the toolkit under test.
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR" "$XDG_DIR"
}

@test "reapply: writes markers to working tree as unstaged changes" {
  git shadow feature start my-feature
  printf 'public before\n/// local note\npublic after\n' > file.txt
  git add file.txt
  git shadow commit -q -m "add note"

  git checkout -- file.txt
  run git shadow annotations reapply file.txt
  [ "$status" -eq 0 ]
  [ -n "$(git diff -- file.txt)" ]
  [[ "$(cat file.txt)" == *"/// local note"* ]]
}

@test "reapply: refuses to overwrite non-marker working-tree changes" {
  git shadow feature start my-feature
  printf 'public before\n/// local note\npublic after\n' > file.txt
  git add file.txt
  git shadow commit -q -m "add note"

  git checkout -- file.txt
  sed -i 's/public after/public after changed/' file.txt
  run git shadow annotations reapply file.txt
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-marker changes"* ]]
}

@test "show: renders committed source with markers" {
  git shadow feature start my-feature
  printf 'public before\n/// local note\npublic after\n' > file.txt
  git add file.txt
  git shadow commit -q -m "add note"

  run git shadow show --with-annotations file.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"/// local note"* ]]
  [[ "$output" == *"public before"* ]]
}

@test "show: requires --with-annotations" {
  git shadow feature start my-feature
  run git shadow show file.txt
  [ "$status" -ne 0 ]
}

@test "publish guard: rejects public tree with leaked /// markers" {
  git shadow feature start my-feature
  printf 'public before\n/// local note\npublic after\n' > file.txt
  git add file.txt
  git shadow commit -q -m "add note"

  # Add a second public commit (not [MEMORY]) that still contains /// markers.
  printf 'public before\n/// another note\npublic after\n' > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -q -m "leaked marker"

  run git shadow feature publish
  [ "$status" -ne 0 ]
  [[ "$output" == *"leaked local-only markers"* ]]
}

@test "publish guard: rejects public tree with leaked // @local markers" {
  git shadow feature start my-feature
  printf 'public before\npublic after\n' > file.txt
  git add file.txt
  git shadow commit -q -m "add file"

  # Add a public commit that contains // @local.
  printf 'public before\n// @local note\npublic after\n' > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -q -m "leaked local marker"

  run git shadow feature publish
  [ "$status" -ne 0 ]
  [[ "$output" == *"// @local"* ]]
}

@test "publish guard: rejects public tree with .git-shadow/annotations" {
  git shadow feature start my-feature
  printf 'public before\n/// local note\npublic after\n' > file.txt
  git add file.txt
  git shadow commit -q -m "add note"

  # Add a non-[MEMORY] public commit with an annotation sidecar.
  mkdir -p .git-shadow/annotations
  echo "leaked" > .git-shadow/annotations/leaked.txt
  git add .git-shadow/annotations/leaked.txt
  GIT_SHADOW=1 git commit -q -m "leaked sidecar"

  run git shadow feature publish
  [ "$status" -ne 0 ]
  [[ "$output" == *".git-shadow/annotations"* ]]
}

@test "check public: flags .git-shadow/annotations on public branch" {
  git shadow feature start my-feature
  printf 'public before\n/// local note\npublic after\n' > file.txt
  git add file.txt
  git shadow commit -q -m "add note"

  # Tamper with the public branch head by fast-forwarding it to include the
  # [MEMORY] sidecar that feature publish would normally filter out.
  memory_sha="$(git log --format='%H' -1 --grep='MEMORY' my-feature@local)"
  git checkout -q my-feature
  git merge --ff-only --quiet "$memory_sha"
  git checkout -q my-feature@local

  # Update the local checkpoint to match the new public head so check public
  # does not fail for a stale checkpoint.
  public_head="$(git rev-parse my-feature)"
  local_head="$(git rev-parse my-feature@local)"
  git commit --quiet --allow-empty -m "[CHECKPOINT] public:$public_head local:$local_head"

  run git shadow check public my-feature
  [ "$status" -ne 0 ]
  [[ "$output" == *".git-shadow/annotations"* ]]
}

@test "show: reads committed sidecar, not working tree" {
  git shadow feature start my-feature
  printf 'public before\n/// local note\npublic after\n' > file.txt
  git add file.txt
  git shadow commit -q -m "add note"

  # Remove the working-tree sidecar; only the committed version remains.
  rm -f .git-shadow/annotations/file.txt

  run git shadow show --with-annotations file.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"/// local note"* ]]
  [[ "$output" == *"public before"* ]]
}
