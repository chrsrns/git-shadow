#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main
  printf 'A\nB\nC\n' > file.txt
  git add file.txt
  git commit -qm "initial"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TOOLKIT_ROOT
  export PATH="$TOOLKIT_ROOT/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "feature finish inherits .git-shadow/patches sidecars" {
  git shadow feature start inherited >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null
  git reset --hard HEAD >/dev/null
  printf 'feature\n' > feature.txt
  git add feature.txt
  git commit -qm "feat: add feature"
  git shadow feature publish >/dev/null
  git checkout -q main
  git merge -q --no-edit inherited
  git checkout -q main@local
  printf 'base\n' > base.txt
  git add base.txt
  git commit -qm "chore: base change"
  git checkout -q inherited@local
  run git shadow feature finish --no-pull
  [ "$status" -eq 0 ]
  [ -f "${TEST_DIR}/.git-shadow/patches/file.txt.patch" ]
}

@test "feature finish reapplies the patch overlay after [MEMORY] replay" {
  git shadow feature start inherited >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null
  git reset --hard HEAD >/dev/null
  printf 'feature\n' > feature.txt
  git add feature.txt
  git commit -qm "feat: add feature"
  git shadow feature publish >/dev/null
  git checkout -q main
  git merge -q --no-edit inherited
  git checkout -q main@local
  printf 'base\n' > base.txt
  git add base.txt
  git commit -qm "chore: base change"
  git checkout -q inherited@local
  run git shadow feature finish --no-pull
  [ "$status" -eq 0 ]
  [ -f "${TEST_DIR}/.git-shadow/patches/file.txt.patch" ]
  # The inherited overlay must be applied on the local base, not left stripped.
  [ "$(sed -n '2p' file.txt)" = "B local" ]
}

@test "doctor reports no orphan sidecar when a patch overlay is applied" {
  git shadow feature start healthy >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null

  # An applied overlay is the normal state; doctor must not flag it.
  run git shadow doctor
  [[ "$output" == *"patches: no orphan sidecars"* ]]
}

@test "doctor warns about orphan patch sidecar" {
  git shadow feature start warned >/dev/null
  printf 'A\nB local\nC\n' > file.txt
  git shadow local add file.txt >/dev/null
  git reset --hard HEAD >/dev/null
  git checkout -q main
  printf 'A\nB2\nC\n' > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -qm "chore: change B"
  git checkout -q warned@local
  # Make the sidecar unappliable to HEAD by deleting B entirely.
  # Bypass the sidecar guard: this synthetic orphan setup diverges the
  # source on purpose and is not a user-facing commit path.
  printf 'A\nC\n' > file.txt
  git add file.txt
  GIT_SHADOW=1 git commit -qm "[MEMORY] orphan patch"
  git shadow local apply >/dev/null 2>&1 || true
  run git shadow doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"orphan sidecar"* ]]
}

_setup_overlay_worktree_feature() {
  git shadow feature start wt-feat >/dev/null
  echo "wf" > wf.txt
  git add wf.txt
  git commit -qm "feat: wf"
  git shadow feature publish >/dev/null
  git checkout -q main
  git merge -q --no-edit wt-feat
  git checkout -q "main@local"
  git worktree add -q "$TEST_DIR/wt-feat" "wt-feat@local"
  # Mirror worktree_add's info/exclude write for in-repo worktree paths so
  # commit staging cannot sweep the worktree dir as an embedded repo.
  grep -qxF "/wt-feat/" .git/info/exclude 2>/dev/null || \
    printf '/wt-feat/\n' >> .git/info/exclude
}

@test "feature finish removes a worktree whose only dirt is an applied overlay" {
  _setup_overlay_worktree_feature
  ( cd "$TEST_DIR/wt-feat" && printf 'A\nB local\nC\n' > file.txt && git shadow local add file.txt >/dev/null )
  run git shadow feature finish wt-feat --no-pull
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_DIR/wt-feat" ]
  ! git worktree list --porcelain | grep -qxF "worktree $TEST_DIR/wt-feat"
  ! git show-ref --verify --quiet "refs/heads/wt-feat@local"
  [ -f "${TEST_DIR}/.git-shadow/patches/file.txt.patch" ]
}

