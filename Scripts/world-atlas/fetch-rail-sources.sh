#!/bin/bash
#
# fetch-rail-sources.sh — download WorldRail.pack's own source onto the build machine, once, with the owner's OK
# (Docs/World-Rail-Pack.md; owner's T1 A, 2026-11-15). The app never fetches any of this: only
# Scripts/world-atlas/build_world_rail.py reads it, and only the pack it writes ships.
#
# The rail pack also reads ne_10m_roads (its ferry routes), which stays pinned in the atlas's own table,
# Scripts/world-atlas/fetch-sources.sh: run that script too. The rail layer has its own table so the atlas's
# fourteen sources, and WorldAtlas.pack's META, stay as they are.
#
# The file goes into its own new, empty subdirectory of the destination (curl -fL), and its size and SHA-256 are
# checked against the pinned table below. A file already in place is only re-checked, never downloaded again.
# An entry whose hash is the literal UNPINNED prints the hash it computed and makes the run fail, unless the run
# is `--record`, which prints the table with the computed hashes, ready to paste between the TABLE lines.
#
# Usage: Scripts/world-atlas/fetch-rail-sources.sh [--record] [destination]
#        destination defaults to "$HOME/Library/Caches/Fernlet/atlas-sources"
#
# The generator reads this table too. Format: subdir|file|bytes|required-or-optional|sha256|url

set -euo pipefail

read -r -d '' SOURCES <<'TABLE' || true
ne_10m_railroads|ne_10m_railroads.zip|15116579|required|0bce64d1bb7ce1178810f0a341322b0459acb0689a61016259ef38f75abed0a4|https://naciscdn.org/naturalearth/10m/cultural/ne_10m_railroads.zip
TABLE

usage() {
  echo "usage: Scripts/world-atlas/fetch-rail-sources.sh [--record] [destination]"
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
    echo "rail sources: $file already present, checking it."
  else
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
      echo "error: $dir is not empty and holds no $file; refusing to download into it." >&2
      FAILED=1
      continue
    fi
    mkdir -p "$dir"
    echo "rail sources: downloading $file ($bytes bytes) from $url"
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
    echo "rail sources: $file matches its pin."
  fi
done 3<<< "$SOURCES"

if [ "$FAILED" -ne 0 ]; then
  echo "error: rail sources are incomplete or do not match their pins (see above)." >&2
  exit 1
fi

if [ "$RECORD" -eq 1 ]; then
  echo ""
  echo "Paste these lines between the TABLE lines of Scripts/world-atlas/fetch-rail-sources.sh:"
  printf '%s' "$RECORDED"
  exit 0
fi

if [ "$UNPINNED" -ne 0 ]; then
  echo "error: some sources are UNPINNED; check the hashes above and pin them (run again with --record)." >&2
  exit 1
fi

echo "rail sources: all present and pinned in $DEST"
