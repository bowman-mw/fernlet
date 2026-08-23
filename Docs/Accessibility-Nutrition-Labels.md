# Accessibility Nutrition Labels — the declaration

**Status:** Decided, not yet submitted. This document IS the declaration: App Store Connect's
Accessibility Nutrition Labels are a **form, not an API**, so there is no code artifact to point at
and no build that can be green or red about it. What we can do is write down, per feature, the
Apple criterion, the current verdict, the evidence the verdict rests on, and — for every "no" — the
named blocker that would have to be cleared first.

**Sibling walls.** The [no-tracking wall](No-Tracking-Wall.md) answers *"where may bytes go?"*; the
[S3 privacy wall](SPM-Module-Carveup-Plan.md) answers *"which code may touch sealed data?"*; the
[Power of 10 standard](Power-of-10-Swift.md) answers *"what shape may shipping Swift take?"* This
one answers *"what may we tell a disabled user this app can do?"* — and it is the only one of the
four whose failure mode is a promise made to a person rather than a rule broken in a file.

**Why this document exists at all, and why it is unusually load-bearing here.** Apple makes the
**developer** responsible for verifying that *all common tasks* work with each declared feature
([App Store Connect › Manage app accessibility](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/)).
For most apps there is a second check on that promise: field telemetry, crash reports, an analytics
funnel showing that VoiceOver users abandon a screen. **Fernlet has none of those, on purpose** —
the no-tracking wall means no data about a user's session ever reaches the developer, so no
declaration here can ever be validated after the fact. That is the whole reason §4.5's mechanical
wall was built alongside this file. **This document plus the wall ARE the validation.** There is no
third thing coming later.

**The bias, stated once.** An over-claim is worse for a disabled user than a blank. A blank row
costs them nothing; a wrong row costs them a download, a setup, and a task they cannot finish.
Fernlet has never been submitted, so it gets the rare luxury of choosing its declarations *before*
the first submission instead of retrofitting them — and the choice below is deliberately the
conservative one at every point where the evidence was thin.

---

## 1. The declaration

Three rows declared, two left blank as inapplicable, four left undeclared.

| Feature | First submission | Basis |
|---|---|---|
| **Dark Interface** | **DECLARE** | Full adaptive palette; measured ratios; the last cold-launch light flash removed. |
| **Reduced Motion** | **DECLARE** | Zero ungated continuous motion in shipping code, verified by enumeration. |
| **Differentiate Without Color** | **DECLARE** | Selection carries a trait, not a hue; all three hue-only encodings were fixed. |
| **Captions** | *blank — inapplicable* | The product contains no timed media of any kind. |
| **Audio Descriptions** | *blank — inapplicable* | Same. |
| **VoiceOver** | undeclared | See §3. |
| **Voice Control** | undeclared | See §3. |
| **Larger Text** | undeclared | See §3. |
| **Sufficient Contrast** | undeclared | See §3. |

"Blank" and "undeclared" are the same thing in the form — Apple offers no "not supported" state,
and inventing one in prose would be worse than silence. §2 and §3 are where the difference lives:
§2's rows can never be declared because the feature has nothing to act on; §3's rows are ones we
intend to declare, later, once the named blocker is gone.

---

## 2. Declared, and what each declaration rests on

### Dark Interface — DECLARE at first submission

**Apple's criterion:** the app supports a dark appearance and does not force light.

**Evidence.** Every *adaptive* colour in the app flows through a named token. The claim this row
originally rested on — "zero hard-coded system colours anywhere in the tree" — was an over-claim and
is corrected here rather than quietly kept. Measured with the accessibility scanner's own tokenizer
(comments and string literals stripped) over the four shipping roots:

- **4** references to a platform system colour, and all four are last-resort fallbacks or a
  throwaway: three `?? .systemBackground` tails on a hex parse that has already fallen back once
  (`FernletTheme.swift` ×2, `SettingsSheet.swift` ×1) and one `UIColor.systemGreen.setFill()` in
  `LinkMetadataPrototypeView.swift`. None of them can be reached by a well-formed theme.
- **71** references to a hard-coded `Color.white` / `Color.black` (or the bare `.white` / `.black`
  form) across **15** files — companion vector art, the camera and barcode chrome, the QR views,
  the widget bundle. Those are not *system* colours, so the original sentence was technically not
  about them, but they are hard-coded and they do not adapt, and a reader would reasonably have
  understood the sentence to exclude them.

Neither number undermines this row — the declaration is about honouring the system appearance, and
the surfaces that carry the app's appearance all do. It is recorded because §6's rule is that a
declaration and its evidence move together, and evidence that overstates is the failure mode this
document was written to avoid.

