#!/bin/bash
#
# fetch-shore-sources.sh — download WorldShore.pack's sources onto the build machine (Docs/World-Shore-Pack.md). The app
# never fetches any of this: only Scripts/world-atlas/build_world_shore.py reads these files, and only the pack ships.
#
# About 28 GB in all. Each source goes into its own new, empty subdirectory of the destination, and every file's SHA-256
# is checked against the pins in shore-sources.sha256. A file already in place is only re-checked, never downloaded again.
#
# Usage: Scripts/world-atlas/fetch-shore-sources.sh [destination]
#        destination defaults to "$HOME/Library/Caches/Fernlet/atlas-sources"

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$HOME/Library/Caches/Fernlet/atlas-sources}"
PINS="$HERE/shore-sources.sha256"
LAND_URL="https://osmdata.openstreetmap.de/download/land-polygons-split-4326.zip"
WATER_BASE="https://overturemaps-us-west-2.s3.amazonaws.com/release/2026-10-21.0/theme=base/type=water"
LAND_DIR="$DEST/osm_land_polygons_split"
WATER_DIR="$DEST/overture_water_2026-10-21"

mkdir -p "$LAND_DIR" "$WATER_DIR"

fetch() {
  local url="$1" file="$2"
  [ -f "$file" ] && return 0
  curl -fL --retry 4 --silent --show-error -o "$file.partial" "$url"
  mv "$file.partial" "$file"
}

fetch "$LAND_URL" "$LAND_DIR/land-polygons-split-4326.zip"

while read -r sha name; do
  case "$name" in
    *.parquet) fetch "$WATER_BASE/$name" "$WATER_DIR/$name" ;;
  esac
done < "$PINS"

failed=0
while read -r sha name; do
  case "$name" in
    *.zip) file="$LAND_DIR/$name" ;;
    *) file="$WATER_DIR/$name" ;;
  esac
  actual="$(shasum -a 256 "$file" | cut -d ' ' -f 1)"
  if [ "$actual" != "$sha" ]; then
    echo "SHA-256 mismatch: $name" >&2
    failed=1
  fi
done < "$PINS"
[ "$failed" -eq 0 ] || exit 1

if [ ! -f "$LAND_DIR/unpacked/land-polygons-split-4326/land_polygons.shp" ]; then
  unzip -o -q "$LAND_DIR/land-polygons-split-4326.zip" -d "$LAND_DIR/unpacked"
fi

echo "Sources ready in $DEST"
