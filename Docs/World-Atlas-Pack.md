# World atlas pack (round 7, ideas 1, 2, 4, 7, A and B)

The bundled data and the engines under the World exploration ideas
([World-Exploration-Ideas-2026-10-28.md](World-Exploration-Ideas-2026-10-28.md)). No screens: the design session
approves those first. This file is the contract between the generator (`Scripts/world-atlas/`) and the Swift reader
(`FernletKit/Sources/WorldMapStore/WorldAtlas*.swift`).

## Where it lives and what it may do

- **Bundled, never fetched.** `App/Fernlet/World/Atlas/WorldAtlas.pack` ships inside the app (a synchronized folder,
  so no project-file edit). The app opens no connection for it; the no-tracking wall gains no destination
  ([No-Tracking-Wall.md](No-Tracking-Wall.md)). Only the build machine fetches the sources, once, with the owner's
  OK, through `Scripts/world-atlas/fetch-sources.sh` (pinned URLs and SHA-256s).
- **Size cap: 6 MiB** (6,291,456 bytes) for the whole file. The generator refuses to write a bigger pack, and
  `WorldAtlasPackTests` fails one.
- **Checksum.** `WorldAtlasPack.expectedSHA256` pins the shipped file's SHA-256. Regenerating the pack changes it
  on purpose, in the same commit.

## Sources

| Layer | Source | Licence | Credit |
| --- | --- | --- | --- |
| Land, minor islands | Natural Earth 1:10m `ne_10m_land`, `ne_10m_minor_islands` | public domain | none required (Fernlet credits it anyway) |
| Oceans | Natural Earth 1:10m `ne_10m_geography_marine_polys` | public domain | none required |
| Countries | Natural Earth 1:10m `ne_10m_admin_0_countries` | public domain | none required |
| Cities | Natural Earth 1:10m `ne_10m_populated_places` + `ne_10m_urban_areas` | public domain | none required |
| Climate | Beck et al. (2018) Köppen-Geiger 1-km maps, `Beck_KG_V1_present_0p083.tif` | CC BY 4.0 | required: see Acknowledgments |

## File layout (all integers little-endian)

```
header   magic "FWA1" (4 bytes) · version u16 = 1 · sectionCount u16
table    sectionCount × { tag 4 ASCII bytes · offset u32 · storedLength u32 · rawLength u32 }
bodies   each section's bytes, raw DEFLATE (RFC 1951, no zlib header: Python zlib wbits=-15,
         Apple Compression COMPRESSION_ZLIB)
```

Offsets count from the start of the file. A reader refuses: a wrong magic or version, a section past the end, a
`rawLength` over 64 MiB, a decompressed length that differs from `rawLength`, or a missing required section.

### The grid

Every raster section uses one global grid, whose size the `LAND` header states: `cols = 2 × rows`, a cell
`180° / rows` on a side. The shipped pack uses **0.1°** cells (`cols = 3600`, `rows = 1800`); tests build small
grids. Row 0 is the band just south of 90°N; column 0 starts at 180°W. With `step = 180 / rows`:

```
row = clamp(floor((90 - lat) / step), 0, rows - 1)
col = floor((lon + 180) / step) mod cols        (lon normalised to [-180, 180))
index = row * cols + col
```

`CLIM`, `OCEA` and `CONT` are each exactly `cols × rows` bytes on the same grid.

### `LAND`: water and land

```
u32 cols · u32 rows · u16 sub (= 16)
u8 state[cols*rows]           0 water · 1 land · 2 coast (mixed)
u32 coastCount
coastCount × 32 bytes         a 16×16 bit mask per coast cell, coast cells in index order
```

Inside a coast cell: `sx = floor(fracCol * 16)`, `sy = floor(fracRow * 16)` with both fractions measured from the
cell's north-west corner; `bit = sy * 16 + sx`; byte `bit >> 3`, bit `bit & 7` (least significant first);
1 = land. A sub-cell is about 700 m at the equator, the source's own precision. Land is Natural Earth land plus
minor islands; lakes inside land are land (inland water is not an ocean).

### `CLIM`: climate

`u8 class[cols*rows]`, Beck's Köppen-Geiger codes 1–30 (1 Af … 29 ET, 30 EF), 0 where there is no land. Each cell is
the majority of the source cells inside it; a land or coast cell the source misses takes the nearest class within
5 cells, else 0.

### `OCEA`: oceans and seas

`u8 body[cols*rows]` for every water or coast cell: 0 none (land, or water not joined to the sea, such as the
Caspian and lakes), 1 Pacific, 2 Atlantic, 3 Indian, 4 Arctic, 5 Southern, and `6 + i` for sea `i` of the `SEAS`
table (at most 250 seas).

