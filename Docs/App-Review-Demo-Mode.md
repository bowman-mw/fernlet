# App Review demo mode

Apple's beta review (Guideline 2.1(a), 2026-10-27) asked for a demo account or a demonstration mode.
Fernlet has no accounts and its social features need two iPhones in the same room, so the review build
carries a **demo mode**: a fresh install can fill Fernlet with sample data, a pretend friend and a fixed
passcode, and leave it again.

## Demo builds only

Owner's call (2026-10-29): normal builds neither show the demo button nor carry the sample data.

- The `Demo` build configuration (a copy of Release on every target) sets the Swift compilation
  condition `FERNLET_DEMO` on the **app target only**. The `Fernlet Demo` scheme runs, profiles and
  archives with it; its tests still run Debug.
- Every demo file (`App/Fernlet/ReviewDemo/`) is wrapped whole in `#if FERNLET_DEMO`, and each call
  site is one flat `#if FERNLET_DEMO`. That is the one custom condition Power-of-10 §R8 allows
  (`Docs/Power-of-10-Swift.md`); the scanner and `PowerOfTenBoundaryTests` carry it in their allowlist.
- The walls that count build configurations (`EnhancedSecurityConfigurationTests`,
  `WorldIdentityBoundaryTests`, `AppPermissionDeclarationsTests`) expect three: Debug, Release, Demo.

## Submitting the review build

1. In Xcode, pick the **Fernlet Demo** scheme, then Product → Archive (or
   `xcodebuild archive -project App/Fernlet.xcodeproj -scheme "Fernlet Demo" -configuration Demo …`).
2. Upload it like any build. It ships under the same bundle ID; only its build number tells it apart.
3. In App Store Connect → TestFlight → Test Information → Beta App Review Information, leave
   **Sign-in required** unchecked and paste the review notes below.

### Review notes

> Fernlet has no accounts, sign-in or server; all data stays on the device. To see every feature
> without setting anything up, tap **"Look around with sample data"** under Continue on the first
> screen. It fills the app with two weeks of sample entries and a pretend friend, Juniper. The Private
> passcode is **246810** (it is also shown on the passcode screen and in Settings). Settings → Demo →
> "Leave demo and start fresh" erases the sample data and returns to the first screen.
>
> Meeting friends in person needs two iPhones running Fernlet: with both on Home, holding them
> together (about 15 cm, for under a second) starts a hangout over Ultra Wideband and the local
> network, with no server. The demo shows the result of meeting the pretend friend. Nearby chat
> additionally requires the device's Apple Account to share an age range of 13 or older through
> Declared Age Range, by design.

The friends paragraph follows the tap-to-connect flow (bowman-mw/fernlet#123): meeting someone new
happens by holding phones together on Home, and a live session is a "hangout" in every user-facing
string, so the notes no longer name the retired "Connect" button.

### Test Information (shown to testers)

App Store Connect → TestFlight → Test Information. Feedback email `fernletapp@gmail.com`, marketing
URL `https://fernlet.com`, privacy policy URL `https://fernlet.com/privacy/`.

**Beta App Description:**

> Fernlet is a gentle self-care app: a small pixel companion that lives on a map of your world and
> reflects the food, sleep, movement and rest you choose to log. No streaks, no ads, no tracking, no
> account. Your data stays on your iPhone, or in your own iCloud if you turn on sync.
>
> This beta is for trying Fernlet day to day and telling me what's confusing, what's broken and what
> you love. Take a screenshot and tap Share Beta Feedback, or email fernletapp@gmail.com.

**What to Test** (per build):

> Use Fernlet the way you normally would for a few days: log meals, go for a walk and watch the map
> uncover, try a workout, write in the journal. Most useful: anything confusing in your first five
> minutes, anything that crashes or looks wrong, and anything you'd miss if it were gone. If a friend
> is testing too, hold your phones together on Home to start a hangout.

Before the first tester outside the US or Canada, finish the encryption self-classification
([Export-Compliance-Encryption.md](Export-Compliance-Encryption.md) §6A.4): a public TestFlight link
can reach anyone.

## What the demo does

- **Starts** only from Welcome on a fresh install (`OnboardingCoordinatorModel.startReviewDemo`): sets
  the demo passcode for the Private hub, commits a demo persona (30, female, so the cycle section is
  on as it is for anyone who answers Female), plants the sample data and the pretend friend
  (`FernletStore.seedReviewDemo`, `seedReviewDemoFriend`), closes the hub and opens the app.
- **Keeps everything on this iPhone:** storage stays local, and turning on iCloud sync, the Apple
  Health switch, or the first-workout Health offer is refused while the demo runs.
- **Never fakes the system age check.** Nearby chat opens only on Apple's own age-range answer, and
  the demo build is public, so the persona opens intimacy tracking through the same manual "16 or
  older" confirmation a person uses and leaves chat as the device's own answer leaves it.
- **Leaves** from Settings → Demo (`ReviewDemo.leave`): removes the pretend friend (whose photos the
  delete-everything funnel would otherwise keep, by design), erases everything through
  `FernletStore.deleteAllData`, drops the demo passcode and returns to Welcome.

## What gets seeded

- **Two weeks of days** (`FernletStore+ReviewDemoSeed.swift`): 3–4 meals a day with macros (today's
  first two with sealed photos), strength / run / walk / yoga workouts on 12 days (written through
  `diary.appendWorkout`, never the store's `addWorkout`, which would offer Apple Health), sleep, water
  and personal care every day; four journal entries, three recipes (one with timed steps), three
  progress photos, three memories and three solo-album photos.
- **Cycle:** four 5-day periods 28 days apart — three complete cycles, which the Cycle page needs
  before it shows predictions and period-aware care — sealed with the hub key straight into the
  cycle record store (never `logEvent`, which mirrors to Apple Health).
- **Intimacy:** two entries. Only `ContentView` may build the intimacy funnel
  (`appTargetConstructsTheIntimacyFunnelOnlyInContentView`), so the seed leaves them owed and
  `ReviewDemoLaunchHooks` writes them the first time the Private hub opens.
- **Juniper, the pretend friend** (`FernletStore+ReviewDemoFriend.swift`): a friends-list row over
  freshly generated public keys whose private halves are thrown away (no device can ever answer as
  Juniper), three photos on the album wall, one golden heart, and a two-item shop. Nothing is ever
  sent over the radio. The nearby page shows its three stand-in cards while no real phone is near.

### Known limits

- The golden heart is gold for 12 hours and glows for 24, as any heart does; it is not re-given.
- The friend shop is memory-only, so `ReviewDemoLaunchHooks` reopens its one-hour window at every
  launch while the demo runs.
- Leaving removes Juniper's photos, which leaves the wall's 24-hour re-delivery markers behind
  (harmless), and the shop's saved designer name goes with the delete-everything funnel.
- The demo screens' own words (the Welcome link, the Settings section, the passcode hint) are
  English only: `Scripts/sync-string-catalogs.sh` builds Debug, where they are compiled out.