@test "feature finish aborts on a patch-stale overlay worktree" {
  _setup_overlay_worktree_feature
  ( cd "$TEST_DIR/wt-feat" && printf 'A\nB local\nC\n' > file.txt && git shadow local add file.txt >/dev/null && printf 'A\nB other\nC\n' > file.txt )
  run git shadow feature finish wt-feat --no-pull
  [ "$status" -eq 1 ]
  git worktree list --porcelain | grep -qxF "worktree $TEST_DIR/wt-feat"
  git show-ref --verify --quiet "refs/heads/wt-feat@local"
}

@test "feature finish removes the toolkit .git-shadow.env copy from the worktree" {
  _setup_overlay_worktree_feature
  ( cd "$TEST_DIR/wt-feat" && printf 'A\nB local\nC\n' > file.txt && git shadow local add file.txt >/dev/null )
  echo "K=V" > "$TEST_DIR/wt-feat/.git-shadow.env"
  run git shadow feature finish wt-feat --no-pull
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_DIR/wt-feat" ]
  ! git worktree list --porcelain | grep -qxF "worktree $TEST_DIR/wt-feat"
  ! git show-ref --verify --quiet "refs/heads/wt-feat@local"
}

@test "feature finish aborts pre-mutation on an exempt untracked path in the worktree" {
  _setup_overlay_worktree_feature
  echo "x" > "$TEST_DIR/wt-feat/.gitignore"
  cp_before="$(git log --format='%s' main@local | grep -c '^\[CHECKPOINT\]')"
  run git shadow feature finish wt-feat --no-pull
  [ "$status" -eq 1 ]
  [[ "$output" == *".gitignore"* ]]
  git worktree list --porcelain | grep -qxF "worktree $TEST_DIR/wt-feat"
  git show-ref --verify --quiet "refs/heads/wt-feat@local"
  [ "$(git log --format='%s' main@local | grep -c '^\[CHECKPOINT\]')" = "$cp_before" ]
}

@test "second finish after --keep-branches adds no checkpoint" {
  _setup_overlay_worktree_feature
  ( cd "$TEST_DIR/wt-feat" && printf 'A\nB local\nC\n' > file.txt && git shadow local add file.txt >/dev/null )
  run git shadow feature finish wt-feat --no-pull --keep-branches
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_DIR/wt-feat" ]
  git show-ref --verify --quiet "refs/heads/wt-feat@local"
  cp_count="$(git log --format='%s' main@local | grep -c '^\[CHECKPOINT\]')"
  run git shadow feature finish wt-feat --no-pull
  [ "$status" -eq 0 ]
  [ "$(git log --format='%s' main@local | grep -c '^\[CHECKPOINT\]')" = "$cp_count" ]
  ! git show-ref --verify --quiet "refs/heads/wt-feat@local"
  ! git show-ref --verify --quiet "refs/heads/wt-feat"
}

@test "named finish from a linked base worktree with @local in main aborts" {
  git shadow feature start wt-feat >/dev/null
  echo "wf" > wf.txt
  git add wf.txt
  git commit -qm "feat: wf"
  git shadow feature publish >/dev/null
  git checkout -q main
  git merge -q --no-edit wt-feat
  git checkout -q "wt-feat@local"
  WT_BASE="$(mktemp -d)"
  git worktree add -q "$WT_BASE/base" "main@local"
  echo "K=V" > "$TEST_DIR/.git-shadow.env"
  cp_before="$(git log --format='%s' main@local | grep -c '^\[CHECKPOINT\]')"
  cd "$WT_BASE/base"
  run git shadow feature finish wt-feat --no-pull
  [ "$status" -eq 1 ]
  [[ "$output" == *"$TEST_DIR"* ]]
  [ -f "$TEST_DIR/.git-shadow.env" ]
  git -C "$TEST_DIR" show-ref --verify --quiet "refs/heads/wt-feat@local"
  [ "$(git -C "$TEST_DIR" log --format='%s' main@local | grep -c '^\[CHECKPOINT\]')" = "$cp_before" ]
}
