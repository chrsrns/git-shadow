#!/usr/bin/env bats

# Stacked finish: effective-base resolution drives merged-check, net
# diff, [MEMORY] replay, and the final checkpoint (V127, V131, V295,
# V298, V305, V306).

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main
  echo "initial" > file.txt
  git add file.txt
  git commit -qm "initial"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TOOLKIT_ROOT
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  # Parent pair with one published commit.
  git shadow feature start parent-feature >/dev/null
  echo "parent code" > parent.txt
  git add parent.txt
  git commit -qm "feat: parent code"
  git shadow feature publish >/dev/null

  # Child pair stacked on the parent.
  git shadow feature start child-feature >/dev/null
  echo "child code" > child.txt
  git add child.txt
  git commit -qm "feat: child code"
  git shadow feature publish >/dev/null

  # Merge the child into the parent public branch (the stack target).
  git checkout -q parent-feature
  git merge -q --no-edit child-feature
  git checkout -q child-feature@local
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Pause the stacked finish on a [MEMORY] conflict against the parent:
# both sides replaced file.txt's whole content.
pause_finish() {
  echo "child note text" > file.txt
  git add file.txt
  git commit -qm "[MEMORY] child note"
  git checkout -q parent-feature@local
  echo "parent note text" > file.txt
  git add file.txt
  git commit -qm "[MEMORY] parent note"
  git checkout -q child-feature@local
  run git shadow feature finish --no-pull
  [ "$status" -ne 0 ]
}

@test "stacked finish replays the feature [MEMORY] onto the parent @local" {
  echo "child notes" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] child notes"

  git shadow feature finish --no-pull >/dev/null
  [ "$(git branch --show-current)" = "parent-feature@local" ]
  git show parent-feature@local:notes.md >/dev/null
  body="$(git log --format='%b' parent-feature@local)"
  [[ "$body" == *"git-shadow-source-memory:"* ]]
}

@test "stacked finish preserves the parent's publishable backlog via cp_local" {
  # Unpublished public work on the parent must survive the child's
  # finish checkpoint.
  git checkout -q parent-feature@local
  echo "backlog" > backlog.txt
  git add backlog.txt
  git commit -qm "feat: parent backlog"
  PRE_CP_LOCAL="$(git log --format='%s' parent-feature@local \
    | grep '^\[CHECKPOINT\]' | head -1 \
    | sed -n 's/.*local:\([0-9a-f]*\).*/\1/p')"
  [ -n "$PRE_CP_LOCAL" ]
  git checkout -q child-feature@local

  git shadow feature finish --no-pull >/dev/null

  # The new tip checkpoint records the parent's pre-finish cp_local, not
  # the post-replay tip — the backlog stays publishable.
  tip_subject="$(git log -1 --format='%s' parent-feature@local)"
  [[ "$tip_subject" == *"local:$PRE_CP_LOCAL"* ]]
  git checkout -q parent-feature@local
  run git shadow status
  [[ "$output" == *"publishable"*1* ]]
}

@test "stacked finish deletes the child pair and keeps the parent pair" {
  git shadow feature finish --no-pull >/dev/null
  ! git show-ref --verify --quiet "refs/heads/child-feature"
  ! git show-ref --verify --quiet "refs/heads/child-feature@local"
  git show-ref --verify --quiet "refs/heads/parent-feature"
  git show-ref --verify --quiet "refs/heads/parent-feature@local"
}

@test "stacked finish lands the child public content on the parent" {
  git shadow feature finish --no-pull >/dev/null
  [ "$(git show parent-feature@local:child.txt)" = "child code" ]
}

@test "finishing a parent warns naming each stacked child left dangling" {
  # Merge the parent into main so its own finish passes the merged-check.
  git checkout -q main
  git merge -q --no-edit parent-feature
  git checkout -q main@local

  run git shadow feature finish parent-feature --no-pull
  [ "$status" -eq 0 ]
  [[ "$output" == *"child-feature"* ]]
  [[ "$output" == *"dangling"* ]]

  # The child's shadow-parent now dangles; its effective base is main.
  [ "$(git config --get branch.child-feature@local.shadow-parent)" = "parent-feature" ]
}

@test "finish retargets to the base pair when the parent pair is deleted" {
  # Child merges into main directly (parent pair then deleted).
  git checkout -q main
  git merge -q --no-edit child-feature
  git checkout -q child-feature@local
  git branch -D parent-feature parent-feature@local >/dev/null

  echo "child notes" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] child notes"

  git shadow feature finish --no-pull >/dev/null
  git show main@local:notes.md >/dev/null
  [ "$(git branch --show-current)" = "main@local" ]
}

