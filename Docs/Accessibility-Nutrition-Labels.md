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

Four rows declared, two left blank as inapplicable, three left undeclared.

| Feature | First submission | Basis |
|---|---|---|
| **Dark Interface** | **DECLARE** | Full adaptive palette; measured ratios; the last cold-launch light flash removed. |
| **Reduced Motion** | **DECLARE** | Zero ungated continuous motion in shipping code, verified by enumeration. |
| **Differentiate Without Color** | **DECLARE** | Selection carries a trait, not a hue; all three hue-only encodings were fixed. |
| **Sufficient Contrast** | **DECLARE** | On the Increase Contrast route: the gallery measures clean in light, dark and Increase Contrast. |
| **Captions** | *blank — inapplicable* | The product contains no timed media of any kind. |
| **Audio Descriptions** | *blank — inapplicable* | Same. |
| **VoiceOver** | undeclared | See §3. |
| **Voice Control** | undeclared | See §3. |
| **Larger Text** | undeclared | See §3. |

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
migration: `e6a3b48:Docs/UI-UX-Review-2026-08-16.md` (line 1772) records, against a screenshot gallery, that with
the phone in Dark Mode every tab and sheet still rendered light. What could *not* be determined from
source is which of the two writes wins today; that is why the line was deleted rather than reasoned
about.

