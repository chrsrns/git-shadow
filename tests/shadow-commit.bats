#!/usr/bin/env bats

# Integration tests for git shadow commit.

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
  # Ensure tests use the toolkit under test.
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR" "$XDG_DIR"
}

@test "commit: requires a @local branch" {
  git checkout -q -b my-feature
  run git shadow commit -m "test"
  [ "$status" -ne 0 ]
  [[ "$output" == *"@local"* ]]
}

@test "commit: requires staged changes" {
  git shadow feature start my-feature
  run git shadow commit -m "test"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No staged changes"* ]]
}

@test "commit: rejects a public message matching [MEMORY]" {
  git shadow feature start my-feature
  echo "/// note" > file.txt
  git add file.txt
  run git shadow commit -m "[MEMORY] test"
  [ "$status" -ne 0 ]
}

@test "commit: creates clean public commit and [MEMORY] sidecar" {
  git shadow feature start my-feature
  printf 'public before\n/// local note\npublic after\n' > file.txt
  git add file.txt
  run git shadow commit -m "add note"
  [ "$status" -eq 0 ]

  # Public tree has no marker.
  run git show HEAD~1:file.txt
  [[ "$output" == *"public before"* ]]
  [[ "$output" != *"/// local note"* ]]

  # Memory tree has the sidecar and the marker-inside source.
  run git show HEAD:.git-shadow/annotations/file.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"## hunk"* ]]

  # Working tree is clean.
  git diff --quiet
}

@test "commit: keeps /// markers in LOCAL_COMMENT_EXCLUDE files" {
  git shadow feature start my-feature
  printf '/// csdoc\npublic code\n' > "app.cs"
  git add app.cs
  run git shadow commit -m "add cs file"
  [ "$status" -eq 0 ]

  # Public commit (HEAD because there was no [MEMORY] sidecar) keeps the /// marker.
  run git show HEAD:app.cs
  [[ "$output" == *"/// csdoc"* ]]

  # No annotation sidecar for /// in the excluded file.
  [ ! -f .git-shadow/annotations/app.cs ]
}

@test "commit: extracts // @local markers even in LOCAL_COMMENT_EXCLUDE files" {
  git shadow feature start my-feature
  printf '/// csdoc\n// @local local-only\npublic code\n' > "app.cs"
  git add app.cs
  run git shadow commit -m "add cs file with local"
  [ "$status" -eq 0 ]

  # Public commit keeps ///, drops @local.
  run git show HEAD~1:app.cs
  [[ "$output" == *"/// csdoc"* ]]
  [[ "$output" != *"// @local"* ]]

  # Annotation sidecar records the @local marker.
  [ -f .git-shadow/annotations/app.cs ]
}

@test "commit: preserves unstaged non-marker changes in public-tracked files" {
  git shadow feature start my-feature
  printf 'public before\n/// local note\npublic after\n' > file.txt
  git add file.txt
  printf 'public before\n/// local note\npublic after\nunstaged change\n' > file.txt
  run git shadow commit -m "add note"
  [ "$status" -eq 0 ]

  # Public tree has no marker and no unstaged change.
  run git show HEAD~1:file.txt
  [[ "$output" == *"public before"* ]]
  [[ "$output" == *"public after"* ]]
  [[ "$output" != *"/// local note"* ]]
  [[ "$output" != *"unstaged change"* ]]

  # Working tree has the clean content plus the unstaged change.
  run cat file.txt
  [[ "$output" == *"public before"* ]]
  [[ "$output" == *"public after"* ]]
  [[ "$output" == *"unstaged change"* ]]
  [[ "$output" != *"/// local note"* ]]
}

@test "commit: [MEMORY] sidecar bypasses pre-commit hook" {
  git shadow feature start my-feature
  run git shadow install-hooks
  [ "$status" -eq 0 ]
  [ -f .git/hooks/pre-commit ]

  printf 'public before\n/// local note\npublic after\n' > file.txt
  git add file.txt
  run git shadow commit -m "add note"
  [ "$status" -eq 0 ]
}

