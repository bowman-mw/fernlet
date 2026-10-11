#!/bin/bash
#
# run-gated-suites-selftest.sh — prove the restart guard and the suite census in
# Scripts/run-gated-suites.sh are LOAD-BEARING on the script's LIVE branch, not merely at its
# `--check-log` seam, and that it reads exactly the two selector shapes.
#
# Why this exists: a restart RE-RUNS suites, so the result bundle's `totalTestCount` counts some
# cells twice and every floor above it stops proving anything (P9 item 6's fix review, NOTE-4;
# thirteen of the mesh step's suites rest on that floor alone). The guard shipped with a
# `--check-log <file>` seam so it could be shown red with no Mac — but the seam is a SECOND code
# path, and nothing had ever executed the live branch's `tee` -> `grep -qF "$RESTART_MARKER"
# "$RUN_LOG"`. A refactor that dropped the `tee`, renamed `$RUN_LOG` or moved the grep above the
# redirect would have left the seam green and the gate blind. Since ProximityKit plan step A0.8 a
# line may also name a suite of ProximityKit's own package test target (`ProximityKitTests/<Suite>`),
# and a mixed line's total can hide a selector of the wrong target, so the runner reads the result
# bundle's tests tree and refuses a named suite that ran no test case: that census, the two selector
# shapes, the duplicate refusal and the workspace container are held here too. This runs the REAL
# script, on its REAL branch, with `xcodebuild` and `xcrun` stubbed on PATH, and asserts the exit
# code and the arguments the script passed.
#
# It needs no Simulator, no build and no Xcode: the stubs are what the script reads.
#   * `xcodebuild` prints a normal-looking green run — including "TEST EXECUTE SUCCEEDED" — and
#     CREATES the directory named by `-resultBundlePath`, because the gate refuses a missing bundle
#     before it ever reaches the floor. It APPENDS each argument it was given, one per line, to
#     `$FERNLET_SELFTEST_ARGS`, which `run_gate` truncates before every invocation (the runner
#     refuses a bad shape before it calls the stub, so a stub-side truncation would leave the
#     previous run's arguments in the log). It exits 0: a run that looks green is the whole point.
#   * `xcrun` answers `xcresulttool get test-results summary --path <bundle> --compact` with a
#     passing summary whose `totalTestCount` is ABOVE the floor, so the floor never decides an
#     assertion here, and `xcresulttool get test-results tests` with the tree in
#     `$FERNLET_SELFTEST_TREE`: `fernlet-only.json` (one FernletTests suite) or `both.json` (that
#     suite and one ProximityKitTests suite), in the shape measured on Xcode 26.5. A stub that
#     under-counted would pass this self-test for the wrong reason, which is why assertion 2 runs the
#     same stubs with the marker removed and requires exit 0. Any other `xcrun` call is a loud
#     refusal rather than a silent `{}`.
#
# Eight assertions, in the order that makes each one mean something:
#   1. LIVE NEGATIVE  — marker in the run output                    -> the gate must exit non-zero
#   2. LIVE POSITIVE  — same stubs, marker removed                  -> the gate must exit 0
#   3. TWO TARGETS    — a bare suite and ProximityKitTests/<Suite>,
#                       both in the tree                            -> 0, through the workspace,
#                                                                      each selector in its target
#   4. SUITE CENSUS   — the same selectors, the package suite
#                       absent from the tree                        -> non-zero, naming it
#   5. REFUSED SHAPES — FernletTests/<Suite>, another target, a
#                       second slash, an empty suite                -> exit 2 each, xcodebuild never runs
#   6. DUPLICATE      — one suite named twice                       -> exit 2, xcodebuild never runs
#   7. SEAM NEGATIVE  — --check-log over a log with the marker      -> non-zero
#   8. SEAM POSITIVE  — --check-log over a log without it           -> 0
# 1 without 2 would pass on any broken stub, and 4 without 3 on a census that refuses everything;
# 7 and 8 are cheap and keep both restart paths in one place.
#
# Every step is a fixed, bounded command; the one loop walks assertion 5's fixed four-item list.
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
  printf '%s\n' "$arg" >> "$FERNLET_SELFTEST_ARGS"
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

# The xcrun stub. Only the result bundle's summary and its tests tree are ever asked for.
cat > "$WORK/bin/xcrun" <<'STUB'
#!/bin/bash
case "$*" in
  *"xcresulttool get test-results summary"*)
    echo '{"totalTestCount":999,"failedTests":0,"skippedTests":0,"result":"Passed"}' ;;
  *"xcresulttool get test-results tests"*)
    cat "$FERNLET_SELFTEST_TREE" ;;
  *)
    echo "run-gated-suites-selftest: unstubbed xcrun call: $*" >&2; exit 97 ;;
