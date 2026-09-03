#!/usr/bin/env bats

# Test that the normal diff-sync workflow (base sync, feature start, publish,
# finish) works after migrating an existing project with the messy v1-style
# history preserved via `git shadow re-anchor`.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main

  # 1. Create an initial public commit on main (v1 state)
  echo "v1" > file.txt
  git add file.txt
  git commit -qm "feat: v1 public file"

  # 2. Create a v1-style main@local from main
  git checkout -q -b main@local

  # 3. Simulate messy v1 history on main@local:
  #    - a legacy feature branch with a public commit
  #    - merged into main@local (v1 merge-finish style)
  #    - local-only [MEMORY] notes added afterwards
  git checkout -q -b legacy-feature main
  echo "legacy code" > legacy.txt
  git add legacy.txt
  git commit -qm "feat: legacy feature"

  git checkout -q main@local
  git merge -q --no-edit legacy-feature

  echo "agent context" > notes.md
  git add notes.md
  git commit -qm "[MEMORY] migration notes"

  # 4. Simulate the project being migrated to diff-sync: main is updated
  #    to a new public tree (like the diff-sync rewrite) while main@local
  #    already contains that tree plus the messy local history.
  git checkout -q main
  echo "v2" > file.txt
  git add file.txt
  git commit -qm "feat: diff-sync rewrite"

  # main@local already has v2 from the merge above? No. We need to put the
  # same public tree on main@local before re-anchor. Apply the v2 change as a
  # public commit on main@local (this is the "messy" part: a local branch with
  # ad-hoc public content).
  git checkout -q main@local
  echo "v2" > file.txt
  git add file.txt
  git commit -qm "feat: adopt diff-sync changes"

  # 5. main and main@local now have the same public tree, but main@local still
  #    carries the legacy merge and [MEMORY] notes.
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "re-anchor creates checkpoint and preserves messy history" {
  git checkout -q main@local

  run git shadow re-anchor main@local
  [ "$status" -eq 0 ]

  # A new checkpoint was created on main@local
  subject="$(git log -1 --format='%s' main@local)"
  [[ "$subject" == "[CHECKPOINT]"* ]]

  # The legacy merge and [MEMORY] notes are still in the history
  log="$(git log --oneline main@local)"
  [[ "$log" == *"feat: legacy feature"* ]]
  [[ "$log" == *"[MEMORY] migration notes"* ]]

  # Local-only file is still present
  [ -f notes.md ]
}

@test "base sync works after re-anchor migration" {
  git checkout -q main@local
  git shadow re-anchor main@local

  # Add another public commit to main
  git checkout -q main
  echo "v3" > file.txt
  git add file.txt
  git commit -qm "feat: public update after re-anchor"

  git checkout -q main@local
  run git shadow base sync
  [ "$status" -eq 0 ]

  # main@local now has v3
  result="$(cat file.txt)"
  [ "$result" = "v3" ]

  # local-only file still present
  [ -f notes.md ]

  # status is clean
  run git shadow status
  [[ "$output" == *"diverged     : false"* ]]
  [[ "$output" == *"public-ahead : 0"* ]]
}

@test "feature workflow works after re-anchor migration" {
  git checkout -q main@local
  git shadow re-anchor main@local

  # Start a new diff-sync feature from the migrated main@local
  git checkout -q main@local
  run git shadow feature start workflow-feature
  [ "$status" -eq 0 ]

  # We are now on workflow-feature@local
  current="$(git branch --show-current)"
  [ "$current" = "workflow-feature@local" ]

  # Add public code
  echo "workflow code" > workflow.txt
  git add workflow.txt
  git commit -qm "feat: workflow code"

  # Publish the feature
  run git shadow feature publish
  [ "$status" -eq 0 ]

  # Public branch has the code, not the [MEMORY] notes
  git checkout -q workflow-feature
  public_log="$(git log --oneline)"
  [[ "$public_log" == *"feat: workflow code"* ]]
  [[ "$public_log" != *"[MEMORY]"* ]]

  # Merge the feature into main and finish it
  git checkout -q main
  git merge -q --no-edit workflow-feature

  git checkout -q workflow-feature@local
  run git shadow feature finish --no-pull
  [ "$status" -eq 0 ]

  # Feature branches deleted
  run git branch --list workflow-feature
  [ -z "$output" ]
  run git branch --list workflow-feature@local
  [ -z "$output" ]

  # main@local has the new public code and the original local notes
  git checkout -q main@local
  [ -f workflow.txt ]
  [ -f notes.md ]

  # main@local got a final checkpoint
  subject="$(git log -1 --format='%s' main@local)"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}
