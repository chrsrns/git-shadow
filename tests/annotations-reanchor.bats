#!/usr/bin/env bats

# Regression tests for V108: annotation re-anchor failures must not be swallowed.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck disable=SC1091
  source "$TOOLKIT_ROOT/lib/common.sh"

  # Replace python3 with a failing fake so `annotations_reanchor` errors.
  mkdir -p "$TEST_DIR/fakebin"
  cat > "$TEST_DIR/fakebin/python3" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$TEST_DIR/fakebin/python3"
  PATH="$TEST_DIR/fakebin:$PATH"

  echo "public source" > file.txt
  git add file.txt
  git commit -q -m "initial"

  mkdir -p .git-shadow/annotations
  echo "sidecar" > .git-shadow/annotations/file.txt
  git add .git-shadow/annotations/file.txt
  git commit -q -m "checkpoint with sidecar"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "annotations_reanchor_all fails when re-anchor subprocess fails" {
  run annotations_reanchor_all
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot re-anchor sidecar"* ]]
}

@test "annotations_reanchor_all_commit returns 1 when re-anchor fails" {
  run annotations_reanchor_all_commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot re-anchor sidecar"* ]]
}
