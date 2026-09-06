#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TOOLKIT_ROOT
  PATH="$TOOLKIT_ROOT/bin:$PATH"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/develop
  echo "initial" > file.txt
  git add file.txt
  git commit -qm "initial"
  git checkout -q -b "develop@local"
  git checkout -q develop
  # Create a feature branch pair and add a code commit
  git shadow feature start test-feature
  printf 'real code\n' > feature.txt
  git add feature.txt
  git commit -m "feat: real code"
  # Now on test-feature@local with 1 publishable commit
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "feature publish exits 1 when not on a @local branch" {
  git checkout -q test-feature
  run git shadow feature publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"@local"* ]]
}

@test "feature publish exits 0 from a @local branch" {
  run git shadow feature publish
  [ "$status" -eq 0 ]
}

@test "feature publish replays the code commit to the public branch" {
  git shadow feature publish
  git checkout -q test-feature
  result="$(git log --oneline)"
  [[ "$result" == *"feat: real code"* ]]
}

@test "feature publish skips [MEMORY] commits from the public branch" {
  git shadow feature publish
  git checkout -q test-feature
  result="$(git log --oneline)"
  [[ "$result" != *"[MEMORY]"* ]]
}

@test "feature publish outputs a completion message" {
  run git shadow feature publish
  [ "$status" -eq 0 ]
  [[ "$output" == *"Published to"* ]]
}

@test "feature publish exits 0 with no publishable commits (already up to date)" {
  git shadow feature publish
  git checkout -q "test-feature@local"
  run git shadow feature publish
  [ "$status" -eq 0 ]
}

@test "feature publish creates a checkpoint on the local branch" {
  git shadow feature publish
  subject="$(git log -1 --format='%s' test-feature@local)"
  [[ "$subject" == "[CHECKPOINT]"* ]]
}

@test "feature publish aborts with a named error when the check pass fails" {
  mkdir -p notes
  echo "local note" > notes/local.md
  git add notes/local.md
  git commit -qm "[MEMORY] local note"
  git rm -q notes/local.md
  git commit -qm "fix: drop local note"

  run git shadow feature publish
  [ "$status" -ne 0 ]
  [[ "$output" != *"No publishable commits"* ]]
  [[ "$output" == *"notes/local.md"* ]]
  [[ "$output" == *"Check pass"* || "$output" == *"check pass"* ]]
}

@test "feature publish allows excluded docs with marker examples" {
  mkdir -p docs
  cat > docs/git-shadow-as-ia-memory-layer.md <<'EOF'
```ts
/// This is an example local note.
```
EOF
  git add docs/git-shadow-as-ia-memory-layer.md
  git commit -m "docs: add marker example"

  run git shadow feature publish
  [ "$status" -eq 0 ]
  [[ "$output" == *"Published to"* ]]
}
