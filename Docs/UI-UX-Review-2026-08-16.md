# Fernlet UI/UX Review — 2026-08-16

A full-app review of every in-app surface: the five tabs, ~50 sheets and pushed routes, onboarding, Settings and Privacy & Data, the Private hub (journal, cycle, worry box, first aid), the Friends/mesh surfaces, coach exchange and trainer export. Eight surface reviewers read the code against three screenshot galleries (light, dark, accessibility-extra-large) plus 311 hand-walked screenshots, then adversarial verifiers tried to refute every high- and medium-severity claim. **271 findings were raised, 12 were refuted outright, and 190 survive here** after cross-surface dedupe — 28 high, 108 medium, 54 low; 18 of them are Tier 2 (structural).

The lenses were **daily-use speed**, **consistency & polish** and **accessibility** — not first-run education. Recommendations are tiered so the structural moves can be accepted or rejected separately: **Tier 1** changes something inside the current screen, **Tier 2** changes where a feature lives or the shape of a flow.

**The verdict in three themes.** First, *the app is polished but not reversible*: ten kinds of saved data — meals, recipes, journal entries, cycle days, designed clothing, planned workouts, friends, shared photos, memories — delete on a single tap with no confirmation and no undo, while iOS 26 renders the confirmations that *do* exist with the Cancel button suppressed, so ~15 dialogs show one red action and no visible way out. Second, *the daily loop leaks taps*: logging a meal throws you to Home, starting today's workout is three sheets deep, half the quick-log grid is below the fold, and several sheets are detent-locked so the option you came for is hidden. Third, *the design system stops at the sheet boundary*: root-presented sheets and the Settings form never inherit the moss tint or the house fonts, so the deeper you go the more the app looks like stock iOS — and at accessibility sizes, fixed frames and `lineLimit(1)` truncate titles, wrap buttons mid-word and push two onboarding primaries off-screen.

## How to use this brief with Claude Design

- Every entry has a stable **id** (e.g. `FOOD-01`). Reference it when you hand a mockup back — that's how I'll match design to finding.
- Pick an entry, upload its **Current** screenshot(s) from `Docs/design-refs/ux-review-2026-08-16/shots/`, and paste the entry's *What's unclear or slow* + *Recommended change* text as the prompt.
- **145 entries are marked "Mockup needed: No"** — accessibility labels, tap targets, copy, sheet detents, missing Cancel buttons, tint inheritance. Those can be implemented directly; no design round trip.
- **Decide the Tier 2 entries on a screen before mocking its Tier 1 entries** — a structural move usually rewrites the layout the Tier 1 fix would be drawn on.
- The systemic entries (marked *Systemic*) are one fix in a shared component that resolves defects on many screens; mock them once, as the shared pattern, not per screen.
- Galleries: `shots/light/`, `shots/dark/`, `shots/ax/` (accessibility-extra-large) hold the same 46 screens in each condition; `shots/manual/{homefood,movefriends,privatesettings}/` hold the deeper walked screens, each with an `INDEX.md` giving the tap path for every file.

## Top 12 changes

The twelve with the most impact on "straightforward to use", in order.

1. **Saving a meal always jumps the app to the Home tab** (`FOOD-01`)  
   After typing a meal in the Food tab's '+ meal' sheet and tapping Save (or picking a Recent item), the app switches to Home. → Drop the `selectedTab = .home` line: keep the user on whatever tab they logged from and show the MealLogNotification toast over that tab.  
   *Food · Tier 1 · no mockup*
2. **iOS 26 confirmationDialog hides Cancel - only the destructive button shows** (`XCUT-02`)  
   Every `.confirmationDialog` renders on iOS 26 as a popover that suppresses the `.cancel`-role button, so the user sees a single red action and no visible way out: "Discard your changes?" shows only Discard (code declares "Keep editing"), "Remove this workout?" only Remove ("Keep it" declared), "End this session?" only "End without logging" ("Keep going" declared), and "Reset app lock?" - which makes private notes permanently unreadable - only "Reset app lock" ("Cancel" declared). → Convert destructive/discard confirmations to `.alert` (which always renders the Cancel-role button on iOS 26) - start with `discardConfirmation` in FernletUI so all five Move sheets and future callers inherit it - or add an explicit non-cancel-role "Keep editing"/"Cancel" button to each `.confirmationDialog`.  
   *Cross-cutting · Tier 1 · no mockup*
3. **Typed drafts discarded silently on swipe-down; Move sheets guard, others don't** (`XCUT-04`)  
   Only the five Move sheets pair `.interactiveDismissDisabled(isDirty)` with the discard confirmation. → Apply the Move pattern everywhere a sheet holds a draft: compute `isDirty`, add `.interactiveDismissDisabled(isDirty)`, a `SheetCancelBar` whose action dismisses when clean and raises the (alert-based) discard confirmation when dirty.  
   *Cross-cutting · Tier 1 · no mockup*
4. **Instant deletes with no confirmation on saved user data** (`XCUT-03`)  
   Several one-tap controls destroy saved data with no confirmation and no undo: the X on a Food meal row deletes the meal immediately; "Delete recipe" (both the saved-recipe notes sheet and the recipe editor) deletes and dismisses in one tap; the Cycle day detail's Delete removes the HealthKit sample + sealed narrative instantly; the X on a Core memory row and the minus on a Personal-care task remove them outright; "Release this worry" releases with no confirmation. → Route recipe delete, Cycle day delete, Core-memory X and Personal-care minus through the existing DestructiveConfirmation alert as the progress-photo delete does; for the meal-row X prefer a 5-second in-place 'Meal removed - Undo' row and defer mealPhotoStore.delete until the undo window closes so the photo is never lost first; leave the worry-box ritual to FLOW-25 (undo window, no dialog).  
   *Cross-cutting · Tier 1 · no mockup*
5. **Meal row X deletes instantly, no confirmation, no undo** (`FOOD-02`)  
   Tapping the X on any meal card removes it (and its sealed photo) immediately with no confirmation and no undo. → Route the X through the shared .destructiveConfirmation ('Remove this meal?' / Remove) as RecipeDetailView already does for the photo; an Undo toast may be added on top but must not replace the confirmation.  
   *Food · Tier 1 · no mockup*
6. **Recent re-log keeps the old meal type and note** (`FOOD-06`)  
   Picking 'Greek yogurt with berries' from Recent at 7:35 PM filed it under Breakfast with the seed note 'Seeded demo meal.' - copyForToday keeps the source mealType and note and ignores both the current time and the sheet's Meal type chips. → When repeating a meal, set mealType to the sheet's selection when one is chosen, otherwise MealParser.classifyMealType-by-time (same 'Auto' rule as typed logs), clear the carried note, and stamp confidence 'Repeated'.  
   *Food · Tier 1 · no mockup*
7. **Sleep sheet locked at medium hides 'Great' and the hours field** (`HOME-01`)  
   The sheet is presented with detents [.medium] only, so it cannot be dragged taller. → Give the sleep sheet detents [.medium, .large] like Care, and render Quality as one FlowLayout row of four ChipButtonStyle chips (Poor / Ok / Good / Great, description as a single slate line under the row) so all four options plus Hours and Note sit above the Save pill at medium height.  
   *Home · Tier 1 · no mockup*
8. **Water sheet locked at medium; add/remove buttons fall below fold at AX** (`HOME-02`)  
   Detents are [.medium] only. → Allow [.medium, .large]; replace the left-aligned chip pair with a centered stepper directly under the bottle row ('−  6  +' in DM Sans, moss accents, 44pt targets) so it is above the fold at every text size; keep Done bottom-right.  
   *Home · Tier 1 · mockup*
9. **Home Move tile opens a strength-only exercise picker** (`HOME-10`)  
   The Move quick-log tile opens 'Quick exercise', a search list of ~90 gym exercises with Sets/Reps/Weight/RPE. → Point the Move tile at the same Log workout sheet the Move tab uses (Strength / Workouts kind chips at the top, medium+large detents), or add a first row of quick kinds (Walk · Run · Ride · Stretch · Gym) above the exercise search in Quick exercise.  
   *Home · Tier 2 · mockup*
10. **Guided workout start is buried three sheets deep** (`FLOW-03`)  
   On any day without an already-approved plan the Move root shows no start/suggest entry at all. → Always render the 'Today's workout' card on the Move root: with no plan it carries one primary button 'Suggest today's workout' that presents WorkoutSuggestionSheet directly from the root (one sheet), and once a plan exists it shows Start.  
   *Move · Tier 2 · mockup*
11. **Runner finish strands user on empty Plan workout sheet** (`MOVE-01`)  
   Suggest is presented from inside the Plan workout sheet, and the guided runner from inside Suggest (sheet-of-sheet-of-sheet). → Give WorkoutSuggestionSheet an onFinished callback; WorkoutPlanSheet dismisses itself on it ONLY when its own form is not dirty (otherwise stay, since the nesting exists to keep a part-filled plan).  
   *Move · Tier 2 · mockup*
12. **Today's entries are listed twice: under Today and Previous** (`PRIV-01`)  
   Every entry written today appears in the TODAY card and again in the PREVIOUS card (dated 'Aug 16'), so a daily user sees three entries become six. → In previousSection filter out entries whose dayKey == store.todayKey (store.previousJournals deliberately front-inserts today's entries), and render both lists newest-first so the entry just saved is at the top of Today.  
   *Private · Tier 1 · no mockup*

## Systemic themes (fix once, in shared components)

- iOS 26 confirmationDialog drops the Cancel button — every discard/remove/reset dialog shows one red action; convert discardConfirmation and siblings to .alert (XCUT-02; HOME-03, MOVE-02, SETT-07 merged; MOVE-03, MOVE-21).
- Saved data deleted with no confirmation — one DestructiveConfirmation path for meal X, recipe, journal, cycle day, wardrobe item, planned workout, friend, photos, memory, care task (XCUT-03, FOOD-02, PRIV-02, PRIV-03, HOME-08, MOVE-04, FRND-03, FRND-11, FRND-14, PRIV-20; FOOD-03, SETT-20, SETT-21 merged).
- Draft sheets discard typed text on swipe; only Move guards — a shared draftSheet(isDirty:) + SheetCancelBar (XCUT-04, HOME-07, MOVE-21, SETT-22; FOOD-10, PRIV-04, HOME-15 merged).
- Sheet chrome is inconsistent: close/save placement, titles, detents hide primary controls (XCUT-14, XCUT-15, HOME-01, HOME-02, FOOD-08, FOOD-20, MOVE-14, MOVE-17, PRIV-06, PRIV-13, FRND-28, FOOD-19; HOME-14, MOVE-20, FRND-20 merged).
- Root-presented sheets and the Settings Form never inherit moss tint or house fonts, and the app ignores system dark mode (XCUT-11, XCUT-13, XCUT-06, SETT-02, MOVE-09, PRIV-15; FOOD-13, SETT-03, XCUT-12, HOME-17, HOME-33, SETT-01 merged).
- VoiceOver: icon-only buttons unlabeled, selected state never exposed, targets under 44pt (XCUT-08, XCUT-09, XCUT-01, XCUT-18, HOME-06, HOME-21, PRIV-12, SETT-24, FRND-15, FRND-17, FRND-18; PRIV-31, PRIV-34, FOOD-26, MOVE-19, FRND-10, FRND-16 merged).
- Dynamic Type: fixed frames, HStack pairs and lineLimit(1) truncate or wrap mid-word (XCUT-17, XCUT-19, XCUT-20, HOME-34, SETT-33, MOVE-06; FOOD-27, MOVE-30, SETT-06 merged).
- Contrast: white ink on moss/terracotta and slate/goldenrod small text sit under 4.5:1 (XCUT-07, XCUT-10, PRIV-21, PRIV-24, PRIV-30, MOVE-18; FOOD-28 merged).
- Daily logging speed: post-save tab jump, no recents/prefill, wrong keyboards, required names, defaults that override today's mood (FOOD-01, FOOD-06, FOOD-07, FLOW-15, MOVE-07, MOVE-08, MOVE-12, XCUT-22, PRIV-05, PRIV-14, HOME-10; FLOW-06, FLOW-21, FLOW-12 merged).
- Move's guided flow is buried three sheets deep and strands the user on finish; destructive/empty-state visual tokens also diverge app-wide (FLOW-03, MOVE-01, XCUT-21, FRND-19, XCUT-29; MOVE-27, FLOW-04, MOVE-29, FRND-24 merged).

## Tier 2 — structural proposals

These change where something lives or the shape of a flow. Decide them before mocking Tier 1 work on the same screen.

| id | Tab | Screen | Proposal | Why it earns a structural change |
| --- | --- | --- | --- | --- |
| `FLOW-03` | Move | Move tab root | Always render the 'Today's workout' card on the Move root: with no plan it carries one primary button 'Suggest today's workout' that presents WorkoutSuggestionSheet directly from the root (one sheet), and once a plan exists it shows Start | On any day without an already-approved plan the Move root shows no start/suggest entry at all |
| `MOVE-01` | Move | Plan workout / Suggest sheets | Give WorkoutSuggestionSheet an onFinished callback; WorkoutPlanSheet dismisses itself on it ONLY when its own form is not dirty (otherwise stay, since the nesting exists to keep a part-filled plan) | Suggest is presented from inside the Plan workout sheet, and the guided runner from inside Suggest (sheet-of-sheet-of-sheet) |
| `HOME-10` | Home | Home: Quick log grid | Point the Move tile at the same Log workout sheet the Move tab uses (Strength / Workouts kind chips at the top, medium+large detents), or add a first row of quick kinds (Walk · Run · Ride · Stretch · Gym) above the exercise search in Quick exercise | The Move quick-log tile opens 'Quick exercise', a search list of ~90 gym exercises with Sets/Reps/Weight/RPE |
| `SETT-14` | Settings | Settings > Goal & nutrition | Split into hub rows that match user intent: 'Goal & nutrition' (goal, calories, body, targets, hydration), 'Reminders', 'AI & data sources' (AI status, web lookup, weather, body signals), 'Personal care tasks', and fold Coach into Move; the search breadcrumbs then match | Under the title 'Goal & nutrition' the scroll contains Goal, Sick mode/Show calories, Body profile, Preferences, Nutrition targets, AI (web lookup, weather prompts), Coach, Body signals, Reminders (daily check-in), Hydration and Personal care tasks |
| `SETT-15` | Settings | Settings > Goal & nutrition | Surface 'I'm unwell today' where the day lives — the Home Today card / companion menu or as a Quick-log shortcut option — and leave Settings with only the explanation of what sick mode changes | 'Sick mode' is bound to `store.setSick(_:on: store.todayKey)` — it is a per-day flag, not a preference — yet its only control is Settings › Goal & nutrition, below seven goal cards |
| `SETT-26` | Settings | Settings > Wellness | Remove the Sleep and Move rows (or hide Move until it works, without '(M2)'); collapse the Wellness section to a single 'Health' row; show the unavailable message once and rewrite the intro in user voice ('Fernlet asks for Health access only when a feature needs it.') | 'Sleep' opens a read-only card of today's sleep with no setting; 'Move' shows a placeholder 'Available after Apple Fitness integration lands (M2)' — an internal milestone tag — with a permanently disabled 'Request access' button, even though workout Health sync already exists under Health/Privacy & Data |
| `SETT-27` | Settings | Settings > Wellness | Make Settings › Health the single Health surface (master switch, then one card per capability with a plain-language name and its request/revoke action) and reduce Privacy & Data to a link 'Health access → ' plus the master switch | Settings › Health lists per-capability cards with 'Give access / Update data / Revoke access' buttons; Privacy & Data › HealthKit lists a master 'Health integration' switch plus per-capability toggles named with internal titles ('Body context', 'Activity context', 'Intimate logging') |
| `SETT-28` | Settings | Settings hub | Gate the Debug page behind #if DEBUG and derive its storage line from store.storageLocation only; collapse Connection Inspector + History into one 'Connection log' row at the bottom of Advanced (keep it user-reachable as a transparency surface) and drop the duplicate hub row | 'Debug' opens a page headed 'Prototype only — not production-private' with a hardcoded 'Storage: local JSON database' line directly above 'File: Core Data + iCloud'; 'Connection Inspector' and 'Connection History' are both hub rows and the Inspector page links to History again |
| `FOOD-11` | Food | Recipe detail | Make the recipe book a pushed page in the Food NavigationStack (the 'Recipe book' link and the Home shortcut both push it), so book -> detail -> editor is one stack: the editor presents as a sheet over the detail and dismisses back to it | From the Food card the detail is a pushed page with the tab bar; from the Recipe book it is a page inside a full-height sheet |
| `HOME-13` | Home | Home: cards | Present Milestones through activeSheet as a .large sheet with its own NavigationStack (Keepsake shelf pushed inside, top-right Done), matching the library family; or move Trends/First aid to pushes — one rule for read-only destinations from Home | Milestones is a NavigationLink push inside Home's stack (tab bar stays, back chevron), while the visually identical Trends and First aid cards and the gear open large sheets with Done |
| `HOME-22` | Home | Home: companion | Add a small 'Customize' pencil chip beneath the companion (next to the Body signals link) and a 'Wardrobe' row in the Customize sheet header with the coin pill; keep long-press as a shortcut | The only production entry to companion customization is a 0.45s long-press on the companion (hint exists only for VoiceOver) |
| `FRND-12` | Friends | Photo review sheet | Make the primary action 'Keep selected' (retains on the shelf, no permission needed) and add a secondary toggle/row 'Also save to Photos' (default off, or remembered) | 'Save selected' first writes to the system Photos library and only on success calls finishSessionPhotos(keeping:) which retains the pictures on the in-app photo wall |
| `FRND-25` | Friends | Friends tab root | Add a 'Your friends' strip on the root under the searching bar: horizontal companion avatars with a nearby dot and a one-tap heart on those reachable now, tapping opens their card; add a small 'Nearby settings' link (or gear) in the header that deep-links to the Privacy nearby toggles | The Friends root is a photo album plus a searching bar; your friends and the 'Send good vibes' heart live behind the unlabeled person.2 icon, then a row tap to expand the detail card |
| `FOOD-18` | Food | Food tab root | Add a small 'Targets' link in the MACROS TODAY header row (or make the card tappable) that presents NutritionTargetsEditor in a sheet from Food | The card shows 'of 93g / of 372g / of 88g' targets but is not tappable; the targets editor lives only under Settings > Goal & nutrition |
| `FOOD-35` | Food | Meal planner | On today's day card give each planned recipe a 'Log' pill (same meal-type chip + Log control), and show a small 'Planned today' card on the Food root above the meals with one-tap Log per recipe | The planner assigns recipes to days and feeds the shopping list, but today's planned rows have only a '-' remove control; when the day comes the user still has to find the recipe in the book to log it, and the Food root never surfaces 'planned for today' |
| `HOME-23` | Home | Home: root | Decide deliberately whether horizontal tab paging is wanted; if not, .scrollDisabled(true) on the TabView and rely on tab-bar taps | The root TabView uses .page style, so any horizontal drag that is not captured by an inner scroller switches tabs; the polaroid strip has hit-testing disabled (drags there always page), and the mood-chip and Recent-bites rows are horizontal scrollers competing with paging |
| `FLOW-18` | Home | Home: root | Tighten the vertical rhythm above the grid (shorter polaroid strip, less Today-card top padding, tile minHeight 66 -> 56) so all six tiles clear the tab bar on a 6.1-inch device with the companion still centred; do not reorder widgets, and leave the user's Layout & shortcuts order authoritative | On a 6.1-inch device the second row of quick-log tiles (Sleep, Journal, Care) is hidden behind the floating tab bar on cold open; the polaroid strip, companion and Today card consume the first screen, so three of the six daily actions need a scroll first |
| `FLOW-34` | Cross-cutting | Tab headers | Either add the same small gear to every tab's ScreenHeader trailing slot, or make a long-press on the Home tab item open Settings | Only the Home header has the gear; from any other tab opening Settings is Home > gear (two taps plus a tab switch), and there is no long-press or shortcut |

---

# Findings by screen

## Home

Home reads beautifully and the companion carries it, but the quick-log grid — the thing you touch every day — is half below the fold on a cold open, its tile labels use four different state conventions, and two of its sheets are detent-locked so the option you want is hidden. Customization is reachable only by an unmarked long-press.

### Sleep sheet

**Current:** ![26-quicklog-sleep-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/26-quicklog-sleep-sheet.png) ![27-quicklog-sleep-sheet-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/27-quicklog-sleep-sheet-scrolled.png) ![Sheet--Sleep.png](design-refs/ux-review-2026-08-16/shots/ax/Sheet--Sleep.png)

#### HOME-01 — High — Tier 1 — Daily-use speed — Sleep sheet locked at medium hides 'Great' and the hours field

- **What's unclear or slow:** The sheet is presented with detents [.medium] only, so it cannot be dragged taller. Its four quality rows are each two-line cards, so at default type the fourth option 'Great' (the one already selected in the demo) is clipped behind the floating Save pill and the Hours/Note fields are entirely off-screen; the user has to discover an inner scroll inside a half-sheet. At AX Dynamic Type only 1.5 options are visible. Care sheet, by contrast, allows medium+large.
- **Recommended change:** Give the sleep sheet detents [.medium, .large] like Care, and render Quality as one FlowLayout row of four ChipButtonStyle chips (Poor / Ok / Good / Great, description as a single slate line under the row) so all four options plus Hours and Note sit above the Save pill at medium height.
- **Mockup needed:** No (code-only)
- **Evidence:** [26-quicklog-sleep-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/26-quicklog-sleep-sheet.png) · [27-quicklog-sleep-sheet-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/27-quicklog-sleep-sheet-scrolled.png) · [Sheet--Sleep.png](design-refs/ux-review-2026-08-16/shots/ax/Sheet--Sleep.png) · [29-quicklog-care-sheet-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/29-quicklog-care-sheet-scrolled.png) — `App/Fernlet/ContentView.swift:684-686`, `App/Fernlet/SharedSheets.swift:77-109`, `App/Fernlet/SharedSheets.swift:112-149`
- **Also reported as:** XCUT-05

### Water sheet

**Current:** ![Sheet--Water.png](design-refs/ux-review-2026-08-16/shots/ax/Sheet--Water.png) ![20-quicklog-water-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/20-quicklog-water-sheet.png)

#### HOME-02 — High — Tier 1 — Accessibility — Water sheet locked at medium; add/remove buttons fall below fold at AX

- **What's unclear or slow:** Detents are [.medium] only. At accessibility text sizes the entire Remove / Add a bottle row is below the visible area of the half-sheet, leaving only the count and a Done pill — the primary action is invisible until the user scrolls inside the sheet. At default size the actions are also left-aligned as chip-style buttons ('Add a bottle' uses ChipButtonStyle(selected:true), a bark toggle look) while Done sits bottom-right, so the primary action is neither styled as primary nor in thumb reach.
- **Recommended change:** Allow [.medium, .large]; replace the left-aligned chip pair with a centered stepper directly under the bottle row ('−  6  +' in DM Sans, moss accents, 44pt targets) so it is above the fold at every text size; keep Done bottom-right.
- **Mockup needed:** Yes
- **Evidence:** [Sheet--Water.png](design-refs/ux-review-2026-08-16/shots/ax/Sheet--Water.png) · [20-quicklog-water-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/20-quicklog-water-sheet.png) — `App/Fernlet/ContentView.swift:681-683`, `App/Fernlet/SharedSheets.swift:37-52`, `App/Fernlet/SharedSheets.swift:59`

### Creation Studio

**Current:** ![14-creation-studio-painted.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/14-creation-studio-painted.png) ![12-creation-studio-editor.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/12-creation-studio-editor.png) ![06-home-companion-longpress.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/06-home-companion-longpress.png)

#### HOME-07 — High — Tier 1 — Daily-use speed — Back or sheet swipe silently discards a painted canvas

- **What's unclear or slow:** The studio is pushed inside the customization sheet's NavigationStack. Tapping the back chevron with a painted canvas, or swiping the sheet down from anywhere in Customize > Wardrobe > Studio, throws the drawing away with no prompt (walker reproduced it). Neither the studio nor the host sheet uses interactiveDismissDisabled or a dirty guard, unlike the logging sheets.
- **Recommended change:** When the canvas is non-blank and unsaved: hide the system back button and use a custom back that raises the shared discard alert ('Keep drawing' / 'Discard'), and set .interactiveDismissDisabled(true) on the customization sheet while a dirty studio is on the stack; or persist per-slot drafts across the session so nothing is lost.
- **Mockup needed:** No (code-only)
- **Evidence:** [14-creation-studio-painted.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/14-creation-studio-painted.png) · [12-creation-studio-editor.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/12-creation-studio-editor.png) · [06-home-companion-longpress.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/06-home-companion-longpress.png) — `App/Fernlet/CreationStudioView.swift:83-111`, `App/Fernlet/HomeView.swift:86-94`

#### HOME-30 — Low — Tier 1 — Consistency & polish — Palette sits below the fold; slot picker is a system segmented control

- **What's unclear or slow:** On first open the palette swatches are scrolled under the pinned Next bar (only the 'PALETTE' label shows), so the user must scroll to pick a colour before painting; the Hat/Face/Outfit/Held item switcher is the stock segmented control (white pill on grey) rather than HubSectionPicker.
- **Recommended change:** Place the palette row directly under Undo/Mirror above the canvas (or pin it just above the Next bar), and swap the Picker for HubSectionPicker.
- **Mockup needed:** Yes
- **Evidence:** [12-creation-studio-editor.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/12-creation-studio-editor.png) · [13-creation-studio-editor-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/13-creation-studio-editor-scrolled.png) — `App/Fernlet/CreationStudioView.swift:83-111`, `App/Fernlet/CreationStudioView.swift:126-148`, `App/Fernlet/CreationStudioView.swift:230-247`
- **Note:** low severity — not independently verified.

### Wardrobe

**Current:** ![11-wardrobe-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/11-wardrobe-top.png)

#### HOME-08 — High — Tier 1 — Consistency & polish — Swipe-to-delete removes a designed item instantly, no confirm/undo

- **What's unclear or slow:** The trailing swipe action calls store.deleteCustomItem directly; a full swipe deletes a user-drawn (or purchased) item with no confirmation and no undo, contradicting the app's explicit-confirmation rule for destructive actions.
- **Recommended change:** Route the swipe Delete through a confirmation alert ('Delete "Scarf"? It leaves your closet and your companion.' — Cancel / Delete) and set allowsFullSwipe: false on the trailing edge; keep the confirmation even if an Undo toast is added later.
- **Mockup needed:** No (code-only)
- **Evidence:** [11-wardrobe-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/11-wardrobe-top.png) — `App/Fernlet/WardrobeView.swift:214-220`

#### HOME-24 — Low — Tier 1 — Consistency & polish — Wardrobe rows show a doubled chevron

- **What's unclear or slow:** The 'Design a new item' row draws its own chevron and the List's NavigationLink adds a second one outside the card; the empty-state 'Design your first item' button also gets a stray system chevron to its right.
- **Recommended change:** Drop the hand-drawn chevron and hide the List accessory (e.g. Button + navigationDestination(isPresented:), or overlay the NavigationLink with opacity 0), so exactly one chevron shows.
- **Mockup needed:** No (code-only)
- **Evidence:** [11-wardrobe-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/11-wardrobe-top.png) · [75-wardrobe-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/75-wardrobe-top.png) — `App/Fernlet/WardrobeView.swift:44-53`, `App/Fernlet/WardrobeView.swift:126-152`, `App/Fernlet/WardrobeView.swift:296-307`
- **Note:** low severity — not independently verified.

### Home: Quick log grid

**Current:** ![02-home-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/02-home-scrolled-1.png) ![30-home-feeling-chip-tapped.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/30-home-feeling-chip-tapped.png) ![105-water-plus-badge-tap.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/105-water-plus-badge-tap.png)

#### HOME-09 — Medium — Tier 1 — Clarity — Tile labels use four state conventions; 'Done'/'Logged' lack a noun

- **What's unclear or slow:** Meal shows a count ('3 meal' — also unpluralised), water a multiplier ('6x'), move a bare status ('Done'), sleep 'Logged', while Journal and Care keep their noun and signal state only by moss tint (after a mood chip tap the Journal tile turns green but its label doesn't change). Nothing tells a new-to-the-tile user what '6x' or 'Done' refers to except the icon, and QuickLogButton has no accessibilityLabel so VoiceOver hears the same ambiguity.
- **Recommended change:** Keep the noun on every tile and add a small DM Sans status line: 'Meals · 3', 'Water · 6', 'Move · done', 'Sleep · logged', 'Journal · Good', 'Care · 2/8'; give each tile an accessibilityLabel of the same string.
- **Mockup needed:** Yes
- **Evidence:** [02-home-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/02-home-scrolled-1.png) · [30-home-feeling-chip-tapped.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/30-home-feeling-chip-tapped.png) · [105-water-plus-badge-tap.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/105-water-plus-badge-tap.png) — `App/Fernlet/HomeView.swift:970-987`, `App/Fernlet/HomeView.swift:989-1014`, `App/Fernlet/HomeView.swift:2061-2083`
- **Also reported as:** XCUT-24

#### HOME-06 — Medium — Tier 1 — Accessibility — Water '+' badge is a ~27pt target nested inside another button

- **What's unclear or slow:** The one-tap '+1 bottle' badge is a plus.circle.fill at .body size with 5pt padding, overlaid on the corner of the water tile — roughly 27pt square, well under 44pt, and adjacent to a larger button that does something different (opens the sheet). It is the fastest daily log path in the app but is easy to miss-tap into the sheet, and its existence is not discoverable (no label, no count animation).
- **Recommended change:** Give the badge a 44x44 hit area (.frame(width:44,height:44).contentShape(Rectangle()) around the 20pt glyph) anchored top-trailing, and animate the tile count on tap; the existing accessibilityLabel can stay.
- **Mockup needed:** No (code-only)
- **Evidence:** [105-water-plus-badge-tap.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/105-water-plus-badge-tap.png) · [Home_tab.png](design-refs/ux-review-2026-08-16/shots/light/Home_tab.png) — `App/Fernlet/HomeView.swift:937-968`

#### HOME-10 — Medium — Tier 2 — Daily-use speed — Home Move tile opens a strength-only exercise picker

- **What's unclear or slow:** The Move quick-log tile opens 'Quick exercise', a search list of ~90 gym exercises with Sets/Reps/Weight/RPE. There is no way to log a walk, run, ride or yoga from Home (the catalog's only cardio entries are 'Treadmill walk/run'); the Move tab's Log workout sheet has a 'Workouts' kind with Walking/Running/etc. A daily walker gets routed into the wrong flow from the app's front door.
- **Recommended change:** Point the Move tile at the same Log workout sheet the Move tab uses (Strength / Workouts kind chips at the top, medium+large detents), or add a first row of quick kinds (Walk · Run · Ride · Stretch · Gym) above the exercise search in Quick exercise.
- **Mockup needed:** Yes
- **Evidence:** [22-quicklog-movement-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/22-quicklog-movement-sheet.png) · [24-quicklog-movement-exercise-picked.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/24-quicklog-movement-exercise-picked.png) · [40-log-workout-kind-workouts.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/40-log-workout-kind-workouts.png) — `App/Fernlet/HomeView.swift:1047-1048`, `App/Fernlet/MoveView.swift:889-970`, `App/Fernlet/WorkoutExercises.json`
- **Also reported as:** FLOW-26

### Home: mood row

**Current:** ![02-home-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/02-home-scrolled-1.png) ![30-home-feeling-chip-tapped.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/30-home-feeling-chip-tapped.png) ![21-quicklog-journal-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/21-quicklog-journal-sheet.png)

#### HOME-11 — Medium — Tier 1 — Consistency & polish · Systemic — Mood row hides Tired and Hard behind a horizontal scroll

- **What's unclear or slow:** The Home mood row is a horizontal ScrollView; only Bright/Good/Neutral/Quiet fit and the fourth chip ends flush with the card edge, so nothing peeks to suggest more. The two harder moods (Tired, Hard) are the hidden ones. The Journal sheet lays out the same six FeelingTags with FlowLayout on two rows (and without the coloured dots), so the same job looks and behaves differently one tap apart.
- **Recommended change:** Use FlowLayout(spacing: 8) so all six chips wrap onto two rows on Home, and share one chip component (with dots) between Home and the Journal sheet.
- **Mockup needed:** No (code-only)
- **Evidence:** [02-home-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/02-home-scrolled-1.png) · [30-home-feeling-chip-tapped.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/30-home-feeling-chip-tapped.png) · [21-quicklog-journal-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/21-quicklog-journal-sheet.png) — `App/Fernlet/QuickMoodRow.swift:41-74`
- **Also reported as:** PRIV-11, XCUT-26, FLOW-29

