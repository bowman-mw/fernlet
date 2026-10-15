#!/bin/bash
#
# run-gated-suites-selftest.sh — prove the restart guard and the suite census in
# Scripts/run-gated-suites.sh are LOAD-BEARING on the script's LIVE branch, not merely at its
# `--check-log` seam, and that it reads exactly the one selector shape.
#
# Why this exists: a restart RE-RUNS suites, so the result bundle's `totalTestCount` counts some
# cells twice and every floor above it stops proving anything (P9 item 6's fix review, NOTE-4;
# thirteen of the mesh step's suites rest on that floor alone). The guard shipped with a
# `--check-log <file>` seam so it could be shown red with no Mac — but the seam is a SECOND code
# path, and nothing had ever executed the live branch's `tee` -> `grep -qF "$RESTART_MARKER"
# "$RUN_LOG"`. A refactor that dropped the `tee`, renamed `$RUN_LOG` or moved the grep above the
# redirect would have left the seam green and the gate blind. A line's total can also hide a named
# suite that ran nothing beside ones that ran, so the runner reads the result bundle's tests tree and
# refuses a named suite that ran no test case (ProximityKit plan step A0.8, when a line could name a
# suite of ProximityKit's package tests too, `ProximityKitTests/<Suite>`, until A1.3 moved them to its
# own repository): that census, the one selector shape, the duplicate refusal and the workspace
# container are held here too. This runs the REAL script, on its REAL branch, with `xcodebuild` and
# `xcrun` stubbed on PATH, and asserts the exit code and the arguments the script passed.
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
#     `$FERNLET_SELFTEST_TREE`: `fernlet-only.json` (one FernletTests suite) or `two.json` (that
#     suite and a second), in the shape measured on Xcode 26.5, or `extra-segment.json`, a tree in a
#     shape that was never measured. The first suite's display name is not its type name, as a Swift
#     Testing suite's need not be, so a census that keyed suites by name would refuse assertions 2
#     and 3. A stub that under-counted would pass this self-test for
#     the wrong reason, which is why assertion 2 runs the same stubs with the marker removed and
#     requires exit 0. Any other `xcrun` call is a loud refusal rather than a silent `{}`.
#   * Every gate runs under the UTF-8 locale macOS defaults to, in which bash's ranged classes admit
#     accented letters, so assertion 5's non-ASCII selector is refused for the runner's own reason.
#
# Eight assertions, in the order that makes each one mean something:
#   1. LIVE NEGATIVE  — marker in the run output                    -> the gate must exit non-zero
#   2. LIVE POSITIVE  — same stubs, marker removed                  -> the gate must exit 0
#   3. TWO SUITES     — two bare suites, both in the tree           -> 0, through the workspace, each
#                                                                      selector in FernletTests
#   4. SUITE CENSUS   — a suite absent beside one its bundle ran    -> non-zero, naming it alone (the
#                                                                      census is per suite, not per bundle);
#                       a tree in an unmeasured shape               -> non-zero, naming the unread tree,
#                                                                      not a suite that ran nothing
#   5. REFUSED SHAPES — FernletTests/<Suite>, the retired
#                       ProximityKitTests/<Suite>, a second slash,
#                       an empty suite, a non-ASCII one             -> exit 2 each, xcodebuild never runs
#   6. DUPLICATE      — one suite named twice                       -> exit 2, xcodebuild never runs
#   7. SEAM NEGATIVE  — --check-log over a log with the marker, and
#                       over a log that is not there                -> non-zero each
#   8. SEAM POSITIVE  — --check-log over a log without it           -> 0
# 1 without 2 would pass on any broken stub, and 4 without 3 on a census that refuses everything;
# 7 and 8 are cheap and keep both restart paths in one place. Assertion 4's cases, the display name,
# 5's non-ASCII selector and 7's missing log joined at ProximityKit plan step A0.8.5; 3's second suite
# is a FernletTests one, and 5 refuses the qualified package shape, since A1.3.
#
# Every step is a fixed, bounded command; the loops walk assertion 5's fixed five-item list and 7's two
# logs.
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

# The measured tests trees, in the shape `xcresulttool get test-results tests --compact` gives on
# Xcode 26.5: a Test Suite node's nodeIdentifierURL is test://com.apple.xcode/<container>/<bundle>/<Type>.
cat > "$WORK/fernlet-only.json" <<'TREE'
{"testNodes":[{"nodeType":"Test Plan","name":"Fernlet","children":[
 {"nodeType":"Unit test bundle","name":"FernletTests","children":[
  {"nodeType":"Test Suite","name":"S3 boundary","nodeIdentifierURL":"test://com.apple.xcode/Fernlet/FernletTests/S3BoundaryTests","children":[
   {"nodeType":"Test Case","name":"aCase()","result":"Passed"}]}]}]}]}
TREE
cat > "$WORK/two.json" <<'TREE'
{"testNodes":[{"nodeType":"Test Plan","name":"Fernlet","children":[
 {"nodeType":"Unit test bundle","name":"FernletTests","children":[
  {"nodeType":"Test Suite","name":"S3 boundary","nodeIdentifierURL":"test://com.apple.xcode/Fernlet/FernletTests/S3BoundaryTests","children":[
   {"nodeType":"Test Case","name":"aCase()","result":"Passed"}]},
  {"nodeType":"Test Suite","name":"NoTrackingBoundaryTests","nodeIdentifierURL":"test://com.apple.xcode/Fernlet/FernletTests/NoTrackingBoundaryTests","children":[
   {"nodeType":"Test Case","name":"aCase()","result":"Passed"}]}]}]}]}
