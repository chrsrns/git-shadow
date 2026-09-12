#!/usr/bin/env bats

# End-to-end test of the sidecar migration path for master@local that has
# [MEMORY] commits modifying public-tracked files.  Simulates the scenario
# described in the review, then verifies that:
#   1. the broken state blocks feature publish,
#   2. reverting the source to master + reapplying via git shadow local add
#      makes master@local clean,
#   3. a new feature branch inherits the sidecars and can publish cleanly.

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"

  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PATH="$TOOLKIT_ROOT/bin:$PATH"

  git init -q
  git config user.name "Migration Test"
  git config user.email "test@example.com"
  git symbolic-ref HEAD refs/heads/master

  mkdir -p apps/api

  # Local-only paths must be ignored so they never count as untracked dirt.
  printf '%s\n' ".git-shadow/annotations/" ".git-shadow/patches/" ".git-shadow.env" > .gitignore

  cat > docker-compose.yml <<'EOF'
services:
  db:
    image: postgres
    ports:
      - "5432:5432"
EOF

  cat > package.json <<'EOF'
{
  "name": "app",
  "scripts": {
    "dev": "npm run db:start && npm run app",
    "db:start": "...",
    "sync": "...",
    "check:country-names": "..."
  }
}
EOF

  cat > apps/api/jest.config.ts <<'EOF'
export default {
  testEnvironment: "node",
};
EOF

  git add .
  git commit -qm "initial public commit"

  # Simulate the existing master@local with [MEMORY] commits that baked
  # local-only tweaks into public-tracked files.
  git checkout -q -b master@local

  cat > docker-compose.yml <<'EOF'
services:
  db:
    image: postgres
    ports:
      - "6543:5432"
EOF

  cat > package.json <<'EOF'
{
  "name": "app",
  "scripts": {
    "dev": "npm run app"
  }
}
EOF

  cat > apps/api/jest.config.ts <<'EOF'
export default {
  testEnvironment: "node",
  maxWorkers: 4,
  workerIdleMemoryLimit: "512MB"
};
EOF

  git add -A
  git commit -qm "[MEMORY] local docker and test tweaks"

  # Create the first checkpoint, matching the user's "base sync already run" state.
  run git shadow base sync
  [ "$status" -eq 0 ]
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "sidecar migration fixes master@local and new feature publish" {
  # master@local should be diverged because the [MEMORY] commits touched
  # public-tracked source files.
  run git shadow status
  [ "$status" -eq 0 ]
  [[ "$output" =~ diverged[[:space:]]+:[[:space:]]*true ]]

  # Before the fix, even a trivial feature cannot publish because the
  # feature/x@local tree carries the baked-in source modifications.
  run git shadow feature start broken
  [ "$status" -eq 0 ]

  echo "new feature work" > new-file.txt
  git add new-file.txt
  git commit -qm "feat: add new file"

  run git shadow feature publish
  [ "$status" -ne 0 ]

  # Discard the broken feature.
  git checkout -q master@local
  git branch -D broken broken@local

  # Migrate on master@local:
  # 1. revert the 3 files to exactly what master (public) has,
  # 2. reapply the intended local tweaks to the working tree,
  # 3. capture each as a .git-shadow/patches sidecar.
  git checkout master -- docker-compose.yml package.json apps/api/jest.config.ts
  git add -A
  git commit -qm "revert local tweaks to master"

  cat > docker-compose.yml <<'EOF'
services:
  db:
    image: postgres
    ports:
      - "6543:5432"
EOF

  cat > package.json <<'EOF'
{
  "name": "app",
  "scripts": {
    "dev": "npm run app"
  }
}
EOF

  cat > apps/api/jest.config.ts <<'EOF'
export default {
  testEnvironment: "node",
  maxWorkers: 4,
  workerIdleMemoryLimit: "512MB"
};
EOF

  run git shadow local add docker-compose.yml
  [ "$status" -eq 0 ]
  run git shadow local add package.json
  [ "$status" -eq 0 ]
  run git shadow local add apps/api/jest.config.ts
  [ "$status" -eq 0 ]

  [ -f .git-shadow/patches/docker-compose.yml.patch ]
  [ -f .git-shadow/patches/package.json.patch ]
  [ -f .git-shadow/patches/apps/api/jest.config.ts.patch ]

  # Refresh the checkpoint now that the HEAD tree matches public again.
  run git shadow base sync
  [ "$status" -eq 0 ]

  run git shadow status
  [ "$status" -eq 0 ]
  [[ "$output" =~ diverged[[:space:]]+:[[:space:]]*false ]]

  run git shadow check public master
  [ "$status" -eq 0 ]
  [[ "$output" == *"No unpromoted files"* ]]

  # A new feature branch started from the fixed master@local should inherit
  # the sidecars and have the local tweaks applied in its working tree.
  run git shadow feature start fixed
  [ "$status" -eq 0 ]

  [ "$(git branch --show-current)" = "fixed@local" ]

  grep -q "6543:5432" docker-compose.yml
  grep -q '"dev": "npm run app"' package.json
  grep -q "maxWorkers: 4" apps/api/jest.config.ts

  # Add a public commit and publish it.  The sidecar must stay on fixed@local
  # and must not leak onto the public branch.
  echo "fixed feature" > fixed-file.txt
  git add fixed-file.txt
  git commit -qm "feat: fixed feature"

  run git shadow feature publish
  [ "$status" -eq 0 ]

  run git shadow status
  [ "$status" -eq 0 ]
  [[ "$output" =~ diverged[[:space:]]+:[[:space:]]*false ]]

  run git shadow check public fixed
  [ "$status" -eq 0 ]
  [[ "$output" == *"No unpromoted files"* ]]

  # The public branch has the new file and the original public source.
  [ -f fixed-file.txt ]
  ! git show fixed:docker-compose.yml | grep -q "6543:5432"
}
