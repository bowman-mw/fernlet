# Design — screenshot & screen-capture protection for the Private tab (2026-08-10)

**Status:** Design brief. Not built, not scheduled. Verified against the working tree at
`main` @ `abd983d`; every file:line below was read, not inferred.

**What this is.** Two tiers of capture friction — a screenshot *reaction* (Tier 1) and a
capture/mirroring *cover* (Tier 2) — applied only to the Private tab's surfaces: the Journal, the
merged Cycle page (period + intimacy), the Worry Box, and their sheets and detail views. Both tiers
are ordinary public API (`UIApplication.userDidTakeScreenshotNotification`,
`UIScreen.capturedDidChangeNotification`, `scenePhase`) and pure UI. There is nothing like it in the
tree today: a repo-wide grep for `isCaptured`, `capturedDidChangeNotification`,
`userDidTakeScreenshotNotification`, `isSecureTextEntry`, and every common "screen shield" spelling
across `Fernlet/`, `FernletKit/`, and `FernletWidgets/` returns zero hits. `UIScreen` is never
referenced anywhere in the app.

**What this is not.** This is **friction, not a guarantee.** It cannot prevent a screenshot; it
reacts after one. It cannot prevent a photograph of the screen. A user who wants to publish their
own journal entry will publish it. The owner has considered this and judged the trade worthwhile on
an explicit premise, which is the whole rationale for the feature:

> The realistic way this data becomes public is that the person it belongs to shares it themselves —
> impulsively, in a group chat, at 1am. Raising the friction on casual self-sharing should reduce
> how often that happens. Nothing here is aimed at an attacker.

That premise is worth stating plainly in the code comments too, so a future reader does not mistake
this for a security control and start reasoning about it as one.