**Seas are their own passport entries** (owner, 2026-10-29): being on the Caribbean counts the Caribbean Sea, not
the Atlantic. Natural Earth draws each sea as its own polygon beside the ocean polygons, which is what tells them
apart. The labels:

1. A cell inside a marine polygon whose `featurecla` is `ocean` takes that ocean (North and South Pacific are both
   Pacific, and so on).
2. A cell inside a polygon whose `featurecla` is `sea`, or one of the large gulfs and bays the generator promotes to
   seas (its `PROMOTED_SEAS` table: the Gulf of Mexico, Hudson Bay, the Bay of Bengal, the Persian Gulf), takes that
   sea.
3. South of 60°S, any water labelled an ocean is the Southern Ocean (its IHO limit), so a ship in the Drake
   Passage is on the Southern Ocean; a sea keeps its own label.
4. Every other water cell (smaller bays, gulfs, straits, channels, sounds, and water no polygon names) takes the
   label of the nearest labelled cell joined to it by water, so the Bay of Biscay is Atlantic and the Gulf of
   Bothnia is the Baltic Sea.

### `SEAS`: the seas

```
u16 count
count × {
  u8 len · bytes    token: the Wikidata ID, else "ne:<ne_id>" (frozen)
  u8                parent ocean code (1–5), for display only ("a sea of the Atlantic"); it never counts the ocean
  u8 len · bytes    name (English, UTF-8), then es, fr, de (len 0 = use English)
}
```

### `CONT`: continents

`u8 continent[cols*rows]` for every land or coast cell: 0 none, 1 Africa, 2 Antarctica, 3 Asia, 4 Europe,
5 North America, 6 Oceania, 7 South America. From the country under the cell, with the landmass overrides the
generator lists (Russia east of 60°E, Anatolia and Sinai are Asia; Hawaii is Oceania). Antarctica's lighter rule is
the reader's, not the grid's.

### `CTRY`: countries

```
u16 count
count × {
  2 ASCII  code         ISO 3166-1 alpha-2 of the territory (Natural Earth ISO_A2_EH), the frozen token
  2 ASCII  sovereign    the sovereign state's alpha-2 (a territory counts toward it in "N of 195")
  u8       continent    the continent code above (the country's own, for display)
  u8       flags        bit 0: one of the 195 (193 UN members, the Holy See, Palestine)
  i32 × 4  bbox         minLon, minLat, maxLon, maxLat in 1e-5 degrees
  u16      ringCount
  ringCount × { u32 pointCount · first point i32 lon, i32 lat · (pointCount-1) × zigzag-LEB128 deltas lon, lat }
}
```

Rings use the even-odd rule (holes are rings too). Coordinates are in 1e-5 degrees, simplified (Douglas-Peucker)
at 0.001°.

### `URBN`: urban boundaries

`u32 count`, then per polygon: the same `bbox · ringCount · rings` encoding as `CTRY`. Only polygons holding at least
one city are kept.

### `CITY`: cities

```
u32 count
count × {
  u8 len · bytes    token: the Wikidata ID ("Q90"), else "ne:<ne_id>" (frozen)
  2 ASCII           country alpha-2
  u8                size class: 0 town, 1 city (≥ 100k), 2 large (≥ 1M), 3 mega (≥ 10M)
  u32               population (POP_MAX)
  i32 · i32         lon, lat in 1e-5 degrees
  i32               urban polygon index, -1 for none
  u8 len · bytes    name (English, UTF-8), then the same for es, fr, de (len 0 = use English)
}
```

### `META`

UTF-8 JSON: the generator version, the generation date, and each source's file name, URL, SHA-256 and licence.

## The rules the reader applies

- **Accepted fixes only.** The keeper reads a fix only after `WorldFogKeeper` accepts it (precise, accurate to
  65 m, "Uncover the map as you go" on), only while the phone is unlocked, and never in a decoy (a decoy keeps
  nothing).
- **Country:** the fix lies inside the country's rings.
- **Continent:** the `CONT` cell under a land fix, plus Antarctica's lighter rule below
  (`WorldAtlas.antarcticaLatitude`).
- **Ocean or sea:** the nearest water sub-cell within `WorldAtlas.oceanReachMetres` (2 km, owner 2026-10-29) of the
  fix; its `OCEA` code names an ocean or a sea, never both.
- **Antarctica** (owner 2026-10-29): any accepted fix south of 60°S, the Antarctic Treaty area, on land, on ice or at
  sea.
- **City:** inside an urban polygon, the nearest of the cities that share it; a city with no polygon is entered
  within `WorldAtlas.townRadiusMetres` of its point.
- **Terrain:** water or land from `LAND`, a class from `CLIM` and the latitude, flora from the class, the latitude
  and (for cacti) the Americas.
