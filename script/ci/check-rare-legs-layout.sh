#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
forge build >/dev/null 2>&1 || { echo "FAIL: forge build failed"; exit 1; }
norm() { forge inspect "$1" storage-layout --json 2>/tmp/inspect.err | python3 script/ci/layout_norm.py 2>/dev/null || { echo "FAIL: forge inspect $1:"; cat /tmp/inspect.err; exit 1; }; }
A=$(norm src/pol/POLHolder.sol:POLHolder); B=$(norm src/pol/POLHolderRareLegs.sol:POLHolderRareLegs)
N=$(printf "%s\n" "$A" | grep -c . || true)
if [ "$N" -lt 10 ]; then echo "FAIL: could not read POLHolder layout (got $N slots) — refusing to pass vacuously"; exit 1; fi
if [ "$A" == "$B" ]; then
  echo "OK: POLHolderRareLegs storage layout matches POLHolder ($N slots)"
else
  echo "FAIL: POLHolderRareLegs storage layout has drifted from POLHolder:"
  diff <(printf "%s\n" "$A") <(printf "%s\n" "$B") || true; exit 1
fi
