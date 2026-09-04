#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TOOLKIT_ROOT
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  PATH="$TOOLKIT_ROOT/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# pre-commit hook
# ---------------------------------------------------------------------------

@test "install-hooks exits 0" {
  run git shadow install-hooks
  [ "$status" -eq 0 ]
}

@test "install-hooks creates .git/hooks/pre-commit file" {
  git shadow install-hooks
  [ -f ".git/hooks/pre-commit" ]
}

@test "install-hooks makes the pre-commit hook executable" {
  git shadow install-hooks
  [ -x ".git/hooks/pre-commit" ]
}

@test "install-hooks pre-commit is idempotent (exits 0 when already installed)" {
  git shadow install-hooks
  run git shadow install-hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
}

# ---------------------------------------------------------------------------
# pre-push hook
# ---------------------------------------------------------------------------

@test "install-hooks creates .git/hooks/pre-push file" {
  git shadow install-hooks
  [ -f ".git/hooks/pre-push" ]
}

@test "install-hooks makes the pre-push hook executable" {
  git shadow install-hooks
  [ -x ".git/hooks/pre-push" ]
}

@test "install-hooks pre-push is idempotent (exits 0 when already installed)" {
  git shadow install-hooks
  run git shadow install-hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
}

@test "install-hooks pre-push hook contains public branch guard" {
  git shadow install-hooks
  grep -q "public branch" ".git/hooks/pre-push"
}

@test "install-hooks pre-commit hook is syntactically valid sh" {
  git shadow install-hooks
  sh -n ".git/hooks/pre-commit"
}

@test "install-hooks pre-push hook is syntactically valid sh" {
  git shadow install-hooks
  sh -n ".git/hooks/pre-push"
}

@test "install-hooks appended pre-commit hook is syntactically valid sh" {
  printf '#!/usr/bin/env sh\necho "existing hook"\n' > ".git/hooks/pre-commit"
  chmod +x ".git/hooks/pre-commit"
  git shadow install-hooks
  sh -n ".git/hooks/pre-commit"
}

@test "pre-commit rejects a commit on a public branch without GIT_SHADOW" {
  git commit --allow-empty -q -m "initial"
  git shadow install-hooks
  echo "change" > file.txt
  git add file.txt
  run git commit -q -m "public commit"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to commit"* ]]
}

@test "pre-commit allows a commit on a public branch with GIT_SHADOW=1" {
  git commit --allow-empty -q -m "initial"
  git shadow install-hooks
  echo "change" > file.txt
  git add file.txt
  GIT_SHADOW=1 run git commit -q -m "public commit"
  [ "$status" -eq 0 ]
}

@test "pre-commit allows a commit on a @local branch" {
  git commit --allow-empty -q -m "initial"
  git shadow install-hooks
  git checkout -q -b "test@local"
  echo "change" > file.txt
  git add file.txt
  run git commit -q -m "local commit"
  [ "$status" -eq 0 ]
}

@test "pre-commit honors extglob patterns in LOCAL_COMMENT_EXCLUDE" {
  git commit --allow-empty -q -m "initial"
  git checkout -q -b "test@local"
  printf 'LOCAL_COMMENT_EXCLUDE="docs/!(public).md"\n' > .git-shadow.env
  git shadow install-hooks

  # docs/internal.md matches docs/!(public).md → /// check is skipped.
  mkdir -p docs
  printf 'public\n/// local note\n' > docs/internal.md
  git add docs/internal.md
  run git commit -q -m "excluded file with /// marker"
  [ "$status" -eq 0 ]

  # docs/public.md does NOT match the extglob → /// is still rejected.
  printf 'public\n/// local note\n' > docs/public.md
  git add docs/public.md
  run git commit -q -m "not excluded"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/// markers"* ]]
}

@test "pre-push rejects a public branch push without GIT_SHADOW" {
  initial_sha="$(git commit --allow-empty -q -m "initial" && git rev-parse HEAD)"
  git shadow install-hooks
  run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' \"$initial_sha\" \"$initial_sha\" | .git/hooks/pre-push origin url"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to push"* ]]
}

@test "pre-push allows a public branch push with GIT_SHADOW=1" {
  initial_sha="$(git commit --allow-empty -q -m "initial" && git rev-parse HEAD)"
  git shadow install-hooks
  GIT_SHADOW=1 run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' \"$initial_sha\" \"$initial_sha\" | .git/hooks/pre-push origin url"
  [ "$status" -eq 0 ]
}

@test "pre-push allows a @local branch push" {
  initial_sha="$(git commit --allow-empty -q -m "initial" && git rev-parse HEAD)"
  git shadow install-hooks
  run bash -c "printf 'refs/heads/test@local %s refs/heads/test@local %s\n' \"$initial_sha\" \"$initial_sha\" | .git/hooks/pre-push origin url"
  [ "$status" -eq 0 ]
}