The four surface tokens (`parchment`, `cream`, `bark`,
`slate`) resolve through `UIColor` dynamic providers keyed on `trait.userInterfaceStyle`
(`FernletKit/Sources/FernletUI/FernletUIComponents.swift`, `FernletTheme.swift`), and every accent
token resolves through `Color(light:dark:)`, which is now `Color(light:dark:lightHC:darkHC:)` and
still branches on style first. Dark mode is measurably the *stronger* of the two appearances: all
nine accents clear 4.5:1 on both dark surfaces (worst case: terracotta at 4.52:1), where light mode
has accents that fail even the 3:1 non-text floor.

**The app no longer sets a second, competing colour scheme.** `ContentView` carried a leftover
`.preferredColorScheme(isDarkModeEnabled ? .dark : .light)` reading `fernletDarkModeEnabled` — the
pre-three-way Bool that `FernletAppearanceMode.migrateLegacyDarkModePreferenceIfNeeded` now reads
exactly once at launch, and that nothing in the app has written since. Because it could never
resolve `nil`, it was the one construct in the tree capable of forcing light against the user's
choice, and whether it actually did depended on which of two `preferredColorScheme` writes on the
same window SwiftUI resolves last. It is deleted: `FernletApp`'s `WindowGroup` body is now the
single writer, so "System" reaches the whole scene — launch screen, onboarding and every tab alike.
There is also no `UIUserInterfaceStyle` in any Info.plist and no `overrideUserInterfaceStyle`
anywhere, so no other mechanism can pin the appearance either. The stored key itself is *not*
removed — `FernletAppearanceMode.legacyDarkModeKey` still holds the literal and the one-time
migration still reads it, so an existing user's preference survives; only the stray read is gone.

Three things make this evidence rather than a hunch, and the fourth is what is still owed. The key
the modifier bound (`fernletDarkModeEnabled`) is **not** the key the live setting binds
(`fernletAppearanceMode`), and a tree-wide search finds nothing that writes the former any more.
The appearance migration's own doc comment (`FernletNavigation.swift:19-21`) describes removing this
exact line, and `git log -S` shows the migration commit never touched `ContentView.swift` — so the
removal was documented and not performed. And the line was demonstrably **live** before the
migration: `Docs/UI-UX-Review-2026-08-16.md:1772` records, against a screenshot gallery, that with
the phone in Dark Mode every tab and sheet still rendered light. What could *not* be determined from
source is which of the two writes wins today; that is why the line was deleted rather than reasoned
about.

