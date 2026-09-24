# Companion emotions — scoping note (2026-09-23)

> **SCOPING ONLY. Nothing in this note is built, and companion behavior is unchanged.** The work is
> meant for a separate session. Owner, verbatim: *"having a happy companion on a hard day seems
> wrong. We'll need to add more emotions for the companion."*

## 1. How `CompanionState` is derived today

The whole derivation is `FernletScoring.state(for:isSick:)` (`FernletKit/Sources/FernletScoring/Scoring.swift`):

| Condition | State | Frozen raw value | Display label (`displayName`) |
|---|---|---|---|
| today marked unwell | `.sick` | `"Sick"` | Sick |
| score ≥ 0.75 | `.thriving` | `"Thriving"` | Thriving |
| score ≥ 0.50 | `.okay` | `"Okay"` | Okay |
| score ≥ 0.25 | `.tired` | `"Tired"` | Tired |
| score < 0.25 | `.resting` | `"Resting"` | Resting |

The score is `FernletScoring.computeBreakdown`. It weights six components by goal: journaling,
meals, movement, sleep, hydration and personal care. Four modifiers adjust it: the sickness
reweight, the period leniency, the micronutrient nudge and the stress nudge.

Two call sites compute the state:
- `FernletStore.companionState` is today's live value.
- `DiaryStore.dailyHealthScore(for:day:)` stores each day's state in `DailyHealthScore.companionState`.

**Nothing in the chain reads how the day felt.** Since 2026-09-23 the journal tag no longer affects
the score at all: every entry earns the same journal credit (`JournalScoringParityTests`). The tag
now survives only as the breakdown's unweighted `"mood"` reading, which feeds the period bridge.
A day tagged *hard* with decent sleep and meals therefore scores exactly like a *bright* one, and
often lands in `.thriving`.

**The journal change makes this more frequent.** A hard-day entry used to earn 0.30. It now earns
1.0, which lifts the overall score by +0.126 under the wellness weights and +0.21 under mental
health. That is enough to move many ordinary hard days from `.okay` to `.thriving`. It is the
strongest reason to take an interim option (§6) before the full work.

**Emotion-like accents already exist, all presentation-only.** They are never persisted, never a
`CompanionState` case, and suppressed for the low-energy states. Each is a flag on `CompanionView`
in `App/Fernlet/CompanionVectorAssets.swift`:
- `stressTint` ("frazzled", from the opt-in body signals)
- `calmTint` (happy-arc eyes, blush, motes)
- `settled` (the pet cooldown)

These flags are the precedent to build on. `calmTint` in particular draws *happy-arc eyes*, so on a
hard day with calm body signals the companion currently looks happier still.

Spec drift worth fixing alongside: spec §5 names the < 0.25 state "Fainted" and gives sick the
label "Resting". The code calls them `.resting` and `.sick`.

## 2. Every surface that renders it

| Surface | Where | Reads | Notes |
|---|---|---|---|
| Home companion (132 pt, interactive) | `HomeView.companionSection` | `store.companionState` + the three accent flags | Accessibility value = `displayName` |
| Home "Today" health bar | `HealthBar(state:value:heartGlow:)` | state colour | `CompanionState.color` (`FernletUI/ModelColors.swift`) |
| Home companion sheet, wardrobe and studio previews (84 pt) | `HomeView` ~L1614/1922/1942 | state | appearance `.state` palette slots resolve per state |
| Creation Studio previews | `CreationStudioView` L206, L490 | state | decorative |
| Launch screen companion | `ContentView` → `LaunchScreen(companionState:)` | state | decorative |
| Journal day detail | `JournalView` `scoreState` | **stored** `DailyHealthScore.companionState` | history view |
| Home-screen / Lock Screen widgets | `WidgetBridge` → `WidgetSnapshot.companionStateRaw` → `App/FernletWidgets/WidgetSharedModels.swift` (`WidgetCompanionState`) → `FernletWidgetsBundle` (`CompanionGlyph` faces, `FernletWidgetPalette.mood`) | raw token, re-parsed in a separate process | written by the foreground publish and by the background `CompanionRefreshWiring` recompute |
| Friends | `CompanionState.fuzzy` → `FriendFuzzyState` (1/2/3, one constant-length byte, sealed) → friend's roster renders `representativeState` | 3-way fold | `sick`/`resting`/`tired` → struggling |
| Exports | `DataExportBuilder` (`state: rawValue`); `TrainerExportBuilder` (sickness-masked `rawValue`); the Coach export schema that a second app reads | raw token | a new value is a schema change |
| Thought bubbles | `HomeView.ambientThought` | **not** state | reads journal tag, AI thought, signals |
| AI prompts | companion thought, day summary | **not** state | signals + journal tag label only |
| Live Activities (workout, cooking), Messages extension | — | **not** state | no companion rendered |

