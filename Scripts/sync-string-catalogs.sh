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

# Each shipping target that owns a Localizable.xcstrings, and where that catalog lives.
TARGETS=(
    "Fernlet:App/Fernlet/Localizable.xcstrings"
    "FernletWidgets:App/FernletWidgets/Localizable.xcstrings"
    "FernletShareExtension:App/FernletShareExtension/Localizable.xcstrings"
)

echo "==> Building (SWIFT_EMIT_LOC_STRINGS=YES) to emit .stringsdata"
# SWIFT_EMIT_LOC_STRINGS is already YES in the pbxproj for these targets; it is
# repeated on the command line because that is the only way it reaches the
# SwiftPM-synthesized FernletKit targets (same gotcha as SUPPRESS_WARNINGS in
# Scripts/spm-wall-check.sh).
BUILD_LOG="$(mktemp -t fernlet-locstrings)"
if ! xcodebuild build \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        SWIFT_EMIT_LOC_STRINGS=YES \
        > "$BUILD_LOG" 2>&1; then
    echo "BUILD FAILED — last 40 lines:" >&2
    tail -40 "$BUILD_LOG" >&2
    exit 1
fi

BUILD_DIR="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
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
    stringsdata=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && stringsdata+=("$line")
    done < <(find "$INTERMEDIATES" -type d -name "${target}.build" \
        -exec find {} -name '*.stringsdata' -print \; 2>/dev/null | sort -u)

    if [[ ${#stringsdata[@]} -eq 0 ]]; then
        echo "!! $target: no .stringsdata found under $INTERMEDIATES — skipping" >&2
        STATUS=1
        continue
    fi

    if [[ $CHECK_ONLY -eq 1 ]]; then
        before="$(mktemp -t fernlet-catalog)"
        cp "$catalog" "$before"
        xcrun xcstringstool sync "$catalog" --stringsdata "${stringsdata[@]}"
        if diff -q "$before" "$catalog" >/dev/null; then
            echo "   $target: catalog up to date (${#stringsdata[@]} stringsdata)"
        else
            echo "!! $target: $catalog is STALE — run Scripts/sync-string-catalogs.sh and commit" >&2
            diff "$before" "$catalog" | head -40 >&2
            STATUS=1
        fi
        cp "$before" "$catalog"   # --check never writes
        rm -f "$before"
    else
        xcrun xcstringstool sync "$catalog" --stringsdata "${stringsdata[@]}"
        keys="$(xcrun xcstringstool print "$catalog" | wc -l | tr -d ' ')"
        echo "   $target: synced $catalog (${#stringsdata[@]} stringsdata, ~$keys keys)"
    fi
done

rm -f "$BUILD_LOG"

if [[ $STATUS -ne 0 ]]; then
    exit $STATUS
fi

echo
echo "String catalogs synced. Review the diff and commit it with the code change."
echo "InfoPlist.xcstrings and AppShortcuts.xcstrings are hand-authored — this script"
echo "does not touch them (their stringsdata producers are IDE-only)."