**Verified on simulator after the deletion** (iPhone 17 / iOS 26, `Fernlet-A11y`, 2026-08-23, with
the app's own Appearance setting untouched at its default): `xcrun simctl ui … appearance dark`
followed by a cold launch renders the Home tab dark — parchment background, ink, cards, the tab bar
and the companion's ambience all on the dark palette — and `appearance light` followed by a cold
launch renders the same screen light. Screenshots of both were taken and compared. That is the
discriminator this row needed: it is exactly the check
`Docs/UI-UX-Review-2026-08-16.md:1772` failed before the appearance migration, when the device was
dark and every tab still came up light.

**The one thing that used to make this row dishonest is fixed.** `Assets.xcassets/LaunchParchment.colorset`
had no dark variant, so every cold launch in dark mode began with a full-screen cream flash (T2-21,
batch A1). The colorset now carries a `luminosity: dark` appearance.

**What is still true and worth knowing:** the app also offers a *custom* background colour, and a
user who picks one is outside the light/dark pair entirely. That does not undermine this row — the
declaration is about honouring the system appearance, which the default palette does — and the ink
fitted to a custom background (§4.2 below) is what keeps the custom case legible.

### Reduced Motion — DECLARE at first submission

**Apple's criterion:** the app honours Reduce Motion and does not present unnecessary motion when
it is on.

**Verification this rests on — enumeration, not spot-checking.** The review found six ungated
`TimelineView(.animation)` sites plus one ungated `repeatForever` (T1-6). Batch A2 closed all seven.
Re-enumerated for this document, in the shipping roots:

- Every `TimelineView(.animation…)` in the tree — `CompanionVectorAssets.swift`,
  `CompanionAmbienceLayer.swift` (×2), `ContentView.swift` (×2), `BarcodeScanView.swift`,
  `DisposableCameraView.swift` — passes `paused: reduceMotion` (the camera's also pauses when
  disarmed). That is **7 of 7**.
- Every remaining `repeatForever` is behind a Reduce Motion branch:
  `BreathingExerciseView.swift:233` (`guard !reduceMotion else { return }` — the idle sway stops, the
  *guided* breathing scale stays, because that motion **is** the exercise),
  `WorryBoxView.swift:400` (same guard), and `FernletUIComponents.swift:1616`
  (`.animation(reduceMotion ? nil : …)`). That is **3 of 3**.
- The barcode scanner's sweep — the one genuinely ungated `repeatForever` the review found — was
  rebuilt on the `TimelineView(.animation(paused:))` idiom rather than merely guarded, so it cannot
  regress into a detached animation.

**The honest caveat.** Reduce Motion also asks for cross-fade rather than slide transitions, and
Fernlet does **not** set `prefersCrossFadeTransitions`. That was refused deliberately (T3-11): the
ten transitions in question are short opacity-combined slides, which Apple's own guidance says not
to flag. If a future reviewer disagrees, the fix is ten modifiers, not a redesign — but the
declaration is being made on the continuous-motion criterion, which is what the setting is for.

### Differentiate Without Color — DECLARE at first submission

**Apple's criterion:** information is never conveyed by colour alone.

**Verification this rests on.** The review named two blockers; implementing the second surfaced a
third of exactly the same shape that the review had missed. All three are closed:

1. **Selection state.** `ChipButtonStyle` already applied `.accessibilityAddTraits(.isSelected)` for
   every chip in the app; six screens had hand-rolled their own tile and skipped it
   (`NutritionLabelCameraSheet` was the worst — fill colour only, no glyph, on the control deciding
   whether logged macros are per-serving or per-container). Batch A2 fixed all six (T1-5). Selection
   is now carried by a *trait*, which is colour-independent by construction, in addition to the fill.
2. **The workout calendar's hue-only cells.** `MoveView` encoded workout category by hue alone and
   distinguished *logged* from *planned* by `.opacity(0.38)` on a 5pt circle — neither channel
   survives colour blindness, and the opacity difference on a 5pt dot is under threshold for most
   low-vision users regardless of hue. Batch A5 added an
   `@Environment(\.accessibilityDifferentiateWithoutColor)` branch (read twice — once per view that
   needs it, then threaded down as a `Bool`, never per dot) that swaps each dot for a per-category
   SF Symbol at 8pt with **filled = logged, hollow outline = planned**, and switches the legend
   swatch to the same filled shape so the key still decodes the cells. The default branch is the
   verbatim original 5pt circle.

   **The verification, stated precisely.** Simulator screenshots with
   `DifferentiateWithoutColor` off and on (set via `xcrun simctl spawn … defaults write`, confirmed
   to take effect by the rendering change, restored to `NO` afterwards), on a seeded calendar with
   one logged Upper day and one planned Lower day — then **both screenshots converted to
   greyscale**. With DWC off, greyscale renders all four legend swatches as indistinguishable grey
   circles and separates the two day dots only by lightness, the planned one nearly invisible. With
   DWC on, both channels survive greyscale intact. *Honest caveat carried from the implementation:*
   the DWC-off rendering was compared against the verbatim-preserved code and the artboard
   description rather than against a pre-change binary, because a second build could not be run in
   the shared worktree.

   The label carries it too, independently of the setting — and fixing that surfaced a second bug:
   the old branching spoke the plan **only** on a day with nothing logged, so a mixed day's plan was
   silent. It now always says "planned", and uses the long weekday name instead of the drawn narrow
   symbol, which VoiceOver had been reading out as a single letter.

3. **The journal calendar's hue-only cells.** The review did not name this one — it was found while
   extending `MoveView`'s pattern. `JournalMonthCell.fill` encoded all six `FeelingTag` categories
   as a wash of `FeelingTag.color` over the card surface and nothing else, and
   `JournalCalendarCard.tagLegend` drew a plain `Circle().fill(tag.color)` swatch per feeling, so
   the key decoded only by hue as well. The journal calendar carries the user's mood history; hue
   alone was the *only* channel on it.

   The same `@Environment(\.accessibilityDifferentiateWithoutColor)` treatment now applies: read
   once per view that needs it (the card, for the legend; the cell, for itself) and threaded down
   as a `Bool`, never per mark. Each feeling takes a filled SF Symbol at 9pt — `bright` ★, `good` ●,
   `neutral` ■, `quiet` ▬, `tired` ◆, `hard` ▲ — chosen for silhouette at that size and drawn from
   the same family the workout calendar uses, so the two calendars speak one visual language. The
   mapping is a `switch` over `FeelingTag` with no `default:`, so a seventh feeling is a compile
   error rather than a silent grey blob. The legend swatch becomes the identical mark. With the
   setting off, the cell and the legend render byte-identically to before — the mark is an
   `EmptyView` and no fill, numeral, dot, spacing or tap target moves.

   **The verification, stated precisely.** Measured, not photographed: this batch could not run a
   simulator for it (the fix pass held the build lock), so the claim rests on arithmetic over the
   actual token values rather than on greyscale screenshots. WCAG relative luminance was computed
   for each `FeelingTag.color` composited at its real alpha (0.28 ordinary, 0.38 today) over the
   real card surfaces (`#FBF7EE` light, `#282A26` dark). **The worst pair, light mode at 28%, is
   `quiet` vs `hard` at 1.0028:1** — in greyscale those two cells are the same value, not merely
   similar. `neutral` vs `tired` is 1.031:1 in dark mode. **All 15 pairs, in both appearances and
   at both wash strengths, fall under 1.43:1**, against the 3:1 WCAG 1.4.11 floor for a graphic
   that carries meaning; not one pair reaches half of it. Composited in linear light instead of
   gamma space the same pair leads at 1.0102:1, so the conclusion does not depend on the blend
   model.

   The mark is inked `bark`, not the feeling's own tint — a deliberate departure from the workout
   calendar, where the mark sits on a plain card rather than on a wash of its own hue. A
   tint-inked glyph measures **1.497:1** against its own cell for `bright`, 1.787:1 for `neutral`
   and 2.138:1 for `good`: three of six would have failed the 3:1 floor, i.e. the shape channel
   would have been drawn in invisible ink. `bark` measures **≥4.93:1** against all six washes in
   both appearances at both wash strengths.

   The spoken label carries the feeling independently of the setting, and now opens with the
   weekday name as well (T2-17): the drawn weekday initials came off these cells in that review,
   which had left "Day 14" as the entire utterance for a cell in a month grid.

**Why the rest of the palette does not block this row.** `WorkoutSplit.color` genuinely collides,
and so does `WorkoutType.color` (`.upper`/`.armsBack`/`.mixed` all moss, `.cardio`/`.run`/`.hike`
all terracotta). The render sites were enumerated, and the counting basis is stated here because an
earlier draft said "15" while a reviewer counted 17 and neither said what it was counting: measured
with the accessibility scanner's tokenizer over the four shipping roots, a `WorkoutType`-typed
receiver reaches `.color` on **15 code lines / 16 occurrences** (one line uses it twice, in a
planned-vs-logged ternary), all of them in `MoveView.swift`, plus **2** separate `WorkoutSplit.color`
sites. Every one of them except the calendar cell draws the dot immediately beside its own text
label — the category name, the muscle list, the legend title — so the hue is redundant rather than
load-bearing, and the calendar cell is the one fixed above. Colour in Fernlet is decoration on top
of a word almost everywhere, which is why this row was cheaper to clear than it looked.

The same enumeration was not repeated for `FeelingTag.color`: all six feeling tints are distinct
tokens with no collisions, and every non-calendar site (mood chips, `JournalRow`, summaries) draws
the dot immediately beside `tag.label`, so the calendar grid was the single load-bearing site.

---

## 3. Undeclared, with the blocker named

These four are intended, not abandoned. Each names what would have to be true.

### VoiceOver — undeclared

**Apple's criterion is the strict one:** *complete all common tasks using only VoiceOver.* Not
"most elements are labelled" — **all common tasks, end to end, with the screen off-attention.**

**Blocker.** Fernlet's four common tasks are: log a meal, log water, log a mood, complete a workout.
Batches A1–A5 cleared a great deal — the app lock is now modal and speaks its failures (T0-1/T0-3),
the widget target went from *zero* accessibility modifiers to labelled (T1-7), the announcer exists
and is adopted at 14 sites (T1-2), 124 headings light up the rotor (T1-1) — but the criterion is a
**manual, task-by-task pass**, and that pass has not been run. Nothing mechanical can substitute for
it: the §4.5 wall explicitly does not catch a label that is present but wrong, a broken focus order,
or a missing custom action, and those are exactly what break a task rather than an element.

**What would clear it.** One end-to-end VoiceOver-only session doing all four tasks on a device (not
the simulator), with a stopwatch on the destructive-undo windows. If that session succeeds, this row
can be added at any subsequent submission at no cost. Declaring it before that session is the single
most tempting over-claim available here, and it is refused.

### Voice Control — undeclared

**Blocker.** `accessibilityInputLabels` had zero uses in the tree before batch A5 and now has a
handful (T2-12); several controls' accessibility labels are still full sentences, which a Voice
Control user must speak in their entirety to activate. Batch A5 named short spoken alternatives at
the worst sites, which is a real improvement and not the criterion. The criterion is again
*all common tasks*, and the same manual pass is owed — with the additional wrinkle that Voice
Control's numbered-overlay mode must also be usable, which nobody has tried.

### Larger Text — undeclared

**Blocker, and this is now a measured number rather than a suspicion.** Apple requires **verified
no-truncation at AX5 across all common tasks**. The mechanical half is in place: the §4.5 wall's
rule A5 forbids a fixed adaptive-grid minimum, rule A4 forbids a `Font.custom` without
`relativeTo:`, the AX-size content drops now re-expose through `.accessibilityCustomContent`
(T2-2), and the named fixed-pixel minimums are `@ScaledMetric` (T2-11).

**Then the runtime audit ran for the first time, over the 25 screens of the `ScreenAppearanceUITests`
gallery, and found 119 raw issues:**

| Category | Count | What it means |
|---|---|---|
| Text clipped | 76 | text losing characters to its own frame |
| Dynamic Type font sizes are partially unsupported | 19 | a font that does not track the user's text size |
| Hit area is too small | 15 | a control under 44pt |
| Potentially inaccessible text | 7 | text the audit could not resolve as readable |
| Label not human | 2 | **an SF Symbol name or raw token being spoken** |

The 76 + 19 in the first two rows **are** the Larger Text criterion. Nobody had measured this before
— the previous rounds fixed the sites they could see, which is why the count is a surprise and why
it is recorded here rather than quietly absorbed. Two calibration notes so the number is not
misread: 15 sub-44pt regions across 25 dense screens is a small residue, not a refutation of the
2026-08-16 hit-target round (several are inside system-drawn controls); and the two "Label not
human" findings are the highest-signal items in the whole set — that category means a glyph name is
being read aloud — and should be fixed before any of the other 117.

The findings are frozen as a per-screen **set of issue identities** by the ratchet in
`Tests/FernletUITests/UXScreenProbe.auditBaselines`, so no *new* finding can appear while the
burn-down is scheduled, a fixed one cannot be quietly left in the map, and a newly added screen
starts from an empty baseline. They are attached to every test run as a per-screen listing — raw
issues, identities, and both deltas — so the backlog is readable without re-running the audit. §5
explains why the first version of this ratchet (a per-screen integer) had to be replaced.

**A note on the screen counts in this document, because three different ones were in circulation.**
The measured 119 came from the `ScreenAppearanceUITests` gallery, which visits **25** screens (22 of
them report at least one finding, so the baseline map has 22 keys, not 25). The
wider probe inventory — every suite that constructs a `UXScreenProbe`, so `SettingsAppearance`,
`OnboardingAppearance`, `HomeCardsRedesign`, `ItemCreationFlow`, `ProgressPhoto`, `RecentBites`,
`RecipeDetail`, `NutritionTargetsEditor` and `GoalPresetCards` as well — is **37** distinct screen
names, counted from source by `AuditRatchetBoundaryTests`. Any figure between those two in an older
draft was a snapshot of one suite quoted as if it were the whole inventory.

**What would clear this row:** the burn-down, then a human looking at every common task at AX5.

**One platform note, because it is a trap:** Apple explicitly **forbids citing Hover Text** as
evidence of Larger Text support. Hover Text magnifies one element under the pointer; it is not text
scaling, and offering it as the answer is treated as an over-claim.

**A second note, recorded because it is cheap now and expensive later:** every `isAccessibilitySize`
branch and every `minimumScaleFactor` in the tree is calibrated against **English** string lengths.
German runs 30–40% longer. The day a translation ships, this row's evidence has to be re-taken.

### Sufficient Contrast — undeclared

**Blocker, and the honest reason this one is not being declared even though it improved the most.**
Batch A5 landed the contrast capability the review asked for (§4.2 / T2-6): `Color(light:dark:)`
widened to `Color(light:dark:lightHC:darkHC:)` resolving inside the same dynamic provider, so
Increase Contrast now moves `slate` to the approved `#45535E` (**6.90:1 on parchment / 7.41:1 on
cream**, recomputed from raw channel bytes), `mossFill` to the approved `#38562C` (**white on it
8.28:1**), and `moss` to the already-approved `#46683A` (**5.54:1 / 5.95:1**, up from 3.74:1 /
4.02:1 across 179 foreground sites). Component boundaries that measured 1.15–1.25:1 now clear the
3:1 non-text floor. A custom background's ink is fitted rather than picked off one binary threshold
(T2-7), which closes the case where a mid-grey pick produced **1.79:1 primary and 1.13:1 secondary
ink on every screen, including the Reset button that would undo it**.

**And it is still not enough to declare, for two specific reasons:**

1. **Muted ink and AA are mutually exclusive in this palette, at any contrast setting.** **62**
   code-only occurrences across **32** files draw `slate.opacity(…)` — measured with the
   accessibility scanner's tokenizer over the four shipping roots, so comments and string literals
   are excluded. (An earlier draft of this row said "roughly 30" and a reviewer counted 43; neither
   stated a method, which is how a number drifts. The method is stated now so the next reader can
   re-run it.) Light `slate` at *full* strength is 4.78:1 on
   parchment, so any alpha below 1 is under the 4.5:1 floor **by construction**: 0.7 → 2.74:1, 0.5 →
   1.98:1. Increase Contrast improves them (slate becomes `#45535E`, so 0.7 alpha rises to 3.42:1 and
   clears the *non-text* floor) but even 0.8 alpha only reaches 4.28:1. There is no token that fixes
   this. The correct fix is to **de-emphasize by size and weight rather than by alpha** at each of
   those sites, and that work has not been done.
2. **The runtime auditor's `.contrast` type is currently subtracted** (see §4). Declaring a contrast
   row while the only automated contrast check is switched off would be a promise with nothing behind
   it.

**What would clear it:** the 62 muted-slate sites converted to size/weight de-emphasis, and the
audit's `.contrast` type turned back on with its allowlist deliberately burned down.

---

## 4. Inapplicable, verified

Recorded so a future audit does not re-discover them as gaps, and phrased as *inapplicable* rather
than *unsupported* — because "we do not support captions" reads to a Deaf user as a refusal, and the
truth is that there is nothing here to caption.

| Row | Verification |
|---|---|
| **Captions** | The shipping tree contains exactly **one** `import AVFoundation`, in `App/Fernlet/DisposableCameraView.swift`, and it is camera **capture**, not playback. There are **zero** occurrences of `AVPlayer`, `AVKit`, `AVPlayerLayer`, `AVQueuePlayer`, `AVAudioPlayer`, `AVAsset` or SwiftUI's `VideoPlayer` anywhere in `App/` or `FernletKit/Sources/`. No timed media exists to caption. |
| **Audio Descriptions** | Same verification, same conclusion. |

Two neighbouring rows worth recording for the same reason:

- **Bold Text is a typeface problem, not a missed checkbox.** Instrument Serif is a **single-weight
  family** — the two files in `App/Fernlet/Fonts/` *are* the whole family — and that face carries
  `.body`, `.bodySmall`, `.bubble`, `.header` and `.headerMedium`. There is no heavier cut to bundle.
  Supporting Bold Text means changing a typeface, which is a design decision, plus a sweep of ~1,222
  `.fernlet(` call sites. DM Sans and Fraunces *can* be extended if it is ever revisited; scope it to
  those roles.
- **iPad, size classes, Sound Recognition, Music Haptics, Live Captions and Hover Text are all
  genuinely N/A.** `TARGETED_DEVICE_FAMILY = 1` (iPhone only, verified in `project.pbxproj`); the
  rest are system-level features with no third-party API or no surface in this app.

---

## 5. What is enforced mechanically, and what is not

Because no field telemetry will ever check these claims, it matters exactly where the machine stops.

**The machine checks (the §4.5 wall):**

- `Scripts/accessibility-scan.py` + `Tests/FernletTests/AccessibilityBoundaryTests` — **seven**
  structural rules with a zero-violation baseline and one shared allowlist
  (`Scripts/accessibility-allowlist.json`), each entry stating the invariant that makes it safe:
  A1 a `.combine` anywhere in a modifier chain that also carries a label, A2 a spoken `rawValue`,
  A3 the three heading components' `.isHeader` canary, A4 a `Font.custom` without `relativeTo:`,
  A5 a fixed `GridItem` width, A6 an `Image(uiImage:)` with no `.accessibilityIgnoresInvertColors`
  (Smart Invert turning a user's photograph into a colour negative — T2-10), A7
  `.accessibilityElement(children: .ignore)` on a `Button` (the traitless-second-element defect
  below).

  **The first five were adversarially tested and were porous.** A reviewer planted fifteen evasions
  of A1, A2 and A5 — a same-line pair, `children:.combine` with no space, one interleaved modifier
  between `.combine` and its label, a wrapped `GridItem(`, a `rawValue` reaching a label through a
  `let` or a computed property, an argument list wrapping past the scan window, a named
  `.accessibilityAction`, the UIKit `label.accessibilityLabel =` assignment form, and both
  announcement channels — and **fourteen of the fifteen passed**. The rules now catch **15 of 15**,
  and the Swift port carries the same fifteen as fixtures so the two halves cannot drift. Hardening
  A1 immediately found a real pre-existing site the old rule could not see
  (`SessionChatPanel.swift`, where an `.accessibilityIdentifier` sits between the pair), which is
  the best evidence available that the tightening was not theatre.

  The scanner's module docstring carries the honest ceiling: a `rawValue` reaching a label through a
  function call or from another file, a runtime-computed string, a label that is present but wrong,
  and A7's enclosure test — which reads indentation rather than parsing Swift, so a `Button` vended
  by a helper, a `NavigationLink`, or a `Menu` all read as "not a Button" and are missed.
- `XCUIApplication.performAccessibilityAudit` chained into `Tests/FernletUITests/UXScreenProbe`'s
  `capture()`, across the probe screens, running `.all.subtracting(.contrast)`, with a per-screen
  ratchet (`auditBaselines`) frozen at the measured baseline — 135 issue identities across 22 of
  the 25 gallery screens. It fails on an issue that is **not in
  the baseline**, fails on a baseline entry that **no longer reproduces**, and starts any new screen
  from an empty baseline.

  `performAccessibilityAudit` **throws**, so `capture()` had to become `throws` and every chained
  call site gained a `try` — `try!` would trap the whole gallery run on one transient failure, a
  swallowed `try?` would turn the wall into decoration, and `XCTAssertNoThrow` discards the issue
  handler, which is where every finding lives.

  **The ratchet was a per-screen integer first, and that version was neither stable nor
  discriminating.** It is worth recording why, because both failures looked like flakiness and
  neither was. Not discriminating: fixing one finding while introducing another leaves a count
  unchanged, which is the exact substitution a wall exists to catch. Not stable: the count was taken
  over an array, so it counted duplicates — and the audit's duplicates are its least meaningful
  output, because an issue whose `element` is `nil` renders as a bare category string and a screen
  can report the same category four times with nothing to tell the four apart. The per-issue
  description also embedded the element's frame, whose float digits differ between two runs of the
  same unchanged screen. Measured on this tree: one full-suite run reported Home at 19 findings and
  failed Meal at 9 against a ceiling of 6; the next run of the **same binary** passed Meal and failed
  Home at 25. No app code changed between them.

  The fix is to compare a **set of frame-free issue identities** rather than a count. Duplicates of
  an element-less category collapse to one member and the frame is not part of the key, which
  removes both noise sources at the source rather than papering over them with a wider ceiling. The
  honest cost is stated at `UXScreenProbe.identity(_:)`: element-less issues share one identity, so
  going from one to six of them does not fail the wall. They carry nothing that distinguishes them,
  so counting them was measuring the audit's own resolution luck; the raw listing is attached to
  every run so the multiplicity is visible even though it is not walled.

  With the measurement quiet, a **disappearance is now a failure too**, not a `print()`. The earlier
  argument for printing — a suite that fails when someone *fixes* something gets deleted — was only
  sound while the numbers moved on their own. The house rule everywhere else in this repo is that an
  entry matching nothing is a hole nobody is watching, and this is now that rule. Its companion is
  `Tests/FernletTests/AuditRatchetBoundaryTests`, which reads the probe sources and fails when a
  frozen baseline names a screen no probe visits any more — the same job
  `AccessibilityBoundaryTests.everyAllowlistEntryStillMatchesSomething` does for the grep-wall's
  allowlist, and one a run inside the UI suite structurally cannot do for itself.

**The machine cannot check — and this is the ceiling every row above is bounded by:**

- **Focus order.** Whether the VoiceOver cursor moves somewhere sensible when a sheet appears or a
  screen swaps out. This is a named criterion of the VoiceOver row and there is no automated test
  for it anywhere.
- **A label that is present but WRONG — including a *state* that is missing.** Every automated check
  can tell you an element has a label; none can tell you the label describes the element, or that it
  changes when the thing does. The worked example is the personal-care card. Going into this batch
  it was believed to have all eight toggles 100% unreachable (`customActions == []`); an AX walk with
  the simulator's accessibility server enabled **refuted that** — all eight were already their own
  hittable buttons — and found the real defect instead: the card announced "2/8" while every one of
  the eight toggles reported `selected=false`, so VoiceOver said "Floss, button" identically whether
  the task was done or not. Every automated check in the tree was green for both the imagined bug
  and the real one. (Two lessons worth keeping: the card is an **opt-in** Home widget, not in
  `defaultWidgets`, so a probe that looks for it on a default Home finds nothing and can easily
  report "unreachable" — and a wrong `.isSelected` is invisible to every tool we have.)
- **An element that is *silently the wrong kind*.** Fixing the above surfaced a second class:
  `.accessibilityElement(children: .ignore)` on a `Button` mints a **second, traitless** element
  beside the real one, so the control stops announcing as a button.

  This one has since moved from "the machine cannot check" to "the machine checks it imperfectly",
  and it is left here rather than promoted because the imperfection is the interesting part. Rule A7
  now flags the shape, and the four defective sites in `HomeView.swift` — the milestones card, the
  First-aid header, the "I'm unwell today" row, and every `QuickLogButton` tile, which is the app's
  highest-traffic control grid — are fixed by deleting the modifier and letting the `Button`'s own
  element carry its explicit label. The remaining sites in the tree are *containers*, where
  `.ignore` is the thing that mints the single element rather than a suppression, and they are
  correct as written. `HomeView`'s companion is the instructive one: it looks identical to the four
  defects and is correct, because `CompanionView` is a tap-gesture container whose button trait is
  added explicitly.
  **A grep cannot tell those apart** — it decides "is this on a Button?" by indentation and a
  bounded lookback, so it misses a `Button` returned from a helper, a `NavigationLink` and a `Menu`.
  The rule earns its place by catching the shape that actually shipped, not by being sound.
- **Reduce Motion.** No audit type covers it; §2's declaration rests on source enumeration.
- **Whether an element is hidden from assistive technology at all.** This one is *measured*, and it
  is sharper than expected: **XCUITest queries do not respect `accessibilityHidden`.** The subject is
  a decorative element inside the app-lock gate itself — `FernletLockGate.swift`'s
  `Image(systemName: "lock.shield")` carries an unconditional `.accessibilityHidden(true)`, and an
  XCUITest query run while the gate's overlay is up still finds it, reporting its label as the raw SF
  Symbol name. So `XCTAssertFalse(app.descendants(…)["screen.journal"].exists)` can never pass while
  the gate paints, no matter how correct the app is.

  **The proof is committed**, in `Tests/FernletUITests/LockGateObservabilityUITests`. It was
  originally taken with a throwaway probe that was deleted in the same batch, which left this
  paragraph asserting a result nobody could re-run — a claim about a *tool's limits* is exactly the
  kind that quietly stops being true. The committed version is shaped so the good outcome fails it:
  if a future iOS starts honouring the modifier in UI-test queries, the test goes red with a message
  saying to re-take this measurement and reconsider the runtime test that was abandoned on it.

  **This does not mean the lock gate's fix is broken — it means XCUITest cannot observe it.** The
  consequence for this document is that the grep-wall in
  `Tests/FernletTests/LockGateAccessibilityBoundaryTests` is not merely the *convenient* enforcement
  for `.accessibilityHidden`/`.isModal`, it is the **only** one available: the in-process route is
  closed (SwiftUI does not materialise the tree without an attached assistive technology) and the
  out-of-process route is closed too (XCUITest ignores the modifier).

  **`.isHittable` reported `true` for controls under the gate**, and that was triaged here as an
  observability artifact. A second test in that file now taps the covered journal's "New journal
  entry" button through the overlay and asserts the gate's call-to-action survives.

  **That test does not answer the touch-blocking question, and this document must not be read as
  saying it does.** It was mutation-tested by removing the overlay's `.allowsHitTesting(false)`
  entirely, and **it still passed** — for the same reason as the paragraph above: the assertion reads
  `exists`, and `exists` comes from the query mechanism that has just been proven to ignore covering,
  so the call-to-action is in the tree whether or not it is the view receiving touches. What the test
  genuinely buys is narrow: it fires if a covered tap causes a visible navigation that removes the
  gate from the tree. **Whether the gate actually blocks a touch — and whether the paged `TabView`
  underneath silently changes page — is on the manual device-check list and is not claimed here.**
  The observability half of this section is settled; the touch half is not, and no test in this repo
  can settle it.
- **Whether a task can actually be completed.** Which is, unhelpfully, exactly what Apple's criteria
  are about.

**Why `.contrast` is subtracted from the runtime audit.** XCUITest's contrast auditor samples
rendered pixels and cannot tell text from decoration, so on a parchment palette built from
deliberately soft hairlines (a card edge at 0.08 bark, a chip outline at 0.12) it reports the design's
entire vocabulary of quiet boundaries as failures. Those boundaries **are** measured — every ratio in
the token doc comments was computed from raw channel bytes, and Increase Contrast raises each past
the 3:1 non-text floor — and a wall that buries four real findings under fifty false ones is a wall
someone switches off. Turning it back on with the allowlist burned down is the named prerequisite for
the Sufficient Contrast row, and it is tracked there rather than left as a comment in a test file.

---

## 6. Changing this document

Same rule as the no-tracking wall: **a declaration and its evidence change in the same commit.**

- Adding a row here means the verification in its "Basis"/"Evidence" cell is something a reader can
  re-run or re-derive. "It seems to work" is not evidence.
- Removing a blocker from §3 means the blocker is *gone*, not that it got less annoying.
- If a declared row's evidence stops being true — a `TimelineView` lands without `paused:`, the
  `.isHeader` canary goes red, a hue-only encoding comes back — **the row comes out of the form at
  the next submission.** A shipped over-claim is not a bug to be fixed later; it is a promise that
  was already broken for whoever downloaded on the strength of it.
