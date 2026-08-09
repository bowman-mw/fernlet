> **CLOSED 2026-08-09 — BRIEFS 1–11 SHIPPED.** These are paste-ready mockup briefs, not an implementation plan; briefs 1–11 were mocked (outputs in [`design-refs/`](../design-refs/)) and their UI is live. Briefs 12–14 (adventure/energy loop, proud-dandelion growth, cumulative insights view) were never answered and have zero code — they are open *design* asks, now carried on [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md) §9 as a design backlog rather than kept alive here.

# Fernlet — Design briefs for the new report features (2026-07-05)

Paste-ready briefs for generating mockups (e.g. with Claude design). Each brief is self-contained.
Prepend the **Shared visual system** block to any single brief you feed a design tool so it stays
on-brand. Copy in every brief is the **real, shipped in-app text** — keep it, or edit it in place.

---

## Shared visual system (prepend to any brief)

Fernlet is a gentle, privacy-first "tamagotchi of yourself" wellness app for iOS. The whole feel is
cozy, unhurried, and non-clinical — soft rounded shapes, generous whitespace, matte earthy colors, no
hard edges, no red alerts, no numbers-as-competition, no progress bars that imply a grade. Think warm
paper and houseplants, not a fitness dashboard.

**Palette (light mode → dark mode):**
- Parchment (app background): `#F5EFDF` → `#1C1E1B`
- Cream (cards / boxes): `#FBF7EE` → `#282A26`
- Bark (primary text): `#3D2E1E` → `#F1EDE3`
- Slate (secondary text / captions): `#7B8B99` → `#9EA7AE`
- Moss (primary green accent): `#5E844D` → `#7FB069`
- Fern (lighter green): `#72A364` → `#8FC077`
- Goldenrod (warm accent): `#D2973B` → `#E0A954`
- Sun (coins / gold): `#EBB551` → `#F2C268`
- Soft taupe: `#B8A892` · Dusty rose: `#B67073` · Terracotta: `#B9543D`

**Cards:** cream fill, ~14pt corner radius, very soft shadow. **Type:** system rounded feel; headlines
in bark, body/captions in slate. Buttons: filled moss for primary, cream/outline for secondary.

**The companion ("Fern"):** a soft, plush, rounded blob creature — roughly egg/pear-shaped, flat
vector, matte green body (moss/fern) that subtly shifts hue with mood. It "breathes" (the body gently
swells and contracts on a slow loop). Face is minimal: two small dark dot eyes, a small
rounded-rectangle mouth whose curve/height changes with mood, and an optional soft blush cheek. It can
wear layered hats/clothing/held-items. It should read as calm, cute, and companionable — never
detailed or realistic. Existing mood states: **Thriving** (bright, upright, content), **Okay**
(neutral, settled), **Tired** (slightly drooped, softer color), **Resting** (eyes closed / dozing),
**Sick** (pale, muted).

---

# Part 1 — Polish briefs (feature is built; needs visual design)

## 1. First Aid surface

**What it is:** A calm "gentlest exactly when life is hardest" hub of small self-soothing tools,
opened as a sheet from a "First aid" pill on the Home screen (and offered when body-signals read
tense). It must feel like a quiet, safe room — the opposite of an emergency screen.

**Screen: First Aid menu (sheet).** Header/subtitle then a vertical list of tappable tool rows, then a
gentle support footer.
- Intro line: *"Small tools for a heavy moment. Pick whatever feels kind — or nothing at all."*
- Row 1 — *Slow breathing* — subtitle *"A quiet minute or three with a slowly swelling circle."*
- Row 2 — *5-4-3-2-1 grounding* — subtitle *"Arrive back in the room, one gentle sense at a time."*
- Row 3 — *Worry box* — subtitle *"Write a worry down and let the box hold it for a while."*
- Footer card (visually distinct, warmer/softer): heading *"If things feel heavy"*, body *"Some
  moments are bigger than any app. You deserve real support — the 988 line is free, kind, and there
  around the clock."* with call + text affordances for 988.

**Design notes:** low-stimulation, lots of air, muted greens/taupe, rounded tool rows with a small
leading icon each (breathing = wind/waves, grounding = concentric senses, worry = a little box/archive).
The 988 footer should feel caring and human, set apart but not alarming (no red). Mock both light and
dark. Deliverables: the menu, plus the three sub-screens below.

## 2. Breathing exercise

