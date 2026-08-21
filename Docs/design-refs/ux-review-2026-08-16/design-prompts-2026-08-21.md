# Claude Design prompts — 2026-08-21

Prompts for the five design canvases covering the 45 mockup-flagged findings from
`Docs/UI-UX-Review-2026-08-16.md`. Per canvas: paste the **preamble + one batch block**, attach
the review doc and that batch's screenshots from `shots/fresh-2026-08-21/`. Design tokens below
are copied from `FernletKit/Sources/FernletUI` (FernletDesignSystem.swift / FernletTheme.swift /
FernletUIComponents.swift) — the source of truth, not eyeballed.

---

## PREAMBLE — paste into every canvas, then add ONE batch block

You are designing screen mockups for **Fernlet**, a privacy-first iOS self-care app with a
"tamagotchi-of-yourself" companion. The tone is gentle and anti-optimization: no streaks, no
pressure, soft copy ("No workouts today. No rush."). I've attached the app's UI/UX review
document and current screenshots of the screens in scope.

### Your task
Redesign the screens listed in the SCOPE block below, resolving the review findings cited by id
(e.g. `HOME-02`). Look each id up in the attached review doc — every entry has "What's unclear
or slow" and a "Recommended change". Follow the recommended change unless it conflicts with
something visible in the screenshots; the screenshots are the current build and are authoritative
over the review text where they differ (the review predates a round of shipped fixes).

### Design system — reproduce this exactly
iPhone artboards, 402×874 pt, light mode.

**Palette (light):**
- Screen background `#F5EFDF` (parchment) · card/box surface `#FBF7EE` (cream)
- Primary ink `#3D2E1E` (bark) · secondary ink `#5C6B78` (slate)
- Primary accent / filled buttons `#5E844D` (moss), ink on moss `#F5EFE0`
- Support greens: `#72A364` (fern), `#C8DBC2` (lichen, tinted fills)
- Destructive `#B9543D` (terracotta) · warm accents `#D2973B` (goldenrod), `#EBB551` (sun),
  `#B67073` (dusty rose) · neutral `#B8A892` (soft taupe)

**Type (all on Google Fonts):**
- Screen titles: Fraunces SemiBold 36 · sheet titles: Fraunces SemiBold 28
- Card headers: DM Serif Display 24/20
- Body text: Instrument Serif 17/15 · companion speech & hints: Instrument Serif Italic 14
- Buttons, chips, form labels: DM Sans Medium 14 · section eyebrows: DM Sans 12,
  UPPERCASE, tracked, slate · stats/numbers: DM Sans Medium, tabular digits

**Component vocabulary (match the screenshots):**
- Cards: cream rounded-rects (~24pt radius) on parchment, generous padding, soft shadow
- Primary action: moss-filled pill, parchment ink; secondary: cream pill with bark ink;
  destructive: terracotta-filled pill
- Chips: pill outline, selected state = dark bark fill with cream ink
- Sheets: grabber at top, title top-left, Cancel top-left or Done/primary bottom-right
- Floating pill tab bar (Home · Food · Move · Friends · Private) overlaps content at screen bottom

### Rules
1. One artboard per screen state. Name every artboard with the finding ids it resolves,
   e.g. "Water sheet — HOME-02".
2. Design at medium sheet detent where the finding is about detents — show that the primary
   controls fit above the fold.
3. Touch targets ≥ 44pt. Small text ≥ 4.5:1 contrast on parchment/cream.
4. Don't invent new features or screens; rearrange and restyle what exists. Keep all copy in
   Fernlet's voice — warm, brief, never guilt-inducing.
5. Where an entry offers two alternatives ("or"), mock the first option as the main artboard
   and the second as a smaller variant artboard beside it.
6. Add a short annotation note next to each changed region naming the finding id it addresses.

---

## BATCH 1 — Move workout flow

SCOPE — Move tab workout flow. Findings: FLOW-03, MOVE-01, MOVE-17, MOVE-10, MOVE-26, MOVE-08, MOVE-34.

Artboards to produce:
1. Move root, NO plan yet (FLOW-03): today's screenshot shows no start/suggest entry at all.
   Design the "Today's workout" card in its empty state with one primary button
   "Suggest today's workout". Note: the with-plan state already exists (see the
   approved-plan screenshot) — match its card so empty/filled read as the same component.
2. Suggest workout sheet (MOVE-17, MOVE-10, MOVE-34): fix the two-competing-green-primaries
   problem and the nested 260pt scroll that hides duration/effort fields; presets should not
   repeat locations the user already has.
3. Suggestion result "Today's session" (MOVE-01 context): clarify the Edit / Approve /
   Already-did-this hierarchy — one primary.
4. Guided runner, mid-set (MOVE-26): "Done set" currently floats mid-screen with the bottom
   half empty — move it into thumb reach and use the freed space (set progress, rest preview).
5. Log workout sheet (MOVE-08): add a "recent exercises / repeat last workout" affordance
   above the search list.

