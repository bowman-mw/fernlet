#!/bin/bash
#
# macos-build-selftest.sh — prove Scripts/macos-build-check.sh is LOAD-BEARING: that it really builds
# the Mac-ready set for native macOS, not merely that it exits 0 (plan step A0.6, Mac readiness). It
# plants a throwaway file holding `import UIKit` inside FernletFoundation, one of the three modules the
# check's `MacReady` product names (ProximityPlatformBoundaryTests pins the other two beside it),
# runs the check, and asserts it FAILS on that import: native macOS has no UIKit, so only a native
# macOS build can fail there, while an iOS build, a Mac Catalyst build (Catalyst has UIKit), a build of
# the wrong scheme or a build of nothing would pass it. It then removes the probe and asserts the clean
# tree passes. The probe is ALWAYS cleaned up (trap), even on Ctrl-C.
#
# THE FAILURE TEXT: with explicit modules (Xcode 26's default), xcodebuild's dependency scan reports a
# module the platform does not have as "error: unable to resolve module dependency: 'UIKit'" (some
# lines capitalise "Unable"), with the note "a dependency of main module 'FernletFoundation'". The compiler's
# "no such module 'UIKit'" is what the SwiftPM command line prints, and xcodebuild never does, so the
# assertion matches the scanner's wording, case-insensitively.
#
# CI runs this on every push (.github/workflows/s3-wall.yml, the "The Mac-ready set on native macOS" step);
# Tests/FernletTests/ProximityPlatformBoundaryTests pins that the step's body runs it and that both legs
# below are lines that run. Run it after any change to the macOS check, its scheme or its destination.
#
# USAGE:  Scripts/macos-build-selftest.sh
#         FERNLET_MACOS_DERIVED_DATA=/path/to/derived-data Scripts/macos-build-selftest.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 99

PROBE="FernletKit/Sources/FernletFoundation/__MacOSBuildSelfTestProbe.swift"
cleanup() { rm -f "$PROBE"; }
trap cleanup EXIT

echo "==> macOS build self-test (NEGATIVE): planting \`import UIKit\` into FernletFoundation"
cat > "$PROBE" <<'SWIFT'
// TEMPORARY probe written by Scripts/macos-build-selftest.sh. Must never be committed.
// Native macOS has no UIKit, so a macOS build of FernletFoundation must fail on this line; an iOS or
// Mac Catalyst build, or a build of nothing, would pass it.
import UIKit
SWIFT

OUT="$(Scripts/macos-build-check.sh 2>&1)"
CODE=$?
echo "$OUT" | tail -6

if [ "$CODE" -eq 0 ]; then
  echo
  echo "MACOS SELF-TEST FAILED: the check built FernletFoundation with \`import UIKit\` (build passed)."
  echo "It is not a native macOS build: check its scheme and its -destination."
  exit 1
fi
# grep without -q reads all of the output, so printf never writes into a closed pipe.
UNRESOLVED="$(printf '%s\n' "$OUT" | grep -i "unable to resolve module dependency: 'UIKit'")"
if [ -z "$UNRESOLVED" ]; then
  echo
  echo "MACOS SELF-TEST INCONCLUSIVE: the build failed (exit $CODE) but not on the probe's UIKit import."
  echo "The failure may be unrelated to the platform. Inspect the output above."
  exit 1
fi
echo
printf '%s\n' "$UNRESOLVED" | sed -n '1p'
echo "MACOS SELF-TEST PASSED (negative): the planted UIKit import failed the macOS build (exit $CODE)."

# Remove the probe and confirm the clean tree builds green for native macOS.
cleanup
trap - EXIT
echo
echo "==> macOS build self-test (POSITIVE): re-running the check on the clean tree (expect pass)"
Scripts/macos-build-check.sh
CLEAN=$?
if [ "$CLEAN" -ne 0 ]; then
  echo "MACOS SELF-TEST FAILED: the clean tree did not pass the macOS build check (exit $CLEAN)."
  exit "$CLEAN"
fi
echo
echo "MACOS BUILD SELF-TEST PASSED — the check is a native macOS build and the clean tree passes it."