@test "commit: marker-only public file is removed from public tree and stored in [MEMORY]" {
  git shadow feature start my-feature
  printf '/// only markers\n// @local too\n' > file.txt
  git add file.txt
  run git shadow commit -m "marker only"
  [ "$status" -eq 0 ]

  # Public commit deleted the file.
  run git show "HEAD~1:file.txt"
  [ "$status" -ne 0 ]

  # [MEMORY] commit has the marker content.
  run git show "HEAD:file.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/// only markers"* ]]
  [[ "$output" == *"// @local too"* ]]
}

@test "commit: aborts on staged conflict markers" {
  git shadow feature start my-feature
  printf 'public before\n<<<<<<< HEAD\nconflict\n=======\nother\n>>>>>>> branch\npublic after\n' > file.txt
  git add file.txt
  run git shadow commit -m "conflict"
  [ "$status" -ne 0 ]
  [[ "$output" == *"conflict marker"* ]]
}

@test "commit: staged sidecar is merged by hunk key with the committed one" {
  git shadow feature start my-feature
  printf 'aaa\n/// note one\nbbb\nccc\n/// note two\nddd\n' > file.txt
  git add file.txt
  run git shadow commit -m "add notes"
  [ "$status" -eq 0 ]

  # Drop the second hunk from the sidecar and edit the first hunk's marker,
  # then stage only the sidecar.
  awk '/^## hunk / { h++ } h >= 2 { next } { print }' \
    .git-shadow/annotations/file.txt | sed 's/note one/edited note/' \
    > "$TEST_DIR/edited.md"
  cp "$TEST_DIR/edited.md" .git-shadow/annotations/file.txt
  git add -f .git-shadow/annotations/file.txt
  run git shadow commit -m "update sidecar"
  [ "$status" -eq 0 ]

  # The committed sidecar must still contain both hunks: the dropped record is
  # merged back from the committed version, and the staged edit to the first
  # hunk wins.
  run git show "HEAD:.git-shadow/annotations/file.txt"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c '## hunk')" -eq 2 ]
  [[ "$output" == *"edited note"* ]]
  [[ "$output" == *"note two"* ]]
}

@test "commit: LOCAL_COMMENT_EXCLUDE and binary files are public-tracked" {
  git shadow feature start my-feature
  # foo.cs matches the default LOCAL_COMMENT_EXCLUDE; /// is a doc marker.
  printf '/// <summary>doc</summary>\npublic class X {}\n' > foo.cs
  # bin.dat contains NUL bytes → binary, cannot be scanned for markers.
  printf 'PK\x03\x04\x00\x00' > bin.dat
  # file.txt carries a /// marker so a [MEMORY] commit is also created.
  printf 'pub\n/// note\n' > file.txt
  git add foo.cs bin.dat file.txt
  run git shadow commit -m "add files"
  [ "$status" -eq 0 ]

  # Exclusion only affects /// scanning; the file is still public-tracked and
  # lands in the public commit (parent of the [MEMORY] sidecar commit) with
  # its /// doc comments intact.
  run git show "HEAD~1:foo.cs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"public class X"* ]]
  [[ "$output" == *"/// <summary>"* ]]

  # Binary files are public-tracked too; they publish unchanged.
  run git show "HEAD~1:bin.dat"
  [ "$status" -eq 0 ]
}

@test "commit: keeps /// markers in deeply nested .git-shadow/ paths" {
  git shadow feature start my-feature
  mkdir -p .git-shadow/config.d/nested
  printf '/// nested note\npublic config\n' > .git-shadow/config.d/nested/example.md
  git add .git-shadow/config.d/nested/example.md
  run git shadow commit -m "add config"
  [ "$status" -eq 0 ]

  # Public commit keeps the /// marker.
  run git show HEAD:.git-shadow/config.d/nested/example.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"/// nested note"* ]]

  # No annotation sidecar for the excluded path.
  [ ! -f .git-shadow/annotations/.git-shadow/config.d/nested/example.md ]
}
