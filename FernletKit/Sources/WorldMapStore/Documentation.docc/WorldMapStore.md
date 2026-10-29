# ``WorldMapStore``

The live-map Home's ground truth: plain geometry for Fernlet's own map layers, and the sealed, device-only stores that remember where the fog has lifted. **World build only (branch `world-ui`, never main).**

## Overview

The World build's Home is a live map ("A World for Fernlet", design page v9). Apple's muted map sits behind a small seam in the app target (`App/Fernlet/World/Map/`), and Fernlet draws its own layers on top: the fog, trails, the companion and pins. This module holds everything those layers know about the ground, and nothing about any map provider.

**No map types, ever.** Every position is a ``GeoPoint`` (plain latitude and longitude). A base map reports what it shows as a ``MapViewport`` in normalised Web Mercator, and the layers place themselves from that alone. Phase 2 swaps Apple's map for MapLibre by adding one conformer to the seam; nothing stored here changes. MapKit is imported in exactly one app file, `AppleMutedBaseMap.swift`, which `MapAndLocationConfinementBoundaryTests` pins.

**One fog grid for the whole world.** ``MercatorHexGrid`` lays regular hexagons over Web Mercator, so they stay regular on any north-up map and every ``HexCell`` keeps one stable `Int64` ID. A cell is about 35 m across at 45° (about 25 m radius at the equator, 12 m at 60°): coarse on purpose, so the fog says "you've been round here" and never which door you went in.

**Bounded.** ``Polyline`` keeps at most 50,000 points and samples at most 4,000; a cell query returns at most ``MercatorHexGrid/maxCellsPerQuery``; one fix lifts at most 12 rings. These are the Power of 10 bounds the layers rely on.

### The sealed history

``WorldMapVault`` is the only place the map's history is written. Every file is AES-GCM sealed with its own authenticated purpose (`FernletCryptoPurpose.AEAD.worldMapFogV1`, `worldMapPendingV1`, `worldMapRouteV1`, `worldMapPinsV1`, `worldMapPlacesV1`, `worldMapPlacesDeviceV1`, `worldMapPhotoPlacesV1`, `worldMapPassportV1`, `worldMapCornerV1`), plus any per-file context (a walk line's workout id), written with file protection, and kept in `Application Support/WorldMap`, a folder excluded from device backups (the flag is re-asserted on every write and when the app opens the vault, not only when the folder is created: `reassertBackupExclusion()`, round 6b). Its two keys (``WorldMapKeys``, ``WorldMapKeyRole``) are this-device-only rows under `com.fernlet.world-map`:

- the **store** key is `WhenUnlockedThisDeviceOnly`, so the fog can only be read or written while the phone is unlocked;
- the **buffer** key is `AfterFirstUnlockThisDeviceOnly`, for the small locked-phone buffer alone: a walk with the screen off, or Always mode's visits, lift cells while the phone is locked, and those wait there until the next unlock drains them into the store. The same split as `PendingNarrativeBuffer`, for the same reason.

**Walk lines** (``WorldRouteStore``, ``WorldRouteCodec``, ``RoutePoint``) are one sealed file per workout, bound to the workout's id, shaped like the watch build's planned `DeviceRouteStore` so a later move to it is a straight copy. A line is thinned (Ramer–Douglas–Peucker at 2.5 m), quantised (1e-5°, 0.5 m) and delta-coded as zigzag varints; at most 50,000 points, at most 2,000 lines. Only the workout's duration and distance reach the synced diary; the line stays here.

**Workout-space pins** (``SpacePinStore``) are one small sealed file: a point per space, keyed by the space's `WorkoutLocation.id`, matched within 100 m on the phone. A space's name and setup stay in the synced settings; only its place on the map lives here. At most 200 pins.

**Where you've been** (step 5c; ``PlaceLogStore``, ``PlaceLog``, ``PlaceDeviceState``) is two files. The log (`places.bin`, `AEAD.worldMapPlacesV1`) is sealed with the **Private tab's hub key**, passed per call while Private is open (``WorldMapVault/read(_:sealedWith:)``, ``WorldMapVault/write(_:to:sealedWith:)``): the rolling 30-day timeline of ``PlaceStop``s and Places you return to (``PlaceRecord``: the person's own point, Apple's reference to the place when it gave one, the person's own name once they rename it, and a visit count, never dates). Since round 5 (the MapKit terms: a place's identifier may be kept, its data only cached) nothing of Apple's answer is kept but that reference: never its name or kind; the app asks for the name again by the reference when the person looks, in memory only. Format 2; a format-1 log (which held the lookup's name and kind) is read with both dropped and sealed again at once. A log the current hub key can't open (the app lock was reset) is removed, with what waited on the device side. The device side (`places-device.bin`, `AEAD.worldMapPlacesDeviceV1`, the buffer key) holds what was captured while Private was closed and the allowed places' points and references (``KnownPlace``, no names) that visits are matched against; a fold moves it under the hub key, each stop once. ``PlaceClassifier`` is the device's rule at capture: a visit is kept only at the nearest place, only an allowed kind (food and drink, gyms, parks, beaches, campgrounds), and a refused place (medical, legal, therapy, by kind or by the words in its name) refuses the visit; nothing of a lookup's answer (``NearbyPlace``) is stored but the decision (``PlaceVerdict``) and an allowed place's reference. At most 300 places, 2,000 stops and 500 waiting.

