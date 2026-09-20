#!/bin/bash
#
# run-gated-suites.sh — run named FernletTests suites against the ALREADY-BUILT test bundle and
# refuse a green run that executed fewer tests than its floor.
#
# Why the floor exists: `-only-testing:FernletTests/<Suite>` matches suite names exactly and
# matches NOTHING on a misspelling, a renamed suite, a file name where a `@Suite` struct was
# meant, or a suite that has since been deleted — and xcodebuild then exits 0 having executed
# zero tests under a "TEST EXECUTE SUCCEEDED" banner. A wall gated on such a line is not a wall
# (Docs/Verifiability.md §1 learned this on 2026-08-20; the P5 close-out found three phases of
# mesh batteries ungated for the same reason). So every CI test step goes through here: the run
# writes a result bundle, and the bundle's OWN test count is checked against the floor before
# the step may pass. Tests/FernletTests/CIGateSelectorBoundaryTests.swift is the static half —
# every suite the workflow names must be a declared suite, and every mesh battery declared in the
# tree must be named.
#
# Usage:  Scripts/run-gated-suites.sh <label> <min-tests> <Suite> [<Suite> ...]
#         <label>      a short name for the result bundle (letters, digits, dashes)
#         <min-tests>  the smallest test count that may pass. 1 means "at least not vacuous";
#                      a battery pins its real count and RAISES it as suites grow — lowering a
#                      floor is a review event, never a drive-by.
#         <Suite>      a suite name WITHOUT the FernletTests/ prefix
#
#         Scripts/run-gated-suites.sh --check-log <xcodebuild-log>
#                      scans a SAVED xcodebuild log for the restart marker with the same grep the
#                      live run uses, and runs nothing else. This is how the restart guard below is
#                      shown red without a Mac, a simulator or a build.
#
# Env:    FERNLET_DESTINATION    xcodebuild -destination (default: the iPhone 17 simulator)
#         FERNLET_DERIVED_DATA   xcodebuild -derivedDataPath (default: Xcode's shared one)
#         FERNLET_RESULT_DIR     where the result bundle AND the run log are written
#                                (default: $TMPDIR or /tmp)
#
# This script never builds: run `xcodebuild build-for-testing …` (CLAUDE.md) first.
set -euo pipefail

# The line xcodebuild prints when it restarts a test run after a crash, an unexpected exit or a
# timeout. A restart RE-RUNS suites, so the result bundle's `totalTestCount` counts some cells
# twice and the floor below stops proving anything — the run has to be repeated, never passed
# (P9 item 6's fix review, NOTE-4). Thirteen of the mesh step's suites rest on that floor alone.
RESTART_MARKER='Restarting after unexpected exit, crash, or test timeout'

# The guard's one seam, so it can be shown red with no simulator and no build: the SAME grep, over
# a log that already exists. It runs nothing else and touches no bundle.
if [[ "${1:-}" == "--check-log" ]]; then
    if [[ $# -ne 2 ]]; then
        echo "usage: Scripts/run-gated-suites.sh --check-log <xcodebuild-log>" >&2
        exit 2
    fi
    if grep -qF "$RESTART_MARKER" "$2"; then
        echo "::error::--check-log: $2 records a test-run RESTART (\"$RESTART_MARKER\") — a restart re-runs suites, so the bundle's test count is inflated and the floor proves nothing" >&2
        exit 1
    fi
    echo "==> --check-log: no restart recorded in $2"
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ $# -lt 3 ]]; then
    echo "usage: Scripts/run-gated-suites.sh <label> <min-tests> <Suite> [<Suite> ...]" >&2
    exit 2
fi
LABEL="$1"; MIN_TESTS="$2"; shift 2
case "$LABEL" in *[!A-Za-z0-9-]*|"") echo "label must be letters, digits or dashes: '$LABEL'" >&2; exit 2 ;; esac
case "$MIN_TESTS" in *[!0-9]*|"") echo "min-tests must be a non-negative integer: '$MIN_TESTS'" >&2; exit 2 ;; esac
if [[ "$MIN_TESTS" -lt 1 ]]; then
    echo "min-tests must be at least 1 — a floor of 0 is exactly the vacuous green this script exists to refuse" >&2
    exit 2
fi

DESTINATION="${FERNLET_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
RESULT_DIR="${FERNLET_RESULT_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$RESULT_DIR"
BUNDLE="$RESULT_DIR/fernlet-$LABEL-$$.xcresult"
RUN_LOG="$RESULT_DIR/fernlet-$LABEL-$$.log"
rm -rf "$BUNDLE"
rm -f "$RUN_LOG"

# Seeded non-empty on purpose: macOS ships bash 3.2, where expanding an EMPTY array under
# `set -u` is an unbound-variable error.
ARGS=(-project App/Fernlet.xcodeproj -scheme Fernlet -destination "$DESTINATION" -resultBundlePath "$BUNDLE")
if [[ -n "${FERNLET_DERIVED_DATA:-}" ]]; then
    ARGS+=(-derivedDataPath "$FERNLET_DERIVED_DATA")
fi
for suite in "$@"; do
    case "$suite" in *[!A-Za-z0-9_]*|"") echo "suite names are bare identifiers, got '$suite'" >&2; exit 2 ;; esac
    ARGS+=("-only-testing:FernletTests/$suite")
done

echo "==> $LABEL: $# suite(s), floor $MIN_TESTS test(s)"
RUN_STATUS=0
# Through `tee` so the restart marker can be read back: the console still sees every line, and
# `set -o pipefail` keeps the pipeline's status xcodebuild's own.
xcodebuild test-without-building "${ARGS[@]}" 2>&1 | tee "$RUN_LOG" || RUN_STATUS=$?

RESTARTED=0
if [[ -f "$RUN_LOG" ]] && grep -qF "$RESTART_MARKER" "$RUN_LOG"; then
    RESTARTED=1
fi

if [[ ! -d "$BUNDLE" ]]; then
    echo "::error::$LABEL: xcodebuild wrote no result bundle at $BUNDLE (status $RUN_STATUS)" >&2
    exit 1
fi

SUMMARY_JSON="$(xcrun xcresulttool get test-results summary --path "$BUNDLE" --compact)"
export SUMMARY_JSON
python3 - "$LABEL" "$MIN_TESTS" "$RUN_STATUS" "$RESTARTED" <<'PY'
import json, os, sys
label, floor, run_status = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
restarted = int(sys.argv[4])
summary = json.loads(os.environ["SUMMARY_JSON"])
total = int(summary.get("totalTestCount", 0))
failed = int(summary.get("failedTests", 0))
skipped = int(summary.get("skippedTests", 0))
result = summary.get("result", "unknown")
print(f"==> {label}: {total} test(s) ran, {failed} failed, {skipped} skipped, result={result}, xcodebuild status={run_status}")
problems = []
if run_status != 0:
    problems.append(f"xcodebuild exited {run_status}")
if restarted:
    problems.append(
        "xcodebuild RESTARTED the test run after an unexpected exit, crash or timeout — a restart "
        "re-runs suites, so totalTestCount is inflated and this floor proves nothing; re-run on a "
        "quiet machine rather than accepting the number"
    )
if failed > 0 or result != "Passed":
    problems.append(f"result is {result} with {failed} failure(s)")
if total < floor:
    problems.append(
        f"only {total} test(s) ran but the floor is {floor} — a selector matched nothing "
        "(misspelled, renamed or deleted suite, or a file name where a @Suite struct was meant), "
        "or a battery shrank; raise the floor deliberately, never lower it in passing"
    )
if problems:
    print("::error::" + label + ": " + "; ".join(problems))
    sys.exit(1)
PY
