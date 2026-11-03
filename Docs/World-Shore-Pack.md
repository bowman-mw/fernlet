# World shore pack

The fog's and Your world's land and water, far finer than the atlas's Natural Earth mask. This file is the contract
between the generator (`Scripts/world-atlas/build_world_shore.py`) and the Swift reader
(`FernletKit/Sources/WorldMapStore/WorldShoreMask*.swift`).

## Where it lives and what it may do

- **Bundled, never fetched by the app.** `App/Fernlet/World/Atlas/WorldShore.pack` ships inside the app. The app opens no
  connection for it, so the no-tracking wall gains no data destination ([No-Tracking-Wall.md](No-Tracking-Wall.md)).
- **Kept out of git, like the branded food catalog.** The pack is gitignored and published as a GitHub Release asset on this
  repository: release [`world-shore-v1`](https://github.com/bowman-mw/fernlet/releases/tag/world-shore-v1).
  `Scripts/fetch-world-shore.sh` downloads it, checks the pinned hash and moves it into place; run it once in a fresh clone
  or worktree. Xcode Cloud's post-clone hooks and the scheduled workflow run it for you.
- **Without it.** A Debug build goes on and the map falls back to the atlas's `LAND`. Any other configuration fails in the
  Fernlet target's "Ensure world shore pack" phase, unless `FERNLET_ALLOW_MISSING_SHORE_PACK=YES`, so a shipped app always
  has its land and water. The shipped-pack tests fail without it too.
- **Sources stay on the build machine.** It fetches them through `Scripts/world-atlas/fetch-shore-sources.sh` (pinned
  URLs and SHA-256s).
- **Size cap: 30 MiB.** The owner's goal is under 30 MB (2026-11-02). The generator refuses a bigger pack, and the tests
  fail one.
- **Checksum.** `WorldShoreMask.expectedSHA256` pins the shipped file. Regenerating the pack changes it on purpose, in
  the same commit.
- **Drawing only.** The fog and Your world's picture read it. The passport's rules (country, ocean within reach,
  continent, terrain stamps) stay on the atlas's `LAND`, so nothing already earned changes, and without the pack the map
  falls back to `LAND`.

## Sources and licence

| Layer | Source | Licence |
| --- | --- | --- |
| Land and coast | OpenStreetMap land polygons, [osmdata.openstreetmap.de](https://osmdata.openstreetmap.de/data/land-polygons.html), `land-polygons-split-4326`, data of 2026-10-31 | ODbL 1.0 |
| Lakes, rivers, reservoirs, canals | OpenStreetMap water through Overture Maps `theme=base/type=water`, release `2026-10-21.0`. Checked: all 66,814,038 features in that release list OpenStreetMap as their only source | ODbL 1.0 |

**The pack is treated as a Derivative Database** (2026-11-03). The OSMF's Produced Work guideline says a raster image is
usually a Produced Work, but it also says that something published for extraction, or a dump, is a database, and a
tile grid in a public repository can be read back as data. So the safer reading is the one this project follows:

- The pack is under the ODbL, stated in `WorldShore.LICENSE.txt` beside it and in `META` (ODbL 4.2).
- The pack is free to download as a release asset of this repository, and its generator and pinned inputs are in the
  repository (ODbL 4.6). So a release asset must be published before an app using that pack ships, and is never removed.
- Nothing but ODbL-compatible data goes in the pack (ODbL 4.4d). Natural Earth, climate and the rest stay in other
  files, used side by side. Fernlet's code is not covered (ODbL 2.3a).
- The fog and Your world as drawn are Produced Works, and carry the on-map credit below (ODbL 4.3).

**Attribution.** The OSMF's guideline puts the credit in a corner of the map, adjacent to it, or on a splash screen, and
says a person should not have to interact to see it. So each map that draws this data shows a small
"© OpenStreetMap" beside Apple's credit, linked to <https://www.openstreetmap.org/copyright>. Settings → Privacy &
data → Acknowledgments, `NOTICE` and the site carry the longer form. Any screenshot or marketing image showing the fog
needs the credit visible too.

**Still open for a person, not settled by the guidelines:** whether App Store FairPlay reaches a resource file and
whether Apple's end-user terms count as further restrictions (ODbL 4.7, 4.8; the public release asset is
the unrestricted parallel copy 4.7b asks for), and whether to ask legal-questions@osmfoundation.org about the
classification. This is a working reading, not legal advice.

## The plan (owner, 2026-11-02)

| Layer | Where | Level per 0.1° cell | Smallest water kept |
| --- | --- | --- | --- |
| Coast | Everywhere | 128 × 128 (about 75 × 87 m at 30°N) | |
| Water | Everywhere else | 64 × 64 (about 150 × 174 m) | 1 hectare |
| Water | Canada, Norway, Sweden, Finland, Russia, China and Alaska, except a 1° square holding a place of 100,000 or more | 32 × 32 (about 300 × 350 m) | 100 hectares |

A square's country is the most common one on a 5 × 5 sample of the atlas's `CTRY`; Alaska is the US north of 51°N and
west of 129°W; a place is a `CITY` row of size class 1 or more.

**What counts as water.** A polygon of `base/water` with any subtype but `ocean`, `human_made`, `physical` and `spring`,
and not `water/wastewater`, `wastewater/sewage` or `water/fairway`. **Seasonal water is left out** (owner, 2026-11-03):
`is_intermittent` is false, so a dry riverbed stays land, and Lake Eyre does too (the atlas's `LAND` keeps counting it as
water for the passport). Water below ground (`level` under 0) is left out. A water cell whose centre lies at sea is
dropped, since the coast already answers there.

## File layout (all integers little-endian)

```
magic        "FWS1" (4 bytes)
version      u16 = 1
coastLevel   u16 = 128
tableStored  u32
tableRaw     u32
overStored   u32
metaLength   u32
table        tableStored bytes of raw DEFLATE (RFC 1951)
overview     overStored bytes of raw DEFLATE
meta         metaLength bytes of UTF-8 JSON (licence, sources, plan)
bodies       the stored tiles' xz streams, one after another
```

### Tiles

The world is 64,800 tiles of 1° × 1°. `index = (89 - floor(lat)) * 360 + (floor(lon) + 180)`, so tile 0 is the north-west
corner, and a tile covers its floor latitude up to the next. Longitude is normalised to [-180, 180).

### `table`

Decompressed, `tableRaw` bytes:

```
coastKind[64800]  u8: 0 all water, 1 all land, 2 stored
waterCode[64800]  u8: 0 no water, 1 stored at level 32, 2 stored at level 64
lengths[n]        u32: each stored tile's xz length, coast tiles in index order, then water tiles in index order
```

A tile's offset is the sum of the lengths before it, counted from the start of `bodies`. A reader refuses a wrong magic
or version, a `coastLevel` other than 128, an unknown kind or code, `tableRaw` other than `129600 + 4n`, and lengths that
do not exactly fill the file.

### `overview`

Decompressed, 259,200 bytes: 360 rows × 720 columns of half-degree cells from the north-west, each how much of the cell is
land after water is taken out, 0–255. It answers Your world's World and Country levels without opening a tile.

### A stored tile

An xz stream (`lzma` with `FORMAT_XZ`, `CHECK_NONE`, LZMA2 preset 6 with a 256 KiB dictionary), which Apple's
`COMPRESSION_LZMA` decodes. Decompressed:

```
state[100]       u8 per 0.1° cell, row by row from the north-west: 0 none, 1 all, 2 mixed
masks            level × level bits per mixed cell, in cell order, (level × level) / 8 bytes each
```

Inside a mixed cell: `sx = floor(fracCol * level)`, `sy = floor(fracRow * level)` with both fractions measured from the
cell's north-west corner, `bit = sy * level + sx`, byte `bit >> 3`, bit `bit & 7` (least significant first). A set bit means
land in a coast tile and water in a water tile.

## The rule the reader applies

`isLand(at:)` is true when the coast tile says land and the water tile does not say water at that point. A lookup decodes at
most two tiles, and only when they are not already in a small bounded cache, so a hex's answer costs one or two bit reads
in the usual case. The pack maps the file (nothing is read until a tile is asked for), so opening it costs the table only.

## Measured

The 2026-11-03 pack is 29,960,467 bytes (29.96 MB, 28.57 MiB): 6,893 stored coast tiles, 10,074 water tiles at 64 and 5,629
at 32, a 47 KB table and a 45 KB overview, from 5,874,204 water polygons. 6,608 of the 26,776 tiles holding land are cut.
Without the cut, all water of 1 hectare or more at 64 × 64 is 35.1 MB by itself (Canada 14.5, Russia 5.6, the US 2.8).

## Regenerating

```bash
Scripts/world-atlas/fetch-shore-sources.sh
```

```bash
python3 Scripts/world-atlas/build_world_shore.py
```

It needs `numpy` and `pyarrow`, about 30 GB of disk for the sources and 15 GB of work files, and about ten minutes. Then
publish the pack as a NEW release (`world-shore-v2`, …), and move the tag and hash in `Scripts/fetch-world-shore.sh` and
`WorldShoreMask.expectedSHA256` in the same commit. An asset is never replaced in place.
