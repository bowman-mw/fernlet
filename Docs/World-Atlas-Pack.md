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
| States and provinces | Natural Earth 1:10m `ne_10m_admin_1_states_provinces` (owner's OK 2026-10-29) | public domain | none required |
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
  2 ASCII  sovereign    the sovereign state's alpha-2 (a territory counts toward it in "N of 194")
  u8       continent    the continent code above (the country's own, for display)
  u8       flags        bit 0: one of the passport's 194 (193 UN members, the Holy See, Palestine, without North Korea: owner 2026-10-29)
  i32 × 4  bbox         minLon, minLat, maxLon, maxLat in 1e-5 degrees
  u16      ringCount
  ringCount × { u32 pointCount · first point i32 lon, i32 lat · (pointCount-1) × zigzag-LEB128 deltas lon, lat }
}
```

Rings use the even-odd rule (holes are rings too). Coordinates are in 1e-5 degrees, simplified (Douglas-Peucker)
at 0.001°.

**Territory override: Crimea counts as Ukraine** (owner, 2026-10-29). Natural Earth's default admin-0 draws
Crimea, Sevastopol with it, as Russia's: a separate part of RU's multipolygon (one 424-point ring, its northern
border with Kherson 46 vertices that Ukraine's ring shares exactly), and files Crimea's two admin-1 rows (`UA-43`,
`UA-40`) under `ADM0_A3` RUS. The generator's `TERRITORY_OVERRIDES` has one entry for it: every RU ring lying
wholly inside lon 32.3..36.75, lat 44.2..46.3 moves to UA and is stitched into the Ukrainian ring it shares that
border with (the shared run dropped, one ring left), before simplification, so the coast and the isthmus are
simplified once and no sliver between two outlines exists. The run stops unless a ring moves and Simferopol,
Sevastopol (44.60, 33.52) and Yalta then lie in UA and in no RU ring. Measured on a 0.005° lattice over Crimea's
source admin-1 outlines (124,328 points): 124,322 UA, 0 RU, 6 in no country (coast where the admin-1 and admin-0
outlines differ); over the isthmus band (lat 45.9..46.3, on the source's land, 28,604 points) 28,602 UA, 0 RU,
2 none, the same 2 as before. `CONT` is byte-for-byte unchanged (Europe either way). Sevastopol's listed centre
(44.6166, 33.5254) and Kherson's (46.6354, 32.6169) fall in water the 10m land leaves open (Sevastopol Bay, the
Dnieper), before and after: no country there, the Black Sea, still the city.

### `URBN`: urban boundaries

`u32 count`, then per polygon: the same `bbox · ringCount · rings` encoding as `CTRY`. A polygon is kept when at
least one city's point lies within that city's **reach** (below, "City") of the polygon's bounding box, measured
flat-earth with a degree of longitude taken at the most poleward latitude of the box and the point, so the distance
is never overstated; a polygon holding a city's point is always kept. Natural Earth cuts a metro area into
fragments that do not follow its cities (New York's Brooklyn and Queens fragment holds no city's point), so keeping
only the polygons that hold a point lost whole boroughs. A fix inside a polygon lies inside its box, so every city
the reader could find in reach of such a fix is in reach of the box. The 2026-10-29 pack keeps 4,393 of 11,878
polygons (1,056 of them for a city in reach only); `URBN` stores 0.62 MB of the pack.

### `CITY`: cities

```
u32 count
count × {
  u8 len · bytes    token: the Wikidata ID ("Q90"), else "ne:<ne_id>" (frozen)
  2 ASCII           country alpha-2
  u8                size class: 0 town, 1 city (≥ 100k), 2 large (≥ 1M), 3 mega (≥ 10M)
  u32               population (POP_MAX)
  i32 · i32         lon, lat in 1e-5 degrees
  i32               urban polygon index: the kept polygon holding the city's own point, -1 for none (for the
                    screens to draw; the city rule does not read it)
  u8 len · bytes    name (English, UTF-8), then the same for es, fr, de (len 0 = use English)
}
```

### `ADM1`: states and provinces

For the world view's State and City zooms (World-Exploration-Spec, "The world view", answer 13): the state and
province lines and the plate's place ("Oregon · United States", "England · United Kingdom"). **No county data,
ever.**

```
u16 groupCount                           the plate groups (below)
groupCount × {
  u8 len · bytes    token: the region's ISO 3166-2 code ("GB-ENG"), else "ne:region:<country>:<slug>" (frozen;
                    at most 64 bytes; the slug is the English name in lower-case ASCII letters, digits and hyphens)
  2 ASCII           country alpha-2: a CTRY code
  u8 len · bytes    name (English, UTF-8; never empty)
  u8 len · bytes    Spanish name (len 0 = use English)
}
u16 count
count × {
  u8 len · bytes    token: the ISO 3166-2 code ("US-OR"), else "ne:<ne_id>" (frozen; at most 24 bytes)
  2 ASCII           country alpha-2: a CTRY code (the territory, as CTRY counts it)
  u8 len · bytes    name (English, UTF-8; never empty)
  u8 len · bytes    Spanish name (len 0 = use English)
  u16      group    index into the plate groups, 0xFFFF: the entry is its own plate group
  i32 × 4  bbox     minLon, minLat, maxLon, maxLat in 1e-5 degrees
  u16      ringCount
  ringCount × { u32 pointCount · first point i32 lon, i32 lat · (pointCount-1) × zigzag-LEB128 deltas lon, lat }
}
```

Entries are sorted by country, then token. The rings are the `CTRY` encoding (even-odd, 1e-5 degrees), simplified
(Douglas-Peucker) at **0.008°** (about 890 m, under 3 pt at City's 360 pt a degree and under a third of its 10-pt
hex); a ring that would vanish is kept at a tenth of the tolerance, then unsimplified, as in `CTRY`. 0.003° (1 pt
at City) would make a 6.7 MB pack and 0.005° leave 130 KB under the cap, so the shipped pack takes 0.008°.

- **Token.** `ISO_3166_2` when it is a real code (`CC-` and one to three capitals or digits; Natural Earth's own
  stand-ins, with a `~`, `-99-` or an `X` and digits, are not) and every feature carrying it has one name: several
  such features (a province Natural Earth cuts into pieces) merge into one entry. A code features of different
  names share stays with the largest only when it is at least 10 times the area of all the others together
  (`AU-NSW` stays New South Wales', not Lord Howe Island's; `CO-CUN` Cundinamarca's, not Bogotá's); otherwise it
  names none of them (Bosnia's nine cantons all say `BA-BIH`). Each name without the code is its own entry,
  `ne:<its smallest ne_id>`, as is every feature without a real code.
- **Country.** A territory override's country for the codes it lists (Crimea `UA-43` and Sevastopol `UA-40` are
  UA), else the feature's `ADM0_A3` mapped exactly as `CTRY` maps admin-0 (so Somaliland is SO and Kosovo XK),
  else its own `ISO_A2` when `CTRY` has it; the generator logs every disagreement. Each entry's label point lies in
  its own country's `CTRY` rings (checked 2026-10-29: none in another country). A feature with no `CTRY`
  country (Dhekelia, Akrotiri, Guantánamo Bay, Kashmir, the Spratlys), no rings or no name (seven unnamed islets)
  is left out: a fix there names only its country.
- **Names.** English from `NAME_EN`, else `NAME`; Spanish from `NAME_ES`, stored empty when it equals the English.
  France's entries are its départements ("Paris"), as Natural Earth draws it.
- **Everyday names** (owner, 2026-10-29). Regions are named the way people say them in everyday English: "Madrid ·
  Spain", "Bavaria · Germany", never the official long form ("Community of Madrid", "Free State of Bavaria"). A
  designation ("Community of", "Region of", "Republic of", "Emirate of", "Prefecture", "State", "Krai", ...) goes
  only where an everyday name exists without it, and stays where the rest would be an adjective ("Silesian
  Voivodeship", "Western Province", "Nenets Autonomous Okrug"), a common word ("Free State", "Rivers State") or
  another place's name ("State of Mexico", "Niger State", "Mali Prefecture", "Davao Region"). No name is invented:
  each short form is the feature's own `NAME`, `NAME_ALT` or `NAME_ES`, or a hand-written entry. Spanish follows the
  same style ("Madrid", "Baviera", "Cataluña", "Escocia"). The rule is written at the top of the generator's
  hand-written names (`PLATE_GROUPS`) and covers them all, and Natural Earth's own names through
  `EVERYDAY_AFFIXES` (per country: AE "Emirate of", RU "Republic of" and "Krai", JP, GN and CF "Prefecture", NG,
  MM, FM and VE "State", SG "Community Development Council"; a trailing one only when the rest is the feature's
  own short name) and `EVERYDAY_NAMES` (by code: Madrid, Bremen, Crimea, Chechnya, Chuvashia, Udmurtia, Yakutia
  and others, plus four of Natural Earth's broken names repaired from the feature's own fields: "Jewish", "of
  Bougainville", "Archipelago of Saint Andréws", and "Altai Republic" on Altai Krai). The owner's American-style
  picks (2026-10-30: "Go with Valencia and Kyiv city"): "Valencia" (not "Valencian Community"), "Kyiv City" and
  "Kyiv Oblast" (Natural Earth names both "Kyiv"), "Cordillera", "Yakutia", and Japan's names without the Hepburn
  macrons, in English and Spanish ("Kyoto", "Osaka", "Hokkaido"; `MACRONS_DROPPED`). A macron that is a letter of
  the place's own language stays (Latvian "Jūrmala", Māori "Manawatū-Whanganui"). A Spanish name that is a
  designation and then the English name ("Municipio de Wandsworth", "Krai de Krasnodar") becomes the name alone.
  The 2026-10-30 pack changes 175 English and 366 Spanish entry names.
- **Plate groups** (coordinator, 2026-10-29). Where Natural Earth's admin-1 is a second-level unit, the plate and the
  state lines use the first-level region; the polygons are not dissolved, each entry just names its group. The
  generator's `PLATE_GROUPS` table gives, per country, the source field naming the region and each value's ISO
  3166-2 code and English and Spanish names (hand-written; Natural Earth has no Spanish region names); an
  `iso:<code>` key places a feature by its own code first. Every other country's entries are their own groups.
  Its names follow the everyday-names rule ("Brussels", "Madrid", "Murcia", "Valencia", "Ilocos", "Bicol",
  "Cordillera", "Uva"; "Bisayas Occidentales" in Spanish). The Philippine codes and members match Natural Earth's
  `REGION_COD` (its `REGION` text still says "ARMM" for Bangsamoro and "Dinagat Islands" for Caraga); Burkina
  Faso's `REGION_COD` is empty, so its `BF-01`..`BF-13` codes are ISO 3166-2's, not the source's, and neither
  country's 2024–2025 changes (the Negros Island Region, Burkina's new regions) are in the source.
  The countries, chosen because ISO 3166-2's first level is the region and Natural Earth's admin-1 sits under it:

  | Country | Natural Earth's admin-1 | Plate group | From |
  | --- | --- | --- | --- |
  | GB | 232 council areas | England, Scotland, Wales, Northern Ireland (`GB-ENG`…) | `GEONUNIT` |
  | FR | 101 départements | 13 metropolitan regions (`FR-IDF`…); the 5 overseas regions and Clipperton stay their own | `REGION_COD` |
  | IT | 110 provinces | 20 regions (`IT-62` Lazio…) | `REGION_COD` |
  | ES | 52 provinces | 17 autonomous communities and 2 cities (`ES-MD`…) | `REGION` |
  | IE | 34 counties and cities | Leinster, Munster, Connacht, Ulster (`IE-L`…) | each county's own code |
  | BE | 10 provinces and Brussels | Flanders, Wallonia, Brussels (`BE-VLG`…) | `GEONUNIT` |
  | PH | 118 provinces and cities | 17 regions (`PH-00` Metro Manila…) | `REGION_COD` |
  | UG | 112 districts | 4 regions (`UG-C`…) | `REGION` |
  | LK | 25 districts | 9 provinces (`LK-1`…) | `REGION_COD` |
  | GN | 34 prefectures | 8 regions (`GN-B`…) | `REGION_COD` |
  | BF | 45 provinces | 13 regions (`BF-01`…) | `REGION` |
  | MW | 28 districts | 3 regions (`MW-C`…) | `REGION`, two districts by code |

  Considered and left as they are: Slovenia, North Macedonia, Latvia, Malta and Azerbaijan, whose ISO 3166-2
  first level is the municipality Natural Earth draws (its `REGION` there is a statistical region); Japan,
  Russia, Vietnam and India, whose `REGION` groups first-level units into non-administrative regions. A
  region value the table does not list is logged and the entry stays its own group. The 2026-10-29 pack has
  117 groups holding 887 entries.

The 2026-10-29 pack has 4,554 entries over 239 countries (4,293 with an ISO token), 8,480 rings and 435,491
points; `ADM1` stores 2.02 MB of the 5.77 MB pack (5,771,019 bytes, 520 KB under the cap). A reader refuses a
count over 8,192, a token of the wrong shape or used twice, a country `CTRY` lacks, an empty English name and any
malformed outline. `ADM1` is required in version 1 (nothing has shipped).

### `META`

UTF-8 JSON: the generator version (3 since `ADM1`, 4 since its plate groups, 6 since the territory override and everyday names, 7 since Kyiv's pair and Japan's names without macrons), the generation date, both simplification tolerances, and each
source's file name, URL, SHA-256 and licence.

## The rules the reader applies

- **Accepted fixes only.** The keeper reads a fix only after `WorldFogKeeper` accepts it (precise, accurate to
  65 m, "Uncover the map as you go" on), only while the phone is unlocked, and never in a decoy (a decoy keeps
  nothing).
- **Country:** the fix lies inside the country's rings. **Crimea counts as Ukraine** (owner, 2026-10-29): a fix in
  Simferopol, Sevastopol or Yalta earns UA, and its plate reads Crimea's own admin-1 · Ukraine (`CTRY`, "Territory
  override").
- **Continent:** the `CONT` cell under a land fix, plus Antarctica's lighter rule below
  (`WorldAtlas.antarcticaLatitude`).
- **Ocean or sea:** the nearest water sub-cell within `WorldAtlas.oceanReachMetres` (2 km, owner 2026-10-29) of the
  fix; its `OCEA` code names an ocean or a sea, never both.
- **Antarctica** (owner 2026-10-29): any accepted fix south of 60°S, the Antarctic Treaty area, on land, on ice or at
  sea.
- **City** (owner's rule, 2026-10-29): each city has a **reach** and a **core** by its size class,
  `WorldAtlas.cityReachMetres` (town 5 km, city 10 km, large 20 km, mega 35 km) and
  `WorldAtlas.cityCoreRadiusMetres` (town 2 km, city 4 km, large 8 km, mega 12 km, the earlier "town radius"
  values, unchanged). A fix is in a city when either (a) it lies inside **any** urban polygon and the city's point
  lies within the city's reach of it, or (b) it lies within the city's core of its point, wherever the polygons
  are. The nearest candidate of both kinds wins (plain flat-earth distance, the longitude difference taken the
  short way round); no candidate, no city. Which polygon holds which city's point plays no part: the polygons only
  say "built-up". So Yankee Stadium (in the fragment holding Stamford's point) and Brooklyn (in one holding none)
  are New York, the CN Tower and central Copenhagen (in gaps between polygons) are Toronto and København by their
  cores, and the Bosphorus Bridge is Istanbul, not İzmit 90 km off. Nearest means nearest: a small town whose
  point is closer than a megacity's wins (Versailles stays Versailles). On land, only cities of the country under
  the fix count, so Castel Sant'Angelo is Rome's though the Holy See's point is nearer; a fix at sea counts every
  city. Bounded: the reader buckets the cities by one-degree cell once
  (`AtlasCityIndex`); a fix reads its own row and the rows either side, and as many columns either side as
  35 km spans half a degree poleward of it, at most 8 (so 51 cells; the cap covers the whole reach to about
  87°), and only when the nearest city in reach lies outside its own core does it make one pass over the urban
  polygons (each box tested before its rings). About 0.03 ms a fix, 0.1 ms a whole visit, on a Mac.
- **Terrain:** water or land from `LAND`, a class from `CLIM` and the latitude, flora from the class, the latitude
  and (for cacti) the Americas.
- **Landmark:** within the landmark's find radius of its point (below).
- **State or province** (`WorldAtlas.admin1(at:)`): the entry whose rings hold the fix, among only the entries of
  the country under it when `CTRY` has one there (each box first), else among all. The plate's
  `WorldAtlas.placeName(at:)` names that entry's plate group (`admin1Group(at:)`) and the country. No entry, no
  state: the plate names just the country, and at sea nothing.
- **Lines on hex edges** (`WorldAtlas.border(between:and:)`): each world-view hex is named by the place at its
  centre (`placeName(of:in:)`); an edge carries a country line where the two countries differ and a state line
  where, in one country, the two plate groups differ (so London's boroughs draw none between them), and nothing
  beside the sea or a side with no state. `AtlasZoomLevel.draws(_:)` shows country lines from Country and state
  lines from State.

## The world view's zoom ladder

World-Exploration-Spec, "The world view" (answers 9 and 13); `AtlasZoomLevel` and `WorldViewHexGrid` in
`WorldMapStore`. Frozen tokens `world`, `country`, `state`, `city`; City is the closest.

| Level | Points per degree of latitude | Country lines | State lines | Plate names the place | + | − |
| --- | --- | --- | --- | --- | --- | --- |
| World | 4.966 (mockup `worldFull`: 874 pt for 176°) | no | no | no | yes | no |
| Country | 20.70 | yes | no | no | yes | yes |
| State | 86.33 | yes | yes | yes | yes | yes |
| City | 360 (mockup `worldZoom`; about 270 km top to bottom) | yes | yes | yes | no | yes |

The mockup gives only World and City, so Country and State sit on a geometric ladder between them, each
`(360 / 4.966)^(1/3)` ≈ 4.17 times the one below. A level's scale holds at 45° (the fog grid's reference latitude;
Portland, where the mockup's City view sits) and is a fixed number of points per Web Mercator unit
(`pointsPerMercatorUnit`), so a level looks the same anywhere on the map.

**Hexes.** At every level a world-view hex is 10 pt across (flat side to flat side) on screen: a regular pointy-top
grid in Web Mercator at the level's scale, laid out and rounded as the fog's own `MercatorHexGrid` (about 3.1 km
across at City at 45°, 13 km at State, 54 km at Country, 224 km at World). A hex is uncovered when any lifted fog
cell's centre lies in it (`WorldViewHexGrid.uncovered(by:)`, at most `FogCellStore.maxCells` cells read), so the
one fog store drives every level.

**VoiceOver.** `WorldAtlas.zoomDescription(level:centre:)` gives the parts of the zoom control's words: the level's
token; at Country the country at the view's centre alone ("Country, United States"); from State the plate group's
names and the country code ("City, Oregon, United States"). The screen formats them.

## Landmarks

World-Exploration-Spec §2 (owner: two tiers, grey and unnamed through the fog before found, named once found).

- **Hand-written and bundled beside the pack, not in it.** `App/Fernlet/World/Atlas/WorldLandmarks.json` is a short
  list written by hand (never an OpenStreetMap import, never fetched), read by `WorldLandmarks` in `WorldMapStore`.
  The generator does not touch it; regenerating the pack leaves it as it is. A missing or refused file means no
  landmarks; the atlas and the passport carry on.
- **Format** (frozen keys): `{"version": 1, "landmarks": [...]}`, each entry:

  | Key | Meaning |
  | --- | --- |
  | `id` | the frozen token, lowerCamel ASCII, at most 64 bytes (`eiffelTower`); what the passport stores |
  | `en`, `es` | the English and Spanish names (the usual Spanish name, else the English one) |
  | `city` | the city's frozen atlas token, exactly as the shipped pack's `CITY` table has it (`Q90`) |
  | `lat`, `lon` | the landmark's point, in degrees |
  | `radius` | the find radius in metres, 50–600 (a tower about 150, a big park 250–400 from its centre) |
  | `art` | famous tier only: the art id, one of `WorldLandmarks.drawnArtIDs` (28, all approved 2026-10-29: `eiffel`, `empire`, `opera`, `colosseum` and the owner's 24 more), or a placeholder in `placeholderArtIDs` (none today) drawn with a generic stand-in until its art is approved |
  | `kind` | generic tier only: `park`, `bridge`, `lighthouse`, `stadium`, `castle` or `tower` |

  Exactly one of `art` or `kind`. The reader refuses the whole file for an unknown key, a missing field, a second
  use of an `id`, a bad name, token, point or radius, an unknown art id or kind, a version it does not read, more
  than 5,000 entries or more than 2 MiB. `WorldLandmarkTests` checks the shipped list against the shipped pack:
  every `city` is in `CITY`, and every point lies within 30 km of its city's point and in its city's country.
- **The find rule.** An accepted fix (the same fixes the rest of the passport reads) within a landmark's `radius` of
  its point finds it, measured flat-earth and the short way round the antimeridian; one fix finds at most 16. The
  passport keeps each landmark once, by its `id`, with the date of the first fix, reported after the city and before
  the terrain. Its city comes from the list, so the city card's "2 of 6 found" needs no second record. A decoy finds
  nothing.
