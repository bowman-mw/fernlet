#!/bin/bash
#
# spm-wall-check.sh — enforce the "S3 privacy wall" of the FernletKit SPM carve-up.
#
# THE RULE: the AI-provider and iCloud-sync modules (AIProviders, CloudKitSync) must NOT be
# able to reach the protected side of the wall — the sealed/private store modules
# (PrivateStoreCore, PrivateHealthStore, PrivateMemoryStore, PrivateMediaStore). Sealed data
# may only travel to AI/sync as the typed, de-identified payloads in AIContext.
#
# HOW THE WALL IS ENFORCED: AIProviders/CloudKitSync deliberately OMIT every Private* store
# from their `dependencies:` lists in FernletKit/Package.swift. The build setting
#
#     DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR   ("Validate Dependencies = Yes (Error)")
#
# then turns any `import <NotADependency>` into a hard build error (exit 65):
#
#     error: '<Importer>' is missing a dependency on '<Imported>'
#
# so a forbidden `import PrivateHealthStore` (etc.) inside a walled module FAILS THE BUILD.
#
# WHY THE FLAG IS LOAD-BEARING: the carve-up uses a single umbrella product (FernletKit),
# which pools every package module into one framework search path. WITHOUT this flag a
# forbidden cross-wall import is only a build-system *warning*, not an error — and using
# separate products does NOT change that (verified). This build-command override is what
# makes the dependency DAG actually load-bearing. It must be passed on the BUILD COMMAND;
# the value baked into the pbxproj does not reach the synthesized SwiftPM targets. It only
# re-fires on (re)compilation, so a CI clean build always triggers it.
#
# COMPLEMENTARY CHECK: FernletTests/S3BoundaryTests is a grep-wall (belt-and-suspenders) that
# scans the AI-facing source files for forbidden sealed-type tokens. Run the test suite to
# exercise it; this script covers the compiler-enforced half of the wall.
#
# POWER-OF-10 RULE 10 (Docs/Power-of-10-Swift.md §R10) RIDES ON THIS BUILD TOO. It is the one
# strict build CI runs, so it also carries the warnings-are-errors overrides:
#
#     SUPPRESS_WARNINGS=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
#
# WHY THESE MUST BE ON THE COMMAND LINE: Xcode passes `-suppress-warnings` to every synthesized
# FernletKit package target, so an ordinary build HIDES every warning in the package (dozens of
# real Sendable/isolation diagnostics went unseen this way). Only SUPPRESS_WARNINGS=NO on the
# build command lifts that; the pbxproj carries SWIFT_/GCC_TREAT_WARNINGS_AS_ERRORS for the app
# and test targets, but — like the dependency flag above — a project-level setting does not
# reach the SwiftPM targets, and `.treatAllWarnings(as: .error)` in Package.swift collides with
# Xcode's own `-suppress-warnings` ("conflicting options"), so the override here is the ONE
# place package warnings become errors. A new warning anywhere therefore fails this check.
#
# USAGE:  Scripts/spm-wall-check.sh
#         FERNLET_DESTINATION='platform=iOS Simulator,name=iPhone 17' Scripts/spm-wall-check.sh
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${FERNLET_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"

cd "$REPO_ROOT" || exit 99

echo "==> SPM S3 wall check (+ Power-of-10 rule 10: warnings are errors)"
echo "    repo:        $REPO_ROOT"
echo "    destination: $DESTINATION"
echo "    flag:        DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR"
echo "    R10 flags:   SUPPRESS_WARNINGS=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES"
echo

xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet \
  -destination "$DESTINATION" \
  DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR \
  SUPPRESS_WARNINGS=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
CODE=$?

echo
if [ $CODE -ne 0 ]; then
  echo "WALL CHECK FAILED (exit $CODE)."
  echo "A module imports across the S3 wall (look for \"is missing a dependency on\"), a warning"
  echo "was introduced somewhere (Power-of-10 rule 10: look for \"error:\" on a line that used to"
  echo "be a warning), or the build is broken."
  exit $CODE
fi
echo "WALL CHECK PASSED — the FernletKit dependency DAG is honest under enforcement, and the tree"
echo "                    (app, extensions, tests, and every FernletKit package target) built with"
echo "                    zero warnings."
