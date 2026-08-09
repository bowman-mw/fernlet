> **CLOSED 2026-08-09 — SHIPPED.** The parchment redesign was delivered through the three UX-Batch-Continuation rounds (2026-07-17, -17b, -18) and the TestFlight b19 feedback waves; the review that gated it was [UI-UX-Review-Prompt-2026-07-09.md](UI-UX-Review-Prompt-2026-07-09.md). Of the four questions left open at authoring time, two turned out to be answered by the shipped code (Dynamic Type is uncapped; the shop entry is hidden rather than ghosted) — recorded inline in "Still open". The two that remain (global IA for the Private tab, and the Settings debug surfaces plus the still-reachable placeholder `PersonalScreenView`) moved to [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md) §9.

# Fernlet UI/UX Redesign Brief — 2026-07-08

This brief organizes the UI/UX changes you asked for, plus additional issues found in a
code-grounded review of every surface involved. It is written to feed **two** phases:

1. **Design phase** — mock the flagged screens/states in Claude design. Each surface has a
   "**Mock in Claude design**" shot list.
2. **Implementation phase** — every claim is anchored to `file:line` so the edits are locatable.

**How each surface is structured:** _Current state_ → _Your ask + analysis_ → _Recommended direction_
→ _Also found_ → _Mock in Claude design_.

**Legend:** 🔴 high · 🟡 medium · ⚪ low. Effort: **S** (hours) · **M** (a day) · **L** (multi-day / model work).

### Locked decisions (from 2026-07-08 review feedback)
- **Camera viewfinder** — confirmed: the viewfinder **grows out of the Dynamic Island, driven by the wind** — as the thumbwheel rotates, a black rounded housing (green "on" LED) expands from the island into the live-preview square, fully popped on the **final wind**. **Keep** the film/wind mechanic; **no change to the camera body** (near-black). Approximate island anchor accepted. Reference: your "PicoCam" images. → §5
- **Mesh** — the **clothing shop and photo sessions share ONE mesh** (merge `fernlet-clothes` into `fernlet-friend`). Simplifies shop gating + gives one connection banner. *Proximity-subsystem work, not UI-only.* → §4
- **Home ambience** — **full-bleed wash** (no contained card/clip); **keep BOTH** WeatherKit + time-of-day. → §1
- **Home chips** — **fully chip-free**: remove the signal chips; companion + thought bubble carry mood; detail lives in Trends. → §1
- **Customization vs Wardrobe** — the **sheet is a SELECTOR** (shows the selected item per slot, pick/equip, "custom items" → closet); the **Wardrobe handles ALL customization** (recolor built-ins + design custom items). Recolor **moves into** the wardrobe. Coins removed from the sheet. → §7
- **Milestones** — move to the **Home page as a compact card** (visible even when mostly-empty). → §7 / A8

---

## Part 0 — Read this first: the parchment design system (foundation)

Almost every "it looks like default Apple, not Fernlet" problem traces to a **few systemic gaps**,
not per-screen sloppiness. The theme itself is strong and widely used; drift is concentrated in the
newer clothing/shop/wardrobe cluster and in one global omission (nav-bar titles). **Fixing the
foundation first makes most of the surface work a substitution, not a redesign.**

### Canonical tokens (reuse these; don't invent)
Defined in `FernletUIComponents.swift:12-53`, backed by `FernletTheme.swift`:

- **Surface/text roles (theme-adaptive, user-customizable):** `Color.parchment` (page bg, light `#F5EFDF` / dark `#1C1E1B`), `Color.cream` (card bg, `#FBF7EE` / `#282A26`), `Color.bark` (primary text), `Color.slate` (**secondary text — the parchment replacement for system `.secondary`**).
- **Accent palette (fixed light/dark pairs):** `moss` (primary action / global tint), `fern`, `goldenrod`, `sun` (coins / heart-glow), `terracotta` (**error/destructive**), `dustyRose` (intimacy cues), `softTaupe`.
- **No dedicated error/success token yet** — `terracotta`=error, `moss`=success are used ad hoc. Formalize semantic names before mocking error states.

### Canonical components (the kit)
`ScreenHeader` + `HeaderActionButton` (serif title + 58pt cream action button), `FernletCard`
(cream, radius 18), `FernletScrollSection`, `SectionLabel` (uppercased caption), `ChipButtonStyle`,
**`HubSectionPicker`** (parchment-native segmented control — the intended replacement for
`.pickerStyle(.segmented)`), `SheetField`/`sheetTextInput()` (cream field), **`SheetSaveBar`** (moss
capsule CTA — the intended replacement for `.borderedProminent`), `EmptyState`, `PolaroidTile`,
`fernletSheetStyle()` (the 3-line recipe — `scrollContentBackground(.hidden)` + parchment + moss tint
— that de-systems any List/Form/sheet).

### The four systemic fixes (do these before/with the surface work)

