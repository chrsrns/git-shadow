#!/usr/bin/env bats

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

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TOOLKIT_ROOT
  PATH="$TOOLKIT_ROOT/bin:$PATH"
  unset SHADOW_COMMIT_PREFIX
  source "$TOOLKIT_ROOT/lib/common.sh"
}

teardown() {
  rm -rf "$TEST_DIR" "$XDG_DIR"
}

# ---- predicate unit legs ----

@test "commit_subject_is_memory: default prefix and literal [MEMORY] classify" {
  run commit_subject_is_memory "[MEMORY] notes"
  [ "$status" -eq 0 ]
  run commit_subject_is_memory "feat: normal"
  [ "$status" -eq 1 ]
}

@test "commit_subject_is_memory: reconfigured prefix classifies" {
  SHADOW_COMMIT_PREFIX="[LOCAL]"
  run commit_subject_is_memory "[LOCAL] notes"
  [ "$status" -eq 0 ]
  run commit_subject_is_memory "[MEMORY] notes"
  [ "$status" -eq 0 ]
}

@test "commit_subject_is_memory: empty prefix disables only the prefix leg" {
  SHADOW_COMMIT_PREFIX=""
  run commit_subject_is_memory "[MEMORY] notes"
  [ "$status" -eq 0 ]
  run commit_subject_is_memory "feat: normal"
  [ "$status" -eq 1 ]
}

@test "commit_subject_is_memory: [CHECKPOINT]/[SYNC] never memory under colliding prefix" {
  SHADOW_COMMIT_PREFIX="[CHECKPOINT]"
  run commit_subject_is_memory "[CHECKPOINT] public:a local:b"
  [ "$status" -eq 1 ]
  SHADOW_COMMIT_PREFIX="[SYNC]"
  run commit_subject_is_memory "[SYNC] x"
  [ "$status" -eq 1 ]
}

@test "commit_subject_is_memory: prefix test is literal, not regex" {
  SHADOW_COMMIT_PREFIX="[MEMORY]"
  run commit_subject_is_memory "MEMORY loose"
  [ "$status" -eq 1 ]
  run commit_subject_is_memory "[MEMORY] x"
  [ "$status" -eq 0 ]
}

# ---- checkpoint legs (V289) ----

@test "checkpoint_parse requires non-empty hex fields" {
  git commit --allow-empty -qm "[CHECKPOINT] public:main local:main"
  run checkpoint_parse HEAD
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "checkpoint_latest skips malformed candidate and finds older valid" {
  good="$(checkpoint_create "$(git rev-parse HEAD)" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")"
  git commit --allow-empty -qm "[CHECKPOINT] garbage"
  run checkpoint_latest HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "$good" ]
}

# ---- commit abort legs (V41) ----

@test "git shadow commit aborts on memory-prefix public message" {
  git checkout -q -b feat/x@local
  echo x > new.txt
  git add new.txt
  run git shadow commit -m "[MEMORY] sneaky"
  [ "$status" -ne 0 ]
}

@test "git shadow commit aborts on toolkit-subject public message" {
  git checkout -q -b feat/x@local
  echo x > new.txt
  git add new.txt
  run git shadow commit -m "[CHECKPOINT] public:a local:b"
  [ "$status" -ne 0 ]
  run git shadow commit -m "[SYNC] fake"
  [ "$status" -ne 0 ]
}

# ---- load_env warn (V288) ----

@test "load_env warns on colliding SHADOW_COMMIT_PREFIX" {
  printf 'SHADOW_COMMIT_PREFIX="[SYNC]"\n' > .git-shadow.env
  run git shadow status
  [[ "$output" == *"SHADOW_COMMIT_PREFIX"*invalid* ]] || [[ "$output" == *"[SYNC]"* ]]
}

@test "load_env warns on empty SHADOW_COMMIT_PREFIX" {
  printf 'SHADOW_COMMIT_PREFIX=""\n' > .git-shadow.env
  run git shadow status
  [[ "$output" == *"SHADOW_COMMIT_PREFIX"*invalid* ]] || [[ "$output" == *"empty"* ]]
}

# ---- integration: publish exclusion + finish replay ----

@test "publish excludes a reconfigured-prefix memory commit" {
  base="$(git symbolic-ref --short HEAD)"
  printf 'SHADOW_COMMIT_PREFIX="[LOCAL]"\n' > .git-shadow.env
  if [ "$base" != main ]; then printf 'PUBLIC_BASE_BRANCH="%s"\n' "$base" >> .git-shadow.env; fi
  git checkout -q -b "${base}@local"
  git checkout -q "$base"
  git shadow feature start test-feature >/dev/null
  git checkout -q "test-feature@local"
  echo code > code.txt && git add code.txt && git commit -qm "feat: code"
  git commit --allow-empty -qm "[LOCAL] reasoning"
  git shadow feature publish >/dev/null
  run git log --format='%s' test-feature
  [ "$status" -eq 0 ]
  [[ "$output" != *"[LOCAL] reasoning"* ]]
  [[ "$output" == *"feat: code"* ]]
}

@test "feature finish replays a reconfigured-prefix memory commit onto the base" {
  base="$(git symbolic-ref --short HEAD)"
  printf 'SHADOW_COMMIT_PREFIX="[LOCAL]"\n' > .git-shadow.env
  if [ "$base" != main ]; then printf 'PUBLIC_BASE_BRANCH="%s"\n' "$base" >> .git-shadow.env; fi
  git checkout -q -b "${base}@local"
  git checkout -q "$base"
  git shadow feature start test-feature >/dev/null
  git checkout -q "test-feature@local"
  echo code > code.txt && git add code.txt && git commit -qm "feat: code"
  git commit --allow-empty -qm "[LOCAL] reasoning"
  git shadow feature publish >/dev/null
  git checkout -q "$base"
  git merge -q --no-edit test-feature
  git checkout -q "test-feature@local"
  git shadow feature finish --no-pull >/dev/null
  run git log --format='%s' "${base}@local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[LOCAL] reasoning"* ]]
}
