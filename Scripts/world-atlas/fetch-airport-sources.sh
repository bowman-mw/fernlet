#!/bin/bash
#
# fetch-airport-sources.sh — download WorldAirports.pack's sources onto the build machine, once, with the
# owner's OK (World-Airports-Spec §1.3–§1.4; OurAirports OK'd with screen 14, Wikidata in chat, 2026-10-30).
# The app never fetches any of this: only Scripts/world-atlas/build_world_airports.py reads these files, and
# only the pack it writes ships.
#
# Two kinds of source:
# - OurAirports' airports.csv and runways.csv (public domain), fetched by URL;
# - Wikidata snapshots (CC0): each is one SPARQL query from Scripts/world-atlas/airport-queries/, sent to
#   query.wikidata.org and saved as CSV. A query's answer changes as Wikidata is edited, so a re-fetch is a
#   new snapshot: run with --record and pin the new hashes in the same commit as the pack they built.
#
# Each file goes into its subdirectory of the destination and its size and SHA-256 are checked against the
# pinned table below. A file already in place is only re-checked, never downloaded again. An entry whose hash
# is the literal UNPINNED prints the hash it computed and makes the run fail, unless the run is --record,
# which prints the whole table with the computed hashes, ready to paste between the TABLE lines.
#
# Usage: Scripts/world-atlas/fetch-airport-sources.sh [--record] [destination]
#        destination defaults to "$HOME/Library/Caches/Fernlet/atlas-sources"
#
# The generator reads this table too. Format: subdir|file|bytes|required-or-optional|sha256|url
# (url "wikidata:<name>.rq" means the query file of that name).

set -euo pipefail

read -r -d '' SOURCES <<'TABLE' || true
ourairports|airports.csv|12753348|required|423a70f3a3a6b849db1063a5558e47bbd4e715decb6071f1f80f413ab92a88ac|https://davidmegginson.github.io/ourairports-data/airports.csv
ourairports|runways.csv|3972451|required|30364d9cff967c348317156758595ada533217bf00ef1711ad25204320f3de22|https://davidmegginson.github.io/ourairports-data/runways.csv
wikidata-airports|iata.csv|420897|required|58a7ea40ccc6054ce527544b90fb67e0f238c5083b902cc90239a367b22565be|wikidata:iata.rq
wikidata-airports|icao.csv|959860|required|6d7cab36bfe75feaedd814bba858c3615afc2227c9612329cb4a0cfa3d394cbe|wikidata:icao.rq
wikidata-airports|label-es-iata.csv|237855|required|7ccdff3793f412550ccaea99530b107c5747e69da7200197187e08b153d0bc94|wikidata:label-es-iata.rq
wikidata-airports|label-es-icao.csv|331211|required|9dae165265bdabddded21e6ba6ab7d0b8aa957bb8b13da09bc629076cf6d7056|wikidata:label-es-icao.rq
wikidata-airports|served.csv|1324127|required|c5d9ded4351a297c9f71d068386a1e1a4f9496aa781ff35340999e74a74a56b7|wikidata:served.rq
wikidata-airports|city-en-iata.csv|250858|required|08a456f2b9238031b1ac4c823766b89df5877a9ba7afd3db0247fd3ec6133dfb|wikidata:city-en-iata.rq
wikidata-airports|city-en-icao.csv|435390|required|c8923e43d1aea9bf0dd371dc6523dd6dc476f6f9de0586f38f10d45669eab848|wikidata:city-en-icao.rq
wikidata-airports|city-es-iata.csv|193514|required|1f4e33464e5b9953e80ea1997dbefa78eb4d2301953537552ba31858f8b052ea|wikidata:city-es-iata.rq
wikidata-airports|city-es-icao.csv|389600|required|6723ca46f12460db1bf0399f5edc9d520390ef4aee62e9cfab514ea367866d2f|wikidata:city-es-icao.rq
wikidata-airports|patronage.csv|20847474|optional|6e03b63b9310b08dae4b7e7d5de6fbf38a861c19a12997f4f8d3a711196bacb4|wikidata:patronage.rq
TABLE

usage() {
  echo "usage: Scripts/world-atlas/fetch-airport-sources.sh [--record] [destination]"
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
QUERIES="$(cd "$(dirname "$0")" && pwd)/airport-queries"
AGENT="FernletAtlasBuild/1.0 (bowman-mw; build-machine data fetch)"

FAILED=0
RECORDED=""
while IFS='|' read -r subdir file bytes need sha url; do
  [ -z "$subdir" ] && continue
  mkdir -p "$DEST/$subdir"
  path="$DEST/$subdir/$file"
  if [ ! -f "$path" ]; then
    echo "fetching $subdir/$file"
    case "$url" in
      wikidata:*)
        query="$QUERIES/${url#wikidata:}"
        [ -f "$query" ] || { echo "error: missing query $query" >&2; exit 1; }
        curl -sSf --max-time 300 -G -H "Accept: text/csv" -A "$AGENT" \
          --data-urlencode "query@$query" https://query.wikidata.org/sparql -o "$path.partial" \
          && mv "$path.partial" "$path" || { rm -f "$path.partial"; echo "error: could not fetch $file" >&2; FAILED=1; continue; }
        ;;
      *)
        curl -sSfL --max-time 300 -o "$path.partial" "$url" \
          && mv "$path.partial" "$path" || { rm -f "$path.partial"; echo "error: could not fetch $file" >&2; FAILED=1; continue; }
        ;;
    esac
  fi
  got_bytes=$(stat -f %z "$path")
  got_sha=$(shasum -a 256 "$path" | cut -c1-64)
  RECORDED="$RECORDED$subdir|$file|$got_bytes|$need|$got_sha|$url"$'\n'
  if [ "$RECORD" -eq 0 ]; then
    if [ "$sha" = "UNPINNED" ]; then
      echo "UNPINNED $subdir/$file: $got_bytes bytes, sha256 $got_sha" >&2
      FAILED=1
    elif [ "$got_sha" != "$sha" ] || [ "$got_bytes" != "$bytes" ]; then
      echo "error: $subdir/$file is $got_bytes bytes, sha256 $got_sha; pinned $bytes, $sha" >&2
      FAILED=1
    fi
  fi
done <<< "$SOURCES"

if [ "$RECORD" -eq 1 ]; then
  printf '%s' "$RECORDED"
  exit 0
fi
exit "$FAILED"
