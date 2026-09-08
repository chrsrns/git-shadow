#!/usr/bin/env bats

# Worktree transparency: feature sync, publish, shadow commit, and status
# run unchanged inside a feature worktree on <name>@local.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/develop
  echo "v1" > app.ts
  git add app.ts
  git commit -qm "initial"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  git shadow feature start feature-foo >/dev/null
  git checkout -q "develop@local"
  git worktree add -q "$TEST_DIR/wt" "feature-foo@local"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "feature sync runs inside a feature worktree" {
  git checkout -q feature-foo
  echo "v3" > extra.ts
  git add extra.ts
  GIT_SHADOW=1 git commit -qm "feat: add extra module"
  git checkout -q "develop@local"

  run git -C "$TEST_DIR/wt" shadow feature sync
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/wt/extra.ts" ]
  subject="$(git -C "$TEST_DIR/wt" log -1 --format='%s')"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "feature publish runs inside a feature worktree" {
  echo "v2" > "$TEST_DIR/wt/app.ts"
  git -C "$TEST_DIR/wt" add app.ts
  git -C "$TEST_DIR/wt" commit -qm "feat: v2 from worktree"
  run git -C "$TEST_DIR/wt" shadow feature publish
  [ "$status" -eq 0 ]
  run git show "feature-foo:app.ts"
  [[ "$output" == *"v2"* ]]
}

@test "git shadow commit works inside a worktree" {
  printf 'public before\n/// local note\npublic after\n' > "$TEST_DIR/wt/wt-file.ts"
  git -C "$TEST_DIR/wt" add wt-file.ts
  run git -C "$TEST_DIR/wt" shadow commit -m "add wt note"
  [ "$status" -eq 0 ]

  # Public commit is clean; the [MEMORY] sidecar carries the annotations.
  run git -C "$TEST_DIR/wt" show "HEAD~1:wt-file.ts"
  [[ "$output" == *"public before"* ]]
  [[ "$output" != *"/// local note"* ]]
  run git -C "$TEST_DIR/wt" show "HEAD:.git-shadow/annotations/wt-file.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## hunk"* ]]
}

@test "status runs inside a worktree" {
  echo "v2" > "$TEST_DIR/wt/app.ts"
  git -C "$TEST_DIR/wt" add app.ts
  git -C "$TEST_DIR/wt" commit -qm "feat: v2"
  run git -C "$TEST_DIR/wt" shadow status
  [ "$status" -eq 0 ]
  [[ "$output" == *"publishable  : 1"* ]]
  [[ "$output" == *"diverged"* ]]
}
