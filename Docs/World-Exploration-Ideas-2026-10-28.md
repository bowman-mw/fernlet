# World exploration ideas (logged 2026-10-28)

Status: **ideas only, nothing built.** Per the owner's rule, feature content is proposed and logged first; build after picks. Open questions are at the end.

Four linked ideas from the owner, plus the constraints they run into in this codebase.

## 1. The map matches the real world

**Goal:** water tiles sit over water, land over land. Land gets real terrain: desert, mountains, forest (kinds vary by place), grass, trees, and flowers that fit the region.

**What exists:** the World map is a pixel-style fog map on Apple's muted base map (Sprout's world, `WorldBaseMap` seam). Terrain and fog are drawn per tile. The 2026-10-26 world-map fix (W-20) guards map frames.

**Idea:**
- Classify each map tile by the real land cover under it: water, desert, mountain, forest (temperate, tropical, boreal), grassland, cropland, urban, tundra, ice.
- Pick a flora set from the same class plus latitude and climate band: palms in the tropics, conifers in the north, cacti and dry scrub in deserts, wildflower mixes in temperate grass.
- Keep the owner's pixel style. Each class is one tile art set; flowers are a small seasonal layer on top.

**Data options (must be bundled, see constraints):**
- Natural Earth (public domain): land, ocean, coastlines, country borders, populated places, major roads, at 1:10m or 1:50m. Good for water/land and the passport.
- ESA WorldCover (CC BY 4.0, 10 m land cover): best for forest/desert/mountain-scale classes. Heavy to ship. Likely pre-reduced to a coarse grid (for example 0.05°) and compressed.
- Köppen-Geiger climate zones (public, CC BY): picks flora by climate band. Small.

**Constraint:** the no-tracking wall allows only an exact allowlist of network destinations and bans fetching at runtime for this data. So the terrain data ships inside the app (a compressed resource or a generated tile pack), not fetched. The pack size needs a cap, and the data needs an attribution screen. Any network source would need a deliberate allowlist entry and a doc in `Docs/No-Tracking-Wall.md`.

**Open:** how coarse can the terrain be before water sits wrong at the coast? The fix may be a coastline mask from Natural Earth over whatever base tiles are shown.

## 2. Discovering cities, important roads, and landmarks

**Goal:** walking, running, or riding into a city discovers it. Major roads get marked on the map. Notable landmarks get marked too.

**Idea:**
- A city is discovered on the first visit to its boundary. The discovered city gets a marker on the map and a city card (name, country, a pixel skyline for its size class).
- Roads: only the important ones (motorways, trunk, primary) from Natural Earth, drawn as a thin line. A road counts as discovered when the route has crossed it, which the existing route store could support.
- Landmarks: a short curated list per city (for example a famous park, bridge, or tower). Discovered when visited within a small radius. Start with the list, not a full OSM POI import.

**Data:** Natural Earth populated places (city points, with a size rank for skyline class) and roads. Landmarks come from a hand-written list, which keeps licensing clean.

**Privacy:** discovered cities and landmarks are visit history, the same kind as the existing 30-day private route log. They should stay device-local (the World route store / Private history model), with no sync unless the owner decides otherwise. Precise location stays opt-in as today.

**Open:** what counts as a visit: entering the city boundary, or a fixed radius around the city centre? Do drive-throughs count (the car/bike rides already auto-log)?

## 3. World map tied to the city view

**Goal:** a world map view where discovered cities, roads, and landmarks show, and tapping one opens its city view.

**Idea:**
- The world map is the second level of the Home map: zoom out past the local fog to see the whole world with discovered places only (undiscovered places stay as fog).
- The city view is the zoomed-in level of the same map: the discovered roads, landmarks, and the city's own pixel buildings.
- One data set drives both, so the two views never disagree.

**Constraint:** the map is built on Apple's base map today. Any move to a custom world map (the "phase 2" MapLibre + OSM path in the approvals tracker) changes the attribution and the network allowlist. Decide that first, or keep the pixel layer on Apple's map.