esac
STUB

chmod +x "$WORK/bin/xcodebuild" "$WORK/bin/xcrun"

# The two tests trees, in the shape `xcresulttool get test-results tests --compact` gives on Xcode
# 26.5: a Test Suite node's nodeIdentifierURL is test://com.apple.xcode/<container>/<bundle>/<Type>.
cat > "$WORK/fernlet-only.json" <<'TREE'
{"testNodes":[{"nodeType":"Test Plan","name":"Fernlet","children":[
 {"nodeType":"Unit test bundle","name":"FernletTests","children":[
  {"nodeType":"Test Suite","name":"S3BoundaryTests","nodeIdentifierURL":"test://com.apple.xcode/Fernlet/FernletTests/S3BoundaryTests","children":[
   {"nodeType":"Test Case","name":"aCase()","result":"Passed"}]}]}]}]}
TREE
cat > "$WORK/both.json" <<'TREE'
{"testNodes":[{"nodeType":"Test Plan","name":"Fernlet","children":[
 {"nodeType":"Unit test bundle","name":"FernletTests","children":[
  {"nodeType":"Test Suite","name":"S3BoundaryTests","nodeIdentifierURL":"test://com.apple.xcode/Fernlet/FernletTests/S3BoundaryTests","children":[
   {"nodeType":"Test Case","name":"aCase()","result":"Passed"}]}]},
 {"nodeType":"Unit test bundle","name":"ProximityKitTests","children":[
  {"nodeType":"Test Suite","name":"PeerHandleIdentityTests","nodeIdentifierURL":"test://com.apple.xcode/FernletKit/ProximityKitTests/PeerHandleIdentityTests","children":[
   {"nodeType":"Test Case","name":"aCase()","result":"Passed"}]}]}]}]}
TREE

# The stubs must be what actually runs, or every assertion below is about the real toolchain.
if [ "$(PATH="$WORK/bin:$PATH" command -v xcodebuild)" != "$WORK/bin/xcodebuild" ]; then
  echo "SELF-TEST INCONCLUSIVE: the xcodebuild stub is not first on PATH; nothing below is about the stub." >&2
  exit 1
fi

# $1 = the marker to plant (empty for none), $2 = the tests tree, the rest = the selectors. Runs the
# LIVE branch and echoes its exit code. The arguments log is truncated FIRST, before every run, so a
# run the script refuses before it calls xcodebuild leaves it empty. The `|| status=$?` is what
# keeps `set -e` from killing the subshell before the code is read.
run_gate() {
  local status=0
  local marker="$1"
  local tree="$2"
  shift 2
  : > "$WORK/args.log"
  env PATH="$WORK/bin:$PATH" \
      FERNLET_SELFTEST_MARKER="$marker" \
      FERNLET_SELFTEST_TREE="$tree" \
      FERNLET_SELFTEST_ARGS="$WORK/args.log" \
      FERNLET_RESULT_DIR="$WORK/results" \
      FERNLET_DESTINATION='platform=iOS Simulator,name=SelfTestStub' \
      Scripts/run-gated-suites.sh selftest 1 "$@" > "$WORK/gate.log" 2>&1 || status=$?
  echo "$status"
}

# Whether the stub received $1 as one whole argument.
passed_arg() { grep -qxF -e "$1" "$WORK/args.log"; }

echo "==> 1/8 LIVE NEGATIVE: a run whose output carries the restart marker must NOT pass"
CODE="$(run_gate "$MARKER" "$WORK/fernlet-only.json" S3BoundaryTests)"
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

echo "==> 2/8 LIVE POSITIVE: the same stubs with no marker must pass (or 1/8 proves nothing)"
CODE="$(run_gate "" "$WORK/fernlet-only.json" S3BoundaryTests)"
if [ "$CODE" -ne 0 ]; then
  tail -12 "$WORK/gate.log"
  echo "SELF-TEST FAILED: the gate refused a clean stubbed run (exit $CODE), so the negative above"
  echo "says nothing about the marker — the stubs or the script's own preconditions are broken."
  exit 1
fi
echo "    exit 0."

echo "==> 3/8 TWO TARGETS: a bare suite and a ProximityKitTests/<Suite>, both in the tree, must pass"
CODE="$(run_gate "" "$WORK/both.json" S3BoundaryTests ProximityKitTests/PeerHandleIdentityTests)"
if [ "$CODE" -ne 0 ]; then
  tail -12 "$WORK/gate.log"
  echo "SELF-TEST FAILED: the gate refused a run in which both named suites ran (exit $CODE)."
  exit 1