**Remember this place's marks** (round 7, ``WorldMapVault/File/placeMarks``, `places-marks.bin`): the spots the person said "Not here" to and the places they remembered themselves, written by the app (`WorldPlaceMarksStore`) under the device side's purpose and buffer key, bound to its own context so it never opens as `places-device.bin`. Bounded; removed with the vault by every wipe.

**Solo photos' places** (``PhotoPlaceStore``, `photo-places.bin`, `AEAD.worldMapPhotoPlacesV1`): a point per solo camera photo id, kept only where a visit would be kept (an everyday place, or inside a park, beach or campground; ``PlaceClassifier/photoMayKeepPlace(_:)``, owner, round 5), never anywhere else or with no lookup answer, unless the person puts the photo on the map themselves (round 6). Deleting a photo deletes its point. At most 3,650.

**Round 6** (owner-approved 2026-10-25). A park's own features (``NearbyPlace/Kind/feature``: a lake, a restroom, a bike dock, a playground) no longer block the park around them. A place the person adds themselves is an ordinary ``PlaceRecord`` with their name and no reference. The device side gains two optional parts the map reads with Private closed, never folded into the log: the person's **homes and hotel** (``HomeBook``, ``HomePlace``, ``HomeKind``): up to two homes and one hotel stay, the hotels stayed at before (for a welcome back), and where the person was last seen (``HomePresence``), so leaving and getting back join the timeline (``PlaceStop/Kind/leftHome``, ``PlaceStop/Kind/cameHome``, ``PlaceLog/outAndAbout(on:calendar:)``) and getting home after an hour leaves Sprout one greeting (``HomeGreeting``); and the **places the person eats out at** (``EatingPlace``, ``EatingMeal``): Apple's reference, their own name, Fernlet's point and the meals logged there (no dates), a favourite after three (``PlaceClassifier/eatingPlaceID(_:)`` decides food and drink at the moment). "Delete all of it" keeps the homes and hotel (they stay until removed in Settings › Home map); an app-lock reset and every wipe take them. **One place or one stop** (W-14, owner-approved 2026-10-26) goes on its own: ``PlaceLog/deletingPlace(_:)`` removes a place and every visit to it on any day, ``PlaceLog/deletingStop(_:)`` one stop by ``PlaceLog/deletingDay(_:calendar:)``'s count rule (a walk's or run's workout id comes back so its saved line can go), and ``PlaceDeviceState/forgettingPlaces(_:)`` drops a removed place from matching and its place to eat (its map icon) by id or reference; the homes and hotel are never touched. ``MercatorHexGrid/disc(around:radius:)`` gives the circles drawn clear round homes (1 km) and kept places (about 300 m): drawn, never written into the fog.

**The passport** (round 7, owner 2026-10-29; ``PassportStore``, ``PassportBook``, `passport.bin`, `AEAD.worldMapPassportV1`, the store key) is every country or territory, continent, ocean, sea, city, landmark and terrain class the person has been to, each by its frozen token (``AtlasDiscovery``) with the date of the first visit; a sea is its own entry, never its ocean. It is sealed on the iPhone like journal text, and the same versioned bytes (``PassportBook/encoded()``, ``PassportBook/init(data:)``) are the passport's on-device format; Fernlet's sealed iCloud backup carries the same entries as a payload of its own behind its own switch (``PassportBook/init(discoveries:)`` rebuilds a restored book, refusing what this build can't hold; this module never reaches CloudKit itself); a restore merges by token and keeps the earliest date (``PassportStore/restore(_:)``). ``PassportBook/record(_:at:)`` returns only first visits, in a fixed order (country, continent, ocean, sea, city, landmark, terrain), and the store saves before it reports one. The app's `WorldAtlasKeeper` reads only the fixes the fog keeper accepted, unlocked and never in a decoy, through ``AtlasVisitResolving`` (the bundled atlas conforms); a decoy shows an empty passport and keeps nothing, and every wipe reaches it through the fog keeper and the vault. At most 300 countries and territories, 7 continents, 5 oceans, 250 seas, 20,000 cities, 5,000 landmarks and 20 terrain classes: past a cap a first visit is refused and counted, never an eviction.

**Bike rides on the timeline** (round 7, Refinements group 19, owner-approved 2026-10-29). ``PlaceStop/Kind/ride`` (raw value `ride`, the one additive change to the frozen enum) is a bike ride Fernlet logged: `at` its start, `metres` its distance when known, `workoutID` its cycling workout, whose line (if kept) is saved like a walk's. It is kept 30 days, goes with Delete a day and Delete this stop as a walk does (its line goes, the workout stays), and ``PlaceLog/deletingOuting(workoutID:)`` and ``PlaceDeviceState/removingOuting(workoutID:)`` take it off for the ride note's Undo. Both files read their stops one by one, so a stop of a kind this build doesn't know (a newer build's, then restored) is skipped instead of failing the whole log.

