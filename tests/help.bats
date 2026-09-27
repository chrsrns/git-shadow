#!/usr/bin/env bats

# Uniform help contract: every leaf resolves -h|--help before any
# repository, config, or state access; usage goes to stdout with exit 0.

TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  TEST_DIR="$(mktemp -d)"
  export TEST_DIR

  HOME_DIR="$TEST_DIR/home"
  mkdir -p "$HOME_DIR"
  export HOME="$HOME_DIR"
  export XDG_CONFIG_HOME="$HOME_DIR/xdg"
  export SHELL="/bin/bash"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  cd "$TEST_DIR"
  git init -q repo
  cd repo
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "initial" > file.txt
  git add file.txt
  git commit -qm "initial"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- helpers ---------------------------------------------------------------

# Print every dispatcher-routed leaf as "group/sub" or "cmd" (path under
# commands/ without .sh).
_leaf_paths() {
  local f
  for f in "$TOOLKIT_ROOT"/commands/*.sh "$TOOLKIT_ROOT"/commands/*/*.sh; do
    f="${f#"$TOOLKIT_ROOT"/commands/}"
    printf '%s\n' "${f%.sh}"
  done
}

# Print rendered §I command signatures (one per line), or nothing when
# SPEC.md is absent (public checkout / packaged tree — V204).
_spec_sigs() {
  [[ -f "$TOOLKIT_ROOT/SPEC.md" ]] || return 0
  awk '
    /^\| `git shadow / {
      sig = $0
      sub(/^\| `/, "", sig)
      sub(/`.*/, "", sig)
      gsub(/\\\|/, "|", sig)
      print sig
    }' "$TOOLKIT_ROOT/SPEC.md"
}

# Rendered §I signature for a leaf path (e.g. "feature/start").
_spec_sig_for() {
  local words
  words="$(tr '/' ' ' <<< "${1%.sh}")"
  _spec_sigs | while IFS= read -r sig; do
    if [[ "$sig" == "git shadow $words" || "$sig" == "git shadow $words "* ]]; then
      printf '%s\n' "$sig"
      return 0
    fi
  done
}

# Run a help invocation; sets $h_out $h_err_file $h_status.
_help() {
  h_err_file="$(mktemp "$TEST_DIR/err.XXXXXX")"
  h_out="$("$@" </dev/null 2>"$h_err_file")"
  h_status=$?
}

# Assert: exit 0, stderr empty, stdout starts with "Usage: git shadow".
_assert_usage() {
  local label="$1"
  if [[ "$h_status" -ne 0 ]]; then
    echo "FAIL $label: exit $h_status; stderr: $(cat "$h_err_file")" >&2
    return 1
  fi
  if [[ -s "$h_err_file" ]]; then
    echo "FAIL $label: stderr not empty: $(cat "$h_err_file")" >&2
    return 1
  fi
  if [[ "$h_out" != "Usage: git shadow "* ]]; then
    echo "FAIL $label: stdout does not start with 'Usage: git shadow': $h_out" >&2
    return 1
  fi
  return 0
}

# --- top-level -------------------------------------------------------------

@test "top-level help forms print the Commands inventory" {
  # V209: `git shadow --help` is intercepted by git's own help builtin;
  # the --help form is exercised via the direct binary.
  local form
  for form in "" "help" "-h"; do
    _help git shadow $form
    if [[ "$h_status" -ne 0 ]]; then
      echo "FAIL form '$form': exit $h_status" >&2
      return 1
    fi
    if [[ -s "$h_err_file" ]]; then
      echo "FAIL form '$form': stderr not empty" >&2
      return 1
    fi
    if [[ "$h_out" != *"Commands:"* ]]; then
      echo "FAIL form '$form': no Commands: block" >&2
      return 1
    fi
    if grep -q '^Usage:' <<< "$h_out"; then
      echo "FAIL form '$form': generic Usage: line present" >&2
      return 1
    fi
  done
  _help "$TOOLKIT_ROOT/bin/git-shadow" --help
  if [[ "$h_status" -ne 0 ]]; then
    echo "FAIL direct git-shadow --help: exit $h_status" >&2
    return 1
  fi
  [[ "$h_out" == *"Commands:"* ]]
  [[ ! -s "$h_err_file" ]]
}

@test "direct git-shadow --help ignores trailing args" {
  _help "$TOOLKIT_ROOT/bin/git-shadow" --help bogus extra
  [[ "$h_status" -eq 0 ]]
  [[ "$h_out" == *"Commands:"* ]]
}

@test "top-level help lists every §I leaf signature" {
  [[ -f "$TOOLKIT_ROOT/SPEC.md" ]] || skip "SPEC.md absent (public tree)"
  local out sig
  out="$(git shadow help </dev/null)"
  while IFS= read -r sig; do
    if [[ "$out" != *"$sig"* ]]; then
      echo "missing from top-level help: $sig" >&2
      return 1
    fi
  done < <(_spec_sigs)
}

@test "arguments after a top-level help token are ignored" {
  _help git shadow -h bogus
  [[ "$h_status" -eq 0 ]]
  [[ "$h_out" == *"Commands:"* ]]
}

# --- leaf help via dispatcher and direct invocation -------------------------

@test "every leaf prints its §I Usage signature on -h and --help" {
  local leaf words tok expected
  while IFS= read -r leaf; do
    words="$(tr '/' ' ' <<< "$leaf")"
    expected=""
    if [[ -f "$TOOLKIT_ROOT/SPEC.md" ]]; then
      expected="Usage: $(_spec_sig_for "$leaf")"
      if [[ -z "$expected" || "$expected" == "Usage: " ]]; then
        echo "FAIL $leaf: no §I signature row" >&2
        return 1
      fi
    fi
    for tok in -h --help; do
      _help git shadow $words $tok
      _assert_usage "dispatcher $leaf $tok" || return 1
      if [[ -n "$expected" && "$h_out" != "$expected" ]]; then
        echo "FAIL $leaf $tok: expected '$expected', got '$h_out'" >&2
        return 1
      fi
      _help bash "$TOOLKIT_ROOT/commands/$leaf.sh" $tok
      _assert_usage "direct $leaf $tok" || return 1
      if [[ -n "$expected" && "$h_out" != "$expected" ]]; then
        echo "FAIL direct $leaf $tok: expected '$expected', got '$h_out'" >&2
        return 1
      fi
    done
  done < <(_leaf_paths)
}

@test "every leaf help resolves before any git invocation" {
  # Direct binary: GIT_TRACE catches any git run by the leaf itself
  # (through-git dispatch would trace git's own exec, not the leaf).
  local leaf
  while IFS= read -r leaf; do
    h_err_file="$(mktemp "$TEST_DIR/err.XXXXXX")"
    GIT_TRACE=1 "$TOOLKIT_ROOT/bin/git-shadow" $leaf --help </dev/null > /dev/null 2>"$h_err_file"
    if [[ -s "$h_err_file" ]]; then
      echo "FAIL $leaf: git trace output under --help: $(head -3 "$h_err_file")" >&2
      return 1
    fi
  done < <(_leaf_paths)
}

# --- group help -------------------------------------------------------------

@test "every group help form lists one Usage line per leaf" {
  local grp tok leaf lines
  for grpdir in "$TOOLKIT_ROOT"/commands/*/; do
    grp="$(basename "$grpdir")"
    for tok in help -h --help; do
      _help git shadow "$grp" "$tok"
      if [[ "$h_status" -ne 0 ]]; then
        echo "FAIL $grp $tok: exit $h_status" >&2
        return 1
      fi
      if [[ -s "$h_err_file" ]]; then
        echo "FAIL $grp $tok: stderr not empty" >&2
        return 1
      fi
      # every output line is a Usage line for this group
      while IFS= read -r lines; do
        if [[ "$lines" != "Usage: git shadow $grp "* ]]; then
          echo "FAIL $grp $tok: non-Usage line: $lines" >&2
          return 1
        fi
      done <<< "$h_out"
      # one Usage line per leaf file in the group
      local count=0
      for leaf in "$grpdir"*.sh; do count=$((count + 1)); done
      local got
      got="$(grep -c '^Usage:' <<< "$h_out")"
      if [[ "$got" -ne "$count" ]]; then
        echo "FAIL $grp $tok: $got Usage lines, expected $count" >&2
        return 1
      fi
    done
  done
}

# --- errors -----------------------------------------------------------------

@test "unknown command exits 1 and points at git shadow help" {
  local out
  out="$(git shadow bogus </dev/null 2>&1)" || true
  [[ "$out" == *"git shadow help"* ]]
  run git shadow bogus
  [ "$status" -eq 1 ]
}

@test "unknown command wins over a later leaf --help" {
  run git shadow bogus --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"git shadow help"* ]]
}

@test "unknown subcommand wins over a later leaf --help" {
  run git shadow feature bogus --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"git shadow help"* ]]
}

@test "bare group is a missing-subcommand error pointing at group --help" {
  local grp
  for grpdir in "$TOOLKIT_ROOT"/commands/*/; do
    grp="$(basename "$grpdir")"
    run git shadow "$grp"
    if [[ "$status" -ne 1 ]]; then
      echo "FAIL bare $grp: exit $status" >&2
      return 1
    fi
    if [[ "$output" != *"git shadow $grp --help"* ]]; then
      echo "FAIL bare $grp: output lacks 'git shadow $grp --help': $output" >&2
      return 1
    fi
  done
}

# --- literal help is leaf data ----------------------------------------------

@test "literal help is not a leaf help token" {
  local out st
  out="$(git shadow commit help </dev/null 2>&1)" && st=0 || st=$?
  if [[ "$st" -eq 0 || "$out" == "Usage: git shadow commit"* ]]; then
    echo "FAIL: 'commit help' treated as help request" >&2
    return 1
  fi
  out="$(git shadow push help </dev/null 2>&1)" && st=0 || st=$?
  if [[ "$st" -eq 0 && "$out" == "Usage: git shadow push"* ]]; then
    echo "FAIL: 'push help' treated as help request" >&2
    return 1
  fi
}

# --- -h|--help consumed as option values stays data --------------------------

@test "help tokens consumed as option values do not trigger help" {
  local st
  # -m / --message take a value: `commit -m --help` means message "--help".
  git shadow commit -m --help </dev/null > /dev/null 2>&1 && st=0 || st=$?
  if [[ "$st" -eq 0 ]]; then
    echo "FAIL: 'commit -m --help' exited 0" >&2
    return 1
  fi
  git shadow commit --message --help </dev/null > /dev/null 2>&1 && st=0 || st=$?
  if [[ "$st" -eq 0 ]]; then
    echo "FAIL: 'commit --message --help' exited 0" >&2
    return 1
  fi
  # --worktree-dir takes a path: `start --worktree-dir --help` uses it as path.
  git shadow feature start --worktree-dir --help </dev/null > /dev/null 2>&1 && st=0 || st=$?
  if [[ "$st" -eq 0 ]]; then
    echo "FAIL: 'feature start --worktree-dir --help' exited 0" >&2
    return 1
  fi
  # --mark-applied takes a sha.
  git shadow feature finish --mark-applied --help </dev/null > /dev/null 2>&1 && st=0 || st=$?
  if [[ "$st" -eq 0 ]]; then
    echo "FAIL: 'feature finish --mark-applied --help' exited 0" >&2
    return 1
  fi
}

@test "ignored surplus operands do not suppress a later help token" {
  _help git shadow push no-such-branch --help
  _assert_usage "push <branch> --help" || return 1
  _help git shadow local add some/path --help
  _assert_usage "local add <path> --help" || return 1
  _help git shadow show --with-annotations file.txt --help
  _assert_usage "show --with-annotations <file> --help" || return 1
}

# --- environment independence ------------------------------------------------

@test "help works outside a git repository" {
  cd "$TEST_DIR"
  local leaf words
  while IFS= read -r leaf; do
    words="$(tr '/' ' ' <<< "$leaf")"
    _help git shadow $words --help
    _assert_usage "outside-repo $leaf" || return 1
  done < <(_leaf_paths)
  _help git shadow help
  [[ "$h_status" -eq 0 ]]
}

@test "help works on a detached HEAD" {
  git checkout -q "$(git rev-parse HEAD)"
  local leaf words
  while IFS= read -r leaf; do
    words="$(tr '/' ' ' <<< "$leaf")"
    _help git shadow $words --help
    _assert_usage "detached $leaf" || return 1
  done < <(_leaf_paths)
}

@test "help works while a git-shadow sync is paused" {
  touch .git/git-shadow-sync
  local leaf words
  while IFS= read -r leaf; do
    words="$(tr '/' ' ' <<< "$leaf")"
    _help git shadow $words --help
    _assert_usage "sync-state $leaf" || return 1
  done < <(_leaf_paths)
}

@test "help works while a feature finish is paused" {
  touch .git/git-shadow-finish
  local leaf words
  while IFS= read -r leaf; do
    words="$(tr '/' ' ' <<< "$leaf")"
    _help git shadow $words --help
    _assert_usage "finish-state $leaf" || return 1
  done < <(_leaf_paths)
}

@test "help works during native merge, cherry-pick, and rebase states" {
  local leaf words
  for guard in MERGE_HEAD CHERRY_PICK_HEAD; do
    touch ".git/$guard"
    while IFS= read -r leaf; do
      words="$(tr '/' ' ' <<< "$leaf")"
      _help git shadow $words --help
      _assert_usage "$guard $leaf" || return 1
    done < <(_leaf_paths)
    rm -f ".git/$guard"
  done
  for guard in rebase-merge rebase-apply; do
    mkdir -p ".git/$guard"
    while IFS= read -r leaf; do
      words="$(tr '/' ' ' <<< "$leaf")"
      _help git shadow $words --help
      _assert_usage "$guard $leaf" || return 1
    done < <(_leaf_paths)
    rm -rf ".git/$guard"
  done
}

@test "help resolves before user config is loaded" {
  mkdir -p "$XDG_CONFIG_HOME/git-shadow"
  printf 'exit 42\n' > "$XDG_CONFIG_HOME/git-shadow/config.env"
  _help git shadow commit --help
  _assert_usage "malformed user config" || return 1
}

@test "help resolves before project config is loaded" {
  printf 'exit 42\n' > .git-shadow.env
  _help git shadow commit --help
  _assert_usage "malformed project config" || return 1
}

@test "help does not prompt on config leaves" {
  _help git shadow config set --help
  _assert_usage "config set --help" || return 1
  _help git shadow config unset --help
  _assert_usage "config unset --help" || return 1
}

# --- no side effects ---------------------------------------------------------

_repo_snapshot() {
  {
    git rev-parse HEAD
    git for-each-ref
    git status --porcelain
    find .git/hooks -type f | sort
    find "$HOME_DIR" -type f | sort
    find . -name '.git-shadow*' -o -name 'git-shadow-*' | sort
    find .git -name 'FETCH_HEAD' -o -name 'ORIG_HEAD'
  } 2>/dev/null
}

@test "help on mutating leaves changes nothing" {
  local before after leaf words
  local mutating="commit install-hooks completion/install local/add local/rm local/apply local/diff annotations/reapply config/set config/unset feature/start feature/publish feature/finish feature/sync base/sync push re-anchor check/public doctor status version show feature/list config/list config/show config/get"
  for leaf in $mutating; do
    before="$(_repo_snapshot)"
    words="$(tr '/' ' ' <<< "$leaf")"
    _help git shadow $words --help
    _assert_usage "no-mutation $leaf" || return 1
    after="$(_repo_snapshot)"
    if [[ "$before" != "$after" ]]; then
      echo "FAIL $leaf: repository/HOME state changed under --help" >&2
      diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
      return 1
    fi
  done
}

# --- version aliases ---------------------------------------------------------

@test "--version and -V print the version and forward argv" {
  local expected
  expected="$(cat "$TOOLKIT_ROOT/VERSION")"
  [[ "$(git shadow --version </dev/null)" == "$expected" ]]
  [[ "$(git shadow -V </dev/null)" == "$expected" ]]
  _help git shadow --version --help
  _assert_usage "--version --help" || return 1
  _help git shadow -V --help
  _assert_usage "-V --help" || return 1
  _help git shadow version --help
  _assert_usage "version --help" || return 1
}

# --- reserved filenames ------------------------------------------------------

@test "reserved help/alias leaf filenames are absent" {
  local f grpdir
  for f in help -h --help -V --version; do
    if [[ -e "$TOOLKIT_ROOT/commands/$f.sh" ]]; then
      echo "FAIL: reserved leaf commands/$f.sh exists" >&2
      return 1
    fi
  done
  for grpdir in "$TOOLKIT_ROOT"/commands/*/; do
    for f in help -h --help; do
      if [[ -e "$grpdir$f.sh" ]]; then
        echo "FAIL: reserved leaf $grpdir$f.sh exists" >&2
        return 1
      fi
    done
  done
}

# --- staged package tree ------------------------------------------------------

@test "help works in a staged package tree without SPEC.md" {
  local pkg="$TEST_DIR/pkg"
  mkdir -p "$pkg"
  cp -r "$TOOLKIT_ROOT/bin" "$TOOLKIT_ROOT/commands" "$TOOLKIT_ROOT/config" \
        "$TOOLKIT_ROOT/lib" "$TOOLKIT_ROOT/VERSION" "$pkg/"
  cd "$TEST_DIR"
  _help "$pkg/bin/git-shadow" --help
  [[ "$h_status" -eq 0 ]]
  [[ "$h_out" == *"Commands:"* ]]
  _help "$pkg/bin/git-shadow" commit --help
  _assert_usage "package commit --help" || return 1
  _help "$pkg/bin/git-shadow" feature --help
  [[ "$h_status" -eq 0 ]]
  [[ "$h_out" == "Usage: git shadow feature "* ]]
}