## 4. Discovering oceans and continents, tied to the stamp book

**Goal:** the stamp book becomes a passport. Every country, continent, and ocean you have been to gets a stamp. Visiting all seven continents earns a special stamp. Visiting all oceans earns one too.

**Current state:** the stamp book is already one page (approved as `b2-milestones`, 2026-10-24) with 19 stamps for silly stats. The passport extends that page.

**Idea:**
- **Passport layout:** one spread per continent, with the countries you have visited as stamps, plus an oceans spread. A progress line reads "N of 195 countries", "N of 7 continents", "N of 5 oceans".
- **Country stamps:** one stamp per country. 195 hand-drawn stamps is a lot of art. A cheaper route: one shared stamp frame per continent, filled with the country's flag colours and name (generated from data), so the art is a template, not 195 drawings. Hand-drawn art can come later for a few favourites.
- **Continent and ocean stamps:** one stamp each (7 + 5). The special stamp for all continents and the special stamp for all oceans are the rewards, and they are the only stamps with full art at launch.
- **Visit rules:**
  - Country: inside its boundary (Natural Earth admin-0 polygons).
  - Continent: inside its landmass, from a country visit or any point on it.
  - Ocean: a point over the ocean polygon, or within a set distance of the coast. Pure "over the ocean" needs a boat, ferry, or flight, so the owner must choose the rule. Flights may not log location at all.
- **Antarctica:** a continent, but almost no one visits. It stays on the list, and "all seven" needs it. Decide whether it is a real requirement or a lighter rule (for example, any research-station or ship visit).

**Privacy:** the passport is a full record of where a person has been. It should be device-local, and the owner should decide whether it is sealed like journal text, the period log, and intimate notes. It must not reach any third party.

**Localization:** the passport words (continent and ocean names, "N of 195") need display strings through `LocalizedStringKey` with `bundle: .module`. The stored token (a country code, a continent rawValue) stays English and frozen.

## Constraints that cut across all four

- **No network at runtime for map data.** Bundle it. Keep the pack small and attributed.
- **Frozen tokens.** Country codes, continent and ocean IDs, and visited-place records are persisted, so their rawValues are frozen (localization wall).
- **Power-of-10 and S3 walls.** Keep functions under 60 lines and the data layer on the sealed side, not the AI/CloudKit side.
- **Pixel style.** Every new art piece follows the approved one-design-language (approved as pixel).

## Owner's answers (2026-10-28)

1. Terrain: **coarse model** (climate bands plus a Natural Earth coastline mask; smaller, approximate biomes).
2. Map base: **Apple base + pixel layer** (no MapLibre/OSM move yet; no new network or attribution work).
3. City discovery: **enter the city boundary**.
4. Country stamps: **hand-drawn for all 195** (not a template; plan for a large art batch).
5. Ocean visits: **within a set distance of the coast** counts (no boat or flight needed).
6. Antarctica: **required** for "all seven continents". Use a lighter rule for it (for example, any research station or ship visit).
7. Passport privacy: **device-local only** (not sealed like journal text).
8. Sync: **sync via iCloud**.

**Tension to resolve before building:** answers 7 and 8 conflict in part. The sealed-store rule keeps sealed data out of the synced blob, and the walled CloudKit module must not reach the sealed `Private*` stores. A device-local passport that also syncs over iCloud needs a decision: sync the passport as a plain (unsealed) record, or keep it sealed and local. Visit history is location-derived, so the first option needs a privacy review.

## Owner's answers (2026-10-29)

- **Passport storage (resolves the 7-vs-8 tension).** The passport is sealed on the iPhone like journal text, and
  it travels in Fernlet's existing encrypted sealed iCloud backup (`SealedBackupCoordinator`), so a new phone gets
  it back. No plain record syncs. It stays on the sealed side of the S3 wall: `AIProviders` and `CloudKitSync`
  never reach it (`Scripts/spm-wall-check.sh`).
