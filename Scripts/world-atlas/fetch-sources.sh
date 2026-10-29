#!/bin/bash
#
# fetch-sources.sh — download the World atlas pack's eight sources onto the build machine, once, with the
# owner's OK (Docs/World-Atlas-Pack.md). The app never fetches any of this: only
# Scripts/world-atlas/build_world_atlas.py reads these files, and only the pack it writes ships.
#
# Each source goes into its own new, empty subdirectory of the destination (curl -fL), and every file's
# size and SHA-256 are checked against the pinned table below. A file already in place is only re-checked,
# never downloaded again. A subdirectory that exists and holds anything but its pinned file is refused.
#
# Pinning: an entry whose hash is the literal UNPINNED prints the hash it computed and makes the run fail,
# unless the run is `--record`, which prints the whole table with the computed hashes, ready to paste
# between the TABLE lines below. Pin them in the same commit as the pack they built.
#
# The coastline is for reference and QA only: the generator does not need it, so a failed download of it
# is a warning, not an error.
#
# Usage: Scripts/world-atlas/fetch-sources.sh [--record] [destination]
#        destination defaults to "$HOME/Library/Caches/Fernlet/atlas-sources"
#
# The generator reads this table too (build_world_atlas.py parses the TABLE block), so it is the single
# place the URLs and pins live. Format: subdir|file|bytes|required-or-optional|sha256|url

set -euo pipefail

read -r -d '' SOURCES <<'TABLE' || true
ne_10m_land|ne_10m_land.zip|3269070|required|e547d749445eaa0964aba76738090ec88f5e63c4585122170f98c67a7ea922dc|https://naciscdn.org/naturalearth/10m/physical/ne_10m_land.zip
ne_10m_minor_islands|ne_10m_minor_islands.zip|314932|required|47c0b3ce26df7b4dbabdbb251023918cb2f5c83462a426288f1f253da7284db2|https://naciscdn.org/naturalearth/10m/physical/ne_10m_minor_islands.zip
ne_10m_coastline|ne_10m_coastline.zip|3069451|optional|bfa04cdbcbef07ef90dfca1dabb48062eca29900a113df0f389303e255484017|https://naciscdn.org/naturalearth/10m/physical/ne_10m_coastline.zip
ne_10m_geography_marine_polys|ne_10m_geography_marine_polys.zip|940563|required|a2d3395904c41e718e02c3ec5bc988712164c524c236fad32d95d282ca303b2a|https://naciscdn.org/naturalearth/10m/physical/ne_10m_geography_marine_polys.zip
ne_10m_admin_0_countries|ne_10m_admin_0_countries.zip|4930492|required|ce1ac7036499a0edd641fbc093cd209a98f96a49d2eca8480aaacad35138a7f6|https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_0_countries.zip
ne_10m_populated_places|ne_10m_populated_places.zip|2811199|required|cd149186f03d2603e0410da399b980a4357d0ac32d3a2305a49ed3dffcc41d7b|https://naciscdn.org/naturalearth/10m/cultural/ne_10m_populated_places.zip
ne_10m_urban_areas|ne_10m_urban_areas.zip|13097698|required|2c593114e954ce1adb297ddee5465f05d9e81fa0a26deb13f8500d58a00d7051|https://naciscdn.org/naturalearth/10m/cultural/ne_10m_urban_areas.zip
Beck_KG_V1|Beck_KG_V1.zip|70961149|required|a33f861200e32e80d5615bba1350ceeb8b0f5e6a6ffdc18b2d1715a3293d7b4b|https://ndownloader.figshare.com/files/12407516
TABLE

usage() {
  echo "usage: Scripts/world-atlas/fetch-sources.sh [--record] [destination]"
}

RECORD=0
DEST=""
for arg in "$@"; do
  case "$arg" in
    --record) RECORD=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option $arg" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$DEST" ]; then
        echo "error: more than one destination given" >&2
        exit 2
      fi
      DEST="$arg"
      ;;
  esac
done
DEST="${DEST:-$HOME/Library/Caches/Fernlet/atlas-sources}"

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

size_of() {
  wc -c < "$1" | tr -d ' '
}

mkdir -p "$DEST"
FAILED=0
UNPINNED=0
RECORDED=""

while IFS='|' read -r subdir file bytes need pinned url <&3; do
  [ -n "$subdir" ] || continue
  dir="$DEST/$subdir"
  path="$dir/$file"

  if [ -f "$path" ]; then
    echo "atlas sources: $file already present, checking it."
  else
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
      echo "error: $dir is not empty and holds no $file; refusing to download into it." >&2
      FAILED=1
      continue
    fi
    mkdir -p "$dir"
    echo "atlas sources: downloading $file ($bytes bytes) from $url"
    if ! curl -fL --silent --show-error --retry 3 --retry-delay 5 --max-time 1800 \
        --output "$path.part" "$url" < /dev/null; then
      rm -f "$path.part"
      if [ "$need" = "optional" ]; then
        echo "warning: $file (optional, QA only) could not be downloaded; continuing without it." >&2
        continue
      fi
      echo "error: $file could not be downloaded." >&2
      FAILED=1
      continue
    fi
    mv -f "$path.part" "$path"
  fi

  actual_size="$(size_of "$path")"
  if [ "$actual_size" != "$bytes" ]; then
    echo "error: $file is $actual_size bytes, not the expected $bytes (the upstream file changed?)." >&2
    FAILED=1
  fi

  actual="$(sha256_of "$path")"
  RECORDED="$RECORDED$subdir|$file|$actual_size|$need|$actual|$url
"
  if [ "$pinned" = "UNPINNED" ]; then
    echo "UNPINNED: $file sha256 $actual"
    UNPINNED=1
  elif [ "$actual" != "$pinned" ]; then
    echo "error: $file sha256 is $actual, not the pinned $pinned." >&2
    FAILED=1
  else
    echo "atlas sources: $file matches its pin."
  fi
done 3<<< "$SOURCES"

if [ "$FAILED" -ne 0 ]; then
  echo "error: atlas sources are incomplete or do not match their pins (see above)." >&2
  exit 1
fi

if [ "$RECORD" -eq 1 ]; then
  echo ""
  echo "Paste these lines between the TABLE lines of Scripts/world-atlas/fetch-sources.sh:"
  printf '%s' "$RECORDED"
  exit 0
fi

if [ "$UNPINNED" -ne 0 ]; then
  echo "error: some sources are UNPINNED; check the hashes above and pin them (run again with --record)." >&2
  exit 1
fi

echo "atlas sources: all present and pinned in $DEST"