### Home: First aid card

**Current:** ![03-home-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/03-home-scrolled-2.png) ![36-firstaid-from-home.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/36-firstaid-from-home.png)

#### HOME-12 — Medium — Tier 1 — Clarity — First aid chips look tappable but only the card is a target

- **What's unclear or slow:** The Breathe / Ground / Worry box chips are styled as capsule buttons but are decorative (accessibilityHidden); tapping 'Breathe' opens the First aid list and the user taps 'Slow breathing' again. The routes for direct entry already exist (.firstAid(.breathing) etc.).
- **Recommended change:** Make each chip its own Button routing to activeSheet = .firstAid(.breathing / .grounding / .worryBox), keep the card header as the target for the general sheet, and give the chips accessibility labels.
- **Mockup needed:** No (code-only)
- **Evidence:** [03-home-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/03-home-scrolled-2.png) · [36-firstaid-from-home.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/36-firstaid-from-home.png) — `App/Fernlet/HomeView.swift:460-527`, `App/Fernlet/HomeView.swift:1066-1071`

### Home: cards

**Current:** ![33-milestones-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/33-milestones-top.png) ![31-trends-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/31-trends-sheet-top.png) ![36-firstaid-from-home.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/36-firstaid-from-home.png)

#### HOME-13 — Medium — Tier 2 — Consistency & polish — Milestones pushes a page; sibling cards open sheets

- **What's unclear or slow:** Milestones is a NavigationLink push inside Home's stack (tab bar stays, back chevron), while the visually identical Trends and First aid cards and the gear open large sheets with Done. Same chevron affordance, two navigation models.
- **Recommended change:** Present Milestones through activeSheet as a .large sheet with its own NavigationStack (Keepsake shelf pushed inside, top-right Done), matching the library family; or move Trends/First aid to pushes — one rule for read-only destinations from Home.
- **Mockup needed:** Yes
- **Evidence:** [33-milestones-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/33-milestones-top.png) · [31-trends-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/31-trends-sheet-top.png) · [36-firstaid-from-home.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/36-firstaid-from-home.png) · [38-settings-hub.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/38-settings-hub.png) — `App/Fernlet/HomeView.swift:176-242`, `App/Fernlet/HomeView.swift:303-305`, `App/Fernlet/ContentView.swift:714-742`

#### HOME-28 — Low — Tier 1 — Consistency & polish — Home cards use three different header treatments

- **What's unclear or slow:** Quick log has an external uppercase SectionLabel above its card; Macros today and Recent bites put the uppercase label inside the card; Today, Trends, First aid and Milestones use a serif header inside the card. Same page, three header styles.
- **Recommended change:** Pick one: serif header inside every navigable card, uppercase SectionLabel inside every data card — and apply it to Quick log too.
- **Mockup needed:** Yes
- **Evidence:** [02-home-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/02-home-scrolled-1.png) · [03-home-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/03-home-scrolled-2.png) · [04-home-scrolled-3.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/04-home-scrolled-3.png) — `App/Fernlet/HomeView.swift:919-935`, `App/Fernlet/HomeView.swift:2094-2113`, `App/Fernlet/HomeView.swift:561-607`, `App/Fernlet/HomeView.swift:176-242`
- **Note:** low severity — not independently verified.

#### HOME-29 — Low — Tier 1 — Clarity — Today card's 'Sunday / Wellness' is an unlabeled goal name

- **What's unclear or slow:** The trailing stack shows the weekday (already in the page header) and the raw goal displayName 'Wellness' with no label, so it reads as a status word rather than 'your goal'.
- **Recommended change:** Replace with 'Goal · Wellness' (tap → Settings > Goal & nutrition) or the companion state word, and drop the duplicated weekday.
- **Mockup needed:** No (code-only)
- **Evidence:** [Home_tab.png](design-refs/ux-review-2026-08-16/shots/light/Home_tab.png) · [02-home-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/02-home-scrolled-1.png) — `App/Fernlet/HomeView.swift:848-866`
- **Note:** low severity — not independently verified.

### Macros today card

**Current:** ![02-home-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/02-home-scrolled-1.png) ![03-home-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/03-home-scrolled-2.png)

#### HOME-18 — Medium — Tier 1 — Clarity · Systemic — 'Fiber 37g' shows the target where intake totals are read

- **What's unclear or slow:** The card's footer prints targets.fiber ('Fiber 37g') beside the three consumed-vs-goal rings; MacroTotals has no fiber field, so the number is a goal, but it reads as today's intake. Shared with the Food tab.
- **Recommended change:** Show 'Fiber — of 37g' with the day's fiber intake from the day's Micronutrients totals when available; otherwise relabel as 'Fiber target 37g'. Same card on Food (FOOD-17 folded in).
- **Mockup needed:** No (code-only)
- **Evidence:** [02-home-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/02-home-scrolled-1.png) · [03-home-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/03-home-scrolled-2.png) — `App/Fernlet/HomeView.swift:2089-2115`, `FernletKit/Sources/FernletDomainModel/NutritionModels.swift:1934-1946`
- **Also reported as:** XCUT-28

### Trends sheet

**Current:** ![31-trends-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/31-trends-sheet-top.png) ![32-trends-sheet-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/32-trends-sheet-scrolled.png)

#### HOME-19 — Medium — Tier 1 — Clarity — Trends leaks developer copy and raw field identifiers

- **What's unclear or slow:** The subtitle reads 'Prototype only — not production-private', and each signal card lists its inputs as raw code keys ('journals.tag', 'sleep.hours', 'meals.calorieSnapshot'). The Done pill is also the only bottom-centred one in the app.
- **Recommended change:** Subtitle: 'Local signals from your logs — worked out on this device.'; map sourceFields to human labels ('Journal moods', 'Sleep hours', 'Meal count'); right-align Done via SheetSaveBar(label: "Done").
- **Mockup needed:** No (code-only)
- **Evidence:** [31-trends-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/31-trends-sheet-top.png) · [32-trends-sheet-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/32-trends-sheet-scrolled.png) — `App/Fernlet/HomeView.swift:1882-1905`, `App/Fernlet/HomeView.swift:1745-1754`, `App/Fernlet/HomeView.swift:1907-1921`
- **Also reported as:** XCUT-27

### Milestones page

**Current:** ![33-milestones-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/33-milestones-top.png) ![34-milestones-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/34-milestones-scrolled.png)

#### HOME-20 — Medium — Tier 1 — Clarity — Rows count 'milestone gifts' while footer says none yet

- **What's unclear or slow:** Row gifts come from thresholds crossed (reachedCount) while the footer/header come from the coin ledger (milestoneAwardCoins), so the page can show '2 milestone gifts' on rows and 'No milestone gifts yet' beneath them — reachable after a reset (ledger voided, counts append-only) and in the demo state.
- **Recommended change:** Drive both from one source (e.g. word rows as '2 milestones reached' and let only the footer talk about coins), or hide the row star line when totalMilestoneCoins == 0.
- **Mockup needed:** No (code-only)
- **Evidence:** [33-milestones-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/33-milestones-top.png) · [34-milestones-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/34-milestones-scrolled.png) — `App/Fernlet/MilestonesView.swift:176-184`, `App/Fernlet/MilestonesView.swift:209-253`, `App/Fernlet/MilestonesView.swift:405-410`

#### HOME-27 — Low — Tier 1 — Consistency & polish — Keepsake icons and tints differ between card and page

- **What's unclear or slow:** Home's card renders journal as a moss 'book' and workouts terracotta; the Milestones page and shelf render journal as an amethyst 'book.closed' and workouts green, so the same keepsake changes colour and glyph one tap later.
- **Recommended change:** Move the medal icon/tint table into MilestoneRowModel and have the Home card read from it.
- **Mockup needed:** No (code-only)
- **Evidence:** [03-home-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/03-home-scrolled-2.png) · [33-milestones-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/33-milestones-top.png) · [35-keepsake-shelf.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/35-keepsake-shelf.png) — `App/Fernlet/HomeView.swift:146-157`, `App/Fernlet/MilestonesView.swift:396-404`, `App/Fernlet/MilestonesView.swift:451-481`
- **Note:** low severity — not independently verified.

### Home: misc a11y

**Current:** ![76-empty-home-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/76-empty-home-top.png) ![13-creation-studio-editor-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/13-creation-studio-editor-scrolled.png) ![26-quicklog-sleep-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/26-quicklog-sleep-sheet.png)

#### HOME-21 — Medium — Tier 1 — Accessibility — Small icon-only controls and missing selection semantics for VoiceOver

- **What's unclear or slow:** Dismiss 'x' buttons on Today's intent, gentle offer and nutrient nudge are 28x28pt; the friend-shop '•••' menu is ~27pt and has an identifier but no accessibilityLabel; studio swatches are announced as 'Color 1…N'; sleep-quality and care rows expose their chosen state only through a checkmark image (no .isSelected trait or value).
- **Recommended change:** Wrap the 28pt glyphs in a 44pt frame + contentShape; add .accessibilityLabel("More options for <item>") to the ellipsis Menu; name palette swatches (e.g. 'Moss', 'Bark'); add .accessibilityAddTraits(.isSelected) to the chosen sleep row and .accessibilityValue("completed") to done care rows.
- **Mockup needed:** No (code-only)
- **Evidence:** [76-empty-home-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/76-empty-home-top.png) · [13-creation-studio-editor-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/13-creation-studio-editor-scrolled.png) · [26-quicklog-sleep-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/26-quicklog-sleep-sheet.png) · [28-quicklog-care-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/28-quicklog-care-sheet.png) — `App/Fernlet/HomeView.swift:888-899`, `App/Fernlet/AmbientCards.swift:161-172`, `App/Fernlet/AmbientCards.swift:472-482`, `App/Fernlet/FriendShopView.swift:186-202`, `App/Fernlet/CreationStudioView.swift:285-296`, `App/Fernlet/SharedSheets.swift:127-149`, `App/Fernlet/SharedSheets.swift:268-285`

### Home: companion

**Current:** ![05-home-companion-tapped.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/05-home-companion-tapped.png) ![06-home-companion-longpress.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/06-home-companion-longpress.png) ![10-customize-accessory-picker.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/10-customize-accessory-picker.png)

#### HOME-22 — Medium — Tier 2 — Clarity — Customize/Wardrobe/Studio reachable only by an unmarked long-press

- **What's unclear or slow:** The only production entry to companion customization is a 0.45s long-press on the companion (hint exists only for VoiceOver). Wardrobe, the Creation Studio, the coin balance and the shop are then four levels deep (Customize > slot > 'Design & recolor in Wardrobe' > Studio). Existing users who forget the gesture have no visible door and never see their coins.
- **Recommended change:** Add a small 'Customize' pencil chip beneath the companion (next to the Body signals link) and a 'Wardrobe' row in the Customize sheet header with the coin pill; keep long-press as a shortcut.
- **Mockup needed:** Yes
- **Evidence:** [05-home-companion-tapped.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/05-home-companion-tapped.png) · [06-home-companion-longpress.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/06-home-companion-longpress.png) · [10-customize-accessory-picker.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/10-customize-accessory-picker.png) · [11-wardrobe-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/11-wardrobe-top.png) — `App/Fernlet/HomeView.swift:386-431`, `App/Fernlet/HomeView.swift:1443-1497`

#### HOME-25 — Low — Tier 1 — Clarity — Companion says notes 'are here' on an empty day

- **What's unclear or slow:** The deterministic fallback thought is 'A few ordinary care notes are here. Keep the day simple.' regardless of the day, so on a fresh install the bubble claims notes exist while the Today's intent card below says nothing is logged; HomeView's own 'Start with one small thing' empty branch is unreachable because companionThought is never nil.
- **Recommended change:** Return nil from deterministicThought when the day has no meals/workouts/journals so HomeView's empty-day line shows, or make the fallback log-aware.
- **Mockup needed:** No (code-only)
- **Evidence:** [76-empty-home-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/76-empty-home-top.png) — `App/Fernlet/LaunchPreparationService.swift:384-401`, `App/Fernlet/HomeView.swift:649-663`
- **Note:** low severity — not independently verified.

### Home: header

**Current:** ![Home_tab.png](design-refs/ux-review-2026-08-16/shots/light/Home_tab.png) ![Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) ![Move_tab.png](design-refs/ux-review-2026-08-16/shots/light/Move_tab.png)

#### XCUT-16 — Low — Tier 1 — Consistency & polish — Home gear button breaks the header-action pattern

- **What's unclear or slow:** Food, Move, Journal, Cycle and Friends place a 58pt cream, stroked pill/circle (`HeaderActionButton`) beside the title; Home's settings gear is a 44pt circle filled with 6% bark and no stroke, visibly lighter and smaller than its siblings.
- **Recommended change:** Replace the hand-rolled gear with `HeaderActionButton(systemImage: "gearshape")` (adding an accessibility label "Settings") so all six tab headers share one control.
- **Mockup needed:** No (code-only)
- **Evidence:** [Home_tab.png](design-refs/ux-review-2026-08-16/shots/light/Home_tab.png) · [Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) · [Move_tab.png](design-refs/ux-review-2026-08-16/shots/light/Move_tab.png) · [Friends_tab.png](design-refs/ux-review-2026-08-16/shots/light/Friends_tab.png) · [Private--Journal.png](design-refs/ux-review-2026-08-16/shots/light/Private--Journal.png) — `App/Fernlet/HomeView.swift:309-324`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:139-175`, `App/Fernlet/ConnectView.swift:234-244`
- **Note:** low severity — not independently verified.

### Home: root

**Current:** ![Home_tab.png](design-refs/ux-review-2026-08-16/shots/light/Home_tab.png) ![04-home-scrolled-3.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/04-home-scrolled-3.png)

#### HOME-23 — Low — Tier 2 — Daily-use speed — Horizontal drags on Home content page-swipe to another tab

- **What's unclear or slow:** The root TabView uses .page style, so any horizontal drag that is not captured by an inner scroller switches tabs; the polaroid strip has hit-testing disabled (drags there always page), and the mood-chip and Recent-bites rows are horizontal scrollers competing with paging. The walker switched Home→Food by accident on the strip.
- **Recommended change:** Decide deliberately whether horizontal tab paging is wanted; if not, .scrollDisabled(true) on the TabView and rely on tab-bar taps. Making the strip hit-testable is not a fix — a non-scrolling view still lets the pager take the drag.
- **Mockup needed:** No (code-only)
- **Evidence:** [Home_tab.png](design-refs/ux-review-2026-08-16/shots/light/Home_tab.png) · [04-home-scrolled-3.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/04-home-scrolled-3.png) — `App/Fernlet/ContentView.swift:554-591`, `App/Fernlet/HomeView.swift:326-363`, `App/Fernlet/QuickMoodRow.swift:41-74`

#### HOME-34 — Low — Tier 1 — Accessibility — Thought bubble truncates and captions collide at AX sizes

- **What's unclear or slow:** The strip is a fixed 132pt frame with tiles positioned by width fraction; at accessibility-extra-large the bubble text is cut to 'Keep t…' and the four captions overlap into 'brigh good note morning'.
- **Recommended change:** Scale the strip height with @ScaledMetric, allow the bubble up to 3 lines with minimumScaleFactor, and hide captions (or show only the front tile's) above accessibility1.
- **Mockup needed:** No (code-only)
- **Evidence:** [Home_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Home_tab.png) — `App/Fernlet/HomeView.swift:326-363`, `App/Fernlet/HomeView.swift:1930-1943`
- **Note:** low severity — not independently verified.

#### FLOW-18 — Low — Tier 2 — Daily-use speed — Half the Quick log grid sits below the fold on cold open

- **What's unclear or slow:** On a 6.1-inch device the second row of quick-log tiles (Sleep, Journal, Care) is hidden behind the floating tab bar on cold open; the polaroid strip, companion and Today card consume the first screen, so three of the six daily actions need a scroll first.
- **Recommended change:** Tighten the vertical rhythm above the grid (shorter polaroid strip, less Today-card top padding, tile minHeight 66 -> 56) so all six tiles clear the tab bar on a 6.1-inch device with the companion still centred; do not reorder widgets, and leave the user's Layout & shortcuts order authoritative.
- **Mockup needed:** Yes
- **Evidence:** [Home_tab.png](design-refs/ux-review-2026-08-16/shots/light/Home_tab.png) · [01-home-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/01-home-top.png) — `App/Fernlet/HomeView.swift:919-935`, `App/Fernlet/HomeView.swift:2077`, `App/Fernlet/ContentView.swift:608-651`

### Care sheet

**Current:** ![02-home-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/02-home-scrolled-1.png) ![28-quicklog-care-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/28-quicklog-care-sheet.png)

#### HOME-26 — Low — Tier 1 — Clarity — One feature named Care, Personal care and Hygiene

- **What's unclear or slow:** The quick-log tile says 'Care', the sheet it opens is titled 'Personal care', and the Home widget/card and settings row for the same tasks say 'Hygiene'.
- **Recommended change:** Use 'Care' (or 'Personal care') everywhere: tile, sheet title, HygieneCard SectionLabel and the HomeWidget title.
- **Mockup needed:** No (code-only)
- **Evidence:** [02-home-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/02-home-scrolled-1.png) · [28-quicklog-care-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/28-quicklog-care-sheet.png) — `FernletKit/Sources/FernletDomainModel/NavigationEnums.swift:120`, `FernletKit/Sources/FernletDomainModel/NavigationEnums.swift:204`, `App/Fernlet/SharedSheets.swift:258`, `App/Fernlet/HomeView.swift:2175`
- **Note:** low severity — not independently verified.

### Customize sheet

**Current:** ![06-home-companion-longpress.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/06-home-companion-longpress.png) ![33-milestones-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/33-milestones-top.png)

#### HOME-31 — Low — Tier 1 — Consistency & polish — Duplicated titles: 'Fernlet' + 'Customize', 'Milestones' ×3

- **What's unclear or slow:** The customization sheet's nav title is 'Fernlet' with a second in-body header 'Customize'; the Milestones page shows the nav title 'Milestones', an eyebrow 'MILESTONES' and the heading 'All of it, added up' stacked.
- **Recommended change:** Nav title 'Customize' and drop the in-body header; on Milestones drop the eyebrow (keep it as the a11y anchor with opacity 0 if tests need it).
- **Mockup needed:** No (code-only)
- **Evidence:** [06-home-companion-longpress.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/06-home-companion-longpress.png) · [33-milestones-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/33-milestones-top.png) — `App/Fernlet/HomeView.swift:1145-1191`, `App/Fernlet/MilestonesView.swift:34-68`
- **Note:** low severity — not independently verified.

#### HOME-32 — Low — Tier 1 — Clarity — All four body shapes share the same 'seal' icon

- **What's unclear or slow:** Circle, Soft, Pear and Puddle each show an identical seal glyph, so the icons carry no information; the live preview above is the only cue.
- **Recommended change:** Use per-shape glyphs (circle, oval, drop, a squashed ellipse) or drop the icons and enlarge the labels.
- **Mockup needed:** No (code-only)
- **Evidence:** [08-customize-body-picker.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/08-customize-body-picker.png) — `App/Fernlet/HomeView.swift:1204-1231`
- **Note:** low severity — not independently verified.

## Food

Food is the busiest surface and the one with the most avoidable friction: logging always throws you back to Home, partial matches auto-commit without review, and deleting a meal takes one tap with no confirmation and no undo. The recipe area works but is presented two different ways depending on where you entered it.

### Meal sheet

**Current:** ![44-meal-after-save-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/44-meal-after-save-1.png) ![53-meal-recent-picked.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/53-meal-recent-picked.png) ![45-food-after-meal-logged.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/45-food-after-meal-logged.png)

#### FOOD-01 — High — Tier 1 — Daily-use speed — Saving a meal always jumps the app to the Home tab

- **What's unclear or slow:** After typing a meal in the Food tab's '+ meal' sheet and tapping Save (or picking a Recent item), the app switches to Home. The user has to tap Food again to see the row they just logged and check the match. The toast is the only feedback and it is shown on Home even when the log started on Food.
- **Recommended change:** Drop the `selectedTab = .home` line: keep the user on whatever tab they logged from and show the MealLogNotification toast over that tab. When the log started on Food, additionally scroll the new row into view (or briefly highlight it) so the match can be checked in one glance.
- **Mockup needed:** No (code-only)
- **Evidence:** [44-meal-after-save-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/44-meal-after-save-1.png) · [53-meal-recent-picked.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/53-meal-recent-picked.png) · [45-food-after-meal-logged.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/45-food-after-meal-logged.png) — `App/Fernlet/ContentView.swift:1119-1123 (showMealLogNotification sets selectedTab = .home unconditionally)`, `App/Fernlet/ContentView.swift:675-677 (MealSheet onLogged: showMealLogNotification)`, `App/Fernlet/FoodView.swift:2306-2314 (resolveTypedMeal -> onLogged -> dismiss)`
- **Also reported as:** FLOW-01

#### FOOD-06 — High — Tier 1 — Daily-use speed — Recent re-log keeps the old meal type and note

- **What's unclear or slow:** Picking 'Greek yogurt with berries' from Recent at 7:35 PM filed it under Breakfast with the seed note 'Seeded demo meal.' - copyForToday keeps the source mealType and note and ignores both the current time and the sheet's Meal type chips. The Food tab then shows two Breakfast rows (one with photo, one without, misaligned titles).
- **Recommended change:** When repeating a meal, set mealType to the sheet's selection when one is chosen, otherwise MealParser.classifyMealType-by-time (same 'Auto' rule as typed logs), clear the carried note, and stamp confidence 'Repeated'.
- **Mockup needed:** No (code-only)
- **Evidence:** [53-meal-recent-picked.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/53-meal-recent-picked.png) · [106-food-after-recent-repeat.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/106-food-after-recent-repeat.png) — `App/Fernlet/FoodView.swift:2204-2218 (recentMealsMenu -> store.copyMeal(meal))`, `FernletKit/Sources/DiaryStore/DiaryStore.swift:669-675 (copyMeal appends copyForToday())`, `FernletKit/Sources/FernletDomainModel/NutritionModels.swift:282-288 (copyForToday keeps mealType/note)`

#### FOOD-04 — High — Tier 1 — Clarity — Partial matches auto-log as 'Food match'; eggs silently dropped

- **What's unclear or slow:** '2 eggs and toast' logged immediately as 'Toast - 1 serving French toast sticks - P 3g' with no review step. The deterministic plan drops every split item it cannot bind and still returns confidence .high as long as one item bound, so the review sheet only appears for the keyword fallback or an implausible calorie total. A daily user gets a confident-looking wrong meal and only finds out by reading the row.
- **Recommended change:** Make coverage part of the confidence: when the plan bound fewer items than MealItemSplitter produced (or the bound name shares no token with the typed item), return .medium and set needsReview so the 'Check this meal' sheet opens with the unmatched words shown as a chip ("Couldn't find: 2 eggs - Add"). Full-coverage matches keep logging instantly.
- **Mockup needed:** No (code-only)
- **Evidence:** [43-meal-sheet-typed.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/43-meal-sheet-typed.png) · [46-food-new-row.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/46-food-new-row.png) — `FernletKit/Sources/AIProviders/FoundationFoodSelection.swift:106-118 (deterministicPlan compactMaps unbound items away, returns a plan)`, `App/Fernlet/MealResolutionService.swift:153-158 + 169-180 (plan -> confidence .high)`, `FernletKit/Sources/FernletDomainModel/NutritionModels.swift:374 + 456 (needsReview only when .low or fallback)`, `App/Fernlet/FoodView.swift:2295-2305 (needsReview gate in resolveTypedMeal)`
- **Also reported as:** FLOW-14

#### FOOD-08 — Medium — Tier 1 — Daily-use speed — Meal type hidden at half height; sheet has no Cancel

- **What's unclear or slow:** The sheet opens at .medium showing the field, Capture and the Scan/Recent/Import row; the Meal type chips only appear after dragging to full height (at AX sizes only the field and half of Capture are visible). There is no Cancel/close control anywhere - dismissal is grabber-only, and the walker noted the drag had to start exactly on the grabber.
- **Recommended change:** Put a compact meal-type control on the same line as the 'What did you eat?' caption (a small 'Auto v' menu or the chip row directly under the field, above Capture), so type + meal type + Save all fit at .medium. Add SheetCancelBar at the top of the sheet.
- **Mockup needed:** Yes
- **Evidence:** [Sheet--Meal.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Meal.png) · [60-meal-sheet-full-height.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/60-meal-sheet-full-height.png) · [Sheet--Meal.png](design-refs/ux-review-2026-08-16/shots/ax/Sheet--Meal.png) — `App/Fernlet/ContentView.swift:675-677 (detents [.medium, .large])`, `App/Fernlet/FoodView.swift:2117-2149 (order: photo, field, capture buttons, mealTypeChips, notice)`, `App/Fernlet/FoodView.swift:2221-2232 (mealTypeChips FlowLayout)`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:300-320 (SheetCancelBar exists, unused here)`
- **Also reported as:** FLOW-13

#### FOOD-07 — Medium — Tier 1 — Consistency & polish — Recent list has duplicates and shows names only

- **What's unclear or slow:** The Recent popup lists 'Apple and almonds', 'Chicken rice bowl', 'Greek yogurt with berries' twice each (every log inserts into recentMeals, nothing dedupes) and shows no macros, so identical names can't be told apart. It's also a hidden popup - the fastest re-log path is behind a tap.
- **Recommended change:** Dedupe by case-folded name (newest wins) before taking the top 8; render Recent as a horizontally scrolling chip row directly under the text field (name + 'P 28g') so a repeat is one visible tap; keep the Menu only if the row is empty.
- **Mockup needed:** Yes
- **Evidence:** [52-meal-recent.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/52-meal-recent.png) — `FernletKit/Sources/DiaryStore/DiaryStore.swift:656-664 (appendMeal inserts every meal, prefix(50), no dedupe)`, `App/Fernlet/FoodView.swift:2206-2213 (Menu of store.recentMeals.prefix(8), name-only Buttons)`
- **Also reported as:** FLOW-12

#### FLOW-15 — Medium — Tier 1 — Daily-use speed — 'Logged' toast is not actionable: no Undo or Adjust

- **What's unclear or slow:** After Save the only feedback is a 3-second card with the name and macros; it cannot be tapped. To fix or remove the meal the user must open Food, find the row, and hit the small 'Looks off?' or X.
- **Recommended change:** Add 'Adjust' and 'Undo' buttons to MealLogNotificationView (5-second window); Adjust opens MealCorrectionSheet for the just-logged meal, Undo removes it.
- **Mockup needed:** Yes
- **Evidence:** [44-meal-after-save-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/44-meal-after-save-1.png) · [47-food-looks-off-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/47-food-looks-off-sheet.png) — `App/Fernlet/ContentView.swift:1119-1137`, `App/Fernlet/ContentView.swift:1302-1336`

#### FOOD-25 — Medium — Tier 1 — Clarity — Import shown while web lookup is off; jargon dead-end

- **What's unclear or slow:** The Import button is always offered; with AI set to Manual/off the page accepts input, then answers 'Turn off Manual off mode before using web nutrition lookup.' - a double negative naming a mode the user may not recognise. The field placeholder also auto-renders its example URL as a blue link.
- **Recommended change:** Hide (or grey with a one-line reason) the Import button when !store.allowsWebNutritionLookup; reword the notice to 'Web nutrition lookup is off. Turn on AI features and Web nutrition lookup in Settings to search the web.'; use a plain placeholder such as 'Product name or paste a page link'.
- **Mockup needed:** No (code-only)
- **Evidence:** [61-meal-import.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/61-meal-import.png) · [62-meal-import-find.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/62-meal-import-find.png) — `App/Fernlet/FoodView.swift:2185-2192 (Import always in the secondary row)`, `App/Fernlet/FoodView.swift:2730-2734 (webNutritionLookupDisabledMessage copy)`, `App/Fernlet/FoodView.swift:2762-2766 (loadPreview guard)`, `App/Fernlet/FoodView.swift:2713-2717 (placeholder with https://example.com/product)`

#### FOOD-09 — Low — Tier 1 — Daily-use speed — Return inserts a newline instead of saving the meal

