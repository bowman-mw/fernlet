# ``WorldMapStore``

The live-map Home's ground truth: plain geometry for Fernlet's own map layers, and the sealed, device-only stores that remember where the fog has lifted. **World build only (branch `world-ui`, never main).**

## Overview

The World build's Home is a live map ("A World for Fernlet", design page v9). Apple's muted map sits behind a small seam in the app target (`App/Fernlet/World/Map/`), and Fernlet draws its own layers on top: the fog, trails, the companion and pins. This module holds everything those layers know about the ground, and nothing about any map provider.

**No map types, ever.** Every position is a ``GeoPoint`` (plain latitude and longitude). A base map reports what it shows as a ``MapViewport`` in normalised Web Mercator, and the layers place themselves from that alone. Phase 2 swaps Apple's map for MapLibre by adding one conformer to the seam; nothing stored here changes. MapKit is imported in exactly one app file, `AppleMutedBaseMap.swift`, which `MapAndLocationConfinementBoundaryTests` pins.

**One fog grid for the whole world.** ``MercatorHexGrid`` lays regular hexagons over Web Mercator, so they stay regular on any north-up map and every ``HexCell`` keeps one stable `Int64` ID. A cell is about 35 m across at 45° (about 25 m radius at the equator, 12 m at 60°): coarse on purpose, so the fog says "you've been round here" and never which door you went in.

**Bounded.** ``Polyline`` keeps at most 50,000 points and samples at most 4,000; a cell query returns at most ``MercatorHexGrid/maxCellsPerQuery``; one fix lifts at most 12 rings. These are the Power of 10 bounds the layers rely on.

### The sealed history

``WorldMapVault`` is the only place the map's history is written. Every file is AES-GCM sealed with its own authenticated purpose (`FernletCryptoPurpose.AEAD.worldMapFogV1`, `worldMapPendingV1`), written with file protection, and kept in `Application Support/WorldMap`, a folder excluded from device backups. Its two keys (``WorldMapKeys``, ``WorldMapKeyRole``) are this-device-only rows under `com.fernlet.world-map`:

- the **store** key is `WhenUnlockedThisDeviceOnly`, so the fog can only be read or written while the phone is unlocked;
- the **buffer** key is `AfterFirstUnlockThisDeviceOnly`, for the small locked-phone buffer alone: a walk with the screen off, or Always mode's visits, lift cells while the phone is locked, and those wait there until the next unlock drains them into the store. The same split as `PendingNarrativeBuffer`, for the same reason.

A key that can't be read right now is an error, never a reason to mint a new one over it; a file that can't be opened (its key gone, its bytes damaged) is removed, so the map starts fresh rather than carrying noise.

``FogCellStore`` holds the lifted cells: at most ``FogCellStore/maxCells`` (a lifetime of walking one city), with ``FogCellStore/maxPendingCells`` waiting in the buffer, stored in ``FogCellCodec``'s compact delta form. Past a cap new cells are refused and counted, never an eviction of old history. It never decides whether to lift: the app's `WorldFogKeeper` does (precise location, "Uncover the map as you go" on, no decoy session).

**Wipes.** ``WorldMapVault/clearAll()`` removes the folder and both keys. Delete everything and the duress silent wipe reach it through `FernletStore.resetAll()`; the duress recovery lock through its own purge hook (design page answer 16). A decoy session never reads or writes it.

### Its place on the walls

This module holds location history (the lifted fog cells now; saved walk lines and workout-space pins in later steps), so it sits on the far side of the S3 wall from every module that sends data anywhere. `CloudKitSync`, `AIProviders`, `AIContext`, `FernletSocial` and `FernletConnections` do not depend on it, and the strict build (`Scripts/spm-wall-check.sh`, `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR`) fails any of them that imports it. It holds no display strings, so it has no string catalog.

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