**One new corner a week** (round 7, spec §5, owner's option 1; ``FogCornerNudge``, ``FogCornerStore``, ``FogCornerState``, `corner.bin`, `AEAD.worldMapCornerV1`, the store key). Once a week Sprout points at the nearest still-fogged patch within 1 km of home: a cell 120 m to 1 km from the home point that is not in the fog history (the 1 km circle Home draws clear is drawn, never written, so it does not count as walked) and at least four of whose six neighbours are fogged too, so a one-cell gap never qualifies. The nearest 100 m band wins and a SplitMix64 hash of the week and the cell picks within it, so a week always picks the same cell and weeks differ; a new week passes over last week's corner when it can. Weeks run Monday to Monday in the calendar's time zone, identified by a rounded count of weeks since 1970-01-05 that every zone agrees on. The sealed file holds only that week's start, the cell and whether it was reached (18 bytes), so the pick survives a relaunch; there is no history of corners, no streak and no penalty. A corner is done when the fog keeper lifts it and lapses when the week ends. ``FogCornerNudge/bearingAndDistance(from:to:)`` gives the metres and a frozen ``CompassPoint`` token for VoiceOver. One pick examines at most ``FogCornerNudge/maxExamined`` disc cells. The app's `WorldCornerNudgeKeeper` picks only from the loaded history, never in a decoy, and every wipe reaches the file through the fog keeper and the vault.

A key that can't be read right now is an error, never a reason to mint a new one over it; a file that can't be opened (its key gone, its bytes damaged) is removed, so the map starts fresh rather than carrying noise.

``FogCellStore`` holds the lifted cells: at most ``FogCellStore/maxCells`` (a lifetime of walking one city), with ``FogCellStore/maxPendingCells`` waiting in the buffer, stored in ``FogCellCodec``'s compact delta form. Past a cap new cells are refused and counted, never an eviction of old history. It never decides whether to lift: the app's `WorldFogKeeper` does (precise location, "Uncover the map as you go" on, no decoy session).

**Wipes.** ``WorldMapVault/clearAll()`` removes the folder and both keys. Delete everything and the duress silent wipe reach it through `FernletStore.resetAll()`; the duress recovery lock through its own purge hook (design page answer 16). A decoy session never reads or writes it.

### The atlas

Round 7 (ideas 1, 2, 4, 7, A and B; contract in `Docs/World-Atlas-Pack.md`). The app bundles one file, `WorldAtlas.pack`, and never fetches anything for it. ``WorldAtlasPack`` opens it: the `FWA1` header and section table, each body raw DEFLATE inflated through Apple's Compression framework into a buffer of exactly its stated length (the module's one unsafe-pointer seam, `WorldAtlasInflate.swift`, allowlisted). It refuses, with a ``WorldAtlasPackError`` and never a trap, a file over ``WorldAtlasPack/maxPackBytes`` (6 MiB), a wrong magic or version, a section past the end, a `rawLength` over 64 MiB or one that disagrees with the body, and a missing section. ``WorldAtlasPack/expectedSHA256`` pins the shipped file and stays "unpinned" until the pack is generated.

``WorldAtlas`` is the parsed pack, immutable and `Sendable`. Its ``AtlasGrid`` size comes from the `LAND` header (0.1° when shipped, 10° or 5° in tests). It answers ``WorldAtlas/isLand(at:)`` (coast cells read their 16 × 16 sub-mask), ``WorldAtlas/climateCode(at:)``, ``WorldAtlas/continent(at:)``, ``WorldAtlas/country(at:)`` (an ``AtlasPolygon`` box first, then the even-odd rule, so holes work) and ``WorldAtlas/city(at:)``. ``WorldAtlas/water(near:within:)`` returns the nearest ocean or sea (``AtlasWater``) within ``WorldAtlas/oceanReachMetres``. ``WorldAtlas/visit(at:)`` applies all the rules to one accepted fix:

