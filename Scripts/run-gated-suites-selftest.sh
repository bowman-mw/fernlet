#!/bin/bash
#
# run-gated-suites-selftest.sh — prove the restart guard in Scripts/run-gated-suites.sh is
# LOAD-BEARING on its LIVE branch, not merely at its `--check-log` seam.
#
# Why this exists: a restart RE-RUNS suites, so the result bundle's `totalTestCount` counts some
# cells twice and every floor above it stops proving anything (P9 item 6's fix review, NOTE-4;
# thirteen of the mesh step's suites rest on that floor alone). The guard shipped with a
# `--check-log <file>` seam so it could be shown red with no Mac — but the seam is a SECOND code
# path, and nothing had ever executed the live branch's `tee` -> `grep -qF "$RESTART_MARKER"
# "$RUN_LOG"`. A refactor that dropped the `tee`, renamed `$RUN_LOG` or moved the grep above the
# redirect would have left the seam green and the gate blind. This runs the REAL script, on its
# REAL branch, with `xcodebuild` and `xcrun` stubbed on PATH, and asserts the exit code.
#
# It needs no Simulator, no build and no Xcode: the stubs are what the script reads.
#   * `xcodebuild` prints a normal-looking green run — including "TEST EXECUTE SUCCEEDED" — and
#     CREATES the directory named by `-resultBundlePath`, because the gate refuses a missing bundle
#     before it ever reaches the floor. It exits 0: a run that looks green is the whole point.
#   * `xcrun` answers `xcresulttool get test-results summary --path <bundle> --compact` with a
#     passing summary whose `totalTestCount` is ABOVE the floor, so the ONLY thing left that can
#     fail the gate is the restart line. A stub that under-counted would pass this self-test for
#     the wrong reason, which is why assertion 2 runs the same stubs with the marker removed and
#     requires exit 0. Any other `xcrun` call is a loud refusal rather than a silent `{}`.
#
# Four assertions, in the order that makes each one mean something:
#   1. LIVE NEGATIVE  — marker in the run output           -> the gate must exit non-zero
#   2. LIVE POSITIVE  — same stubs, marker removed         -> the gate must exit 0
#   3. SEAM NEGATIVE  — --check-log over a log with it     -> non-zero
#   4. SEAM POSITIVE  — --check-log over a log without it  -> 0
# 1 without 2 would pass on any broken stub; 3 and 4 are cheap and keep both paths in one place.
#
# Every step is a fixed, bounded command — there is no loop here to run away.
#
# USAGE:  Scripts/run-gated-suites-selftest.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MARKER='Restarting after unexpected exit, crash, or test timeout'
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/bin" "$WORK/results"

# The xcodebuild stub. `$FERNLET_SELFTEST_MARKER` decides whether this run "restarted"; everything
# else about the output is deliberately the shape of a healthy green run.
cat > "$WORK/bin/xcodebuild" <<'STUB'
#!/bin/bash
bundle=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-resultBundlePath" ]; then bundle="$arg"; fi
  prev="$arg"
done
echo "Test Suite 'All tests' started"
if [ -n "${FERNLET_SELFTEST_MARKER:-}" ]; then echo "$FERNLET_SELFTEST_MARKER"; fi
echo "Test run with 999 tests in 9 suites passed after 1.000 seconds"
echo "** TEST EXECUTE SUCCEEDED **"
[ -n "$bundle" ] && mkdir -p "$bundle"
exit 0
STUB

# The xcrun stub. Only `xcresulttool get test-results summary` is ever asked for.
cat > "$WORK/bin/xcrun" <<'STUB'
#!/bin/bash
case "$*" in
  *"xcresulttool get test-results summary"*)
    echo '{"totalTestCount":999,"failedTests":0,"skippedTests":0,"result":"Passed"}' ;;
  *)
    echo "run-gated-suites-selftest: unstubbed xcrun call: $*" >&2; exit 97 ;;
esac
STUB

chmod +x "$WORK/bin/xcodebuild" "$WORK/bin/xcrun"

# The stubs must be what actually runs, or every assertion below is about the real toolchain.
if [ "$(PATH="$WORK/bin:$PATH" command -v xcodebuild)" != "$WORK/bin/xcodebuild" ]; then
  echo "SELF-TEST INCONCLUSIVE: the xcodebuild stub is not first on PATH; nothing below is about the stub." >&2
  exit 1
fi

# $1 = the marker to plant (empty for none). Runs the LIVE branch and echoes its exit code.
# The `|| status=$?` is what keeps `set -e` from killing the subshell before the code is read.
run_gate() {
  local status=0
  env PATH="$WORK/bin:$PATH" \
      FERNLET_SELFTEST_MARKER="$1" \
      FERNLET_RESULT_DIR="$WORK/results" \
      FERNLET_DESTINATION='platform=iOS Simulator,name=SelfTestStub' \
      Scripts/run-gated-suites.sh selftest 1 S3BoundaryTests > "$WORK/gate.log" 2>&1 || status=$?
  echo "$status"
}

echo "==> 1/4 LIVE NEGATIVE: a run whose output carries the restart marker must NOT pass"
CODE="$(run_gate "$MARKER")"
if [ "$CODE" -eq 0 ]; then
  tail -12 "$WORK/gate.log"
  echo "SELF-TEST FAILED: the gate passed a run that RESTARTED. The live branch's marker check is"
  echo "dead — the floor it guards is inflated by re-run suites and proves nothing."
  exit 1
fi
if ! grep -q "RESTARTED the test run" "$WORK/gate.log"; then
  tail -12 "$WORK/gate.log"
  echo "SELF-TEST INCONCLUSIVE: the gate failed (exit $CODE) but not with the restart diagnostic."
  echo "The failure may be the stub's, not the guard's. Inspect the log above."
  exit 1
fi
echo "    exit $CODE, and the diagnostic names the restart."

echo "==> 2/4 LIVE POSITIVE: the same stubs with no marker must pass (or 1/4 proves nothing)"
CODE="$(run_gate "")"
if [ "$CODE" -ne 0 ]; then
  tail -12 "$WORK/gate.log"
  echo "SELF-TEST FAILED: the gate refused a clean stubbed run (exit $CODE), so the negative above"
  echo "says nothing about the marker — the stubs or the script's own preconditions are broken."
  exit 1
fi
echo "    exit 0."

echo "==> 3/4 SEAM NEGATIVE: --check-log over a log that records a restart"
printf 'Test Suite started\n%s\n** TEST EXECUTE SUCCEEDED **\n' "$MARKER" > "$WORK/with.log"
if Scripts/run-gated-suites.sh --check-log "$WORK/with.log" > "$WORK/seam.log" 2>&1; then
  cat "$WORK/seam.log"
  echo "SELF-TEST FAILED: --check-log passed a log that records a restart."
  exit 1
fi
echo "    exit non-zero."

echo "==> 4/4 SEAM POSITIVE: --check-log over a clean log"
printf 'Test Suite started\n** TEST EXECUTE SUCCEEDED **\n' > "$WORK/without.log"
if ! Scripts/run-gated-suites.sh --check-log "$WORK/without.log" > "$WORK/seam.log" 2>&1; then
  cat "$WORK/seam.log"
  echo "SELF-TEST FAILED: --check-log refused a clean log."
  exit 1
fi
echo "    exit 0."

echo
echo "RUN-GATED-SUITES SELF-TEST PASSED — the restart guard fires on the LIVE branch and at the"
echo "                                    seam, and neither refuses an honest run."