**What it is:** A full-screen animated breathing guide reached from First Aid.
**Core visual:** one big soft circle (or nested translucent circles) centered on parchment that
**slowly expands on the inhale and contracts on the exhale**, with a phase label above it.
**States/content:**
- Setup: preset picker — *Box* (caption *"In 4 · hold 4 · out 4 · hold 4"*) and *Relax* (caption *"In
  4 · hold 7 · out 8"*); a 1–3 minute selector; a "soft haptics" toggle; a filled moss *Begin* button.
  Idle label: *"Ready when you are."*
- Running: the swelling circle with the current phase word — *"Breathe in"* / *"Hold"* / *"Breathe
  out"* — and a subtle *End early* text button.
- Finished: label *"All done"*, a warm line *"That was a whole minute of care. Nicely done."* (adapts
  to the chosen length), and an *Once more* option.
**Design notes:** the circle is the star — show the inhale (large) and exhale (small) frames, plus the
color/opacity treatment. Calming green/moss gradients on parchment. No countdown numbers racing down;
time should feel soft. Provide the three states as frames.

## 3. 5-4-3-2-1 grounding

**What it is:** A gentle stepped grounding flow (senses countdown) reached from First Aid. One sense per
screen; the user taps anywhere to advance — no timers, no pressure.
**Steps (each = one full screen: a big count numeral, an icon, a prompt, a hint):**
- 5 — icon *eye* — *"Notice five things you can see"* — *"Anything at all — a corner of the ceiling,
  the light on your hand."*
- 4 — *hand* — *"Notice four things you can touch"* — *"The chair under you, the fabric of your
  sleeve, the air on your skin."*
- 3 — *ear* — *"Notice three things you can hear"* — *"Near or far. A hum, a bird, your own breath."*
- 2 — *nose* — *"Notice two things you can smell"* — *"Or two smells you like remembering."*
- 1 — *mouth* — *"Notice one thing you can taste"* — *"Even just the inside of your mouth counts."*
- Final screen: *"You're here."* / *"That's enough. Take the calm with you — there's nothing else to
  do."*
- Persistent hint at bottom: *"Tap anywhere when you're ready for the next one — take all the time you
  like."*
**Design notes:** show the transition feel (the big number, calm color per sense maybe). Very soft,
meditative, lots of breathing room. Provide 2–3 representative step frames + the final frame.

## 4. Worry Box (write + "let it go", and the kept-list)

**What it is:** Write a worry, symbolically set it down; it's stored **sealed on-device only**. Two
surfaces:

**(a) Write flow (from First Aid).**
- Prompt: *"What's circling around? Write it down — the box can hold it for a while so you don't have
  to."* A soft multiline text field. A privacy reassurance line: *"Stays sealed on this device only —
  worries never sync anywhere."* Primary button labeled **"Let it go"**.
- **The "let it go" moment (the key animation to design):** on tap, the written worry visibly leaves
  — e.g. the text lifts into a little box that closes, or drifts off as a leaf/paper boat/ember. Then a
  confirmation: heading *"Tucked away."* / body *"You can set it down for now. It's kept safe in the
  Worry Box on your Personal tab, whenever — if ever — you want to look again."*

**(b) Worry Box list (Personal/Private tab).** Subtitle *"Worries you've set down. They stay sealed on
this device only — releasing one lets it go for good."* A list of kept worries, each with a *Release
this worry* (delete) action. Empty state: *"The box is empty right now."* / *"That's a good thing. When
something feels heavy, First aid on the Home screen can tuck it in here."* An add affordance labeled
*"Something circling around?"*.
**Design notes:** the box/vessel metaphor and the release animation are what I most need — pick a
gentle motif (closing box, floating leaf, drifting balloon) and show its keyframes. Warm, private,
safe feeling.

## 5. Companion "frazzled / tense" state

**What it is:** A **presentation-only** overlay on the existing companion when opt-in body-signals read
"tense" (elevated stress). It is NOT a new mood — it's a light accent layered on whatever the base mood
is. Currently it just breathes slightly faster and shows a tiny squiggle; I'd like a nicer cue.
**Design notes:** give me a subtle "a little frazzled, be kind to me" look for the blob companion —
options to explore: a small sweat-drop, a faint squiggle/steam above the head, a slightly furrowed
brow on the simple face, a marginally quicker breath. It must stay **gentle and endearing, never
alarming** (no red, no distress). Show it composited over the Okay and Thriving base states so it reads
as an accent, not a replacement. Also fine to propose the matching soft "calm/settled" positive accent
for the calm reading.

## 6. Weather + day-night ambiance behind the companion

**What it is:** A subtle environment layer *behind* the Home companion (Home only). Two dimensions
compose: **time of day** (dawn / day / dusk / night — from the local clock, always on) and **weather**
(clear / clouds / rain / snow — only when the user has weather enabled).
**Design notes:** it must be *very* subtle so it never fights the parchment theme or the companion.
Show a small matrix of treatments: the four time-of-day sky tints (soft warm dawn, bright day, amber
dusk, deep calm night) and a couple of weather accents (a drifting cloud or two, gentle rain streaks,
slow snow, a soft sun glow). Everything low-opacity, painterly, cozy. I need to see how strong the tint
and the accent shapes should be. Provide a few representative combinations (e.g. clear morning, rainy
afternoon, clear night).

## 7. Milestones screen

**What it is:** A modest sheet of **lifetime cumulative** care counts — no streaks, no rates, no
percentages, no "days in a row". Just warm totals that only ever grow, plus the little coin gifts each
milestone gave.
**Content:** Intro: *"Every bit of care you've logged, added up over all time. These numbers only ever
grow — nothing here resets, expires, or asks you to keep a streak."* Then a list of rows, each with an
icon, a warm headline, and (for coin-earning kinds) a small "N milestone gifts" line:
- Journal (book icon): *"You've written 40 journal moments."*
- Meals (fork/knife): *"You've noted 40 meals."*
- Workouts (figure walking): *"You've moved your body 40 times."*
- Water (drop): *"You've had 40 well-watered days."*
- Breathing (wind): *"You've taken 40 slow-breathing breaks."*
- Worries let go (archive box): *"You've let 40 worries go."*
Plus a summary card: *"Milestone gifts have added N coins to your pouch."* with a coin glyph in `sun`
gold. Empty variants exist per row (e.g. *"Your journal moments will gather here."*).
**Design notes:** the open question is the treatment — soft badges/medallions vs. plain warm list
rows. It must feel like a gentle keepsake shelf, celebratory but never a scoreboard. Show both a
"has-data" and a "mostly-empty" state.

## 8. Pet cooldown ("settled") moment

**What it is:** After the companion is petted a few times, it enters a gentle ~10-minute "settled"
state (anti-compulsion). This is a positive, content beat — never a "you've hit a limit" message.
**Content:** on reaching the cap: *"Fern is soaking up all this love — feeling completely content."*
During the settled window (if the user taps again): *"Fern is feeling nice and settled — check back in
a little while."*
**Design notes:** design the companion's **content/settled pose** (droopy-happy eyes, soft smile,
maybe a small "z" or heart, a relaxed slump) and the little copy bubble/overlay that carries the line.
Warm and rewarding, so the cooldown feels like a gift, not a lockout.

