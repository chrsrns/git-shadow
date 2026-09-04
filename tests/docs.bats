#!/usr/bin/env bats

# Documentation drift tests.

@test "troubleshooting docs describe the in-source marker workflow" {
  TOOLKIT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  file="$TOOLKIT_ROOT/docs/troubleshooting.md"
  [ -f "$file" ]

  # The stale note that denies the in-source marker workflow is gone.
  run grep -F "Local-only content belongs in separate files and is committed manually as \`[MEMORY]\`." "$file"
  [ "$status" -ne 0 ]

  # The in-source marker workflow is referenced.
  run grep -F "Use \`///\` or \`// @local\` markers" "$file"
  [ "$status" -eq 0 ]
}
