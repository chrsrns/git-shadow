#!/usr/bin/env bats

# Unit tests for lib/hook-installer.sh:install_hook_file.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "install_hook_file creates a new hook with one shebang" {
  source "$TOOLKIT_ROOT/lib/common.sh"
  install_hook_file pre-commit "# my marker" "echo 'hello'" bash
  [ -f .git/hooks/pre-commit ]
  [ -x .git/hooks/pre-commit ]
  lines=()
  while IFS= read -r line; do lines+=("$line"); done < <(head -3 .git/hooks/pre-commit)
  [ "${lines[0]}" = "#!/usr/bin/env bash" ]
  [ "${lines[1]}" = "# my marker" ]
  [ "${lines[2]}" = "echo 'hello'" ]
}

@test "install_hook_file uses sh shebang when omitted" {
  source "$TOOLKIT_ROOT/lib/common.sh"
  install_hook_file pre-push "# my marker" "echo 'hello'"
  [ -f .git/hooks/pre-push ]
  [ "$(head -1 .git/hooks/pre-push)" = "#!/usr/bin/env sh" ]
}

@test "install_hook_file appends to an existing hook" {
  printf '#!/usr/bin/env sh\necho existing\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit

  source "$TOOLKIT_ROOT/lib/common.sh"
  install_hook_file pre-commit "# my marker" "echo 'appended'" bash

  [[ "$(cat .git/hooks/pre-commit)" == *"echo existing"* ]]
  [[ "$(cat .git/hooks/pre-commit)" == *"# my marker"* ]]
  [[ "$(cat .git/hooks/pre-commit)" == *"echo 'appended'"* ]]
}

@test "install_hook_file is idempotent" {
  source "$TOOLKIT_ROOT/lib/common.sh"
  install_hook_file pre-commit "# my marker" "echo 'hello'" bash
  install_hook_file pre-commit "# my marker" "echo 'hello'" bash
  [ "$(grep -c 'my marker' .git/hooks/pre-commit)" -eq 1 ]
}