| # | Fix | Why it's foundational | Effort |
|---|-----|----------------------|--------|
| F1 🔴 | **Re-apply `.tint(Color.moss)` inside the customization sheet** at `HomeView.swift:848`. The root tint (`ContentView.swift:269`) does **not** cross the `.sheet` boundary (`HomeView.swift:62`), so every system control inside Wardrobe + Creation Studio renders **system-blue**. | This one line is the single highest-leverage fix — it directly answers "the color is the default Apple color" for the whole wardrobe cluster (segmented picker, TextField cursor, Stepper, chevrons, alert buttons). | S |
| F2 🔴 | **Nav-bar title theming.** There is **no** `UINavigationBar.appearance()` anywhere (grep = 0 hits). ~16 pushed screens use `.navigationTitle` and get system SF titles. Main tabs dodge this via `.navigationTitle("")` + in-content `ScreenHeader`. | Makes secondary screens (Wardrobe, Creation Studio, Friend shop, Milestones, First Aid tools, Settings) read as "the same app." Pick one: (a) global themed `UINavigationBarAppearance`, or (b) the `ScreenHeader`-in-content pattern the tabs already use. | M |
| F3 🟡 | **`.secondary` → `Color.slate`** (14 confirmed sites: `FriendShopView` 74/78/94/115/134, `WardrobeView` 33/52/104, `CreationStudioView` 160/221/236, `HomeView` 924/954/986; plus tab bar `ContentView.swift:348`). Define one radius scale (card 16–18 / field 12 / chip 24) — today radii are a free-for-all (12 used 58×, plus 10/8/14/16/7/4/3/20/28). | Kills hue drift between screens and "subtle sloppiness." Mechanical sweep. | M |
| F4 🟡 | **Dynamic Type scale.** The app opts out of type scaling for its most prominent text — every title is fixed `.system(size: 28/32/36, design:.serif)` (`ScreenHeader` `FernletUIComponents.swift:180,193` + ~20 sheet titles) and labels go as small as 10–11pt (`DisposableCameraView.swift:598`, `PolaroidTile` 260). No `.dynamicTypeSize` limits anywhere. | Accessibility gap across the whole app. Introduce named serif roles built on `.font(.custom(..., relativeTo:))` so the serif look is kept **and** text scales. | M |

**Design-phase deliverable for Part 0:** a **token + component sheet** (the 4 semantic roles ×
light/dark/custom-bg, the 8 accents with hex + usage, a formalized error/success name), a **type
ramp** (displayTitle/screenTitle/sheetTitle/sectionLabel/body/caption) shown at Default / XL / AX3,
and a **themed-control set** replacing Apple defaults (`HubSectionPicker` 2-way & 4-way, `SheetSaveBar`
default/disabled/pressed, a secondary/buy capsule, a themed Toggle row + section header, a themed
alert). Everything downstream references this.

---

## Part 1 — The surfaces you named

### 1. Home / companion — background + "too many tags" 🔴
**Files:** `HomeView.swift` (`companionSection` 199-249), `CompanionAmbienceLayer.swift`, `CompanionVectorAssets.swift`.

**Current.** The companion (`CompanionView`, size 132) has **no card/disc of its own** — the only thing
behind it is `CompanionAmbienceLayer` (a time-of-day tint + always-on celestial Canvas + optional
weather Canvas), clipped to a rounded rect (radius 26). Below it, **three separate chip systems stack**:
(1) state chip + First Aid pill (`233-242`), (2) `signalsCard` horizontal-scroll chips — up to 5:
Resting/Cycle/Mood/Energy/Readiness (`356-383`, `407-419`), (3) `stressLineView` full-width bubble shown
**every** opted-in day (`278-306`). A fully opted-in user sees **up to 8 elements across 3 visual
languages**. Separately the `ThoughtBubble` floats **above** the companion (`167-170`), splitting its
"voice" from its "stats."

**Your ask + analysis.**
- *Background feels off* — confirmed, with concrete causes: (a) tint radials use **fixed pixel radii**
  (`endRadius 240-260`) and celestial bodies use **fractional positions** inside a wide, short strip →
  light pools in a corner with dead tinted space; (b) with no container the rounded-rect clip reads as a
  **stray tinted card** on the parchment; (c) `AmbiencePalette` is **theme-blind** (no light/dark
  variants, `405-408`) → the night deep-blue wash and near-white sun **glow** against parchment/dark;
  (d) **2–3 concurrent animation loops** (celestial + weather + the companion itself) behind a small hero
  feel busy — counter to the app's calm ethos.
- *Tags are a lot* — confirmed: 8 elements, 3 inconsistent chip languages, **redundant** (state chip +
  Mood chip + stress "calm" line all say the same thing), overflow hidden with no indicator
  (`showsIndicators:false`, `364`), and First Aid (an **action**) is fused into the status row.

**Recommended direction (updated per your decisions).**
- *Background:* **full-bleed wash** — drop the rounded-rect clip and feather the edges so the ambience
  dissolves into the parchment page (no contained card). **Keep BOTH** the time-of-day tint and the
  WeatherKit accents. Still required: convert the fixed radii/fractional positions to **size-relative
  geometry** (GeometryReader) so it composes in the wide strip, and give `AmbiencePalette` **light/dark
  variants** so night/dark stops clashing. Keep the animation gentle (a wash tolerates the loops better
  than a bordered card did — tune intensity down so the companion stays the one focal motion).
