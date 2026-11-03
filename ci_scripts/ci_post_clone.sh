#!/bin/sh
#
# Xcode Cloud post-clone hook. It puts the gitignored branded food catalog and World shore pack in place before the
# build, so a Release archive ships the branded-food-catalog on-demand resource with its database and the map with its
# land and water (Scripts/fetch-branded-catalog.sh, ODRAssets/README.md; Scripts/fetch-world-shore.sh,
# Docs/World-Shore-Pack.md). There is one of these beside the project (App/ci_scripts) and one beside the workspace
# (ci_scripts), because Xcode Cloud reads the folder next to whichever container the workflow builds. Both call the same
# scripts.

set -e
ROOT="${CI_PRIMARY_REPOSITORY_PATH:?not running under Xcode Cloud}"
"$ROOT/Scripts/fetch-branded-catalog.sh"
"$ROOT/Scripts/fetch-world-shore.sh"