---

## BATCH 2 — Canonical sheet template + Water sheet

SCOPE — the shared sheet pattern, then the Water sheet as its worked example.
Findings: XCUT-14, XCUT-15, XCUT-21, FRND-19, HOME-02.

Artboards to produce:
1. The canonical Fernlet sheet template (XCUT-14, XCUT-15): one standard for title placement,
   close/cancel affordance, detent behavior, and primary-action position that every sheet will
   adopt. Show it annotated as a spec, not tied to one feature.
2. The destructive-action token (XCUT-21, FRND-19): one visual standard for destructive
   buttons/rows vs neutral chips — show the same control in destructive, neutral, and
   disabled states side by side.
3. Water sheet redesigned in that template (HOME-02): replace the left-aligned
   Remove / "Add a bottle" chip pair with a centered − 6 + stepper directly under the bottle
   row, 44pt targets, above the fold at medium detent; Done stays bottom-right.
4. Same Water sheet at accessibility text size (AX3) proving the stepper stays visible.

---

## BATCH 3 — Home root + quick log

SCOPE — Home tab root and its quick-log grid. Findings: HOME-10, HOME-22, HOME-13, FLOW-18,
HOME-09, HOME-28, HOME-30.

Artboards to produce:
1. Home root, cold open (FLOW-18, HOME-09, HOME-28): tighten vertical rhythm (shorter polaroid
   strip, less Today-card padding, tile height 66→56) so all six quick-log tiles clear the
   floating tab bar; unify the tile label convention (today's labels mix "3 meal", "6x",
   "Done", "Logged" — pick one noun+state pattern); one header treatment for all cards.
2. The Move quick-log tile target (HOME-10): main artboard = the tile opens the same Log
   workout sheet as the Move tab (kind chips at top); variant = keep Quick exercise but add a
   first row of quick kinds (Walk · Run · Ride · Stretch · Gym) above the exercise search.
3. Companion area with a visible "Customize" entry (HOME-22): small pencil chip beneath the
   companion + a Wardrobe row with coin pill in the Customize sheet header; long-press stays
   as a shortcut.
4. Navigation rule for Home's read-only cards (HOME-13): show Milestones presented as a .large
   sheet with Done, matching Trends/First aid — one consistent rule.

---

## BATCH 4 — Food logging + recipes

SCOPE — Food tab: meal sheet, post-log feedback, recipe surfaces. Findings: FOOD-08, FOOD-14,
FOOD-24, FLOW-15, FOOD-15, FOOD-05, FOOD-07, FOOD-19, FOOD-22, FOOD-35.

Artboards to produce:
1. Log meal sheet at medium detent (FOOD-08, FOOD-14, FOOD-24): meal-type chips must sit above
   the fold with a stable order and clear selected state; add a visible path to enter macros
   by hand.
2. Post-save feedback (FLOW-15, FOOD-15, FOOD-05): an actionable "Logged" toast with Undo and
   Adjust; a meal row whose whole body is tappable, with "Looks off?" as a proper affordance,
   opening an Adjust view that can add/remove/replace matched items.
3. Recent list (FOOD-07): deduplicated, with meal type + time shown, not names only.
4. Recipe book and detail (FOOD-19, FOOD-22): align book rows with Food-root row styling, add
   close affordance and section labels; give the detail a Steps section (the current detail
   shows macros/ingredients/notes but never steps).
5. Meal planner day card (FOOD-35): each planned recipe gets a one-tap "Log" pill, plus a small
   "Planned today" card on the Food root.

---

## BATCH 5 — Settings information architecture

SCOPE — Settings restructure. This is mostly IA: prefer simple hub/flow mocks over pixel polish.
Findings: SETT-14, SETT-15, SETT-27, SETT-29, SETT-08, SETT-11, SETT-23.

Artboards to produce:
1. New Settings hub (SETT-14, SETT-29): split the current "Goal & nutrition" pile (12 sections)
   into intent-matched rows — Goal & nutrition / Reminders / AI & data sources / Personal care
   tasks; move the six nearby-friends toggles out of the flat Privacy list into one
   "Nearby friends" row with a sub-page, replacing the 90-word footer with one plain sentence.
2. Sick mode relocated (SETT-15): "I'm unwell today" surfaced on the Home Today card or
   companion menu (it is a per-day flag, not a preference); Settings keeps only an explanation.
3. One Health surface (SETT-27): Settings › Health becomes the single surface — master switch,
   then one card per capability with a plain-language name (rename "Body context",
   "Activity context", "Intimate logging") and its request/revoke action; Privacy & Data
   reduces to the master switch + a "Health access →" link.
4. Delete-everything confirmation (SETT-08): restructure the 180-word alert into a scannable
   destructive confirmation (what's deleted where, typed/holded confirm, terracotta action).
5. "Lock photos to this device" (SETT-11): restyle so a protective one-way action no longer
   reads as a delete button — distinct from terracotta-destructive.
