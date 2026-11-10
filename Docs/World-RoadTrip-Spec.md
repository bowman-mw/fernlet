# World — Road Trip Mode spec (FINAL, owner-approved 2026-11-10)

Review page: https://claude.ai/artifact/HcCCHzX7db9BKF9wvvjvhW. All 10 pieces were approved on 2026-11-10, with no change notes. The page's db collection `decisions` holds the record.

The owner's ask (2026-11-09): "a road trip mode. It would use a mesh session to split the load of location tracking. Each person could take pictures along the way, and they would be geotagged. They would show up on the map when you drive past them in the future. Goal is to get the location, pictures, and tile unlocking while using as little battery as possible."

## 1. Decisions (owner, 2026-11-10)

- **The trip's road is shared**, as an exception to "map history is never shared with friends":
  - only with the people on the trip;
  - only in person, at a stop;
  - only the stretch each person was there for.
  - Everything else on the map stays never-shared.
- **Friends' trip photos go on the map.** Photos anyone takes on the trip may sit on each member's map where they were taken. Hangout and other friends' photos stay off the map, as now. The four "never a friend's photo on the map" enforcement sites get a trip-only exception: WorldPhotoPrints.swift:18, PhotoPlaceStore.swift:7-8, DisposableCameraView.swift:1400 and FernletStore+WorldPlaces.swift:297.
- **A trip photo keeps its spot anywhere on the trip's road.** Outside a trip, the everyday-places rule stays (`PlaceClassifier.photoMayKeepPlace`).
- **Trip photos are always on the map**, from the start, not hidden until you pass.
- **Transport:** the road and photos go over the direct phone-to-phone payload path, never a routed row, so no ProximityKit release is needed. No server.
- **Sub-choices:**
  - Who maps: **auto** (`rt-mapper`).
  - Catch-up: **ask once when a member is nearby** (`rt-catchup`).
  - Friends' photos: **straight onto the map**, no review (`rt-photos`).
  - The end: **also add the trip to the passport's trips** (`rt-end`).

## 2. Approved screens and copy (verbatim)

