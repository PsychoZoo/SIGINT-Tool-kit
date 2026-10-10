#!/usr/bin/env bats
# Checks on the repository itself.

@test "scripts that toolkit.sh runs directly are executable" {
  cd "$BATS_TEST_DIRNAME/.."
  for f in toolkit.sh scripts/setup.sh scripts/flash-node.sh; do
    [ -x "$f" ] || { echo "$f is not executable"; return 1; }
  done
}
