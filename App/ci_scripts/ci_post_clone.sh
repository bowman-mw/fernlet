#!/bin/sh
#
# Xcode Cloud post-clone hook. It puts the gitignored branded food catalog in place before the build,
# so a Release archive ships the branded-food-catalog on-demand resource with its database
# (Scripts/fetch-branded-catalog.sh, ODRAssets/README.md). There is one of these beside the project
# (App/ci_scripts) and one beside the workspace (ci_scripts), because Xcode Cloud reads the folder next
# to whichever container the workflow builds. Both call the same script.

set -e
exec "${CI_PRIMARY_REPOSITORY_PATH:?not running under Xcode Cloud}/Scripts/fetch-branded-catalog.sh"