@test "named finish accepts a resolved-parent-pair checkout" {
  git checkout -q parent-feature@local
  run git shadow feature finish child-feature --no-pull
  [ "$status" -eq 0 ]
}

@test "named finish refuses from an unrelated checkout" {
  git checkout -q main
  git shadow feature start other-feature >/dev/null
  run git shadow feature finish child-feature --no-pull
  [ "$status" -eq 1 ]
  [[ "$output" == *"parent-feature@local"* ]]
}

@test "unpaused --mark-applied writes provenance to the parent @local" {
  echo "child notes" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] child notes"
  MEM_SHA="$(git rev-parse HEAD)"

  git shadow feature finish --mark-applied "$MEM_SHA" >/dev/null
  body="$(git log -1 --format='%b' parent-feature@local)"
  [[ "$body" == *"git-shadow-source-memory: $MEM_SHA"* ]]
}

@test "unpaused --mark-applied refuses when the resolved base is the invoking branch" {
  git checkout -q main@local
  echo "child notes" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] stray notes"
  MEM_SHA="$(git rev-parse HEAD)"

  run git shadow feature finish --mark-applied "$MEM_SHA"
  [ "$status" -eq 1 ]
}

@test "finish --abort clears state when the stored local base was deleted" {
  pause_finish
  state_file="$(git rev-parse --git-dir)/git-shadow-finish"
  [ -f "$state_file" ]
  grep -q "local_base=parent-feature@local" "$state_file"

  # The parent pair disappears mid-pause.
  git update-ref -d "refs/heads/parent-feature@local"
  git update-ref -d "refs/heads/parent-feature"

  run git shadow feature finish --abort
  [ "$status" -eq 0 ]
  [ ! -f "$state_file" ]
  [[ "$output" == *"parent-feature@local"* ]]
}

@test "finish --continue refuses when the stored local base was deleted" {
  pause_finish
  state_file="$(git rev-parse --git-dir)/git-shadow-finish"
  [ -f "$state_file" ]

  git update-ref -d "refs/heads/parent-feature@local"
  git update-ref -d "refs/heads/parent-feature"

  run git shadow feature finish --continue
  [ "$status" -eq 1 ]
  [[ "$output" == *"parent-feature@local"* ]]
  [ -f "$state_file" ]
}

@test "paused finish pins the resolved base in state" {
  pause_finish
  grep -q "local_base=parent-feature@local" "$(git rev-parse --git-dir)/git-shadow-finish"
}

@test "merged-check failure on a stacked pair names the reparent retarget" {
  # Rewind the parent past the child merge, then merge the child into
  # the real base instead — the retarget path is reparent --onto main.
  git branch -f parent-feature "$(git rev-parse 'parent-feature^')"
  git checkout -q main
  git merge -q --no-edit child-feature
  git checkout -q child-feature@local

  run git shadow feature finish --no-pull
  [ "$status" -eq 1 ]
  [[ "$output" == *"reparent child-feature --onto main"* ]]
}

@test "no-checkpoint hint names feature sync on a feature-pair base" {
  # Rebuild the parent pair by hand — live pair, @local on a rootless
  # commit so no [CHECKPOINT] exists in its history — then merge the
  # child into the rebuilt parent.
  git checkout -q main
  git branch -D parent-feature parent-feature@local >/dev/null
  git branch parent-feature main
  orphan="$(echo "orphan" | git commit-tree "$(git rev-parse 'main^{tree}')")"
  git update-ref "refs/heads/parent-feature@local" "$orphan"
  git checkout -q parent-feature
  git merge -q --no-edit child-feature
  git checkout -q child-feature@local

  run git shadow feature finish --no-pull
  [ "$status" -eq 1 ]
  [[ "$output" == *"feature sync"* ]]
  [[ "$output" != *"base sync"* ]]
}

@test "finish dedups a child [MEMORY] cherry-picked from the parent line" {
  # A plain [MEMORY] lands on the parent after the child branched; the
  # child cherry-picks it — same patch-id, no provenance trailer.
  git checkout -q parent-feature@local
  echo "shared note" > shared-note.txt
  git add shared-note.txt
  git commit -qm "[MEMORY] shared note"
  MEM_SHA="$(git rev-parse HEAD)"
  git checkout -q child-feature@local
  git cherry-pick "$MEM_SHA" >/dev/null

  run git shadow feature finish --no-pull
  [ "$status" -eq 0 ]
  count="$(git log --format='%s' parent-feature@local | grep -c 'shared note')"
  [ "$count" -eq 1 ]
}

@test "finish --no-pull succeeds while the parent public branch is worktree-held" {
  git worktree add -q "$TEST_DIR/wt" parent-feature
  run git shadow feature finish --no-pull
  [ "$status" -eq 0 ]
}