TREE
# A shape never measured: one path segment more before the bundle.
cat > "$WORK/extra-segment.json" <<'TREE'
{"testNodes":[{"nodeType":"Test Plan","name":"Fernlet","children":[
 {"nodeType":"Unit test bundle","name":"FernletTests","children":[
  {"nodeType":"Test Suite","name":"S3 boundary","nodeIdentifierURL":"test://com.apple.xcode/Fernlet/Extra/FernletTests/S3BoundaryTests","children":[
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
      LC_ALL=en_US.UTF-8 \
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

echo "==> 3/8 TWO SUITES: two bare suites, both in the tree, must pass"
CODE="$(run_gate "" "$WORK/two.json" S3BoundaryTests NoTrackingBoundaryTests)"
if [ "$CODE" -ne 0 ]; then
  tail -12 "$WORK/gate.log"
  echo "SELF-TEST FAILED: the gate refused a run in which both named suites ran (exit $CODE)."
  exit 1
fi
if ! passed_arg "-workspace" || ! passed_arg "Fernlet.xcworkspace" || passed_arg "-project" \
  || ! passed_arg "-only-testing:FernletTests/S3BoundaryTests" \
  || ! passed_arg "-only-testing:FernletTests/NoTrackingBoundaryTests"; then
  cat "$WORK/args.log"
  echo "SELF-TEST FAILED: the runner did not pass -workspace Fernlet.xcworkspace (and no -project) with"
  echo "each selector in FernletTests: -only-testing:FernletTests/S3BoundaryTests and"
  echo "-only-testing:FernletTests/NoTrackingBoundaryTests. The arguments it passed are above."
  exit 1
fi
echo "    exit 0, through Fernlet.xcworkspace, each selector in FernletTests."

echo "==> 4/8 SUITE CENSUS: one suite of two absent from the tree, and a tree in an unmeasured shape,"
echo "    must NOT pass"
CODE="$(run_gate "" "$WORK/fernlet-only.json" S3BoundaryTests NoTrackingBoundaryTests)"
if [ "$CODE" -eq 0 ]; then
  tail -12 "$WORK/gate.log"
  echo "SELF-TEST FAILED: the gate passed a run in which a named suite ran no test case. Its total"
  echo "cleared the floor, which is exactly how a suite that matched nothing hides on a line."
  exit 1
fi
if ! grep -q "named but ran no test case: FernletTests/NoTrackingBoundaryTests —" "$WORK/gate.log"; then
  tail -12 "$WORK/gate.log"
  echo "SELF-TEST FAILED: a suite that ran nothing beside one its bundle ran gave exit $CODE without"
  echo "naming FernletTests/NoTrackingBoundaryTests alone. A census per bundle cannot see it."
  exit 1
fi
CODE="$(run_gate "" "$WORK/extra-segment.json" S3BoundaryTests)"
if [ "$CODE" -eq 0 ] || ! grep -q "no parseable nodeIdentifierURL" "$WORK/gate.log" \
  || grep -q "named but ran no test case" "$WORK/gate.log"; then
  tail -12 "$WORK/gate.log"
  echo "SELF-TEST FAILED: a tree in a shape never measured gave exit $CODE without being named as a"
  echo "tree the census cannot read, or was read as a selector that ran nothing."
  exit 1
fi
echo "    exit non-zero each: the census names each suite that ran nothing, and a tree it cannot read."

echo "==> 5/8 REFUSED SHAPES: every other selector shape exits 2 before xcodebuild runs"
# R2: bounded by the fixed five-item list.
for shape in FernletTests/S3BoundaryTests ProximityKitTests/S3BoundaryTests ProximityKitTests/A/B ProximityKitTests/ CaféTests; do
  CODE="$(run_gate "" "$WORK/fernlet-only.json" "$shape")"
  if [ "$CODE" -ne 2 ] || [ -s "$WORK/args.log" ]; then
    tail -6 "$WORK/gate.log"
    echo "SELF-TEST FAILED: '$shape' gave exit $CODE (expected 2), or xcodebuild ran. A selector is a"
    echo "FernletTests suite's bare name; any other shape reads differently here and in"
    echo "CIGateSelectorBoundaryTests."
    exit 1
  fi
done
echo "    exit 2 for each, and xcodebuild never ran."

echo "==> 6/8 DUPLICATE: a suite named twice on one line exits 2 before xcodebuild runs"
CODE="$(run_gate "" "$WORK/fernlet-only.json" S3BoundaryTests S3BoundaryTests)"
if [ "$CODE" -ne 2 ] || [ -s "$WORK/args.log" ]; then
  tail -6 "$WORK/gate.log"
  echo "SELF-TEST FAILED: a suite named twice gave exit $CODE (expected 2), or xcodebuild ran. It would"
  echo "run twice and inflate the floor."
  exit 1
fi
echo "    exit 2, and xcodebuild never ran."

echo "==> 7/8 SEAM NEGATIVE: --check-log over a log that records a restart, and over one that is not there"
printf 'Test Suite started\n%s\n** TEST EXECUTE SUCCEEDED **\n' "$MARKER" > "$WORK/with.log"
# R2: bounded by the two logs.
for log in "$WORK/with.log" "$WORK/no-such.log"; do
  if Scripts/run-gated-suites.sh --check-log "$log" > "$WORK/seam.log" 2>&1; then
    cat "$WORK/seam.log"
    echo "SELF-TEST FAILED: --check-log passed $log, which records a restart or does not exist."
    exit 1
  fi
done
echo "    exit non-zero each."

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
echo "                                    exactly the one selector shape, refuses a duplicate, a"
echo "                                    named suite that ran nothing and a tree it cannot read."