- the ocean or sea within 2 km, never both, since a sea is its own passport entry;
- Antarctica anywhere south of ``WorldAtlas/antarcticaLatitude`` (60°S, on land, ice or sea);
- the nearest city whose point lies within its ``WorldAtlas/cityReachMetres(for:)`` of a fix inside any urban boundary, or within its ``WorldAtlas/cityCoreRadiusMetres(for:)`` of any fix (``WorldAtlas/isUrban(_:)``; ``WorldAtlas/urbanArea(of:)`` gives the boundary holding a city's own point, for the screens).

``WorldAtlas/city(token:)``, ``WorldAtlas/country(code:)`` and ``WorldAtlas/sea(token:)`` turn a passport's frozen tokens back into the pack's entries (one dictionary read each, built once when the atlas opens).

**Landmarks** (World-Exploration-Spec §2; ``WorldLandmarks``, ``AtlasLandmark``). A hand-written list in its own bundled file, `WorldLandmarks.json`, beside the pack and not in it (never an OpenStreetMap import, never fetched). Two tiers (``AtlasLandmarkTier``): a famous landmark has its own pixel art, named by an art id (``WorldLandmarks/famousArtIDs``: 28 drawn, all approved 2026-10-29: `eiffel`, `empire`, `opera`, `colosseum` and the owner's 24 more; a future famous landmark waits in ``WorldLandmarks/placeholderArtIDs``, which ``AtlasLandmarkTier/drawable`` draws with a generic icon until its art is approved); the art itself is ``WorldLandmarkArt`` (the design session's sprites, palette, halos, not-found greys and scales, bundled as `WorldLandmarkArt.json`; ``WorldLandmarkArt/sprite(for:)`` picks what a landmark draws now); every other one a generic icon (``AtlasLandmarkKind``: park, bridge, lighthouse, stadium, castle, tower). Each entry has a frozen lowerCamel token, an English and a Spanish name (data, shown only once found), its city's atlas token, a point and a find radius of 50 to 600 m. ``WorldLandmarks/init(data:)`` refuses a whole file for any broken entry, an unknown key, a second use of a token, a version it does not read, or more than ``WorldLandmarks/maxLandmarks`` (5,000). An accepted fix within a landmark's radius finds it: ``AtlasWithLandmarks`` puts the tokens into ``AtlasVisit/landmarks`` (at most ``AtlasVisit/maxLandmarks``), and the passport keeps each one once as kind `landmark`, after the city and before the terrain. The city card reads ``PassportBook/foundLandmarkCount(inCity:of:)`` against ``WorldLandmarks/landmarks(inCity:)``, and the map asks ``PassportBook/isFound(_:)``; before it is found a landmark is drawn grey and unnamed through the fog, even in a decoy, since the list is public data and a decoy's empty book finds nothing.

**States and provinces, and the world view's zoom** (World-Exploration-Spec, "The world view", answers 9 and 13). The pack's `ADM1` section holds Natural Earth's admin-1 states and provinces (``AtlasAdmin1``: a frozen token, its ISO 3166-2 code or `ne:<id>`; the country's alpha-2; English and Spanish names; an outline at 0.008°). Where Natural Earth's admin-1 is second-level (Britain's council areas, France's départements, Italy's and Spain's provinces, Ireland's counties, and Belgium, the Philippines, Uganda, Sri Lanka, Guinea, Burkina Faso and Malawi), each entry names its first-level region, its plate group (``AtlasAdmin1Group``: England, Île-de-France); elsewhere an entry is its own group. ``WorldAtlas/admin1(at:)`` tests only the entries of the country under the fix when there is one, ``WorldAtlas/admin1Group(at:)`` gives its group, and ``WorldAtlas/placeName(at:)`` gives the plate's place (``AtlasPlaceName``: the group's names and the country code, the screen naming the country). The screen draws lines on hex edges: ``WorldAtlas/placeName(of:in:)`` names a hex and ``WorldAtlas/border(between:and:)`` says whether an edge carries a country line, a state line (two groups of one country) or none (``AtlasHexBorder``). ``AtlasPolygon/ring(_:)``, ``WorldAtlas/admin1s(overlapping:)`` and ``WorldAtlas/countries(overlapping:)`` hand over the outlines too. No county data, ever. ``AtlasZoomLevel`` is the ladder World → Country → State → City (about 4.97, 20.7, 86.3 and 360 pt a degree of latitude at 45°; the ends from the mockup, a geometric ladder between), with + and − availability, country lines from Country, state lines and the plate's place from State, and VoiceOver naming the country from Country and the group from State. ``WorldViewHexGrid`` lays a level's 10-pt hexes over Web Mercator and ``WorldViewHexGrid/uncovered(by:)`` maps the lifted fog cells to the hexes they uncover, so one fog store drives every level; ``WorldAtlas/zoomDescription(level:centre:)`` gives the zoom control's VoiceOver parts.

