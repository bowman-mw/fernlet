# World: frequent paths and roads (exploration, 2026-11-15)

**Owner's ask:** "explore adding paths and roads for frequently used roads and paths."
**Status:** exploration only. Nothing is built. The owner picks an option and answers the calls in §7.

## 1. What the World records today

| Record | What it holds | Size of a unit | Kept | Sealed? | Wiped by |
| --- | --- | --- | --- | --- | --- |
| Walked fog (`FogCellStore`, `fog.bin`) | A **set** of hex cell IDs. No counts, no dates. | Hex about 35 m across (`MercatorHexGrid`, 17.5 m radius at 45°) | Forever, cap 250,000 cells (about 2 MB) | Yes, `WorldMapVault` (AES-GCM, device-only key, excluded from backup) | Delete map history, Delete Everything, duress lock |
| Driven fog (`DrivenFogStore`, `fog-driven.bin`) | A set of cells driven past but never walked. Bus and train (#162) count as drives. | 25 m lane either side, joined every 15 m | Forever | Yes, vault | Same |
| Drive line | **None.** `WorldRideWatch` keeps the last 10 minutes in memory only. A line is saved only for a bike ride with "Save new routes" on. | | | | |
| Walk, run and bike lines (`WorldRouteStore`, `route-<workout>.bin`) | One line per recorded outing, thinned at 2.5 m. **No timestamps** on the points. | About 1 m | Until the workout is deleted or "Delete all stored routes" is used. They outlive the 30-day timeline. Cap 2,000 lines. | Yes, vault | Same, plus route deletion |
| Road trips (`RoadTripLine`) | Timed line, a point at least every 25 m | About 1 m | Until map history is deleted. Cap 100 trips. | Yes, vault (buffer key) | Same |
| Where you've been (`PlaceLog`, `places.bin`) | 30-day timeline of stops, plus Places you return to with a `visits` count and no dates | A place | 30 days for the timeline; places until deleted | Yes, Private hub key | Same |

Settings that gate these: "Uncover the map as you go" (fog), "Save new routes" (`fernlet.worldMap.saveNewRoutes`, lines), "Remember places I stop at" (`fernlet.worldMap.rememberPlaces`, stops and visits only; it does not gate fog or lines).

**What friends get over the mesh:** only a road trip's road, sent in person to the people on that trip, for the stretch they were there for. Friends nearby carries no coordinates. `WorldMapStore` is walled off from `FernletSocial`, `CloudKitSync` and the AI modules by the build check.

**What this means for "frequent":**
- The fog cannot say how often you went somewhere. A cell walked 500 times looks the same as one walked once.
- **Walks, runs and bike rides can be counted with no new storage.** Lay the saved route lines over the hex grid and count passes per cell, at draw time.
- **Drives cannot be counted today.** No drive line is kept, and the driven set has no counts. Frequent roads need a new sealed counter.

## 2. Where the shapes could come from

| Source | What it gives | Size | Licence and walls | Verdict |
| --- | --- | --- | --- | --- |
| **The user's own saved lines** (walks, runs, rides) | The real path they took, about 1 m accurate | Already on the phone | Nothing new | **Best for footpaths** |
| **The user's own cells** (walked + driven, plus a new count) | A cell-by-cell road, drawn hex centre to hex centre | About 1 MB for a full counter (250k cells × about 4 bytes) | Nothing new, but a new sealed file and a policy sentence | **Best for roads**, if drives are wanted |
| **Natural Earth major roads** (already in `WorldAtlas.pack`, 767 KB) | Motorway, trunk and primary roads, simplified to about 110 m. `WorldCrossedRoads` already draws the ones you crossed. | Already bundled | Public domain | Good for "which big roads you use most"; misses every street and path |
| **Bundled OSM / Overture roads and paths** | Clean street and footpath shapes | Major roads worldwide likely tens to low hundreds of MB; all streets and footpaths would be gigabytes. The shore pack is already at its 30 MiB cap. | ODbL (like the shore pack: credit plus a public release asset) | **No.** Too big to bundle worldwide. |
| **OSM fetched by region at runtime** | Same shapes, only where you go | Small per region | New allowlist entry, pinned client, off-by-default switch, policy change. The request itself would tell a server where you are. | **No**, against the wall's spirit |
| **Apple MapKit** | Roads drawn by Apple | | The app keeps only `MKMapItem.identifier`. Taking geometry from Apple's tiles or pixels would break that rule. `MKDirections` is not used anywhere. | **No** |

There is no snap-to-road or map-matching code in the app. Douglas–Peucker already exists in Swift (`WorldRouteCodec`) and in the atlas builder.

## 3. How it could look

- **Footpaths (worn dirt).** A dirt line along your own walk line, snapped to the art pixel (2.19 m at full detail) with square caps. It darkens in three steps:
  - trodden (2–4 passes)
  - worn (5–14)
  - well-worn (15+), with a darker edge pixel
- **Roads (lit with use).** A grey road with a pale centre dash, from hex centre to hex centre along the cells you drive often. It brightens in steps (for example 3+, 10+, 30+ drives). The top step uses the amber of `WorldRoadStyle`, so it reads as a sibling of the crossed major roads.
- **Footpath vs road.** Dirt brown, about 2 art pixels wide, no dash, for footpaths. Grey with a dash, about 4 art pixels wide, for roads. There is no dirt colour today. New colours sit beside `WorldRoadStyle` and the terrain palettes, and Dark Mode mixes toward the night ink like the rest.
- **Fog.** Drawn **under** the fog in the first ground Canvas (`WorldGroundLayer`, between `drawRoads` and `drawTrails`), so a path shows only on uncovered ground. On driven-only cells (fog at 0.3 opacity) the road shows faintly through, which reads as "a road you've seen from the car".
- **Saved trails today.** The green 30-day trails would sit over the worn paths. Option: hide a trail where it lies on a worn path, so the map shows one line, not two.

**Zoom (Home):**
- Full detail (R ≥ 13 pt, about 300 m to 1.7 km camera): all tiers.
- Reduced detail (R 9.5 down to 3.4, up to the 7 km limit): drop the "trodden" tier and thin roads to 2 art pixels.

**Zoom (passport "Your world"):**
- Its finest hex is about 360 m and it never goes below about 24 m a point.
- Show only the top tier, as a 1 pt line clipped to uncovered hexes, from zoom 4 up. Or leave Your world out of version 1.

## 4. Performance and memory

- **Don't paint into the fog tiles.** Tiles cost about 1 MiB each, with about 120 MiB live (72 cached + 48 spare) and up to about 220 MB at 2×. Any path change would also dirty tiles.
- **Do copy the crossed-roads layer.** Build `WorldRoadDrawing`-like pieces off the main thread (as `WorldCrossedRoadsModel` does), keep only the newest request, and stroke them in the existing Canvas.
  - **Memory:** a few MB, with no bitmaps.
  - **Per frame:** about the cost of today's roads and trails. Cap the pieces; trail re-strokes are already flagged as growing with history.
- **Counting cost (estimate, not measured):** up to 2,000 lines, on the order of a million points, binned to cells once off the main thread at launch and again when a route is saved. Hundreds of ms in Release is likely; keep the result in memory only.
- **Release numbers are owed.** Every map figure measured so far is Debug or -Onone. Build-time gate: Release on the phone, fling and pinch with a full history.

## 5. Privacy

- **A frequent-routes map is a map of home, work and routine.** It must stay sealed, device-only, with the rest of the World: never synced, backed up, exported, given to the AI, or sent to friends.
- **Option A adds no stored data.** It is derived at draw time from the sealed route files, so "Delete all stored routes", Delete map history and Delete Everything already remove it.
- **Option B adds a sealed counter file** (`fog-passes.bin` or similar) in `WorldMapVault`. It needs:
  - an entry in `clearAll()`
  - an entry in `Docs/PrivacyWipeCoverage.md`
  - a privacy-policy sentence
- **Friends see nothing.** No wire change. A road trip still shares only that trip's road.
- **"Remember places I stop at"** stays about stops and visits. Worn paths follow "Save new routes" (walks); frequent roads follow background mapping (drives). A separate display switch, "Show worn paths", lets someone hide the layer when showing their phone to someone.
- **Widget:** the map widget's picture is not sealed (`WidgetMap.plist`, file protection only). Recommend it **never** shows worn paths or frequent roads.

**Privacy policy:**
- **A:** an optional clarifying clause in "Location and the map": "and draws the paths you walk most often from those lines".
- **B:** a required sentence. Draft: "If you turn on background mapping, Fernlet also counts how often you pass along each part of the map, with no dates, so the roads you use most can show on your map; it is encrypted on this iPhone with the rest of your map and deleted with it."

## 6. Options

| | What | New storage | Shapes | Recommendation |
| --- | --- | --- | --- | --- |
| **A. Worn footpaths** | Dirt paths from your saved walks, runs and rides that darken with use | None | Your own lines | **Recommended first step** |
| **B. A + frequent roads** | Also roads that brighten with repeat drives, bus and train | Sealed per-cell counter, about 1 MB max | Your own cells | Good second step, if the owner wants drives |
| **C. Big roads you use most** | Highlight Natural Earth major roads by how often you cross them | A small per-road count, or derive from B | Natural Earth (bundled) | Cheap add-on to B; too coarse alone |
| **D. Snap to OSM** | Clean bundled or fetched street and footpath shapes | Large pack, or a network fetch | OSM / ODbL | **Not recommended**: size cap and the no-tracking wall |

## 7. Owner's calls

1. Which option: A, A then B, or something else?
2. The pass thresholds for each tier (draft: 2 / 5 / 15 for paths, 3 / 10 / 30 for drives).
3. Should worn paths replace the green 30-day trails where they overlap, or sit under them?
4. Home only, or also the passport's Your world (top tier only)?
5. A "Show worn paths" display switch: on by default?
6. Keep worn paths out of the map widget? (Recommended: yes.)
7. For B: count only from now on (no backfill possible), and approve the policy sentence in §5.
8. Should a "worn path" count fade if unused for a long time? This needs dates, which A has none of. Recommended: no fading.

## 8. Owner's answers (2026-11-15)

Answered on the review page: calls 4 and 8. Calls 1, 2, 3, 5, 6 and 7 are still open (not saved).

- **Call 4, where:** walked paths on **Home only**. Roads can also show on **Your world**, if they are long enough.
- **Call 8, fading: yes.**
  - Every 30 days without travel on a path drops it one level.
  - At the bottom it does not disappear. It becomes an **abandoned path** (a fourth look).
  - The first time back on an abandoned path cleans it up to level 1.

**What the fading answer changes:**
- **Paths (A).** Route points have no times, but each route file is keyed by its workout ID, and the workout has `completedAt`. So a dated pass list can be derived per cell with nothing new stored. The level is then replayed in date order: +passes, −1 level per 30 idle days, floored at "abandoned", and a pass on an abandoned cell goes to level 1. The cost is finding each workout's day: `loadDay` per day across the whole history. If that is too slow at launch, the fallback is a small sealed index (workout ID → day) in `WorldMapVault`. That is new stored data, so it needs a privacy wording check.
- **Roads (B).** The counter needs a last-used day (or month) per cell next to the count, so it can fade. That is still small (about 250k × 6 bytes at most), but it is date-bearing routine data. The policy sentence in §5 drops "with no dates" and needs a new draft.
- **Art.** An abandoned path needs its own look: for example faint, broken dirt with grass pixels growing through. It still shows only on uncovered ground.
- **Your world roads.** "Long enough" needs a number. Draft: a road run of at least 2 km of connected frequent cells, about 6 of Your world's finest hexes.
