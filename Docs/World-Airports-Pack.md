# WorldAirports.pack

The bundled airport list behind World's airports (World-Airports-Spec §1–§2): every large and medium airport as an
unlockable, every IATA-coded airport as a point an imported flight can draw an arc to, each airport's time zone, and a
small airline table. It's its own file, never part of `WorldAtlas.pack`, so the atlas keeps its headroom under its
7 MiB cap. Nothing is downloaded on the phone.

- **File:** `App/Fernlet/World/Atlas/WorldAirports.pack`, 514,360 bytes (cap 1 MiB), SHA-256 pinned in
  `WorldAirports.expectedSHA256`.
- **Generator:** `Scripts/world-atlas/build_world_airports.py`; its self-test is `airports_selftest.py`.
- **Sources:** `Scripts/world-atlas/fetch-airport-sources.sh` (sizes and SHA-256 pinned).
- **Reader:** `FernletKit/Sources/WorldMapStore/WorldAirports.swift`.

## Sources and licences

| Source | Used for | Licence |
|---|---|---|
| OurAirports `airports.csv`, `runways.csv` | airports, codes, positions, runway ends | Public domain |
| Wikidata snapshots (queries in `Scripts/world-atlas/airport-queries/`) | Spanish airport names; English and Spanish served-city names | CC0 |
| tzdata `zone.tab` (this Mac's `/usr/share/zoneinfo`, version in META) | each airport's IANA zone | Public domain |
| `airlines.json` (hand-made) | ICAO ↔ IATA ↔ names | ours |
| `airport-outlines.json` (hand-kept) | our own approved outlines (§2.1) | ours, traced from open imagery |

Never used: OpenStreetMap or Overture in any form, OpenFlights (ODbL), Apple, Google or Bing imagery.

The owner OK'd the OurAirports download with screen 14 and the Wikidata queries in chat (2026-10-30). A Wikidata
query's answer changes as Wikidata is edited, so a re-fetch is a new snapshot: run `fetch-airport-sources.sh --record`
and pin the new hashes in the same commit as the pack they build.

## Rules

- **Unlockables:** OurAirports' `large_airport` and `medium_airport`, any `scheduled_service` (the owner wanted all of
  them, military and private fields included): 5,280 (1,176 large). Closed airports are left out, and so is any row in
  the generator's `DATA_ERRORS` (one so far: VE-0526, a misplaced duplicate of Caracas placed in Chad).
- **Points:** every airport with a three-letter IATA code, of any type but closed: 9,052. An IATA code on two airports
  keeps the first and is logged.
- **Tokens:** an unlockable's passport token is frozen in `airport-tokens.json` (OurAirports id → token) the first time
  it's built: its IATA code, else its ident. A later data update never changes or reuses one, so it can't make a second
  stamp. A new airport stops the run until `--record-tokens` freezes it.
- **Names:**
  - English: OurAirports' name without "Airport"/"Aerodrome"/"Airfield" ("Portland International"), or the
    nickname list (`NICKNAMES`: Heathrow, O'Hare, Narita…, a draft for the owner).
  - Spanish: Wikidata's Spanish label without its leading "Aeropuerto (de)" ("Internacional de Portland"). It's empty,
    so the reader shows English, where there's none.
  - City: the Wikidata served city whose English name is the airport's municipality, else the one the airport's own name
    mentions first ("Naples International" → Naples / Nápoles), else the municipality without its qualifiers. A served
    place the name doesn't mention (a state, a district) is never taken.
- **Time zones:**
  - A hand list of airports in regions that split (`ZONE_BY_AIRPORT`: the Florida panhandle, east Tennessee, the far
    Aleutians…).
  - Then region tables for the US, Canada, Australia and Brazil (`ZONE_BY_REGION`).
  - Elsewhere, the nearest `zone.tab` point in the airport's country.
  - Every zone must exist in tzdata. Any airport more than three hours from its longitude's sun time is logged for
    review (none left in the shipped pack).
- **Grounds** (§2):
  1. An approved outline from `airport-outlines.json`. A record without an approval stops the run.
  2. Otherwise the convex hull of the airport's open runway ends, each widened by 500 m as a 16-sided circle, then
     simplified at 50 m (median 12 points, at most 64). The airport's own point joins the hull, so its grounds
     always hold it (25 reference points sit more than 500 m from their runways).
     - A runway end over 8 km from the airport is a data error and is skipped.
     - Airports above 80° latitude keep the circle.
  3. With no usable runway end, a 1.5 km circle: 812 airports.
- **Our own outlines** (1122 so far: batches 1–2, 107, reviewed by the owner on review pages; batches 3 on, 1015, under
  the owner's blanket approval of 2026-10-31, "I don't need to review it", each flagged `unsure` where its tracer was): each is seeded from the US
  Census TIGER/Line 2015 "Airport or Airfield" polygon, CORINE Land Cover 2018 class 124, or the runways, then traced by eye
  on open imagery (USGS The National Map; Sentinel-2 cloudless 2016 by EOX, CC BY 4.0; or Copernicus Sentinel-2 L2A and
  NASA GIBS HLS for airports newer than 2016) with `draft_airport_outlines.py`. The owner's rules: runways, taxiways,
  terminals, aprons, car parks (distant ones too), and bases and maintenance sites inside the fence; past every runway
  end across the cleared ground to the perimeter road; never houses, public roads beyond the perimeter or uncleared
  forest. META lists each outline's picture and seed credit (`outlineCredits`).

## Layout

The atlas container (`magic · u16 version · u16 sectionCount · 16-byte table rows · raw DEFLATE bodies`) with magic
`FAP1` and version 1. All integers are little-endian. A short text is `u8 length · UTF-8`.

| Tag | Holds |
|---|---|
| `TZNS` | `u16 count`, then short texts: IANA zone names, indexed by the other sections |
| `APTS` | `u16 count`, then per unlockable, sorted by token: token, IATA (empty if none), ident (short texts) · `i32 lat`, `i32 lon` (1e-5°) · 2 ASCII country · `u8 size` (1 large, 2 medium) · `u16 zone` · English name, Spanish name, English city, Spanish city (short texts, the Spanish ones empty when they'd repeat the English) · `u8 grounds` (0 circle: `u16 radius m`; 1 runways or 2 our outline: the atlas ring, `u32 pointCount · i32 lon · i32 lat · zigzag-LEB128 deltas`) |
| `PNTS` | `u16 count`, then per IATA point, sorted by code: 3 ASCII code · `i32 lat`, `i32 lon` · 2 ASCII country · `u16 zone` · `u16` unlockable index (0xFFFF: points only) |
| `AIRL` | `u16 count`, then 3 ASCII ICAO · 2 ASCII IATA · short text names joined by "\|" |
| `META` | JSON: generator, version, date, tzdata version, every source's file, URL, SHA-256 and licence (optional) |

Sizes as shipped (raw → stored): TZNS 6 KB → 2.5 KB, APTS 595 KB → 375 KB, PNTS 154 KB → 107 KB, AIRL 2 KB → 1 KB.

## Rebuilding

```bash
Scripts/world-atlas/fetch-airport-sources.sh
python3 -I Scripts/world-atlas/airports_selftest.py
python3 -I Scripts/world-atlas/build_world_airports.py --sources ~/Library/Caches/Fernlet/atlas-sources \
    --out App/Fernlet/World/Atlas/WorldAirports.pack --date YYYY-MM-DD
```

Then pin the printed SHA-256 in `WorldAirports.expectedSHA256` in the same commit.