- **Roads (idea 7).** Keep the 1 km circle round home for now. Road reveal is not built.
- **Screens.** Design first: the data, rules and engines are built (round 7, lane ideas-data), and no new screen
  is, until the design session's pages are approved. The pack format and rules are in
  [World-Atlas-Pack.md](World-Atlas-Pack.md).

## Suggested order (if the owner picks)

1. Decide the data source and the visit rules (questions 1, 3, 5, 6). Nothing builds until these are answered.
2. Terrain pack and water/land fix on the existing map (idea 1). Shippable alone.
3. Cities, roads, and landmarks as discovered places (idea 2), with the world map and city view on top (idea 3).
4. Passport: continents first, then oceans, then countries and the two special stamps (idea 4). Continent and ocean stamps first, since they need the least art.

## Idea 5: store images as JPEG XL (logged 2026-10-28)

**Goal:** photos in Fernlet take a lot of space over time. Save them in a compressed format such as JPEG XL instead of the current format.

**Idea:**
- Encode new images as JPEG XL at save time, at a quality setting that keeps them visually close to the original.
- Decode on read for display. Keep the original stored format readable, so existing photos never break.
- Migrate old images in the background, after a successful save of the new copy, and only then remove the old file.

**Constraints and checks before building:**
- Confirm which iOS 26 APIs can encode and decode JPEG XL (ImageIO or a bundled library). Do not assume support.
- Check how photos are stored today: Core Data external storage, CloudKit assets, or sealed columns. Sealed photos must stay sealed.
- Existing photos must stay readable through the migration. Own photos from before 2026-08-26 are a known risk (W-19 in the world phone-test issues), so the migration must not lose them.
- Storage gain should be measured on real photos before committing to the format.

**Open:** quality setting, whether to convert old photos or only new ones, and whether the photo-backup behaviour changes.

### Research findings (idea 5, 2026-10-28)

Based on secondary sources (blogs, forums, package pages). Apple's own reference for the JPEG XL type was not found, so every point below needs a device check.

