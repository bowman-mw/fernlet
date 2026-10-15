#!/bin/bash
#
# run-gated-suites.sh — run named test suites against the ALREADY-BUILT test bundles and
# refuse a green run that executed fewer tests than its floor, or in which a named suite ran none.
#
# Why the floor exists: `-only-testing:<Target>/<Suite>` matches suite names exactly and
# matches NOTHING on a misspelling, a renamed suite, a file name where a `@Suite` struct was
# meant, or a suite that has since been deleted — and xcodebuild then exits 0 having executed
# zero tests under a "TEST EXECUTE SUCCEEDED" banner. A wall gated on such a line is not a wall
# (Docs/Verifiability.md §1 learned this on 2026-08-20; the P5 close-out found three phases of
# mesh batteries ungated for the same reason). So every CI test step goes through here: the run
# writes a result bundle, and the bundle's OWN test count is checked against the floor before
# the step may pass, and its own tests tree against every selector (the suite census below).
# Tests/FernletTests/CIGateSelectorBoundaryTests.swift is the static half — every suite the
# workflow names must be a declared FernletTests suite, every mesh battery declared in the tree
# must be named, and Tests/suite-inventory.tsv holds every suite to its file and lines.
#
# Usage:  Scripts/run-gated-suites.sh <label> <min-tests> <Selector> [<Selector> ...]
#         <label>      a short name for the result bundle (letters, digits, dashes)
#         <min-tests>  the smallest test count that may pass. 1 means "at least not vacuous";
#                      a battery pins its real count and RAISES it as suites grow — lowering a
#                      floor is a review event, never a drive-by.
#         <Selector>   a FernletTests suite's bare name; no other shape, so this script and
#                      CIGateSelectorBoundaryTests read a line alike (ProximityKit's package tests,
#                      named ProximityKitTests/<Suite> from plan step A0.8, are its own repository's
#                      CI since A1.3). Every named suite must run at least one test case (the suite
#                      census).
#
#         Scripts/run-gated-suites.sh --check-log <xcodebuild-log>
#                      scans a SAVED xcodebuild log for the restart marker with the same grep the
#                      live run uses, and runs nothing else. This is how the restart guard below is
#                      shown red without a Mac, a simulator or a build.
#
# Env:    FERNLET_DESTINATION    xcodebuild -destination (default: the iPhone 17 simulator)
#         FERNLET_DERIVED_DATA   xcodebuild -derivedDataPath (default: Xcode's shared one, where
#                                Scripts/spm-wall-check.sh builds; that script takes no such path, so
#                                set this only to the derived data of a build made with the same one)
#         FERNLET_RESULT_DIR     where the result bundle AND the run log are written
#                                (default: $TMPDIR or /tmp)
#
# This script never builds: run Scripts/spm-wall-check.sh (the strict build-for-testing through
# Fernlet.xcworkspace) first; a -project build lands in other derived data.
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
    # A log that is not there, or not a readable file, records nothing: grep's file error would read
    # as "no match", so it is refused before the grep rather than passed.
    if [[ ! -f "$2" || ! -r "$2" ]]; then
        echo "::error::--check-log: cannot read $2 — a log that is not there proves no run was clean" >&2
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
    echo "usage: Scripts/run-gated-suites.sh <label> <min-tests> <Selector> [<Selector> ...]" >&2
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

# Through the workspace: Scripts/spm-wall-check.sh builds through the same workspace (kept for
# developing ProximityKit beside Fernlet, plan step A1.5), so a run with the default derived data finds
# what that build made; a run through -project would read other derived data.
# Seeded non-empty on purpose: macOS ships bash 3.2, where expanding an EMPTY array under
# `set -u` is an unbound-variable error.
ARGS=(-workspace Fernlet.xcworkspace -scheme Fernlet -destination "$DESTINATION" -resultBundlePath "$BUNDLE")
if [[ -n "${FERNLET_DERIVED_DATA:-}" ]]; then
    ARGS+=(-derivedDataPath "$FERNLET_DERIVED_DATA")
fi
# One shape: a bare FernletTests suite. Every other shape (a `/` among them: FernletTests/<Suite>,
# or the ProximityKitTests/<Suite> a line used for ProximityKit's package tests until plan step A1.3),
# and a suite named twice on one line (it would run twice and inflate the floor), is refused before
# xcodebuild runs. Bounded: one pass over the arguments. The identifier class is spelled out, not
# ranged: under macOS's default UTF-8 locale, bash 3.2's `A-Z` admits accented letters, which
# CIGateSelectorBoundaryTests' ASCII-only reader refuses (ProximityKit plan step A0.8.5).
IDENTIFIER_CHARS='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_'
SELECTORS=""
for suite in "$@"; do
    case "$suite" in
        *[!$IDENTIFIER_CHARS]*|"")
            echo "a selector is a FernletTests suite's bare name, got '$suite'" >&2
            exit 2 ;;
    esac
    case " $SELECTORS " in
        *" FernletTests/$suite "*) echo "'$suite' is named twice on this line: it would run twice" >&2; exit 2 ;;
    esac
    SELECTORS="$SELECTORS FernletTests/$suite"
    ARGS+=("-only-testing:FernletTests/$suite")