1. **Start** (`rt-start`):
   - Where: only from a hangout you're in. The green session button's menu gains **Start a road trip**.
   - Up to 5 people (one phone's direct links).
   - The name is optional; the default is "Road trip" plus the date.
   - Sheet title: "Road trip with Rae and Sam".
   - Sheet line: "One phone maps the road while the others rest. At each stop, Fernlet catches everyone up: the road you drove together and the photos you took."
   - Name row placeholder: "Road trip".
   - Buttons: **Start the road trip** · **Not now**.
2. **Join** (`rt-join`):
   - Each friend says yes on their own phone; no means the hangout stays as it was.
   - Title: "Mike started a road trip".
   - Line: "Join, and Fernlet shares the road you drive together and your trip photos with Mike and Sam, in person at each stop."
   - Buttons: **Join** · **Not this time**.
3. **Who maps** (`rt-mapper`, auto):
   - The phone on CarPlay or charging maps. If none or several are, the person who started.
   - It switches by itself at a stop when that changes.
   - **Map from this iPhone** lets anyone take over.
   - The others stay in background mapping's low-power mode until the next stop; passengers' phones must NOT trace the drive.
4. **Home** (`rt-home`):
   - Chip under the status bar: "Road trip · 3". VoiceOver: "Road trip with Rae and Sam, button". Tap → trip info.
   - A passenger's map shows the road up to the last catch-up, see-through like any drive (driven cells, PR #142).
5. **Trip info** (`rt-info`):
   - Rows: "Mapping: Mike's iPhone · Last caught up 2:14 pm · 84 km · 6 photos".
   - Buttons: **Catch up now** (works when another member is nearby with Fernlet open) · **Map from this iPhone** · **Leave the road trip** (map and photos so far stay) · **End the road trip** (ends it for everyone at their next catch-up).
6. **Catch-up** (`rt-catchup`, ask):
   - With Fernlet open and a trip member heard nearby, ask once, never as a notification: "Rae is here. Catch up the road trip?" with button **Catch up**.
   - One tap opens a short hangout, swaps the road and photos, and closes it.
   - After: "Caught up: 84 km of road, 6 photos."
   - **Proof of presence:** you get only the road between two catch-ups you were part of, plus from the start if you were there at the start.
   - Every phone's fog lifts along its stretch as driven cells.
7. **Photos** (`rt-photos`, straight to map):
   - During a trip, Home's camera puts photos on the trip's roll, up to 30 per person.
   - Each photo keeps its capture time. Its place comes from the trip's road at that time: this phone's own line if it was mapping, otherwise from the next catch-up.
   - Friends get your photos at the next catch-up and you get theirs, straight onto the map; any one can be hidden later.
8. **On the map** (`rt-map`):
   - Each trip photo sits where it was taken with a small car stamp.
   - Photos within 40 m share one print, like solo photos.
   - Tap opens the photo with "Road trip to the coast · Nov 10 · Rae". VoiceOver: "Photo from the road trip to the coast, by Rae".
   - A decoy shows none.
9. **End** (`rt-end`, passport):
   - The trip ends when someone taps End the road trip, when everyone has left, or by itself after 7 days without a catch-up.
   - A summary card shows once on Home: "Road trip to the coast · 3 days · 412 km · 1,280 new tiles · 4 towns · 23 photos".
   - The trip is also added to the passport's trips, next to flights and country trips.
   - The trip is kept on each phone like a walk's line: sealed, never synced, deleted with map history.
10. **Privacy** (`rt-privacy`):
    - Privacy policy, all three copies (Docs/Privacy-Policy.md, PrivacyPolicyView.swift, Site/privacy/index.html), plus PrivacyPolicyParityTests markers and the effective date: "If you start or join a road trip with friends you're with, Fernlet shares with them, in person over the same direct connection as a hangout, the road you drove together and the photos you took on the trip, and their phones share theirs with you. Each person gets only the stretch they were there for. It's kept on each iPhone like the rest of your map and photos, and a friend's trip photos sit on your map where they were taken. Nothing goes through a server."
    - NSLocalNetworkUsageDescription (Info.plist, InfoPlist.xcstrings en/es/es-MX, AppPermissionDeclarationsTests): "Fernlet connects directly with nearby friends to share recipes and, during a hangout or road trip you start, photos, short-lived messages, hearts and the road you drove together. A hangout may continue in the background."

Out of scope: live sharing on the road, a bus or train state, and trips with people not kept as friends.

## 3. Constraints found (exploration 2026-11-10)

- **Hangouts:**
  - At most 6 h (`MeshSessionCeiling.ceilingSeconds`).
  - A left, developed or terminated mesh can never be rejoined (`MeshSessionContext` departures).
  - So a trip is a Fernlet-level record (members, ID) that spans a chain of short catch-up hangouts. Each stop is a new mesh.
  - Discovery runs in the foreground only.
  - Background continuation is best effort and decrypts nothing.
- **Payloads:**
  - A routed row would need a new ProximityKit token (fixed 4-field `RoutedTypes`, PK pinned 0.1.2), so use the direct path.
  - Direct path: `registerPayloadHandler(forToken:)` plus `sendFeatureEnvelope(_:encodable:via:sealed:)` (committed slots only, best effort). Model it on `FriendStateExchange.swift:69` and the clothing catalog.
  - Needed: a `PayloadType` case (FernletDomainModel/PayloadType.swift) and a capability token in the frozen, signed order (FernletMeshCapabilities.swift).
  - **OPEN:** the direct envelope size limit for photos (the routed photo row's cap is 10.5 MB; check the envelope or frame cap). If photos don't fit, chunk them or send thumbnails plus originals later.
- **Module walls:**
  - FernletSocial and FernletConnections cannot import WorldMapStore, so use a wire point type in FernletSocial, or convert in the app.
  - CoreLocation stays in WorldLocationSource.swift.
- **No line today:** drives keep no line (`WorldRideKeeper` is memory-only), and `RoutePoint` has no timestamp. A timed trip line is needed (lat, lon, t), thinned and bounded.
- **Name clash:** `WorldTrip*` and `Trip` are taken (Take a trip, passport trips, `FlightDetector.Trip`). Prefix new types `RoadTrip…`.
- **Who can join:** a hangout commit needs a UWB dwell, a manual confirm or QR. For catch-ups, use presence (kept friends' rotating tags) plus the manual-confirm path. **OPEN:** whether a hangout with a specific recognised kept friend can start from presence with one tap (check FriendsNearbyPage and TapToConnect).
- **Data rules:**
  - Every new store needs wipe and duress coverage: a Docs/PrivacyWipeCoverage.md row, PersistedSurfaceWipeBoundaryTests for any defaults key, nothing in a decoy, and recovery-lock handling like map history.
  - Sealed files go in WorldMapVault, reusing a purpose with its own context per the `places-marks.bin` precedent, or a new purpose registered in CryptographicDomainSeparationTests.
  - Localization: every display string in es and es-MX (LocalizationBoundaryTests es-MX completeness). Tokens stay English.
  - Power-of-10 and doc-coverage scans. `MapAndLocationConfinementBoundaryTests`.

## 4. Suggested PR plan

1. **Trip core:**
   - The `RoadTrip` record and store, sealed in the vault.
   - The timed trip line recorder: this phone records while it maps; passengers suppress drive tracing while a trip is active.
   - Mapper rules.
   - Home chip and trip info, local only.
   - Wipe and decoy coverage.
2. **Mesh exchange:**
   - The PayloadType and capability token.
   - `RoadTripExchange` in FernletSocial: invite, join, catch-up swap (segments since the last common catch-up, members' presence ledger, mapper state), applying the proof-of-presence rule.
   - Start a road trip from the session menu, the join prompt, the catch-up prompt from presence, and the toast.
3. **Photos:**
   - The trip roll on Home's camera, up to 30 each.
   - Places from the line by timestamp, interpolated.
   - Friends' photos received at catch-up.
   - Prints with the car stamp on the map, and the photo detail.
4. **End:** summary card, passport trips, auto-end after 7 days.
5. **Privacy text:** policy (three copies plus parity markers), Local Network string, Spanish.

Phone checks need two or three iPhones in a car: start a trip, drive with one mapping, catch up at a stop, take photos on each, check prints and the passengers' see-through road, and end the trip.
