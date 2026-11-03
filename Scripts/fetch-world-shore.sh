#!/bin/bash
#
# fetch-world-shore.sh — put the World map's land and water pack in place.
#
# `App/Fernlet/World/Atlas/WorldShore.pack` (30 MB, OpenStreetMap data under the ODbL) is gitignored, kept out of
# the repository's history the way the branded food catalog is (Scripts/fetch-branded-catalog.sh). A fresh clone
# therefore has none: a Debug build goes on without it and the map falls back to the atlas's coarser land, while the
# Fernlet target's "Ensure world shore pack" phase fails any other build rather than ship the app without it. Xcode
# Cloud clones fresh for every build, so its post-clone hooks run this. Runnable by hand from any checkout.
#
# It downloads the pinned GitHub Release asset, checks its SHA-256 against the pin, and only then moves it into place.
# A pack already there with the pinned hash is left alone. A different one (a locally regenerated pack, say) is
# refused unless `--force`.
#
# Moving to a regenerated pack: publish a NEW release (`world-shore-v2`, …), and move the tag and hash below and
# `WorldShoreMask.expectedSHA256` in the same commit. A published asset is never replaced in place, so an old commit
# still builds the pack it was tested with, and the ODbL's public copy of each shipped pack stays available.
#
# Usage: Scripts/fetch-world-shore.sh [--force]

set -euo pipefail

TAG="world-shore-v1"
URL="https://github.com/bowman-mw/fernlet/releases/download/${TAG}/WorldShore.pack"
SHA256="1b6bbe3954541ab9c3169e02eb5005c4d4ebc18035f65f1ccf0bddb42c0e4a60"

FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
fi

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEST="$REPO_ROOT/App/Fernlet/World/Atlas/WorldShore.pack"

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

if [ -s "$DEST" ]; then
  if [ "$(sha256_of "$DEST")" = "$SHA256" ]; then
    echo "world shore: $TAG already in place."
    exit 0
  fi
  if [ "$FORCE" -ne 1 ]; then
    echo "error: $DEST holds a different pack than $TAG; pass --force to replace it." >&2
    exit 1
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "world shore: downloading $TAG …"
curl --fail --location --silent --show-error --retry 3 --retry-delay 5 --max-time 600 \
  --output "$WORK/WorldShore.pack" "$URL"

ACTUAL="$(sha256_of "$WORK/WorldShore.pack")"
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "error: the downloaded pack's sha256 is $ACTUAL, not the pinned $SHA256; nothing was installed." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
mv -f "$WORK/WorldShore.pack" "$DEST"
echo "world shore: $TAG installed at App/Fernlet/World/Atlas/WorldShore.pack."