- **Decode:** ImageIO reportedly decodes JPEG XL from iOS 17. Animated JXL may not decode through that path.
- **Encode through ImageIO:** one developer reports that `CGImageDestination` writes JPEG XL with a JXL type identifier from iOS 18.2. `CIContext` reportedly cannot save JXL. Unverified against Apple's docs.
- **Camera:** iOS 18 uses JPEG XL for ProRAW capture. That does not give apps a general JXL save option.
- **Libraries (if ImageIO can't encode):**
  - JxlCoder (awxkee/jxl-coder-swift): encode and decode, built on libjxl, Swift Package Manager or CocoaPods.
  - libjxl-Xcode (SDWebImage): packages libjxl itself, for the raw C API.
  - SDWebImageJPEGXLCoder: decode only, for SDWebImage users.

**Fernlet constraints:**
- A new SPM dependency fails CI until it is allowlisted in `NoTrackingBoundaryTests` and documented in `Docs/No-Tracking-Wall.md` in the same commit.
- Vendored libjxl C code must build under warnings-as-errors and the Power-of-10 scan. Expect allowlist entries for any unsafe pointer use.
- The ImageIO route adds no dependency, so it is the first thing to test.

**Suggested next step:** a short spike on a real iOS 26 device. Encode a sample set with `CGImageDestination` and a JXL type identifier, decode it back, and measure file size against the current format and HEIC. HEIC is worth measuring too, since it is already hardware-encoded on iOS and may give most of the saving with no new format. If ImageIO can't encode, try JxlCoder.

**Sources:**
- [Apple JPEG XL support (cizucu, iPhone 16 Pro)](https://www.cizucu.com/magazines/2024-09-iphone-16-pro-supports-jpeg-xl)
- [JPEG XL in ProRAW capture (juniperphoton)](https://juniperphoton.substack.com/p/supporting-jpeg-xl-compression-in)
- [JPEG XL: iPhone's new photo format explained (Cult of Mac)](https://www.cultofmac.com/news/jpeg-xl-iphone-new-photo-format-explained)
- [jxl-coder-swift (Swift Package Registry)](https://swiftpackageregistry.com/awxkee/jxl-coder-swift)
- [libjxl (CocoaPods)](https://cocoapods.org/pods/libjxl)
- [SDWebImageJPEGXLCoder (CocoaPods)](https://cocoapods.org/pods/SDWebImageJPEGXLCoder)

## Idea 6: compress stored data (logged 2026-10-28)

**Problem:** on the owner's device Fernlet uses about 243 MB, plus another 160 MB of data. Part of that is photos; the rest is records and caches. Find out where the space goes, then compress what can be compressed.

**What the code shows (quick survey, not yet measured):**
- Photos are re-encoded as JPEG at quality 0.8 to 0.9 in several places (`FernletStore.swift`, the friend album, the food gallery, the demo seed). Lower quality or a better format (idea 5) reduces this directly.
- Sealed text and records go through `ColumnCrypto` and `PrivateMediaStore`. Encrypted bytes do not compress, so compression has to run on the plaintext, before sealing.
- Records live in Core Data with CloudKit mirroring (`CoreDataFernletRepository`, `Persistence.swift`). A local JSON repository (`LocalFernletRepository`) also exists.
- Peer payloads already use deflate before sealing (`PayloadType.swift`). That is a precedent for compression on the plaintext side.

**Idea:**
1. **Measure first.** Split the 243 MB and 160 MB by type: photos, Core Data store, external binary storage, caches, sealed media, and logs. Without this, any compression is guesswork.
2. **Compress plaintext before sealing** the text and record payloads (deflate or LZFSE through Apple's Compression framework, no new dependency). Store a format marker so older rows still read.
3. **Cut re-encoding waste:** one encode per photo, a single quality setting, and no duplicate copies (thumbnail plus full size where one would do).
4. **Prune caches** that can be rebuilt: thumbnails, map tiles, and generated images.
5. **Photos:** follow idea 5 (JPEG XL or HEIC) once the spike shows the saving.

**Constraints:**
- Sealed data stays sealed. Compression runs before sealing, never after.
- Existing rows must still read after the change. Use a format marker and migrate in the background.
- Power-of-10 rules apply: bounded loops, no silent `try?`, functions under 60 lines.
- Core Data and CloudKit changes need a schema check. The CloudKit schema deploy path (`CloudKitSchemaDeploy.swift`) is the gate.
- Verify the saving on the owner's device before shipping, since the simulator's store is not representative.

**Open:** is the 160 MB cache or CloudKit's local mirror? Does the owner want a "storage" screen that shows the breakdown? Is a one-time cleanup of caches acceptable?

## Idea 7: reveal along roads and paths around home (logged 2026-10-28)

**Problem:** the fog lifts in a circle about 1 km wide around home. The owner wants about 1 km along the roads instead, so exploring the nature near home feels like walking out from the door.

**What the code shows:** the fog is a hex grid of cells (`MercatorHexGrid`). `WorldFogKeeper.liftRadius` is 50, and a reading lifts every cell within that radius of the fix. The circle is that radius. The grid unit and its metric meaning still need confirming in code.

**Idea:**
- Reveal the cells along the road network within about 1 km of home, following the streets and paths, not a flat circle.
- Use a wider corridor than the normal tracking band, so the cells beside a road are lifted too, and nature on both sides shows.
- Still lift the cells the user walks through, with the usual rules (no reveal from a poor fix, no reveal while locked).
- **Odd hidden tiles:** check for cells left hidden that should be open, such as a single fogged cell inside a revealed area, a gap at a corridor junction, or a cell cut off from its road. Find these with a check over the revealed set and close the gaps.

**Data:** road lines from the bundled map data (see Idea 1 and the Natural Earth roads layer). Bundled, not fetched, because of the no-tracking wall. A walking or driving network is larger than Natural Earth's major roads, so the first version may use the major roads plus the owner's own routes.

**Open:**
- Which roads count: **answered 2026-10-28: main roads only.** Footpaths and minor roads are out of the first version.
- Should the reveal update at home, or only as the user walks?
- Is "1 km" a walking distance along the road, or a straight distance from home that follows the roads?
- How big is the corridor either side of the road?

## Idea 8: a daily "bathroom calendar" (logged 2026-10-28)

**Idea:** borrow the bodybuilding habit of one calendar that shows the whole day at a glance. Each day gets a row or tile with: body weight, hours of sleep, bowel movements, what was trained, steps, macros, free meal, and overall energy.

**What is already tracked:**
- Sleep (daily logs), steps and workouts (Apple Health mirror and the workout engine), macros and meals (food log), weight (workout and body data), and energy (the daily care score and hearts).
- Bowel movements are not tracked as a field. The only matches are unrelated copy, so this is new.
- "Free meal" is not a field. Whether a meal is a planned cheat or a free meal needs a definition (a tag on a logged meal is the simplest).

**Idea:**
- One calendar screen, one day per cell, showing a small set of icons or numbers for each signal.
- Tapping a day opens the day's details (the existing day edit sheet already holds most of the data).
- Bowel movements: a quick log beside water and sleep, with a count per day. Keep it under the existing daily-log pattern.
- Free meal: a tag on a logged meal, shown as a marker on the day.

**Constraints:**
- Bowel and free-meal data are health-sensitive. Store them with the sealed narrative data if they carry notes, and keep the counts unsealed only if the owner agrees.
- Weight, sleep, and steps should come from the existing sources, not new ones.
- Keep it gentle: no streaks or grades, which fits Fernlet's care-over-optimization rule. A bodybuilder's calendar is a tally, so the tone needs changing.

**Open:**
- Bowel count: **answered 2026-10-28: a count per day.**
- Free meal: **answered 2026-10-28: the same as a cheat meal** (a tag on a logged meal). Use the word "free meal" in the UI only if the owner wants it; the stored token stays English and frozen.
- Should the calendar show all signals at once or let the owner pick which ones?
- Which view is the default: the month grid or a week list?

### Scope update (2026-10-28): opt-in for the bodybuilding class

The calendar is for people who choose the bodybuilding class. It does not appear for everyone.

- **Gate:** show the calendar only after the user picks a bodybuilding class or goal. Nothing shows by default.
- **Current state:** `GoalType` (`FernletKit/Sources/FernletDomainModel/WellbeingModels.swift`) has seven presets, and none is bodybuilding. The closest are Strength and Sports Prep. A bodybuilding class therefore needs adding to the goal presets, or to a new class picker, before the gate can exist.
- **Counts:** bowel movements are a count per day, and a free meal is the same as a cheat meal (a tag on a logged meal).

## Picked ideas from the brainstorm (2026-10-28)

The owner picked four of the six brainstormed ideas. Items 1 and 2 extend Idea 1 and the companion; items 5 and 6 extend Idea 7 and Idea 8. Nothing built.

- **A. Seasonal flora on the home map.** The terrain layer from Idea 1 changes with the real season at the user's location. The hemisphere flips the season, so the owner's area shows spring flowers or autumn colour in its own season. Depends on the terrain pack (Idea 1) and the device date.
- **B. Sprout comments on new places.** When a new desert, mountain, or city is discovered, the companion gives one short line in its usual voice. No new data is needed beyond the discovery event. Localize the lines through `LocalizedStringKey` with `bundle: .module`, and keep discovery tokens English and frozen.
- **C. Deload days on the bodybuilding calendar.** Mark rest or lighter training weeks on the calendar (Idea 8), so a dip in energy reads as planned. Opt-in with the bodybuilding class, like the rest of Idea 8.
- **D. A soft "one new cell a week" nudge.** A gentle weekly prompt to reveal one unrevealed area near home (Idea 7). No streak, no penalty, in line with Fernlet's care-over-optimization rule.

Open: whether A depends on Idea 1 shipping first; whether B's lines are per-place or per-category; whether C is set by the user or suggested from logged training; and whether D shows on Home, the Today panel, or only as a notification the owner turns on.