**Relationship to the security-hardening runbook: none.** This is *not* a phase of
[`Plan-Security-Hardening-Runbook.md`](Plan-Security-Hardening-Runbook.md) and must not be folded
into its ledger. That runbook moves key custody, at-rest formats, and deletion semantics — things
with mechanical, testable guarantees behind them. This changes no key, no format, no store, and no
wall; it draws rectangles over views. Sequencing it alongside runbook phases would imply an
equivalence of strength that [`Verifiability.md`](Verifiability.md) §5 exists specifically to deny.
Treat it as independent future work, schedulable whenever, and describable to users only in the
weaker register (see §4's copy rules).

---

## 1. Threat model and honest limits

The population this helps is *the user*, acting against their own later regret. Every row below is
stated in that frame.

| Case | Tier | What actually happens | Honest read |
|---|---|---|---|
| Impulsive self-screenshot of a journal entry / cycle detail / worry note | 1 | Screenshot succeeds. The app blurs the surface for ~2 s and shows a one-time nudge. | Pure after-the-fact friction. The image already exists in Photos. The value is the pause before it is sent, and the reminder that this is the sealed corpus. |
| Screen recording (Control Center) with a private surface open | 2 | `isCaptured` goes true; an opaque panel covers the protected views for the whole recording. | Genuinely effective for its case: the recording contains the panel, not the content. Stops the "I recorded my whole screen and forgot the journal was open" accident. |
| AirPlay **mirroring** to a TV / Mac | 2 | Same as recording — mirroring sets `isCaptured` on the mirrored screen. | Effective. This is the most common accidental-broadcast path. |
| QuickTime capture over USB, ReplayKit-based screen-share apps | 2 | Same path; `isCaptured` covers these. | Effective for the same reason, with the same limits. |
| App-switcher / Control Center / notification-shade snapshot | 2b | Cover paints on resign-active, so the OS snapshot is the cover. | Effective, and the one case with an existing in-repo precedent (`Fernlet/ProgressPhotoTimeline.swift:65`, `:167`). |
| **A second camera pointed at the screen** | — | Nothing happens. | The analog hole. Unclosable by any app on any OS. |
| **A determined self-sharer** | — | They will screenshot anyway, or type the text out, or record with another phone. | Out of scope by construction. This feature targets impulse, not intent. |
| A malicious app on the same device, a jailbroken device, forensic imaging | — | Out of scope here; addressed (to the extent it can be) by the lock service and key custody — see [`Verifiability.md`](Verifiability.md) §4–§5. | Capture protection adds nothing against these and must not be cited as if it did. |

### 1.1 Tier 3 is ruled out

The known third tier is the `UITextField.isSecureTextEntry` trick: host arbitrary SwiftUI content
inside the private secure-canvas layer of a secure text field so the system omits it from
screenshots and recordings. **Not doing it.** It depends on an undocumented private view hierarchy
that Apple has silently reshaped across releases (so it breaks on an OS point update with no
compile-time signal), it is App-Store gray at best, and reparenting real content into a secure text
field's canvas costs VoiceOver correctness, Dynamic Type behavior, and hit-testing — the exact
things this app is careful about. The gain would be "the screenshot is blank instead of blurred a
moment later," which is not worth a fragile, inaccessible, undocumented dependency in the one part
of the app that holds the sealed corpus. Scope is Tiers 1+2, full stop.

### 1.2 Why the Netflix approach does not port

The common objection is "streaming apps show a black frame — why can't we?" Because that is not an
app capability. A FairPlay-protected video decodes inside a hardware secure video path; the OS
compositor honors the DRM flag on **that surface** and substitutes black in the framebuffer copy fed
to screenshots and recorders. The app never asks for it and cannot extend it. There is no public
(or even private-and-stable) way to mark an arbitrary `CALayer` of SwiftUI text as DRM-protected, so
no amount of engineering gets a Fernlet journal entry into that path. Anything that claims otherwise
is Tier 3 wearing a hat. This is worth writing down because it is the first question anyone asks and
the answer changes the feature's ceiling.

---

## 2. Scope

### 2.1 In scope — and the attach points

There is **no single attach point that covers everything**. The hub root covers the three pages and
their pushed detail views; every sensitive *sheet* presents in its own presentation context and must
be covered separately. Six attachments is the floor, not a preference.

| # | Surface | Attach at | Notes |
|---|---|---|---|
| 1 | Private hub: Journal + Cycle + Worry Box pages, **and** their pushed details | `Fernlet/PrivateHubView.swift:83` — same modifier chain as the existing `.fernletLockGate(scope: .privateHub, …)`, after `.background(Color.parchment)` (`:78`) | The hub body is a paged `TabView` (`:61`) holding `JournalView` (`:63`), `CycleTrackerView` (`:65`, conditional), `WorryBoxView` (`:68`). `navigationDestination` content renders inline in the same presentation host, so `DayDetailView` (`Fernlet/JournalView.swift:802`, pushed at `:93`) and `CycleDayDetailView` (`Fernlet/CycleDayDetailView.swift:21`, pushed at `Fernlet/CycleTrackerView.swift:102`) are covered for free. `WorryBoxView` (`Fernlet/WorryBoxView.swift:361`) presents no sheets at all — its composer is inline (`:396-420`), so the hub attachment fully covers it. |
| 2 | `JournalSheet` | `Fernlet/JournalView.swift:136` (body; struct at `:119`) | Presented from the root router at `Fernlet/ContentView.swift:538`. Also raised from the Journal page (`JournalView.swift:33`, `:51`), Home's quick-log tile (`Fernlet/HomeView.swift:985`), a notification tap (`ContentView.swift:314`), and the "Write in my journal" App Intent (`ContentView.swift:307`). |
| 3 | `JournalEntryEditorSheet` | `Fernlet/JournalView.swift:455` (body; struct at `:428`) | Two call sites, both in scope: `JournalView.swift:101` and `DayDetailView`'s `:945`. Attaching at the type covers both with one edit. |
| 4 | `DayEditSheet` | `Fernlet/JournalView.swift:1260` | Presented from `DayDetailView` at `JournalView.swift:939`; reachable only by pushing from the Journal calendar. |
| 5 | `LogPeriodSheet` | `Fernlet/LogPeriodSheet.swift:63` (body; struct at `:18`) | Presented from the root router at `Fernlet/ContentView.swift:613`; raised from the Cycle page (`CycleTrackerView.swift:113`) **and** Home's quick-log tile (`HomeView.swift:989`). |
| 6 | `LogIntimacySheet` | `Fernlet/LogIntimacySheet.swift:32` (body; struct at `:18`) | Presented from the root router at `Fernlet/ContentView.swift:620`. |

**Attach inside each sheet type's `body`, not at the call sites.** Three of the five sheets have two
or more presenters; typing it at the sheet root is one edit each, cannot be forgotten at a new call
site, and cannot bleed onto an out-of-scope screen — a modifier on a sheet's own root draws only
inside that sheet.

A consequence to accept deliberately: because `JournalSheet` and `LogPeriodSheet` are presented from
the **root** router (`ContentView.swift:73`), which sits above the tab `TabView`, they can be opened
while Home is the underlying tab. Attaching at the type means protection engages there too. That is
the correct content-privacy answer (the sensitive text is on screen regardless of which tab is
behind it) and it does not touch the Home page itself — but it is an owner-visible behavior, listed
in §9.

### 2.2 Explicitly out of scope

Recipes (`RecipeBookSheet` / `RecipeSheet`, `ContentView.swift:520-525`), Milestones (instantiated
inside `HomeView.swift:177`), Home / companion, Settings (`ContentView.swift:574`), Trends
(`:588`), and the Food / Move / Social tabs. These are structural **siblings** of `PrivateHubView`
in `pagedTabs` (`Fernlet/ContentView.swift:417-449`), so a hub-scoped modifier physically cannot
reach them — the scope boundary is enforced by the view tree, not by discipline.

### 2.3 The Home tab renders in-scope *content* on an out-of-scope *screen*

Three leak surfaces sit outside the boundary as drawn. The owner has ruled on one; two remain open,
and they are **not** the same question.

**DECIDED — the cycle-outlook bubble stays capturable** (`AmbientCards.swift:381-400`, text builder
`:402-410`, fed by `homePeriodPrediction` at `HomeView.swift:614-617`). Owner, 2026-08-10: *"On the
main page, I think it's fine to take screenshots of that data. The full calendar view is the issue."*
The governing distinction: **the Home card is a derived summary** (roughly where you are in your
cycle, one predicted date), **the Cycle calendar is the raw record** (every logged day, flow level,
intimacy marker, and the notes behind each). Protecting a one-line prediction would cost real
usability — people legitimately screenshot their companion and its cards — for very little privacy
gain. Do not re-raise this.

**STILL OPEN — `lookingBackCard`** (`Fernlet/AmbientCards.swift:201-215`, computed at `:222`)
renders **decrypted journal text** from a past day on the Home tab. Note that the decided rationale
*cuts the other way here*: this is not a derived summary, it is verbatim sealed-corpus prose — the
raw record — surfaced on the tab a user is most likely to screenshot to show off their companion.
It is the strongest case in the app for a narrow exception. Recommendation: apply the modifier to
this **card**, not to the Home screen.

**STILL OPEN — the First Aid worry composer.** `WorryEntryView` (`Fernlet/WorryBoxView.swift:24`)
is pushed inside `FirstAidView`'s stack (`Fernlet/FirstAidView.swift:122`), presented as a root
sheet case (`ContentView.swift:604`) and reached from Home's `.worryBox` tile (`HomeView.swift:1004`).
This is where worry text is actually *typed*, so "worry box including its sheets" arguably already
covers it — but First Aid also hosts breathing and grounding tools that are not sensitive, so
covering the whole sheet over-applies. Recommendation: protect `WorryEntryView` itself wherever it
is hosted, leaving the rest of First Aid alone.

For both open items the mechanism is the same narrow one: attach `captureProtected()` to the
**component**, not the screen, so the surrounding Home/First Aid content stays capturable.

---

## 3. Tier 1 — the screenshot pulse

**Trigger.** `UIApplication.userDidTakeScreenshotNotification`. It is app-wide, posts *after* the
pixels are captured, and carries no scene attribution.

**Reaction.** On a protected surface that is currently frontmost:

1. Blur the surface (a real `.blur(radius:)` plus a slight desaturation reads better than an opaque
   fill here — the user knows what they just did; the point is a beat of hesitation, not alarm) for
   a short fixed interval, then clear on its own.
2. Once — see §9 on frequency — show a small, calm nudge in the voice of the existing per-surface
   privacy copy (`Fernlet/CycleTrackerView.swift:294-310` is the tonal precedent):

   > **This is your private data — it stays safest on your device.**
   > A screenshot leaves Fernlet's protection behind.

**Copy rules.** The nudge must not imply the screenshot was blocked, degraded, or logged. It was
not, and this repo's documentation posture ([`Verifiability.md`](Verifiability.md) §5,
[`No-Tracking-Wall.md`](No-Tracking-Wall.md) §6) is unusually strict about not over-claiming.
Nothing about the screenshot leaves the device, nothing is recorded, and the copy should not create
a suspicion that either happened.

