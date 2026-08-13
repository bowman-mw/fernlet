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
# USAGE:  Scripts/spm-wall-check.sh
#         FERNLET_DESTINATION='platform=iOS Simulator,name=iPhone 17' Scripts/spm-wall-check.sh
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${FERNLET_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"

cd "$REPO_ROOT" || exit 99

echo "==> SPM S3 wall check"
echo "    repo:        $REPO_ROOT"
echo "    destination: $DESTINATION"
echo "    flag:        DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR"
echo

xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet \
  -destination "$DESTINATION" \
  DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR
CODE=$?

echo
if [ $CODE -ne 0 ]; then
  echo "WALL CHECK FAILED (exit $CODE)."
  echo "A module imports across the S3 wall (look for \"is missing a dependency on\"), or the build is broken."
  exit $CODE
fi
echo "WALL CHECK PASSED — the FernletKit dependency DAG is honest under enforcement."
