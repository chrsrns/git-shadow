#!/usr/bin/env bats

setup() {
  REPO="$(mktemp -d)"
  cd "$REPO"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/main

  cat > .gitattributes <<'EOF'
SPEC.md merge=union
EOF
  git add .gitattributes
  git commit -qm "chore: gitattributes"

  cat > SPEC.md <<'EOF'
# Spec

## §T Tasks

| ID | Status | Description |
|----|--------|-------------|
| T1 | . | first |
| T2 | . | second |
EOF
  git add SPEC.md
  git commit -qm "spec: initial table"
}

teardown() {
  cd /
  rm -rf "$REPO"
}

@test "SPEC.md merge=union merges append-only rows without conflict" {
  git checkout -q -b left
  cat >> SPEC.md <<'EOF'
| T3 | . | left row |
EOF
  git add SPEC.md
  git commit -qm "spec: add left row"

  git checkout -q main
  git checkout -q -b right
  cat >> SPEC.md <<'EOF'
| T4 | . | right row |
EOF
  git add SPEC.md
  git commit -qm "spec: add right row"

  git checkout -q main
  git merge -q --no-edit left
  git merge -q --no-edit right

  grep -q "T3.*left row" SPEC.md
  grep -q "T4.*right row" SPEC.md
  ! grep -q '<<<<<<<' SPEC.md
  ! grep -q '>>>>>>>' SPEC.md
}