## 9. Widget (Home + Lock Screen)

**What it is:** A WidgetKit widget showing the companion's state + today's water, with an interactive
"+1 water" button. **The full vector companion can't render in a widget**, so I need a **simplified
companion glyph set** — one small, legible mark per mood.
**Deliverables:**
- **Companion glyph set:** a tiny, recognizable emblem of Fern for each state — Thriving, Okay, Tired,
  Resting, Sick — that reads at small sizes and in monochrome (for the Lock Screen). Keep the blob
  silhouette + simple face.
- **Small widget (Home Screen):** companion glyph + a water progress element (a ring or row of dots,
  e.g. "3 of 6 bottles") + a "+1" tap target. Cream card, parchment-friendly.
- **Lock Screen accessories:** circular (companion glyph or water ring) and rectangular (glyph + a
  short line like "water: 3 of 6"). Must work in the tinted/monochrome Lock Screen rendering.
- **Placeholder state** (before first app launch): a gentle "open Fernlet" prompt.
**Design notes:** no sensitive data ever (no mood text, no scores) — just companion + water. Keep it
calm and glanceable.

## 10. Hearts / "good vibes"

**What it is:** Friends can send each other wordless "good vibes" in person. **Never any numbers or
counts anywhere.** Two moments to design:
- **Received bubble (Home):** a warm ambient card with a heart, heading *"Good vibes"*, body *"[Name]
  sent you some warmth — a friend is thinking of you."* (first name only). Dismissible.
- **Health-bar glow:** the companion's health/well-being bar (a soft segmented bar) gains a subtle
  **golden glow at the end** for 24h after receiving a heart, fading gradually. It must be
  presentation-only warmth — *not* a number, badge, or point. Show the bar with and without the glow.