done

echo "==> $LABEL: $# selector(s), floor $MIN_TESTS test(s)"
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
# The tests tree goes to a FILE: mesh-batteries' compact tree is ~600 KB, and arguments plus
# environment share macOS's 1 MiB ARG_MAX.
TESTS_PATH="$RESULT_DIR/fernlet-$LABEL-$$.tests.json"
xcrun xcresulttool get test-results tests --path "$BUNDLE" --compact > "$TESTS_PATH"
export SUMMARY_JSON TESTS_PATH SELECTORS
python3 - "$LABEL" "$MIN_TESTS" "$RUN_STATUS" "$RESTARTED" <<'PY'
import json, os, sys
label, floor, run_status = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
restarted = int(sys.argv[4])
summary = json.loads(os.environ["SUMMARY_JSON"])
total = int(summary.get("totalTestCount", 0))
failed = int(summary.get("failedTests", 0))
skipped = int(summary.get("skippedTests", 0))
result = summary.get("result", "unknown")
# The suite census: test cases per `<bundle>/<TypeName>`, the type read off the first Test Suite
# node's nodeIdentifierURL (test://com.apple.xcode/<container>/<bundle>/<Type>), because a Swift
# Testing suite's `name` is its display name. A top-level suite whose URL is not exactly that shape,
# with <bundle> the enclosing bundle's name, and a test case outside any suite, are unparsed: a changed
# tree format is named as such, never read as a selector that ran nothing (ProximityKit plan step
# A0.8.5; every tree measured on Xcode 26.5 reads with none). Bounded: every node of the finite tree is
# pushed once.
with open(os.environ["TESTS_PATH"], encoding="utf-8") as fh:
    tree = json.load(fh)
counts, per_bundle, unparsed = {}, {}, []
stack = [(node, "", "") for node in tree.get("testNodes", [])]
while stack:
    node, bundle, suite = stack.pop()
    kind = node.get("nodeType", "")
    if kind == "Unit test bundle":
        bundle = node.get("name", "")
    if kind == "Test Suite" and not suite:
        parts = node.get("nodeIdentifierURL", "").split("/")
        if len(parts) == 6 and parts[0] == "test:" and parts[4] == bundle and parts[5]:
            suite = f"{parts[4]}/{parts[5]}"
        else:
            # A display name is not a type name (the MeshContent* suites), so no fallback key: say so.
            unparsed.append(f"{bundle}/{node.get('name', '?')}")
            suite = f"{bundle}/?"
    if kind == "Test Case":
        if not suite:
            unparsed.append(f"{bundle}/{node.get('name', '?')} (a test case outside any suite)")
        key = suite or f"{bundle}/?"
        counts[key] = counts.get(key, 0) + 1
        per_bundle[bundle] = per_bundle.get(bundle, 0) + 1
        continue
    stack.extend((child, bundle, suite) for child in node.get("children", []) or [])
split = " + ".join(f"{name} {n}" for name, n in sorted(per_bundle.items())) or "no test case"
print(f"==> {label}: {total} test(s) ran ({split}), {failed} failed, {skipped} skipped, result={result}, xcodebuild status={run_status}")
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
        "(misspelled, renamed or deleted suite, a file name where a @Suite struct was meant, "
        "or a suite of another bundle), "
        "or a battery shrank; raise the floor deliberately, never lower it in passing"
    )
if unparsed:
    problems.append(
        "the result bundle's tests tree has Test Suite nodes with no parseable nodeIdentifierURL, or "
        "test cases outside any suite ("
        + ", ".join(sorted(set(unparsed))[:5]) + "): this xcresulttool's format is not the one measured on "
        "Xcode 26.5, so the suite census cannot read it — fix the census, never pass the line around it"
    )
unrun = [s for s in os.environ["SELECTORS"].split() if counts.get(s, 0) == 0]
if unrun and not unparsed:
    problems.append(
        "named but ran no test case: " + ", ".join(unrun) + " — a suite that left FernletTests, a "
        "scheme that lost a testable, or a suite that matched nothing; a line's total can hide it, "
        "this cannot"
    )
if problems:
    print("::error::" + label + ": " + "; ".join(problems))
    sys.exit(1)
PY
