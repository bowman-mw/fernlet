#!/bin/bash
#
# sync-string-catalogs.sh — repopulate the string catalogs without opening Xcode.
#
# `xcodebuild` never writes into an .xcstrings: the XCStrings build spec declares
# exactly one command, `xcstringstool compile`, and the *sync* half lives in the
# IDE. But the same `xcstringstool` binary ships in the toolchain, and its `sync`
# subcommand consumes precisely the `.stringsdata` files xcodebuild already emits
# (SWIFT_EMIT_LOC_STRINGS is YES on all three shipping targets). So the loop is:
#
#     build  ->  collect .stringsdata  ->  xcstringstool sync
#
# Run this after adding or changing user-facing strings, then commit the catalog
# diff alongside the code change. It is additive: keys that disappear from the
# code are marked stale rather than deleted, so a translation is never silently
# thrown away.
#
# Usage:  Scripts/sync-string-catalogs.sh [--check]
#         --check   fail (exit 1) if syncing would change a catalog, instead of
#                   writing it. This is the CI form: it proves the committed
#                   catalogs match the code.
#
# Env:    FERNLET_DESTINATION      xcodebuild -destination (default: iPhone 17 sim)
#         FERNLET_DERIVED_DATA     xcodebuild -derivedDataPath. Unset (the default)
#                                  uses Xcode's shared DerivedData, which is right for
#                                  CI and for a lone developer — but two xcodebuilds
#                                  sharing one DerivedData corrupt it, so set this to a
#                                  private path when running from one of several
#                                  concurrent worktrees. It is threaded through BOTH
#                                  xcodebuild calls on purpose: -showBuildSettings has
#                                  to report the same BUILD_DIR the build wrote to, or
#                                  the .stringsdata search below finds nothing.
#
#                                  DO NOT point this at the DerivedData you run tests
#                                  from. This script's action is `build`; a test run's is
#                                  `build-for-testing`, and interleaving the two in ONE
#                                  DerivedData leaves the test bundle and the app linked
#                                  against different copies of the same modules. Measured
#                                  2026-08-27: ~22 failures across 11 untouched suites,
#                                  every one of them the duplicate-type-identity tell —
#                                    expected error ".missingPayload" of type RecipeImportError,
#                                    but ".missingPayload" of type RecipeImportError was thrown
#                                  Expected X, got X is never a real assertion failure. A
#                                  clean rebuild into a fresh path clears it; do not bisect.
#                                  Give this script its own path:
#                                    FERNLET_DERIVED_DATA=/tmp/dd-sync Scripts/sync-string-catalogs.sh
#
# `--check` NEVER writes: `xcstringstool sync` has no dry-run, so the check syncs for
# real and restores the file afterwards. That restore is trap-backed (see `cleanup`)
# because `set -e` would otherwise strand a mutated catalog on any non-zero status in
# the window between the sync and the restore.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CHECK_ONLY=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK_ONLY=1
fi

PROJECT="App/Fernlet.xcodeproj"
SCHEME="Fernlet"
DESTINATION="${FERNLET_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"