fi
if ! passed_arg "-workspace" || ! passed_arg "Fernlet.xcworkspace" || passed_arg "-project" \
  || ! passed_arg "-only-testing:FernletTests/S3BoundaryTests" \
  || ! passed_arg "-only-testing:ProximityKitTests/PeerHandleIdentityTests"; then
  cat "$WORK/args.log"
  echo "SELF-TEST FAILED: the runner did not pass -workspace Fernlet.xcworkspace (and no -project) with"
  echo "each selector in its own target: -only-testing:FernletTests/S3BoundaryTests and"
  echo "-only-testing:ProximityKitTests/PeerHandleIdentityTests. The arguments it passed are above."
  exit 1
fi
echo "    exit 0, through Fernlet.xcworkspace, each selector in its own target."

echo "==> 4/8 SUITE CENSUS: the same selectors with the package suite absent from the tree must NOT pass"
CODE="$(run_gate "" "$WORK/fernlet-only.json" S3BoundaryTests ProximityKitTests/PeerHandleIdentityTests)"
if [ "$CODE" -eq 0 ]; then
  tail -12 "$WORK/gate.log"
  echo "SELF-TEST FAILED: the gate passed a run in which a named suite ran no test case. Its total"
  echo "cleared the floor, which is exactly how a selector of the wrong target hides on a mixed line."
  exit 1
fi
if ! grep -q "named but ran no test case" "$WORK/gate.log" \
  || ! grep -q "ProximityKitTests/PeerHandleIdentityTests" "$WORK/gate.log"; then
  tail -12 "$WORK/gate.log"
  echo "SELF-TEST INCONCLUSIVE: the gate failed (exit $CODE) but did not name"
  echo "ProximityKitTests/PeerHandleIdentityTests as a named suite that ran no test case."
  exit 1
fi
echo "    exit $CODE, and the census names the suite that ran nothing."

echo "==> 5/8 REFUSED SHAPES: every other selector shape exits 2 before xcodebuild runs"
# R2: bounded by the fixed four-item list.
for shape in FernletTests/S3BoundaryTests OtherTests/S3BoundaryTests ProximityKitTests/A/B ProximityKitTests/; do
  CODE="$(run_gate "" "$WORK/both.json" "$shape")"
  if [ "$CODE" -ne 2 ] || [ -s "$WORK/args.log" ]; then
    tail -6 "$WORK/gate.log"
    echo "SELF-TEST FAILED: '$shape' gave exit $CODE (expected 2), or xcodebuild ran. A selector is a"
    echo "FernletTests suite's bare name or ProximityKitTests/<Suite>; any other shape reads differently"
    echo "here and in CIGateSelectorBoundaryTests."
    exit 1
  fi
done
echo "    exit 2 for each, and xcodebuild never ran."

echo "==> 6/8 DUPLICATE: a suite named twice on one line exits 2 before xcodebuild runs"
CODE="$(run_gate "" "$WORK/both.json" S3BoundaryTests S3BoundaryTests)"
if [ "$CODE" -ne 2 ] || [ -s "$WORK/args.log" ]; then
  tail -6 "$WORK/gate.log"
  echo "SELF-TEST FAILED: a suite named twice gave exit $CODE (expected 2), or xcodebuild ran. It would"
  echo "run twice and inflate the floor."
  exit 1
fi
echo "    exit 2, and xcodebuild never ran."

echo "==> 7/8 SEAM NEGATIVE: --check-log over a log that records a restart"
printf 'Test Suite started\n%s\n** TEST EXECUTE SUCCEEDED **\n' "$MARKER" > "$WORK/with.log"
if Scripts/run-gated-suites.sh --check-log "$WORK/with.log" > "$WORK/seam.log" 2>&1; then
  cat "$WORK/seam.log"
  echo "SELF-TEST FAILED: --check-log passed a log that records a restart."
  exit 1
fi
echo "    exit non-zero."

echo "==> 8/8 SEAM POSITIVE: --check-log over a clean log"
printf 'Test Suite started\n** TEST EXECUTE SUCCEEDED **\n' > "$WORK/without.log"
if ! Scripts/run-gated-suites.sh --check-log "$WORK/without.log" > "$WORK/seam.log" 2>&1; then
  cat "$WORK/seam.log"
  echo "SELF-TEST FAILED: --check-log refused a clean log."
  exit 1
fi
echo "    exit 0."

echo
echo "RUN-GATED-SUITES SELF-TEST PASSED — the restart guard fires on the LIVE branch and at the"
echo "                                    seam, neither refuses an honest run, and the runner reads"
echo "                                    exactly the two selector shapes, refuses a duplicate and a"
echo "                                    named suite that ran nothing."
