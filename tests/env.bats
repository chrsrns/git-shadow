#!/usr/bin/env bats

# Unit tests for lib/env.sh loading helpers.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  XDG_DIR="$(mktemp -d)"
  export XDG_CONFIG_HOME="$XDG_DIR"
}

teardown() {
  rm -rf "$TEST_DIR" "$XDG_DIR"
}

@test "_load_config_file exports variables from a file" {
  source "$TOOLKIT_ROOT/lib/env.sh"
  cat > config.env <<'EOF'
LOCAL_SUFFIX="@mine"
EOF
  _load_config_file config.env 0
  [ "$LOCAL_SUFFIX" = "@mine" ]
}

@test "_load_config_file returns 0 when file is missing" {
  source "$TOOLKIT_ROOT/lib/env.sh"
  run _load_config_file missing.env 1
  [ "$status" -eq 0 ]
}

@test "_load_config_file warns on unknown keys when requested" {
  source "$TOOLKIT_ROOT/lib/env.sh"
  cat > config.env <<'EOF'
UNKNOWN_KEY=value
EOF
  run _load_config_file config.env 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unknown config key"* ]]
}

@test "load_env uses defaults, user, and project configs in order" {
  # Defaults include LOCAL_SUFFIX=@local and PUBLIC_BASE_BRANCH=main.
  # User config overrides LOCAL_SUFFIX.
  mkdir -p "$XDG_CONFIG_HOME/git-shadow"
  cat > "$XDG_CONFIG_HOME/git-shadow/config.env" <<'EOF'
LOCAL_SUFFIX="@user"
EOF

  # Project config overrides user config.
  cat > "$PWD/.git-shadow.env" <<'EOF'
LOCAL_SUFFIX="@project"
EOF

  source "$TOOLKIT_ROOT/lib/env.sh"
  load_env

  [ "$LOCAL_SUFFIX" = "@project" ]
  [ "$PUBLIC_BASE_BRANCH" = "main" ]
}

@test "load_env does not warn for unknown keys in defaults" {
  source "$TOOLKIT_ROOT/lib/env.sh"
  run load_env
  [[ "$output" != *"Unknown config key"* ]]
}