- **Send affordance (friend detail / in-session):** a gentle *"Send good vibes"* button with a heart.
  Disabled states carry copy: *"You've already sent [Name] some warmth today."* and *"Hearts travel in
  person for now — they can be sent when you're together."*
**Design notes:** heart in `dustyRose` or `terracotta`, glow in `sun`. Cozy and fuzzy — the whole point
is "a feeling, never a metric".

## 11. Barcode scan — "not found" handoff

**What it is:** After scanning a product barcode Fernlet doesn't recognize, a gentle screen to name it
and optionally scan the nutrition label — creating a remembered food (macros only, **never calories**).
**Content:** a friendly "New to Fernlet" landing: a name field for the product, an option to scan its
nutrition label (camera), and macro (protein/carbs/fat) entry/preview. It should reassure that next
time the scan will be instant.
**Design notes:** keep the live-scanner viewfinder framing in mind too (a clean scanning frame + the
line *"Point the camera at the product's barcode."*, and the denied-camera fallback that offers a
photo instead). Macros shown as a small P/C/F trio — **no calorie number anywhere**. Warm, low-friction.

---

# Part 2 — Concept briefs (not built; want your direction before I implement)

These need a *concept*, not just styling — what they are and how they behave, then the look. Sketches or
notes are enough to unblock implementation.

> **Status reconciled 2026-08-09.** Briefs 1–11 were mocked and shipped — their design outputs are
> the HTML files in [`design-refs/`](../design-refs/) and the corresponding UI is live (first aid,
> breathing, grounding, worry box, companion states, weather/day-night ambiance, milestones, pet
> cooldown, widget, hearts, barcode handoff). **Briefs 12–14 below were never answered and have zero
> code** — a repo-wide search finds no adventure/energy-loop, dandelion/growth-stage, or cumulative
> insights implementation. They are still open *design* asks (each says "what I need from you"), not
> pending implementation work, and are carried on
> [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md) as a design backlog.

## 12. Adventure / rest system (Finch-style energy loop)

**Idea:** When the day's self-care fills an "energy" measure, the companion goes off on a gentle
multi-hour "adventure" and returns with a little story/postcard; otherwise it rests. Non-punishing —
missing a day just means a quieter day, never a penalty.
**What I need from you:** what triggers an adventure (which signals, what threshold — mapped onto the
existing rolling wellness score, not a streak); the **away-state** art (does Fern leave the screen? a
"out exploring" placeholder?); and the **return** format (a postcard? a short illustrated vignette? a
souvenir it brings back?). Plus the rest-state look for quiet days.

## 13. Proud-Dandelion cumulative growth visual

**Idea (from Quabble):** a living thing that grows a little with each act of self-affirmation /
journaling — a cumulative, non-streak growth metaphor that sits near the companion.
**What I need:** what grows (a plant/dandelion beside Fern? Fern itself gaining a small feature?), the
**stages** (how many, what triggers a stage), and where it lives on Home. It should feel like slow,
forgiving growth — never wilts, never resets.

## 14. Cumulative history / insights view

**Idea:** A "patterns, not grades" view of your care over months — the report is explicit that this
must show gentle patterns and never completion rates, streaks, or scores. You already have per-feature
month calendars (journal/period/intimacy) that could unify into one component.
**What I need:** the visual language for "patterns over time" — a soft multi-month heatmap? gentle
trend ribbons? qualitative callouts ("you tend to sleep better on days you move")? Decide what's shown
and how it stays non-judgmental.

## 15. Six-pillar wellness radar (qualitative)

**Idea (from Quabble):** an at-a-glance sense of balance across a few wellness areas (e.g. food,
movement, sleep, mind, hygiene, connection) — but **qualitative, never a ranked score to beat**.
**What I need:** the shape (a soft radar/petal bloom? a ring of gentle indicators?) and how it conveys
"fuller / quieter" in each area without numbers or grades. Which pillars, and how many.

## 16. Guided multi-day journeys

**Idea (from Finch):** themed, resumable multi-day self-care tracks ("Creating Calm", "Building
Focus") that never break if you skip a day (non-linear, resumable).
**What I need:** the **card design** for a journey (on Home and in a browser), the per-step layout, and
how "resumable, skip-friendly" is expressed visually (no broken-chain / streak framing). Plus 1–2
example journey themes to seed content.
