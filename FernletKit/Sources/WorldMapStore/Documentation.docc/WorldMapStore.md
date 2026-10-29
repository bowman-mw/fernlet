# ``WorldMapStore``

The live-map Home's ground truth: plain geometry for Fernlet's own map layers, and the sealed, device-only stores that remember where the fog has lifted. **World build only (branch `world-ui`, never main).**

## Overview

The World build's Home is a live map ("A World for Fernlet", design page v9). Apple's muted map sits behind a small seam in the app target (`App/Fernlet/World/Map/`), and Fernlet draws its own layers on top: the fog, trails, the companion and pins. This module holds everything those layers know about the ground, and nothing about any map provider.

**No map types, ever.** Every position is a ``GeoPoint`` (plain latitude and longitude). A base map reports what it shows as a ``MapViewport`` in normalised Web Mercator, and the layers place themselves from that alone. Phase 2 swaps Apple's map for MapLibre by adding one conformer to the seam; nothing stored here changes. MapKit is imported in exactly one app file, `AppleMutedBaseMap.swift`, which `MapAndLocationConfinementBoundaryTests` pins.

**One fog grid for the whole world.** ``MercatorHexGrid`` lays regular hexagons over Web Mercator, so they stay regular on any north-up map and every ``HexCell`` keeps one stable `Int64` ID. A cell is about 35 m across at 45° (about 25 m radius at the equator, 12 m at 60°): coarse on purpose, so the fog says "you've been round here" and never which door you went in.

**Bounded.** ``Polyline`` keeps at most 50,000 points and samples at most 4,000; a cell query returns at most ``MercatorHexGrid/maxCellsPerQuery``; one fix lifts at most 12 rings. These are the Power of 10 bounds the layers rely on.

### The sealed history

``WorldMapVault`` is the only place the map's history is written. Every file is AES-GCM sealed with its own authenticated purpose (`FernletCryptoPurpose.AEAD.worldMapFogV1`, `worldMapPendingV1`, `worldMapRouteV1`, `worldMapPinsV1`, `worldMapPlacesV1`, `worldMapPlacesDeviceV1`, `worldMapPhotoPlacesV1`), plus any per-file context (a walk line's workout id), written with file protection, and kept in `Application Support/WorldMap`, a folder excluded from device backups (the flag is re-asserted on every write and when the app opens the vault, not only when the folder is created: `reassertBackupExclusion()`, round 6b). Its two keys (``WorldMapKeys``, ``WorldMapKeyRole``) are this-device-only rows under `com.fernlet.world-map`:

- the **store** key is `WhenUnlockedThisDeviceOnly`, so the fog can only be read or written while the phone is unlocked;
- the **buffer** key is `AfterFirstUnlockThisDeviceOnly`, for the small locked-phone buffer alone: a walk with the screen off, or Always mode's visits, lift cells while the phone is locked, and those wait there until the next unlock drains them into the store. The same split as `PendingNarrativeBuffer`, for the same reason.

**Walk lines** (``WorldRouteStore``, ``WorldRouteCodec``, ``RoutePoint``) are one sealed file per workout, bound to the workout's id, shaped like the watch build's planned `DeviceRouteStore` so a later move to it is a straight copy. A line is thinned (Ramer–Douglas–Peucker at 2.5 m), quantised (1e-5°, 0.5 m) and delta-coded as zigzag varints; at most 50,000 points, at most 2,000 lines. Only the workout's duration and distance reach the synced diary; the line stays here.

**Workout-space pins** (``SpacePinStore``) are one small sealed file: a point per space, keyed by the space's `WorkoutLocation.id`, matched within 100 m on the phone. A space's name and setup stay in the synced settings; only its place on the map lives here. At most 200 pins.

**Where you've been** (step 5c; ``PlaceLogStore``, ``PlaceLog``, ``PlaceDeviceState``) is two files. The log (`places.bin`, `AEAD.worldMapPlacesV1`) is sealed with the **Private tab's hub key**, passed per call while Private is open (``WorldMapVault/read(_:sealedWith:)``, ``WorldMapVault/write(_:to:sealedWith:)``): the rolling 30-day timeline of ``PlaceStop``s and Places you return to (``PlaceRecord``: the person's own point, Apple's reference to the place when it gave one, the person's own name once they rename it, and a visit count, never dates). Since round 5 (the MapKit terms: a place's identifier may be kept, its data only cached) nothing of Apple's answer is kept but that reference: never its name or kind; the app asks for the name again by the reference when the person looks, in memory only. Format 2; a format-1 log (which held the lookup's name and kind) is read with both dropped and sealed again at once. A log the current hub key can't open (the app lock was reset) is removed, with what waited on the device side. The device side (`places-device.bin`, `AEAD.worldMapPlacesDeviceV1`, the buffer key) holds what was captured while Private was closed and the allowed places' points and references (``KnownPlace``, no names) that visits are matched against; a fold moves it under the hub key, each stop once. ``PlaceClassifier`` is the device's rule at capture: a visit is kept only at the nearest place, only an allowed kind (food and drink, gyms, parks, beaches, campgrounds), and a refused place (medical, legal, therapy, by kind or by the words in its name) refuses the visit; nothing of a lookup's answer (``NearbyPlace``) is stored but the decision (``PlaceVerdict``) and an allowed place's reference. At most 300 places, 2,000 stops and 500 waiting.