- **What's unclear or slow:** The description box is a multi-line TextEditor; pressing Return adds a line break. For a one-line log ('2 eggs and toast') the natural 'type - return' rhythm does nothing, and the user must reach for the Save pill.
- **Recommended change:** Use TextField(axis: .vertical) with .lineLimit(1...4), .submitLabel(.done) and .onSubmit { if canSave { saveTapped() } } for the meal description; keep the same cream card styling.
- **Mockup needed:** No (code-only)
- **Evidence:** [43-meal-sheet-typed.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/43-meal-sheet-typed.png) — `App/Fernlet/FoodView.swift:2127-2129 (SheetTextEditor for description)`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:436-472 (SheetTextEditor wraps TextEditor, no submit handling)`
- **Note:** low severity — not independently verified.

### Food tab root

**Current:** ![49-food-row-x-deleted-no-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/49-food-row-x-deleted-no-confirm.png) ![Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png)

#### FOOD-02 — High — Tier 1 — Daily-use speed — Meal row X deletes instantly, no confirmation, no undo

- **What's unclear or slow:** Tapping the X on any meal card removes it (and its sealed photo) immediately with no confirmation and no undo. This is the only instant destructive action in the food surface: deleting the recipe *photo* on the detail page gets a confirmation dialog, but deleting a whole meal does not. Violates the nothing-destructive-happens-silently invariant.
- **Recommended change:** Route the X through the shared .destructiveConfirmation ('Remove this meal?' / Remove) as RecipeDetailView already does for the photo; an Undo toast may be added on top but must not replace the confirmation.
- **Mockup needed:** No (code-only)
- **Evidence:** [49-food-row-x-deleted-no-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/49-food-row-x-deleted-no-confirm.png) · [Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) — `App/Fernlet/FoodView.swift:3014-3020 (Button(role: .destructive, action: onDelete) with no confirmation)`, `App/Fernlet/FernletStore.swift:2118-2129 (deleteMeal removes the meal and its photo)`, `App/Fernlet/FoodView.swift:4312-4319 (recipe photo delete uses DestructiveConfirmation - the pattern to reuse)`

#### FOOD-15 — Medium — Tier 1 — Clarity — Row body inert; 'Looks off?' is a tiny wrapping text link

- **What's unclear or slow:** Tapping a meal card does nothing; the only entry to Adjust is the small green 'Looks off?' text at the row's trailing edge, which wraps to two lines whenever the row has a photo (walker needed two taps). The goldenrod tag beside the macros ('Logged', 'Food match', 'Recipe') is jargon in a low-contrast colour and reads like a status the user must interpret.
- **Recommended change:** Make the whole MealRow a button that opens Adjust meal, and replace 'Looks off?' with a right-aligned 'Adjust' label plus chevron in a 44pt frame. Move the confidence into a quiet slate capsule with plain words ('Estimated', 'Reviewed', 'From recipe') and drop it entirely for seeded 'Logged'.
- **Mockup needed:** Yes
- **Evidence:** [Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) · [46-food-new-row.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/46-food-new-row.png) · [47-food-looks-off-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/47-food-looks-off-sheet.png) — `App/Fernlet/FoodView.swift:2973-2989 (MealRow body has no tap action)`, `App/Fernlet/FoodView.swift:3036-3050 (macrosRow: confidence in goldenrod, 'Looks off?' plain text button, no min frame)`
- **Also reported as:** FLOW-16

#### FOOD-16 — Low — Tier 1 — Clarity — Unlabelled 'P 28g' subtotal repeats single-row protein

- **What's unclear or slow:** Every meal-type card ends with a right-aligned 'P 28g' line. For the common single-meal section it repeats the row's own protein directly beneath 'P 28g' with no label, so it reads as a duplicated/orphaned value.
- **Recommended change:** Render the subtotal only when the group has two or more meals, and label it ('Breakfast total P 56g').
- **Mockup needed:** No (code-only)
- **Evidence:** [Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) · [106-food-after-recent-repeat.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/106-food-after-recent-repeat.png) — `App/Fernlet/FoodView.swift:376-390 (mealTypeSubtotal always rendered)`
- **Note:** low severity — not independently verified.

#### FOOD-18 — Low — Tier 2 — Daily-use speed — Macros card is inert; no path to nutrition targets

- **What's unclear or slow:** The card shows 'of 93g / of 372g / of 88g' targets but is not tappable; the targets editor lives only under Settings > Goal & nutrition. A user who wants to nudge a target from the Food tab has to leave and hunt for it (walker could not find it).
- **Recommended change:** Add a small 'Targets' link in the MACROS TODAY header row (or make the card tappable) that presents NutritionTargetsEditor in a sheet from Food.
- **Mockup needed:** No (code-only)
- **Evidence:** [Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) — `App/Fernlet/FoodView.swift:52 (MacroCard, no action)`, `App/Fernlet/NutritionTargetsEditor.swift:10-20 (editor is a Settings card)`

#### FOOD-30 — Low — Tier 1 — Clarity — Recipe logs read 'Matched from local foods.'

- **What's unclear or slow:** A meal logged from a recipe or cooking mode shows the note 'Matched from local foods.' with a 'Recipe' tag - the note is set for any meal with component snapshots, so recipe logs get the food-matching wording.
- **Recommended change:** Branch on meal.mealSource: `.recipe` -> 'From your recipe', `.manual` with components -> 'Matched from your foods', else the stored note.
- **Mockup needed:** No (code-only)
- **Evidence:** [120-food-after-cooking-log.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/120-food-after-cooking-log.png) — `App/Fernlet/FoodView.swift:3052-3054 (displayNote returns 'Matched from local foods.' whenever breakdownText != nil)`
- **Note:** low severity — not independently verified.

### Adjust meal sheet

**Current:** ![47-food-looks-off-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/47-food-looks-off-sheet.png) ![48-food-adjust-meal-full.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/48-food-adjust-meal-full.png)

#### FOOD-05 — Medium — Tier 1 — Daily-use speed — Adjust meal can't add, remove or replace matched items

- **What's unclear or slow:** The correction sheet only lets the user rename, retype and re-quantify the items the resolver picked. When the match is wrong ('French toast sticks' for toast, eggs missing) the only fix is delete the row and re-log. The quantity box also looks like static text ('1 serving'), so the stepper reads as the only control.
- **Recommended change:** In 'Matched items' add an 'Add item' row that opens the same debounced catalog typeahead used by the recipe editor (suggestion row with source badge + macros), and a small x on each item to remove it; recompute totals via MealBuilder.totals as today. Style the Qty box like a field (cream fill, underline as in MacroInputRow).
- **Mockup needed:** Yes
- **Evidence:** [47-food-looks-off-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/47-food-looks-off-sheet.png) · [48-food-adjust-meal-full.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/48-food-adjust-meal-full.png) — `App/Fernlet/FoodView.swift:3162-3170 (only Macros or Matched items editors)`, `App/Fernlet/FoodView.swift:3223-3275 (MealComponentEditorRows: quantity only, no add/remove)`, `App/Fernlet/FoodView.swift:3236-3247 (unstyled Qty TextField)`

#### FOOD-20 — Medium — Tier 1 — Daily-use speed — Adjust meal opens at half height, hiding matched items

- **What's unclear or slow:** The sheet opens at .medium with name and type chips first; the 'Matched items' editor - the thing the user came to fix - is clipped behind the Save correction pill until they drag up.
- **Recommended change:** Present the correction sheet at .large only (as Edit recipe is), or reorder so 'Matched items' comes directly under the meal name and the type chips move below.
- **Mockup needed:** No (code-only)
- **Evidence:** [47-food-looks-off-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/47-food-looks-off-sheet.png) · [48-food-adjust-meal-full.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/48-food-adjust-meal-full.png) — `App/Fernlet/FoodView.swift:304-308 (MealCorrectionSheet detents [.medium, .large])`, `App/Fernlet/FoodView.swift:3140-3175 (content order: name, type, macros/items)`

### Recipe detail

**Current:** ![65-recipe-detail-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/65-recipe-detail-top.png) ![112-recipe-detail-pushed-from-food.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/112-recipe-detail-pushed-from-food.png) ![69-recipe-edit-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/69-recipe-edit-top.png)

#### FOOD-11 — Medium — Tier 2 — Consistency & polish — Recipe detail lives in two containers; Edit drops the book

- **What's unclear or slow:** From the Food card the detail is a pushed page with the tab bar; from the Recipe book it is a page inside a full-height sheet. Tapping Edit from the book dismisses the whole book before presenting the editor, so after Save the user lands on the Food root instead of back on the recipe. From the pushed detail the editor returns to the detail.
- **Recommended change:** Make the recipe book a pushed page in the Food NavigationStack (the 'Recipe book' link and the Home shortcut both push it), so book -> detail -> editor is one stack: the editor presents as a sheet over the detail and dismisses back to it. Keep the Home .recipeBook sheet only as a shortcut that switches to Food and pushes.
- **Mockup needed:** No (code-only)
- **Evidence:** [65-recipe-detail-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/65-recipe-detail-top.png) · [112-recipe-detail-pushed-from-food.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/112-recipe-detail-pushed-from-food.png) · [69-recipe-edit-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/69-recipe-edit-top.png) — `App/Fernlet/FoodView.swift:216-224 (NavigationLink push from Food root)`, `App/Fernlet/FoodView.swift:310-315 (RecipeBookSheet presented as .large sheet)`, `App/Fernlet/FoodView.swift:4687-4692 + 4719-4723 (book row push; onEdit: beginEditing + dismiss())`

#### FOOD-14 — Medium — Tier 1 — Consistency & polish — Meal-type Menus flip order and give no feedback after logging

- **What's unclear or slow:** 'Log this recipe', the cooking finish 'Log this meal' and the fork icon on recipe cards all open a Menu of six meal types; anchored at the bottom the list renders reversed (Post-workout first) versus Breakfast-first higher up. After choosing, nothing visible happens - no toast, no navigation - because these paths call store.logRecipe directly and never reach the MealLogNotification path the meal sheet uses.
- **Recommended change:** Replace the Menus with the shared ChipButtonStyle meal-type row (Auto preselected by time of day) plus one 'Log' button - same control as the meal sheet - and route the log through the same onLogged toast ('Overnight oats logged - P 16g'). On the recipe cards, make the fork a labelled 'Log' pill that opens that row inline.
- **Mockup needed:** Yes
- **Evidence:** [117-cooking-log-this-meal.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/117-cooking-log-this-meal.png) · [119-recipe-log-this-recipe.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/119-recipe-log-this-recipe.png) · [118-cooking-logged-result.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/118-cooking-logged-result.png) · [75-food-recipe-fork-icon.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/75-food-recipe-fork-icon.png) — `App/Fernlet/FoodView.swift:4194-4209 (Log this recipe Menu)`, `App/Fernlet/CookingMode.swift:572-594 (finish screen Menu)`, `App/Fernlet/FoodView.swift:4503-4523 (RecipeMealTypeMenu fork icon)`, `App/Fernlet/FoodView.swift:271-278 (logRecipe writes to store, no onLogged/toast)`

#### FOOD-22 — Medium — Tier 1 — Clarity — Recipe detail never shows the recipe's steps

- **What's unclear or slow:** After adding a step in Edit recipe and saving, the detail page shows photo, macros, cook-for, ingredients, notes and actions - but no Steps section. The only way to read the steps is to start cooking mode.
- **Recommended change:** Add a 'Steps' FernletCard below Ingredients listing numbered steps (with the timer minutes when set); keep 'Cook' as the hands-free walker.
- **Mockup needed:** Yes
- **Evidence:** [114-recipe-detail-after-edit-save.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/114-recipe-detail-after-edit-save.png) · [115-cooking-mode-step-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/115-cooking-mode-step-1.png) — `App/Fernlet/FoodView.swift:3835-3849 (detailScroll sections; no steps card)`, `App/Fernlet/FoodView.swift:1326-1337 (steps are editable in RecipeSheet)`

#### FOOD-29 — Low — Tier 1 — Consistency & polish — Cards hug content, swap icons misaligned, share title truncates

- **What's unclear or slow:** The mise-en-place Ingredients card and the recipe-detail Notes card are narrower than their siblings (FernletCard hugs content when nothing inside stretches). Swap icons sit visibly below each ingredient's text baseline (top-aligned row with a 44pt icon frame). The share sheet header truncates 'Sheet pan chicken and vegetab...' because ScreenHeader is lineLimit(1).
- **Recommended change:** Give the two card bodies `.frame(maxWidth: .infinity, alignment: .leading)`; centre-align the ingredient row (or top-align the icon with `.padding(.top, -6)`); let ScreenHeader take a `titleLineLimit` (2 for dynamic recipe names).
- **Mockup needed:** No (code-only)
- **Evidence:** [102-cooking-mode-start.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/102-cooking-mode-start.png) · [66-recipe-detail-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/66-recipe-detail-scrolled.png) · [77-food-recipe-share-full.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/77-food-recipe-share-full.png) — `App/Fernlet/CookingMode.swift:337-342 (Ingredients FernletCard, no maxWidth)`, `App/Fernlet/FoodView.swift:4182-4192 (notesCard, no maxWidth)`, `App/Fernlet/FoodView.swift:4153-4179 (HStack(alignment: .top) + 44pt swap frame)`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:109-116 (ScreenHeader lineLimit(1))`, `App/Fernlet/Proximity/UI/ProximityRecipeShareSheet.swift:56-57 (ScreenHeader(title: draft.title))`
- **Note:** low severity — not independently verified.

### Recipe editor sheet

**Current:** ![69-recipe-edit-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/69-recipe-edit-top.png) ![70-recipe-edit-ingredients.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/70-recipe-edit-ingredients.png)

#### FOOD-12 — Medium — Tier 1 — Daily-use speed — Edit recipe opens with the first ingredient's search expanded

- **What's unclear or slow:** Every time an existing recipe is edited the first ingredient row is expanded into the search editor (pre-filled 'Rolled oats' with catalog results), pushing the ingredient list, servings and steps below the fold. The user must tap Done before they can see what they came to edit.
- **Recommended change:** In edit mode initialise expandedId to nil (only blank rows auto-expand); the collapsed rows already re-expand on tap.
- **Mockup needed:** No (code-only)
- **Evidence:** [69-recipe-edit-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/69-recipe-edit-top.png) · [70-recipe-edit-ingredients.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/70-recipe-edit-ingredients.png) — `App/Fernlet/FoodView.swift:1039-1051 (_expandedId = loadedIngredients.first?.id in edit mode)`, `App/Fernlet/FoodView.swift:1122-1123 (row renders expanded when expandedId matches or name is empty)`

#### FOOD-31 — Medium — Tier 1 — Clarity — Ingredient X sits beside Done and looks like 'close search'

- **What's unclear or slow:** In the expanded ingredient editor the trailing controls are 'Done' then an X. The X removes the whole ingredient (no confirmation), but positioned next to the search field it reads as 'clear/close search'. One mis-tap while looking for a way out of the results list deletes the row.
- **Recommended change:** Keep only Done in the expanded header; expose Remove as a labelled 'Remove' text button at the bottom of the expanded card (and keep the X only on collapsed rows with an accessibilityLabel).
- **Mockup needed:** No (code-only)
- **Evidence:** [69-recipe-edit-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/69-recipe-edit-top.png) — `App/Fernlet/FoodView.swift:1602-1625 (searchHeaderRow: Done + xmark remove side by side)`

#### FOOD-34 — Medium — Tier 1 — Daily-use speed — Step text loses and reorders characters while typing

- **What's unclear or slow:** Typing 'Mix oats and yogurt' into Step 1 produced 'Mix oats ad\| yogurtn' on screen with the caret jumped mid-word, and the saved step read 'Mix oats an'. The step editor binds a TextEditor through a by-id computed Binding into the @State steps array inside ForEach, a pattern known to reset the caret when the array is rewritten each keystroke. Needs a device repro to rule out automation artefacts.
- **Recommended change:** Iterate with `ForEach($steps) { $step in ... SheetTextEditor(text: $step.text) }` so each editor keeps a stable element binding, and compute the display index separately; verify caret stability on device.
- **Mockup needed:** No (code-only)
- **Evidence:** [113-recipe-edit-step-typed.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/113-recipe-edit-step-typed.png) · [115-cooking-mode-step-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/115-cooking-mode-step-1.png) — `App/Fernlet/FoodView.swift:1341-1366 (stepEditorCard with SheetTextEditor(text: bindingForStepText))`, `App/Fernlet/FoodView.swift:1413-1421 (computed by-id Binding writing steps[i].text)`

### Recipe book

**Current:** ![Sheet--Recipe_book.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Recipe_book.png) ![41-food-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/41-food-scrolled-1.png)

#### FOOD-19 — Medium — Tier 1 — Consistency & polish — Book rows differ from Food-root rows; no close, no section labels

- **What's unclear or slow:** In the book the fork/share icons sit beside the row, so '2 servings' lands ~65% across and reads centred; on the Food root the same rows were reworked to put controls on their own trailing line (comment in code explains why). Manual and saved recipes are two unlabelled cards while products get an 'Imported products' header. The full-height sheet has no Done/close control.
- **Recommended change:** Reuse the Food-root card layout in the book (summary above, controls on a trailing line), add SectionLabels 'Your recipes' / 'Saved from web' / 'Imported products', and put a 'Done' text button top-right of the header.
- **Mockup needed:** Yes
- **Evidence:** [Sheet--Recipe_book.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Recipe_book.png) · [41-food-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/41-food-scrolled-1.png) — `App/Fernlet/FoodView.swift:4681-4707 (recipeRow HStack with trailing controls)`, `App/Fernlet/FoodView.swift:203-241 (recentRecipeCard - controls on their own line, with rationale)`, `App/Fernlet/FoodView.swift:4583-4613 (no close affordance, cards without headers)`

#### FOOD-32 — Medium — Tier 1 — Daily-use speed — Saving a new recipe pops back to the Create-recipe chooser