- *Tags:* **remove the signal chips from Home.** Let the companion's pose/expression + the `ThoughtBubble`
  carry mood, and move Mood/Energy/Readiness/Cycle/stress detail into the **Trends** sheet. First Aid is
  an **action**, not a status — give it its own affordance (alongside quick-log), not a chip. *Sub-decision:*
  keep a single companion-state indicator, or go fully chip-free (recommend fully chip-free).

**Also found:** ⚪ companion has no ground shadow/base (floats); 🟡 thought-bubble/stats split across the blob.

**Mock in Claude design:**
- Companion with the **full-bleed wash** (feathered, no card edge) in **light + dark**, at all four phases (dawn/day/dusk/night), rendered at the real Home aspect ratio + the 3 weather accents.
- Home **without the chip row** — companion + thought bubble carrying mood; show where **First Aid** now lives as a standalone action.
- The **Trends** sheet as the new home for Mood/Energy/Readiness/Cycle/stress detail.
- Optional: a single retained companion-state indicator vs fully chip-free (so you can compare).

---

### 2. Food logging — unify Photo + Scan into one button 🔴
**Files:** `FoodView.swift` (`mealContent` capture row `1185-1192`), `NutritionLabelCameraSheet.swift`, `BarcodeScanView.swift`, plus on-device engines `BarcodeScanner.swift`, `NutritionLabelScanner.swift`, `MealPhotoRecognizer.swift`.

**Current.** There are **five** scattered capture entry points and "Scan" is **overloaded**: on the meal
sheet "Scan" (`1190`) is **barcode-only**; in recipe creation "Scan label" (`2230`) is **OCR**. Label OCR
is **unreachable from the meal sheet at all**. "Photo" (`1187`) only **stores** the image — recognition
is a separate "Identify from photo" tap (`1170`) that **vanishes when AI is off** (`1169`), silently
degrading to a decorative attachment.

**Your ask + analysis.** Correct, and understated. All three detectors are **already on-device** and can
run over any single still image — so auto-routing is feasible with existing primitives:
`VisionBarcodeDetector.payload(in:)`, `NutritionLabelScanner.recognizeText(in:)` (label markers already in
`customWords` `209-218`), `MealPhotoRecognizer` (`39`).