**Solo photos' places** (``PhotoPlaceStore``, `photo-places.bin`, `AEAD.worldMapPhotoPlacesV1`): a point per solo camera photo id, kept only where a visit would be kept (an everyday place, or inside a park, beach or campground; ``PlaceClassifier/photoMayKeepPlace(_:)``, owner, round 5), never anywhere else or with no lookup answer, unless the person puts the photo on the map themselves (round 6). Deleting a photo deletes its point. At most 3,650.

**Round 6** (owner-approved 2026-10-25). A park's own features (``NearbyPlace/Kind/feature``: a lake, a restroom, a bike dock, a playground) no longer block the park around them. A place the person adds themselves is an ordinary ``PlaceRecord`` with their name and no reference. The device side gains two optional parts the map reads with Private closed, never folded into the log: the person's **homes and hotel** (``HomeBook``, ``HomePlace``, ``HomeKind``): up to two homes and one hotel stay, the hotels stayed at before (for a welcome back), and where the person was last seen (``HomePresence``), so leaving and getting back join the timeline (``PlaceStop/Kind/leftHome``, ``PlaceStop/Kind/cameHome``, ``PlaceLog/outAndAbout(on:calendar:)``) and getting home after an hour leaves Sprout one greeting (``HomeGreeting``); and the **places the person eats out at** (``EatingPlace``, ``EatingMeal``): Apple's reference, their own name, Fernlet's point and the meals logged there (no dates), a favourite after three (``PlaceClassifier/eatingPlaceID(_:)`` decides food and drink at the moment). "Delete all of it" keeps the homes and hotel (they stay until removed in Settings › Home map); an app-lock reset and every wipe take them. ``MercatorHexGrid/disc(around:radius:)`` gives the circles drawn clear round homes (1 km) and kept places (about 300 m): drawn, never written into the fog.

A key that can't be read right now is an error, never a reason to mint a new one over it; a file that can't be opened (its key gone, its bytes damaged) is removed, so the map starts fresh rather than carrying noise.

``FogCellStore`` holds the lifted cells: at most ``FogCellStore/maxCells`` (a lifetime of walking one city), with ``FogCellStore/maxPendingCells`` waiting in the buffer, stored in ``FogCellCodec``'s compact delta form. Past a cap new cells are refused and counted, never an eviction of old history. It never decides whether to lift: the app's `WorldFogKeeper` does (precise location, "Uncover the map as you go" on, no decoy session).

**Wipes.** ``WorldMapVault/clearAll()`` removes the folder and both keys. Delete everything and the duress silent wipe reach it through `FernletStore.resetAll()`; the duress recovery lock through its own purge hook (design page answer 16). A decoy session never reads or writes it.

### The atlas

Round 7 (ideas 1, 2, 4, 7, A and B; contract in `Docs/World-Atlas-Pack.md`). The app bundles one file, `WorldAtlas.pack`, and never fetches anything for it. ``WorldAtlasPack`` opens it: the `FWA1` header and section table, each body raw DEFLATE inflated through Apple's Compression framework into a buffer of exactly its stated length (the module's one unsafe-pointer seam, `WorldAtlasInflate.swift`, allowlisted). It refuses, with a ``WorldAtlasPackError`` and never a trap, a file over ``WorldAtlasPack/maxPackBytes`` (6 MiB), a wrong magic or version, a section past the end, a `rawLength` over 64 MiB or one that disagrees with the body, and a missing section. ``WorldAtlasPack/expectedSHA256`` pins the shipped file and stays "unpinned" until the pack is generated.

``WorldAtlas`` is the parsed pack, immutable and `Sendable`. Its ``AtlasGrid`` size comes from the `LAND` header (0.1° when shipped, 10° or 5° in tests). It answers ``WorldAtlas/isLand(at:)`` (coast cells read their 16 × 16 sub-mask), ``WorldAtlas/climateCode(at:)``, ``WorldAtlas/continent(at:)``, ``WorldAtlas/country(at:)`` (an ``AtlasPolygon`` box first, then the even-odd rule, so holes work) and ``WorldAtlas/city(at:)``. ``WorldAtlas/water(near:within:)`` returns the nearest ocean or sea (``AtlasWater``) within ``WorldAtlas/oceanReachMetres``. ``WorldAtlas/visit(at:)`` applies all the rules to one accepted fix:

- the ocean or sea within 2 km, never both, since a sea is its own passport entry;
- Antarctica anywhere south of ``WorldAtlas/antarcticaLatitude`` (60°S, on land, ice or sea);
- the nearest city sharing an urban boundary, or a city with no boundary within ``WorldAtlas/townRadiusMetres(for:)``.

``AtlasTerrainClassifier`` maps the Köppen-Geiger code and the latitude to an ``AtlasTerrain``, and picks a few ``AtlasFlora`` (cacti only in the Americas). ``AtlasSeason`` gives meteorological seasons, flipped south of the equator, and none of the four inside the tropics.

Bounded throughout:

- at most 250 seas, 512 countries, 16,384 urban boundaries and 16,384 cities;
- at most 10,000 rings a feature and 200,000 points a ring, with every varint capped at ten bytes;
- the reach search walks at most 81 cells of 256 sub-cells each.

### Its place on the walls

This module holds location history (the lifted fog cells, saved walk and run lines, workout-space pins, Where you've been and the solo photos' places), so it sits on the far side of the S3 wall from every module that sends data anywhere. `CloudKitSync`, `AIProviders`, `AIContext`, `FernletSocial` and `FernletConnections` do not depend on it, and the strict build (`Scripts/spm-wall-check.sh`, `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR`) fails any of them that imports it. It holds no display strings, so it has no string catalog.

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