# Seeded non-empty on purpose: macOS ships bash 3.2, where expanding an EMPTY array
# under `set -u` is an unbound-variable error.
XCODEBUILD_ARGS=(-project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION")
if [[ -n "${FERNLET_DERIVED_DATA:-}" ]]; then
    XCODEBUILD_ARGS+=(-derivedDataPath "$FERNLET_DERIVED_DATA")
fi

# Every target that owns a Localizable.xcstrings, and where that catalog lives.
#
# The FernletKit entries are package targets. They only emit .stringsdata because
# SWIFT_EMIT_LOC_STRINGS is forced on the xcodebuild COMMAND LINE below — a pbxproj
# setting does not reach the SwiftPM-synthesized targets. A module appears here once
# it has a catalog; add the .xcstrings to its Sources directory (SwiftPM auto-processes
# it, no Package.swift edit) and add a line here in the same commit.
TARGETS=(
    "Fernlet:App/Fernlet/Localizable.xcstrings"
    "FernletWidgets:App/FernletWidgets/Localizable.xcstrings"
    "FernletShareExtension:App/FernletShareExtension/Localizable.xcstrings"
    "FernletMessagesExtension:App/FernletMessagesExtension/Localizable.xcstrings"
    "FernletDomainModel:FernletKit/Sources/FernletDomainModel/Localizable.xcstrings"
    "FernletLockUI:FernletKit/Sources/FernletLockUI/Localizable.xcstrings"
    "FernletUI:FernletKit/Sources/FernletUI/Localizable.xcstrings"
    "ProximityKit:FernletKit/Sources/ProximityKit/Localizable.xcstrings"
    "AppServices:FernletKit/Sources/AppServices/Localizable.xcstrings"
    "AIProviders:FernletKit/Sources/AIProviders/Localizable.xcstrings"
    "CloudKitSync:FernletKit/Sources/CloudKitSync/Localizable.xcstrings"
    "FernletFoundation:FernletKit/Sources/FernletFoundation/Localizable.xcstrings"
    "HealthKitGateway:FernletKit/Sources/HealthKitGateway/Localizable.xcstrings"
)

echo "==> Building (SWIFT_EMIT_LOC_STRINGS=YES) to emit .stringsdata"
# SWIFT_EMIT_LOC_STRINGS is already YES in the pbxproj for these targets; it is
# repeated on the command line because that is the only way it reaches the
# SwiftPM-synthesized FernletKit targets (same gotcha as SUPPRESS_WARNINGS in
# Scripts/spm-wall-check.sh).
BUILD_LOG="$(mktemp -t fernlet-locstrings)"

# ── The never-writes invariant, made structural ──────────────────────────────────────
#
# `xcstringstool sync` writes IN PLACE, so `--check` is sync-then-restore and the
# catalog is genuinely dirty in between. Under `set -euo pipefail` ANY non-zero status
# in that window kills the script before the restore, and the mutation ships: a failing
# `sync`, a `diff` (which exits 1 by definition when it finds the difference we are
# reporting), a `head` closing the pipe early, or a Ctrl-C / CI cancellation.
#
# A trap is the only structure that covers all four, so the in-flight pair is registered
# here rather than restored by straight-line code at the end of the branch. `cleanup`
# also owns the build log, which every early `exit 1` above used to leak.
#
# ARMING ORDER IS LOAD-BEARING: PENDING_* are set only AFTER the backup is a real copy.
# Arming on the bare `mktemp` would let an interrupted `cp` leave the trap copying an
# EMPTY file over the catalog — turning a safety net into the data loss it prevents.
PENDING_CATALOG=""
PENDING_BACKUP=""

restore_pending() {
    if [[ -n "$PENDING_BACKUP" ]]; then
        # `|| true` on each step: a restore that fails for catalog N must not abort the
        # trap (under `set -e` it would) and strand catalogs N+1…
        [[ -f "$PENDING_BACKUP" && -n "$PENDING_CATALOG" ]] \
            && cp "$PENDING_BACKUP" "$PENDING_CATALOG" || true
        rm -f "$PENDING_BACKUP" || true
    fi
    PENDING_CATALOG=""
    PENDING_BACKUP=""
    return 0
}

cleanup() {
    restore_pending
    rm -f "$BUILD_LOG" || true
    return 0
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

if ! xcodebuild build \
        "${XCODEBUILD_ARGS[@]}" \
        SWIFT_EMIT_LOC_STRINGS=YES \
        > "$BUILD_LOG" 2>&1; then
    echo "BUILD FAILED — last 40 lines:" >&2
    tail -40 "$BUILD_LOG" >&2
    exit 1
fi

BUILD_DIR="$(xcodebuild "${XCODEBUILD_ARGS[@]}" \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/[ ]BUILD_DIR = /{print $2; exit}')"
if [[ -z "$BUILD_DIR" ]]; then
    echo "Could not resolve BUILD_DIR from xcodebuild -showBuildSettings" >&2
    exit 1
fi
INTERMEDIATES="${BUILD_DIR%/Build/Products}/Build/Intermediates.noindex"

STATUS=0
for entry in "${TARGETS[@]}"; do
    target="${entry%%:*}"
    catalog="${entry##*:}"

    # One target's .stringsdata can be spread over several architectures and
    # configurations; sync wants that target's COMPLETE set in one invocation.
    # (Built with `while read`, not `mapfile` — macOS ships bash 3.2.)
    #
    # The `Objects-normal` anchor is load-bearing. The project-level intermediates
    # directory is ALSO called `Fernlet.build`, and it CONTAINS every target's build
    # directory — so matching on the directory name alone picked up the widget's and
    # the test bundle's strings as well, and silently synced foreign keys into the app
    # catalog. Requiring `<target>.build/Objects-normal/` selects the compile outputs
    # of that target and nothing else.
    stringsdata=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && stringsdata+=("$line")
    done < <(find "$INTERMEDIATES" -path "*/${target}.build/Objects-normal/*" \
        -name '*.stringsdata' -print 2>/dev/null | sort -u)

    if [[ ${#stringsdata[@]} -eq 0 ]]; then
        echo "!! $target: no .stringsdata found under $INTERMEDIATES — skipping" >&2
        STATUS=1
        continue
    fi

    if [[ $CHECK_ONLY -eq 1 ]]; then
        before="$(mktemp -t fernlet-catalog)"
        cp "$catalog" "$before"
        PENDING_BACKUP="$before"   # arm the trap only now — see the arming-order note
        PENDING_CATALOG="$catalog"
        xcrun xcstringstool sync "$catalog" --stringsdata "${stringsdata[@]}"
        if diff -q "$before" "$catalog" >/dev/null; then
            echo "   $target: catalog up to date (${#stringsdata[@]} stringsdata)"
        else
            echo "!! $target: $catalog is STALE — run Scripts/sync-string-catalogs.sh and commit" >&2
            # `|| true` is what keeps this a REPORT of every stale target rather than an
            # abort at the first one: `diff` exits 1 precisely because it found the
            # difference being printed, and `head` can SIGPIPE the pipeline to 141. The
            # trap would restore the catalog either way; only this makes the loop finish.
            diff "$before" "$catalog" | head -40 >&2 || true
            STATUS=1
        fi
        restore_pending   # --check never writes
    else
        xcrun xcstringstool sync "$catalog" --stringsdata "${stringsdata[@]}"
        keys="$(xcrun xcstringstool print "$catalog" | wc -l | tr -d ' ')"
        echo "   $target: synced $catalog (${#stringsdata[@]} stringsdata, ~$keys keys)"
    fi
done

# (The build log and any in-flight catalog backup are the `cleanup` trap's, so that every
# exit path — including the early `exit 1`s above — disposes of them exactly once.)

if [[ $STATUS -ne 0 ]]; then
    exit $STATUS
fi

echo
echo "String catalogs synced. Review the diff and commit it with the code change."
echo "InfoPlist.xcstrings and AppShortcuts.xcstrings are hand-authored — this script"
echo "does not touch them (their stringsdata producers are IDE-only)."
