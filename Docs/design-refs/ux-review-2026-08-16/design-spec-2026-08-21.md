# Design spec (text extraction) — Fernlet Redesign 2026-08-21

Mechanical text dump of `Fernlet-Redesign-2026-08-21.dc.html` (the v2 canvas): every artboard's
labels, copy, and annotation notes in document order. The rendered canvas is the visual truth;
this file exists so an implementing session can read the spec without a browser.

html, body { margin: 0; padding: 0; background: #E9E2D2; }
a { color: #46683A; text-decoration: none; border-bottom: 1px solid rgba(70,104,58,.35); }
a:hover { color: #2F4A25; border-bottom-color: rgba(47,74,37,.6); }
* { box-sizing: border-box; }
Fernlet — UI/UX review redesign
iPhone artboards, 402 × 874 pt, light mode. Every artboard is named with the finding ids it resolves; notes sit in the column beside each screen.
Filled buttons are moss
#5E844D; moss ink stays #46683A so small text clears 4.5:1
Moss
#5E844D stays for tints, icons, fills
All touch targets ≥ 44 pt
AX twins run Increase Contrast: slate → #45535E, card edges 30%, filled moss → #38562C

---

# Batch 5
Settings information architecture
SETT-14 · SETT-29 · SETT-15 · SETT-27 · SETT-08 · SETT-11 · SETT-23
!
The hub on

## 5a
is the load-bearing artboard — every other board in this batch is one of its rows. Two adjacent findings are absorbed while restructuring: the Sleep and Move rows that hold no settings are gone (SETT-26), and Coach moves to the Move tab (part of SETT-14).

## 5a
Settings hub — SETT-14, SETT-29
Done
Settings
Your day
Goal & nutrition
Goal, body, targets, hydration, calories
Reminders
Daily check-in · 8:30 pm
Personal care tasks
3 daily, 2 weekly
Quick-log shortcuts
Six tiles on Home
Data & sources
AI & data sources
On-device AI, web lookup, weather, body signals
Health
3 of 4 kinds shared
Privacy & data
Storage, backups, export, delete
Friends & private
Nearby friends
Presence, vibe, hearts, sharing
Period & sensitive content
Visibility, gating, app lock
Everything stays on your device unless you turn it on.
1
2
3
1
SETT-14
The twelve-section scroll splits four ways, and each row states what is inside it, so the sub-label is the search breadcrumb. Reminders, Personal care tasks and the AI switches stop hiding under a nutrition heading. Sleep and Move — rows that held no settings — are gone; Coach moves to the Move tab, where it is used.
2
SETT-29
Six friend toggles leave the Privacy list for one Nearby friends row with its own sub-page (

## 5b
). Nobody looks under Privacy to change a friends setting. Privacy & data keeps what it is for: storage, backups, export, delete.
3
SETT-29
Every row on today's hub has a stated home, so nothing vanishes in the split:
Appearance
→ Your day ·
App lock, Safety & reporting, Privacy Policy, AI activity log
→ Privacy & data ·
Core memory, Signals
→ AI & data sources ·
Period section toggles
→ Period & sensitive content, which stays a first-class hub row because it gates sensitive surfaces ·
Debug, Connection Inspector
→ one Connection log row in Advanced, behind #if DEBUG (SETT-28) · Sleep and Move deleted (SETT-26), Coach to the Move tab. The 90-word footer becomes the one sentence at the bottom.

## 5a · AX3
Settings hub
Done
Settings
Your day
Goal & nutrition
Reminders
Personal care tasks
What gives way
The rows keep their names and lose their sub-labels — the breadcrumb line is the first casualty, and the row icons go with it. Three of the four "Your day" rows are visible; Data & sources, Friends & private and the footer are a scroll away. This is the argument for the split: at AX3 a twelve-section page is unnavigable.

## 5b
Nearby friends sub-page — SETT-29
Nearby friends
Everything here needs both of you nearby.
Presence
Lets friends see you're around. Hearts and vibe need this on.
Share your vibe
A mood, never a number.
Hearts
Small hellos from friends in the room.
Deliver hearts later
Holds a heart until you're next nearby.
Recipe shares
Hand a recipe over in person.
Clothing shops
Friends can browse what you've designed.
1
1
SETT-29 · XCUT-11
Ordered by dependency: Presence first, because hearts and vibe need it, then vibe, hearts, away delivery, recipe shares, clothing shops. Each carries its own one-line footnote instead of a shared paragraph at the bottom. Toggles are moss-tinted — a routed sheet inherits the tint now, so no stock blue.

## 5b · AX3
Nearby friends
Nearby friends
Presence
Hearts and vibe need this on.
Share your vibe
Hearts
What gives way
Toggles grow to 78 × 46 pt and stay on the label's line, since the names are short enough to survive it. Only Presence keeps its footnote — it is the one with a dependency — and the other five explanations scroll with their rows.

## 5c
"I'm unwell today" on the Today card — SETT-15
2:38
Friday, august 21
Fernlet
bright
good
note
morning
A bit tired today. That's okay.
Today
Goal · Wellness
I'm unwell today
Scoring goes gentle until tomorrow
Quick log
Home
Food
Move
Friends
Private
1
1
SETT-15
A per-day flag belongs on the day. It sits under the health bar in the Today card, dusty rose rather than terracotta — being unwell is not an error — and states what it changes in one line. It clears itself tomorrow. Settings keeps only the explanation of what gentle scoring means, with no control.

## 5c · AX3
"I'm unwell today"
2:33
Fernlet
Today
Wellness
I'm unwell today
Scoring goes gentle until tomorrow.
What gives way
The row keeps its explanation because that is what makes it safe to tap — it is the one sub-line worth the space at this size. The dusty-rose glyph drops, the health bar shows four segments instead of ten, and the companion, bubble and photowall are all above the scroll.

## 5d
Settings › Health, the only Health surface — SETT-27
Health
Fernlet asks for Health access only when a feature needs it.
Share with Health
Turning this off stops every kind below
Body measurements
Weight and height, for macro targets
Shared
Stop sharing
Workouts & activity
Reads Apple Watch workouts, writes yours back
Shared
Stop sharing
Mindfulness
Breathe and ground sessions, written back to Health
Shared
Stop sharing
Cycle & intimate logging
Sealed notes never leave this device. Samples live in Apple Health, under its protections.
Not shared
Give access
1
2
1
SETT-27
One surface, one vocabulary: a master switch that states what turning it off does, then one card per capability — all four that exist today. "Body context" becomes Body measurements; "Workout logging" and "Activity context" merge into Workouts & activity, which is also where sleep hours arrive (there is no separate sleep permission); Mindfulness keeps its own card; "Intimate logging" becomes Cycle & intimate logging. Its copy states the real boundary: sealed notes stay on device, samples belong to Health and travel under Health's own protections — not a claim that nothing syncs.
2
SETT-27 · SETT-26
State and action sit on the same card, so the two pages can no longer disagree about whether a kind is shared. Privacy & data drops its duplicate toggles and keeps one row:
Health access →
. The old "(M2)" placeholder row and its permanently disabled button are deleted, not relabelled.

## 5d · AX3
Health, one surface
Health
Share with Health
Body measurements
Shared
Stop sharing
What gives way
The master switch keeps its own card and loses its sub-line. Each capability keeps the three things that matter — plain-language name, state, action — and drops the description of what Fernlet does with it. One capability card is visible; Workouts & activity, Mindfulness and Cycle scroll.

## 5e
Delete everything — SETT-08
Cancel
Delete everything?
This cannot be undone.
This deletes
Meals, workouts, water and sleep
Journal entries, cycle days, the worry box
Recipes, plans, photos and polaroids
Your companion, wardrobe and coins
All 8 friends and everything they shared
Kept on purpose
Anything already written to Apple Health
Clothing you published to other people
Health samples are yours to remove in the Health app — Fernlet can't reach them once deleted here.
Type DELETE to confirm
DELETE
Cancel
Delete everything
1
2
3
1
SETT-08
180 words of alert become two scannable lists: what goes, what stays. Same sheet shape the lesser "Delete iCloud data" action already uses — the most destructive action in the app should not have the weakest confirmation.
2
SETT-08
The typed gate is the same one iCloud deletion uses, and the Health caveat sits with what is kept rather than as a third paragraph nobody reaches. Two engineering notes: the confirm word is a
matching input
, so it falls under the localization wall — it has to localize with the display string or a French user types DELETE in English forever; and the "Kept on purpose" list here is illustrative and must be reconciled against the wipe-wall disposition table before it ships as truth.
3
XCUT-21 · XCUT-02
Cancel is a real, always-rendered button, not a suppressed dialog role. The terracotta action stays disabled — opacity, never a red error — until DELETE is typed, then fills to the confirm token from

## 2b
.

## 5e · AX3
Delete everything
Cancel
Delete everything?
This deletes
Meals, workouts, water, sleep
Journal, cycle, worry box
DELETE
Delete everything
Cancel
What gives way
The two bullet lists lose their glyph bullets and shorten to phrases; "Kept on purpose" and the Health note scroll, which is acceptable only because the typed gate cannot be passed without scrolling past them. Cancel and the destructive action unstack, with Cancel underneath so the destructive one is never the closest to the thumb.

## 5e · AX5
Delete everything at AX5
Cancel
Delete all?
Deletes
Meals, workouts, journal, friends
Delete
Cancel
What gives way
At AX5 the title shortens and the list collapses to one line naming the four biggest categories. The typed-DELETE gate moves below the fold — the sheet still cannot be confirmed without reaching it, so the protection holds even though it is off-screen.

## 5f
Photo protection vs deletion — SETT-11
Privacy & data
Health access
3 of 4
Photo protection
Photos are sealed on this device. Locking them means a future iCloud backup can never carry them off it.
Lock photos to this device
One way. Nothing is deleted — you just can't move them to another device later.
Backups
Include Fernlet in iCloud backup
Delete
Delete iCloud data
Delete everything
1
2
1
SETT-11
A protective one-way action gets its own card, a lock glyph and a moss outline — the shape Fernlet uses for "this is careful", not "this destroys". Its explanation sits inside the card, so the paragraph the walker tapped is no longer a stray target below an unrelated button.
2
SETT-11 · XCUT-21
Terracotta now means exactly one thing on this page: the two deletions, grouped under their own label at the bottom. Nothing else on the screen is red-adjacent, so the two reds are the two deletes.

## 5f · AX3
Photo protection
Privacy & data
Photo protection
Photos are sealed on this device.
Lock photos
Delete
Delete iCloud data
What gives way
The lock button shortens to "Lock photos" and keeps its moss outline and lock glyph — shape and colour carry the "protective, not destructive" distinction when the label has to give ground. Its one-way footnote scrolls; the two deletions stay grouped under their own label so terracotta still means exactly one thing.

## 5g
Quick-log shortcuts — SETT-23
Quick-log tiles
Drag to reorder. Tap one to swap it.
Meals
Water
Move
Choosing
Move
Log period
Cycle page
Worry box
Breathe
Sleep
Journal
Care
Six tiles, in this order, on Home.
1
2
1
SETT-23
Six chosen shortcuts as one reorderable list instead of six slots that each redraw the whole palette — roughly 48 chips become six rows. Drag to reorder; the order here is the order on Home.
2
SETT-23
Tapping a row opens the palette for that slot only, inline, with the current pick selected — and the picker shows every option, including ones used elsewhere, so nothing silently disappears. "Period" becomes Cycle page; "Log period" keeps its name. Both are drawn here for completeness, but the picker must respect the period-visibility gate and fail closed: when period surfaces are hidden, the two cycle chips are absent from the list, not shown disabled.

## 5g · AX3
Quick-log shortcuts
Quick-log tiles
Meals
Water
Move
Choosing
Move
Cycle page
What gives way
Drag handles hold at 26 pt while rows grow to 88, so reordering stays possible without the handle eating the label. The inline picker keeps stacking one chip per row — the thing SETT-23 was fixing, a palette that wraps into dozens of chips, would be five screens tall here.

---

# Batch 4
Food logging & recipes
FOOD-08 · FOOD-14 · FOOD-24 · FLOW-15 · FOOD-15 · FOOD-05 · FOOD-07 · FOOD-19 · FOOD-22 · FOOD-35
!
Two placements to sanity-check.
Capture
loses its moss fill on

## 4a
— it was a second green primary competing with Save.
FOOD-19
asks for Done top-right on the recipe book, and

## 4e
does that — the same trailing slot every other sheet now uses, so complying with the finding and matching the template turned out to be one move.

## 4a
Log meal, medium detent — FOOD-08, FOOD-14, FOOD-24
2:33
Food
Eating enough, eating well.
Cancel
Log meal
What did you eat?
Meal type
Auto · breakfast
Breakfast
Lunch
Dinner
Snack
Post-workout
Capture
Scan label
Enter macros by hand
Save
Medium detent · 437 pt
1
2
3
1
FOOD-08 · FOOD-14
Meal type moves directly under the field, so type → meal type → Save all happen without a drag. Six chips in one fixed order, Breakfast first, wrapping to two rows — the bottom-anchored menu that reversed itself is gone. Auto is preselected and states what it inferred, so the user can confirm rather than guess.
2
XCUT-14
Capture drops to a cream secondary beside Scan label. It was a full-width moss button one screen-third above the moss Save — two greens, and the louder one wasn't the commit. Recent moves out of this row into its own surface (

## 4d
).
3
FOOD-24
A stated path to typing macros, on the sheet rather than buried in the by-hand screen. It opens three protein/carbs/fat fields, prefilled by a label scan when there is one and editable when there isn't — and the "you can add them later" line goes away, because there was no later.

## 4a · AX3
Log meal — forced to .large
Cancel
Log meal
What did you eat?
Meal type
Auto · breakfast
Breakfast
Save
What gives way
The meal-type chips are the whole point of FOOD-08, so they keep their place directly under the field — but at 80 pt each the six of them are 540 pt, so the sheet opens .large and the last four scroll. Capture, Scan and "Enter macros by hand" are below the fold; the Auto chip keeps its inferred value at a slightly smaller label so it stays on one line.

## 4a · AX5
Log meal at AX5
Cancel
Log meal
What did you eat?
Auto
Breakfast
Save
What gives way
At AX5 the Auto chip loses its inferred value and the section label goes; the field and two chips are the screen. This is the honest floor for this sheet — anything more and either the field or the commit would be off-screen.

## 4b
Food root, just logged — FLOW-15, FOOD-15, FOOD-35
2:33
Food
Eating enough, eating well.
meal
Macros today
Adjust targets
76g
Protein
of 93g
114g
Carbs
of 372g
35g
Fat
of 88g
Planned today
Overnight oats
Breakfast · P 16g
Log
Breakfast
Greek yogurt with berries
P 28g
C 34g
F 9g
Estimated
Adjust
Lunch
Chicken rice bowl
P 42g
C 58g
F 14g
Chicken rice bowl logged
Lunch · P 42g · C 58g · F 14g
Undo
Adjust
Home
Food
Move
Friends
Private
1
2
3
1
FOOD-35
"Planned today" sits above the meals with one Log per recipe, so a plan made on Sunday costs one tap on Wednesday instead of a trip through the book. The card only exists on days that have a plan — no empty state, no nagging.
2
FOOD-15 · FOOD-02
The whole row is the button. "Looks off?" becomes a right-aligned Adjust with a chevron in a 44 pt frame on its own trailing line, so it can never wrap. The goldenrod jargon tag becomes a quiet slate capsule in plain words — Estimated, Reviewed, From recipe — and disappears entirely for seeded logs. The X stays, but it stops being an instant delete — it now carries the destructive tint from

## 2b
and routes through "Remove this meal?" with its photo named in the copy. Undo on the toast covers the five seconds after a log; the X covers everything older.
3
FLOW-15 · FOOD-01
The toast becomes the fastest correction path: five seconds, Undo removes the meal, Adjust opens

## 4c
for the meal just logged. It appears over whichever tab you logged from — no jump to Home — and sits above the tab bar so neither covers the other.

## 4b · AX3
Food root, just logged
2:33
Food
Macros today
76
P
114
C
35
F
Greek yogurt
P 28g
Adjust
Chicken rice bowl logged
Undo
Adjust
Food
What gives way
The macro rings become numerals with one-letter labels — three donuts with 40 pt values inside them cannot hold a readable ring at this size. The meal row loses its thumbnail and its C/F figures so the name and Adjust stay whole. The toast stacks its two actions under the message and keeps both at 76 pt.

## 4c
Adjust meal — FOOD-05
Cancel
Adjust meal
Scrambled eggs and toast · breakfast
Matched items
Scrambled eggs
2
eggs
P 12g · C 1g · F 10g
French toast sticks
Probably not what you meant
Replace
Add an item
sourdough toast
Sourdough bread, toasted
P 5g · C 26g · F 1g · per slice
Catalog
New total
P 17g · C 27g · F 11g
Save
1
2
1
FOOD-05
Each matched item can be removed outright, and a bad match can be replaced rather than deleted-and-re-logged. Quantity is styled as a field — cream fill, taupe underline — so it stops reading as static text. A low-confidence match is outlined in sun and says so in words.
2
FOOD-05
"Add an item" opens the same debounced catalogue typeahead the recipe editor uses — suggestion, source badge, macros per unit. Totals recompute from the item list, so the number under the rings always matches what is on screen.

## 4c · AX3
Adjust meal
Cancel
Adjust meal
Matched items
Scrambled eggs
2 eggs
+ Add an item
Save
What gives way
Quantity moves under the item name instead of beside it, keeping the field wide enough to read and the remove target at 64 pt. The per-item macro line and the mis-matched second item scroll; the new-total row sits just above the bar and is the next thing to go.

## 4d
Recent meals — FOOD-07
Done
Recent
Tap to log it again with today's time.
Greek yogurt with berries
Breakfast · yesterday 7:40 · P 28g
Log
Chicken rice bowl
Lunch · yesterday 13:10 · P 42g
Log
Apple and almonds
Snack · Tue 16:05 · P 6g
Log
Overnight oats
Breakfast · Tue 7:25 · P 16g
Log
Repeats collapse into one row — the most recent time wins.
1
1
FOOD-07 · FOOD-06
Deduped case-insensitively, newest wins, top eight. Every row states meal type, when it was last eaten and its protein, so two identical names are told apart by the only things that differ. Logging one stamps today's time and re-derives the meal type — it does not inherit yesterday's breakfast slot or its note.

## 4d · AX3
Recent meals
Done
Recent
Greek yogurt with berries
Breakfast · 7:40
Log
Chicken rice bowl
Lunch · 13:10
Log
What gives way
Each row becomes a card: name, then meal type and time on their own line, then a full-width Log. The protein figure drops — meal type and time are what disambiguate two identical names, which is what FOOD-07 asked for. Two of eight rows are visible.

## 4e
Recipe book — FOOD-19, FOOD-14
Done
Recipe book
Recipes and saved products, A–Z.
Create
Planner
List
Search recipes and products
Your recipes
Overnight oats
2 servings
3 ingredients · P 16g · C 37g · F 5g
Log
Share
Sheet pan chicken and vegetables
4 servings
4 ingredients · P 26g · C 16g · F 17g
Log
Share
Saved from web
Miso salmon
2 servings
1
2
1
FOOD-19 · XCUT-14
The book gets a close control at last — top-left, like every other sheet. Create loses its moss fill and joins Planner and List as three equal secondary actions: entering the book is not the same as committing anything.
2
FOOD-19 · FOOD-14
Rows adopt the Food-root layout: summary above, controls on their own trailing line — so "2 servings" sits at the trailing edge instead of drifting to the middle. The bare fork icon becomes a labelled Log pill that opens the meal-type chip row inline, and section labels name what you are looking at: Your recipes, Saved from web, Imported products.

## 4e · AX3
Recipe book
Done
Recipe book
Create
Planner
Your recipes
Overnight oats
2 servings
Log
What gives way
The three toolbar buttons stack and List scrolls off; the search field goes with it. Row layout is unchanged in principle — summary above, controls on a trailing line — but the trailing line now holds only Log, with Share and the chevron below the fold.

## 4f
Recipe detail with Steps — FOOD-22
2:36
Overnight oats
2 servings · 5 min · chills overnight
Add a photo of this recipe
Per serving
Protein
16g
Carbs
37g
Fat

## 5g
Ingredients
1 cup · Rolled oats
1 cup · Greek yogurt
0.5 cup · Blueberries
Steps
1
Stir the oats and yogurt together in a jar.
2
Chill overnight.
8 hr
3
Top with blueberries before eating.
Cook
Log this recipe
1
2
1
FOOD-22
A Steps card under Ingredients: numbered, with the timer minutes shown as a quiet capsule where one is set. Steps you typed in the editor are now readable without starting cooking mode — Cook stays as the hands-free walker, not the only way to see what you wrote. The timer capsule assumes per-step durations exist on the model; cooking mode implies structured steps, but confirm the duration field before promising it — without it the capsule simply does not render.
2
FOOD-14
"Log this recipe" is the one primary; Cook is its cream sibling. It opens the same meal-type chip row as the meal sheet and routes through the same toast, so logging from a recipe finally says something happened.

## 4f · AX3
Recipe detail, Steps
2:33
Overnight oats
Steps
1
Stir the oats and yogurt together in a jar.
2
Chill overnight.
Log this recipe
Cook
What gives way
The photo slot, macros and ingredients scroll above Steps — the section this finding adds is the one worth showing. Step numerals stay 44 pt circles so they remain scannable beside 40 pt text, and the timer capsule drops. Cook and Log unstack into a full-width pair, primary on top.

## 4g
Meal planner day card — FOOD-35
Done
Meal planner
Aug 18–24 · feeds the shopping list.
Today · Friday
2 planned
Overnight oats
Breakfast
Log
Sheet pan chicken and vegetables
Dinner
Log
Saturday
Miso salmon
Dinner
Sunday
Nothing planned.
1
2
1
FOOD-35
Today's card is the only one with Log pills, and it carries the moss outline so it is findable at a glance. Each planned recipe logs against the meal type it was planned for — the plan already knows, so the user isn't asked twice.
2
FOOD-35 · XCUT-21
Future days keep remove only — and remove now reads as the destructive token from

## 2b
rather than a neutral minus. Future Log pills are omitted deliberately: logging Saturday's dinner on Friday is almost always a mis-tap.

## 4g · AX3
Meal planner day card
Done
Meal planner
Today
Overnight oats
Breakfast
Log
Saturday
Miso salmon
What gives way
Today's card keeps its moss outline and its Log pill, now on a line below the recipe with the remove target beside it at 76 pt. The second planned recipe and the "2 planned" badge scroll; Sunday's empty card is below the fold.

---

# Batch 3
Home root & quick log
FLOW-18 · HOME-09 · HOME-28 · HOME-10 · HOME-22 · HOME-30 · HOME-13
!
HOME-28's "one header treatment" is resolved as:
every card states its own name inside itself
, DM Serif Display 20 top-left. The external uppercase section label above Quick log is retired — it was the only one of its kind. HOME-13 asks for a large sheet with Done, and

## 3f
now gives exactly that — Done in the trailing header slot under the three-slot rule on

## 2a
, which is also where Trends and First aid put theirs.

## 3a
Home root, cold open — FLOW-18, HOME-09, HOME-28
2:32
Friday, august 21
Fernlet
bright
good
note
morning
You marked today as bright. Let that be enough information for now.
Today
Goal · Wellness
Quick log
Meals
3 logged
Water
6 bottles
Move
1 logged
Sleep
7h 20m
Journal
1 entry
Care
2 of 3
How today felt
Bright
Good
Neutral
Quiet
Tired
Hard
Home
Food
Move
Friends
Private
1
2
3
1
FLOW-18
Polaroid strip 133 → 92 pt, Today card padding halved, tiles 66 → 56. Both grid rows and the mood row beneath them now finish above the floating tab bar on a 6.1-inch cold open — nothing that gets touched daily starts life behind the bar.
2
HOME-09
One convention, six tiles:
noun over state
. Name in DM Sans Medium 12, state in 11 slate underneath — a count with its unit ("3 logged", "6 bottles", "2 of 3") or "none yet". "3 meal", "6x", bare "Done" and bare "Logged" all disappear, and every tile reads the same way to VoiceOver.
3
HOME-28 · HOME-11
Every card names itself inside itself in DM Serif Display 20 — Today, Quick log, How today felt. The mood row also stops being a horizontal scroll: six chips wrap onto two lines, so Tired and Hard are no longer hidden past the card edge.

## 3a · AX3
Home root, cold open
2:33
Fernlet
Today
Wellness
Quick log
Meals
3
Water
6
Move
1
Sleep
7h
Home
What gives way
The grid goes 3-up to 2-up — three tiles at a 30 pt noun cannot share 362 pt — so four of the six tiles are visible and Journal and Care are one scroll down. The photowall, companion and thought bubble scroll off entirely; the date eyebrow and mood row go too. FLOW-18's promise holds in the sense that matters: the grid still starts above the bar.

## 3b
Move tile → Log workout — HOME-10 (chosen)
2:32
Fernlet
Cancel
Log workout
Kind
Strength Training
Cardio & activity
Recent
Bench press
3×8 · 60 kg
Back squat
4×8 · 80 kg
Dip
Exercise
Search exercise or muscle
Save
Medium detent · 437 pt
1
2
1
HOME-10
The Home tile stops opening a strength-only picker and presents the Move tab's own Log workout sheet — the identical component from

## 1f
, kind chips first, detents [medium, large]. A walk, a run or a ride is now two taps from Home instead of impossible.
2
HOME-10 · MOVE-08
Kind, Recent and the search fit inside the medium detent alongside the primary, so the quick path stays quick: the sheet the tile opens is never one the user has to drag open first. Optional name and "Log it again" live below the fold, where they belong.

## 3b · AX3
Move tile → Log workout, .large
Cancel
Log workout
Kind
Strength
Cardio
Bench press
Save
What gives way
Same story as

## 1b
: kind chips at 80 pt each plus a label do not fit the medium detent with the primary, so the sheet opens .large. One Recent chip stays visible and drops its sets×reps line; the search field and catalogue scroll.

## 3b · AX5
Log workout at AX5
Cancel
Log
Strength
Cardio
Save
What gives way
At AX5 the title truncates to "Log", the Kind label goes, and the two chips plus the commit are the whole screen. Save goes full width rather than keeping the trailing position — a 53 pt label in a trailing pill would leave no room for anything beside it.

## 3c
Quick exercise + quick kinds — HOME-10 (not chosen)
Cancel
Quick exercise
Log a kind
Walk
Run
Ride
Stretch
Gym
Or pick an exercise
Search exercise or muscle
Bench press
Upper – Chest, Front Delts, Triceps
Incline bench press
Upper – Chest, Front Delts, Triceps
Overhead press
Upper – Front Delts, Traps, Triceps
Save
1
1
HOME-10 — second option
Keeps Quick exercise as its own sheet and adds the five kinds above the search. Cheaper to ship and it preserves the fast strength path, but Home and Move stay two different logging surfaces — which is the divergence HOME-10 exists to close. Not chosen —

## 3b
is the direction.

## 3c · AX3
Quick exercise
Cancel
Quick exercise
Log a kind
Walk
Run
Ride
Save
What gives way
The five quick kinds lose their icons and their wrapping row, becoming full-width rows — three visible, Stretch and Gym one scroll down. The exercise search and its results are below the fold, which is the argument against this variant: at AX3 it is two screens where

## 3b
is one.

## 3d
Companion area, Customize visible — HOME-22
2:32
Friday, august 21
Fernlet
bright
good
note
morning
You marked today as bright. Let that be enough information for now.
Customize
Body signals
Today
Goal · Wellness
Quick log
Home
Food
Move
Friends
Private
1
1
HOME-22
A Customize chip sits beside Body signals under the companion — 44 pt, pencil glyph, same cream pill as its neighbour so the pair reads as one row of companion actions. The 0.45 s long-press keeps working for people who already know it; it is no longer the only door. Wardrobe and the Studio move inside the sheet (

## 3e
).

## 3d · AX3
Companion, Customize visible
2:33
Fernlet
Customize
Body signals
What gives way
The two companion chips unstack to full-width rows, so "Customize" is never the thing that gets truncated to make room for its neighbour. The thought bubble and photowall scroll above the companion; the Today card and quick-log grid are below the fold.

## 3e
Customize sheet — HOME-22, HOME-30, XCUT-14
128
Done
Customize
Tap a slot to change it.
Wardrobe
9 items
Creation Studio
Body
Circle
Accessory
Sprout
Clothing
None
Side item
None
Everything you've unlocked stays unlocked.
1
2
1
XCUT-14 · XCUT-15
The centred serif title and the floating moss pill are replaced by the standard chrome: left-aligned Fraunces 28 with Done as a text button in the trailing header slot. The coin balance moves to the leading slot — a balance is information, not an action, so it gives up the slot that dismisses the sheet.
2
HOME-22 · HOME-30 · HOME-24
Wardrobe and Creation Studio become named rows beside the companion, each with one chevron — no doubled affordance. Inside the Studio the palette moves above the pinned Next bar and the slot picker becomes Fernlet chips instead of a system segmented control, so a colour is pickable before the first stroke.

## 3e · AX3
Customize sheet
128
Done
Customize
Wardrobe
9
Creation Studio
What gives way
The companion stops sharing a row with the Wardrobe and Studio links and sits above them, centred. The coin balance keeps the header's trailing slot but drops its glyph. Body, Accessory, Clothing and Side item — the four slot rows — are all below the fold.

## 3f
Milestones as a large sheet — HOME-13
Done
Milestones
Everything here is cumulative. Nothing resets.
Meals logged
124
150 unlocks a picnic blanket.
Journal entries
14
A keepsake at 20.
Workouts
22
Two gifts waiting on the shelf.
Keepsake shelf
2 gifts
1
2
1
HOME-13
One rule for read-only destinations from Home:
they present as large sheets
. Milestones stops being the odd push with a back chevron and a lingering tab bar, and now matches Trends, First aid and the gear.
2
HOME-13 · HOME-20
Keepsake shelf pushes inside the sheet's own stack, so the sheet owns its depth. Gift counts come from one source — the row states what is on the shelf rather than a threshold count that can disagree with the footer.

## 3f · AX3
Milestones sheet
Done
Milestones
Meals logged
124
150 unlocks a picnic blanket.
Keepsake shelf
What gives way
One milestone card fills the screen at 40 pt body, so the other two and the italic subtitle scroll. The count keeps its own line beside the name because both are short; the reward line wraps rather than truncating. Keepsake shelf stays reachable as a row.

---

# Batch 2
Canonical sheet template & Water sheet
XCUT-14 · XCUT-15 · XCUT-21 · FRND-19 · HOME-02
!
XCUT-14 wants Water's Done demoted so it stops outshouting the real action; your scope note wants Done in one predictable place. The three-slot rule on

## 2a
satisfies both: the stepper becomes the action, and Done is a text button in the trailing header slot beside Cancel — fixed position, no moss pill competing for attention, and no bottom bar on a sheet that edits in place.

## 2a
The Fernlet sheet — XCUT-14, XCUT-15
Cancel
Sheet title
Optional one-line subtitle, never two.
Field · 20 pt gutters
Selected
Chip
Chip
Content scrolls. Nothing else does.
Field
Save
1
2
3
4
1
XCUT-14
Three slots, one rule, all 19 sheets:
Cancel top-left
when a draft can be lost,
Done top-right
to dismiss or commit in place,
Save bottom-right
only when a draft is being committed. Done never moves to the bottom bar — that was the inconsistency, four sheets putting it there and two putting it up top. 44 pt rows, DM Sans Medium 16 in moss.
2
XCUT-15
One header, six voices retired: Fraunces SemiBold 28 title, optional Instrument Serif Italic 15 subtitle, left-aligned under the Cancel row. The 36 pt screen header belongs to tab roots and pushed pages only — never to a sheet.
3
Detents
Every sheet gets [medium, large]. The rule that makes it real: whatever the user opened the sheet to do fits above the medium line — the drag is for context, never for the control. 20 pt gutters, 14 pt stack, one scroll surface.
4
XCUT-14
A draft sheet commits bottom-right in a bar with a hairline above it — 52 pt moss pill, 26 pt safe inset. A read-only or live-editing sheet has no bar at all: Done sits top-right and is the whole exit. The bottom-right moss "Done" pill is retired everywhere.
Cancel
Title
Entry sheet
Done
Title
Read-only sheet

## 2a · AX3
The Fernlet sheet at AX3
Cancel
Sheet title
Field
Selected
Chip
Save
What gives way
The template's AX rules, in order: the subtitle is the first thing to go; chips go one per row at 80 pt; the commit stays bottom-right until its label would wrap, then goes full width; the detent grows to .large rather than hiding a control. Cancel and the header never move.

## 2b
Destructive token — XCUT-21, FRND-19
Full-width action
Delete recipe
Duplicate recipe
Delete recipe
destructive
neutral
disabled
Chip
End activity
Dismiss
Block
Leave · Delete all · Remove · Block · Report · End session take the destructive chip. Dismiss, Decline and Cancel stay neutral.
Row
Add a task
Remove this task
Filled — confirmation only
Remove this meal?
Its photo goes with it.
Keep it
Remove
Terracotta ink #A8452F on cream
6.0:1
Parchment ink on filled #A8452F
5.1:1
Brief terracotta #B9543D, filled
4.2:1 — tint only
1
2
3
1
XCUT-21
One style replaces five: terracotta ink and a trash glyph on a terracotta-12 % card, full width. Terracotta, not system red, so it survives dark mode. Disabled drops to 6 % fill and taupe ink — opacity, never a red error.
2
FRND-19
The Friends chips inherit the same token instead of the cream outline they share with Dismiss: terracotta ink on a 10 % fill with a 35 % edge. The chip reads its button role, so nothing has to be styled per call site.
3
XCUT-21 · XCUT-02
Solid terracotta is reserved for the confirm button inside an alert — the one place a destructive action should be the loudest thing on screen, and the one place the keep-it button is guaranteed to render beside it.

## 2b · AX3
Destructive token at AX3
2:33
Full-width action
Delete recipe
Duplicate
Chip
End activity
Dismiss
What gives way
The glyph holds at 26 pt while the label grows, so a destructive control is still identifiable when the text is too big to scan. Chips lose their row and stack; the state labels under each specimen and the contrast readout move below the fold. Disabled stays an opacity drop, never a colour change.

## 2c
Water sheet, medium detent — HOME-02
2:33
Friday, august 21
Fernlet
Cancel
Done
Water
24 oz each · target 4 bottles
target met
6
bottles
144 oz today. Plenty.
Medium detent · 437 pt
1
2
3
1
HOME-02 · HOME-18
The hero numeral is the stepper's value, so the count is stated once. Bottles read as a row of glyphs with a goldenrod tick at the target instead of a second number, and the total drops to one italic line — no target masquerading as an intake figure.
2
HOME-02
The left-aligned Remove / "Add a bottle" pair becomes one centred stepper directly under the bottle row. 56 pt circular targets, 22 pt apart — comfortably past 44 with no neighbour to mis-hit. Plus carries the moss fill because adding is what people come here to do; minus is the cream sibling, not a destructive control.
3
XCUT-14
Sheet chrome from

## 2a
: Cancel top-left, Done top-right — the trailing header slot, not a bottom pill. That pairing is a behaviour change, not just a layout one —
the sheet becomes transactional
: the stepper edits a draft, Done commits it, Cancel reverts. Today it writes live, which would make Cancel a lie. Transactional is the call because an accidental +3 followed by a swipe is otherwise unrecoverable. Detents are [medium, large]; the drag is optional at every text size.

## 2c · AX5
Water sheet at AX5
Cancel
Done
Water
6
6 bottles
What gives way
AX5, the worst case for

## 2d
's claim: the stepper survives because it is second in the stack and its targets grow to 96 pt. The bottle glyphs, the oz total and the target line are all gone; the count states itself once in words. Done is full width at 100 pt.

## 2d
Water sheet at accessibility text size (AX3) — HOME-02
2:33
Fernlet
Cancel
Done
Water
6
6 bottles · 144 oz
24 oz each. Target 4, met.
Medium detent · 437 pt
1
2
1
HOME-02
The stepper is second in the stack, so it is the last thing that could ever fall below the fold. What gives way as type grows is decoration: the glyph row collapses to a text count, the caption reflows, the target line merges into it. Targets scale 56 → 64 pt rather than shrinking.
2
XCUT-17 · XCUT-19
Done is a text button in the trailing header slot at every text size, so there is no commit pill to wrap or outgrow — the reason the template puts it there rather than in a bar. Cancel keeps the leading slot; both stay 44 pt tall as the label grows.

---

# Batch 1
Move workout flow
FLOW-03 · MOVE-01 · MOVE-17 · MOVE-10 · MOVE-26 · MOVE-08 · MOVE-34
!
Two entries were re-pointed where the screenshots contradict the review text.
MOVE-17
— the Suggest sheet already ships a single green primary, so the competing-primaries fix lands on

## 1d
(Today's session).
MOVE-10
— the nested 260 pt type list and the duration/effort fields live in Log workout's Cardio & activity mode, not in Suggest, so it is resolved on

## 1g
.

## 1a
Move root, no plan yet — FLOW-03
2:32
Move
Enough to feel it, not enough to drain.
Log
Share
Goal
Wellness
Space
Full gym · 22 items
Today's workout
Nothing planned yet — I can put something together.
Suggest today's workout
Aug 16
-
Aug 22
S
16
Rest
M
17
Rest
T
18
Rest
W
19
Rest
T
20
Rest
F
21
Rest
S
22
Rest
Workout
Upper
Lower
Full Body
Exercise history
Today's movement
No workouts today. No rush.
Progress photos
Home
Food
Move
Friends
Private
1
1
FLOW-03
The card now always renders on the Move root. Empty state carries one primary that opens Suggest workout directly from the root — one sheet, not three. Same card, icon, header and button geometry as the with-plan state, so the two read as one component: only the body line and the button label change.

## 1a · AX3
Move root, no plan
2:32
Move
Today's workout
Nothing planned yet.
Suggest workout
Aug 16–22
rest
19
20
21
›
Move
What gives way
Body 40, labels 32. The card keeps everything — header, line, 88 pt primary — but its button label shortens to "Suggest workout" — 250 pt on one line inside a 284 pt button, so it holds its 88 pt height rather than wrapping. The week strip shows three days plus a scroll affordance instead of seven, and drops its per-day captions and legend. The Today's movement card, photowall, exercise history and progress photos are all below the fold — at 40 pt body only two cards clear the tab bar. The tab bar goes icon-only with the selection labelled.

## 1b
Suggest workout sheet, medium detent — MOVE-34, XCUT-15
2:33
Move
Enough to feel it, not enough to drain.
Cancel
Suggest workout
How are you feeling?
Today's readiness suggests hard.
Light
Moderate
Hard
Space & equipment
Full gym · 22 items
Change
Anything else?
e.g. sore left knee, short on time
Suggest a workout
Medium detent · 437 pt
1
2
3
1
XCUT-15 · XCUT-14
Cancel added top-left — the sheet was swipe-only to dismiss. Grabber, Cancel, then title: the same chrome order every Fernlet sheet gets in Batch 2.
2
MOVE-34
The saved space is stated inline with one Change action instead of a preset grid. Presets only appear behind Change, and only the ones you don't already own — see

## 1c
.
3
Detent
Feeling, space and the note all sit above the primary inside the 437 pt medium detent — the sheet's children sum to the detent exactly, with no internal scroll. Detents stay [medium, large]; the drag is for reading, never for reaching a control.

## 1b · AX3
Suggest workout — forced to .large
Cancel
Suggest workout
How are you feeling?
Light
Moderate
Hard
Suggest
What gives way
Chips are 80 pt each at a 40 pt label, so the three of them plus their section label come to 300 pt — the 437 pt medium detent cannot hold that and the primary and the title too. The sheet opens .large instead: grow the sheet, never hide the control. The readiness line, the space row and the note field all scroll.

## 1b · AX5
Suggest workout at AX5
Cancel
Suggest
Light
Moderate
Hard
Suggest
What gives way
Body 53. The title drops to one word and the "How are you feeling?" label goes with it — the three chips are self-describing and each is 100 pt. Nothing else fits on screen; space, note and readiness are all a scroll away. The primary grows rather than wrapping, the exception recorded on

## 2d
.

## 1c
Your spaces — MOVE-34
Cancel
Done
Your spaces
Suggestions only use what's here.
Saved
Full gym
22 items · barbell, rack, machines
In use
Home
6 items · bands, mat, kettlebell
Add a location
Two spaces saved. Hotel gym, park and travel presets are behind Add.
1
1
MOVE-34
Once one location exists the four preset cards collapse into a single "Add a location" tile, and a saved space never appears twice. Saved rows own the space; presets are a step inside Add, filtered to the ones not already saved.

## 1c · AX3
Your spaces
Cancel
Done
Your spaces
Saved
Full gym
22 items
In use
Home
6 items
+ Add a location
What gives way
The "In use" badge moves under the name instead of competing for the same line, and each row keeps only its count — the equipment summary drops. The Add tile is 88 pt. Done keeps the trailing header slot and grows with the type rather than moving to a bar; the explanatory caption is the first thing to go.

## 1d
Today's session — MOVE-17, MOVE-01
2:34
Move
Cancel
Daily movement · day 1
Today's session
Full Body A
5 exercises · ~45 min
Back squat
4 × 8–12
Band chest press
4 × 8–12
Band row
4 × 8–12
Band good morning
3 × 10–12
Medicine ball slam
3 × 10–12
Full gym · built for a hard day
Start it now, or save it and it'll be waiting on the Move root.
Edit
Save for later
Already did this — log it
Start now
1
2
1
MOVE-17
One green on the screen. Approve becomes "Save for later" — an outline pill beside Edit — and the explanatory paragraph shrinks to the one italic line above. "Already did this" keeps its moss-tint capsule at 48 pt. Cancel sits top-left where the other Move sheets have it.
2
MOVE-01
Start now is the only route into the runner, so finishing has one place to land: this sheet dismisses itself and the user is back on the Move root with the session logged.
Move root
→
Suggest
→
Runner
→
Move root, logged

## 1d · AX3
Today's session
Cancel
Today's session
Full Body A
Back squat
4 × 8–12
Edit
Save for later
Start now
What gives way
Exercise and prescription stop sharing a line, which costs 86 pt per exercise — only the first one stays above the fold, the other four scroll. Edit and Save for later unstack to full width and keep their outline; the "Already did this" tertiary and the one-line caption move below the primary bar.

## 1e
Guided runner, mid-set — MOVE-26
Full Body A
Exercise 1 of 5 · 38 min left
Back squat
Set
1 of 4
Reps
8–12
Last time
60 kg
Sets
Rest after this set
90 seconds — I'll count it for you
Up next
Band chest press
4 × 8–12
Band row
4 × 8–12
Band good morning
3 × 10–12
No rush getting started.
Done set
Skip to next exercise
1
2
1
MOVE-26
The empty lower 60 % now earns its keep: a segmented set strip (the health-bar pattern), the rest preview that used to be a surprise, and the next two exercises. All of it scrolls; none of it is a control.
2
MOVE-26
Done set moves into a fixed bar above the safe area — 56 pt, thumb reach, unmoved as the set count changes. In the rest phase the same bar holds "Skip rest", and on the last set the label becomes "Finish workout".

## 1e · AX3
Guided runner, mid-set
Full Body A
1 of 5
Back squat
Set
1/4
Reps
8–12
Rest next
90 seconds
Done set
Skip
What gives way
"Exercise 1 of 5" abbreviates to "1 of 5" and "Set 1 of 4" to "1/4" so the numerals stay at 40 pt rather than the labels shrinking. The "Last time" pill and the Up next list are gone; the rest preview keeps a 26 pt eyebrow. The bottom bar is the point of the finding, so it is the one thing that never moves.

## 1f
Log workout sheet — MOVE-08
Cancel
Log workout
Wednesday · upper body
Log it again
Bench press, Lat pulldown, Dip · 3 more
Log again
Workout
Optional, e.g. Upper strength
Kind
Strength Training
Cardio & activity
Recent
Bench press
3×8 · 60 kg
Back squat
4×8 · 80 kg
Dip
Exercise
Search exercise or muscle
Bench press
Upper – Chest, Front Delts, Triceps
Incline bench press
Upper – Chest, Front Delts, Triceps
Save
1
2
1
MOVE-08
"Log it again" entry card copies the most recent workout of the same category, mirroring Plan's "Copy previous week". Not a green primary — Save still owns that.
2
MOVE-08
Recent chips sit above the search, last five exercises, each carrying its last sets×reps×weight so a tap prefills instead of opening the keyboard. 44 pt tall, scrolls horizontally past three.

## 1f · AX3
Log workout
Cancel
Log workout
Wed · upper body
Log it again
Log again
Kind
Strength
Cardio
Save
What gives way
The Log-again card puts its button on its own line under the body copy. Kind chips go one per row and shorten to "Strength" / "Cardio" — at 40 pt "Cardio & activity" would wrap inside its own pill. Recent chips, the name field and the catalogue are all below the fold; Save keeps the trailing position.

## 1g
Log workout → Cardio & activity, type chosen — MOVE-10
Cancel
Log workout
Kind
Strength Training
Cardio & activity
Activity
Walking
Outdoor · counts toward daily movement
Change
Duration
42
min
Distance
3.8
km
Effort
5 of 10
Comfortable — could hold a conversation.
Note
Optional
Save
1
2
1
MOVE-10
The 260 pt inner ScrollView is gone. Once a type is chosen it collapses to the chosen row with Change, exactly as the exercise picker does. Before selection: six chips plus search, one scroll surface.
Walking
Running
Cycling
Yoga
Swimming
Hiking
Search…
2
MOVE-10 · MOVE-09
Duration, Distance and Effort are now the first thing under the chosen type instead of below a nested list. Effort reads its value as text next to the label, and the track is moss — no system blue anywhere in Fernlet. Energy (kcal) only appears when the calories opt-in is on.

## 1g · AX3
Cardio & activity
Cancel
Log workout
Activity
Walking
Change
Duration · min
42
Effort · 5 of 10
Save
What gives way
Each numeric field takes a full row and folds its unit into the label, so Duration reads as one 44 pt numeral instead of a number fighting a suffix. Distance and Note scroll below the fold; Effort keeps its value in the label and a 48 pt thumb. Two side-by-side numeric fields are the classic AX truncation — there are none left here.
class Component extends DCLogic {
renderVals() {
return {
showAnnotations: this.props.showAnnotations ?? true,
showFoldGuides: this.props.showFoldGuides ?? true
};
}
}