**Frontmost gating is a correctness requirement, not polish.** Both `TabView`s are paged and keep
their children alive — the outer `pagedTabs` (`ContentView.swift:417-449`) and the inner hub
`TabView` (`PrivateHubView.swift:61`). `PrivateHubView` therefore exists and evaluates while the
user is on Home. Without a frontmost gate, a screenshot of the Home tab fires a private-tab nudge.
Gate on the observable state plus `selectedTab == .personal` (`ContentView.swift:53`, `:417`) for
the hub attachment; sheet attachments are self-gating because a presented sheet *is* frontmost.

Do **not** gate on `.onAppear`/`.onDisappear` — page-style `TabView` lifecycle events are documented
in this codebase as unreliable (`FernletKit/Sources/FernletLockUI/FernletLockGate.swift:11-15`,
`ProgressPhotoTimeline.swift:42-47`). Render from state.

---

## 4. Tier 2 — the capture cover

**Trigger A — active capture.** `UIScreen.capturedDidChangeNotification` plus an initial read of
`isCaptured` at mount. While true, draw an **opaque** panel over the protected views for the entire
duration of the recording / mirroring session, with a short line explaining why ("Hidden while your
screen is being recorded"), and clear it when `isCaptured` goes false.

Opaque, not blurred: the lesson is already recorded in this repo. `ProgressPhotoTimeline.swift:498`
notes that an earlier partial cover redacted only the picture and left the capture date and caption
legible in the snapshot. Cover the **whole surface**, not the sensitive-looking widget.

**Trigger B — resign-active snapshot blanking.** Paint the same cover when `scenePhase != .active`,
exactly as `ProgressPhotoTimeline.swift:65` / `:167` (strip) and `:388` / `:501` (detail) already do
for body photos. Use `!= .active`, not `== .background`: the app switcher can be entered without a
true background transition, and that is precisely the gap.

Two interactions to get right:

- **The existing background re-lock already covers part of this.** `Fernlet/FernletApp.swift:137`
  calls `lockService.lock(reason: .background)` on a true background transition, which scrubs the
  content key and flips the gate to `.locked`
  (`FernletKit/Sources/FernletLock/FernletLockService.swift:1022-1026`), so `FernletLockGateModifier`
  paints its unlock overlay over the hub. Whether SwiftUI commits that render before iOS takes the
  snapshot is unverified and needs an on-device check (§9). If it does, Trigger B is only closing
  the `.inactive`-only path — which is still worth closing, and still leaves the five sheets
  uncovered, since the lock gate does not reach them either.
- **Face ID bounces the scene through `.inactive`.** Documented twice
  (`FernletLockGate.swift:11-15`, `ProgressPhotoTimeline.swift:42-47`), with a 1500 ms suppression
  window at `FernletLockGate.swift:120-141` and a verbatim second copy at
  `ProgressPhotoTimeline.swift:85-108`. A resign-active cover **will** flash during every biometric
  prompt. `ProgressPhotoTimeline` accepts exactly that today, so it is precedented rather than
  novel — but see the ordering decision in §5.3, which determines whether the flash can ever sit on
  *top* of the passcode field.

### 4.1 Multi-scene and external-display correctness

`UIScreen.main` is both deprecated and **wrong here**. The built `Info.plist` carries
`UIApplicationSupportsMultipleScenes: true` (from `Fernlet.xcodeproj/project.pbxproj:578-579`), the
device family is iPhone + iPad (`pbxproj:604`), and all four iPad orientations are enabled
(`pbxproj:586`) — so Stage Manager and Split View can run two Fernlet windows. Deployment target is
iOS 26.5 (`pbxproj:588`), so every API here is available unconditionally and there is no reason to
reach for a deprecated one.

Rules:

- **Resolve the screen from the view's own window scene.** A small `UIViewRepresentable` probe
  inside the modifier reports `view.window?.windowScene` upward; read `windowScene.screen.isCaptured`.
  The only existing scene traversal in the app is `UIApplication.shared.connectedScenes` at
  `Fernlet/FernletApp.swift:107-108` — do **not** copy that shape for per-view state; it cannot tell
  which window the modifier is in.
- **Observe `capturedDidChangeNotification` with `object: nil`** and re-read the modifier's own
  screen on each post, rather than trusting the notification's subject. Per-screen state, one
  observer.
- **A genuinely separate external display is not "captured."** AirPlay *mirroring* sets `isCaptured`
  on the mirrored screen (good, and it is the case we care about). A non-mirrored external display
  showing different content is a distinct, uncaptured screen. The app creates no external-display
  scene today, so this is a forward-looking constraint: if one is ever added, it must not render
  private surfaces, because Tier 2 will not cover it.
- **The screenshot pulse cannot be scene-targeted.** `userDidTakeScreenshotNotification` is
  app-wide, and the system screenshot captures the whole display anyway. With two windows open the
  honest behavior is to react in every foreground-active protected surface rather than pretend to
  attribute it.

---

## 5. Architecture

### 5.1 `CaptureProtectionState` — one observable

A `@MainActor @Observable` service owning exactly two things: `isCaptured` (per the resolved window
scene) and a screenshot *pulse* (a monotonically increasing token or a timestamped event that views
observe). It installs both `NotificationCenter` observers once and is injected via `.environment(…)`.

This matches the app's established service shape — `WorryBoxService`
(`Fernlet/WorryBoxService.swift:42`), `StressService` (`Fernlet/StressService.swift:57`),
`AgeAssuranceStore` (`Fernlet/AgeAssuranceStore.swift:20`), `ConnectionInspector`
(`Fernlet/Proximity/Audit/ConnectionInspector.swift:29`) — and the observer template is
`FernletKit/Sources/ProximityKit/HeartSharing/ProtectedSidecar.swift:172-191`: `#if canImport(UIKit)`,
`addObserver(forName:object:queue:)` with `[weak self]`, an explicit `Task { @MainActor [weak self] in … }`
hop, token stored and removed in `deinit`. The comment at `:174` is the load-bearing one — *the block
runs nonisolated under Swift 6; never touch state directly, hop first.* A second stored-token example
is `Fernlet/FernletStore.swift:4348-4356`.

One observer is sufficient even while a sheet is up: SwiftUI does not fire `.onDisappear` on a view
covered by a `.sheet` (`FernletLockGate.swift:7-9`), so a hub-mounted observer stays alive. Only the
**rendering** has to be duplicated per presentation context.

**Ownership and injection.** Declare `@State private var captureProtection = CaptureProtectionState()`
alongside the existing app-lifetime singletons at `Fernlet/FernletApp.swift:32-34`, and inject in
`readyContent(store:)` at `Fernlet/FernletApp.swift:220`, next to the existing `.environment(lockService)`
/ `.environment(storagePreferencesStore)` (`:219-221`). Then **re-inject per sheet case**, following
the convention already in place at `ContentView.swift:582-583` (`.settings`), `:612` (`.firstAid`),
`:618` (`.logPeriod`), `:625-626` (`.logIntimacy`). Modern SwiftUI does propagate environment into
sheets, but the repo's habit is explicit re-injection and a missing environment object in a sheet is
a **runtime crash, not a compile error** — match the convention and verify the two JournalView-owned
sheets (`JournalView.swift:101`, `:945`) empirically.

### 5.2 `captureProtected()` — one ViewModifier

A structural copy of `FernletLockGateModifier`
(`FernletKit/Sources/FernletLockUI/FernletLockGate.swift:52`): reads its dependency from
`@Environment` (`:64`) plus `@Environment(\.scenePhase)` (`:65`), wraps content in a `ZStack` (`:86`)
and layers the cover with an explicit `zIndex` (`:93`, `:99`), exposed through a documented
`public extension View` (`:278-285`). The smaller in-house idiom is
`FernletKit/Sources/FernletUI/FernletUIComponents.swift:79-86` (`uxScreenAnchor(_:)`).

Signature sketch — note the memory rule: **a `@MainActor` type can never be a default-argument
value** in Swift 5 mode. Do not default `monitor:` to `CaptureProtectionState()`; read it from the
environment inside the modifier, or default to `nil` and resolve in the body.

```swift
func captureProtected(active: Bool = true, isFrontmost: Bool = true) -> some View
```

`active:` is the UI-test escape hatch, mirroring `.fernletLockGate(active:)` at
`PrivateHubView.swift:83`.

### 5.3 Ordering relative to the lock gate

Applying `.captureProtected()` **inner** to `.fernletLockGate(...)` (i.e. on the line *before* it at
`PrivateHubView.swift:83`) puts the capture cover *under* the lock overlay, which draws at
`zIndex(100)` (`FernletLockGate.swift:93`, `:99`). That is the recommendation: the capture cover can
then never occlude the passcode field or the Face-ID chrome during the documented inactive→active
bounce (`FernletLockGate.swift:11-15`). The outer ordering covers the lock overlay too, which reads
"safer" until the first user cannot see the keypad they are typing on. Recorded as an explicit
decision because it is easy to get backwards.

### 5.4 Always-on, not visibility-keyed

**Recommendation: always on for all four surfaces, unconditional.** `PrivateHubSection.visibleSections`
(`Fernlet/PrivateHubView.swift:26-34`) gates only `.cycle` — `.journal` and `.worryBox` return `true`
unconditionally at `:31`. Keying protection to `store.sensitiveSurfaceVisibility`
(`Fernlet/FernletStore.swift:700-705`) would therefore leave two of the four in-scope surfaces
permanently unprotected while adding a conditional path to reason about. Any conditional scheme
degenerates to "`.cycle` only," which buys nothing.

If a conditional ever is added, it must read the **derived** value, never the setter — the discipline
enforced at `ContentView.swift:136-139` and `CycleTrackerView.swift:60-65`, and the lesson recorded in
the period/intimacy gating work.

### 5.5 Walls: both N/A, and why

- **No-tracking wall.** No network call, no new SPM dependency, no new destination. `NoTrackingBoundaryTests`
  scans every Swift file in every target, so a new UI file passes without a change to
  [`No-Tracking-Wall.md`](No-Tracking-Wall.md). The corollary is a constraint: adding a third-party
  "screen shield" package would fail `thirdPartyPackageDependenciesAreExactlyTheOneAllowedPackage()`
  until allowlisted and documented in the same commit — which is one more reason to build these ~200
  lines in-house with UIKit/SwiftUI only.
- **S3 wall.** No sealed-store access, no `Private*` import, no `AIProviders` / `CloudKitSync`
  involvement. Nothing in `Scripts/spm-wall-check.sh` or `FernletTests/S3BoundaryTests` changes.

**Module placement.** If the modifier's API takes only plain inputs (`Bool`, closures), it belongs in
`FernletKit/Sources/FernletUI/` alongside the other view modifiers — the module is wall-neutral,
depends only on `FernletDomainModel` (`FernletKit/Package.swift:98-104`), builds with
`.defaultIsolation(MainActor.self)` (`:101-103`), and already reaches UIKit
(`FernletUIComponents.swift:73-77`). The counter-argument: `FernletUI` today owns no
UIKit-notification or observable surface at all, so adding one changes its character. If the modifier
ends up wanting `FernletStore` or `FernletLockService`, it must live in the app target next to
`ProgressPhotoTimeline.swift` and `UITestSupport.swift`. Owner call — §9.

---

## 6. UX and accessibility

**Default on.** The nearest precedent in the app, `redactForSnapshot`
(`ProgressPhotoTimeline.swift:65`, `:388`), ships with no user control whatsoever, and the lock gate
is unconditional in release builds (`PrivateHubView.swift:83`). The app's consent pattern is
consistent: features that *emit or read* data default off (iCloud sync, sealed backups,
`allowNearbyPresence`, `stressAwarenessEnabled`); features that are purely *protective* ship on with
no switch. Capture protection is the second kind.

**Settings toggle — recommendation: no.** A toggle turns a quiet protection into a decision the user
has to make about a threat they have not thought about, and it adds surface to maintain. If the owner
wants one anyway, the constraints are concrete: it belongs with the other privacy cards in
`Fernlet/PrivacyDataSettingsView.swift` (`privacyControls` at `:313-333`, `SectionLabel` groups at
`:337` / `:678` / `:699`), that whole screen sits behind a fresh-biometric gate on every entry
(`:210-222`) — so reaching a low-stakes toggle costs a Face ID prompt — and any new Privacy & Data
control **must** also be registered in `Fernlet/SettingsSearchIndex.swift` (Privacy & Data entries
run ~`:369-425`) in the same commit. The flag would be passed *into* `captureProtected(active:)` as a
`Bool` from app-side code, never read from inside `FernletUI`.

**Accessibility is preserved, and that is a design advantage.** Both tiers *overlay* — they add a
sibling view in a `ZStack`. They do not reparent content into a secure text field's canvas, which is
exactly why Tier 3 is out (§1.1). Consequences:

- VoiceOver keeps working on the underlying content; the cover should carry its own label ("Hidden
  while your screen is being recorded") and use `.accessibilityHidden(true)` on the content beneath
  while it is up, so the reading order matches what is visible.
- Dynamic Type is unaffected — no text is moved into a foreign hierarchy. The cover's own copy must
  itself scale, and the app runs its appearance suite across content-size categories.
- Reduce Motion / Increase Contrast: the cover must be legible without animation. Do not make the
  blur's arrival the only signal — the nudge text carries the meaning.

**Legitimate-use friction.** Someone screen-recording to report a bug, or recording a workout to
share, will see the panel appear when a private surface or one of the five sheets is on screen. This
is real friction and should be handled by copy rather than by an escape hatch: the panel names its
own cause ("recording"), it is obviously temporary, and it lifts the moment recording stops. The rest
of the app records normally — Home, Food, Move, Social, Settings, and recipes are untouched — so a
bug report about anything outside the Private tab is unaffected. That containment is a reason to keep
the scope narrow rather than expand it.

---

## 7. Testing

**What is honestly not testable in CI.** Neither trigger can be driven from an automated iOS test:
XCUITest's `app.screenshot()` is an out-of-process capture and (almost certainly — verify, §9) does
not post `userDidTakeScreenshotNotification`; simulator screen recording does not set `isCaptured`;
AirPlay and external displays have no simulator equivalent. Any test suite that claims to cover the
real triggers is testing the fake.

**The seam that makes it testable anyway.** Because `CaptureProtectionState` is injected rather than
self-discovered, a test can construct one, flip `isCaptured` / fire a pulse, and assert on rendered
output. That injectability is a design requirement, not an afterthought — and it extends to the
**`NotificationCenter` the two observers attach to** (`init(…, notificationCenter:)`, defaulting to
`.default`, the only center UIKit really posts on). Both triggers are process-global and Swift
Testing runs separate suites in parallel (`.serialized` orders tests only *within* a suite), so a
test posting a screenshot to `.default` bumps every other test's live state: that is exactly how
`frontmostSurfaceClaimsThePulseNudge` came to see two pulses against its one claimed nudge
(2026-08-12). Every test constructs its state on a private `NotificationCenter()` and posts there;
`stateObservesOnlyItsInjectedCenter` pins it.

| Layer | Test | Asserts |
|---|---|---|
| Unit (Swift Testing) | Construct `CaptureProtectionState` **on a private `NotificationCenter`**, post `UIApplication.userDidTakeScreenshotNotification` / a synthetic capture change to it on the main actor | The observable's state transitions, the MainActor hop, observer removal in `deinit` (no retain cycle), and that a post to any other center is ignored |
| View-level | Host each of the six roots with an injected state, toggle it | Cover renders when captured; clears when not; frontmost gating suppresses the pulse when `selectedTab != .personal` |
| UI (XCUITest) | A `FERNLET_UI_TEST_FORCE_CAPTURE` flag following `Fernlet/UITestSupport.swift:31`/`:37`/`:42` with `#else` no-op stubs at `:69-71` | The cover appears over each of the six surfaces and carries its accessibility label |
| UI regression guard | Existing `ScreenAppearanceUITests` (screenshots the private hub and the logging sheets via `FernletUITests/UXScreenProbe.swift:185`, under `FERNLET_UI_TEST_BYPASS_PRIVATE_LOCK=1`, `UITestSupport.swift:37`) | **Nothing goes blank.** A `scenePhase != .active` cover or a screenshot-triggered blur firing during those runs empties the appearance gallery and fails its "nothing is blank" assertions. This is the most likely way this feature breaks CI. |

**Manual device matrix — required before shipping, since CI cannot cover it:**

| Case | Expected |
|---|---|
| Screenshot on each of the six surfaces | Brief blur + nudge (per the chosen frequency); no nudge when the screenshot is taken on Home/Food/Move/Social |
| Control Center screen recording, started while a private surface is open | Panel appears for the whole recording; recording plays back showing the panel; panel clears on stop |
| Recording started on Home, then navigate to the Private tab | Panel is already up on arrival (state read at mount, not only on notification) |
| AirPlay mirror to Apple TV / Mac | Same as recording, on the mirrored screen |
| Genuinely separate (non-mirrored) external display | Documented as uncovered; confirm no private surface renders there |
| App switcher (partial swipe **and** full background) | Cover in the snapshot, both paths; confirm whether the `.background` lock (`FernletApp.swift:137`) already handles the full path |
| Face ID unlock of the private hub | Cover may flash on `.inactive` but must never sit above the passcode field (§5.3) |
| iPad Split View / Stage Manager, two Fernlet windows, record one | Correct per-window state; no cross-window false positive (§4.1) |
| Both tiers at once (screenshot during a recording) | No stuck overlay; states are independent |

---

## 8. Obligations

- **Doc comments.** `Scripts/doc-coverage-scan.py` enforces a zero-undocumented baseline across
  `Fernlet`, `FernletKit/Sources`, `FernletWidgets`, `FernletShareExtension`. Every new declaration —
  `CaptureProtectionState`, the `ViewModifier` struct, any enum for the nudge reason — needs a `///`
  block or the scan exits 1. Match the density of `FernletLockGateModifier`
  (`FernletLockGate.swift:1-51`), which documents its invariants and the lifecycle traps, not just
  its purpose. The honest-limits framing from §1 belongs in the type's doc comment.
- **DocC landing page.** No new module is proposed, so no new landing page is needed — but the
  owning module's page is updated in the same commit: `FernletKit/Sources/FernletUI/Documentation.docc/FernletUI.md`
  (Overview modifier list + Topics) if it lands in `FernletUI`, or
  `Fernlet/Documentation.docc/Fernlet.md` (the "Cycle, Journal & Private Data" prose, Topics list) if
  app-target.
- **Index files.** New source files get a row in [`FileIndex.md`](FileIndex.md). If a Settings toggle
  ships, `Fernlet/SettingsSearchIndex.swift` must be updated too (§6).
- **No wall-doc changes.** [`No-Tracking-Wall.md`](No-Tracking-Wall.md) and
  [`SPM-Module-Carveup-Plan.md`](SPM-Module-Carveup-Plan.md) are untouched, for the reasons in §5.5:
  no new egress, no new dependency, no sealed-store reach. Stating this explicitly is itself an
  obligation — a reader should not have to re-derive it.
- **Do not add this to [`Verifiability.md`](Verifiability.md) §1's guarantee list.** It is not a
  verifiable guarantee. If it is mentioned there at all, it belongs in §5 (honest limits) as a note
  that capture friction exists and does not constitute protection.
- **Xcode 16 synced folder groups:** new files are picked up by dropping them in the folder; no
  `pbxproj` surgery. `Docs/` files never get target membership.

---

## 9. Open owner sub-decisions

| # | Decision | Options | Lean |
|---|---|---|---|
| 1 | **`lookingBackCard`** — decrypted journal text on Home (`AmbientCards.swift:201-215`) | (a) leave out; (b) modifier on the card; (c) content-level suppression on capture | (b). The cycle-outlook bubble is **already decided out** (§2.3) because it is a derived summary; this card is the opposite — verbatim sealed prose, i.e. the raw record the decision meant to protect |
| 2 | **Always-on vs visibility-keyed** | Unconditional for all four surfaces, vs keyed to `sensitiveSurfaceVisibility` | **Always-on.** Journal and Worry Box have no visibility gate (`PrivateHubView.swift:31`); keying would leave half the scope unprotected (§5.4) |
| 3 | **Settings toggle** | None (precedent: `redactForSnapshot` has no control), vs a row in `PrivacyDataSettingsView` behind its per-entry biometric gate | **None.** Protective defaults ship on and quiet in this app (§6) |
| 4 | **Nudge frequency** | Once ever, once per session, or every screenshot | Once per session reads as respectful; "every time" becomes noise and trains dismissal; "once ever" is forgotten by the time it matters |
| 5 | **Progress photos in a follow-up** | They already have `redactForSnapshot` (`ProgressPhotoTimeline.swift:167`, `:501`) hand-rolled twice, and their own lock scope + separate media key — but **no** `isCaptured` handling | Yes, follow-up: fold both hand-rolled copies into `captureProtected()` and gain Tier 2 for free. Deliberately out of this brief's scope, but it is the obvious second customer and the reason to build a reusable modifier rather than three inline overlays |
| 6 | **First Aid worry composer** (`WorryEntryView`, `WorryBoxView.swift:24`, via `ContentView.swift:604`) | In (it is where worry text is typed) vs out (First Aid also hosts non-sensitive tools) | In — it is the writing surface for an in-scope corpus |
| 7 | **Sheets opened from Home** (`JournalSheet` at `HomeView.swift:985`, `LogPeriodSheet` at `:989`, App Intent at `ContentView.swift:307`) | Protection engages automatically (consequence of attaching at the sheet type) vs call-site-scoped | Automatic — the content is what matters, not the tab behind it (§2.1) |
| 8 | **Modifier ordering** at `PrivateHubView.swift:83` | Inner to `.fernletLockGate` vs outer | **Inner** (§5.3) — the cover must never occlude the passcode field |
| 9 | **Module home** | `FernletUI` (store-free API) vs the app target | `FernletUI` if the API stays plain-input; app target the moment it wants store state |
| 10 | **Two empirical checks before building** | Does the `.background` lock (`FernletApp.swift:137`) already paint before the OS snapshot? Does `app.screenshot()` post `userDidTakeScreenshotNotification`? | Both are 15-minute device/simulator checks and both change how much machinery is warranted — do them first |

---

## 10. Related

- [`Docs/Verifiability.md`](Verifiability.md) — §5's honest-limits register, which this feature must
  not be promoted out of.
- [`Docs/No-Tracking-Wall.md`](No-Tracking-Wall.md), [`Docs/SPM-Module-Carveup-Plan.md`](SPM-Module-Carveup-Plan.md)
  — the two walls; neither changes (§5.5).
- [`Docs/Plan-Security-Hardening-Runbook.md`](Plan-Security-Hardening-Runbook.md) — the hardening
  ledger this brief is deliberately **not** part of.
- `Fernlet/ProgressPhotoTimeline.swift:64-65`, `:167`, `:209-222`, `:388`, `:497-516` — the existing
  hand-rolled snapshot cover, and the recorded lesson that a partial cover leaks.
- `FernletKit/Sources/FernletLockUI/FernletLockGate.swift:52`, `:120-141`, `:278-285` — the
  ViewModifier, scene-suppression, and public-API templates.
- `FernletKit/Sources/ProximityKit/HeartSharing/ProtectedSidecar.swift:172-191` — the observable +
  `NotificationCenter` + Swift-6 hop template.