- **What's unclear or slow:** Manual entry and Import recipe are pushed inside the book's NavigationStack; on Save/Log & save/Import they call dismiss(), which in a pushed view pops one level - landing the user on the 'Import recipe / Manual entry' chooser rather than on the new recipe or the book. Not walked to completion; inferred from the embedded dismiss path.
- **Recommended change:** Give the embedded editor/import an onSaved closure that pops the book path to root (or pushes the new recipe's RecipeDetailView) instead of a bare dismiss(); show the 'added to your recipes' toast on the book.
- **Mockup needed:** No (code-only)
- **Evidence:** [80-create-recipe-options.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/80-create-recipe-options.png) · [84-new-recipe-manual-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/84-new-recipe-manual-top.png) — `App/Fernlet/FoodView.swift:1233-1266 (saveBar/createButtons -> dismiss())`, `App/Fernlet/FoodView.swift:1054-1063 (isEmbeddedInNavigationStack renders without its own stack)`, `App/Fernlet/FoodView.swift:4410-4430 (NavigationLink pushes RecipeSheet/RecipeImportSheet)`, `App/Fernlet/FoodView.swift:621-630 + 741-749 (RecipeImportSheet dismiss on success)`

#### FOOD-33 — Low — Tier 1 — Consistency & polish — Pushed pages mix in-body titles with empty navigation bars

- **What's unclear or slow:** 'Import product', 'New recipe' (from the book), 'Recipe book', 'Meal planner' and 'Shopping list' draw their title in the body under an empty nav bar (about 90pt of blank space beneath the back chevron), while 'Scan a food', 'Remember product', 'Scan label' and 'Recipe' use inline nav-bar titles. Two title systems within one flow.
- **Recommended change:** For pushed pages use `.navigationTitle(...)` inline and suppress the body title when isEmbeddedInNavigationStack; keep the display-serif body title only for sheets that have no nav bar.
- **Mockup needed:** No (code-only)
- **Evidence:** [61-meal-import.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/61-meal-import.png) · [84-new-recipe-manual-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/84-new-recipe-manual-top.png) · [55-meal-scan-full.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/55-meal-scan-full.png) · [56-meal-scan-by-hand.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/56-meal-scan-by-hand.png) — `App/Fernlet/FoodView.swift:2627-2629 (Import product body title)`, `App/Fernlet/FoodView.swift:1069-1071 (New/Edit recipe body title, also when embedded)`, `App/Fernlet/BarcodeScanView.swift:105 + 674 (inline navigation titles)`, `App/Fernlet/FoodView.swift:3851-3852 (Recipe inline title)`
- **Note:** low severity — not independently verified.

### Cooking mode

**Current:** ![115-cooking-mode-step-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/115-cooking-mode-step-1.png) ![102-cooking-mode-start.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/102-cooking-mode-start.png) ![29-runner-close-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/29-runner-close-confirm.png)

#### FOOD-21 — Medium — Tier 1 — Consistency & polish — Cooking Close and Discard end the run with no confirmation

- **What's unclear or slow:** The header 'Close' during a walk (and 'Discard' on the Food-root Cooking-in-progress card) ends the run, clears the Live Activity and dismisses on one tap. The Move tab's workout runner asks before closing mid-session.
- **Recommended change:** When stage == .cooking (or from the resume card) show a confirmationDialog 'Stop cooking Overnight oats? / Stop cooking (destructive) / Keep cooking'; mise en place and the finish screen can close directly.
- **Mockup needed:** No (code-only)
- **Evidence:** [115-cooking-mode-step-1.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/115-cooking-mode-step-1.png) · [102-cooking-mode-start.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/102-cooking-mode-start.png) · [29-runner-close-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/29-runner-close-confirm.png) — `App/Fernlet/CookingMode.swift:264-282 (header Close -> closeCooking)`, `App/Fernlet/CookingMode.swift:668-673 (closeCooking: endCookingRun + dismiss)`, `App/Fernlet/FoodView.swift:80-89 (CookingResumeCard onDiscard: store.endCookingRun())`

### Swap ingredient sheet

**Current:** ![67-recipe-substitution-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/67-recipe-substitution-sheet.png) ![69-recipe-edit-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/69-recipe-edit-top.png)

#### FOOD-23 — Medium — Tier 1 — Consistency & polish — Swap results are name-only; duplicates indistinguishable

- **What's unclear or slow:** 'Rolled oats', 'Rolled Oats', 'Rolled Oats' appear as three bare rows with no source badge, serving or macros, plus unrelated hits (lamb, ice-cream cones). The recipe editor's typeahead for the same catalog shows name + source badge + '30 g - P13g C68g F6g', so the two pickers disagree and the swap one can't be chosen from confidently.
- **Recommended change:** Render swap candidates with the same suggestion row (name, dataSourceLabel badge, serving and P/C/F line) and collapse exact-duplicate name+source rows.
- **Mockup needed:** No (code-only)
- **Evidence:** [67-recipe-substitution-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/67-recipe-substitution-sheet.png) · [69-recipe-edit-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/69-recipe-edit-top.png) — `App/Fernlet/IngredientSubstitutionSheet.swift:159-180 (substituteRow: name + optional reason only)`, `App/Fernlet/FoodView.swift:1638-1667 (RecipeIngredientEditor.suggestionRow with badge + macros)`

### Scan a food

**Current:** ![56-meal-scan-by-hand.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/56-meal-scan-by-hand.png)

#### FOOD-24 — Medium — Tier 1 — Clarity — 'Enter details by hand' offers no way to type macros

- **What's unclear or slow:** The screen has a name field, a 'Scan the nutrition label (optional)' row and three read-only 0g rings; the only way to fill values is the label scanner. The footer says 'you can also add them later' but no later surface edits a remembered food's macros. Saving with 0g nudges 'No macros yet' but still can't take a number.
- **Recommended change:** Under the rings add three MacroInputRow fields (Protein/Carbs/Fat per serving) prefilled by a label scan and editable by hand; drop the 'add them later' line.
- **Mockup needed:** Yes
- **Evidence:** [56-meal-scan-by-hand.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/56-meal-scan-by-hand.png) — `App/Fernlet/BarcodeScanView.swift:765-795 (macroSection: MacroRingTile read-only)`, `App/Fernlet/BarcodeScanView.swift:810-833 (rememberFood uses scanResult only)`, `App/Fernlet/FoodView.swift:4335-4392 (MacroInputRow - the existing editable control)`

### Meal planner

**Current:** ![93-meal-planner-after-add.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/93-meal-planner-after-add.png) ![91-meal-planner-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/91-meal-planner-top.png)

#### FOOD-35 — Low — Tier 2 — Daily-use speed — Planned recipes can't be logged from the plan

- **What's unclear or slow:** The planner assigns recipes to days and feeds the shopping list, but today's planned rows have only a '-' remove control; when the day comes the user still has to find the recipe in the book to log it, and the Food root never surfaces 'planned for today'.
- **Recommended change:** On today's day card give each planned recipe a 'Log' pill (same meal-type chip + Log control), and show a small 'Planned today' card on the Food root above the meals with one-tap Log per recipe.
- **Mockup needed:** Yes
- **Evidence:** [93-meal-planner-after-add.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/93-meal-planner-after-add.png) · [91-meal-planner-top.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/91-meal-planner-top.png) — `App/Fernlet/GroceryPlannerView.swift:294-337 (dayCard rows: name + minus only)`
- **Note:** low severity — not independently verified.

## Move

Move's daily jobs — start today's workout, log what you did — are buried three sheets deep and ask you to type things the app already knows. Several of its confirmations show only the destructive button, and finishing a guided run strands you on an empty planning form.

### Move tab root

**Current:** ![01-move-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/01-move-top.png) ![11-week-today-detail.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/11-week-today-detail.png) ![12-day-plan-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/12-day-plan-sheet-top.png)

#### FLOW-03 — High — Tier 2 — Daily-use speed — Guided workout start is buried three sheets deep

- **What's unclear or slow:** On any day without an already-approved plan the Move root shows no start/suggest entry at all. To run a guided session the user must tap the today calendar cell (push) > Plan (sheet) > 'Suggest a workout' (second sheet over the first) > Suggest > Start now (third sheet over both) > Start: six taps and three stacked sheets. The header's second slot is spent on 'Share' (trainer export) instead.
- **Recommended change:** Always render the 'Today's workout' card on the Move root: with no plan it carries one primary button 'Suggest today's workout' that presents WorkoutSuggestionSheet directly from the root (one sheet), and once a plan exists it shows Start. Move 'Suggest a workout' out of the Plan sheet, and demote 'Share' from the header into the context strip or an overflow so the header reads Log \| Plan.
- **Mockup needed:** Yes
- **Evidence:** [01-move-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/01-move-top.png) · [11-week-today-detail.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/11-week-today-detail.png) · [12-day-plan-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/12-day-plan-sheet-top.png) · [16-suggest-workout-result.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/16-suggest-workout-result.png) · [25-runner-first-step.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/25-runner-first-step.png) · [81-empty-move-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/81-empty-move-top.png) — `App/Fernlet/MoveView.swift:41-53`, `App/Fernlet/MoveView.swift:107-123`, `App/Fernlet/MoveView.swift:130-138`, `App/Fernlet/MoveView.swift:2792-2804`, `App/Fernlet/MoveView.swift:3246-3253`, `App/Fernlet/MoveView.swift:3324-3333`, `App/Fernlet/MoveView.swift:1470-1484`
- **Also reported as:** MOVE-27

#### MOVE-04 — High — Tier 1 — Daily-use speed — Planned-workout Remove deletes instantly with no confirmation

- **What's unclear or slow:** PlannedWorkoutRow's 'Remove' calls `onDelete` straight into `store.deletePlannedWorkout` — no dialog, no undo — while the sibling logged-row Remove confirms first. A mis-tap on the small text button silently erases a plan (possibly a coach-imported one).
- **Recommended change:** Route planned-row Remove through the shared `.destructiveConfirmation` ('Remove this plan?' / 'It won't be logged — you can plan it again any time.'), matching WorkoutRow.
- **Mockup needed:** No (code-only)
- **Evidence:** [11-week-today-detail.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/11-week-today-detail.png) — `App/Fernlet/MoveView.swift:2926-2935`, `App/Fernlet/MoveView.swift:158-161`, `App/Fernlet/MoveView.swift:2726-2729`

#### MOVE-06 — Medium — Tier 1 — Clarity — GOAL segment truncates and disagrees with Suggest's Goal

- **What's unclear or slow:** After accepting crafted goals the strip reads 'Complete 3 gene…' (first FitnessGoal sentence + timeframe, lineLimit 1), while the Suggest sheet's read-only 'Goal' box still says 'Wellness' (settings.selectedGoal). Two surfaces, two models, one word 'Goal'. SPACE also truncates at default type ('Home setup · 5 it…') and both truncate to 'Wellne…'/'Full gy…' at AX sizes.
- **Recommended change:** Strip value = goal type plus count ('Wellness · 3 goals'); Suggest's Goal field reads the same summary (and drops the text-input styling since it is not editable — render as a plain value row). Let segment values wrap to 2 lines and shorten SPACE to 'Home setup · 5' at AX.
- **Mockup needed:** No (code-only)
- **Evidence:** [05-goal-accepted.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/05-goal-accepted.png) · [15-suggest-workout-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/15-suggest-workout-sheet-top.png) · [34-move-after-workout.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/34-move-after-workout.png) · [Move_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Move_tab.png) — `App/Fernlet/MoveView.swift:1890-1899`, `App/Fernlet/MoveView.swift:1372-1376`, `App/Fernlet/MoveView.swift:1958-1963`

#### MOVE-16 — Medium — Tier 1 — Clarity — Guided cardio logged as 'Full Body · hard' with no duration

- **What's unclear or slow:** A Daily Movement 'Easy cardio – 20 min' session logs with the plan-level readiness intensity ('hard'), the fallback type Full Body, and `duration: nil`, so the row's meta line reads 'Full Body · hard' and never shows 20 min — contradicting the session's own name.
- **Recommended change:** Parse a leading '– N min' descriptor into `duration` when building the logged Workout, and label the row by the session's own kind (cardio line present → 'Cardio' when the session has no strength rows) so the meta reads 'Cardio · 20 min'; leave intensity as the committed readiness.
- **Mockup needed:** No (code-only)
- **Evidence:** [45-move-after-workout-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/45-move-after-workout-scrolled-1.png) · [48-workout-remove-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/48-workout-remove-confirm.png) — `FernletKit/Sources/FernletDomainModel/WorkoutProgram.swift:1035-1044`, `App/Fernlet/MoveView.swift:1199-1204`, `App/Fernlet/MoveView.swift:1575-1584`

#### MOVE-03 — Low — Tier 1 — Clarity — Remove popover points at the wrong workout row

- **What's unclear or slow:** The Remove confirmation is attached to the whole WorkoutRow VStack, so its arrow anchors to whatever part of the tall row is on screen — here it points at 'Easy cardio – 20 min' although Remove was tapped under 'Upper body strength'. The title 'Remove this workout?' never names the workout, so the user cannot tell which one is about to go.
- **Recommended change:** Name the workout in the title ('Remove Upper body strength?'); anchoring becomes moot once MOVE-02 moves this to .alert.
- **Mockup needed:** No (code-only)
- **Evidence:** [48-workout-remove-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/48-workout-remove-confirm.png) — `App/Fernlet/MoveView.swift:1646-1659`, `App/Fernlet/MoveView.swift:1621-1631`

#### MOVE-31 — Low — Tier 1 — Accessibility — Context-strip a11y labels are inconsistent

- **What's unclear or slow:** The Goal segment overrides its label with 'Edit movement goals' (VoiceOver never hears the current goal), while the Space segment's label is the bare value 'Full gym · 22 items' (never hears that it opens setup).
- **Recommended change:** Both segments: `.accessibilityLabel("Goal, Wellness")` / `"Space, Full gym, 22 items"` plus `.accessibilityHint("Opens goals" / "Opens where you train")`.
- **Mockup needed:** No (code-only)
- **Evidence:** [Move_tab.png](design-refs/ux-review-2026-08-16/shots/light/Move_tab.png) — `App/Fernlet/MoveView.swift:1910`, `App/Fernlet/MoveView.swift:1924-1927`
- **Note:** low severity — not independently verified.

#### MOVE-35 — Low — Tier 1 — Clarity — Done card names no workout and isn't tappable

- **What's unclear or slow:** After a guided session the card reads 'Today's workout — That's logged for today. Nicely done — rest up.' without saying which session; tapping the card does nothing, and the same information sits again in the Today's movement list below.
- **Recommended change:** Copy: 'Easy cardio is logged. Nicely done — rest up.' and make the card tappable to scroll to that logged row (or collapse it to a single line once done).
- **Mockup needed:** No (code-only)
- **Evidence:** [34-move-after-workout.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/34-move-after-workout.png) — `App/Fernlet/MoveView.swift:492-563`
- **Note:** low severity — not independently verified.

### Plan workout / Suggest sheets

**Current:** ![31-runner-finish-summary.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/31-runner-finish-summary.png) ![32-after-runner-done.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/32-after-runner-done.png) ![33-day-detail-after-workout.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/33-day-detail-after-workout.png)

#### MOVE-01 — High — Tier 2 — Daily-use speed — Runner finish strands user on empty Plan workout sheet

- **What's unclear or slow:** Suggest is presented from inside the Plan workout sheet, and the guided runner from inside Suggest (sheet-of-sheet-of-sheet). After 'Finish workout' → 'Done', only the Suggest sheet closes itself (dismissIfPlanFullyLogged); the user lands back on the blank 'Plan workout' form they never wanted and needs an extra Cancel to reach the Move root that now shows the logged session.
- **Recommended change:** Give WorkoutSuggestionSheet an onFinished callback; WorkoutPlanSheet dismisses itself on it ONLY when its own form is not dirty (otherwise stay, since the nesting exists to keep a part-filled plan). Longer term, surface Suggest from the Move root's Today's movement empty state / a root pill so the flow is root → Suggest → runner → root.
- **Mockup needed:** Yes
- **Evidence:** [31-runner-finish-summary.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/31-runner-finish-summary.png) · [32-after-runner-done.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/32-after-runner-done.png) · [33-day-detail-after-workout.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/33-day-detail-after-workout.png) — `App/Fernlet/MoveView.swift:3324-3333`, `App/Fernlet/MoveView.swift:1476-1478`, `App/Fernlet/MoveView.swift:1433-1442`, `App/Fernlet/GuidedWorkout.swift:310-313`
- **Also reported as:** FLOW-04

### Space sheet

**Current:** ![06-space-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/06-space-sheet-top.png) ![10-space-add-home-setup.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/10-space-add-home-setup.png) ![34-move-after-workout.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/34-move-after-workout.png)

#### MOVE-05 — High — Tier 1 — Daily-use speed — Peeking at a Space preset adds and activates it on back-out

- **What's unclear or slow:** Tapping 'Home setup' appends a new location AND sets it active in local state; the back chevron then calls `commitEdits()`, which persists both. The context strip flips to 'Home setup · 5 it…' and the next Suggest builds an 'Easy cardio (Home setup)' plan against the wrong gym — no Save was tapped and nothing said the active space changed.
- **Recommended change:** For a location that does not yet exist in the store, the back chevron should discard it (or ask 'Keep Home setup?'), matching the swipe-dismiss guard already in `onDisappear`. Do not change `activeID` on add; after Save location show the new card with a 'Make active' affordance (or a one-line 'Now training at Home setup' confirmation) so the switch is explicit.
- **Mockup needed:** No (code-only)
- **Evidence:** [06-space-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/06-space-sheet-top.png) · [10-space-add-home-setup.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/10-space-add-home-setup.png) · [34-move-after-workout.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/34-move-after-workout.png) · [16-suggest-workout-result.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/16-suggest-workout-result.png) — `App/Fernlet/WorkoutLocationSetupView.swift:437-444`, `App/Fernlet/WorkoutLocationSetupView.swift:264`, `App/Fernlet/WorkoutLocationSetupView.swift:412-415`, `App/Fernlet/WorkoutLocationSetupView.swift:252-257`

#### MOVE-34 — Low — Tier 1 — Clarity — Presets repeat locations the user already has

- **What's unclear or slow:** 'Add a location' always lists all four templates, so a daily user sees a saved 'Full gym' card and a 'Full gym' preset side by side; the presets take more room than the user's own locations.
- **Recommended change:** Hide (or dim with an 'added' tag) presets whose template is already saved, and collapse the preset grid under a single '+ Add location' tile once at least one location exists.
- **Mockup needed:** Yes
- **Evidence:** [06-space-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/06-space-sheet-top.png) · [07-space-sheet-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/07-space-sheet-scrolled-1.png) — `App/Fernlet/WorkoutLocationSetupView.swift:76-90`, `App/Fernlet/WorkoutLocationSetupView.swift:172-192`
- **Note:** low severity — not independently verified.

### Log workout sheet

**Current:** ![Sheet--Workout.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Workout.png) ![39-log-workout-sheet-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/39-log-workout-sheet-scrolled-1.png)

#### MOVE-07 — Medium — Tier 1 — Daily-use speed — Strength log requires a typed name; no default

- **What's unclear or slow:** Save stays disabled until the user invents a workout name (WorkoutSheetRules), so every daily strength log costs a keyboard round-trip; the Plan sheet defaults to '<Split> workout' and activity mode defaults to the type name, but strength logging gets neither. Meanwhile the 'Category · Auto' strip claims 'Full Body' before anything is entered.
- **Recommended change:** Default the name to the inferred category or first exercise ('Upper body', 'Bench press + 2') so Save enables as soon as one exercise is added; show the name field as optional. Hide the Category preview until an exercise or activity type exists.
- **Mockup needed:** No (code-only)
- **Evidence:** [Sheet--Workout.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Workout.png) · [39-log-workout-sheet-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/39-log-workout-sheet-scrolled-1.png) — `App/Fernlet/MoveView.swift:802-809`, `App/Fernlet/MoveView.swift:851-867`, `App/Fernlet/MoveView.swift:3051-3058`, `App/Fernlet/MoveView.swift:719`
- **Also reported as:** FLOW-06

#### MOVE-08 — Medium — Tier 1 — Daily-use speed — No recent exercises or repeat-last-workout shortcut

- **What's unclear or slow:** With an empty query the picker lists the catalog in fixed order (Bench press first, 8 rows) every time; a user who logs the same five lifts daily must search and re-enter sets/reps for each. Activity mode already has 'Recent' chips and the Plan sheet has 'Copy previous week', but strength logging has neither.
- **Recommended change:** Add a 'Recent' chip row above the exercise search (last 5 exercises; tapping prefills last sets×reps×weight) and a 'Log again' entry card at the top of Log workout that copies the most recent workout of the same category, mirroring 'Copy previous week'.
- **Mockup needed:** Yes
- **Evidence:** [Sheet--Workout.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Workout.png) · [12-day-plan-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/12-day-plan-sheet-top.png) · [41-log-workout-walking-selected.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/41-log-workout-walking-selected.png) — `App/Fernlet/MoveView.swift:2243-2245`, `App/Fernlet/MoveView.swift:2266-2275`, `FernletKit/Sources/FernletDomainModel/WorkoutModels.swift:1024-1033`, `App/Fernlet/ActivityPickerSection.swift:41-51`, `App/Fernlet/MoveView.swift:3238-3244`
- **Also reported as:** FLOW-21

#### MOVE-10 — Medium — Tier 1 — Daily-use speed — Nested 260pt scroll hides duration/effort fields

- **What's unclear or slow:** The workout-type list is an inner ScrollView capped at 260pt; a swipe over it scrolls the list, not the sheet, and the Duration/Distance/Effort fields that appear after choosing a type sit below it, off-screen. The user has to find a swipe target above the list to reach them.
- **Recommended change:** Once a type is selected, collapse the list to the chosen row with a 'Change' affordance (as ExerciseSearchPicker does) and render Duration/Distance/Effort directly beneath; before selection show the top ~6 types as chips plus search, with no nested scroll.
- **Mockup needed:** Yes
- **Evidence:** [42-log-workout-walking-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/42-log-workout-walking-scrolled-1.png) · [43-log-workout-walking-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/43-log-workout-walking-scrolled-2.png) — `App/Fernlet/ActivityPickerSection.swift:65-73`, `App/Fernlet/ActivityPickerSection.swift:76-78`
- **Also reported as:** FLOW-22

#### MOVE-12 — Medium — Tier 1 — Daily-use speed — Numeric fields open the full keyboard; inconsistent keypads

- **What's unclear or slow:** RPE (1–10) and Duration (min) in the Log sheet and Duration in Edit workout have no keyboardType, so the alphabetic keyboard appears; the Plan sheet's Duration and the activity fields use the number pad. Daily numeric entry costs an extra keyboard switch.
- **Recommended change:** `.keyboardType(.numberPad)` on RPE and Duration everywhere (decimalPad on Weight/Distance), plus `.submitLabel(.next)` chaining Sets → Reps → Weight.
- **Mockup needed:** No (code-only)
- **Evidence:** [39-log-workout-sheet-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/39-log-workout-sheet-scrolled-1.png) · [46-workout-edit-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/46-workout-edit-sheet-top.png) — `App/Fernlet/MoveView.swift:683-691`, `App/Fernlet/MoveView.swift:1788-1792`, `App/Fernlet/MoveView.swift:950-953`, `App/Fernlet/MoveView.swift:3270-3274`, `App/Fernlet/ActivityPickerSection.swift:126-131`

#### MOVE-11 — Medium — Tier 1 — Clarity — 'Workouts' kind label is ambiguous; Split duplicates Kind

- **What's unclear or slow:** Inside a sheet titled 'Log workout', the Kind chips are 'Strength Training' vs 'Workouts' — the second means cardio/activity but reads as 'everything'. In Plan workout the Split row also has a 'Workout' chip that silently toggles Kind to Workouts and vice-versa (two controls mirroring one state).
- **Recommended change:** Rename the mode to 'Cardio & activity' (picker title 'Activity'); in the Plan sheet remove the 'Workout' chip from Split and show Split chips only when Kind = Strength.
- **Mockup needed:** No (code-only)
- **Evidence:** [40-log-workout-kind-workouts.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/40-log-workout-kind-workouts.png) · [12-day-plan-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/12-day-plan-sheet-top.png) — `FernletKit/Sources/FernletDomainModel/WorkoutModels.swift:478-483`, `App/Fernlet/MoveView.swift:3135-3167`

#### MOVE-09 — Medium — Tier 1 — Consistency & polish — Effort slider uses system blue and has no a11y label

- **What's unclear or slow:** The only blue control in the app: the Slider has no `.tint`, so it renders iOS blue against the parchment palette. It also carries no accessibilityLabel/value — VoiceOver reads only 'adjustable', not 'Effort, 5 of 10'.
- **Recommended change:** `.tint(Color.moss)` on the Slider, `.accessibilityLabel("Effort")` and `.accessibilityValue("\(effort) of 10")`.
- **Mockup needed:** No (code-only)
- **Evidence:** [43-log-workout-walking-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/43-log-workout-walking-scrolled-2.png) — `App/Fernlet/ActivityPickerSection.swift:149-164`
- **Also reported as:** XCUT-23

#### MOVE-32 — Medium — Tier 1 — Consistency & polish — 'Energy (kcal)' shown regardless of the calories opt-in

- **What's unclear or slow:** The activity fields always include an 'Energy (kcal)' input, although calories elsewhere (macros card, nutrition label, exports) render only behind `settings.showCalories`. A user who opted out of calories still meets a kcal field on every activity log.
- **Recommended change:** Pass `showCalories` into ActivityPickerSection and render the Energy field only when it is on (Health-imported energy stays stored, just not asked for).
- **Mockup needed:** No (code-only)
- **Evidence:** [43-log-workout-walking-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/43-log-workout-walking-scrolled-2.png) — `App/Fernlet/ActivityPickerSection.swift:142-147`, `FernletKit/Sources/FernletDomainModel/SettingsModel.swift:69`, `App/Fernlet/HomeView.swift:2104`

#### MOVE-13 — Low — Tier 1 — Daily-use speed — Return key does nothing in exercise search; no auto-focus

- **What's unclear or slow:** Typing 'squat' then Return leaves the top result unselected — the user must reach up and tap it. Quick exercise, whose whole point is speed, opens without focusing the search field.
- **Recommended change:** `.submitLabel(.search)` + `.onSubmit { if let first = results.first { select(first) } }` on the search field; `@FocusState` auto-focus in QuickExerciseSheet.
- **Mockup needed:** No (code-only)
- **Evidence:** [19-suggest-edit-search.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/19-suggest-edit-search.png) · [Sheet--Quick_exercise.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Quick_exercise.png) — `App/Fernlet/MoveView.swift:2250-2258`, `App/Fernlet/MoveView.swift:926-957`
- **Note:** low severity — not independently verified.

### Edit workout sheet

**Current:** ![46-workout-edit-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/46-workout-edit-sheet-top.png) ![47-workout-edit-sheet-full.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/47-workout-edit-sheet-full.png)

#### MOVE-14 — Medium — Tier 1 — Consistency & polish — Edit sheet opens at medium, hiding notes; can't edit exercises

- **What's unclear or slow:** EditWorkoutSheet is the only Move entry sheet with `.medium` in its detents; at half height the Workout notes field is out of view with no cue, and there is no way to fix exercises, sets or RPE — the fields a daily user most often mistypes.
- **Recommended change:** Present EditWorkoutSheet at .large like Log/Plan and add an RPE field now; treat editing exercise lines (reusing WorkoutExerciseBuilder + LoggedExerciseRow with guided-provenance rules) as a separate follow-up.
- **Mockup needed:** No (code-only)
- **Evidence:** [46-workout-edit-sheet-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/46-workout-edit-sheet-top.png) · [47-workout-edit-sheet-full.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/47-workout-edit-sheet-full.png) — `App/Fernlet/MoveView.swift:1665-1670`, `App/Fernlet/MoveView.swift:1775-1807`
- **Also reported as:** FLOW-30

### Guided runner

**Current:** ![26-runner-exercise-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/26-runner-exercise-1.png) ![27-runner-exercise-2.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/27-runner-exercise-2.png) ![30-runner-last-set.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/30-runner-last-set.png)

#### MOVE-26 — Medium — Tier 1 — Daily-use speed — 'Done set' sits mid-screen, not in thumb reach

- **What's unclear or slow:** The primary 'Done set' / 'Finish workout' button is laid out directly under the exercise card near the top of the sheet; the lower ~60% of the screen is empty, so the action tapped most often during a workout is the furthest from the thumb.
- **Recommended change:** Move the primary button (and 'Skip rest' in the rest phase) into a fixed bottom bar above the safe area; keep the exercise card, set/reps pills and encouragement in the scrollable top area.
- **Mockup needed:** Yes
- **Evidence:** [26-runner-exercise-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/26-runner-exercise-1.png) · [27-runner-exercise-2.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/27-runner-exercise-2.png) · [30-runner-last-set.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/30-runner-last-set.png) — `App/Fernlet/GuidedWorkout.swift:64-85`, `App/Fernlet/GuidedWorkout.swift:213-247`

### Today's session sheet

**Current:** ![21-suggest-after-edit.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/21-suggest-after-edit.png) ![16-suggest-workout-result.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/16-suggest-workout-result.png)

#### MOVE-17 — Medium — Tier 1 — Consistency & polish — Two green primaries (Start now, Approve) and no close button

- **What's unclear or slow:** 'Start now' (full-width moss) and 'Approve workout' (moss, bottom bar) compete as primary; the paragraph between them exists only to explain the difference. The sheet also has no Cancel/close (unlike Log/Plan/Edit) — dismiss is swipe-only.
- **Recommended change:** One primary: 'Start now' in the bottom bar; 'Save for later' (approve) as the secondary outline button beside Edit; drop the explanatory paragraph to a one-line caption. Add SheetCancelBar at the top.
- **Mockup needed:** Yes
- **Evidence:** [21-suggest-after-edit.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/21-suggest-after-edit.png) · [16-suggest-workout-result.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/16-suggest-workout-result.png) — `App/Fernlet/MoveView.swift:1275-1300`, `App/Fernlet/MoveView.swift:1141-1169`, `App/Fernlet/MoveView.swift:1444-1467`

#### MOVE-18 — Medium — Tier 1 — Accessibility — 'Log as already done' is a tiny low-contrast text link

- **What's unclear or slow:** An action that writes workouts is a 4pt-padded italic slate caption (~24pt tall, low contrast on parchment) centered under the bar; easy to miss and hard to hit.
- **Recommended change:** Render as a full-width tertiary button (moss text on moss 12% capsule, 44pt min height) labelled 'Already did this — log it', placed under Edit/Approve.
- **Mockup needed:** No (code-only)
- **Evidence:** [16-suggest-workout-result.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/16-suggest-workout-result.png) · [21-suggest-after-edit.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/21-suggest-after-edit.png) — `App/Fernlet/MoveView.swift:1181-1192`

#### MOVE-15 — Medium — Tier 1 — Clarity — 'Nothing's logged yet' reads as false after a log

- **What's unclear or slow:** The caption under 'Rework today's plan' says "Nothing's logged yet, so you can rebuild it" while a workout is already logged for today (it means nothing of THIS plan).
- **Recommended change:** Copy: "None of this plan is logged yet, so you can still rebuild it — adjust your intensity, notes, or equipment."
- **Mockup needed:** No (code-only)
- **Evidence:** [21-suggest-after-edit.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/21-suggest-after-edit.png) · [17-suggest-workout-result-full.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/17-suggest-workout-result-full.png) — `App/Fernlet/MoveView.swift:1112-1114`

### Workout setup sheet

**Current:** ![22-suggest-equipment-limits.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/22-suggest-equipment-limits.png) ![23-workout-setup-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/23-workout-setup-scrolled-1.png) ![24-workout-setup-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/24-workout-setup-scrolled-2.png)

#### MOVE-21 — Medium — Tier 1 — Consistency & polish — Setup: silent swipe-discard and guilt-toned split confirmation

- **What's unclear or slow:** The sheet has no Cancel and no `interactiveDismissDisabled`, so a swipe throws away typed days/experience/injury notes silently. Saving with a different split shows 'Switch your routine? …switching restarts that momentum' — a confirmation on a non-destructive change with guilt copy; and because it is a confirmationDialog its 'Keep X' cancel-role button is not rendered, so tapping outside abandons the whole save.
- **Recommended change:** Add SheetCancelBar + isDirty/discardConfirmation like the other sheets; drop the switch dialog and instead show a neutral inline caption under the split list ('You've been consistent with Full Body ×3 — keep it unless something changed').
- **Mockup needed:** No (code-only)
- **Evidence:** [22-suggest-equipment-limits.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/22-suggest-equipment-limits.png) · [23-workout-setup-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/23-workout-setup-scrolled-1.png) · [24-workout-setup-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/24-workout-setup-scrolled-2.png) — `App/Fernlet/WorkoutSetupView.swift:72-108`, `App/Fernlet/WorkoutSetupView.swift:275-284`

### Paste a plan sheet

**Current:** ![62-paste-plan-pasted-clipboard.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/62-paste-plan-pasted-clipboard.png)

#### MOVE-24 — Medium — Tier 1 — Daily-use speed — Paste editor grows unbounded; Read plan pushed off-screen

- **What's unclear or slow:** TextEditor has minHeight 220 and no maxHeight inside a ScrollView, so a pasted reply expands to its full length (many screens) and 'Read plan' sits far below the fold.
- **Recommended change:** `.frame(minHeight: 220, maxHeight: 320)` so the editor scrolls internally, and pin 'Read plan' in a bottom bar (SheetSaveBar-style) outside the ScrollView.
- **Mockup needed:** No (code-only)
- **Evidence:** [62-paste-plan-pasted-clipboard.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/62-paste-plan-pasted-clipboard.png) — `App/Fernlet/CoachPlanPasteSheet.swift:72-85`, `App/Fernlet/CoachPlanPasteSheet.swift:129-152`

#### MOVE-25 — Medium — Tier 1 — Clarity — Raw decoding path shown for a mis-pasted plan

- **What's unclear or slow:** Pasting the app's own summary back (an easy slip: it is what was just copied) yields 'That plan couldn't be read: edits → Index 0 → targetID couldn't be read.' — a coding-path string with no next step.
- **Recommended change:** Detect Fernlet's own export/format tag and say 'That looks like your training summary, not a plan — paste the assistant's reply instead.' For other decode failures show a plain sentence ('The plan is missing something Fernlet needs. Ask the assistant to reply with the complete JSON block again.') with the technical path as a smaller secondary line.
- **Mockup needed:** No (code-only)
- **Evidence:** [63-paste-plan-read-summary-json.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/63-paste-plan-read-summary-json.png) · [61-paste-plan-error.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/61-paste-plan-error.png) — `App/Fernlet/CoachPlanImporter.swift:250-275`, `App/Fernlet/CoachPlanImporter.swift:141-153`, `App/Fernlet/CoachPlanPasteSheet.swift:111-127`

### Share with a trainer sheet

**Current:** ![55-share-prepare-summary.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/55-share-prepare-summary.png) ![56-share-summary-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/56-share-summary-sheet.png) ![57-share-copy-prompt-tapped.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/57-share-copy-prompt-tapped.png)

#### MOVE-22 — Medium — Tier 1 — Clarity — Prepare → Share two-step; button reverts to Prepare after sharing

- **What's unclear or slow:** The user must tap 'Prepare summary' then 'Share summary…'; after the share sheet closes the file is deleted and the button flips back to 'Prepare summary', which reads as the summary being lost. Preparation is instant, so the extra step buys nothing visible.
- **Recommended change:** One 'Share summary…' button that writes the file, presents the share sheet and deletes on finish; keep the 'N days will be included' preview line above it. If a prepared state must remain, label the reverted button 'Share again' with a 'Shared — the file has been removed from Fernlet' caption.
- **Mockup needed:** No (code-only)
- **Evidence:** [55-share-prepare-summary.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/55-share-prepare-summary.png) · [56-share-summary-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/56-share-summary-sheet.png) · [57-share-copy-prompt-tapped.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/57-share-copy-prompt-tapped.png) — `App/Fernlet/TrainerExportView.swift:257-299`, `App/Fernlet/TrainerExportView.swift:149-151`

#### MOVE-23 — Low — Tier 1 — Clarity — 'You control exactly what goes in it' offers no control here

- **What's unclear or slow:** The intro promises control over contents, but the include-toggles (goal, hydration, sleep, unwell days, wellbeing) live in Settings under Coach; nothing on this screen links there or lists what is included.
- **Recommended change:** Add a 'What's included ›' row under the count line that opens the Coach settings section (or shows the five toggles inline in a disclosure).
- **Mockup needed:** No (code-only)
- **Evidence:** [53-share-trainer-export-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/53-share-trainer-export-top.png) · [Settings--Move.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Move.png) — `App/Fernlet/TrainerExportView.swift:244-255`, `App/Fernlet/SettingsSheet.swift:1400-1408`
- **Note:** low severity — not independently verified.

### Day detail

**Current:** ![11-week-today-detail.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/11-week-today-detail.png) ![35-week-rest-day-detail.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/35-week-rest-day-detail.png)

#### MOVE-28 — Low — Tier 1 — Consistency & polish — Day detail shows the title twice

- **What's unclear or slow:** The nav bar shows 'Today' inline and the body repeats a large 'Today' ScreenHeader with the subtitle 'Movement only.' directly beneath — duplicated title, ambiguous subtitle.
- **Recommended change:** Keep the ScreenHeader (with a clearer subtitle, e.g. 'Sunday, Aug 16') and set `.navigationTitle("")`/`.toolbarTitleDisplayMode(.inline)` so the bar shows only back + Plan/Log — matching the Move root's own header pattern.
- **Mockup needed:** No (code-only)
- **Evidence:** [11-week-today-detail.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/11-week-today-detail.png) · [35-week-rest-day-detail.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/35-week-rest-day-detail.png) — `App/Fernlet/MoveView.swift:2806-2818`
- **Also reported as:** FLOW-33
- **Note:** low severity — not independently verified.

### Plan workout sheet

**Current:** ![13-day-plan-sheet-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/13-day-plan-sheet-scrolled-1.png) ![14-day-plan-sheet-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/14-day-plan-sheet-scrolled-2.png)

#### MOVE-36 — Low — Tier 1 — Clarity — Two free-text fields with overlapping placeholders

- **What's unclear or slow:** 'Plan steps' ('Exercises, sets, reps, or trainer cues...') and 'Plan notes' ('Exercises, coach cues, target pace, or recovery focus...') both invite exercises and cues; the difference (steps parse into rows, notes don't) is invisible.
- **Recommended change:** Placeholders: Plan steps → 'One exercise per line, e.g. Squat 3x8 @60'; Plan notes → 'Anything to remember on the day (pace, warm-up, how you felt)'.
- **Mockup needed:** No (code-only)
- **Evidence:** [13-day-plan-sheet-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/13-day-plan-sheet-scrolled-1.png) · [14-day-plan-sheet-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/14-day-plan-sheet-scrolled-2.png) — `App/Fernlet/MoveView.swift:3202-3208`, `App/Fernlet/MoveView.swift:3223-3231`
- **Note:** low severity — not independently verified.

## Friends

The social surfaces are the least labelled in the app: icon-only headers, one glyph reused for three destinations, and camera/album controls that VoiceOver cannot operate. Removing a friend and deleting every shared photo are both single unconfirmed taps, while Block — a lesser action — does ask.

### Friends & Blocks

**Current:** ![71-friends-roster-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/71-friends-roster-top.png)

#### FRND-03 — High — Tier 1 — Consistency & polish — Remove friend is instant - no confirmation, unlike Block/Report

- **What's unclear or slow:** Swipe action 'Remove' (role .destructive) and the detail card's 'Remove' chip call store.revokeTrustedProximityPeer immediately. Revocation stamps revokedAt and forgets the friend's cached state; getting them back requires meeting in person again. Block raises the 'Block peer?' alert and Report raises a confirmation dialog on the same row, so the most destructive of the three is the only one that fires silently.
- **Recommended change:** Route both Remove entry points through a confirmation matching the Block alert: title 'Remove <name>?', message 'You'll need to meet in person to add them again.', buttons Remove (destructive) / Cancel.
- **Mockup needed:** No (code-only)
- **Evidence:** [71-friends-roster-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/71-friends-roster-top.png) — `App/Fernlet/FriendListView.swift:197-202`, `App/Fernlet/FriendListView.swift:405-408`, `App/Fernlet/FriendListView.swift:78-82`, `App/Fernlet/FriendListView.swift:246-257`, `App/Fernlet/FernletStore.swift:1858-1862`

#### FRND-04 — Medium — Tier 1 — Clarity — Removed friends linger forever with 'Removed' badge and Remove action

- **What's unclear or slow:** Remove only sets revokedAt; the record stays in the 'All' list (and in search) with a 'Removed' badge, and its swipe still offers 'Remove' (which re-stamps the date). There is no un-remove and no way to purge the row, so the roster accumulates ghosts a user cannot act on. The 'Friends' filter hides them, but 'All' is the default segment.
- **Recommended change:** Hide revoked rows from 'All' (or move them under a collapsed 'Removed' group), swap the swipe/detail 'Remove' on a revoked row for 'Forget' (deletes the record, with confirmation), and default the segment to 'Friends'.
- **Mockup needed:** Yes
- **Evidence:** [71-friends-roster-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/71-friends-roster-top.png) · [72-friends-roster-blocked-filter.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/72-friends-roster-blocked-filter.png) — `App/Fernlet/FriendListView.swift:345-352`, `App/Fernlet/FriendListView.swift:743-749`, `App/Fernlet/FriendListView.swift:196-202`, `FernletKit/Sources/ProximityKit/Trust/ProximityTrustVault.swift:162-172`

#### FRND-05 — Medium — Tier 1 — Consistency & polish — Large title sits flush against the screen edge

- **What's unclear or slow:** 'Friends & Blocks' renders as a system large title with zero leading inset (the F touches x=0) while every field below is inset 20pt. Sibling pushes from the same header use different title idioms: Activities and Safety & reporting use centered inline titles, the tab root uses the in-content ScreenHeader. Three title treatments one tap apart.
- **Recommended change:** Drop .navigationBarTitleDisplayMode(.large) and either use .inline like Activities/Safety, or render ScreenHeader(title: "Friends & Blocks", subtitle: ...) as the first list row with the 20pt insets so the title aligns with the fields. Pick one idiom for all three pushed screens.
- **Mockup needed:** No (code-only)
- **Evidence:** [71-friends-roster-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/71-friends-roster-top.png) · [72-friends-roster-blocked-filter.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/72-friends-roster-blocked-filter.png) · [65-friends-toolbar-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/65-friends-toolbar-1.png) · [73-safety-reporting-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/73-safety-reporting-top.png) — `App/Fernlet/FriendListView.swift:61-62`, `App/Fernlet/FriendListView.swift:141`, `App/Fernlet/ActivitiesView.swift:44-45`, `App/Fernlet/SafetyReportingView.swift:53-54`, `App/Fernlet/ConnectView.swift:191`

#### FRND-07 — Medium — Tier 1 — Clarity — Empty display name silently broadcasts as 'iPhone'

- **What's unclear or slow:** The 'You appear as' field is empty by default with placeholder 'Your name'; the wire name falls back to UIDevice.current.name ('iPhone'), so friends see 'iPhone' and the Activities roster shows a blank name. Nothing on the row says what friends currently see, and the setting lives two taps deep inside the roster rather than near the connect flow.
- **Recommended change:** Use the resolved fallback as the placeholder ('iPhone') and add a labelSmall helper line 'Friends nearby see this name.' Show the same row (or a 'You appear as iPhone - change' link) at the top of the Friends root under the searching bar the first time it is empty.
- **Mockup needed:** No (code-only)
- **Evidence:** [71-friends-roster-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/71-friends-roster-top.png) · [67-activities-started.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/67-activities-started.png) — `App/Fernlet/FriendListView.swift:86-107`, `FernletKit/Sources/FernletDomainModel/SettingsModel.swift:153`, `FernletKit/Sources/ProximityKit/PeerDisplayNames.swift:20-23`

#### FRND-22 — Medium — Tier 1 — Clarity — Security-console jargon on everyday friend surfaces

- **What's unclear or slow:** Empty roster says 'No trusted peers yet.' and search says 'No peers match'; the album search placeholder is 'Search sessions by person or mesh'; the detail card lists 'Mode: Uwb/Manual' and 'First accepted'; every roster row shows the raw hex fingerprint; the hosting card says 'Roster as of … (v1)'; the info sheet says '2 person(s) connected' / '10 shot(s) remaining'.
- **Recommended change:** 'No friends yet - meet up in person to add one.' / 'No one matches "x"'; 'Search by friend or session name'; hide Mode, keep 'Friends since'; move the fingerprint out of the row into the detail card; 'Updated 7:17 PM'; use real plurals ('2 people connected', '1 shot left').
- **Mockup needed:** No (code-only)
- **Evidence:** [71-friends-roster-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/71-friends-roster-top.png) · [72-friends-roster-blocked-filter.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/72-friends-roster-blocked-filter.png) · [67-activities-started.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/67-activities-started.png) — `App/Fernlet/FriendListView.swift:760-767`, `App/Fernlet/FriendListView.swift:276-280`, `App/Fernlet/FriendListView.swift:368-371`, `App/Fernlet/ConnectView.swift:422`, `App/Fernlet/ActivitiesView.swift:239-241`, `App/Fernlet/DisposableCameraView.swift:1361-1368`

### Friends tab root

**Current:** ![Friends_tab.png](design-refs/ux-review-2026-08-16/shots/light/Friends_tab.png) ![Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) ![Move_tab.png](design-refs/ux-review-2026-08-16/shots/light/Move_tab.png)

#### FRND-02 — High — Tier 1 — Clarity — Icon-only header actions; person.2 glyph reused three times

- **What's unclear or slow:** An existing user has to tap the two unlabeled circles to learn that figure.2.arms.open = Activities and person.2 = Friends & Blocks (walker note confirmed). person.2 is also the glyph inside the 'Looking for nearby friends…' pulse and the (filled) Friends tab icon on the same screen, so it does not disambiguate. Food and Move headers use text pills ('+ meal', 'Log', 'Share') and an italic subtitle; Friends passes subtitle "" so its header is the only tab root with a bare title and icon-only pills.
- **Recommended change:** Use HeaderActionButton(title: "Activities", systemImage: "figure.2.arms.open") and HeaderActionButton(title: "Friends", systemImage: "person.2") (text pills like Move's Log/Share), and give the ScreenHeader a one-line subtitle in the same italic voice as Food/Move (e.g. 'Together, in person.'). Use a different glyph (e.g. dot.radiowaves.left.and.right) inside the searching pulse.
- **Mockup needed:** No (code-only)
- **Evidence:** [Friends_tab.png](design-refs/ux-review-2026-08-16/shots/light/Friends_tab.png) · [Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) · [Move_tab.png](design-refs/ux-review-2026-08-16/shots/light/Move_tab.png) · [65-friends-toolbar-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/65-friends-toolbar-1.png) · [71-friends-roster-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/71-friends-roster-top.png) — `App/Fernlet/ConnectView.swift:190-208`, `App/Fernlet/ConnectView.swift:301`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:151-174`
- **Also reported as:** FRND-01

#### FRND-17 — Medium — Tier 1 — Accessibility — Album cells and review tiles carry no VoiceOver name or state

- **What's unclear or slow:** Album grid cells are Color.cream overlays with .onTapGesture - not buttons, no label - so VoiceOver cannot open a post. In the feed, the close button is 42pt, the save button keeps the label 'Save this picture…' after it turns into a checkmark, the favorite heart has no selected state, and the session-end review tiles (Button with checkmark overlay) expose no isSelected trait, so selection is conveyed only by the moss checkmark.
- **Recommended change:** Make each grid cell a Button (plain style) with .accessibilityLabel("Photo from \(sender), \(date)") and 'carousel, N photos' when isCarousel; bump the feed close to 44pt; switch save label to 'Saved to Photos' when done; add .accessibilityAddTraits(.isSelected) to favorite and review tiles.
- **Mockup needed:** No (code-only)
- **Evidence:** [Friends_tab.png](design-refs/ux-review-2026-08-16/shots/light/Friends_tab.png) — `App/Fernlet/ConnectView.swift:406-416`, `App/Fernlet/ConnectView.swift:444-460`, `App/Fernlet/ConnectView.swift:581-591`, `App/Fernlet/ConnectView.swift:745-763`, `FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift:36-41`, `FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift:109-122`

#### FRND-25 — Medium — Tier 2 — Daily-use speed — Friends root shows no friends; sending a heart is 3+ taps deep

- **What's unclear or slow:** The Friends root is a photo album plus a searching bar; your friends and the 'Send good vibes' heart live behind the unlabeled person.2 icon, then a row tap to expand the detail card. The nearby-friend toggles (presence, hearts, away delivery, clothing shops) live under Settings > Privacy with no link from Friends. For a daily user the most frequent social action (heart a friend who is 'Nearby now') is Friends -> icon -> find row -> expand -> Send.
- **Recommended change:** Add a 'Your friends' strip on the root under the searching bar: horizontal companion avatars with a nearby dot and a one-tap heart on those reachable now, tapping opens their card; add a small 'Nearby settings' link (or gear) in the header that deep-links to the Privacy nearby toggles.
- **Mockup needed:** Yes
- **Evidence:** [Friends_tab.png](design-refs/ux-review-2026-08-16/shots/light/Friends_tab.png) · [71-friends-roster-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/71-friends-roster-top.png) · [53-settings-hub-scrolled-3.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/53-settings-hub-scrolled-3.png) — `App/Fernlet/ConnectView.swift:186-230`, `App/Fernlet/FriendListView.swift:169-192`, `App/Fernlet/FriendListView.swift:383-386`, `App/Fernlet/FriendListView.swift:429-449`

### Disposable camera

#### FRND-15 — High — Tier 1 — Accessibility — Wind-to-arm is drag-only; VoiceOver users cannot take a photo

- **What's unclear or slow:** The shutter is disabled until camera.isArmed, and arming happens only through a DragGesture on the 64pt thumbwheel ('Slide ↓'/'Swipe →'). The wheel has no accessibility label, no accessibilityAdjustableAction/accessibilityAction, and the decorative housing is flattened, so VoiceOver and Switch Control users have no way to arm the camera - the shutter reads 'Wind camera first' forever.
- **Recommended change:** Give windIndicator .accessibilityLabel("Film wind"), .accessibilityValue(armed ? "Ready" : "\(Int(progress*100))% wound") and .accessibilityAction(named: "Wind camera") { camera.advanceWind(progress: 1) }; also honor Reduce Motion / Switch Control by letting a double-tap on the wheel arm it.
- **Mockup needed:** No (code-only)
- **Evidence:** _(code only)_ — `App/Fernlet/DisposableCameraView.swift:1095-1109`, `App/Fernlet/DisposableCameraView.swift:1169-1187`, `App/Fernlet/DisposableCameraView.swift:1037-1078`, `App/Fernlet/DisposableCameraView.swift:824-827`

#### FRND-13 — Medium — Tier 1 — Daily-use speed — 'Develop' with zero photos ends the session instantly

- **What's unclear or slow:** beginDevelop() stops the camera and, when sessionPhotos is empty, calls leaveSessionAfterNotifyingPeers with no confirmation. The button reads 'Develop' (a photo verb), so a curious tap before any shot silently ends the live session for this user - the session chat transcript vanishes and the camera surface disappears. Ending via the info sheet, by contrast, asks 'End session?'.
- **Recommended change:** When there are no photos, show the same 'End session?' alert (Cancel / End Session) instead of leaving directly; relabel the control 'Develop & finish' (or 'Finish') so the exit semantics are visible.
- **Mockup needed:** No (code-only)
- **Evidence:** _(code only)_ — `App/Fernlet/DisposableCameraView.swift:1023-1035`, `App/Fernlet/DisposableCameraView.swift:1221-1239`, `App/Fernlet/DisposableCameraView.swift:1554-1560`, `App/Fernlet/DisposableCameraView.swift:1852-1859`

#### FRND-14 — Medium — Tier 1 — Consistency & polish — In-session Block fires instantly; roster Block asks first

- **What's unclear or slow:** The participant '…' menu's 'Block' (role .destructive) calls manager.block(participant) directly, whereas Block in Friends & Blocks raises the 'Block peer?' alert with a Cancel. Same action, same person, two different safety nets; blocking mid-session also drops them from the shared photo/chat flow.
- **Recommended change:** Reuse the roster's block alert ('Block <name>? Blocking hides their content from you and yours from them.' Block/Cancel) from the session menu.
- **Mockup needed:** No (code-only)
- **Evidence:** _(code only)_ — `App/Fernlet/DisposableCameraView.swift:1438-1455`, `App/Fernlet/FriendListView.swift:78-82`, `App/Fernlet/FriendListView.swift:246-257`

### Activities

**Current:** ![67-activities-started.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/67-activities-started.png) ![68-activities-started-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/68-activities-started-scrolled-1.png)

#### FRND-06 — Medium — Tier 1 — Clarity — Host roster row shows '?' avatar, blank name, raw hex id, '(v1)'

- **What's unclear or slow:** After starting an activity the roster lists the host (you) as a '?' monogram circle, an empty name with the small 'host' tag, and the raw 16-hex fingerprint in monospace; the caption reads 'Roster as of Aug 16, 2026 at 7:17 PM (v1)'. The monogram is '?' because the display name is empty; the fingerprint and version stamp are developer metadata to a daily user.
- **Recommended change:** For the local participant show the companion avatar (CompanionView with the user's own appearance) and 'You' (plus 'host' tag); for others show the name with the fingerprint behind a tap or as a short 4-group code. Replace the caption with 'Updated 7:17 PM' and drop '(v1)'.
- **Mockup needed:** Yes
- **Evidence:** [67-activities-started.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/67-activities-started.png) · [68-activities-started-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/68-activities-started-scrolled-1.png) — `App/Fernlet/ActivitiesView.swift:239-259`, `App/Fernlet/ActivitiesView.swift:277-289`, `App/Fernlet/ActivitiesView.swift:403-406`, `FernletKit/Sources/ProximityKit/PeerDisplayNames.swift:20-23`

#### FRND-08 — Medium — Tier 1 — Consistency & polish — Activity-type chips overflow and clip at the card edge

- **What's unclear or slow:** The 7 type chips (Walk…Other) live in a horizontal ScrollView inside the card's 16pt padding, so 'Workout' is hard-clipped to 'Worko' at the padding edge with no fade or trailing peek; Hangout/Other are invisible. The duration row beneath fits on one line, so the two chip rows read inconsistently. FlowLayout already exists in FernletUI for exactly this.
- **Recommended change:** Lay the type chips out with FlowLayout(spacing: 8) so they wrap to two rows inside the card; if the scroller stays, bleed it to the card edges with .contentMargins(.horizontal, 16) so chips scroll under the padding instead of clipping.
- **Mockup needed:** No (code-only)
- **Evidence:** [65-friends-toolbar-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/65-friends-toolbar-1.png) · [67-activities-started.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/67-activities-started.png) — `App/Fernlet/ActivitiesView.swift:104-105`, `App/Fernlet/ActivitiesView.swift:341-353`, `App/Fernlet/ActivitiesView.swift:138`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:330-374`

#### FRND-09 — Medium — Tier 1 — Daily-use speed — Start form pins to top; live activity and End pushed below fold

- **What's unclear or slow:** The full 'Start an activity' form (name, two chip rows, location, button) always renders first, so once you are hosting, the 'You're hosting' card and its 'End activity' button sit below the fold and need a scroll (67 -> 68). Starting also requires typing a name even though a type chip is already chosen, and the name field has no submit label/onSubmit, so Return does nothing.
- **Recommended change:** Order live cards (hosting/joined/invites) above the form; when at least one activity is live, collapse the form to a single 'Start another activity' pill that expands in place. Prefill the name with the chosen type ('Walk') so Start is enabled immediately, and set .submitLabel(.next) on name -> location and .submitLabel(.go) with .onSubmit(startActivity) on location.
- **Mockup needed:** Yes
- **Evidence:** [65-friends-toolbar-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/65-friends-toolbar-1.png) · [67-activities-started.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/67-activities-started.png) · [68-activities-started-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/68-activities-started-scrolled-1.png) — `App/Fernlet/ActivitiesView.swift:32-42`, `App/Fernlet/ActivitiesView.swift:82-141`, `App/Fernlet/ActivitiesView.swift:93-102`, `App/Fernlet/ActivitiesView.swift:120-131`

#### FRND-31 — Low — Tier 1 — Consistency & polish — Activity section titles skip SectionLabel; sentence-case vs uppercase

- **What's unclear or slow:** 'You're hosting', 'You've joined', 'Nearby invites' are plain .fernlet(.label) slate text in sentence case, whereas Move ('TODAY'S MOVEMENT') and Food ('BREAKFAST', 'RECIPES') title sections with the uppercase, letter-spaced SectionLabel.
- **Recommended change:** Use SectionLabel("You're hosting") etc. for the three activity sections so the tab shares the app's section-heading treatment.
- **Mockup needed:** No (code-only)
- **Evidence:** [67-activities-started.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/67-activities-started.png) · [Move_tab.png](design-refs/ux-review-2026-08-16/shots/light/Move_tab.png) · [Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) — `App/Fernlet/ActivitiesView.swift:313-320`, `FernletKit/Sources/FernletUI/FernletPrimitives.swift:40-53`
- **Note:** low severity — not independently verified.

### Photo review sheet

#### FRND-11 — Medium — Tier 1 — Consistency & polish — 'Delete all' wipes every shared photo in one tap, no confirm

- **What's unclear or slow:** The review sheet's footer has 'Delete all' (role .destructive, but ChipButtonStyle ignores role so it looks like any neutral chip) which immediately deletes all session photos from the device and leaves the session; the FriendsView copy of the sheet is even interactiveDismissDisabled, so a mis-tap here is unrecoverable. 'Save selected' is disabled with nothing ticked, so 'Delete all' is the only affordance left when the user unticks everything.
- **Recommended change:** Confirm before discarding: alert 'Delete N shared pictures?' / 'They'll be removed from this phone. Friends keep their own copies.' with Delete (destructive) and Cancel; render the chip in a destructive (terracotta) variant. Rename to 'Delete all N'.
- **Mockup needed:** No (code-only)
- **Evidence:** _(code only)_ — `FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift:136-151`, `App/Fernlet/ConnectView.swift:133-145`, `App/Fernlet/ConnectView.swift:165-172`, `App/Fernlet/DisposableCameraView.swift:1281-1288`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:406-429`

#### FRND-12 — Medium — Tier 2 — Daily-use speed — Keeping photos on Fernlet's shelf requires Photos-library permission

- **What's unclear or slow:** 'Save selected' first writes to the system Photos library and only on success calls finishSessionPhotos(keeping:) which retains the pictures on the in-app photo wall. If Photos access is denied or the save fails, the alert fires, nothing is kept, and the only remaining exit is 'Delete all'. Keeping shared photos inside Fernlet is coupled to exporting them out of it.
- **Recommended change:** Make the primary action 'Keep selected' (retains on the shelf, no permission needed) and add a secondary toggle/row 'Also save to Photos' (default off, or remembered). On a Photos failure still keep the shelf copies and say so in the alert.
- **Mockup needed:** Yes
- **Evidence:** _(code only)_ — `App/Fernlet/ConnectView.swift:149-162`, `App/Fernlet/DisposableCameraView.swift:1269-1279`, `FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift:881-889`, `FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift:104`

### Shared: chips & pickers

**Current:** ![68-activities-started-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/68-activities-started-scrolled-1.png)

#### FRND-18 — Medium — Tier 1 — Accessibility · Systemic — Primary/secondary actions rendered as ~34pt chips (under 44pt)

- **What's unclear or slow:** ChipButtonStyle (label font + 8pt vertical padding) is used for real actions across the tab: Allow/Decline in the join prompt, Save selected/Delete all in the review footer, End activity, Leave, Ask to join, Connect, Block/Remove/Report on the detail card, Done in the keep-friends sheet; 'Verify' is a bare Text menu label. All land around 32-36pt tall - below the 44pt minimum - while Move/Food primary actions are full-height pills.
- **Recommended change:** Introduce an action-pill style (min height 44, horizontal 18) for these call-to-action rows and reserve ChipButtonStyle for selection chips; give the Verify menu label the same pill so it matches Connect.
- **Mockup needed:** No (code-only)
- **Evidence:** [68-activities-started-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/68-activities-started-scrolled-1.png) — `FernletKit/Sources/FernletUI/FernletUIComponents.swift:413-428`, `App/Fernlet/ActivitiesView.swift:168-172`, `App/Fernlet/ActivitiesView.swift:197-199`, `FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift:136-151`, `App/Fernlet/ConnectView.swift:971-991`, `App/Fernlet/FriendListView.swift:390-415`, `App/Fernlet/JoinPromptSheet.swift:106-118`

#### FRND-19 — Medium — Tier 1 — Consistency & polish · Systemic — Destructive actions look identical to neutral chips

- **What's unclear or slow:** End activity, Leave, Delete all, Remove, Block, Report and End session all use ChipButtonStyle(selected: false) - the same cream outline as 'Dismiss' or 'Decline'. ChipButtonStyle ignores Button role, so nothing in the tab visually signals 'this one is destructive' the way the terracotta/red treatments do in Move's remove flows.
- **Recommended change:** Add a destructive variant (terracotta text + terracotta 0.12 outline, or read configuration.role inside ChipButtonStyle) and apply it to End activity, Leave, Delete all, Remove, Block, Report, End session; keep neutral chips for Dismiss/Decline/Cancel.
- **Mockup needed:** Yes
- **Evidence:** [68-activities-started-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/68-activities-started-scrolled-1.png) · [69-activities-end-tapped.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/69-activities-end-tapped.png) — `FernletKit/Sources/FernletUI/FernletUIComponents.swift:406-429`, `App/Fernlet/ActivitiesView.swift:197-199`, `App/Fernlet/ActivitiesView.swift:223-225`, `App/Fernlet/FriendListView.swift:390-415`, `FernletKit/Sources/ProximityKit/UI/FriendPhotoReviewSheet.swift:137-141`, `App/Fernlet/DisposableCameraView.swift:1554-1560`

### Join prompt sheet

#### FRND-28 — Medium — Tier 1 — Consistency & polish — Full-height sheet with no close; swipe-down silently declines all

- **What's unclear or slow:** The join prompt presents as a default large sheet for one small card, has no Cancel/close control, and its binding setter declines every pending request when the sheet is dismissed by swipe - a fail-closed choice that the UI never states, so a host who swipes to peek at the camera silently declines friends waiting to join.
- **Recommended change:** Present at .presentationDetents([.medium]) with a visible 'Decline all' secondary action and a labelSmall footer 'Swiping this away declines everyone waiting.'; keep the fail-closed behavior.
- **Mockup needed:** No (code-only)
- **Evidence:** _(code only)_ — `App/Fernlet/JoinPromptSheet.swift:31-52`, `App/Fernlet/ActivitiesView.swift:47-61`, `App/Fernlet/ActivitiesView.swift:357-364`

### Friends: misc

**Current:** ![65-friends-toolbar-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/65-friends-toolbar-1.png)

#### FRND-21 — Low — Tier 1 — Consistency & polish — System color and font leaks in the social surfaces

- **What's unclear or slow:** JoinPromptSheet's error banner uses Color.orange (icon and stroke); ConnectionSuccessOverlay renders the peer name in Color.primary; FriendListView.detailRow values use .subheadline system font; fingerprints use .system(.caption, design: .monospaced) in three files; the Activities form mixes .fernlet(.body) for the name field with .fernlet(.bodySmall) for the location field so the two text fields render at different sizes.
- **Recommended change:** Swap orange -> goldenrod/terracotta, Color.primary -> Color.bark, .subheadline -> .fernlet(.body); add a Font.fernlet(.mono) role (or a shared FingerprintText view) for fingerprints; use .fernlet(.body) on both Activities fields.
- **Mockup needed:** No (code-only)
- **Evidence:** [65-friends-toolbar-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/65-friends-toolbar-1.png) — `App/Fernlet/JoinPromptSheet.swift:59`, `App/Fernlet/JoinPromptSheet.swift:73`, `App/Fernlet/ConnectView.swift:1108-1110`, `App/Fernlet/FriendListView.swift:711-724`, `App/Fernlet/FriendListView.swift:276-280`, `App/Fernlet/ActivitiesView.swift:93-94`, `App/Fernlet/ActivitiesView.swift:107-108`
- **Note:** low severity — not independently verified.

### Session chat

#### FRND-27 — Low — Tier 1 — Daily-use speed — Return inserts newline; send is a 30pt glyph; no autofocus

- **What's unclear or slow:** The compose TextField is axis .vertical with no submitLabel/onSubmit, so Return adds a line and the only way to send is the arrow.up.circle.fill glyph (30pt, no frame). The field is not focused on open, so every message costs a tap on the field first.
- **Recommended change:** Set composeFocused = true on appear, add .submitLabel(.send) + .onSubmit(send) (Shift-return for newline), and give the send button .frame(width: 44, height: 44) with .accessibilityLabel already present.
- **Mockup needed:** No (code-only)
- **Evidence:** _(code only)_ — `App/Fernlet/SessionChatPanel.swift:127-147`, `App/Fernlet/SessionChatPanel.swift:17-18`
- **Note:** low severity — not independently verified.

### Safety & reporting

**Current:** ![73-safety-reporting-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/73-safety-reporting-top.png)

#### FRND-29 — Low — Tier 1 — Clarity — Copy omits photos, chat, activities; no path from Friends

- **What's unclear or slow:** The page states 'Fernlet's only shared content is the custom companion clothing' although friends also share photos (photo wall), session chat messages, recipes and activity titles, and it never says how to report a photo or a chat message. The 'Contact' line is plain text (not a link) and the page is reachable only from Settings > Privacy - Friends & Blocks, where blocking happens, has no link to it.
- **Recommended change:** Update the copy to list photos/messages/recipes/activities and where each report/delete lives; make Contact a tappable link; add a 'Safety & reporting' footer row at the bottom of Friends & Blocks.
- **Mockup needed:** No (code-only)
- **Evidence:** [73-safety-reporting-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/73-safety-reporting-top.png) — `App/Fernlet/SafetyReportingView.swift:23-47`, `App/Fernlet/FriendListView.swift:46-83`
- **Note:** low severity — not independently verified.

## Private

The private surfaces are careful with data but loose with reversibility: releasing a worry, deleting a journal entry and deleting a cycle day are all instant. The journal lists today's entries twice, and empty past days show a red score with nutrition headers for meals that do not exist.

### Journal page

**Current:** ![19-journal-new-entry-row.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/19-journal-new-entry-row.png) ![13-journal-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/13-journal-scrolled-1.png)

#### PRIV-01 — High — Tier 1 — Clarity — Today's entries are listed twice: under Today and Previous

- **What's unclear or slow:** Every entry written today appears in the TODAY card and again in the PREVIOUS card (dated 'Aug 16'), so a daily user sees three entries become six. The two lists also run in opposite order (Today oldest-first, Previous newest-first).
- **Recommended change:** In previousSection filter out entries whose dayKey == store.todayKey (store.previousJournals deliberately front-inserts today's entries), and render both lists newest-first so the entry just saved is at the top of Today.
- **Mockup needed:** No (code-only)
- **Evidence:** [19-journal-new-entry-row.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/19-journal-new-entry-row.png) · [13-journal-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/13-journal-scrolled-1.png) — `App/Fernlet/JournalView.swift:131-146`, `App/Fernlet/JournalView.swift:116`, `App/Fernlet/FernletStore.swift:3134-3136`
- **Also reported as:** FLOW-24

### Journal editor sheet

**Current:** ![16-journal-editor-mood-prompt-chosen.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/16-journal-editor-mood-prompt-chosen.png)

#### PRIV-02 — High — Tier 1 — Consistency & polish — Delete journal entry is instant, no confirmation or undo

- **What's unclear or slow:** Tapping the terracotta 'Delete journal entry' row deletes the entry and dismisses immediately. A mis-tap while scrolling the sheet loses a sealed entry with no confirmation and no undo, violating the nothing-destructive-happens-silently invariant.
- **Recommended change:** Wrap the delete in a confirmationDialog ('Delete this entry?' / Delete (destructive) / Keep) using the same pattern as discardConfirmation, or dismiss then show a 5-second 'Entry deleted — Undo' toast on the Journal page.
- **Mockup needed:** No (code-only)
- **Evidence:** [16-journal-editor-mood-prompt-chosen.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/16-journal-editor-mood-prompt-chosen.png) — `App/Fernlet/JournalView.swift:545-557`, `App/Fernlet/FernletStore.swift:3180-3190`
- **Also reported as:** FLOW-08

### Cycle day detail

**Current:** ![29-cycle-day-detail.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/29-cycle-day-detail.png)

#### PRIV-03 — High — Tier 1 — Consistency & polish — Cycle day Delete deletes instantly; also offered on empty days

- **What's unclear or slow:** The plain-text 'Delete' at the bottom of the cycle day detail calls periodStore.deleteEntry with no confirmation, removing HealthKit samples and the sealed note for that day and popping the screen. It is also shown (with 'Edit') on a day that has nothing logged, where it is a no-op that still pops.
- **Recommended change:** Add a confirmationDialog ('Delete this day's cycle log?' with destructive Delete + Cancel) before deleteDay, and hide Delete (show only 'Log this day') when entry.hasObservedEvent is false and narrative is nil.
- **Mockup needed:** No (code-only)
- **Evidence:** [29-cycle-day-detail.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/29-cycle-day-detail.png) — `App/Fernlet/CycleDayDetailView.swift:53-63`, `App/Fernlet/CycleTrackerView.swift:160-182`
- **Also reported as:** FLOW-09

#### PRIV-16 — Medium — Tier 1 — Clarity — Day detail shows 'Unknown', 'Health samples', 'Narrative' and text-link actions

- **What's unclear or slow:** The subtitle prints the raw phase title 'Unknown'; the two period cards are titled 'Health samples' and 'Narrative' (developer terms); Edit/Delete are bare text links at the bottom of the scroll; there is no way to log intimacy for that day; and this detail uses a ScreenHeader while the Journal day detail uses an inline nav title with an 'Edit day' capsule.
- **Recommended change:** Match the Journal day detail: inline nav title with the date, an 'Edit day' capsule in the toolbar (menu: Log/edit period, Log intimacy for this day, Delete…), subtitle omitted when phase == .unknown, cards renamed 'Flow & observations' and 'Symptoms & note'.
- **Mockup needed:** Yes
- **Evidence:** [29-cycle-day-detail.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/29-cycle-day-detail.png) · [20-journal-day-detail.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/20-journal-day-detail.png) — `App/Fernlet/CycleDayDetailView.swift:39-63`, `App/Fernlet/CycleDayDetailView.swift:76`, `App/Fernlet/CycleDayDetailView.swift:96`, `App/Fernlet/JournalView.swift:997-1015`

#### PRIV-17 — Low — Tier 1 — Clarity — Editing an empty day opens a sheet titled 'Edit period'

- **What's unclear or slow:** onEdit always passes the (placeholder) entry, so the sheet says 'Edit period' and runs editEvent even when nothing exists for that day; the user thinks something is already logged.
- **Recommended change:** Pass editingEntry: dayEntry.hasObservedEvent \|\| dayEntry.narrative != nil ? dayEntry : nil (with targetDate: day.date) so an empty day opens 'Log period' for that date.
- **Mockup needed:** No (code-only)
- **Evidence:** [30-cycle-day-detail-edit.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/30-cycle-day-detail-edit.png) · [29-cycle-day-detail.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/29-cycle-day-detail.png) — `App/Fernlet/CycleTrackerView.swift:160`, `App/Fernlet/LogPeriodSheet.swift:67`
- **Note:** low severity — not independently verified.

### Journal compose sheet

**Current:** ![14-journal-editor-new.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/14-journal-editor-new.png) ![12-private-unlocked-journal.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/12-private-unlocked-journal.png)

#### PRIV-05 — Medium — Tier 1 — Daily-use speed — New-entry sheet defaults Feeling to Neutral, overriding today's mood

- **What's unclear or slow:** The Journal '+' sheet preselects Neutral even when today is already marked Bright in the mood row. Because scoring, the calendar tint and the companion read today's LAST entry's tag, writing a note and tapping Save silently flips today's mood to Neutral unless the user re-taps a chip every time. The editor is also not focused on open, so writing takes an extra tap.
- **Recommended change:** Initialise tag from store.day.journals.last?.tag ?? .neutral, and give SheetTextEditor a FocusState that becomes true on appear so the keyboard is up when the sheet lands.
- **Mockup needed:** No (code-only)
- **Evidence:** [14-journal-editor-new.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/14-journal-editor-new.png) · [12-private-unlocked-journal.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/12-private-unlocked-journal.png) — `App/Fernlet/JournalView.swift:178-179`, `App/Fernlet/JournalView.swift:224-227`, `App/Fernlet/QuickMoodRow.swift:30-32`
- **Also reported as:** FLOW-32

#### PRIV-06 — Medium — Tier 1 — Daily-use speed — Medium detent hides the editor; Save sits below the fold

- **What's unclear or slow:** The compose sheet opens at .medium: at default type only one line of the text field is visible under the Feeling chips and prompt card, and at AX sizes the editor and Save are entirely off-screen — the user must drag the grabber up before writing.
- **Recommended change:** Present the compose/edit journal sheets at [.large] (like Log period / Edit day), or keep .medium but move the prompt card below the editor and shrink minHeight so the text field is the first thing visible; Save is already pinned and needs no change.
- **Mockup needed:** No (code-only)
- **Evidence:** [14-journal-editor-new.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/14-journal-editor-new.png) · [Sheet--Journal.png](design-refs/ux-review-2026-08-16/shots/ax/Sheet--Journal.png) · [Sheet--Journal.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Journal.png) — `App/Fernlet/ContentView.swift:687-690`, `App/Fernlet/JournalView.swift:54-58`

#### PRIV-07 — Low — Tier 1 — Clarity — 'Start from this' pastes the prompt into the entry as literal text

- **What's unclear or slow:** The plain-text link 'Start from this' inserts the daily prompt as the first line of the note; the saved entry then reads 'How tired are you, honestly? What kind of tired is it? Demo entry' in the list, and compact rows (3-line limit) can truncate the user's own words behind the question.
- **Recommended change:** Keep the prompt visible as a subdued header inside the editor card (not part of the text) and focus the field, or store the prompt as entry metadata rendered in slate above the row body; style 'Start from this' as a small chip button so it reads as an action.
- **Mockup needed:** Yes
- **Evidence:** [16-journal-editor-mood-prompt-chosen.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/16-journal-editor-mood-prompt-chosen.png) · [19-journal-new-entry-row.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/19-journal-new-entry-row.png) — `App/Fernlet/JournalView.swift:280-286`, `App/Fernlet/JournalView.swift:850-853`

### Private hub header

**Current:** ![19-journal-new-entry-row.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/19-journal-new-entry-row.png) ![32-cycle-plus-menu.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/32-cycle-plus-menu.png)

#### PRIV-13 — Medium — Tier 1 — Daily-use speed — The '+' log button scrolls off-screen with the page

- **What's unclear or slow:** The only way to write an entry or log a period/intimacy event is the '+' pill beside the ScreenHeader, which scrolls away; after returning from a day detail (scroll position preserved) the button is off-screen and the first tap hits nothing.
- **Recommended change:** Pin the primary action: place '+' (or 'Log period' / 'Log intimacy' chips) in the HubSectionPicker bar's trailing edge, or as a bottom-trailing floating pill inside the safe area, so it is always in thumb reach.
- **Mockup needed:** Yes
- **Evidence:** [19-journal-new-entry-row.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/19-journal-new-entry-row.png) · [32-cycle-plus-menu.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/32-cycle-plus-menu.png) — `App/Fernlet/JournalView.swift:77-82`, `App/Fernlet/CycleTrackerView.swift:188-194`, `App/Fernlet/PrivateHubView.swift:96-101`

### Log period sheet

**Current:** ![33-cycle-log-period-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/33-cycle-log-period-sheet.png) ![34-cycle-log-intimacy-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/34-cycle-log-intimacy-sheet.png)

#### PRIV-14 — Medium — Tier 1 — Daily-use speed — Log period has no date row and no 'which day' label

- **What's unclear or slow:** The sheet logs today with no visible date and no way to change it, so a user who forgot yesterday must back out, find the day on the calendar, open its detail, then tap Edit. Log intimacy on the same page has a date/time picker. Save is also enabled with nothing selected and dismisses without logging anything.
- **Recommended change:** Add a SheetField('Date') with a compact DatePicker(in: ...Date()) bound to eventDate above Flow level (mirroring LogIntimacySheet), and disable Save until a flow level, toggle, symptom, temperature or note has been entered.
- **Mockup needed:** No (code-only)
- **Evidence:** [33-cycle-log-period-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/33-cycle-log-period-sheet.png) · [34-cycle-log-intimacy-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/34-cycle-log-intimacy-sheet.png) — `App/Fernlet/LogPeriodSheet.swift:25`, `App/Fernlet/LogPeriodSheet.swift:43`, `App/Fernlet/LogPeriodSheet.swift:63-88`, `App/Fernlet/LogIntimacySheet.swift:65-76`
- **Also reported as:** FLOW-10

#### PRIV-15 — Medium — Tier 1 — Consistency & polish — Two unlabeled system-blue 'None' pickers in Observations

- **What's unclear or slow:** Cervical mucus and Ovulation test are SwiftUI Pickers outside a Form, so their titles are dropped: the user sees two stacked 'None ⌃⌄' menus in system blue inside a narrow cream box that hugs the content — the only blue-tint leak on the surface and an ambiguous control.
- **Recommended change:** Render each as a labeled row: 'Cervical mucus' on the left in bark, a moss-tinted Menu chip on the right showing the value; make the box full-width (.frame(maxWidth: .infinity)) and .tint(Color.moss).
- **Mockup needed:** No (code-only)
- **Evidence:** [31-cycle-day-detail-edit-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/31-cycle-day-detail-edit-scrolled.png) — `App/Fernlet/LogPeriodSheet.swift:175-195`

### Journal day detail

**Current:** ![20-journal-day-detail.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/20-journal-day-detail.png) ![21-journal-day-detail-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/21-journal-day-detail-scrolled-1.png)

#### PRIV-08 — Medium — Tier 1 — Clarity — Empty past day shows red 31% score, 'Macros today', partial-data warning

- **What's unclear or slow:** A day with nothing logged reads 'Nothing logged yet' yet renders a terracotta 'DAILY SCORE 31%' bar, a card headed 'MACROS TODAY' on a 'Yesterday' screen, 'Fiber 37g' (the target, not intake), and 'Partial nutrition data — some meals were logged without micronutrients' with zero meals. For a gentle app this reads as a red mark for a day the user did not track.
- **Recommended change:** When the day has no data, replace the score row with 'No score — nothing was logged' and hide MacroCard/micronutrients; give MacroCard a title parameter ('Macros' on day detail), label fiber 'Fiber target 37g' or show actual intake, and only show the partial-data note when meals.count > 0.
- **Mockup needed:** No (code-only)
- **Evidence:** [20-journal-day-detail.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/20-journal-day-detail.png) · [21-journal-day-detail-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/21-journal-day-detail-scrolled-1.png) — `App/Fernlet/JournalView.swift:915-927`, `App/Fernlet/JournalView.swift:1061-1088`, `App/Fernlet/JournalView.swift:1042-1047`, `App/Fernlet/HomeView.swift:2097`, `App/Fernlet/HomeView.swift:2108`

#### PRIV-33 — Low — Tier 1 — Consistency & polish — Score bar shows through the transparent title bar

- **What's unclear or slow:** When the Today detail is scrolled the review card's score pills render behind the 'Today' title and between the back and Edit day buttons.
- **Recommended change:** Add .toolbarBackground(.visible, for: .navigationBar) with Color.parchment (or the parchment scroll-edge effect) on DayDetailView.
- **Mockup needed:** No (code-only)
- **Evidence:** [26-journal-day-detail-today-food.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/26-journal-day-detail-today-food.png) — `App/Fernlet/JournalView.swift:979-1015`
- **Note:** low severity — not independently verified.

### Edit day sheet

**Current:** ![22-journal-day-edit-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/22-journal-day-edit-sheet.png) ![23-journal-day-edit-sheet-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/23-journal-day-edit-sheet-scrolled.png)

#### PRIV-09 — Medium — Tier 1 — Clarity — 'Workout name (optional)' is actually required; blank name saves nothing

- **What's unclear or slow:** The Add a workout field says the name is optional, but saveAll only writes a workout when workoutName is non-empty, so choosing a type and intensity and tapping Save silently records no workout. Sleep 'Ok' and journal 'Neutral' chips are also preselected on a day with no sleep/journal, so the sheet looks pre-filled.
- **Recommended change:** Save a workout when a type/intensity was touched (name falls back to the type's label), or drop '(optional)' from the placeholder; render Sleep and Journal chips unselected until tapped and treat an unselected sleep row as 'no change'.
- **Mockup needed:** No (code-only)
- **Evidence:** [22-journal-day-edit-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/22-journal-day-edit-sheet.png) · [23-journal-day-edit-sheet-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/23-journal-day-edit-sheet-scrolled.png) — `App/Fernlet/JournalView.swift:1470`, `App/Fernlet/JournalView.swift:1650-1660`, `App/Fernlet/JournalView.swift:1383`, `App/Fernlet/JournalView.swift:1633-1638`

### Month calendar card

**Current:** ![Private--Journal.png](design-refs/ux-review-2026-08-16/shots/light/Private--Journal.png) ![Private--Cycle_(both_halves).png](design-refs/ux-review-2026-08-16/shots/light/Private--Cycle_%28both_halves%29.png)

#### PRIV-12 — Medium — Tier 1 — Accessibility — Month chevrons are 32pt, unlabeled, and there is no 'back to today'

- **What's unclear or slow:** The previous/next month buttons are 32×32pt icon-only controls with no accessibilityLabel (VoiceOver reads the symbol name), and after paging back several months the only way home is tapping forward repeatedly. Journal calendar cells also announce 'Day 11, has data' without the feeling tag, so the mood tint is color-only.
- **Recommended change:** Give the chevrons 44×44 frames and labels 'Previous month'/'Next month', make the month title a button that jumps to the current month (subtitle 'Today' when not current), and append the tag label to JournalMonthCell.accessibilityLabel.
- **Mockup needed:** No (code-only)
- **Evidence:** [Private--Journal.png](design-refs/ux-review-2026-08-16/shots/light/Private--Journal.png) · [Private--Cycle_(both_halves).png](design-refs/ux-review-2026-08-16/shots/light/Private--Cycle_%28both_halves%29.png) — `App/Fernlet/MonthCalendarCard.swift:124-152`, `App/Fernlet/JournalView.swift:750-754`

### Worry Box

**Current:** ![37-worrybox-filed.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/37-worrybox-filed.png) ![38-worrybox-after-release.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/38-worrybox-after-release.png)

#### PRIV-20 — Medium — Tier 1 — Consistency & polish — 'Release this worry' deletes forever with no confirmation or undo

- **What's unclear or slow:** The small goldenrod text link on each card runs a 0.76s ember animation and then permanently deletes the sealed worry; there is no confirmation, no undo, and the link is a labelSmall text target well under 44pt. The page copy itself says releasing 'lets it go for good'.
- **Recommended change:** Keep the ember ceremony and skip a confirmation dialog: defer the store delete behind a 6-second 'Released — Keep it' toast that cancels it, give the link a 44pt vertical hit area, and use bark/moss text so it reads as an action.
- **Mockup needed:** No (code-only)
- **Evidence:** [37-worrybox-filed.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/37-worrybox-filed.png) · [38-worrybox-after-release.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/38-worrybox-after-release.png) — `App/Fernlet/WorryBoxView.swift:516-525`, `App/Fernlet/WorryBoxView.swift:560-587`
- **Also reported as:** FLOW-25

#### PRIV-21 — Medium — Tier 1 — Accessibility — Disabled 'Let it go' label is nearly invisible

- **What's unclear or slow:** With the field empty the whole button is drawn at 0.45 opacity: parchment ink on pale moss reads as an empty green bar (the label is unreadable), so the user cannot tell what the control does before typing.
- **Recommended change:** Use the WorryEntryView disabled treatment (moss 0.18 fill with moss 0.55 label) or keep full opacity with a cream fill and moss text when disabled so the label stays legible.
- **Mockup needed:** No (code-only)
- **Evidence:** [35-worrybox-top.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/35-worrybox-top.png) — `App/Fernlet/WorryBoxView.swift:444-456`

#### PRIV-22 — Low — Tier 1 — Clarity — Worry Box copy points to the wrong places and mixed casing

- **What's unclear or slow:** The empty state says 'First aid on the Home screen can tuck it in here' while a composer sits directly above; the First-aid confirmation says the worry is 'in the Worry Box on your Personal tab' but the tab is labelled 'Private'; labels vary 'Worry Box' (picker) / 'Worry box' (title, First aid tile); and ScreenHeader is given an empty subtitle, leaving a blank line under the title.
- **Recommended change:** Empty state: 'Write one above whenever something feels heavy.'; confirmation: '…in the Worry Box on your Private tab'; pick 'Worry box' everywhere; pass a real subtitle ('Set it down for a while.') or add a no-subtitle ScreenHeader variant.
- **Mockup needed:** No (code-only)
- **Evidence:** [35-worrybox-top.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/35-worrybox-top.png) · [47-firstaid-worrybox.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/47-firstaid-worrybox.png) · [00-home.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/00-home.png) — `App/Fernlet/WorryBoxView.swift:486`, `App/Fernlet/WorryBoxView.swift:159`, `App/Fernlet/WorryBoxView.swift:391`, `App/Fernlet/PrivateHubView.swift:20`, `App/Fernlet/FernletNavigation.swift:35`
- **Note:** low severity — not independently verified.

#### PRIV-23 — Low — Tier 1 — Daily-use speed — Worry editor is not focused on open

- **What's unclear or slow:** Arriving from First aid, the large editor shows only the placeholder; the keyboard does not appear until the user taps inside, an extra step in a 'heavy moment' flow. isEditorFocused exists but is never set true.
- **Recommended change:** Set isEditorFocused = true in .onAppear of the composer (writing phase).
- **Mockup needed:** No (code-only)
- **Evidence:** [47-firstaid-worrybox.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/47-firstaid-worrybox.png) — `App/Fernlet/WorryBoxView.swift:38`, `App/Fernlet/WorryBoxView.swift:104-106`
- **Note:** low severity — not independently verified.

### First aid > Slow breathing

**Current:** ![41-firstaid-breathing-mid.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/41-firstaid-breathing-mid.png) ![40-firstaid-breathing-start.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/40-firstaid-breathing-start.png)

#### PRIV-24 — Medium — Tier 1 — Accessibility — No progress or timer while breathing; End early is 2:1 contrast

- **What's unclear or slow:** During a session only the phase word and circle are shown — no remaining time or cycle count for a 1–3 minute exercise — and the only exit, 'End early', is softTaupe on parchment (about 2.0:1). Phase changes are not announced to VoiceOver, and the Haptics toggle has an empty label so VoiceOver reads only 'switch'.
- **Recommended change:** Colour 'End early' slate (or bark at 0.7) for contrast; post an AccessibilityNotification.Announcement on each phaseLabel change; give the haptics Toggle accessibilityLabel('Haptics'); optionally add a thin moss progress ring around the circle rather than a numeric countdown.
- **Mockup needed:** Yes
- **Evidence:** [41-firstaid-breathing-mid.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/41-firstaid-breathing-mid.png) · [40-firstaid-breathing-start.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/40-firstaid-breathing-start.png) — `App/Fernlet/BreathingExerciseView.swift:185-204`, `App/Fernlet/BreathingExerciseView.swift:374-376`, `App/Fernlet/BreathingExerciseView.swift:463-490`

#### PRIV-26 — Low — Tier 1 — Daily-use speed — Pattern, length and haptics reset every visit

- **What's unclear or slow:** preset, minutes and hapticsEnabled are plain @State, so a daily user who prefers Relax · 3 min must re-select both every time before Begin.
- **Recommended change:** Persist the last chosen preset id, minutes and haptics in @AppStorage (or FernletSettings) and seed the @State from them; Begin then repeats the last session in one tap.
- **Mockup needed:** No (code-only)
- **Evidence:** [40-firstaid-breathing-start.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/40-firstaid-breathing-start.png) — `App/Fernlet/BreathingExerciseView.swift:80-82`
- **Note:** low severity — not independently verified.

### First aid > Grounding

**Current:** ![43-firstaid-grounding-start.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/43-firstaid-grounding-start.png) ![44-firstaid-grounding-step2.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/44-firstaid-grounding-step2.png)

#### PRIV-27 — Medium — Tier 1 — Accessibility — Tap-anywhere advance has no VoiceOver action or step-back

- **What's unclear or slow:** Progress relies on a tap gesture on the whole ZStack: VoiceOver users have no button or custom action to advance, an accidental tap skips a sense with no way back except 'Begin again' at the end, and the screen shows both an inline nav title 'Grounding' and a 'GROUNDING' kicker.
- **Recommended change:** Add .accessibilityAction(named: 'Next') and a visible small 'Next' pill beside the dots plus a 'Back' text button; keep tap-anywhere as a bonus; drop the kicker or hide the nav title.
- **Mockup needed:** No (code-only)
- **Evidence:** [43-firstaid-grounding-start.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/43-firstaid-grounding-start.png) · [44-firstaid-grounding-step2.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/44-firstaid-grounding-step2.png) — `App/Fernlet/GroundingView.swift:123-127`, `App/Fernlet/GroundingView.swift:101-107`, `App/Fernlet/GroundingView.swift:235-244`

### Cycle page

**Current:** ![Private--Cycle_(both_halves).png](design-refs/ux-review-2026-08-16/shots/light/Private--Cycle_%28both_halves%29.png) ![27-cycle-top.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/27-cycle-top.png)

#### PRIV-18 — Low — Tier 1 — Daily-use speed — Empty predictions card and primer push the calendar below the fold

- **What's unclear or slow:** Above the calendar sit the one-time primer and a full FernletCard containing only 'Log at least 3 cycles to see predictions.'; the calendar (the thing a daily user comes for) starts at the bottom edge and today's cell is off-screen.
- **Recommended change:** While prediction == nil, render the hint as a single slate line under the calendar (or in the header subtitle) instead of a card, and move the primer below the calendar.
- **Mockup needed:** No (code-only)
- **Evidence:** [Private--Cycle_(both_halves).png](design-refs/ux-review-2026-08-16/shots/light/Private--Cycle_%28both_halves%29.png) · [27-cycle-top.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/27-cycle-top.png) — `App/Fernlet/CycleTrackerView.swift:116-145`, `App/Fernlet/CycleTrackerView.swift:467-500`
- **Note:** low severity — not independently verified.

### Log intimacy sheet

**Current:** ![34-cycle-log-intimacy-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/34-cycle-log-intimacy-sheet.png) ![Sheet--Log_intimacy.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Log_intimacy.png)

#### PRIV-19 — Low — Tier 1 — Consistency & polish — Apple Health card is narrower than the fields above it

- **What's unclear or slow:** The Apple Health status card hugs its text and ends short of the right edge, misaligned with the full-width date and note fields.
- **Recommended change:** Add .frame(maxWidth: .infinity, alignment: .leading) to the card's VStack before .padding(14).
- **Mockup needed:** No (code-only)
- **Evidence:** [34-cycle-log-intimacy-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/34-cycle-log-intimacy-sheet.png) · [Sheet--Log_intimacy.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Log_intimacy.png) — `App/Fernlet/LogIntimacySheet.swift:94-123`
- **Also reported as:** XCUT-25
- **Note:** low severity — not independently verified.

### First aid

**Current:** ![42-firstaid-breathing-finish.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/42-firstaid-breathing-finish.png) ![46-firstaid-grounding-finish.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/46-firstaid-grounding-finish.png)

#### PRIV-25 — Low — Tier 1 — Consistency & polish — Breathing 'Done for now' and Grounding 'Done' exit to different places

- **What's unclear or slow:** After breathing, 'Done for now' resets to the breathing setup screen (still inside the tool); after grounding, 'Done' pops back to the First aid hub. Two identically named secondary actions in sibling tools behave differently.
- **Recommended change:** Make both 'Done' dismiss to the First aid hub (breathing keeps 'Once more' for a repeat), and label the secondary action 'Done' in both.
- **Mockup needed:** No (code-only)
- **Evidence:** [42-firstaid-breathing-finish.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/42-firstaid-breathing-finish.png) · [46-firstaid-grounding-finish.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/46-firstaid-grounding-finish.png) — `App/Fernlet/BreathingExerciseView.swift:244-246`, `App/Fernlet/BreathingExerciseView.swift:441-446`, `App/Fernlet/GroundingView.swift:204`

### Lock setup

**Current:** ![02-private-lock-setup-prompt.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/02-private-lock-setup-prompt.png) ![01-private-lock-gate.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/01-private-lock-gate.png)

#### PRIV-28 — Low — Tier 1 — Clarity — Lock-type copy misstates what the lock protects; 'Recommended' twice

- **What's unclear or slow:** Step 1 says 'Your lock type protects the period and intimacy sections' while the gate it was opened from says 'journal, period, and intimacy history' and neither mentions the Worry Box; the 6-digit card shows a RECOMMENDED badge and a 'Recommended' subtitle.
- **Recommended change:** Use one sentence in both places: 'Protects your journal, cycle, intimacy notes and worry box.'; change the 6-digit subtitle to 'Good balance of speed and security'.
- **Mockup needed:** No (code-only)
- **Evidence:** [02-private-lock-setup-prompt.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/02-private-lock-setup-prompt.png) · [01-private-lock-gate.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/01-private-lock-gate.png) — `FernletKit/Sources/FernletLockUI/FernletLockView.swift:114`, `FernletKit/Sources/FernletLockUI/FernletLockView.swift:121`, `FernletKit/Sources/FernletLockUI/FernletLockGate.swift:299`
- **Note:** low severity — not independently verified.

#### PRIV-29 — Low — Tier 1 — Consistency & polish — Success toast covers Continue on a still-live step for 1.5s

- **What's unclear or slow:** After confirming the disclosure, the sheet stays on the Biometric step with Cancel and Continue still tappable while an 'App lock is set up.' toast overlaps the Continue button, then auto-dismisses; tapping Continue again re-opens the disclosure.
- **Recommended change:** On success either dismiss immediately and let the presenting gate show the toast, or swap the step content for a 'You're set' state (checkmark + one line) with the toolbar Cancel hidden and Continue disabled while the toast dwells.
- **Mockup needed:** No (code-only)
- **Evidence:** [07-private-lock-setup-toast.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/07-private-lock-setup-toast.png) · [08-private-journal-after-setup.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/08-private-journal-after-setup.png) — `FernletKit/Sources/FernletLockUI/FernletLockView.swift:409-415`, `FernletKit/Sources/FernletLockUI/FernletLockView.swift:457-475`
- **Also reported as:** SETT-36

### Lock gate

**Current:** ![11-private-lock-gate-wrong-pin-result.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/11-private-lock-gate-wrong-pin-result.png)

#### PRIV-30 — Low — Tier 1 — Accessibility — PIN dots and attempts-remaining lack accessible state/contrast

- **What's unclear or slow:** The dot row is decorative circles with no accessibility value, so VoiceOver users cannot tell how many digits are entered; the '3 attempts remaining before lockout' line is goldenrod on parchment (about 2.2:1).
- **Recommended change:** Give pinDotsRow accessibilityElement(children: .ignore) with label '\(current.count) of \(total) digits entered' (updated live), and colour the attempts line terracotta or bark.
- **Mockup needed:** No (code-only)
- **Evidence:** [11-private-lock-gate-wrong-pin-result.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/11-private-lock-gate-wrong-pin-result.png) — `FernletKit/Sources/FernletLockUI/FernletLockView.swift:993-1002`, `FernletKit/Sources/FernletLockUI/FernletLockView.swift:583-589`
- **Note:** low severity — not independently verified.

## Settings

Settings is the least house-styled part of the app — system fonts, system-tinted toggles, developer surfaces in the user-facing hub — and its two heaviest pages ('Goal & nutrition' and 'Privacy & Data') stack a dozen unrelated sections each. The delete-everything alert is a 180-word wall under a header about the app lock.

### Settings > Goal & nutrition

**Current:** ![59-settings-goal-nutrition-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/59-settings-goal-nutrition-scrolled-1.png) ![61-settings-goal-nutrition-scrolled-3.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/61-settings-goal-nutrition-scrolled-3.png) ![63-settings-goal-nutrition-scrolled-5.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/63-settings-goal-nutrition-scrolled-5.png)

#### SETT-34 — High — Tier 1 — Clarity — Direct $store.settings bindings may not persist until another save

- **What's unclear or slow:** DiaryStore.settings has no didSet and its doc says 'mutate through the setter methods so every change schedules a snapshot save'. Goal presets use setSelectedGoal (schedules a save) but 'Show calories', 'Web nutrition lookup', 'Manual off mode', weather prompts, 'Manual plan exchange', the five trainer-summary toggles, Bottle/Daily target steppers, and the body-profile/preferences bindings write `$store.settings.*` directly. flushPendingSnapshotSave only flushes a PENDING save, so a user who flips Show calories and backgrounds/force-quits without logging anything can find it reverted. Needs a device check: toggle Show calories, force-quit, relaunch.
- **Recommended change:** Give each of these a store setter that assigns and calls scheduleSnapshotSave() (or add an onChange on store.settings in SettingsSheet that schedules a save), so every Settings change is durable the moment it is made.
- **Mockup needed:** No (code-only)
- **Evidence:** [59-settings-goal-nutrition-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/59-settings-goal-nutrition-scrolled-1.png) · [61-settings-goal-nutrition-scrolled-3.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/61-settings-goal-nutrition-scrolled-3.png) · [63-settings-goal-nutrition-scrolled-5.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/63-settings-goal-nutrition-scrolled-5.png) — `App/Fernlet/SettingsSheet.swift:1308`, `App/Fernlet/SettingsSheet.swift:1338`, `App/Fernlet/SettingsSheet.swift:1345-1357`, `App/Fernlet/SettingsSheet.swift:1387`, `App/Fernlet/SettingsSheet.swift:1403-1407`, `App/Fernlet/SettingsSheet.swift:1496-1498`, `App/Fernlet/SettingsSheet.swift:1504-1509`, `App/Fernlet/SettingsSheet.swift:1243-1251`, `App/Fernlet/SettingsSheet.swift:1318`, `FernletKit/Sources/DiaryStore/DiaryStore.swift:62-64`, `FernletKit/Sources/DiaryStore/DiaryStore.swift:411-414`, `App/Fernlet/FernletStore.swift:5335-5347`

#### SETT-14 — Medium — Tier 2 — Clarity — One page holds 12 unrelated sections behind 'Goal & nutrition'

- **What's unclear or slow:** Under the title 'Goal & nutrition' the scroll contains Goal, Sick mode/Show calories, Body profile, Preferences, Nutrition targets, AI (web lookup, weather prompts), Coach, Body signals, Reminders (daily check-in), Hydration and Personal care tasks. A daily user looking for the reminder time, the AI switch or their care checklist has no reason to open 'Goal & nutrition'; the hub meanwhile spends rows on Sleep and Move that hold no settings.
- **Recommended change:** Split into hub rows that match user intent: 'Goal & nutrition' (goal, calories, body, targets, hydration), 'Reminders', 'AI & data sources' (AI status, web lookup, weather, body signals), 'Personal care tasks', and fold Coach into Move; the search breadcrumbs then match.
- **Mockup needed:** Yes
- **Evidence:** [58-settings-goal-nutrition.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/58-settings-goal-nutrition.png) · [61-settings-goal-nutrition-scrolled-3.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/61-settings-goal-nutrition-scrolled-3.png) · [63-settings-goal-nutrition-scrolled-5.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/63-settings-goal-nutrition-scrolled-5.png) · [Settings--Hub.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Hub.png) — `App/Fernlet/SettingsSheet.swift:1272-1283`, `App/Fernlet/SettingsSheet.swift:235-252`

#### SETT-15 — Medium — Tier 2 — Daily-use speed — Sick mode, a today-only state, is buried three levels deep

- **What's unclear or slow:** 'Sick mode' is bound to `store.setSick(_:on: store.todayKey)` — it is a per-day flag, not a preference — yet its only control is Settings › Goal & nutrition, below seven goal cards. On the day someone actually feels unwell it takes Home → Settings → Goal & nutrition → scroll to reach it (grep shows no other UI calls setSick).
- **Recommended change:** Surface 'I'm unwell today' where the day lives — the Home Today card / companion menu or as a Quick-log shortcut option — and leave Settings with only the explanation of what sick mode changes.
- **Mockup needed:** Yes
- **Evidence:** [59-settings-goal-nutrition-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/59-settings-goal-nutrition-scrolled-1.png) — `App/Fernlet/SettingsSheet.swift:1303-1311`

#### SETT-16 — Medium — Tier 1 — Clarity — 'Manual off mode' toggle is a double negative

- **What's unclear or slow:** The card shows 'Current: Off' and a toggle 'Manual off mode' that is ON — the switch being green means the AI is off. Users must invert twice to know what a tap will do; the same card's other switches ('Web nutrition lookup', 'Weather-aware…') are positive.
- **Recommended change:** Rename to a positive toggle 'On-device AI helper' (ON = ready), keep the 'Today: resting / ready' status line beneath it in the companion voice.
- **Mockup needed:** No (code-only)
- **Evidence:** [61-settings-goal-nutrition-scrolled-3.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/61-settings-goal-nutrition-scrolled-3.png) — `App/Fernlet/SettingsSheet.swift:1326-1369`, `App/Fernlet/SettingsSheet.swift:1504-1509`

#### SETT-17 — Medium — Tier 1 — Clarity — Calories shown and editable while 'Show calories' is off

- **What's unclear or slow:** 'Show calories' is OFF in the card directly above, yet NUTRITION TARGETS lists 'Calories 2,650 cal' as its first editable row and the footnote talks about 'your calories'. The two surfaces disagree, and calorie numbers appear without the opt-in.
- **Recommended change:** When showCalories is false, hide the Calories row and reword the footnote to protein/fat/carbs, with a one-line 'Turn on Show calories to set a calorie target' link that flips the toggle.
- **Mockup needed:** No (code-only)
- **Evidence:** [59-settings-goal-nutrition-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/59-settings-goal-nutrition-scrolled-1.png) · [60-settings-goal-nutrition-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/60-settings-goal-nutrition-scrolled-2.png) — `App/Fernlet/NutritionTargetsEditor.swift:101-102`, `App/Fernlet/SettingsSheet.swift:1308`, `App/Fernlet/SettingsSheet.swift:1320`

#### SETT-18 — Low — Tier 1 — Consistency & polish — Doubled section labels and a half-width Preferences card

- **What's unclear or slow:** 'BODY & PREFERENCES' (SectionLabel) is immediately followed by 'BODY PROFILE' (SheetField label) with nothing between — two stacked uppercase labels. The 'PREFERENCES' card below hugs its content and renders about 40% width while every other card is full width.
- **Recommended change:** Drop the outer 'Body & preferences' SectionLabel (the two SheetField labels already name the cards) and give the Preferences VStack `.frame(maxWidth: .infinity, alignment: .leading)` inside profileFieldStyle.
- **Mockup needed:** No (code-only)
- **Evidence:** [59-settings-goal-nutrition-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/59-settings-goal-nutrition-scrolled-1.png) · [60-settings-goal-nutrition-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/60-settings-goal-nutrition-scrolled-2.png) — `App/Fernlet/SettingsSheet.swift:1316-1321`, `App/Fernlet/OnboardingView.swift:40-58`, `App/Fernlet/OnboardingView.swift:78-87`
- **Note:** low severity — not independently verified.

### Settings hub

**Current:** ![Settings--Hub.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Hub.png) ![51-settings-hub-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/51-settings-hub-scrolled-1.png) ![53-settings-hub-scrolled-3.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/53-settings-hub-scrolled-3.png)

#### SETT-02 — Medium — Tier 1 — Consistency & polish — Hub rows use system font, system-green toggles, system-red destructive

- **What's unclear or slow:** The hub Form's NavigationLinks, section headers/footers and Toggles carry no `.font(.fernlet(...))`, so every row ('Appearance', 'Period tracking', 'Allow nearby hearts') renders in SF Pro while every sub-page uses DM Sans/serif. All hub toggles (Period tracking, Intimacy tracking, six nearby-friends toggles, Dark mode) show the iOS default green, whereas Privacy & Data toggles are tinted moss. 'Delete everything' in Danger zone is system red, App lock's 'Reset app lock' is terracotta, Privacy & Data's is a filled terracotta button — three destructive styles. Root cause: `.tint(Color.moss)` is applied to the tab content in ContentView, but the Settings sheet is a separate presentation and never receives it.
- **Recommended change:** Add `.tint(Color.moss)` on the SettingsSheet NavigationStack (or inside fernletSheetChrome so every sheet inherits it), apply `.font(.fernlet(.label))` to hub rows/toggles and `.font(.fernlet(.labelSmall))` to section headers, and render 'Delete everything' with the same terracotta text+trash-icon row used by App lock's Danger zone.
- **Mockup needed:** No (code-only)
- **Evidence:** [Settings--Hub.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Hub.png) · [51-settings-hub-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/51-settings-hub-scrolled-1.png) · [53-settings-hub-scrolled-3.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/53-settings-hub-scrolled-3.png) · [54-settings-hub-scrolled-4.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/54-settings-hub-scrolled-4.png) — `App/Fernlet/SettingsSheet.swift:206-219`, `App/Fernlet/SettingsSheet.swift:235-252`, `App/Fernlet/SettingsSheet.swift:256-264`, `App/Fernlet/SettingsSheet.swift:345-376`, `App/Fernlet/SettingsSheet.swift:1889-1901`, `App/Fernlet/ContentView.swift:513`, `App/Fernlet/ContentView.swift:718`
- **Also reported as:** XCUT-12

#### SETT-13 — Medium — Tier 1 — Clarity — Search catalog is static: stale, missing, and mis-targeted results

- **What's unclear or slow:** Results come from a hand-written list with no state: 'Set up app lock' is offered after a lock exists; 'Share with a trainer' routes to Privacy & Data where no such row exists (walker landed on the verify gate); hub-level controls are not indexed at all — 'period' never finds the Period tracking toggle, 'hearts', 'presence', 'recipe', 'vibe', 'duress', 'recovery device' return nothing or an unrelated page. Tapping any result pushes the page top with no anchor, so 'Water bottle size' drops the user at the top of the 12-section Goal & nutrition page. The field also auto-capitalises the query ('Lock').
- **Recommended change:** Give SettingsSearchIndex.results a context (lock configured, visibility) to drop stale entries; delete or re-route the trainer entry to Move; add entries for every hub toggle (route .hub with a section anchor) and for Duress code / Recovery device; carry an anchor id per entry and scroll to it via ScrollViewReader after the push; add `.textInputAutocapitalization(.never)`.
- **Mockup needed:** No (code-only)
- **Evidence:** [55-settings-search-lock.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/55-settings-search-lock.png) · [56-settings-search-coach.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/56-settings-search-coach.png) · [105-settings-share-with-trainer-via-search.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/105-settings-share-with-trainer-via-search.png) — `App/Fernlet/SettingsSearchIndex.swift:80-88`, `App/Fernlet/SettingsSearchIndex.swift:430-435`, `App/Fernlet/SettingsSearchIndex.swift:466-471`, `App/Fernlet/SettingsSheet.swift:97`, `App/Fernlet/SettingsSheet.swift:135-161`, `App/Fernlet/SettingsSheet.swift:166-204`

#### SETT-28 — Medium — Tier 2 — Clarity — Developer surfaces sit in the user-facing hub; Debug card contradicts itself

- **What's unclear or slow:** 'Debug' opens a page headed 'Prototype only — not production-private' with a hardcoded 'Storage: local JSON database' line directly above 'File: Core Data + iCloud'; 'Connection Inspector' and 'Connection History' are both hub rows and the Inspector page links to History again. For a daily user these are noise in the primary hub.
- **Recommended change:** Gate the Debug page behind #if DEBUG and derive its storage line from store.storageLocation only; collapse Connection Inspector + History into one 'Connection log' row at the bottom of Advanced (keep it user-reachable as a transparency surface) and drop the duplicate hub row.
- **Mockup needed:** No (code-only)
- **Evidence:** [78-settings-debug.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/78-settings-debug.png) · [79-settings-connection-inspector.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/79-settings-connection-inspector.png) · [52-settings-hub-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/52-settings-hub-scrolled-2.png) — `App/Fernlet/SettingsSheet.swift:305-314`, `App/Fernlet/SettingsSheet.swift:1692-1703`, `App/Fernlet/SettingsSheet.swift:1705-1720`, `App/Fernlet/SettingsSheet.swift:1855-1870`

#### SETT-29 — Medium — Tier 1 — Clarity — Six nearby-friends toggles filed under 'Privacy' with a 90-word footer

- **What's unclear or slow:** The Privacy section starts with four navigation rows (Privacy & Data, Privacy Policy, Safety & reporting, App lock) then runs into 'Allow nearby recipe shares', 'Share clothing shops with friends', 'Allow nearby hearts', 'Deliver hearts when apart', 'Nearby friends presence', 'Share your vibe with friends' and a paragraph-long footer. Someone changing a friends setting won't look under Privacy, and the dependency (hearts need presence) is explained only in the footer.
- **Recommended change:** Add a 'Nearby friends' section (or a 'Friends & sharing' sub-page) ordered Presence → Vibe → Hearts → Away delivery → Recipe shares → Clothing shops, each with a one-line footnote, leaving Privacy with its four links.
- **Mockup needed:** Yes
- **Evidence:** [53-settings-hub-scrolled-3.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/53-settings-hub-scrolled-3.png) · [54-settings-hub-scrolled-4.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/54-settings-hub-scrolled-4.png) — `App/Fernlet/SettingsSheet.swift:319-340`, `App/Fernlet/SettingsSheet.swift:343-393`, `App/Fernlet/SettingsSheet.swift:442-462`

#### SETT-33 — Medium — Tier 1 — Accessibility — Bottom Done pill and intro paragraph leave one row visible at AX

- **What's unclear or slow:** The hub keeps a permanent bottom safeAreaInset with a large moss 'Done' pill plus a serif intro paragraph above the first section. At AX sizes the search field, paragraph and Done bar consume the screen so only 'Appearance' is visible; every other sheet closes via drag or a toolbar button.
- **Recommended change:** Move Done to the navigation bar trailing slot (keeping the wipe-in-progress disable), and shorten the intro to a one-line section footer under Privacy ('Your data stays on this phone unless you turn on iCloud sync.').
- **Mockup needed:** No (code-only)
- **Evidence:** [Settings--Hub.png](design-refs/ux-review-2026-08-16/shots/ax/Settings--Hub.png) · [Settings--Hub.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Hub.png) — `App/Fernlet/SettingsSheet.swift:98-100`, `App/Fernlet/SettingsSheet.swift:1903-1917`, `App/Fernlet/SettingsSheet.swift:221-233`

### Settings > Privacy & Data

**Current:** ![103-settings-delete-everything-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/103-settings-delete-everything-confirm.png) ![99-settings-privacy-data-delete-icloud-dialog.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/99-settings-privacy-data-delete-icloud-dialog.png)

#### SETT-08 — Medium — Tier 1 — Clarity — Delete-everything alert is a 180-word wall with a plain Delete

- **What's unclear or slow:** The confirmation is one system alert three paragraphs long (what goes / what stays / Health caveat) filling the whole screen, ending in Cancel + 'Delete'. Meanwhile the LESSER action 'Delete iCloud data' gets a custom sheet with a typed-DELETE gate. The most destructive action in the app is the one-tap one, and the copy is unscannable (worse at AX sizes).
- **Recommended change:** Present 'Delete everything?' as the same custom sheet shape as the iCloud one: ScreenHeader, two short cards 'This deletes' / 'Kept on purpose' as bullet lists, the Health note, a typed-DELETE (or hold-to-confirm) field, then a terracotta 'Delete everything' and a Cancel.
- **Mockup needed:** Yes
- **Evidence:** [103-settings-delete-everything-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/103-settings-delete-everything-confirm.png) · [99-settings-privacy-data-delete-icloud-dialog.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/99-settings-privacy-data-delete-icloud-dialog.png) — `App/Fernlet/DeleteAllDataConfirmation.swift:36-52`, `App/Fernlet/DeleteAllDataConfirmation.swift:59-142`, `App/Fernlet/DestructiveConfirmation.swift:75-93`, `App/Fernlet/PrivacyDataSettingsView.swift:1132-1167`

#### SETT-09 — Medium — Tier 1 — Clarity — 'Delete iCloud data' opens 'Turn off iCloud sync?' sheet

- **What's unclear or slow:** With sync OFF and 'No Fernlet iCloud records were found', the full-width terracotta 'Delete iCloud data' button still sits in the primary position, and tapping it opens the shared disable-sync sheet titled 'Turn off iCloud sync?' offering 'Stop syncing, keep iCloud data' — neither applies. Inside, the destructive 'Delete iCloud data' confirm is styled moss (the app's positive colour), and its disabled state is moss at 40%.
- **Recommended change:** When entered from the button (sync already off) title the sheet 'Delete iCloud data?' and hide the 'Stop syncing' option; when no cloud records exist, demote the button to a slate text link or hide it; colour the confirm terracotta.
- **Mockup needed:** No (code-only)
- **Evidence:** [99-settings-privacy-data-delete-icloud-dialog.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/99-settings-privacy-data-delete-icloud-dialog.png) · [97-settings-privacy-data-top.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/97-settings-privacy-data-top.png) — `App/Fernlet/PrivacyDataSettingsView.swift:455-466`, `App/Fernlet/PrivacyDataSettingsView.swift:1095-1113`, `App/Fernlet/PrivacyDataSettingsView.swift:1132-1203`, `App/Fernlet/PrivacyDataSettingsView.swift:1581-1585`

#### SETT-10 — Medium — Tier 1 — Clarity — 'Delete everything' lives under an 'App lock data' header

- **What's unclear or slow:** The final card is headed APP LOCK DATA with copy about the Fernlet passcode being separate from the device passcode, and then the red 'Delete everything' button. The header and paragraph describe neither the button nor its scope; the search index even breadcrumbs it as 'Privacy & Data › App lock data'.
- **Recommended change:** Rename the card 'Delete your data' with a one-line summary ('Erase everything Fernlet stores on this phone and in your iCloud'), move the passcode note into the App lock page, and update the breadcrumb.
- **Mockup needed:** No (code-only)
- **Evidence:** [101-settings-privacy-data-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/101-settings-privacy-data-scrolled-2.png) — `App/Fernlet/PrivacyDataSettingsView.swift:1027-1039`, `App/Fernlet/SettingsSearchIndex.swift:436-441`

#### SETT-11 — Medium — Tier 1 — Consistency & polish — 'Lock photos to this device' styled like a delete button

- **What's unclear or slow:** An irreversible-but-protective action ('Lock photos to this device') is rendered as the same full-width terracotta trash-style button as 'Delete iCloud data', wedged between the sealed-backup toggles and their explanatory paragraphs. Two red buttons in one card read as two deletes; the walker's first tap on the paragraph below did nothing.
- **Recommended change:** Move the photo device-binding into its own 'Photo protection' card with a moss-outlined secondary button (lock icon) and its explanation; keep terracotta filled buttons exclusively for deletion.
- **Mockup needed:** Yes
- **Evidence:** [97-settings-privacy-data-top.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/97-settings-privacy-data-top.png) · [104-settings-privacy-data-lock-photos-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/104-settings-privacy-data-lock-photos-confirm.png) — `App/Fernlet/PrivacyDataSettingsView.swift:535-583`, `App/Fernlet/PrivacyDataSettingsView.swift:598-615`

#### SETT-12 — Medium — Tier 1 — Daily-use speed — Every visit needs an extra 'Verify to continue' tap

- **What's unclear or slow:** With an app lock set, Privacy & Data shows a 'FRESH VERIFICATION REQUIRED' card and waits for a button tap before running LAContext; the system passcode/Face ID sheet is not invoked on appear. Arriving from a search result ('Export my data', 'Sync to iCloud') lands on this card too, so a routine change is: hub → search → tap result → tap Verify → Face ID → scroll to the row.
- **Recommended change:** Call verifyFreshAccess() from `.task` on first appear (keeping the card + button only as the retry state after a cancel/failure), and honour a scroll anchor from search so the verified page opens at the requested card.
- **Mockup needed:** No (code-only)
- **Evidence:** [95-settings-privacy-data.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/95-settings-privacy-data.png) · [96-settings-privacy-data-verify.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/96-settings-privacy-data-verify.png) · [105-settings-share-with-trainer-via-search.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/105-settings-share-with-trainer-via-search.png) — `App/Fernlet/PrivacyDataSettingsView.swift:269-312`, `App/Fernlet/PrivacyDataSettingsView.swift:1555-1579`

#### SETT-35 — Low — Tier 1 — Clarity — Toggle feedback is an alert or a page-bottom error; walker saw none

- **What's unclear or slow:** Sync to iCloud, the five sealed-backup switches and Health integration all defer their effect: enable paths show a consent alert (`isShowingEnableConfirmation`, `pendingSealedBackupEnable`) and any failure (e.g. Health unavailable on this device, escrow key missing) is written to `operationError`, rendered as a single terracotta line at the very bottom of the page under Delete everything — far from the switch that snapped back. The walker reported all of these toggles doing nothing at all after verification (no alert, no movement); I could not find a code path that explains that, so treat it as a lead to reproduce on device.
- **Recommended change:** Render each card's failure inline beneath the switch that failed (per-card error string) and disable-with-reason the sealed-backup toggles when iCloud sync/escrow is missing; treat the walker's no-response report as an on-device repro lead, not a finding.
- **Mockup needed:** No (code-only)
- **Evidence:** [97-settings-privacy-data-top.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/97-settings-privacy-data-top.png) · [98-settings-privacy-data-sealed-backup-toggle-inert.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/98-settings-privacy-data-sealed-backup-toggle-inert.png) — `App/Fernlet/PrivacyDataSettingsView.swift:216-240`, `App/Fernlet/PrivacyDataSettingsView.swift:377-383`, `App/Fernlet/PrivacyDataSettingsView.swift:1256-1268`, `App/Fernlet/PrivacyDataSettingsView.swift:1359-1381`, `App/Fernlet/PrivacyDataSettingsView.swift:1499-1521`, `App/Fernlet/PrivacyDataSettingsView.swift:1696-1714`

### Settings > Core memory

**Current:** ![73-settings-core-memory-editor.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/73-settings-core-memory-editor.png) ![74-settings-core-memory-editor-typed.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/74-settings-core-memory-editor-typed.png)

#### SETT-22 — Medium — Tier 1 — Consistency & polish — Memory editor has no Cancel; counter, date, delete below the fold

- **What's unclear or slow:** The editor opens at .medium with a serif 'Core memory' title, free-text 'Category' field showing lowercase 'bright', the text box, and Save — the 0/240 counter, source date and 'Delete memory' are only reachable by scrolling inside the half sheet. There is no Cancel/close control (only the drag handle), unlike sibling sheets which use SheetCancelBar or a toolbar Cancel. Category is an unconstrained TextField though the list groups memories by category.
- **Recommended change:** Add SheetCancelBar at the top, open at .large (or move counter + delete above the fold), and replace the free-text Category with ChipButtonStyle chips of the existing categories (title-cased) plus 'Other'.
- **Mockup needed:** No (code-only)
- **Evidence:** [73-settings-core-memory-editor.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/73-settings-core-memory-editor.png) · [74-settings-core-memory-editor-typed.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/74-settings-core-memory-editor-typed.png) — `App/Fernlet/SettingsSheet.swift:944-949`, `App/Fernlet/SettingsSheet.swift:1980-2045`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:300-320`

### Settings > Layout & shortcuts

**Current:** ![66-settings-layout-shortcuts-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/66-settings-layout-shortcuts-scrolled-1.png) ![67-settings-layout-shortcuts-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/67-settings-layout-shortcuts-scrolled-2.png)

#### SETT-23 — Medium — Tier 1 — Clarity — Six slots each repeat the full 8-chip palette; Log period vs Period

- **What's unclear or slow:** Each of the six quick-log slots renders every unselected shortcut as a chip, so the page shows ~48 chips and each slot's list silently omits items chosen elsewhere. Two chips read 'Log period' (opens the log sheet) and 'Period' (opens the Cycle page) with nothing to tell them apart.
- **Recommended change:** Show the six chosen shortcuts as one reorderable list; tapping a slot opens a single chip picker (or a menu) for that slot. Rename 'Period' → 'Cycle page' (or 'Cycle') and keep 'Log period'.
- **Mockup needed:** Yes
- **Evidence:** [66-settings-layout-shortcuts-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/66-settings-layout-shortcuts-scrolled-1.png) · [67-settings-layout-shortcuts-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/67-settings-layout-shortcuts-scrolled-2.png) — `App/Fernlet/SettingsSheet.swift:770-815`, `App/Fernlet/SettingsSheet.swift:832-844`, `FernletKit/Sources/FernletDomainModel/NavigationEnums.swift:205-206`

#### SETT-24 — Medium — Tier 1 — Accessibility — Reorder chevrons are 28×24pt icon-only; AX breaks 'Companio n'

- **What's unclear or slow:** Every widget/slot row uses two stacked chevron.up/down buttons framed 28×24pt (below 44pt) with no accessibilityLabel, plus an unlabeled xmark.circle.fill remove button; the disabled state is colour-only. At AX sizes the fixed frames squeeze the label so 'Companion' wraps mid-word as 'Companio / n'.
- **Recommended change:** Use a List with `.onMove` (drag handle) and `.onDelete`, or give the chevrons 44pt hit areas with accessibilityLabels 'Move up/down' and hide them when disabled; let the Label take layout priority so it wraps at word boundaries.
- **Mockup needed:** No (code-only)
- **Evidence:** [Settings--Layout_&_shortcuts.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Layout_&_shortcuts.png) · [Settings--Layout_&_shortcuts.png](design-refs/ux-review-2026-08-16/shots/ax/Settings--Layout_&_shortcuts.png) · [66-settings-layout-shortcuts-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/66-settings-layout-shortcuts-scrolled-1.png) — `App/Fernlet/SettingsSheet.swift:709-747`, `App/Fernlet/SettingsSheet.swift:773-800`

#### SETT-25 — Low — Tier 1 — Clarity — Companion widget can be removed from Home with one tap

- **What's unclear or slow:** The 'Companion' row carries the same X as every other widget and removeHomeWidget has no guard, so one tap (no confirmation) removes the companion from Home — the surface the product treats as the emotional centre.
- **Recommended change:** Pin Companion (no X; still reorderable) and say so in the card copy; if removal must stay possible, route it through DestructiveConfirmation.
- **Mockup needed:** No (code-only)
- **Evidence:** [Settings--Layout_&_shortcuts.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Layout_&_shortcuts.png) — `App/Fernlet/SettingsSheet.swift:709-747`, `App/Fernlet/SettingsSheet.swift:756-760`, `App/Fernlet/HomeView.swift:275-278`
- **Note:** low severity — not independently verified.

### Settings > Wellness

**Current:** ![68-settings-health.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/68-settings-health.png) ![69-settings-sleep.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/69-settings-sleep.png) ![70-settings-move.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/70-settings-move.png)

#### SETT-26 — Medium — Tier 2 — Clarity — Sleep and Move rows are dead ends; Health repeats itself

- **What's unclear or slow:** 'Sleep' opens a read-only card of today's sleep with no setting; 'Move' shows a placeholder 'Available after Apple Fitness integration lands (M2)' — an internal milestone tag — with a permanently disabled 'Request access' button, even though workout Health sync already exists under Health/Privacy & Data. 'Health' shows the same 'Health data is not available on this device.' sentence twice (EmptyState + statusMessage) under a developer-voice intro about read-denial status.
- **Recommended change:** Remove the Sleep and Move rows (or hide Move until it works, without '(M2)'); collapse the Wellness section to a single 'Health' row; show the unavailable message once and rewrite the intro in user voice ('Fernlet asks for Health access only when a feature needs it.').
- **Mockup needed:** No (code-only)
- **Evidence:** [68-settings-health.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/68-settings-health.png) · [69-settings-sleep.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/69-settings-sleep.png) · [70-settings-move.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/70-settings-move.png) · [Settings--Sleep.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Sleep.png) · [Settings--Move.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Move.png) — `App/Fernlet/SettingsSheet.swift:1013-1034`, `App/Fernlet/SettingsSheet.swift:864-897`, `App/Fernlet/SettingsSheet.swift:1036-1058`

#### SETT-27 — Medium — Tier 2 — Consistency & polish — Two Health permission surfaces with different controls and vocabulary

- **What's unclear or slow:** Settings › Health lists per-capability cards with 'Give access / Update data / Revoke access' buttons; Privacy & Data › HealthKit lists a master 'Health integration' switch plus per-capability toggles named with internal titles ('Body context', 'Activity context', 'Intimate logging'). A user has to learn which page owns what; the toggles here can be on while the other page shows 'Give access', and vice versa.
- **Recommended change:** Make Settings › Health the single Health surface (master switch, then one card per capability with a plain-language name and its request/revoke action) and reduce Privacy & Data to a link 'Health access → ' plus the master switch.
- **Mockup needed:** Yes
- **Evidence:** [Settings--Health.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Health.png) · [100-settings-privacy-data-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/100-settings-privacy-data-scrolled-1.png) · [101-settings-privacy-data-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/101-settings-privacy-data-scrolled-2.png) — `App/Fernlet/SettingsSheet.swift:1046-1114`, `App/Fernlet/PrivacyDataSettingsView.swift:963-1004`, `App/Fernlet/PrivacyDataSettingsView.swift:1523-1536`

### Settings > App lock

**Current:** ![83-settings-applock-change-passcode.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/83-settings-applock-change-passcode.png) ![81-settings-applock.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/81-settings-applock.png) ![88-settings-applock-set-duress-code.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/88-settings-applock-set-duress-code.png)

#### SETT-30 — Medium — Tier 1 — Consistency & polish — PIN pads sit at the top of full sheets; gate pad is bottom-anchored

- **What's unclear or slow:** The lock gate centres its keypad in the lower half of the screen (thumb reach). Change passcode, the biometric verify sheet and the duress-code entry sheet stack SectionLabel → sentence → dots → keypad from the top, leaving the bottom 55% empty, so the digits are near the top edge. Change passcode also re-asks for the current PIN seconds after the gate accepted it, with no line explaining why (the re-key needs it).
- **Recommended change:** Reuse the gate's layout in these sheets (title + dots in the upper third, keypad anchored above the safe area) and change the verify-step sentence to 'Enter your current passcode again — Fernlet needs it to re-key your sealed notes.'
- **Mockup needed:** No (code-only)
- **Evidence:** [83-settings-applock-change-passcode.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/83-settings-applock-change-passcode.png) · [81-settings-applock.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/81-settings-applock.png) · [88-settings-applock-set-duress-code.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/88-settings-applock-set-duress-code.png) — `App/Fernlet/SettingsSheet.swift:2540-2557`, `App/Fernlet/SettingsSheet.swift:2571-2600`, `App/Fernlet/SettingsSheet.swift:2360-2420`, `App/Fernlet/DuressPINSetupView.swift:664-705`

#### SETT-31 — Medium — Tier 1 — Clarity — 'Be a recovery device' opens the chooser favouring the other role

- **What's unclear or slow:** The row 'Be a recovery device' presents DuressRecoveryEnrollmentSheet with `role == nil`, so the user sees 'Which phone is this?' with the moss primary 'This is the phone I'm protecting' and only a secondary 'This is the recovery device' — the opposite of what they just tapped. Duress › 'Set up a recovery device' opens the identical chooser.
- **Recommended change:** Give DuressRecoveryEnrollmentSheet an `initialRole` parameter: 'Be a recovery device' passes .recoveryDevice and skips the chooser; Duress › 'Set up a recovery device' passes .protectedPhone.
- **Mockup needed:** No (code-only)
- **Evidence:** [89-settings-applock-be-recovery-device.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/89-settings-applock-be-recovery-device.png) · [86-settings-applock-recovery-device-enroll.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/86-settings-applock-recovery-device-enroll.png) — `App/Fernlet/SettingsSheet.swift:2315-2320`, `App/Fernlet/DuressRecoveryCeremonyViews.swift:294-386`

#### SETT-32 — Medium — Tier 1 — Consistency & polish — Two identical primaries, faded reason text, left-side 'Done'

- **What's unclear or slow:** 'Set up a recovery device' and 'Set duress code' are both full-width filled moss buttons in adjacent cards, so the real primary is unclear. The unavailable 'Lock it away…' response is dimmed to 55% opacity INCLUDING its terracotta explanation line, which is meant to be the readable reason (contrast drops well below 3:1). The sheet's only close control is 'Done' in the top-left cancellation slot, while Change passcode, Verify and Recovery device sheets show 'Cancel' there. Also, App lock's 'Lock now' action row carries a navigation chevron.
- **Recommended change:** Make 'Set duress code' the only filled button and 'Set up a recovery device' a moss outline/text button; keep the disabled card at 55% but render its reason line at full opacity; use a trailing 'Done' (or leading 'Cancel') consistently across the lock sheets; drop the chevron from 'Lock now'.
- **Mockup needed:** No (code-only)
- **Evidence:** [85-settings-applock-duress-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/85-settings-applock-duress-scrolled-1.png) · [84-settings-applock-duress.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/84-settings-applock-duress.png) · [83-settings-applock-change-passcode.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/83-settings-applock-change-passcode.png) · [82-settings-applock-unlocked.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/82-settings-applock-unlocked.png) — `App/Fernlet/DuressPINSetupView.swift:323-328`, `App/Fernlet/DuressPINSetupView.swift:405-461`, `App/Fernlet/DuressPINSetupView.swift:518-525`, `App/Fernlet/DuressPINSetupView.swift:534-552`, `App/Fernlet/SettingsSheet.swift:2221-2225`, `App/Fernlet/SettingsSheet.swift:2496-2512`

#### SETT-19 — Low — Tier 1 — Consistency & polish — Several cards hug their text instead of spanning the column

- **What's unclear or slow:** App lock's BIOMETRICS card ('No biometric authentication available…') is narrower than Status/Manage above it; the Duress intro card is narrower than the Status card beneath; the CLOUD RECORDS card in the delete-iCloud sheet is half width; the DEBUG card is a third width. Each is a VStack with cream background and no maxWidth, so widths follow the longest line.
- **Recommended change:** Add `.frame(maxWidth: .infinity, alignment: .leading)` before the padding/background on each card, or route them through FernletCard which already spans.
- **Mockup needed:** No (code-only)
- **Evidence:** [82-settings-applock-unlocked.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/82-settings-applock-unlocked.png) · [84-settings-applock-duress.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/84-settings-applock-duress.png) · [99-settings-privacy-data-delete-icloud-dialog.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/99-settings-privacy-data-delete-icloud-dialog.png) · [78-settings-debug.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/78-settings-debug.png) — `App/Fernlet/SettingsSheet.swift:2231-2261`, `App/Fernlet/SettingsSheet.swift:1692-1703`, `App/Fernlet/DuressPINSetupView.swift:346-362`, `App/Fernlet/PrivacyDataSettingsView.swift:1205-1239`
- **Note:** low severity — not independently verified.

## Onboarding

Only three findings, but one is load-bearing: 'Use biometrics only' records a skip and leaves the private surfaces unlocked, which is the opposite of what the copy promises.

### Onboarding > Lock setup

**Current:** ![Onboarding--Lock_setup.png](design-refs/ux-review-2026-08-16/shots/light/Onboarding--Lock_setup.png) ![Onboarding--Lock_setup.png](design-refs/ux-review-2026-08-16/shots/ax/Onboarding--Lock_setup.png)

#### SETT-05 — High — Tier 1 — Clarity — 'Use biometrics only' silently records a skip, sets no lock

- **What's unclear or slow:** The card promises 'Continue with device biometrics as your preferred lock path', but its action is `biometricsOnlyAction: model.deferLockSetup` — identical to 'Skip for now'. No lock is configured; the Private tab later shows the 'Set up app lock' gate. A user who believes they chose Face ID has been misrouted, and the app's own rule is PIN-before-biometrics, so this option can never be honoured.
- **Recommended change:** Remove the 'Use biometrics only' card (two choices: Set a passcode / Skip for now), or relabel it 'Set a passcode, then use Face ID' and route it into FernletLockSetupView with the biometric toggle pre-enabled.
- **Mockup needed:** No (code-only)
- **Evidence:** [Onboarding--Lock_setup.png](design-refs/ux-review-2026-08-16/shots/light/Onboarding--Lock_setup.png) · [Onboarding--Lock_setup.png](design-refs/ux-review-2026-08-16/shots/ax/Onboarding--Lock_setup.png) — `App/Fernlet/OnboardingLockSetupView.swift:43-50`, `App/Fernlet/OnboardingCoordinator.swift:231-237`, `App/Fernlet/OnboardingCoordinator.swift:144-149`

### Onboarding > Personal details

**Current:** ![Onboarding--Personal_details.png](design-refs/ux-review-2026-08-16/shots/light/Onboarding--Personal_details.png) ![60-settings-goal-nutrition-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/60-settings-goal-nutrition-scrolled-2.png)

#### SETT-04 — Medium — Tier 1 — Clarity — Sex and activity pickers show values with no visible label

- **What's unclear or slow:** Under BODY PROFILE the last two rows are just 'Male ◇' and 'Moderate ◇' — the Picker labels ('Biological sex', 'Activity') are hidden by the menu style outside a Form, so nothing says what 'Moderate' means. The Settings ProfileEditor shows the same fields WITH labels but different words ('Gender', 'Estimated lifestyle activity'), so the two surfaces disagree.
- **Recommended change:** Reuse ProfileEditor's `labeledPicker` (small slate label above the value) in onboarding and pick one wording for both places, e.g. 'Sex' and 'Typical activity'.
- **Mockup needed:** No (code-only)
- **Evidence:** [Onboarding--Personal_details.png](design-refs/ux-review-2026-08-16/shots/light/Onboarding--Personal_details.png) · [60-settings-goal-nutrition-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/60-settings-goal-nutrition-scrolled-2.png) — `App/Fernlet/OnboardingCoordinator.swift:453-471`, `App/Fernlet/OnboardingView.swift:22-35`, `App/Fernlet/OnboardingView.swift:67-75`

### Onboarding flow

**Current:** ![Onboarding--Lock_setup.png](design-refs/ux-review-2026-08-16/shots/light/Onboarding--Lock_setup.png) ![Onboarding--Storage_choice.png](design-refs/ux-review-2026-08-16/shots/light/Onboarding--Storage_choice.png) ![Onboarding--Personal_details.png](design-refs/ux-review-2026-08-16/shots/light/Onboarding--Personal_details.png)

#### SETT-37 — Low — Tier 1 — Daily-use speed — No way back between steps; age stepper starts at 30

- **What's unclear or slow:** Step changes are strictly forward (`advance()` only); a mis-tap on 'Skip for now' or the wrong storage card cannot be undone, and there is no Back affordance on any step. On Personal details, the required Age is a ± stepper starting at 30 (13…100), so a 48-year-old taps 18 times or long-presses.
- **Recommended change:** Add a `back()` on the model and a small 'Back' text button beside the step caption (hidden on step 1); render Age as a numeric TextField or wheel with the stepper as ±1 nudges.
- **Mockup needed:** No (code-only)
- **Evidence:** [Onboarding--Lock_setup.png](design-refs/ux-review-2026-08-16/shots/light/Onboarding--Lock_setup.png) · [Onboarding--Storage_choice.png](design-refs/ux-review-2026-08-16/shots/light/Onboarding--Storage_choice.png) · [Onboarding--Personal_details.png](design-refs/ux-review-2026-08-16/shots/light/Onboarding--Personal_details.png) — `App/Fernlet/OnboardingCoordinator.swift:105-106`, `App/Fernlet/OnboardingCoordinator.swift:134-141`, `App/Fernlet/OnboardingCoordinator.swift:455`
- **Note:** low severity — not independently verified.

## Cross-cutting

Eight of the ten highest-ranked items in the whole review are systemic: one dialog pattern, one destructive-confirmation path, one draft-discard guard, one tint/typography inheritance rule and one icon-button labelling pass would fix defects on dozens of screens at once. Fix these first — several per-screen entries disappear when they land.

### Shared: sheets & dialogs

**Current:** ![44-log-workout-discard-alert.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/44-log-workout-discard-alert.png) ![48-workout-remove-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/48-workout-remove-confirm.png) ![29-runner-close-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/29-runner-close-confirm.png)

#### XCUT-02 — High — Tier 1 — Consistency & polish · Systemic — iOS 26 confirmationDialog hides Cancel - only the destructive button shows

- **What's unclear or slow:** Every `.confirmationDialog` renders on iOS 26 as a popover that suppresses the `.cancel`-role button, so the user sees a single red action and no visible way out: "Discard your changes?" shows only Discard (code declares "Keep editing"), "Remove this workout?" only Remove ("Keep it" declared), "End this session?" only "End without logging" ("Keep going" declared), and "Reset app lock?" - which makes private notes permanently unreadable - only "Reset app lock" ("Cancel" declared). The popover also anchors to the view root, so it appears top-left far from the tapped row and its arrow can point at the wrong workout. This violates the visible-Cancel rule on ~15 dialogs.
- **Recommended change:** Convert destructive/discard confirmations to `.alert` (which always renders the Cancel-role button on iOS 26) - start with `discardConfirmation` in FernletUI so all five Move sheets and future callers inherit it - or add an explicit non-cancel-role "Keep editing"/"Cancel" button to each `.confirmationDialog`. Attach any remaining dialogs to the triggering row so the popover anchors correctly.
- **Mockup needed:** No (code-only)
- **Evidence:** [44-log-workout-discard-alert.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/44-log-workout-discard-alert.png) · [48-workout-remove-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/48-workout-remove-confirm.png) · [29-runner-close-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/29-runner-close-confirm.png) · [91-settings-applock-reset-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/91-settings-applock-reset-confirm.png) · [25-quicklog-movement-discard-alert.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/25-quicklog-movement-discard-alert.png) — `FernletKit/Sources/FernletUI/FernletUIComponents.swift:284-291`, `App/Fernlet/SettingsSheet.swift:2151-2160`, `App/Fernlet/GuidedWorkout.swift:88-96`, `App/Fernlet/MoveView.swift:1654-1659`, `App/Fernlet/FriendListView.swift:63-71`, `App/Fernlet/WorkoutSetupView.swift:99`
- **Also reported as:** HOME-03, MOVE-02, SETT-07

#### XCUT-04 — High — Tier 1 — Consistency & polish · Systemic — Typed drafts discarded silently on swipe-down; Move sheets guard, others don't

- **What's unclear or slow:** Only the five Move sheets pair `.interactiveDismissDisabled(isDirty)` with the discard confirmation. The Meal, Journal, Sleep, Goals, Log period, Log intimacy, New/Edit recipe and Creation Studio sheets have no dirty guard: a swipe-down (or the walker's back-arrow) throws away a typed journal entry, a period log with symptoms, an edited recipe step or a painted canvas with no warning. The walker reproduced this on Edit recipe (also popping the whole Recipe book stack), New recipe and Creation Studio.
- **Recommended change:** Apply the Move pattern everywhere a sheet holds a draft: compute `isDirty`, add `.interactiveDismissDisabled(isDirty)`, a `SheetCancelBar` whose action dismisses when clean and raises the (alert-based) discard confirmation when dirty. Extract this into one `draftSheet(isDirty:onDiscard:)` modifier in FernletUI so no sheet can forget it.
- **Mockup needed:** No (code-only)
- **Evidence:** [Sheet--Journal.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Journal.png) · [Sheet--Recipe.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Recipe.png) · [Sheet--Log_period.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Log_period.png) · [74-recipe-edit-add-step.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/74-recipe-edit-add-step.png) · [14-creation-studio-painted.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/14-creation-studio-painted.png) — `App/Fernlet/JournalView.swift:191-245`, `App/Fernlet/FoodView.swift:1016-1240`, `App/Fernlet/SharedSheets.swift:70-109`, `App/Fernlet/LogPeriodSheet.swift:63-99`, `App/Fernlet/LogIntimacySheet.swift:32-62`, `App/Fernlet/MoveView.swift:749-750`, `App/Fernlet/GuidedWorkoutEditorSheet.swift:61-62`
- **Also reported as:** HOME-15, FOOD-10, PRIV-04

#### XCUT-03 — High — Tier 1 — Consistency & polish · Systemic — Instant deletes with no confirmation on saved user data

- **What's unclear or slow:** Several one-tap controls destroy saved data with no confirmation and no undo: the X on a Food meal row deletes the meal immediately; "Delete recipe" (both the saved-recipe notes sheet and the recipe editor) deletes and dismisses in one tap; the Cycle day detail's Delete removes the HealthKit sample + sealed narrative instantly; the X on a Core memory row and the minus on a Personal-care task remove them outright; "Release this worry" releases with no confirmation. Meanwhile progress-photo delete, workout Remove and Delete everything all confirm - the same job is done two different ways.
- **Recommended change:** Route recipe delete, Cycle day delete, Core-memory X and Personal-care minus through the existing DestructiveConfirmation alert as the progress-photo delete does; for the meal-row X prefer a 5-second in-place 'Meal removed - Undo' row and defer mealPhotoStore.delete until the undo window closes so the photo is never lost first; leave the worry-box ritual to FLOW-25 (undo window, no dialog).
- **Mockup needed:** No (code-only)
- **Evidence:** [49-food-row-x-deleted-no-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/49-food-row-x-deleted-no-confirm.png) · [Sheet--Saved_recipe_notes.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Saved_recipe_notes.png) · [29-cycle-day-detail.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/29-cycle-day-detail.png) · [71-settings-core-memory.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/71-settings-core-memory.png) · [38-worrybox-after-release.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/38-worrybox-after-release.png) — `App/Fernlet/FoodView.swift:3014-3020`, `App/Fernlet/FoodView.swift:142`, `App/Fernlet/FoodView.swift:943-951`, `App/Fernlet/FoodView.swift:1221-1230`, `App/Fernlet/CycleTrackerView.swift:166-182`, `App/Fernlet/CycleDayDetailView.swift:58`, `App/Fernlet/SettingsSheet.swift:1946-1952`, `App/Fernlet/SettingsSheet.swift:1677-1683`, `App/Fernlet/ProgressPhotoTimeline.swift:556-575`
- **Also reported as:** FOOD-03, SETT-20, SETT-21

#### XCUT-14 — Medium — Tier 1 — Consistency & polish · Systemic — Sheet close affordance differs across 19 sheets; 8 have none

- **What's unclear or slow:** Four Move sheets have a top-left SheetCancelBar; First aid and Body signals use a top-right moss text "Done"; Water, Personal care, Saved recipe, Settings use a bottom-right moss "Done" pill (Trends centres the same pill; Worry box uses slate text Done; Meal photo uses a system toolbar Done); Meal, Journal, Sleep, Goals, Log period, Log intimacy, Recipe and Suggest workout have no close control at all and must be swiped (the walker noted swipes only work from the grabber on Meal/Journal). In Water the dismiss ("Done") is the prominent moss pill while the real action ("Add a bottle") is a bark chip.
- **Recommended change:** Adopt one sheet chrome: SheetCancelBar (top-left "Cancel"/"Close") on every routed sheet, SheetSaveBar bottom-right for the commit action, and no moss "Done" pill on read-only sheets (use the top-left Close instead). Make Water's "Add a bottle" the moss primary and demote Done to the top-left Close.
- **Mockup needed:** Yes
- **Evidence:** [Sheet--Meal.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Meal.png) · [Sheet--Trends.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Trends.png) · [Sheet--First_aid.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--First_aid.png) · [20-quicklog-water-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/20-quicklog-water-sheet.png) · [Sheet--Workout.png](design-refs/ux-review-2026-08-16/shots/ax/Sheet--Workout.png) · [Settings--Hub.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Hub.png) — `FernletKit/Sources/FernletUI/FernletUIComponents.swift:300-320`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:597-623`, `App/Fernlet/HomeView.swift:1906-1916`, `App/Fernlet/StressExplainerSheet.swift:38-40`, `App/Fernlet/FirstAidView.swift:138-140`, `App/Fernlet/SharedSheets.swift:46-59`, `App/Fernlet/SharedSheets.swift:296`, `App/Fernlet/MoveView.swift:707`
- **Also reported as:** HOME-14, MOVE-20, FRND-20

#### XCUT-11 — Medium — Tier 1 — Consistency & polish · Systemic — System-blue controls leak in root-presented sheets

- **What's unclear or slow:** The moss tint is applied to `mainInterface`, but the routed sheets are attached to `launchRoot` outside that scope and `fernletSheetStyle()` (which tints) is never called, so any un-tinted system control inside a sheet renders Apple blue: the Effort slider in Log workout, the "Servings" unit menu in the recipe editor, the two Observation menus in Log/Edit period (also label-less - they read as two bare "None" menus because `Picker` outside a Form hides its label), and the link-styled URL in the Import product placeholder.
- **Recommended change:** Add `.tint(Color.moss)` inside `fernletSheetChrome` (ContentView:1271) so every routed sheet inherits it, and label the two Observation pickers with a visible caption row ("Cervical mucus" / "Ovulation test") using `SheetField` + `.labelsHidden()` menu.
- **Mockup needed:** No (code-only)
- **Evidence:** [43-log-workout-walking-scrolled-2.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/43-log-workout-walking-scrolled-2.png) · [Sheet--Recipe.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Recipe.png) · [31-cycle-day-detail-edit-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/31-cycle-day-detail-edit-scrolled.png) · [61-meal-import.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/61-meal-import.png) — `App/Fernlet/ContentView.swift:513`, `App/Fernlet/ContentView.swift:165-186`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:235-240`, `App/Fernlet/ActivityPickerSection.swift:151`, `App/Fernlet/FoodView.swift:1695-1701`, `App/Fernlet/LogPeriodSheet.swift:175-195`
- **Also reported as:** FOOD-13, SETT-03

#### XCUT-22 — Medium — Tier 1 — Daily-use speed · Systemic — Keyboard Done toolbar and return-key handling only on Move sheets

- **What's unclear or slow:** `keyboardDoneToolbar()` (the checkmark Done above the keyboard) is attached only to the five Move sheets. Numeric pads in the recipe quantity, Log period temperature, Nutrition targets, Barcode serving and Journal day-edit fields have no Done key, so the pad floats over the Save bar with no dismissal control; the Sleep "Hours" field opens the full alphabetic keyboard for a decimal; `submitLabel`/`onSubmit` are used in only two/three places so Return never saves or advances anywhere else.
- **Recommended change:** Attach `keyboardDoneToolbar()` inside `fernletSheetChrome` so every routed sheet gets it; give Sleep hours `.keyboardType(.decimalPad)`; set `.submitLabel(.done)` on single-line name fields and `.onSubmit` to trigger the sheet's save when the form is valid.
- **Mockup needed:** No (code-only)
- **Evidence:** [Sheet--Sleep.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Sleep.png) · [Sheet--Recipe.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Recipe.png) · [31-cycle-day-detail-edit-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/31-cycle-day-detail-edit-scrolled.png) · [60-paste-plan-typed.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/60-paste-plan-typed.png) — `FernletKit/Sources/FernletUI/FernletUIComponents.swift:264-279`, `App/Fernlet/MoveView.swift:748`, `App/Fernlet/SharedSheets.swift:88-95`, `App/Fernlet/FoodView.swift:1689-1694`, `App/Fernlet/LogPeriodSheet.swift:200-202`, `App/Fernlet/NutritionTargetsEditor.swift:1`
- **Also reported as:** HOME-16, PRIV-10, FLOW-27

#### XCUT-15 — Low — Tier 1 — Consistency & polish · Systemic — Six different sheet title treatments

- **What's unclear or slow:** Most entry sheets open with a 28pt displayMedium title ("Log meal", "Water", "Log period"); Trends, Recipe book and Create recipe use the 36pt ScreenHeader with italic subtitle; First aid uses a 12pt uppercase SectionLabel eyebrow plus a 22pt serif lede; Body signals uses the 24pt header with an inline Done; Settings uses a navigation large title; Meal photo an inline system title. Same modal family, six voices.
- **Recommended change:** Add a `SheetHeader(title:subtitle:)` primitive to FernletUI (displayMedium title, optional bodySmall italic subtitle, slot for the Close control) and use it in every sheet, reserving ScreenHeader for tab roots and pushed pages.
- **Mockup needed:** Yes
- **Evidence:** [Sheet--Meal.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Meal.png) · [Sheet--Trends.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Trends.png) · [Sheet--First_aid.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--First_aid.png) · [108-stress-explainer-sheet.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/108-stress-explainer-sheet.png) · [Settings--Hub.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Hub.png) · [37-home-recent-bite-tap.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/37-home-recent-bite-tap.png) — `App/Fernlet/SharedSheets.swift:20-22`, `App/Fernlet/HomeView.swift:1886-1890`, `App/Fernlet/FirstAidView.swift:133-146`, `App/Fernlet/StressExplainerSheet.swift:32-40`, `App/Fernlet/SettingsSheet.swift:88-90`, `App/Fernlet/MealPhotoPolaroid.swift:205-211`
- **Note:** low severity — not independently verified.

### App root: appearance

**Current:** ![Home_tab.png](design-refs/ux-review-2026-08-16/shots/dark/Home_tab.png) ![Food_tab.png](design-refs/ux-review-2026-08-16/shots/dark/Food_tab.png) ![Onboarding--Storage_choice.png](design-refs/ux-review-2026-08-16/shots/dark/Onboarding--Storage_choice.png)

#### XCUT-06 — High — Tier 1 — Consistency & polish · Systemic — Main app ignores system Dark Mode; onboarding follows it

- **What's unclear or slow:** ContentView forces `.preferredColorScheme(isDarkModeEnabled ? .dark : .light)` from an in-app toggle, so with the phone in Dark Mode every tab and sheet still renders light (the entire dark gallery except onboarding is identical to light). Onboarding lives outside ContentView and does honor the system, so a dark-mode user gets a dark onboarding, then a light app the moment it finishes, and must discover Settings > Appearance > Dark mode. There is no "Match system" choice, and the UIWindow background is hard-coded to light parchment (a light flash behind sheets/transitions when the in-app dark toggle is on).
- **Recommended change:** Make Appearance a three-way choice (System / Light / Dark, default System) stored as an enum; pass `nil` to `preferredColorScheme` for System so the whole app - onboarding included - follows the phone; drop the fixed UIWindow background (use the adaptive parchment UIColor).
- **Mockup needed:** No (code-only)
- **Evidence:** [Home_tab.png](design-refs/ux-review-2026-08-16/shots/dark/Home_tab.png) · [Food_tab.png](design-refs/ux-review-2026-08-16/shots/dark/Food_tab.png) · [Onboarding--Storage_choice.png](design-refs/ux-review-2026-08-16/shots/dark/Onboarding--Storage_choice.png) · [Settings--Privacy_&_Data.png](design-refs/ux-review-2026-08-16/shots/dark/Settings--Privacy_&_Data.png) · [Settings--Appearance.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Appearance.png) — `App/Fernlet/ContentView.swift:58`, `App/Fernlet/ContentView.swift:167`, `App/Fernlet/SettingsSheet.swift:570-574`, `App/Fernlet/FernletApp.swift:92`, `App/Fernlet/FernletApp.swift:278-297`
- **Also reported as:** HOME-33, SETT-01

### Tab bar

**Current:** ![Home_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Home_tab.png) ![Food_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Food_tab.png) ![Move_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Move_tab.png)

#### XCUT-01 — High — Tier 1 — Accessibility · Systemic — Tab bar labels wrap mid-word at AX; VoiceOver hears symbol names

- **What's unclear or slow:** At accessibility Dynamic Type the five tab labels break mid-word ("Hom/e", "Mov/e", "Frien/ds", "Priva/te") and the bar swallows a fifth of the screen while the icons stay a fixed 20pt. In compact mode (after scrolling) the label is accessibilityHidden and the button has no accessibilityLabel, so VoiceOver announces the SF Symbol ("leaf", "fork knife", "figure walk", "person 2", "lock") instead of Home/Food/Move/Friends/Private, and the selected tab is never announced (no .isSelected / .isTabBar traits).
- **Recommended change:** Give every tab Button `.accessibilityLabel(tab.title)` and `.accessibilityAddTraits(isSelected ? [.isSelected] : [])`, mark the HStack `.accessibilityAddTraits(.isTabBar)`; scale the icon with `.font(.title3)`/`@ScaledMetric`; and under `dynamicTypeSize.isAccessibilitySize` render icon-only tabs (labels hidden visually but kept for VoiceOver) or allow `.lineLimit(1).minimumScaleFactor(0.7)` so words never split.
- **Mockup needed:** No (code-only)
- **Evidence:** [Home_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Home_tab.png) · [Food_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Food_tab.png) · [Move_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Move_tab.png) · [Private--Journal.png](design-refs/ux-review-2026-08-16/shots/ax/Private--Journal.png) · [48-workout-remove-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/48-workout-remove-confirm.png) — `App/Fernlet/ContentView.swift:608-651`, `App/Fernlet/ContentView.swift:619-626`
- **Also reported as:** HOME-05

### Shared: buttons & tokens

**Current:** ![Onboarding--Storage_choice.png](design-refs/ux-review-2026-08-16/shots/dark/Onboarding--Storage_choice.png) ![Settings--Privacy_&_Data.png](design-refs/ux-review-2026-08-16/shots/dark/Settings--Privacy_&_Data.png) ![Sheet--Meal.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Meal.png)

#### XCUT-07 — High — Tier 1 — Accessibility · Systemic — White ink on moss/terracotta fails contrast, badly in dark mode

- **What's unclear or slow:** SheetSaveBar and ~20 hand-rolled pills draw white 14pt DM Sans Medium on `Color.moss`. In light mode that is 4.29:1 (below 4.5 for non-large text); in dark mode moss lightens to (0.498,0.690,0.412) and white drops to 2.53:1 - the dark Continue/Save/Done pills are visibly washed out. White on dark terracotta ("Delete iCloud data") is 3.2:1. The disabled Save state (moss at 40% + white) is 1.8:1, so users cannot read what the button will do once enabled.
- **Recommended change:** Add an `onMoss` ink token = `Color(light: .white, dark: .midnight)` (midnight on dark moss is 6.5:1) and a slightly deeper light-mode moss fill for buttons (e.g. #4F7444, giving white ≥4.6:1); use them in SheetSaveBar and replace the `.foregroundStyle(.white)` sites; for the disabled state keep full-opacity ink and reduce only the fill (e.g. moss 55%) so the label stays legible.
- **Mockup needed:** No (code-only)
- **Evidence:** [Onboarding--Storage_choice.png](design-refs/ux-review-2026-08-16/shots/dark/Onboarding--Storage_choice.png) · [Settings--Privacy_&_Data.png](design-refs/ux-review-2026-08-16/shots/dark/Settings--Privacy_&_Data.png) · [Sheet--Meal.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Meal.png) · [Sheet--Recipe.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Recipe.png) — `FernletKit/Sources/FernletUI/FernletUIComponents.swift:608-622`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:30-33`, `App/Fernlet/SettingsSheet.swift:1903-1915`, `App/Fernlet/HomeView.swift:1906-1916`, `App/Fernlet/PrivacyDataSettingsView.swift:303`

#### XCUT-21 — Low — Tier 1 — Consistency & polish · Systemic — Five different destructive button styles

- **What's unclear or slow:** "Delete recipe" is a bare `role: .destructive` button in system red; "Delete iCloud data" and "Lock photos to this device" are full-width terracotta pills with white text; "Delete this photo" is a dustyRose tinted card; "Reset app lock" is terracotta text with a trash icon in a "Danger zone" card; the workout card's "Remove" is plain bark text next to a moss "Edit". Users get no consistent cue for what is destructive.
- **Recommended change:** Add a `DestructiveButtonStyle` to FernletUI (terracotta text + trash icon on a terracotta-10% card, full width, `.fernlet(.label)`) and apply it to all delete/remove/reset controls; keep terracotta rather than system red so it also survives dark mode.
- **Mockup needed:** Yes
- **Evidence:** [Sheet--Saved_recipe_notes.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Saved_recipe_notes.png) · [Settings--Privacy_&_Data.png](design-refs/ux-review-2026-08-16/shots/dark/Settings--Privacy_&_Data.png) · [52-progress-photo-detail-scrolled-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/52-progress-photo-detail-scrolled-1.png) · [91-settings-applock-reset-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/91-settings-applock-reset-confirm.png) · [48-workout-remove-confirm.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/48-workout-remove-confirm.png) — `App/Fernlet/FoodView.swift:943-951`, `App/Fernlet/FoodView.swift:1221-1230`, `App/Fernlet/ProgressPhotoTimeline.swift:568-575`, `App/Fernlet/PrivacyDataSettingsView.swift:303`, `App/Fernlet/MoveView.swift:1650-1653`
- **Also reported as:** MOVE-29
- **Note:** low severity — not independently verified.

### Shared: icon buttons

**Current:** ![Friends_tab.png](design-refs/ux-review-2026-08-16/shots/light/Friends_tab.png) ![Private--Journal.png](design-refs/ux-review-2026-08-16/shots/light/Private--Journal.png) ![Private--Cycle_(both_halves).png](design-refs/ux-review-2026-08-16/shots/light/Private--Cycle_%28both_halves%29.png)

#### XCUT-08 — High — Tier 1 — Accessibility · Systemic — Icon-only buttons lack accessibility labels and 44pt targets

- **What's unclear or slow:** VoiceOver reads SF Symbol names or nothing useful: the two Friends header buttons (figure.2.arms.open / person.2) have no label - the walker had to tap to learn they were Activities and Friends & Blocks; `HeaderActionButton(systemImage: "plus")` falls back to the literal label "plus" on Journal and Cycle; calendar month chevrons (32x32), grocery week chevrons, ingredient/exercise remove X (glyph-sized, no frame), Core-memory pencil/X (34pt), home-widget up/down chevrons (28x24) and X, and the personal-care minus (32pt) all lack labels and sit under 44pt.
- **Recommended change:** Make `HeaderActionButton` require an `accessibilityLabel:` (or a `title` for VoiceOver only) instead of falling back to the symbol name; add `.accessibilityLabel("Activities")` / "Friends and blocks" / "Previous month" / "Next month" / "Remove <name>" / "Edit memory" / "Move up"/"Move down" / "Hide widget"; give every glyph-only button `.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())`.
- **Mockup needed:** No (code-only)
- **Evidence:** [Friends_tab.png](design-refs/ux-review-2026-08-16/shots/light/Friends_tab.png) · [Private--Journal.png](design-refs/ux-review-2026-08-16/shots/light/Private--Journal.png) · [Private--Cycle_(both_halves).png](design-refs/ux-review-2026-08-16/shots/light/Private--Cycle_%28both_halves%29.png) · [Settings--Layout_&_shortcuts.png](design-refs/ux-review-2026-08-16/shots/ax/Settings--Layout_&_shortcuts.png) · [Sheet--Recipe.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Recipe.png) · [65-friends-toolbar-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/65-friends-toolbar-1.png) — `App/Fernlet/ConnectView.swift:193-206`, `App/Fernlet/ConnectView.swift:234-244`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:173`, `App/Fernlet/JournalView.swift:80`, `App/Fernlet/CycleTrackerView.swift:233-235`, `App/Fernlet/MonthCalendarCard.swift:124-150`, `App/Fernlet/GroceryPlannerView.swift:272-283`, `App/Fernlet/FoodView.swift:1547-1552`, `App/Fernlet/FoodView.swift:1619-1623`, `App/Fernlet/MoveView.swift:2343-2348`, `App/Fernlet/SettingsSheet.swift:1939-1952`, `App/Fernlet/SettingsSheet.swift:712-743`, `App/Fernlet/SettingsSheet.swift:1677-1683`
- **Also reported as:** FOOD-26, MOVE-19, FRND-10, FRND-16, PRIV-34

### Shared: chips & pickers

**Current:** ![Sheet--Journal.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Journal.png) ![Sheet--Log_period.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Log_period.png) ![Sheet--Sleep.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Sleep.png)

#### XCUT-09 — High — Tier 1 — Accessibility · Systemic — Selected state never exposed to VoiceOver

- **What's unclear or slow:** `ChipButtonStyle(selected:)` is used at ~41 sites (meal type, feeling, flow level, readiness, kind, level...) but adds no `.isSelected` trait, so VoiceOver reads "Breakfast, button" for both the chosen and unchosen chip; the same is true of HubSectionPicker (Journal/Cycle/Worry Box, All/Friends/Blocked), the Sleep quality rows and Personal-care rows (state shown only by a checkmark image), and the custom tab bar. Only three views in the whole app add `.isSelected` (QuickMoodRow, GoalPresetCards, Creation Studio mirror).
- **Recommended change:** In `ChipButtonStyle.makeBody` add `.accessibilityAddTraits(selected ? .isSelected : [])` to `configuration.label`; add the same trait to HubSectionPicker's buttons and to the Sleep/Care option rows (plus `.accessibilityValue("Selected")` fallback); one FernletUI change fixes all 41 chip sites.
- **Mockup needed:** No (code-only)
- **Evidence:** [Sheet--Journal.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Journal.png) · [Sheet--Log_period.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Log_period.png) · [Sheet--Sleep.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Sleep.png) · [Private--Journal.png](design-refs/ux-review-2026-08-16/shots/light/Private--Journal.png) · [Sheet--Workout_suggestion.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Workout_suggestion.png) — `FernletKit/Sources/FernletUI/FernletUIComponents.swift:406-429`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:480-520`, `App/Fernlet/SharedSheets.swift:112-149`, `App/Fernlet/SharedSheets.swift:262-290`, `App/Fernlet/QuickMoodRow.swift:69`
- **Also reported as:** MOVE-33, PRIV-31

#### XCUT-18 — Medium — Tier 1 — Accessibility · Systemic — HubSectionPicker wraps mid-word and never scrolls

- **What's unclear or slow:** At AX the Private hub picker renders "Journ/al" and "Worry/Box" on two lines inside their pills; the picker is a fixed HStack with no horizontal scroll, no lineLimit and no `.isSelected` trait, so at larger sizes it both looks broken and is not announced as a selection.
- **Recommended change:** Wrap the HStack in a horizontal ScrollView, add `.lineLimit(1).fixedSize(horizontal: true, vertical: false)` to each label, and add `.accessibilityAddTraits(isSelected ? .isSelected : [])`.
- **Mockup needed:** No (code-only)
- **Evidence:** [Private--Journal.png](design-refs/ux-review-2026-08-16/shots/ax/Private--Journal.png) · [Private--Cycle_(both_halves).png](design-refs/ux-review-2026-08-16/shots/ax/Private--Cycle_%28both_halves%29.png) · [71-friends-roster-top.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/71-friends-roster-top.png) — `FernletKit/Sources/FernletUI/FernletUIComponents.swift:480-520`
- **Also reported as:** FRND-30, PRIV-32

### Shared: typography

**Current:** ![Settings--Hub.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Hub.png) ![Sheet--Workout_suggestion.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Workout_suggestion.png) ![Sheet--Recipe.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Recipe.png)

#### XCUT-13 — Medium — Tier 1 — Consistency & polish · Systemic — System SF font on Settings rows, toggle labels and every TextField

- **What's unclear or slow:** The Settings hub is a stock `Form`: row titles ("Appearance", "Goal & nutrition"), section headers ("General", "Wellness") and chevrons render in system SF, unlike every other list in the app (DM Sans labels + SectionLabel eyebrows). `sheetTextInput()` sets padding and background but no font, so the typed value and placeholder of 63 TextFields ("Wellness", "45", "e.g. Upper strength", "black bean bowls") are SF while the adjacent SheetTextEditor placeholders are Instrument Serif; Toggle labels in Log period are SF too. Large timers use SF Rounded instead of the DM Sans stat role.
- **Recommended change:** Add `.font(.fernlet(.body))` (or `.label` for numeric fields) inside `sheetTextInput()`; style Settings rows with `.font(.fernlet(.label))` and section headers via `SectionLabel` (`.textCase(nil)`); set `.font(.fernlet(.label))` on `periodToggle`; render timers with `.custom(FernletFontName.dmSansMedium, size: 60, relativeTo: .largeTitle).monospacedDigit()`.
- **Mockup needed:** No (code-only)
- **Evidence:** [Settings--Hub.png](design-refs/ux-review-2026-08-16/shots/light/Settings--Hub.png) · [Sheet--Workout_suggestion.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Workout_suggestion.png) · [Sheet--Recipe.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Recipe.png) · [Sheet--Log_period.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Log_period.png) · [28-runner-rest-timer.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/28-runner-rest-timer.png) — `App/Fernlet/SettingsSheet.swift:206-252`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:248-258`, `App/Fernlet/LogPeriodSheet.swift:245-249`, `App/Fernlet/CookingMode.swift:443`, `App/Fernlet/GuidedWorkout.swift:261`
- **Also reported as:** HOME-17, FLOW-31

### Shared: colour tokens

**Current:** ![Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) ![Home_tab.png](design-refs/ux-review-2026-08-16/shots/light/Home_tab.png) ![Sheet--Water.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Water.png)

#### XCUT-10 — Medium — Tier 1 — Accessibility · Systemic — Slate/goldenrod/fern small text under 4.5:1 on parchment

- **What's unclear or slow:** Measured against the light palette: slate on parchment is 3.05:1 and on cream 3.28:1, yet slate is used for every 12pt SectionLabel ("QUICK LOG", "MACROS TODAY", "BREAKFAST"), all labelSmall/bodySmall subtitles and the SheetCancelBar "Cancel". Goldenrod "Logged" on Food rows is 2.4:1, the fern "Looks off?" link - the only correction affordance - is 2.75:1, polaroid captions (slate 58%) are 1.9:1 and the empty water bottles (slate 25%) 1.3:1. Dark-mode slate is fine (5.9-6.9:1).
- **Recommended change:** Darken light-mode slate to roughly (0.36,0.42,0.47) (~4.6:1 on parchment) in FernletThemePalette.defaultPalette while keeping dark-mode slate; use bark or moss for goldenrod/fern text that carries meaning ("Looks off?", confidence word) and reserve goldenrod for fills/icons; raise polaroid caption and disabled-bottle opacities.
- **Mockup needed:** No (code-only)
- **Evidence:** [Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) · [Home_tab.png](design-refs/ux-review-2026-08-16/shots/light/Home_tab.png) · [Sheet--Water.png](design-refs/ux-review-2026-08-16/shots/light/Sheet--Water.png) · [Move_tab.png](design-refs/ux-review-2026-08-16/shots/light/Move_tab.png) — `FernletKit/Sources/FernletUI/FernletUIComponents.swift:27-29`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:38-41`, `FernletKit/Sources/FernletUI/FernletPrimitives.swift:40-53`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:220-223`, `App/Fernlet/FoodView.swift:3038-3046`, `FernletKit/Sources/FernletUI/FernletTheme.swift:96-98`
- **Also reported as:** FOOD-28

### Shared: AX layout

**Current:** ![Sheet--Recipe_book.png](design-refs/ux-review-2026-08-16/shots/ax/Sheet--Recipe_book.png) ![Move_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Move_tab.png) ![Sheet--Recipe.png](design-refs/ux-review-2026-08-16/shots/ax/Sheet--Recipe.png)

#### XCUT-17 — Medium — Tier 1 — Accessibility · Systemic — Side-by-side button pairs wrap mid-word at AX

- **What's unclear or slow:** Fixed HStack pairs do not reflow: at AX the Recipe book's "Meal planner" / "Shopping list" become "planne/r" and "Shopp/ing list" at different heights, Move's "Share" pill becomes "Shar/e", and "Save recipe" / "Log & save" and "Add ingredient" / "Scan barcode" squeeze to the edge. Words breaking inside a button reads as broken UI.
- **Recommended change:** Wrap each pair in `ViewThatFits { HStack{...}; VStack{...} }` or switch to a VStack when `dynamicTypeSize.isAccessibilitySize`; give HeaderActionButton `.lineLimit(1).fixedSize()` so the pill grows rather than wrapping.
- **Mockup needed:** No (code-only)
- **Evidence:** [Sheet--Recipe_book.png](design-refs/ux-review-2026-08-16/shots/ax/Sheet--Recipe_book.png) · [Move_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Move_tab.png) · [Sheet--Recipe.png](design-refs/ux-review-2026-08-16/shots/ax/Sheet--Recipe.png) — `App/Fernlet/FoodView.swift:4587-4620`, `App/Fernlet/MoveView.swift:109-118`, `App/Fernlet/FoodView.swift:1231-1240`, `FernletKit/Sources/FernletUI/FernletUIComponents.swift:151-166`
- **Also reported as:** FOOD-27

### Shared: ScreenHeader

**Current:** ![Onboarding--Lock_setup.png](design-refs/ux-review-2026-08-16/shots/ax/Onboarding--Lock_setup.png) ![Move_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Move_tab.png) ![05-goal-accepted.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/05-goal-accepted.png)

#### XCUT-19 — Medium — Tier 1 — Accessibility · Systemic — lineLimit(1) truncates titles, goal value and legends

- **What's unclear or slow:** ScreenHeader forces the title to one line (min scale 0.72) and the subtitle to two, so at AX titles read "Protect private spa…" and subtitles "not enough to…"; the Move GOAL/SPACE strip truncates its value even at default size once goals are accepted ("Complete 3 gene…", "Wellne…", "Full gy…") with no way to read the rest; the Move and Journal legends use lineLimit(1) + minimumScaleFactor(0.7) and shrink to "Work…"/"Full B…".
- **Recommended change:** Let ScreenHeader titles wrap to two lines (`lineLimit(2)`, no minimum scale) and subtitles to three; in the context strip allow two lines for the value and show the full goal in the segment's accessibility label; render legends with FlowLayout so they wrap instead of shrinking.
- **Mockup needed:** No (code-only)
- **Evidence:** [Onboarding--Lock_setup.png](design-refs/ux-review-2026-08-16/shots/ax/Onboarding--Lock_setup.png) · [Move_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Move_tab.png) · [05-goal-accepted.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/05-goal-accepted.png) · [Move_tab.png](design-refs/ux-review-2026-08-16/shots/light/Move_tab.png) — `FernletKit/Sources/FernletUI/FernletUIComponents.swift:112-131`, `App/Fernlet/MoveView.swift:1958-1969`, `App/Fernlet/JournalView.swift:659-670`
- **Also reported as:** MOVE-30, SETT-06

### Macros today card

**Current:** ![Food_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Food_tab.png) ![Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png)

#### XCUT-20 — Medium — Tier 1 — Accessibility · Systemic — Macro ring is fixed 68pt; numbers overflow at AX

- **What's unclear or slow:** MacroRing hard-codes a 68x68 frame around a Dynamic-Type stat label, so at AX "114g" is wider than the ring, the three columns misalign vertically (Carbs sits higher than Protein/Fat) and "of 372g" wraps. The three Texts are also separate VoiceOver elements with no combined "Protein 76 of 93 grams" label.
- **Recommended change:** Size the ring with `@ScaledMetric(relativeTo: .subheadline) var ring = 68`, cap the ring at ~96pt, and add `.accessibilityElement(children: .combine)` + `.accessibilityLabel("\(label) \(current) of \(goal) grams")` on each MacroRing; under AX sizes stack the three rings vertically via ViewThatFits.
- **Mockup needed:** No (code-only)
- **Evidence:** [Food_tab.png](design-refs/ux-review-2026-08-16/shots/ax/Food_tab.png) · [Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) — `App/Fernlet/HomeView.swift:2139-2158`, `App/Fernlet/HomeView.swift:2094-2114`

### Shared: empty states

**Current:** ![Friends_tab.png](design-refs/ux-review-2026-08-16/shots/light/Friends_tab.png) ![65-friends-toolbar-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/65-friends-toolbar-1.png) ![34-milestones-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/34-milestones-scrolled.png)

#### XCUT-29 — Low — Tier 1 — Consistency & polish · Systemic — Bespoke empty copy bypasses the EmptyState primitive

- **What's unclear or slow:** 31 sections use `EmptyState` (centred italic slate line), but the Friends album ("Photos from your hangouts will appear here" with a 48pt icon), Activities ("No activities yet"), the Friend shop and Milestones each draw their own empty state with different fonts and spacing.
- **Recommended change:** Extend `EmptyState` with an optional systemImage and use it at these four sites so every empty section shares one voice.
- **Mockup needed:** No (code-only)
- **Evidence:** [Friends_tab.png](design-refs/ux-review-2026-08-16/shots/light/Friends_tab.png) · [65-friends-toolbar-1.png](design-refs/ux-review-2026-08-16/shots/manual/movefriends/65-friends-toolbar-1.png) · [34-milestones-scrolled.png](design-refs/ux-review-2026-08-16/shots/manual/homefood/34-milestones-scrolled.png) — `App/Fernlet/ConnectView.swift:466-472`, `App/Fernlet/ActivitiesView.swift:296-298`, `App/Fernlet/MilestonesView.swift:235`, `FernletKit/Sources/FernletUI/FernletPrimitives.swift:59-73`
- **Also reported as:** FRND-24
- **Note:** low severity — not independently verified.

### Shared: motion

**Current:** ![40-firstaid-breathing-start.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/40-firstaid-breathing-start.png) ![37-worrybox-filed.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/37-worrybox-filed.png)

#### PRIV-35 — Low — Tier 1 — Accessibility · Systemic — Repeat-forever animations ignore Reduce Motion

- **What's unclear or slow:** The sealed-box glow pulse, the tuck animation and the breathing circle's idle sway loop forever with no accessibilityReduceMotion check anywhere in the app target.
- **Recommended change:** Read @Environment(\.accessibilityReduceMotion) and skip the idle sway/pulse (static state) and shorten the tuck to a crossfade when it is on; keep the guided breathing scale since it is the exercise itself.
- **Mockup needed:** No (code-only)
- **Evidence:** [40-firstaid-breathing-start.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/40-firstaid-breathing-start.png) · [37-worrybox-filed.png](design-refs/ux-review-2026-08-16/shots/manual/privatesettings/37-worrybox-filed.png) — `App/Fernlet/WorryBoxView.swift:363-365`, `App/Fernlet/BreathingExerciseView.swift:148-155`, `App/Fernlet/WorryBoxView.swift:314-318`
- **Also reported as:** FRND-23
- **Note:** low severity — not independently verified.

### Tab headers

**Current:** ![Home_tab.png](design-refs/ux-review-2026-08-16/shots/light/Home_tab.png) ![Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) ![Move_tab.png](design-refs/ux-review-2026-08-16/shots/light/Move_tab.png)

#### FLOW-34 — Low — Tier 2 — Daily-use speed — Settings gear exists only on Home

- **What's unclear or slow:** Only the Home header has the gear; from any other tab opening Settings is Home > gear (two taps plus a tab switch), and there is no long-press or shortcut.
- **Recommended change:** Either add the same small gear to every tab's ScreenHeader trailing slot, or make a long-press on the Home tab item open Settings.
- **Mockup needed:** No (code-only)
- **Evidence:** [Home_tab.png](design-refs/ux-review-2026-08-16/shots/light/Home_tab.png) · [Food_tab.png](design-refs/ux-review-2026-08-16/shots/light/Food_tab.png) · [Move_tab.png](design-refs/ux-review-2026-08-16/shots/light/Move_tab.png) — `App/Fernlet/HomeView.swift:311-315`, `App/Fernlet/FoodView.swift:68-75`, `App/Fernlet/MoveView.swift:107-123`
- **Note:** low severity — not independently verified.

---

## Coverage and method

- **Evidence.** Three full screenshot galleries produced by the `ScreenAppearance` / `Onboarding` / `Settings` appearance UI suites on an iPhone 17 simulator: light, dark, and accessibility-extra-large Dynamic Type (46 screens each; the AX run failed two asserts — the onboarding **Lock setup** and **Storage choice** primary buttons are pushed off-screen at that size). Plus 311 hand-walked screenshots from three simulator walkers (Home+Food, Move+Friends, Private+Settings), each with an `INDEX.md` giving the tap path per file and the walker's first-hand friction notes.
- **Review.** Eight surface reviewers (Home, Food, Move, Friends, Private, Settings+Onboarding, cross-cutting consistency/a11y, and a daily-flow tracer) read the code against those screenshots. Four adversarial verifiers then tried to refute every high- and medium-severity finding against the code and images; low-severity findings pass through marked as unverified. A final editor pass deduped across surfaces, ranked, and assigned tiers.
- **Result.** 271 raised → 259 survived verification → 190 kept after merges (81 merged or dropped).

**Not covered:**

- Peer-dependent Friends surfaces — verify-QR ceremony, session chat, friend shop, the in-session disposable camera and join prompts (reviewed from code only; no second device).
- Widgets, Live Activities and the recipe share extension (out of scope by request).
- On-device biometrics (simulator has none), the sealed-backup consent sheet (inert on simulator), and cycle predictions/trends (no cycle history seeded).

## Appendix — refuted findings

Raised by a reviewer, then knocked out on verification. Recorded so they don't get re-raised.

| id | Title | Why it was dropped |
| --- | --- | --- |
| `HOME-04` | Saving a meal from Food yanks the user to Home | Same defect and same fix as FOOD-01, which cites the fuller path (showMealLogNotification -> selectedTab = .home plus the FoodView resolve path). |
| `FOOD-17` | 'Fiber 37g' is the target but reads as intake | Same MacroCard footer defect as HOME-18 (shared component); folded its intake-from-micronutrients suggestion into HOME-18's adjusted recommendation. |
| `FRND-26` | Medium-only detent likely clips the Done button | No screenshot exists (sheet unreachable) and the QR is a resizable().scaledToFit() image with only maxWidth 260 (VerifyQRViews 52-58), so the VStack shrinks it to the medium detent instead of overflowing; the Done clip is speculative. |
| `FLOW-02` | Meal row X deletes instantly with no confirmation or undo | Same defect and same undo/confirm recommendation as XCUT-03 (meal-row X, FoodView:142 -> FernletStore.deleteMeal deleting the sealed photo); folded the photo-deferral note into XCUT-03. |
| `FLOW-05` | Confirmation dialogs show only the destructive button, no visible Cancel | Same iOS 26 confirmationDialog-hides-Cancel defect and same .alert recommendation as XCUT-02, which covers more sites (Reset app lock, report/block). |
| `FLOW-07` | Journal draft is discarded silently on swipe; no Cancel | Journal/Meal draft-loss on swipe is the same defect and same SheetCancelBar+interactiveDismissDisabled recommendation as XCUT-04, which covers all eight unguarded sheets. |
| `FLOW-11` | Observations shows two unlabeled system-blue 'None' menus | The label-less blue Observation menus (LogPeriodSheet:175-195) are already stated in XCUT-11 with the same labelled-row + moss tint fix (and their a11y in XCUT-23). |
| `FLOW-17` | Tile labels 'Done', 'Logged', '3 meal', '6x' lack nouns | Same tiles/labels/a11y defect as XCUT-24 (HomeView:970-987, QuickLogButton no accessibilityLabel); the plural/units copy fix has been folded into XCUT-24's adjusted recommendation. |
| `FLOW-19` | Water '+' badge tap target is well under 44pt | The water + badge target (HomeView:946-964, .body glyph + 5pt padding) is already covered by XCUT-24's 44pt-badge recommendation. |
| `FLOW-20` | Sleep sheet clips 'Great' and hides hours; text keyboard for hours | The medium-only clipping is XCUT-05 and the missing decimal pad/Done toolbar is XCUT-22; the remaining claim is false — SleepSheet.prefillFromToday (SharedSheets:152-157) restores today's quality/hours/note and 26-quicklog-sleep-sheet.png shows 'Great' pre-selected, and defaulting to yesterday's sleep would be wrong. |
| `FLOW-23` | Most daily sheets have no Cancel or close control | Same missing/inconsistent close-affordance defect as XCUT-14, which additionally covers the read-only Done pills and the Water primary/secondary inversion. |
| `FLOW-28` | Tab bar labels wrap into two lines at AX sizes | Same AX tab-label wrapping as XCUT-01 (ContentView:612-651, ax/Home_tab.png), which is better stated because it also covers the VoiceOver symbol-name and selection-trait gaps. |

