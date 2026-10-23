# ``WorldMapStore``

The live-map Home's ground truth: plain geometry for Fernlet's own map layers, and (from later steps) the device-only stores that remember where the fog has lifted. **World build only (branch `world-ui`, never main).**

## Overview

The World build's Home is a live map ("A World for Fernlet", design page v9). Apple's muted map sits behind a small seam in the app target (`App/Fernlet/World/Map/`), and Fernlet draws its own layers on top: the fog, trails, the companion and pins. This module holds everything those layers know about the ground, and nothing about any map provider.

**No map types, ever.** Every position is a ``GeoPoint`` (plain latitude and longitude). A base map reports what it shows as a ``MapViewport`` in normalised Web Mercator, and the layers place themselves from that alone. Phase 2 swaps Apple's map for MapLibre by adding one conformer to the seam; nothing stored here changes. MapKit is imported in exactly one app file, `AppleMutedBaseMap.swift`, which `MapAndLocationConfinementBoundaryTests` pins.

**One fog grid for the whole world.** ``MercatorHexGrid`` lays regular hexagons over Web Mercator, so they stay regular on any north-up map and every ``HexCell`` keeps one stable `Int64` ID. A cell is about 35 m across at 45° (about 25 m radius at the equator, 12 m at 60°): coarse on purpose, so the fog says "you've been round here" and never which door you went in.

**Bounded.** ``Polyline`` keeps at most 50,000 points and samples at most 4,000; a cell query returns at most ``MercatorHexGrid/maxCellsPerQuery``; one fix lifts at most 12 rings. These are the Power of 10 bounds the layers rely on.

### Its place on the walls

This module will hold location history (the lifted fog cells, saved walk lines and workout-space pins), so it sits on the far side of the S3 wall from every module that sends data anywhere. `CloudKitSync`, `AIProviders`, `AIContext`, `FernletSocial` and `FernletConnections` do not depend on it, and the strict build (`Scripts/spm-wall-check.sh`, `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR`) fails any of them that imports it. It holds no display strings, so it has no string catalog.

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
