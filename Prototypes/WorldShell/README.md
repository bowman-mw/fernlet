# WorldShell: the live-map Home, as a shell to live with

**Non-shipping prototype. Fixture data only.** This is step 2 of the redesign on the design page
"A World for Fernlet" (version 9): a one-week shell of the live-map Home to carry around on a phone
for a few days. It is not part of the Fernlet app, and nothing here ships.

- **Branch rule:** this folder lives on the local branch `world-ui` only. It never goes to `main`
  and is never pushed.
- **Its own app:** the bundle ID is `MBO.Fernlet.WorldShell` and the name on the Home Screen is
  "World Shell". It has its own data container, so installing it on the owner's phone can't touch
  the real Fernlet app's data. It also keeps no data of its own, so every relaunch starts fresh.
  Never install a build of the main `Fernlet` target from this branch.
- **No dependencies:** there's no FernletKit, no package, and no change to any shipping target or
  `Package.swift`. It uses SwiftUI and MapKit only.
- **Where its rules come from:** the repository's scanners don't run on `Prototypes/`, but this
  code passes them when pointed here. `Scripts/doc-coverage-scan.py` finds 0 undocumented types.
  `Scripts/power-of-10-scan.py` finds 0 violations: functions of 60 lines or fewer, no force
  unwraps or `try!`, bounded loops. The one exception is assertion density, which is 0.30 against
  the shipping floor of 0.68; that's acceptable for a prototype. The project builds with Swift 6,
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and warnings as errors, like the watch shells.

## What's real and what's fixture

