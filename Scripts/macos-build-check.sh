#!/bin/bash
#
# macos-build-check.sh — prove ProximityKit builds for native macOS 26 (plan step A0.6, Mac
# readiness, Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4).
#
# WHAT IT CHECKS: ProximityKit and its closure (ProximityKit, FernletCrypto, FernletDomainModel,
# FernletFoundation) compile for `generic/platform=macOS`, arm64 and x86_64, with warnings as errors.
# Nothing in the closure may name an API native macOS lacks: ProximityKit takes such facts from its
# host, and its two platform seams compile only where their framework is usable (NIRangingSession
# under `#if os(iOS)`, ProtectedSidecar's protected-data retry under `#if canImport(UIKit)`). Nothing
# on iOS can see that hold or break: a UIKit, NearbyInteraction or ActivityKit symbol outside its guard
# compiles clean there. This build is the compiler half; Tests/FernletTests/ProximityPlatformBoundaryTests
# is the source half, and it pins that this script, its self-test, the CI step and the pre-push leg run.
#
# WHY XCODEBUILD AND NOT `swift build`: the SwiftPM command line leaves the closure's `.xcstrings`
# catalogs unprocessed, so FernletFoundation and FernletDomainModel get no `Bundle.module`.
# `resources: [.process(…)]` would make it build, but the CLI then copies each catalog raw, so every
# CLI-built binary would show English and still build green: the silent failure the localization wall
# exists to prevent (FernletKit/Package.swift's header). Xcode compiles the catalogs natively.
#
# WHY A PRODUCT: for a local package, xcodebuild offers one scheme per library product plus
# `FernletKit-Package`, which also builds the UIKit modules (FernletUI, PrivateMediaStore,
# AppServices). The `ProximityKit` product is the one scheme that builds exactly ProximityKit's
# closure. No app target links it.
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
# ProximityKit must fail it, and the clean tree must pass it.
#
# USAGE:  Scripts/macos-build-check.sh
#         FERNLET_MACOS_DERIVED_DATA=/path/to/derived-data Scripts/macos-build-check.sh
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${FERNLET_MACOS_DERIVED_DATA:-$REPO_ROOT/FernletKit/build/macos-check}"

cd "$REPO_ROOT/FernletKit" || exit 99

echo "==> ProximityKit for native macOS 26 (closure: ProximityKit, FernletCrypto, FernletDomainModel, FernletFoundation)"
echo "    derived data: $DERIVED"
echo

xcodebuild build -scheme ProximityKit -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR \
  SUPPRESS_WARNINGS=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
CODE=$?

echo
if [ $CODE -ne 0 ]; then
  echo "MACOS BUILD FAILED (exit $CODE): ProximityKit or its closure no longer builds for native macOS 26."
  echo "An iOS-only API reached it (guard a mechanism seam with #if os(iOS), or take the fact from the host),"
  echo "or a warning appeared (Power-of-10 rule 10). See ProximityKit.md, \"Platforms\"."
  exit $CODE
fi
if [ ! -d "$DERIVED/Build/Products/Debug" ] || [ -d "$DERIVED/Build/Products/Debug-maccatalyst" ]; then
  echo "MACOS BUILD FAILED: no native macOS products under $DERIVED/Build/Products/Debug, or a Mac Catalyst build"
  echo "beside them. 'generic/platform=macOS' also matches Mac Catalyst; check -destination (and delete \$DERIVED"
  echo "if a stale Catalyst build was left there)."
  exit 1
fi
echo "MACOS BUILD PASSED — ProximityKit's closure built for native macOS 26 with zero warnings."
