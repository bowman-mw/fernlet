#!/bin/bash
#
# macos-build-check.sh — prove the Fernlet modules a Mac host needs build for native macOS 26 (plan
# step A0.6, Mac readiness, Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4).
#
# WHAT IT CHECKS: the Mac-ready set (FernletFoundation, FernletCrypto and FernletDomainModel) compiles
# for `generic/platform=macOS`, arm64 and x86_64, with warnings as errors. A Mac host of Fernlet's
# (workstream B, the Coach app) needs all three, so each is named and keeps a macOS build of its own.
# Nothing in the set may name an API native macOS lacks, and nothing on iOS can see that hold or
# break: a UIKit symbol compiles clean there. ProximityKit, which builds for macOS too, is its own
# repository's since plan step A1.3, and that repository's CI builds and tests it on macOS.
# Tests/FernletTests/ProximityPlatformBoundaryTests pins that this script, its self-test, the CI step
# and the pre-push leg run.
#
# WHY XCODEBUILD AND NOT `swift build`: the SwiftPM command line leaves the set's `.xcstrings`
# catalogs unprocessed, so FernletFoundation and FernletDomainModel get no `Bundle.module`.
# `resources: [.process(…)]` would make it build, but the CLI then copies each catalog raw, so every
# CLI-built binary would show English and still build green: the silent failure the localization wall
# exists to prevent (FernletKit/Package.swift's header). Xcode compiles the catalogs natively.
#
# WHY A PRODUCT: for a local package, xcodebuild offers one scheme per library product plus
# `FernletKit-Package`, which also builds the UIKit modules (FernletUI, PrivateMediaStore,
# AppServices). The `MacReady` product names exactly the Mac-ready set, so its scheme builds those three
# modules and nothing else; ProximityPlatformBoundaryTests pins its line in the manifest. No app target
# links it.
#
# WHY ITS OWN DERIVED DATA: `-derivedDataPath` defaults to FernletKit/build/macos-check (gitignored),
# or FERNLET_MACOS_DERIVED_DATA when set. It deliberately does not read FERNLET_DERIVED_DATA, so a
# developer who points that at one shared folder for the iOS builds, or two worktrees building at
# once, never mix a macOS build into an iOS one.
#
# POWER-OF-10 RULE 10 (Docs/Power-of-10-Swift.md §R10): this is the second strict build, beside
# Scripts/spm-wall-check.sh's iOS one. The xcodebuild command below carries the same warnings-as-errors
# overrides and the same dependency-validation flag that build passes, for the same reason: a
# project-level setting does not reach the synthesized package targets, and Xcode passes
# `-suppress-warnings` to every local-package target unless the command lifts it. A warning that only
# a macOS build reports therefore fails this check. PowerOfTenBoundaryTests reads the one command,
# never an `echo`.
#
# THE DESTINATION: `generic/platform=macOS` matches two destinations, and xcodebuild prints "Using the
# first of multiple matching destinations: { platform:macOS, name:Any Mac } { platform:macOS,
# variant:Mac Catalyst, name:Any Mac }". Native macOS is chosen only by that ordering, and a Mac
# Catalyst build would pass where native macOS fails (Catalyst has UIKit). So after a passing build
# this script requires native macOS products (Build/Products/Debug) and no Mac Catalyst products
# (Build/Products/Debug-maccatalyst), and fails naming the destination otherwise.
#
# Scripts/macos-build-selftest.sh proves this check is load-bearing: a planted `import UIKit` in
# FernletFoundation must fail it, and the clean tree must pass it.
#
# USAGE:  Scripts/macos-build-check.sh
#         FERNLET_MACOS_DERIVED_DATA=/path/to/derived-data Scripts/macos-build-check.sh
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${FERNLET_MACOS_DERIVED_DATA:-$REPO_ROOT/FernletKit/build/macos-check}"

cd "$REPO_ROOT/FernletKit" || exit 99
# Run from a git hook (the pre-push leg), this script inherits GIT_DIR and the rest of the hook's git
# environment, and so would SwiftPM's own `git` calls in its package checkouts, which would then read this
# repository and fail to resolve proximitykit from cold derived data. Nothing here needs them.
unset $(git rev-parse --local-env-vars)

echo "==> The Mac-ready set for native macOS 26 (MacReady: FernletFoundation, FernletCrypto, FernletDomainModel)"
echo "    derived data: $DERIVED"
echo

xcodebuild build -scheme MacReady -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR \
  SUPPRESS_WARNINGS=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
CODE=$?

echo
if [ $CODE -ne 0 ]; then
  echo "MACOS BUILD FAILED (exit $CODE): the Mac-ready set no longer builds for native macOS 26."
  echo "An iOS-only API reached it (guard it with #if os(iOS), or keep it out of the Mac-ready set),"
  echo "or a warning appeared (Power-of-10 rule 10)."
  exit $CODE
fi
if [ ! -d "$DERIVED/Build/Products/Debug" ] || [ -d "$DERIVED/Build/Products/Debug-maccatalyst" ]; then
  echo "MACOS BUILD FAILED: no native macOS products under $DERIVED/Build/Products/Debug, or a Mac Catalyst build"
  echo "beside them. 'generic/platform=macOS' also matches Mac Catalyst; check -destination (and delete \$DERIVED"
  echo "if a stale Catalyst build was left there)."
  exit 1
fi
echo "MACOS BUILD PASSED — the Mac-ready set built for native macOS 26 with zero warnings."