| Piece | In the shell |
| --- | --- |
| Base map | **Real.** Apple's map through SwiftUI `Map`, styled `.standard(emphasis: .muted, pointsOfInterest: .excludingAll)`, north-up and flat. Night switches it to the dark style. MapKit draws the "Apple Maps" logo and the "Legal" link itself. The shell lifts them above the item bar with a bottom safe-area inset and cuts a small clear patch in the fog and the wash so they're never covered. |
| Map seam | **Real.** `Map/WorldBaseMap.swift` is the protocol a base map conforms to. Only `Map/AppleMutedBaseMap.swift` imports MapKit. A base map reports what's visible as a `MapViewport` in normalised Web Mercator, and Fernlet's layers place themselves from that alone. `PlainBaseMap` is a second conformer with no tiles: the offline look of answer 30, and proof that the layers don't depend on Apple. For phase 2, add a MapLibre conformer and a `BaseMapKind` case. |
| Coordinates | **Real types, fixture values.** Every layer stores `GeoPoint`, which is plain latitude and longitude, never a MapKit type. |
| Hex fog | **Real drawing, fixture history.** The hexagons are about 60 m across (35 m radius), on a grid laid on the ground (`Geo/HexGrid.swift`). Lifted cells come from fixtures: around home, along saved trails, at known places, and along this session's walks and rides. Frontier cells are lighter. |
| Trails | **Fixture.** Saved routes are drawn as solid lines. This session's walks are drawn as dotted footsteps. |
| Companion | **Real art, fixture state.** A 20 × 22 pixel sprite at 2×, with no blue dot. Its colours, breath tempo, low-energy eyes and mouth heights are copied from the shipping `CompanionState` (`ModelColors.swift`, `CompanionVectorAssets.swift`). It breathes by swapping two frames at the state's tempo, and Reduce Motion holds one frame. Tap to pet: it hops and a heart rises. Pet again within 3 s for the settled pose. Hold for 0.45 s to customise. Riding in the car or on the bike it uses the design page's car and bike sprites. The Today panel uses a crisp vector port of `CompanionView`. |
| Markers | **Fixture.** A star on the noodle bar (starred after three meals), a flag at the saved trail's start, and your own lunch photo and hike photo where they were taken. Friends' photos never go on the map. |
| Status bar, left | **Fixture numbers, real rules.** Six hearts with halves (HealthBar's 12 segments, two per heart), then up to 2 gold hearts. Protein, carbs and fat bars against 90 / 230 / 65 g. Eight water drops. It's one button that opens Today. VoiceOver reads "Care score 58 percent…". |
| Status bar, right | **Real clock, fixture coins.** The clock shows the real time, with the sky phase from the shipping hour mapping (`CompanionDayPhase`). Choosing a fixture time of day shows the page's sample time instead. Coins come from "Time with Fernlet". There's no day badge. |
| Time of day | **Real colours.** The map wash uses `CompanionAmbienceLayer`'s tint stops: dawn and day rise from the top, dusk from the bottom, and night is a blue wash over the dark map. |
| Photo wall | **Fixture.** A strip of four overlapping friend prints with no captions. Tap it for the full wall, which includes Recent bites. The photos are colour washes with a symbol. |
| Item bar | **Fixture panels.** Food, Move, Log (raised, centre), Friends, Private and Settings, with names under the icons. Each opens a framed panel built from fixture versions of today's screens. Rows that would open another screen say so in a toast. |
| Today panel | **Fixture.** The companion card with Customize, then Today, Macros, Gold hearts, Trends, Milestones, Body signals, the stamp book, Silly stats and First Aid. |
| Blue button | **Real matching, fixture places.** `Model/QuickStart.swift` matches the companion's position against known places within 100 m. Home space offers Upper body (6 exercises). Riverside Gym offers Upper body (7 exercises). The Oak Park loop start offers the hike, which replays the saved trail. Hoshi Noodle Bar offers "Log your usual: tonkotsu ramen" and a menu search by name. Anywhere else, it offers Walk together. On a resting or sick day the card adds "Resting counts today". |
| Walks | **Recorded, replayed.** A walk together, or the hike, plays back recorded coordinates at about 12× (roughly 17 m/s). The camera follows, the fog lifts along the line, and a walk bar shows the distance with End. When it ends, a toast says the distance and how many tiles it uncovered. |
| Car and bike | **Recorded, replayed.** In a car, the companion rides along a recorded drive. Quick starts and the photo strip pause, and the fog lifts only the cells the road passes through. On a bike, it pedals a recorded loop. Back on foot, a ride over 300 m logs itself, "Bike ride logged · 1.8 km · counts as movement", with Undo. The first ride earns the "Wheels and Waves" stamp banner. |
| Decoy session | **Fixture.** It hides all map history: lifted fog (except where you stand), trails, pins and photos on the map. The blue button only offers a walk. Private opens to empty cards. Walks taken during decoy vanish when it ends. |
| Private | **Fixture.** "Where you've been" shows today on a 30-day timeline. "Places you return to" shows visit counts only, with no dates. |
| Logging | **Fixture.** Water adds a drop, with Undo. The first Meal is a cookie, which earns the Crumb Goblin stamp and nudges the macros. The other tiles say what would open. |

**Networking:** only Apple's map tiles, which MapKit fetches for the visible area. There's no GPS,
no location permission, no HealthKit, no persistence, and nothing else leaves the phone.

## The fixture neighbourhood

The fixture is fixed around **Laurelhurst Park in Portland, Oregon**, a public park chosen as a
neutral example. It is nobody's real home. The places are real street corners with the design
page's made-up names. The routes come from Apple's walking and driving directions between fixed
waypoints, so they follow real streets and park paths. `Tools/make-routes.swift` is the
developer tool that produced `WorldShell/Fixtures/RecordedRoutes.swift`. It is not part of the app.

Because nothing uses GPS, the shell shows Portland wherever the phone is. Outdoors, the companion
moves only when a walk or ride is replayed. To move the fixture to another area:

1. Change the waypoints in the tool.
2. Change the spots in `Fixtures/WorldFixtures.swift`.
3. Change the grid origin in `WorldFixtures.grid`.
4. Re-run the tool.

## Fixture controls

Open **Settings → Prototype fixtures** to change:

- where you are;
- how you're moving (on foot, bike, or car or bus);
- the decoy session;
- the time of day (or the live clock);
- the companion's state;
- time with Fernlet (day one, a month or a year);
- the base map (Apple's muted map, or no map);
- **Replay the walk**;
- **Reset fixtures**.

The same states can be set at launch with arguments. Arguments are read from the `UserDefaults`
argument domain, so nothing is stored. The full list is in `Fixtures/ShellLaunchOptions.swift`.

```sh
xcrun simctl launch <device> MBO.Fernlet.WorldShell -shellSpot gym -shellQuickStart YES -shellPhase dusk
```

## Build and run

Run from the repository root. DerivedData goes under `~/Library`, never inside `App/`.

```sh
xcodebuild build -project Prototypes/WorldShell/WorldShell.xcodeproj -scheme WorldShell \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath ~/Library/Developer/Xcode/DerivedData/WorldShell
```

The screenshots were taken on a private simulator, "WorldShell iPhone 17" (iOS 26.5), not on the
shared "iPhone 17". To run it on a phone:

1. Open `Prototypes/WorldShell/WorldShell.xcodeproj` in Xcode.
2. Pick the phone and press Run. Signing is automatic with team `3RTUPF8FFH`.

## Screenshots (`Screenshots/`)

| File | State |
| --- | --- |
| `01-home-day.jpg` | Home at midday, a month in: hearts 58% plus 1 gold, macros, 4 of 8 drops, clock and coins, the photo strip, the fog lifted around home and along the saved route, "At Home space" and the blue button, Apple's credit above the bar |
| `02-today-panel.jpg` | The Today panel the hearts open, in Home's order |
| `03-quickstart-gym.jpg` | Quick start at Riverside Gym |
| `04-quickstart-noodle-year.jpg` | Quick start at the noodle bar, a year in (2 gold hearts, 1,180 coins, three saved routes) |
| `05-walk-replay.jpg` | A walk together being replayed: the walk bar, the dotted trace, the fog lifting |
| `06-car-dusk.jpg` | Riding along in a car at dusk: quick starts and the strip paused, a thin line of fog lifted |
| `07-bike-ride-logged.jpg` | Back on foot after a ride: "Bike ride logged" with Undo, and the "Wheels and Waves" stamp |
| `08-decoy.jpg` | A decoy session: no history, no pins, and only Walk together |
| `09-night-trail.jpg` | Night at the trail start: dark muted map, dark fog, moon in the clock, the hike offered |
| `10-offline-plain.jpg` | The same layers on no map at all (offline look, and the seam's second base map) |
| `11-settings-fixtures.jpg` | Settings with the prototype fixtures and the Home map settings |
| `12-private-unlocked.jpg` | Private opened: Where you've been, and Places you return to |
| `13-customize-glasses.jpg` | Customize (also opened by holding the companion), with the pixel preview in round glasses |
| `14-photo-wall.jpg` | The full photo wall the strip opens |
| `15-sick-day-one.jpg` | Day one on a sick day at dawn: the blanket, no history, and "Resting counts today" |

## Known differences and limits

- Fernlet's layers redraw from MapKit's continuous camera callback. During a fast fling they may
  trail the map by a frame. If that shows on the phone, the live-map build should move them into
  a single `UIView` layer driven by the map view.
- Panning the map stops it following the companion. The crosshair button, "Back to Fernlet",
  brings it back.
- The settled pet pose lasts 20 seconds here; the app's lasts ten minutes. Gold hearts, coins,
  visit counts, stamps and photos are fixed by "Time with Fernlet".
- These parts of the design page are not in this shell: friends on the map, shared places, the
  Always setting and its timeline, the photo-wall alternatives, and the pixel map look (phase 2).