## 3. Constraints

- **The raw values are frozen tokens.**
  - `"Thriving"`, `"Okay"`, `"Tired"`, `"Resting"` and `"Sick"` persist on every `DailyHealthScore`
    and sync to iCloud.
  - They are byte-mirrored by `WidgetCompanionState` in the widget process, pinned by
    `LocalizationBoundaryTests` part C (`frozenCompanionStateRawValues`).
  - They are also a Coach-export field.
  - Only `displayName` is ever localized. A new case needs a frozen token *and* a display label, in
    both the app and the widget catalogs.
- **Cross-version behavior of a new case.**
  - `DailyHealthScore` decodes `companionState` tolerantly. An older build parks an unknown token
    and falls back to `.okay`, so history survives.
  - The widget mirror does not tolerate it: `WidgetCompanionState(rawValue:)` returns nil, and the
    widget shows its neutral "Fernlet" face.
  - That is fine within one install (the app and the widget update together). It needs a pin
    anyway.
- **Every exhaustive switch.**
  - `CompanionVectorAssets` has four (`animationTempo`, `horizontalBreath`, `verticalBreath`,
    `mouthHeight`) plus `isLowEnergy`.
  - The rest: `ModelColors` (`color`), `FriendState` (`fuzzy`), `WidgetCompanionState.displayName`,
    and the widget's face-erase and palette switches.
  - `FernletDomainModel` enum changes need a **clean** build (memory:
    fernlet-domainmodel-clean-build-hazard).
- **Privacy and visibility.**
  - The journal tag itself survives the seal strip (it is classified non-sensitive), so deriving an
    emotion from it opens no new S3 path.
  - A "tender" face on a Lock Screen widget, however, tells anyone looking at the phone that today
    was hard.
  - Friends must keep seeing only the 3-way fold. A new state folds to `okay` or `struggling`, never
    to a new bucket.
- **Tone.** "Signals never alarm the user." A new emotion must never read as sad, disappointed or
  "you did badly". It must be warm, present and companionable.

## 4. What adding emotions would take

### Candidate emotions and triggers

| Emotion | When | Existing input |
|---|---|---|
| **tender** | today's latest journal tag is *hard* or *tired*; or `moodTrend == "needs gentleness"` | `store.day.journals.last?.tag`, derived signals |
| **reflective** | a written entry today tagged *quiet* or *neutral* | same |
| **comforted** | a friend's heart arrived today (`store.heartGlow > 0`) on a tender day | heart-drop glow (already presentation-only) |

Sick keeps `.sick`, and the flag wins over every emotion. There is **no** "proud" or streak-like
emotion, because that would reintroduce optimization.

### Route A — presentation-only emotion accents (recommended)

Add accents in the pattern of `calmTint` and `settled`:

- **The flag.** An `emotion: CompanionEmotion?` parameter on `CompanionView`. It is a *render* value,
  never persisted and never synced.
