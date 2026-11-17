# WorldRail.pack

The bundled rail pack: Natural Earth's rail lines and ferry routes, for telling a train or a ferry ride from a drive
(the ferry and train paths build; Docs/World-Transit-Paths-Exploration-2026-11-15.md §2, §3 and §9: owner's T1 A, a
separate rail pack from the world layer only, and F3, bundle Natural Earth's ferry routes). It lives at
`App/Fernlet/World/Atlas/WorldRail.pack`, beside `WorldAtlas.pack` and `WorldAirports.pack`, and reaches the app
target through the synchronized `World` folder (no project-file entry).

The app never fetches it and never sends it anywhere: it is public data, read only on the phone. Its lines are coarse
(1:10 million: they can sit a few hundred metres, in places a few kilometres, from the real track) and miss most
commuter, light-rail, tram and subway lines, so they raise a guess's confidence and are never drawn. In the US the
pack catches intercity trains; the learned lines (T2) recognise a light-rail commute.

| | |
|---|---|
| Size | 1,810,742 bytes (cap 2 MiB, 2,097,152; the generator refuses more, and so does `WorldRail`) |
| SHA-256 | `11513107850a3d201943e2460ba2a535f2bac6a3b18bac9e7d36b5636b0fa7d1` (pinned in `WorldRail.expectedSHA256`, checked by `WorldRailPackTests`) |
| Generated | 2026-11-16 by `Scripts/world-atlas/build_world_rail.py` (generator version 1) |
| Rail | 25,362 lines, cut into 36,918 pieces, 453,168 points, in 5,919 one-degree cells |
| Ferry | 308 lines (288 ferry routes from the roads layer, some in several parts, and the rail layer's 18 train ferries), 969 pieces, 5,352 points, 739 cells |

## Sources and licences

Both are Natural Earth 1:10m cultural layers, in the public domain; Natural Earth asks for no credit, and Fernlet gives
it on the Acknowledgments screen (Map data) and on the site's technical page with the rest of Natural Earth.

| Source | Pinned in | Bytes | SHA-256 |
|---|---|---|---|
| `ne_10m_railroads.zip` | `Scripts/world-atlas/fetch-rail-sources.sh` | 15,116,579 | `0bce64d1bb7ce1178810f0a341322b0459acb0689a61016259ef38f75abed0a4` |
| `ne_10m_roads.zip` (its ferry routes) | `Scripts/world-atlas/fetch-sources.sh` (the atlas's own pin) | 9,075,919 | `880b235383a1e1ccf33f4ea6f82b6755a2ffbce07e3974e412b43e88fe954ae9` |

The rail layer has its own pin table so the atlas's fourteen sources, its generator and `WorldAtlas.pack` (with its
META and pin) stay exactly as they are. Natural Earth's separate North America rail layer was measured and adds
nothing (exploration doc §9, open question 4), so it is not a source.

## Rules

- **Rail:** every `ne_10m_railroads` record whose `FEATURECLA` is `Railroad`, at any scale rank.
- **Ferry:** every `ne_10m_roads` record whose `FEATURECLA` is `Ferry` (`Ferry Route` and `Ferry, seasonal`), and every
  `ne_10m_railroads` record whose `FEATURECLA` is `Railroad ferry` (a train ferry is a boat). A record of any other
  class is left out and counted in the summary (the shipped source has one with an empty class).
- **Thinning:** each line part by Douglas-Peucker at 0.001° (about 110 m, the atlas's road tolerance), then quantised
  to 1e-5° with repeated points dropped. A part is cut where a step jumps more than 180° of longitude, so no piece
  crosses the antimeridian.
- **Pieces:** each part is cut wherever its segments' start points change one-degree cell; neighbouring pieces share
  their cut point. A piece is listed in the index of every cell its box touches (at most 1,024).
- Pieces are sorted by home cell, then source order: the same sources give the same bytes for one zlib build.

## Layout

The atlas's container with its own magic: `"FWR1"` · u16 version (1) · u16 sectionCount · a 16-byte table row per
section (4-byte tag · u32 offset · u32 storedLength · u32 rawLength) · bodies, each raw DEFLATE (RFC 1951, level 9).

| Tag | Body |
|---|---|
| `RAIL` | rail pieces: u32 pieceCount · per piece u16 pointCount (≥ 2) · i32 lon · i32 lat (1e-5°) · zigzag-LEB128 deltas lon, lat |
| `RIDX` | rail index: u16 cellCount · per cell, keys ascending: u16 key (row × 360 + column, rows from 90°S, columns from 180°W) · u32 refCount · zigzag-LEB128 deltas of ascending piece numbers (the first from zero) |
| `FERY` | ferry pieces, as `RAIL` |
| `FIDX` | ferry index, as `RIDX` |
| `META` | optional: the generator, its version, `--date`, the thinning and cell sizes, the counts, and each source's file, URL, SHA-256 and licence (JSON) |

`RAIL`, `RIDX`, `FERY` and `FIDX` are required. `WorldRail` (`FernletKit/Sources/WorldMapStore/WorldRail.swift`)
refuses, never trapping, a file over 2 MiB, a bad header or table, a section out of bounds, over 8 MiB raw or of the
wrong length, a missing section, more than 400,000 pieces or 1,500,000 points a layer, a piece under two points, a
point off the globe, keys out of order, and a listing of a piece that doesn't exist; `WorldRail.decode(_:)` turns any
of those into nil.

## Queries

`isNearRail(_:within:)` and `isNearFerryRoute(_:within:)` read the cells the box of `within` metres (capped at 20 km)
touches, then each listed piece's segments once, measuring point-to-segment distance in a flat local frame, and stop
at the first hit. The densest cell (Bohemia, around 50°N 14°E) holds 211 pieces and about 1,600 points, so a query
reads a few thousand segments at most. The app's `WorldTransitGeography` (`App/Fernlet/World/Atlas/`) joins them with
the shore mask's water and the atlas's `isNearMajorRoad(_:within:)` for the fog keeper's classifier; `WorldAtlasKeeper`
opens the pack off the main actor with the atlas and the shore mask.

## Rebuilding

```sh
Scripts/world-atlas/fetch-sources.sh          # ne_10m_roads (and the atlas's other sources)
Scripts/world-atlas/fetch-rail-sources.sh     # ne_10m_railroads
python3 -I Scripts/world-atlas/build_world_rail.py --sources ~/Library/Caches/Fernlet/atlas-sources \
    --out App/Fernlet/World/Atlas/WorldRail.pack --date 2026-11-16
python3 -I Scripts/world-atlas/rail_selftest.py
python3 -I Scripts/world-atlas/rail_selftest.py --pack App/Fernlet/World/Atlas/WorldRail.pack
```

The generator prints each section's raw and stored size, the counts, notes, unmapped data and the pack's SHA-256.
After a regeneration, move `WorldRail.expectedSHA256` and this page's table to the printed values in the same commit.
The self-test builds a pack from synthetic shapefiles and checks thinning, cell cuts, the index, the antimeridian cut,
which classes go to which layer, near-queries, determinism, the size cap and the pin check. Its `--pack` form decodes
a built pack and prints a few near-queries on real places.
