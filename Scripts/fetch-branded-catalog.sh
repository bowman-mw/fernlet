#!/bin/bash
#
# fetch-branded-catalog.sh — put the branded food catalog's on-demand-resource source in place.
#
# `ODRAssets/FoodCatalogBranded.sqlite` (178 MB, 364,457 USDA FoodData Central branded products) is
# gitignored: it is over GitHub's file limit. A fresh clone therefore has none, and the Fernlet target's
# "Ensure branded catalog ODR source" phase fails a Release build without it, rather than ship the
# branded-food-catalog pack empty (ODRAssets/README.md). Xcode Cloud clones fresh for every build, so
# its post-clone hook runs this. Both hooks call it: `App/ci_scripts/ci_post_clone.sh`, beside the
# project, and `ci_scripts/ci_post_clone.sh`, beside the workspace. Xcode Cloud reads the folder next to
# whichever container its workflow builds.
#
# It downloads the pinned GitHub Release asset, checks the decompressed database's SHA-256 against
# the pin, and only then moves it into place. A database already there with the pinned hash is left
# alone. A different non-empty one (a locally regenerated catalog, say) is refused unless `--force`.
# A zero-byte placeholder left by a Debug build is replaced. Runnable by hand from any checkout.
#
# Moving to a regenerated catalog: publish a NEW release (`branded-food-catalog-v2`, …) and move all
# three pins below in the same commit. A published asset is never replaced in place, so an old commit
# still builds the catalog it was tested with.
#
# Usage: Scripts/fetch-branded-catalog.sh [--force]

set -euo pipefail

TAG="branded-food-catalog-v1"
URL="https://github.com/bowman-mw/fernlet/releases/download/${TAG}/FoodCatalogBranded.sqlite.gz"
SHA256="7dc78cb95401f7a17cc1b078fbe2a54fd1493019f8fc7864218635ce49a5b5a6"

FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
fi

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEST="$REPO_ROOT/ODRAssets/FoodCatalogBranded.sqlite"

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

if [ -s "$DEST" ]; then
  if [ "$(sha256_of "$DEST")" = "$SHA256" ]; then
    echo "branded catalog: $TAG already in place."
    exit 0
  fi
  if [ "$FORCE" -ne 1 ]; then
    echo "error: $DEST holds a different catalog than $TAG; pass --force to replace it." >&2
    exit 1
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "branded catalog: downloading $TAG …"
curl --fail --location --silent --show-error --retry 3 --retry-delay 5 --max-time 900 \
  --output "$WORK/catalog.sqlite.gz" "$URL"
gunzip -c "$WORK/catalog.sqlite.gz" > "$WORK/catalog.sqlite"

ACTUAL="$(sha256_of "$WORK/catalog.sqlite")"
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "error: the downloaded catalog's sha256 is $ACTUAL, not the pinned $SHA256; nothing was installed." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
mv -f "$WORK/catalog.sqlite" "$DEST"
echo "branded catalog: $TAG installed at ODRAssets/FoodCatalogBranded.sqlite."
