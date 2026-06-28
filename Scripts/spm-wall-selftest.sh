#!/bin/bash
#
# spm-wall-selftest.sh — prove the S3 wall is LOAD-BEARING, not merely that the build is green
# (WI-3, Docs/Security-Hardening-Plan-2026-06-27.md). It plants a forbidden `import PrivateHealthStore`
# in a throwaway file inside the walled AIProviders target, runs the wall check, and asserts it FAILS
# with the "is missing a dependency on" diagnostic (the compiler wall firing). It then removes the
# probe and asserts the clean tree passes. The probe is ALWAYS cleaned up (trap), even on Ctrl-C.
#
# This is the automated form of the §0 negative test in the plan. Run it after any change to the
# wall (Package.swift dependency DAG, the enforcement flag, or the walled modules).
#
# USAGE:  Scripts/spm-wall-selftest.sh
#         FERNLET_DESTINATION='platform=iOS Simulator,name=iPhone 17' Scripts/spm-wall-selftest.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 99

PROBE="FernletKit/Sources/AIProviders/__S3WallSelfTestProbe.swift"
cleanup() { rm -f "$PROBE"; }
trap cleanup EXIT

echo "==> S3 wall self-test (NEGATIVE): planting a forbidden import into the walled AIProviders target"
cat > "$PROBE" <<'SWIFT'
// TEMPORARY probe written by Scripts/spm-wall-selftest.sh. Must never be committed.
// A forbidden cross-wall import: the walled AIProviders module must not be able to name a sealed
// store. Under DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR this is a hard build error.
import PrivateHealthStore
SWIFT

OUT="$(Scripts/spm-wall-check.sh 2>&1)"
CODE=$?
echo "$OUT" | tail -6

if [ "$CODE" -eq 0 ]; then
  echo
  echo "SELF-TEST FAILED: the wall did NOT reject a forbidden import (build passed)."
  echo "The S3 wall is NOT load-bearing — check the enforcement flag and the AIProviders dependency list."
  exit 1
fi
if ! printf '%s\n' "$OUT" | grep -q "is missing a dependency on"; then
  echo
  echo "SELF-TEST INCONCLUSIVE: the build failed (exit $CODE) but NOT with 'is missing a dependency on'."
  echo "The failure may be unrelated to the wall. Inspect the output above."
  exit 1
fi
echo
echo "SELF-TEST PASSED (negative): the forbidden import was rejected by the compiler wall"
echo "                             (exit $CODE, 'is missing a dependency on')."

# Remove the probe and confirm the clean tree builds green under enforcement.
cleanup
trap - EXIT
echo
echo "==> S3 wall self-test (POSITIVE): re-running the wall check on the clean tree (expect pass)"
Scripts/spm-wall-check.sh
CLEAN=$?
if [ "$CLEAN" -ne 0 ]; then
  echo "SELF-TEST FAILED: the clean tree did not pass the wall check (exit $CLEAN)."
  exit "$CLEAN"
fi
echo
echo "S3 WALL SELF-TEST PASSED — the wall rejects forbidden imports and the clean tree is honest."
