#!/usr/bin/env bats

# Unit tests for lib/common.sh repository-probe helpers.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$TOOLKIT_ROOT/lib/common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "repo_root prints the worktree toplevel" {
  git init -q repo
  cd repo
  run repo_root
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/repo" ]
}

@test "repo_root returns 1 outside a repo" {
  run repo_root
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "repo_root prints the toplevel from a subdirectory" {
  git init -q repo
  mkdir -p repo/sub/dir
  cd repo/sub/dir
  run repo_root
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/repo" ]
}

@test "repo_root_or_pwd prints $PWD outside a repo" {
  run repo_root_or_pwd
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR" ]
}

@test "repo_root_or_pwd prints the toplevel inside a repo" {
  git init -q repo
  cd repo
  run repo_root_or_pwd
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/repo" ]
}

# Create a repo with a two-path merge conflict; one path contains a space.
# One unmerged path lives under a directory outside any invocation cwd
# subdirectory used by the tests below.
_setup_conflict() {
  git init -qb main repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  mkdir -p dir
  echo a > "f one.txt"
  echo b > "dir/g.txt"
  git add .
  git commit -qm base
  git checkout -qb side
  echo side-a > "f one.txt"
  echo side-b > "dir/g.txt"
  git commit -qam side
  git checkout -q main
  echo main-a > "f one.txt"
  echo main-b > "dir/g.txt"
  git commit -qam main
  git merge side >/dev/null 2>&1 || true
}

@test "conflicted_paths prints the sorted-unique unmerged set" {
  _setup_conflict
  run conflicted_paths
  [ "$status" -eq 0 ]
  [ "$output" = "dir/g.txt
f one.txt" ]
}

@test "conflicted_paths prints a space-containing path whole" {
  _setup_conflict
  run conflicted_paths
  [ "$status" -eq 0 ]
  [[ "$output" == *"f one.txt"* ]]
}

@test "conflicted_paths reports toplevel-relative paths from a subdirectory" {
  _setup_conflict
  mkdir -p sub
  cd sub
  run conflicted_paths
  [ "$status" -eq 0 ]
  [ "$output" = "dir/g.txt
f one.txt" ]
}

@test "branch_exists returns 0 on an existing branch" {
  git init -qb main repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git commit --allow-empty -qm init
  run branch_exists main
  [ "$status" -eq 0 ]
}

@test "branch_exists returns 1 on a missing branch" {
  git init -qb main repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git commit --allow-empty -qm init
  run branch_exists missing-branch
  [ "$status" -eq 1 ]
}

@test "abs_path_m canonicalizes a path with missing components" {
  run abs_path_m "$TEST_DIR/nope/deeper/../leaf"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/nope/leaf" ]
}

@test "abs_path_m resolves a relative path against \$PWD" {
  mkdir -p sub
  cd sub
  run abs_path_m "x/../y"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/sub/y" ]
}

@test "expand_tilde expands bare ~" {
  run expand_tilde "~"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME" ]
}

@test "expand_tilde expands ~/path" {
  run expand_tilde "~/x/y"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/x/y" ]
}

@test "expand_tilde passes absolute paths through" {
  run expand_tilde "/abs/path"
  [ "$status" -eq 0 ]
  [ "$output" = "/abs/path" ]
}

@test "rev_path_exists finds a HEAD blob" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo x > f.txt
  git add f.txt
  git commit -qm init
  run rev_path_exists HEAD f.txt
  [ "$status" -eq 0 ]
}

@test "rev_path_exists returns 1 for a missing path" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git commit --allow-empty -qm init
  run rev_path_exists HEAD missing.txt
  [ "$status" -eq 1 ]
}

@test "rev_path_exists probes the staged index on an empty rev" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git commit --allow-empty -qm init
  echo staged > new.txt
  run rev_path_exists "" new.txt
  [ "$status" -eq 1 ]
  git add new.txt
  run rev_path_exists "" new.txt
  [ "$status" -eq 0 ]
}

@test "rev_blob_to writes a HEAD blob to a file" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo blob-content > f.txt
  git add f.txt
  git commit -qm init
  run rev_blob_to HEAD f.txt out.txt
  [ "$status" -eq 0 ]
  [ "$(cat out.txt)" = "blob-content" ]
}

@test "rev_blob_to returns 1 on a missing object" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git commit --allow-empty -qm init
  run rev_blob_to HEAD missing.txt out.txt
  [ "$status" -eq 1 ]
}

@test "rev_blob_to reads the staged blob on an empty rev" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git commit --allow-empty -qm init
  echo staged-content > s.txt
  git add s.txt
  run rev_blob_to "" s.txt out.txt
  [ "$status" -eq 0 ]
  [ "$(cat out.txt)" = "staged-content" ]
}

@test "require_local_branch renders a supplied label in the refusal" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main
  git commit --allow-empty -qm init
  run require_local_branch "git shadow demo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"git shadow demo must be run from a branch ending with"* ]]
}

@test "require_local_branch keeps the generic message without a label" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main
  git commit --allow-empty -qm init
  run require_local_branch
  [ "$status" -eq 1 ]
  [[ "$output" == *"This command must be run from a branch ending with"* ]]
}

@test "local_branch_refs prints only *@local shortnames sorted" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main
  git commit --allow-empty -qm init
  git branch zebra@local
  git branch feat/x@local
  git branch plain
  run local_branch_refs
  [ "$status" -eq 0 ]
  [ "$output" = $'feat/x@local\nzebra@local' ]
}

@test "paired_public_branches emits only paired public names sorted" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main
  git commit --allow-empty -qm init
  git branch feat/x
  git branch feat/x@local
  git branch orphan@local
  git branch unpaired
  run paired_public_branches
  [ "$status" -eq 0 ]
  [ "$output" = "feat/x" ]
}

@test "require_no_in_progress_git_op aborts naming a cherry-pick" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git commit --allow-empty -qm init
  touch "$(git rev-parse --git-path CHERRY_PICK_HEAD)"
  run require_no_in_progress_git_op
  [ "$status" -eq 1 ]
  [[ "$output" == *"cherry-pick is still in progress"* ]]
}

@test "require_no_in_progress_git_op aborts naming a merge" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git commit --allow-empty -qm init
  touch "$(git rev-parse --git-path MERGE_HEAD)"
  run require_no_in_progress_git_op
  [ "$status" -eq 1 ]
  [[ "$output" == *"merge is still in progress"* ]]
}

@test "require_no_in_progress_git_op aborts naming a rebase" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git commit --allow-empty -qm init
  mkdir -p "$(git rev-parse --git-path rebase-merge)"
  run require_no_in_progress_git_op
  [ "$status" -eq 1 ]
  [[ "$output" == *"rebase is still in progress"* ]]
}

@test "require_no_in_progress_git_op passes on a clean state" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  git commit --allow-empty -qm init
  run require_no_in_progress_git_op
  [ "$status" -eq 0 ]
}

@test "index_dirty returns 0 on a staged change" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo x > f.txt
  git add f.txt
  git commit -qm init
  echo y >> f.txt
  git add f.txt
  run index_dirty
  [ "$status" -eq 0 ]
}

@test "index_dirty returns 1 on a clean index" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo x > f.txt
  git add f.txt
  git commit -qm init
  run index_dirty
  [ "$status" -eq 1 ]
}

@test "index_dirty sees staged changes from a subdirectory" {
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo x > f.txt
  git add f.txt
  git commit -qm init
  mkdir sub
  echo y >> f.txt
  git add f.txt
  cd sub
  run index_dirty
  [ "$status" -eq 0 ]
}