``AtlasTerrainClassifier`` maps the Köppen-Geiger code and the latitude to an ``AtlasTerrain``, and picks a few ``AtlasFlora`` (cacti only in the Americas). ``AtlasSeason`` gives meteorological seasons, flipped south of the equator, and none of the four inside the tropics.

Bounded throughout:

- at most 250 seas, 512 countries, 16,384 urban boundaries, 16,384 cities and 8,192 states and provinces;
- the admin-1 search tests one country's entries (or, the country unknown, one pass over the table); the world-view aggregation reads at most ``WorldViewHexGrid/maxLiftedCells`` fog cells;
- at most 10,000 rings a feature and 200,000 points a ring, with every varint capped at ten bytes;
- the reach search walks at most 81 cells of 256 sub-cells each;
- the city search reads at most 51 one-degree cells of the city index, then at most one pass over the urban boundaries.

### Its place on the walls

This module holds location history (the lifted fog cells, saved walk and run lines, workout-space pins, Where you've been, the solo photos' places, the passport and the week's corner), so it sits on the far side of the S3 wall from every module that sends data anywhere. `CloudKitSync`, `AIProviders`, `AIContext`, `FernletSocial` and `FernletConnections` do not depend on it, and the strict build (`Scripts/spm-wall-check.sh`, `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR`) fails any of them that imports it. It holds no display strings, so it has no string catalog.

## Topics

### Geometry

- ``GeoPoint``
- ``WebMercator``
- ``MapViewport``
- ``WorldCamera``
- ``Polyline``

### The fog grid

- ``MercatorHexGrid``
- ``HexCell``
- ``FogGapCloser``
- ``FogGapScan``

### The sealed history

- ``WorldMapVault``
- ``WorldMapKeys``
- ``WorldMapKeyRole``
- ``FogCellStore``
- ``FogCellCodec``
- ``WorldRouteStore``
- ``WorldRouteCodec``
- ``RoutePoint``
- ``SpacePinStore``
- ``PassportStore``
- ``PassportBook``
- ``AtlasVisitResolving``
- ``FogCornerNudge``
- ``FogCornerBearing``
- ``CompassPoint``
- ``FogCornerStore``
- ``FogCornerState``

### Where you've been and photo places

- ``PlaceLogStore``
- ``PlaceLog``
- ``PlaceDeviceState``
- ``PlaceRecord``
- ``PlaceStop``
- ``KnownPlace``
- ``PlaceCategory``
- ``PlaceClassifier``
- ``PlaceVerdict``
- ``NearbyPlace``
- ``PhotoPlaceStore``

### Homes, hotels and places to eat

- ``HomeBook``
- ``HomePlace``
- ``HomeKind``
- ``HomePresence``
- ``HomeGreeting``
- ``HomeGreetingKind``
- ``HomeMove``
- ``EatingPlace``
- ``EatingMeal``

### The atlas

- ``WorldAtlasPack``
- ``WorldAtlasPackError``
- ``WorldAtlas``
- ``AtlasGrid``
- ``AtlasPolygon``
- ``AtlasCountry``
- ``AtlasWater``
- ``AtlasTerrainClassifier``
- ``AtlasFlora``
- ``AtlasSeason``
- ``AtlasVisit``
- ``AtlasContinent``
- ``AtlasOcean``
- ``AtlasSea``
- ``AtlasCity``
- ``AtlasCityNames``
- ``AtlasCitySize``
- ``AtlasTerrain``
- ``AtlasDiscovery``
- ``AtlasDiscoveryKind``

### Landmarks

- ``WorldLandmarks``
- ``AtlasLandmark``
- ``AtlasLandmarkTier``
- ``AtlasLandmarkKind``
- ``AtlasWithLandmarks``

### States, provinces and the world view

- ``AtlasAdmin1``
- ``AtlasAdmin1Group``
- ``AtlasPlaceName``
- ``AtlasHexBorder``
- ``AtlasZoomLevel``
- ``WorldViewHexGrid``
- ``AtlasZoomDescription``