- **The derivation.** A pure static function takes today's journal tag, the mood trend, the unwell
  flag and the heart glow, and returns an emotion. Home computes it next to `stressTintActive`.
- **Art and animation.** Per emotion: eye shape (softened, lowered gaze), blush, breath tempo, and
  one small motif (for example a held leaf for *tender*, a drifting page for *reflective*, a warm
  glow for *comforted*). Every emotion must be suppressed or reconciled with the existing accents.
  Any emotion outranks `calmTint`'s happy eyes.
- **Accessibility.** Extend the Home companion's accessibility value, for example "Okay, feeling
  tender". Each emotion needs a localized label (app catalog).
- **Widgets.** Optional, a later phase. It needs an additive `companionEmotionRaw` field on
  `WidgetSnapshot`, mirrored in `WidgetSharedModels.swift`. It is off by default because of the
  Lock Screen visibility concern above.
- **Unchanged.** No `CompanionState` token, friend wire, export or `DailyHealthScore` change.
- **Tests.**
  - The derivation table: every tag × unwell × trend.
  - "Never happier than okay-looking on a hard day": no happy-arc eyes when `emotion == .tender`.
  - Emotion labels are display forks.
  - The UI appearance baselines, run serially (memory: ux-appearance-test-harness).

### Route B — new `CompanionState` cases

For example `.tender` / `"Tender"`. This goes through every constraint in §3:

- tokens and labels, in two catalogs;
- a second input to `FernletScoring.state` (the tag);
- persistence in `DailyHealthScore`, so history shows tender days;
- every exhaustive switch;
- new widget glyph faces;
- a Coach export schema bump;
- the friend fold;
- tolerant-decode and widget-mirror pins;
- a clean-build pass.

It buys emotions in history, widgets and exports. It costs a cross-process and cross-version
change, and it puts "today was hard" on the Lock Screen by default.

## 5. Rough size

| Work | Size |
|---|---|
| Interim option (§6, existing art only) | ~0.5 day including tests |
| Route A, *tender* only (art iteration dominates) | ~2 days |
| Route A, all three emotions | ~3–4 days |
| Route A widget phase | +1 day |
| Route B, three new cases, everything in §3 | ~1–1.5 weeks, plus design; UI-appearance baselines move |

## 6. Interim options for the owner — EXISTING art only, not changes

1. **Cap the displayed state on hard/tired days.** When today's latest journal tag is *hard* or
   *tired*, the companion *shown* never goes above `.okay`. The score, the stored
   `DailyHealthScore`, exports and friends are untouched. Two decisions: Home only, or Home plus the
   widget (which also hides "thriving" from the Lock Screen on those days). This is the example in
   the brief, and it directly answers "a happy companion on a hard day".
2. **Drop `calmTint` on hard/tired days.** Its happy-arc eyes are the happiest face the companion
   has. This is a one-line gate beside `calmTintActive`, and it pairs naturally with option 1.
3. **Lean on words, not faces.** Once the day has a journal entry, the ambient thought already
   acknowledges the tag all day ("You marked today as hard. Let that be enough information for
   now."). It outranks the AI thought and the signal lines. The option is to give *hard*/*tired*
   days their own, warmer line. Copy only, no art.
4. **Borrow `.tired`'s softer posture** (drooped eyes, slower breath) on hard days. **Not
   recommended**: it reads as the companion being sad at the user rather than with them.

## 7. Recommendation

Take interim options **1 + 2** now: display cap at `.okay`, Home and widget, plus no `calmTint`, on
hard/tired days. They are small, reversible, and use existing art. They also neutralize the extra
thriving days that the 2026-09-23 journal change creates.

Then build **Route A** with *tender* first, in its own session with a design pass. Revisit Route B
only if the owner wants emotions to appear in history, exports or widgets.

**Owner decisions needed:**
- Which interim option or options, and on which surfaces.
- The emotion list and triggers (§4).
- Whether any emotion may appear on the Lock Screen widget.