**Recommended direction.** Collapse "Photo" + "Scan" into **one primary "Capture" button**. Keep a
**barcode-first live viewfinder** as the default (fast, delightful, already themed) with a persistent
**"not a barcode? capture anyway"** shutter that grabs a still. **Auto-detect order:** barcode →
label-text markers → meal photo (mirrors real-world confidence). On low confidence / tie, show a
**disambiguation card** ("Read the label" / "Look up the barcode" / "It's a meal photo" + "Type it
instead") instead of silently picking. When **AI is off**, the card says the meal-photo branch is
unavailable and steers to label/barcode/manual. Leave "Recent"/"Import" as clearly-secondary (they're
text/URL, not camera). Reconcile vocabulary so "Scan label"/"Scan barcode" feed the **same** component.

**Also found:** 🟡 4 capture buttons share identical low-hierarchy chrome (no primary); 🟡 two unrelated
scan-chrome languages (polished barcode viewfinder vs plain OCR form); 🟡 failure states are dead-ends /
bare error text; 🟡 label-sheet Camera button silently disabled with no styling; ⚪ `Color.red` error
(off-palette → `terracotta`); ⚪ meal photo lacks a library path that label/barcode have.

**Mock in Claude design:**
- Redesigned capture row: one moss **primary "Capture"** + secondary Recent/Import.
- Unified live camera (barcode-first) with the "capture anyway" shutter.
- Post-capture "analyzing…" → three success landings (barcode resolved / label parsed / meal identified).
- Ambiguity chooser card; **AI-off** variant; camera-unavailable / permission-denied; shared calm failure/retry (warm palette, no red).

---

### 3. Move page — the three boxes above the calendar 🟡
**Files:** `MoveView.swift` (header `28-36`, three boxes `38-79`, calendar `81-89`).

**Current.** Three full-width stacked boxes of **mixed kinds but near-identical styling**: #1 **Goal
summary** (navigational, `810-845`), #2 **Readiness** (passive, non-tappable, moss-tinted, `42-55`),
#3 **Location/equipment** (navigational config, `57-79`). Header pills + 3 bands push the calendar and
"Today's movement" near/below the fold.

**Your ask + analysis.** "Too much" is well-founded: goal (#1) and location (#3) are **visually
interchangeable** cream chips distinguished only by a tiny trailing glyph; readiness (#2) **looks
tappable but is inert** and is **redundant** — the same signal shows on Home (`HomeView.swift:415-417`)
and in the Suggest sheet (`585-589`).

**Recommended direction (Option A).** Collapse goal + location into **one slim horizontal context
strip** (goal segment | divider | location segment, both tappable to their existing sheets) directly
under the header; **drop the standalone readiness band** (or demote it to a small pill in the calendar
header). Calendar rises above the fold. Fallbacks: (C) keep only goal, move location behind the header
cluster; (B) attach goal+location as a footer inside the calendar card.

**Also found:** ⚪ readiness shown raw ("ready for hard") vs compacted elsewhere; ⚪ location has no
first-run/empty state ("<name> · 0 items" reads broken).

**Mock in Claude design:** current 3-band vs proposed collapsed strip (side by side); the strip with
truncation at 375pt; goal states (set / "tap to plan"); location states (populated / "set up your
space"); readiness options (removed / calendar-header pill / inline caption); above-the-fold result; dark/custom-bg variant.

---

### 4. Friends page — gate the shop button on mesh connection 🟡
**Files:** `ConnectView.swift` (shop link `134-141`), `FriendShopView.swift`, `ProximityClothingShareManager.swift`, `MeshNetworkManager.swift`.

**Current.** The shop "bag" button is an **unconditional** `NavigationLink` (`135-141`) — always present,
no visibility guard. Tapping it when nobody's nearby lands on a **perpetual spinner** ("Looking for
friends' shops nearby…", `FriendShopView.swift:71-78`).

**Your ask + analysis.** Correct. **Important subtlety:** the shop runs on its **own** mesh
(`ProximityClothingShareManager`, service `fernlet-clothes`, `63`), **separate** from the photo mesh
(`MeshNetworkManager.isInSession`). So **do not** gate on `meshNetworkManager.isInSession` — that's the
wrong subsystem. The clothing manager has no `isInSession` bool; the truest signal is
**`!peerCatalogs.isEmpty`** (a catalog arrives only over a verified sealed channel) or
`nearbyShopPeers.contains { $0.fingerprint != nil }` (verified peer). Do **not** use `nearbyShopPeers`
alone (includes unverified discovery). Requires passing `store.clothingShareManager` into `FriendsView`.

**Recommended direction (updated: unify the meshes).** You've decided the **clothing shop and photo
session should share ONE mesh** (merge `fernlet-clothes` into the `fernlet-friend` session). Once unified,
gating is simple and correct: show the shop affordance when the **session is connected**
(`meshNetworkManager.isInSession`), and the same "you're together with <name>" banner governs **both** the
camera and the shop — which resolves the "two meanings of connected" problem below. For an in-person-only
feature, prefer a **ghosted/disabled** shop affordance ("Shops appear when you're together with a friend in
person") over hard-hiding — mock both. ⚠️ **Note:** merging the two meshes is **proximity-subsystem work**
(signed/sealed transport, service-type consolidation), not a UI-only change — scope it as its own task.
*(Until the merge lands, the interim gate is `!store.clothingShareManager.peerCatalogs.isEmpty`.)*

**Also found:** 🟡 `FriendShopView` empty state uses `.secondary` + `.borderedProminent` (off-theme); 🟡
no distinct disconnected/**sharing-disabled** state (spinner runs forever even when nothing is
searching); 🟡 the page's "nearby" banner reflects the **photo** mesh, so "connected" means two different
things; ⚪ two unlabeled round header icons (bag is ambiguous — consider a coin-count badge); ⚪ selling
(Wardrobe swipe "Sell") is disconnected from the shop surface; ⚪ header re-implements
`HeaderActionButton` by hand (`175-185`).

**Mock in Claude design:** header **with** shop (coin badge) vs **without** (hidden vs ghosted+caption);
`FriendShopView` connected / searching / **sharing-disabled** states, all parchment; a unified nearby
banner covering both meshes; a nav-capable themed header button; a bridge to the closet "Sell" flow.

---

### 5. Disposable camera — viewfinder animating from the Dynamic Island 🔴 **L**
**File:** `DisposableCameraView.swift` (repo root; `takePhoto()` `638-648`).

**Current.** Capture has **zero visual feedback** — `takePhoto()` fires one haptic and hands off bytes.
No flash, no freeze-frame, no thumbnail, nothing island-anchored. The layout reads no device geometry
(no `safeAreaInsets`, no per-model branch except `isLandscape`), and the top island/notch band is **empty
dead space**.

**Your ask + analysis.** This is **net-new**, not a tweak. **Honest hard constraint:** iOS exposes **no
public API for the Dynamic Island's rectangle** (Apple only surfaces it indirectly via ActivityKit Live
Activities, which you can't read the frame of or draw into). So a pixel-perfect "grows out of the island"
is **not officially attainable** — but a **close approximation anchored to the top-center safe area** reads
as "from the island" and degrades gracefully. What **is** available: `GeometryReader` +
`proxy.safeAreaInsets.top` gives the per-device top inset (already have a GeometryReader at `303`).

**Recommended direction (confirmed by your PicoCam reference).** The reference nails the target: a **black
rounded housing emerges from / hugs the Dynamic Island**, carries a small **green "on" LED**, and expands
into a **live-preview square**, with physical point-and-shoot controls below (left: flash/effect · center:
big shutter · right: camera-flip). **Keep the film/wind mechanic and the near-black body — the viewfinder emergence is DRIVEN
BY THE WIND:** as the thumbwheel rotates (`windProgress` 0→1), the black housing grows out of the island
and expands into the live-preview square, fully popped up on the **final/complete wind** (arm). Build it
as a top-anchored overlay treating the island as an **approximated anchor**, never a queried rect. **(A)
Anchor:** origin = horizontally-centered pill at ~`safeAreaInsets.top * 0.5`.
**(B) Device-class heuristic** for pill shape only (the part with no API): Island (~59pt top inset) →
~126×37pt pill r19; Notch (~44–50pt) → thin bar under notch or top-center point; None (~20pt / iPad) →
top-center edge. Keep numbers in one table with a safe default. **(C) Animation (wind-driven):** bind the housing's
grow-from-island to `windProgress` (matchedGeometryEffect between the island anchor pill and the
`viewfinderArea` rect) so rotating the wheel pulls the viewfinder out of the island, completing (fully
popped, green LED lit, armed) on the **final wind**. On shutter: white flash + freeze-frame shrinking
toward "Develop"; on **disarm** (after each shot) the viewfinder retracts toward the island → the next
wind grows it back (a clean **wind → shoot → retract** loop). This binds to the existing
`CameraCaptureController` arm/wind state machine, so `DisposableCameraControllerTests` should still pass
(add a `windProgress`-driven view + capture beat; don't change the gate). **Never** hardcode an
absolute-Y pill — derive from `safeAreaInsets.top` at runtime; the heuristic supplies **shape only, never
position**. Implement Island + top-edge fully now, letting Notch fall back to top-edge.

**Also found:** 🔴 capture feels broken (no confirmation) — the real root requirement; 🟡 disabled shutter
states are cryptic icon-only glyphs (needs captions); 🟡 permission-denied is a plain black box inside the
tiny preview with all chrome still live; ⚪ dead top band worsens top-empty/bottom-crowded imbalance; ⚪
wind gesture is a 66×48 target with 10pt/40%-opacity instructions (mandatory between shots → feels
broken if missed); ⚪ portrait/landscape layouts diverge with no shared spec.

**Mock in Claude design:** the **wind-driven island sequence** as keyframes across wind progress (at-rest,
island empty → mid-wind, housing half-grown from the island with green LED → final wind, fully-popped
live-preview square, armed → shutter flash/freeze → disarm, viewfinder retracts toward the island),
styled per the PicoCam reference with the three physical controls (flash/effect · shutter · flip); the
same sequence on **Island / Notch / no-island** devices; a labeled **geometry diagram** (three buckets,
which numbers are runtime vs heuristic); disabled/empty shutter states with captions; full-surface
permission-denied + first-run pre-prompt; **landscape** variant (island on the side edge → decide side vs
top-edge origin); the **redesigned wind control** (larger, legible) since it now drives the hero animation
+ a first-shot coach hint.

---

### 6. Wardrobe / Creation Studio — off-theme colors & fonts 🔴
**Files:** `CreationStudioView.swift`, `WardrobeView.swift`, host sheet `HomeView.swift:848`.

**Current.** Both views are *partially* themed but the chrome and every un-styled system control fall to
Apple defaults. **Root cause = F1** (the sheet never re-applies `.tint(Color.moss)`), so the slot
segmented Picker (`CreationStudioView.swift:106-112`), name TextField cursor (`213`), price Stepper
(`227`), chevrons, and alert buttons all go **system-blue**. **`WardrobeView`'s bare `List`** (`19`) has
no parchment background → renders as a **stock grouped Settings screen**. Neither view uses **serif**
anywhere or `ScreenHeader` — titles are plain SF `.navigationTitle`.

**Your ask + analysis.** Both halves confirmed and located. Color → F1 + F3 + list chrome. Fonts → adopt
`ScreenHeader` + `design:.serif` for hierarchy-bearing labels (the parchment identity **is** serif).

**Recommended direction (by substitution — no new design needed):** (1) F1 tint at `HomeView.swift:848`;
(2) `WardrobeView` onto parchment via `fernletSheetStyle()` / rebuild with `FernletScrollSection` +
`FernletCard` rows; (3) `ScreenHeader` + serif labels; (4) name field → `sheetTextInput()` not
`.roundedBorder`; (5) `terracotta` for destructive (optional).

**Also found:** ⚪ palette swatch row — light swatches (parchment/cream/white) **disappear** on the cream
card, eraser blends in, selection is only a ring; ⚪ canvas has no "drag to paint" hint and no per-cell
undo (only destructive Clear); ⚪ Save is a bare toolbar text button vs the app's `SheetSaveBar`.

**Mock in Claude design:** CreationStudio full screen light + dark (serif title, moss segmented picker,
cream canvas card, palette, details card); palette states (default/selected/eraser + fix for invisible
light swatches); canvas empty/mid/filled + transparency; themed name field; shop section (toggle off/on +
both alerts); prominent Save; **Wardrobe** full screen light + dark on parchment with **cream card rows**;
row variants (self-designed unlisted / listed "In your shop · N coins" / "designed by <friend>" /
equipped); themed swipe actions; empty state; the "Design a new item" + shop-status rows as parchment cards.

---

### 7. Character customization sheet — "very busy" 🔴
**Files:** `HomeView.swift` (`CompanionCustomizationSheet` `834-1134`), `WardrobeView.swift`, `MilestonesView.swift`, `FriendShopView.swift`, `CompanionVectorAssets.swift`, `CompanionModels.swift`, `CustomItemModels.swift`, `FernletStore.swift`.

**Current.** Opens (long-press companion) at `.medium` detent onto a **Style/Customization segmented
control**, then a scroll that **always leads with three full-width cream cards** — coins (`908-936`),
milestones (`938-970`), wardrobe (`972-1001`) — **before** any editing controls. "Style" = Blob +
Accessory; "Customization" = Clothing + Side item. Built-in clothing is **scarf/sleepCap only**; custom
items are a **disjoint** `ItemSlot` system (hat/face/body/held) reached only via the pushed closet.

**Your ask + analysis — all five check out, and two are easier than expected:**
- (a) **Coins** — off-topic here (nothing on this sheet spends them; spending is `FriendShopView`, which
  has its own wallet badge). Demote to a small pill or remove. ✔
- (b) **Milestones** — genuinely unrelated (lifetime counts + keepsake shelf). **⚠️ CRITICAL: this sheet
  is Milestones' ONLY entry point** (`942`) — removing it **orphans the feature**. It must be **rehomed**
  (Profile/Settings or a Home-feed card) as a **required companion change**, not deleted.
- (c) **Fold custom into the clothing selector** — real IA work: `CompanionClothing` vs `ItemSlot` are
  **disjoint enums**. Natural seam: the Clothing card gains a trailing "Custom items…" entry; the four
  custom slots (hat/face/body/held, no built-in equivalent) get a dedicated "Custom items" section.
- (d) **Custom items opens the closet** — routing already exists (`wardrobeLink → WardrobeView`); just
  move the entry into the selector. ✔ easy.
- (e) **Recolor built-ins in the closet** — **✅ ALREADY SUPPORTED by the data model.**
  `CompanionAppearance` stores per-slot custom hex (`CompanionModels.swift:66-75`), the renderer resolves
  it (`CompanionVectorAssets.swift:693-716`), and the sheet already exposes presets + a freeform
  ColorPicker per item. **This is a placement question, not new modeling.** ("In the closet" specifically
  is new UI placement — the closet currently shows custom items only.)

**Recommended direction (updated per your decisions — clean split of roles):**
- **Customization sheet = a SELECTOR.** For each slot (Body, Accessory, Clothing, Side item, Custom
  items) it **shows the currently selected item** and lets you pick/equip among options. Drop the
  Style/Customization segmented split. Clothing is the **unified selector**: None / Scarf / Sleep cap +
  a **"Custom items"** entry that opens the **Wardrobe**. It stays lightweight — **no dense per-card color
  controls**.
- **Wardrobe (closet) = handles ALL customization.** This is where **recoloring** happens (built-ins
  *and* custom items — the model already supports built-in recolor, so this is purely **moving** the
  control here) and where custom items are **designed/edited** (Creation Studio). The recolor UI **moves
  out of the customization cards and into the wardrobe**.
- **Coins:** removed from this sheet (spending lives in the shop).
- **Milestones:** move to the **Home page as a compact card** (visible even when mostly-empty, so it's discoverable early).
- Net: the sheet becomes a calm "what's my companion wearing + pick something" selector; the wardrobe
  becomes the workshop for color + design.

**Also found:** 🟡 each editing card stacks **three** color controls (option grid + preset grid + freeform
picker) — dense and the preset grid vs freeform picker duplicate each other; 🟡 the four custom slots are
**invisible** from the main sheet (discovery requires entering the closet); ⚪ dormant `CompanionPalette`
enum (whole-companion theme) exists in the model but is never surfaced — decide surface vs vestigial; ⚪
freeform `ColorPicker` is the one system-chrome element in an otherwise themed sheet.

**Mock in Claude design:** the customization sheet as a **selector** — a row/section per slot showing the
**currently selected item** with a tap-to-change picker (Body, Accessory, Clothing, Side item, Custom
items); the **unified Clothing selector** (None / Scarf / Sleep cap + "Custom items" → Wardrobe); the
**Wardrobe** gaining the **recolor control** (built-in equipped items + custom items — swatch row + "+"
freeform) and the design/edit entry; coins removed; **Milestones on the Home page**; empty/first-run
selector; the `.medium` detent showing the selector cleanly (no coins/milestones cards).

---

## Part 2 — Additional issues we found (you didn't name these)

| # | Issue | Sev | Where |
|---|-------|-----|-------|
| A1 | **Nested paged TabViews collide.** The 5-tab app is a paged `TabView`; the **Private tab is a *second* paged TabView** — a horizontal swipe means "change tab" on 4 tabs but "change sub-section" on the 5th, and edge swipes bleed between levels. Also the **unselected tab uses `UIColor.secondaryLabel`** not `Color.slate`. | 🔴 | `ContentView.swift:282-306,348`; `PrivateHubView.swift:33-51` |
| A2 | **Settings sprawl** — 1981 lines, 7 sections, ~12 sub-tabs, and it **ships Debug + "Tier 2 memory (test-only)" + "Derived signals (test-only)"** and a **permanently-disabled "Move / Apple Fitness (M2)"** placeholder to end users. | 🔴 | `SettingsSheet.swift:91-108,479-512,1137-1226` |
| A3 | **Mislabeled affordances** in legacy `PersonalScreenView`: the period **"+" opens Settings**; the friends compose button **opens the Journal**. Affordance ≠ result on privacy-sensitive screens. (Only matters if this legacy path is still reachable — see open questions.) | 🟡 | `ContentView.swift:770-781,886-899` |
| A4 | **Period tracker card sprawl** — up to **7 stacked equal-weight cards**; prediction stats are **split** across a top `PredictionsCard` and a bottom `TrendsCard` with the calendar between them. Flat hierarchy, no focal point. | 🟡 | `PeriodTrackerView.swift:24-45,239-304` |
| A5 | **PeriodDayDetail Edit/Delete** are default SwiftUI buttons → **system-blue Edit / system-red Delete** inside a fully parchment screen. | 🟡 | `PeriodDayDetailView.swift:64-70` |
| A6 | **Journal `moments://` dead link** — "Open Moments" deep-links a third-party app most users lack; tap silently no-ops, and the copy markets an external app inside Fernlet's own composer. Plus a jarring plain-italic **"This entry is sealed."** fallback that deserves an intentional locked-entry treatment. | 🟡 | `JournalView.swift:253-257,319-361,711-724` |
| A7 | **Onboarding is 8 forward-only steps with no Back** — a mis-tapped goal/color/diet can't be corrected until after finishing. | 🟡 | `OnboardingCoordinator.swift:53-64,88-94` |
| A8 | **Milestones keepsake shelf is invisible early** — its only entry point is hidden in the mostly-empty state. **Now a compact card on Home** — surface it even when mostly-empty. | ⚪ | `MilestonesView.swift:61-111` |
| A9 | **Worry Box has two different composers + release animations** for the same action (First Aid vs Private hub). | ⚪ | `WorryBoxView.swift:51-171,361-385` |
| A10 | **Settings opens with an empty `Section` used only as an intro banner** — reads as an orphaned header. | ⚪ | `SettingsSheet.swift:42-51` |

### Accessibility & consistency (cross-cutting — folds into the Part 0 passes)
| # | Issue | Sev | Where |
|---|-------|-----|-------|
| X1 | **Meal-delete is unlabeled + ~17pt** (VoiceOver says "xmark"; destructive, no confirm). | 🔴 | `FoodView.swift:1704` |
| X2 | **Titles don't scale** (fixed `.system(size:)` app-wide) — see **F4**. | 🔴 | `FernletUIComponents.swift:180` + ~20 sites |
| X3 | **`WardrobeView` default List** — biggest single theme break (also #6). | 🔴 | `WardrobeView.swift:19` |
| X4 | **Low-contrast white@40–50% labels** on the dark camera chrome (Ready/Develop/Slide/wind). | 🟡 | `DisposableCameraView.swift:599` |
| X5 | **Unlabeled sub-44pt week-nav chevrons** (32pt). | 🟡 | `MoveView.swift:1190-1209` |
| X6 | **System button styles** (`.bordered`/`.borderedProminent`) instead of `SheetSaveBar`/chip. | ⚪ | `FoodView.swift:53`; `FriendShopView.swift:128` |
| X7 | **Raw `Color.yellow`/`Color.red`** film counter instead of `goldenrod`/`terracotta`. | ⚪ | `DisposableCameraView.swift:445` |
| X8 | **10–11pt fixed labels** that can't scale (camera HUD, PolaroidTile). | 🟡 | `DisposableCameraView.swift:598`; `FernletUIComponents.swift:260` |

---

## Part 3 — Cross-cutting themes (the synthesis)

1. **Theme drift is concentrated, not pervasive** — it clusters in the **clothing/shop/wardrobe** feature
   (built with default Apple controls) and one **global omission** (no nav-bar title theming). Correct by
   **substitution** with existing kit components; almost nothing new needs inventing. **F1 (one line) is
   the highest-leverage fix.**
2. **Coins are surfaced in too many places** — demote to where they're spent (shop).
3. **Flat hierarchy / redundant summaries everywhere** — Home (8 chips, 3 systems), Move (readiness ×3),
   Period (7 cards, split prediction/trends). The recurring fix: **pick one primary per surface, push
   detail into a detail/trends sheet.**
4. **Two disjoint clothing systems** (built-in enums vs `ItemSlot`) surfaced in two places — merging is
   the one genuine **data-model seam**; recoloring built-ins is **already supported**.
5. **Overloaded / mislabeled / ungated affordances** — "Scan" (2 meanings), period "+" (opens Settings),
   First Aid pill (in a status row), shop button (always on).
6. **Accessibility was never a pass** — Dynamic Type unsupported, several sub-44pt/unlabeled controls,
   contrast risks. Fix as **coordinated cleanups** (type ramp, tap-target/label sweep, secondary/radius
   tokens), not per-screen.
7. **Navigation depth** — nested paged tabs + a 1981-line Settings hub shipping debug/dead surfaces.

---

## Part 4 — Recommended sequence (with dependencies)

**Do the foundation first** — the wardrobe, customization, friend-shop, and camera work all reference the
same tokens/components, so establishing them once prevents rework.

| Order | Work | designFirst? | Effort | Depends on |
|-------|------|--------------|--------|-----------|
| 1 | **Part 0 foundation**: F1 tint (S, ship immediately — big visible win), token+component sheet, F2 nav-title, F4 type ramp, F3 secondary/radius sweep | Token/type/nav sheets: **yes**; F1: no | M | — |
| 2 | **#6 Wardrobe/Creation Studio re-theme** (mostly substitution once F1–F4 land) | light | M | 1 |
| 3 | **#4 Friends shop gating** + themed states — after **unifying the clothing/photo mesh** (separate proximity task) | light | M | 1, mesh-unify |
| 4 | **#7 Customization → selector** + **Wardrobe handles customization/recolor** + **move Milestones to Home** | **yes** | M–L | 1, #6 wardrobe, Milestones-home decision |
| 5 | **#1 Home companion** background + tag hierarchy | **yes** | M | 1 |
| 6 | **#3 Move** three-box collapse | **yes** | S–M | 1 |
| 7 | **#2 Food** unified capture + auto-route | **yes** | M–L | 1 |
| 8 | **#5 Camera** dynamic-island viewfinder (+ capture feedback) | **yes** | L | 1 |
| 9 | **Part 2 additional**: A1 IA / A2 Settings / A4 Period / small themed fixes (A5, A6, A7, A10) + a11y sweep (X1, X4–X8) | some | M–L | 1 |

**Hard dependencies to remember:**
- **Move Milestones to Home before/with removing it from the customization sheet** (it's the only entry point — orphan risk).
- **Recolor + design move into the Wardrobe**, so the wardrobe re-theme (#6) should land before the customization selector (#7).
- **Unifying the clothing + photo mesh is a proximity-subsystem task** (signed/sealed transport) — sequence it before shop-gating relies on the single session.
- The **unified clothing selector** needs a decision on how the disjoint enums bridge (possible small model shim).
- Everything visual should reference the **Part 0 token/component/type sheet** first.

---

## Part 5 — Claude design shot list (condensed)

Foundation: token+component sheet · type ramp @ Default/XL/AX3 · themed control set (HubSectionPicker,
SheetSaveBar, buy capsule, Toggle row, section header, alert) · nav-title treatment (large + inline) ·
palette contrast reference (WCAG-annotated).

Per surface: **Home** (stage light/dark, 4 phases, decluttered chips, cold-start) · **Food** (primary
Capture, unified camera, auto-route, ambiguity card, AI-off, failure) · **Move** (before/after strip,
states) · **Friends** (header with/without shop, 3 shop states, unified banner) · **Camera** (capture
beat on 3 device classes, geometry diagram, disabled/permission states, landscape) · **Wardrobe/Studio**
(both screens light/dark, palette/canvas/field/save, row variants) · **Customization** (one-scroll sheet,
unified selector, custom-items section, compact color control, Milestones' new home).

---

## Open questions

### Resolved 2026-07-08
- **Home ambience** → full-bleed wash; keep BOTH WeatherKit + time-of-day.
- **Home chips** → **fully chip-free** (companion + thought bubble carry mood; detail → Trends).
- **Camera** → viewfinder **grows from the Dynamic Island, driven by the wind** (full on the final wind);
  **keep the film/wind mechanic**; **no change to the body**; approximate island anchor accepted. *Still
  to decide in design:* notch/older-device fallback and landscape origin (side vs top-edge).
- **Friends shop** → unify the clothing + photo mesh; gate the shop on the single session's connected
  state.
- **Customization/Wardrobe** → sheet is a selector (shows selected item); wardrobe handles all
  customization; recolor moves to the wardrobe; coins removed.
- **Milestones** → **Home, compact card** (visible even when mostly-empty).

### Still open — reconciled against code 2026-08-09

Two of the four now have de-facto answers in the shipped code; they were decided by implementation
and never written down. Two are genuinely undecided and moved to the live tracker.

3. **Dynamic Type range** — ✅ **Answered by default: full range, no cap.** There is not a single
   `dynamicTypeSize` modifier anywhere in the app or `FernletUI`, so nothing is clamped. If a bounded
   cap was ever wanted, that is new work, not an open question.
4. **Friends shop** — ✅ **Answered: hidden, not ghosted.** `ConnectView.swift:233` renders the shop
   card only inside `if let minutesLeft = manager.clothingShop.remainingWindowMinutes(...)`, so the
   entry simply does not exist while the window is closed.

Genuinely still open (carried to [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md)):

1. **Global IA (A1)** — flatten the Private tab to a NavigationStack list (recommended), or keep
   nested paging? Still a paged `TabView` today.
2. **Settings (A2)** — compile Debug/Tier-2/Signals out under `DEBUG`? And the A3 sub-question is now
   answered in the worst way: the legacy `PersonalScreenView` path **is** still reachable, and the
   2026-08-04 doc pass found it still renders placeholder copy — a `cycleSummary` reading "Tap to
   view your cycle" on a card that is not tappable, and a photos page saying "Photo imports can live
   here when the photo picker is added". That is shipped placeholder UI in the Private hub, so this
   is now a defect, not just an IA question.