**Verified on simulator after the deletion** (iPhone 17 / iOS 26, `Fernlet-A11y`, 2026-08-23, with
the app's own Appearance setting untouched at its default): `xcrun simctl ui … appearance dark`
followed by a cold launch renders the Home tab dark — parchment background, ink, cards, the tab bar
and the companion's ambience all on the dark palette — and `appearance light` followed by a cold
launch renders the same screen light. Screenshots of both were taken and compared. That is the
discriminator this row needed: it is exactly the check
`e6a3b48:Docs/UI-UX-Review-2026-08-16.md` (line 1772) failed before the appearance migration, when the device was
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

### Sufficient Contrast — DECLARE at first submission, on the Increase Contrast route

**Apple's criterion, quoted because the route matters.** "You may indicate your app supports
Sufficient Contrast if the user interface for your common tasks, including text, buttons, and other
controls, meets general contrast guidelines by default — usually 4.5 to 1 for most text elements."
If it does not do that by default, an app on Apple's UI frameworks must "verify that the Increase
Contrast setting applies sufficient contrast." Apple also asks for 3:1 on "interactive controls and
non-text representations of a state, such as a selection" (an unchecked checkbox, for example), and
for checking light and dark
([Sufficient Contrast evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/sufficient-contrast-evaluation-criteria)).
**Fernlet qualifies on the Increase Contrast route, not by default, and is declared on it.** Plain
`moss` text is 3.74:1 on parchment and 4.02:1 on cream in default light, across about 179 foreground
sites, and nothing below changes that. Under Increase Contrast `moss` resolves to `#46683A`, and every
moss label on the gallery measures 5.14–6.33:1 there. That is the verification Apple's criterion asks
of an app on its UI frameworks.

**What Batch A5 already landed (unchanged).** `Color(light:dark:)` widened to
`Color(light:dark:lightHC:darkHC:)` resolving inside the same dynamic provider, so Increase
Contrast moves `slate` to the approved `#45535E` (**6.90:1 on parchment / 7.41:1 on cream**),
`mossFill` to `#38562C` (**white on it 8.28:1**) and `moss` to `#46683A` (**5.54:1 / 5.95:1**). A
custom background's ink is fitted rather than picked off one threshold (T2-7).

**The evidence: the gallery in all three appearances, retaken 2026-10-18 with the Mac awake.** The
25-screen `ScreenAppearanceUITests` gallery (iPhone 17 simulator, iOS 26.5, demo seed, `large` text),
one run per appearance on main 014f8620 (#37 and #38) with this round on top, with `.contrast` on and
the measured sweep walled. Every screen finished; the slowest took 37 s.

| Appearance | Gallery | Swept text under 4.5:1 | Field prompts |
|---|---|---|---|
| Default light | **25 / 25 green** | none unexcused; 10 moss labels at 3.75–4.02:1, exempt on the Increase Contrast route | **5.13:1** (was 1.71:1) |
| Dark | **25 / 25 green** | none | **5.93:1** (was 2.43:1) |
| Increase Contrast | **25 / 25 green** | none | **7.41:1** (was 4.33:1) |

The triage beside it, in default light: 52 nominations whose ink clears, 39 occluded, 7 disabled,
and 29 exemptions (the moss labels and the Home tab's label). In dark: 49 ink clears, 39 occluded,
7 disabled, and 3 exemptions. Under Increase Contrast: 42 ink clears, 39 occluded, 7 disabled, and 5
exemptions. Exemptions are matched before the triage measures anything, so the dark and Increase
Contrast ones were measured by hand afterwards, and none is needed: Food's "Adjust targets",
"Adjust" and "P 42g" at 5.29–6.65:1 in dark; the same three and the Home tab's label at 5.39–7.07:1
under Increase Contrast.

#### Cleared 1: the muted-`slate` sites

**The count, by the stated method.** The accessibility scanner's tokenizer over the five shipping
roots (comments and string literals excluded) found **65 code lines in 35 files** drawing
`slate.opacity(…)` on 2026-10-18. The earlier "62 in 32" was the same method on an older tree.
Light `slate` at full strength is 4.78:1 on parchment, so any alpha under 1 is under the 4.5:1 text
floor by construction: 0.7 → 2.74:1, 0.5 → 1.98:1, and even 0.8 under Increase Contrast → 4.28:1.

**44 lines were converted** to full-strength `slate`. The owner approved the treatment on
before/after screenshots in light, dark and Increase Contrast. Text is quieted by italic or a
smaller role instead of a fainter ink (the `SheetTextEditor` placeholder, the journal's "Not
logged", the Move week strip's "Rest" from 1.83:1 to 5.08:1 rendered). Glyphs that carry a state
are drawn at full strength, one stroke-weight lighter: radio rings, the water bottles (now filled
versus outlined), the journal's drop and moon (also filled versus outlined), and 10 disclosure
chevrons. The unselected ring is the case Apple names, an unchecked control, and it goes from
1.48–1.87:1 to 4.78:1. One text chip on parchment (`MoveView`'s rework affordance) measured 4.22:1 on
its slate tint, so it moved to a cream fill (5.13:1).

**21 lines stay**, each in `Scripts/accessibility-allowlist.json` with its measured ratio and the
invariant that makes it safe:
- 11 disabled controls. Each ternary's dim branch is taken exactly when the control's own
  `.disabled(…)` is true. WCAG 1.4.3 and 1.4.11 exempt inactive components.
- 4 slate@0.10 circles behind a full-strength ✕. The glyph measures 4.22:1 against the circle in
  the worst case, above the 3:1 non-text floor.
- 2 text chips that sit on cream cards: 4.52:1 light, 6.38:1 under Increase Contrast.
- 3 lines of placeholder-swatch palette, which have no ink on them.
- 1 policy divider, which is decoration.

**And it is walled.** Rule **A8-MUTED-SLATE** in `Scripts/accessibility-scan.py` and its Swift
twin `AccessibilityBoundaryTests` refuse any new `slate.opacity(` (and the `slate.secondary`-style
and `secondaryText.withAlphaComponent(` spellings) unless it is allowlisted. Six planted spellings
are fixtures on both halves. The rule's ceiling is in the scanner's docstring: a view-level
`.opacity`, a bare `.secondary` resolving against a slate ancestor, a binding, and every other ink
at alpha are not A8's to catch.

#### Cleared 2: `.contrast` is back on, and its findings are measured, not believed

`UXScreenProbe` now runs `.contrast` in its own first pass, then everything else. Inside one `.all`
audit, 28 of 134 contrast issues came back with no element, and therefore nothing to measure. Run
alone, none did. That comparison is not controlled, because the app changed between the two runs;
it is the observation that made the split worth keeping, not a proof of its cause.

**Why the auditor cannot be taken at its word.** On the 25-screen `ScreenAppearanceUITests` gallery
(iPhone 17, demo seed) its verdicts do not follow the WCAG ratio in either direction:
- Full-strength `bark` headings rendered at 19.6:1 are reported "Contrast failed".
- Under Increase Contrast, text rendered at 7.36:1 is still "failed".
- `moss` text at 3.73:1 is only "nearly passed".
- The Move week strip's 45%-slate "Rest" captions, at 1.83:1 the faintest text on that screen, were
  never reported at all. They were reported once they reached 5.08:1.

So the auditor nominates and `Tests/FernletUITests/UXScreenProbe+Contrast.swift` decides. It
measures each nominated element in the screenshot taken for that screen: the 90th-percentile inked
pixel against the crop's dominant colour, held to 4.5:1 for text and 3:1 for an image. A finding is
excused only for one of these, and each excused finding is listed in the run's attachment with its
number:
- the control is **disabled**;
- the element is **occluded**, running under the floating tab bar or past the window edge;
- its **ink clears** the floor.

**The burn-down, default light, measured 2026-10-17/18:**

| | Before (one `.all` pass, muted sites unconverted) | After |
|---|---|---|
| Raw contrast issues | 134 on 22 of 25 screens (104 "failed", 30 "nearly passed") | 127 |
| Excused by measurement | — | 99: 61 ink clears, 31 occluded, 7 disabled |
| Real, below the floor | — | 28: 26 on the Increase Contrast route, 1 illustration, 1 triage bug |

**What is left in default light is the Increase Contrast route itself, plus one illustration.** The
28th real finding was a triage bug: Home's quick-log "Move" tile was read as the Move tab button. It
is fixed. The other 27:
- `moss`-family text: each sheet's Done, Adjust, Adjust targets, the protein and "0g" amounts,
  Change, "Start from this", "Call 988", and the recipe book's three tabs. Rendered 3.48–4.02:1.
- The unselected Home tab over the bar's glass on the two Cycle screens: 4.43–4.50:1.
- One letter of companion artwork, the sleeping "z" at 2.47:1. WCAG exempts text inside a picture.

Measured at the same frames in the other appearances, **every one of the 27 clears its floor:
5.14–6.33:1 under Increase Contrast and ≥4.54:1 in dark** (the "z" too: 5.55:1 / 5.26:1). They are in
`UXScreenProbe.auditExemptions`, one control per entry, under that measured reason. So a new moss
label on a gallery screen still fails the wall until someone measures it. The sweep below found two
more moss labels the auditor never nominated, "Servings" and "Protein-Forward" (4.02:1). Both are the
same class and both pass under Increase Contrast.

**The wall's own result, after the burn-down:** the full light gallery, 25 of 25 screens, **0
failures**, with `.contrast` on (2026-10-18, iPhone 17 simulator, iOS 26.5).

The first dark and Increase Contrast runs were taken while the Mac slept, and 6 and 4 of their 25
screens timed out inside the audit. Both were retaken awake on 2026-10-18, with every screen
finishing (the slowest in 37 s); the table at the top of this section is that retake.

#### Cleared 3: the system text-field placeholder

The sweep found what the auditor never reports: every SwiftUI `TextField`/`SecureField` in the app,
**88 code lines in 32 files**, passed no `prompt:`, so its prompt drew in the system placeholder
colour: 1.71:1 in default light, 2.43:1 in dark and 4.33:1 under Increase Contrast, on the Meal sheet
("scrambled eggs and toast"), the recipe and recipe-book searches and Plan goals. Logging a meal is a
common task, so this was exactly what Apple's criterion is about.

1. **Every field passes an inked prompt.** FernletUI's `Text.fieldPrompt(_:)` draws full-strength
   `slate` in italic, the treatment `SheetTextEditor`'s placeholder already had: the italic and the
   slate-against-bark ink keep a prompt from reading as typed text. Each call site passes its own
   title (`TextField("Meal", text: $name, prompt: .fieldPrompt("Meal"))`), so the title stays the
   accessibility label and no string is added; the 11 fields titled by a `String` pass it through
   `fieldPrompt(verbatim:)`. 87 of the 88 lines carry one. The 88th, `MacroInputRow`'s inline gram
   editor, never shows a prompt: it opens prefilled with the value it edits. It is allowlisted with
   that invariant. The owner approved the look on before/after screenshots of the Meal, Goals and
   recipe-book sheets in light, dark and Increase Contrast.
2. **Rule A10-FIELD-PROMPT walls it.** `Scripts/accessibility-scan.py` and `AccessibilityBoundaryTests`
   refuse a `TextField(`/`SecureField(` whose call passes no `prompt: .fieldPrompt(`, read across a
   six-line window so a wrapped `Binding(get:set:)` is one call. Seven planted shapes fail on both
   halves (no prompt, `prompt: Text(…)` left in the system colour, `prompt: nil`, a `SecureField`, a
   `value:format:` field, an `axis:` field, and a wrapped binding), and the helper in either spelling,
   a comment and `SheetGrowingTextField` pass. The accessibility CI line's floor goes 21 → 22.
3. **The sweep is walled.** A swept text under 4.5:1 now fails the screen unless it sits in an inactive
   control, under the tab bar, a pinned header or footer or the keyboard, or an `auditExemptions` entry
   names that one text. The bar excuse is new: `PinnedBar` takes the buttons that no scroll container
   holds near the window's bottom, the buttons and texts near its top, and the system keyboard, and
   skips content scrolled under them and the fade beside them. That is where the sweep's non-ink
   readings came from: "ANYTHING ELSE?" (1.80:1) under the suggest bar and the workout search field
   (2.14:1) under `SheetSaveBar` on the gallery; "Calories" (2.27:1) in Nutrition targets' header fade
   and its footnote (1.43:1) under the number pad its UI test leaves up. "Servings" and
   "Protein-Forward", moss labels the auditor never nominated, joined the Increase Contrast entries.
4. **The three appearances were retaken awake** — the table above.
5. **The other probe screens were burned down too.** Turning `.contrast` back on, and then walling the
   sweep, reached every suite that calls `capture()`, not only the gallery. The other probe screens
   (onboarding, Settings, Nutrition targets, the item studio, Home's recent bites, the recipe detail,
   the Move log's photos) held findings no run had judged. Four were real ink defects, fixed:
   - onboarding's menu pickers drew their value in **system blue, 3.29:1**, because nothing tinted
     them; they now take `mossInk` (5.95:1 on the cream card);
   - the item studio's "Clear canvas" was plain `terracotta`, **4.16:1**, a token with no Increase
     Contrast twin; it is now `terracottaInk`;
   - Home's First aid subtitle (**4.28:1**) and a selected onboarding choice's subtitle (**4.44:1**)
     were full `slate` on a moss wash, under the floor by the wash alone; both are `bark`, as the
     "unwell" subtitle already was.

   The rest is the same class as the gallery's moss text and goes the same route: onboarding's step
   counter, Settings' Done, Nutrition targets' "Show calories in Fernlet" and Reset, Home's three First
   aid chips, "Add a photo of this recipe", the Move log's Add tile and Edit link, and Privacy &
   Data's "Multiple devices" heading (full `slate` on a terracotta wash, 4.34:1).

   Measured on those suites, plus the new `LargerTextAX5UITests`, in all three appearances with the
   Mac awake: **62 of 63 tests pass in each, none fails**, and the 63rd skips by its own design (the
   AX5 guided workout needs a suggested session the seed does not always have). The fixes measure
   5.23:1 or more in every appearance (pickers 5.95 / 5.74 / 8.03:1 in light, dark and Increase
   Contrast; "Clear canvas" 5.69 / 5.23 / 5.69:1; the two subtitles 9.99:1 or more). The exempted
   texts measure 3.75–4.34:1 in default light, 5.58:1 or more in dark and 5.54:1 or more under
   Increase Contrast.

#### What this declaration does not rest on

Stated so the wall is not mistaken for coverage:
- **Component boundaries.** The wall measures text, and the glyphs the auditor nominates against 3:1.
  It does not measure the edge of a card, a field or a chip. About 187 `bark` hairlines at 0.08–0.10
  alpha sit at 1.15–1.73:1, and only five shared components thicken theirs under Increase Contrast
  (`fernletHighContrastEdgeAlpha`). The controls on the common tasks are identified by their text,
  every label and prompt measured at 4.5:1 or more on the route this row is declared on, which WCAG
  1.4.11 accepts in place of a boundary. A control identified by its boundary alone would need one.
- **Screens off the gallery.** The three-appearance evidence is the 25 gallery screens plus the other
  probe screens, the AX5 ones included, on one device and one seed. Beyond them, the A8 and A10 grep rules hold the two inks
  that failed most, and nothing measures the rest.
- **Text over a photograph or a gradient**, where the probe's dominant-colour background is wrong.
  There is none on the gallery.

---

## 3. Undeclared, with the blocker named

These three are intended, not abandoned. Each names what would have to be true.

### VoiceOver — undeclared

**Apple's criterion is the strict one:** *complete all common tasks using only VoiceOver.* Not
"most elements are labelled" — **all common tasks, end to end, with the screen off-attention.**

**Blocker.** Fernlet's four common tasks are: log a meal, log water, log a mood, complete a workout.
Apple's fundamentals count too: onboarding, changing a setting, and finding help. Batches A1–A5
cleared a great deal — the app lock is now modal and speaks its failures (T0-1/T0-3), the widget
target went from *zero* accessibility modifiers to labelled (T1-7), the announcer exists and is
adopted at 14 sites (T1-2), 124 headings light up the rotor (T1-1). But the criterion is a **manual,
task-by-task pass on a device**, and that pass has not been run. Nothing mechanical can substitute
for it: the §4.5 wall explicitly does not catch a label that is present but wrong, a broken focus
order, or a missing custom action, and those are exactly what break a task rather than an element.

**The simulator half of that pass ran on 2026-10-18, and it found a lot.** Four read-only maps of the
task flows were followed by a UI suite that walks each task the way VoiceOver reaches it:
`Tests/FernletUITests/VoiceOverTaskUITests` on the `VoiceOverWalk` harness. Every control is found by
its spoken label or identifier and never by a coordinate. Every control must be a kind VoiceOver can
operate and must speak words. Every screen is audited with `performAccessibilityAudit`, restricted to
element description, traits and hit region, at zero tolerance and with no baseline. Each screen's
reading order is attached to the run.

**The suite's final result:** all eight walks pass on a private iPhone 17 simulator (iOS 26.5). They
cover water, a mood, a meal and its Undo, a logged workout, a guided workout to "Nicely done",
onboarding, a setting, and help. It took seven runs to get there, and each run stopped at the next
real defect. Two harness lessons are worth keeping:
- XCUITest lists a SwiftUI button's icon and text as separate elements that VoiceOver never visits,
  so the walk reads a button as one element, as VoiceOver does.
- XCUITest also lists a child of a `.contain` container that `.accessibilityHidden(true)` hides from
  VoiceOver. That is §5's finding again, so the walk excuses such a glyph only by symbol plus
  container, naming the source line that hides it.

The guided walk sets the Strength goal first. The seeded Wellness program suggests a cardio
descriptor on some days, and that has no runner. A run left live by an earlier launch is walked
through its Resume card.

The common thread was not missing labels. **The four tasks completed in silence.** A sighted user
sees the sheet close, the tile's count roll, the chip fill. A VoiceOver user heard the cursor land
somewhere and had to go looking for proof. What changed, all of it labels, traits, actions and
announcements:

- **Every common task now says it landed.** `App/Fernlet/TaskConfirmations.swift` holds the copy.
  It is caller-resolved, per `FernletAnnouncer`'s localization rule, and it announces the event,
  never the payload ("Mood logged.", never which mood; "Journal entry saved.", never the entry).
  - A meal is announced with where its Undo is.
  - A mood chip is announced only when the store actually wrote, because re-tapping today's mood is
    a no-op.
  - A workout is announced from the sheet, from "Already did this", and from a planned row's check.
  - A journal entry is announced on save.
  - Water is deliberately not announced. Its counters now carry an `.accessibilityValue`, the
    mechanism `FernletAnnouncer` reserves for counters. The water sheet's count is one adjustable
    element, so swiping up and down adds or removes a bottle, and the one-tap add on Home carries the
    count it changes. Before, that count was drawn on a different element and every double-tap was
    followed by silence.
- **The meal Undo toast was a destructive-undo window VoiceOver could not see.** It appeared with
  no announcement, and its 20 s assistive window (`FernletDismissalWindow`) ran down even with the
  cursor parked on Undo. It now announces itself. It also waits a second at a time, up to five
  minutes, while VoiceOver's cursor is on any part of it (`@AccessibilityFocusState`, read and never
  written). Undo itself says "Meal removed."
- **The guided workout lost the cursor on every set.** Its bottom bar was an `if`/`else` of two
  buttons, and SwiftUI gives each branch its own identity, so every "Done set" and every "Skip rest"
  destroyed the control under the cursor.
  - It is now one button whose words and action follow the phase.
  - Each transition is announced: "Set done. Resting.", "Set 2 of 3.", "Next exercise: …",
    "Workout finished and logged.". The mapping is a pure function, `GuidedRunAnnouncement`, pinned
    by `TaskConfirmationTests`.
  - The rest timer gained `.updatesFrequently`. Without it VoiceOver kept the time it read on
    arrival, which the Live Activity's own timer already handled.
  - A rest reaching zero is announced, because nothing on screen moves at 0:00.
- **VoiceOver's escape gesture was dead on every logging sheet with input.**
  `interactiveDismissDisabled(isDirty)` swallowed the two-finger scrub: no dismissal, no discard
  prompt, no sound. `FernletDraftGuardModifier` now maps escape to its own Cancel, discard prompt
  included, which covers every draft-guarded sheet at once. The water sheet and the guided runner got
  the same treatment.
- **Onboarding's steps swap in place, so VoiceOver was never told the screen changed.** The cursor
  could land on the next step's Continue and skip a screen unheard. Each step's header now takes
  focus when it appears.
- **Controls that named nothing:**
  - the Suggest-workout sheet's "Anything else?" field, which had no spoken name at all;
  - the meal field, which read its example placeholder ("scrambled eggs and toast"), easy to mistake
    for typed text;
  - the manual-macro rows' amount button, field and stepper;
  - the meal review sheet's quantity field and stepper, one per item, none saying which;
  - three onboarding fields and the age stepper;
  - the eating-pattern rows, whose only selection cue was a glyph's name. They now carry
    `.isSelected`.
- **Glyph names and wrong system labels spoken.** The audit's last frozen "Label not
  human-readable" finding was `figure.strengthtraining.traditional` on the Move tab's workout cards.
  It was found and fixed independently by this round and by the Larger Text round (#38): both hid
  the cards' icons, and the two fixes merged as one. This round also hid the journal sheet's
  `sparkles` and banner glyphs, the catalog rows' trailing glyph, the Log-it-again card's arrow, the
  runner's done-screen leaf, and the progress-photo placeholder.

  The walk also caught one that no audit flags: the Suggest sheet's space-row pin,
  `mappin.and.ellipse`, read as **"Remove Map Pin"**. That is the system's own description of the
  symbol, a present-but-wrong label beside a row that removes nothing, and exactly the class §5 says
  no tool can judge. It was found by reading the run's attached transcript.
- **Navigation:**
  - "Quick log", "How today felt", "Today's workout", "Workout in progress", the runner's "Rest" and
    "Nicely done", the meal review title, and Safety & reporting's section titles are now headings.
  - The Home tab's long-press-to-Settings shortcut has a VoiceOver action, "Open Settings".

**What the simulator could not prove, and why the row stays undeclared.** XCUITest cannot hear an
announcement, cannot see where the cursor lands after a sheet closes or a step changes, cannot fire
the two-finger scrub, and cannot list custom actions (§5). Every one of the fixes above is therefore
an argument, not yet a fact. `TaskConfirmation.sheetSettle`, the 0.7 s wait before a closing sheet's
confirmation is spoken, is a reasoned figure, not a measured one.

**Owner call: there is no in-app Help.** Apple's fundamentals include finding help. Today help is
Settings › Safety & reporting, with regional crisis lines and the developer's email, plus the Privacy
Policy. Settings search finds it from "help". A web support page with common questions exists, and
nothing in the app links to it. Whether that is enough, or the app needs a Help row first, is a
product decision. It is recorded here rather than built unasked. A link out would also be a new
outbound destination for the no-tracking wall's allowlist.

**What would clear it.** One end-to-end VoiceOver-only session on a device, not the simulator.
- Run it with Screen Curtain on and a stopwatch on the Undo toast.
- Do all four tasks and the three fundamentals.
- Follow the owner's step-by-step checklist from this round, which is kept with the local handoff
  material, not in the repo. It lists, step by step, what each fix above should sound like.
- If that session succeeds, this row can be added at any subsequent submission at no cost, with the
  checklist's result table as the evidence.

Declaring it before that session is the single most tempting over-claim available here, and it is
refused.

### Voice Control — undeclared

**Apple's criterion:** *every common task can be completed with Voice Control* — by saying a
control's name ("Tap Log water"), or, where two controls share a name or a control has none, by
saying its number from the numbered overlay. The common tasks are the four above plus the
fundamentals: onboarding, changing a setting, finding help.

**Blocker: the device pass, and nothing else known.** The simulator cannot run Voice Control, so
the one test that can clear this row is the owner's pass on a real iPhone, written out phrase by
phrase in `Docs/Handoff/a11y-2026-10-18/voicecontrol-device-pass.md`: every task by voice, then a
"Show numbers" pass of every screen on those paths. Until that pass succeeds the row stays
undeclared. The code-side blocker this section used to name was sentence-long names on the
common-task paths. It is cleared as far as the inventory and rule A9 can see, and what they cannot
see is listed at the end of this section.

**How a name is decided, and why sentences were the problem.** Voice Control names a control by its
`accessibilityInputLabels` when it has them and by its accessibility label when it does not. Labels
here are written for VoiceOver, so many were sentences or carried live state: a Voice Control user
would have had to say "Tap Meals, 3 logged", a phrase that changes with every meal. Input labels
are a second, short set of names for the same control. They leave the VoiceOver label untouched,
and they lead with the text drawn on the control.

**The inventory (2026-10-18).** `Tests/FernletUITests/VoiceControlNameInventoryUITests` walks every
common-task screen and attaches, per screen, each control's spoken name, its identifier and the
text drawn inside it. It flags names that are long, empty, duplicated, a raw SF Symbol identifier,
or different from what is drawn. It covers 32 screen states: all eight onboarding screens, Home
(top and scrolled), the meal sheet (empty, with catalog results, with a food chosen), the Food
tab, the water and journal sheets, the Move tab, both workout-sheet kinds, the workout suggestion
and its plan, the Private hub's journal, the Settings hub with Goal & nutrition, Appearance and
Safety & reporting, and First aid. The guided runner is the one gap. The demo seed's plan for
today is cardio, which the runner does not guide, so the suite records the plan and stops there.
The runner's names are checked from source ("Done set", "Skip rest", "Skip exercise", "Close") and
by the device pass. What the suite found on those paths:

| Defect | Where | Fix |
|---|---|---|
| The name changes as the user logs | Home's six quick-log tiles ("Meals, 3 logged"); the weight, height and age steppers ("Weight: 170 lb") in onboarding and Goal & nutrition | The drawn noun, plus a "Log …" synonym on the tiles ("Log meal", "Log workout"); the field's word on the steppers |
| Title plus a sentence of copy | The onboarding lock, storage, goal and eating-pattern cards; First aid's three tools; meal rows, catalog results and exercise rows ("Bench press, Upper - Chest, Front Delts, Triceps") | The title or the item's name alone |
| Name is not the drawn text | Mood chips (drawn "Bright", named "Mood: Bright"); "Capture" (named "Capture food"); "Adjust" (named "Adjust meal"); the meal field (no label; its placeholder is an example) | The drawn word first |
| A drawn glyph with a long name | Home's water plus ("Add a bottle of water"), the guided runner's X ("End session"), the developer email link (named by its address) | "Add water", "Close", "Email" |
| No name at all | Settings › Appearance's bedtime and wake-up time pickers (an empty label, so reachable only by number). The workout suggestion's note field and onboarding's two name fields were named only by example placeholders too; the VoiceOver labels from #39 now name them | "Bedtime", "Wake-up"; nothing more for the three fields |
| Many identical controls | Each meal row's Delete and Adjust; each session friend's heart; each meal-planner day's plus; Appearance's two colour Resets and each Home widget's remove X | A unique form with the meal, friend, weekday or row in it, beside the short one |

In all, **38 input-label sites were added** (50 in the tree, from 12), several of them on shared
components: one `QuickLogButton` names every tile, one `QuickMoodRow` names every mood chip, and one
`CatalogSuggestionRow` names every catalog result. No `accessibilityLabel` text was changed.

**What the inventory measured about itself, so its numbers are not misread.** XCUITest reports
a SwiftUI button's drawn children as more elements of the button's own type. The first run
therefore counted the five-button tab bar as fifteen "duplicated" names, one of them the raw symbol
name `person.2.fill`. VoiceOver and Voice Control see one element per button, so the walk now stops
at a control. And XCUITest has no attribute for input labels at all, so a long label that already
has short input labels still reads as long in the listing. The suite fails only on a name that is
an SF Symbol identifier, which no input label can excuse.

**The mechanical half: rule A9 in the §4.5 wall** (an addition to §5's list of nine).
`Scripts/accessibility-scan.py` and its Swift twin `AccessibilityBoundaryTests` now fail on a
literal `.accessibilityLabel(…)` or `.fernletIconButton(…)` longer than four spoken words with no
`.accessibilityInputLabels(…)` in the same modifier chain. Each interpolation counts as one word, a
separator such as "·" counts as none, and a ternary is measured by its longer branch. It found 25
sites. 11 were controls and now have input labels. 13 can never be activated (QR codes, progress
spinners, the macro rings, the care-score bar, a section header), so Voice Control never names them.
One is a label on the text inside a catalog result's button, whose own input labels already name
the food. Each of those 14 is allowlisted with its reason. Its honest ceiling: it reads literals only, so
a label in a variable or built by a function is invisible to it. It cannot judge whether an input
label is good, unique on its screen, or the same as the drawn text. Those are the inventory's job
and the device pass's.

**What is still true and is not a blocker.**

- **Shared names fall back to numbers by design.** On Home, the Move tab and the Move tile share a
  name, so "Tap Move" shows numbers ("Tap Log workout" goes straight to the tile). The Walking and
  Running chips match the list rows below them, and two meal rows' "Adjust" match each other. Voice
  Control's numbered fallback is the intended answer there, and the device pass records each such
  case.
- **The Private hub's month grid exposes its blank leading and trailing cells as four buttons named
  "Empty calendar cell".** They do nothing, so in the numbered overlay they are four numbers over
  nothing. That is the element's kind rather than its name, so it belongs to the VoiceOver work. It
  is recorded here because the device pass will meet it.
- **Long names left on controls the common tasks do not use**, such as Home's "Trends, Review local
  signals." and the Move tab's progress-photo tiles ("Progress photo from September 9, 2026", drawn "Sep 9").
  Whether these are blockers depends on whether iOS accepts the first words of a long name. That is
  the device pass's first experiment, and its answer decides whether they need input labels too.
- **German runs longer**, as the Larger Text row says; input labels localize through the string
  catalogs like every other display string, so a translator gets each one as its own key.

### Larger Text — undeclared

**Blocker: the burn-down is not at zero on the common tasks, and nobody has looked at AX5 on a
device.** Apple requires **verified no-truncation at AX5 across all common tasks**. The mechanical
half was already in place before the burn-down: the §4.5 wall's rule A5 forbids a fixed
adaptive-grid minimum, rule A4 forbids a `Font.custom` without `relativeTo:`, the AX-size content
drops re-expose through `.accessibilityCustomContent` (T2-2), and the named fixed-pixel minimums are
`@ScaledMetric` (T2-11).

**Where it started.** The first runtime audit, over the 25 screens of the `ScreenAppearanceUITests`
gallery, found **119 raw issues**: 76 text clipped, 19 Dynamic Type partially unsupported, 15 hit
areas under 44pt, 7 potentially inaccessible texts and 2 "Label not human" (a glyph name read
aloud). Frozen as issue identities by the ratchet in
`Tests/FernletUITests/UXScreenProbe.auditBaselines` — which by 2026-10-17 covered every probe suite,
not only the gallery — that was **167 identities on 37 screens**.

**Where it is (2026-10-18, branch `claude/focused-curie-bf7c00`).** Measured on a private iPhone 17
(iPhone18,3, portrait, `large`, en_US, light), every line removed after a run reported it gone:

| Category | 2026-10-17 | Now (the 37 original screens) | What is left |
|---|---|---|---|
| Text clipped | 98 | **34** | 8 text-field placeholders, 5 element-less, 5 sheet titles, 5 field captions, 5 personal-care rows, 6 others (below) |
| Dynamic Type partially / un-supported | 51 | **6** | Settings hub's 3 (system-drawn Done, a section header, one element-less), the studio confirmation's 3 |
| Hit area too small | 7 | **2** | Sleep's 19pt hours field, Nutrition targets' Reset |
| Potentially inaccessible text | 10 | 10 | not a Larger Text finding (OCR, boot-dependent; §5) |
| Label not human | 1 | **0** | — |
| **Total** | **167 on 37 screens** | **52 on 20** | |

Plus **8 lines on 3 new `AX5 · ` screens**, below. What moved it, in the commits that carry the
before/after counts: the custom tab bar's hidden labels left the layout (50 lines — the tab bar was
on every screen); `ScreenHeader` and `SheetHeader` lift their line limits at accessibility sizes
(onboarding, 7); side-by-side rows stack and one-line captions wrap (the Move strip and space row,
Sleep's fields, recipe notes, meal polaroids, progress-photo captions); a pinned action bar that
left the guided plan ~150pt at AX5 now scrolls with it; Home's quick-log tiles and the month
calendar stopped being lazy grids and the tile counts scale with `.caption`; four targets reached
44pt; and 32 under-reporting Dynamic Type lines that never reproduced in four full audits and four
Dynamic-Type-only passes were deleted on that measurement. **Home now audits with no findings.**

**The AX5 check over the common tasks.** `LargerTextAX5UITests` launches the app **at** AX5 —
not from `large` — for Home, the meal, water and journal (mood) sheets, the workout suggestion and
plan, the manual workout log, Settings and the first three onboarding steps, attaches every AX5
screenshot, and audits the stable ones. Home, Water, Journal and the onboarding steps audit clean.
Meal (2), the Settings hub (2, both system-drawn) and the workout suggestion (4) carry `AX5 · `
baselines, and in every one of those screenshots the text is drawn whole. The workout plan, the
manual log and Home's mood row are screenshot-only: their findings would rotate with the weekday or
with where a scroll stops. The guided runner is reached only on a day whose suggested session is
guidable, so it is on the device-pass checklist. The probe inventory is now 50 screen names.

**What the audit turned out to be measuring — read this before trusting any count above.**

- `Text clipped` means *may* be clipped **at a larger size than the screen is at**. From `large`, the
  audit's own Dynamic Type pass re-lays an already open sheet out at AX sizes, which reports some
  clipping no AX5 user sees (a medium sheet does not regrow its detent mid-audit) and misses some
  they do: a text field's example truncating, a pinned bar crowding its content. That is why the
  AX5 suite exists, and why the AX5 screenshots are the better evidence.
- Many remaining lines are drawn whole in the AX5 screenshots: the sheet titles ("Log meal",
  "Suggest workout"), several field captions, text running off the bottom of a scrolling screen.
  They stay in the map as what the audit says, not as defects anyone has seen.
- **Text-field placeholders** (8 lines) are one line by platform design and do truncate at AX5;
  what the user types is not affected. Shorter AX-size examples per field is the remaining fix, and
  the Settings search field is drawn by iOS.
- Swapping two views at the accessibility boundary (`if isAccessibilitySize { A } else { B }`)
  makes the audit lose the element and report an element-less finding, which the ratchet treats as
  new. `AdaptiveStack` now switches with `AnyLayout` for that reason.
- "Dynamic Type partially unsupported" on fonts that do scale came from two things, each measured:
  a `LazyVGrid` tearing down rows pushed off screen, and `.caption2`'s ramp, which is a flat 11pt
  from xSmall to Large.

**What would clear this row:** the remaining common-task lines fixed or shown on a device to be
drawn whole — the meal, water and workout sheets' lines, the onboarding name field — and then **the owner's AX5 device pass** over every common task, from the checklist in
`Docs/Handoff/a11y-2026-10-18/largertext-device-pass.md`. Until both are done the row stays blank.

**One platform note, because it is a trap:** Apple explicitly **forbids citing Hover Text** as
evidence of Larger Text support. Hover Text magnifies one element under the pointer; it is not text
scaling, and offering it as the answer is treated as an over-claim.

**A second note, recorded because it is cheap now and expensive later:** every `isAccessibilitySize`
branch and every `minimumScaleFactor` in the tree is calibrated against **English** string lengths.
German runs 30–40% longer. The day a translation ships, this row's evidence has to be re-taken.

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

- `Scripts/accessibility-scan.py` + `Tests/FernletTests/AccessibilityBoundaryTests` — **nine**
  structural rules with a zero-violation baseline and one shared allowlist
  (`Scripts/accessibility-allowlist.json`), each entry stating the invariant that makes it safe:
  A1 a `.combine` anywhere in a modifier chain that also carries a label, A2 a spoken `rawValue`,
  A3 the three heading components' `.isHeader` canary, A4 a `Font.custom` without `relativeTo:`,
  A5 a fixed `GridItem` width, A6 an `Image(uiImage:)` with no `.accessibilityIgnoresInvertColors`
  (Smart Invert turning a user's photograph into a colour negative — T2-10), A7
  `.accessibilityElement(children: .ignore)` on a `Button` (the traitless-second-element defect
  below), A8 `slate` drawn at an alpha below 1, A10 a `TextField`/`SecureField` that passes no
  `prompt: .fieldPrompt(…)` and so draws its prompt in the system placeholder colour (both §2,
  Sufficient Contrast).

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
  `capture()`, across the probe screens, running `.all` (`.contrast` in its own first pass, judged
  by measurement — see the last paragraph of this section), with a per-screen
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
  the content the app-lock gate covers — the gate applies `.accessibilityHidden(true)` to everything
  under its overlay, and an XCUITest query run while the overlay is up still finds the covered
  Private hub's "New journal entry" button. So `XCTAssertFalse(app.descendants(…)["screen.journal"].exists)`
  can never pass while the gate paints, no matter how correct the app is. (Until 2026-09-30 the
  subject was the setup call to action's decorative `Image(systemName: "lock.shield")`, which XCUITest
  reported under a label synthesised from the symbol name. The no-passcode tap screen that replaced
  that overlay puts its decorative `lock.open` inside a `ScrollView`, and there the snapshot reports
  no image element at all — one data point that the tool's behaviour depends on the container, which
  is one more reason the grep-wall, not a runtime query, is the enforcement.)

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

  **`.isHittable` reported `true` for controls under the gate** (under the setup call to action;
  under the no-passcode tap screen's full-screen scroll view it reports `false`, measured
  2026-09-30), and that was triaged here as an observability artifact. A second test in that file now taps the covered journal's "New journal
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

**How `.contrast` runs, now that it is back.** It was subtracted until 2026-10-18 on a correct
diagnosis: XCUITest's contrast auditor samples rendered pixels and, on this palette, its verdicts do
not follow the WCAG ratio. Measured on the gallery, it fails `bark` headings at 19.6:1, calls
3.73:1 `moss` text only "nearly passed", and misses 1.83:1 captions entirely (§2). It came back as a
**nominator**. `UXScreenProbe+Contrast.swift` decides each nominated element by measuring it in the
screenshot. A finding is excused only when the element is disabled, covered by the tab bar, a
pinned header, footer or keyboard, or the window edge, or its ink clears the floor, and every
excused finding is listed in the run's attachment with its number. What survives is real, and fails
the screen unless `UXScreenProbe.auditExemptions` names that control with a measured reason. Beside it, a **walled
sweep** measures every visible text element and empty-field prompt, because the auditor's recall is
as poor as its precision; that sweep is how the field-prompt blocker in §2 was found. A swept text
under 4.5:1 fails the screen unless it sits in an inactive control, under the tab bar or a pinned
header, footer or keyboard, or an `auditExemptions` entry names that one text.

Its ceiling, stated as plainly as the rest:
- It judges a nominated element only where the screenshot shows it.
- A dominant-colour background is wrong for text over a photograph or a gradient.
- A pinned header or footer is found by geometry: elements that no scroll container holds, near
  the top or the bottom of the window. Each band errs wide by a few points, and a screen with a
  fixed control near either edge gets one too, so the few points of text beside such a control go
  unmeasured. The attachment names every band.
- The sweep sees only the screens the probes visit.
- The map describes **default light**. Dark mode and Increase Contrast are re-taken by re-running
  the gallery with the simulator set that way (`xcrun simctl ui <udid> appearance dark`,
  `… increase_contrast enabled`), which no test can do for itself.

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
