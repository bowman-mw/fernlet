# Recipes as reusable building blocks: design (2026-11-15)

Status: **APPROVED by the owner 2026-11-15 (all 12 picks: the recommended option, no notes).** Nothing is built yet. ROADMAP item "Recipes as reusable
building blocks" (owner direction 2026-11-15).

## What the owner asked for

1. A saved recipe can be picked as an ingredient in another recipe (a sauce in a pasta).
2. Recipe parts become separate saved recipes instead of in-recipe parts, so they are reusable, and
   their steps fill into the recipes that use them.
3. On a pasted recipe's unmatched line ("1 cup dragonfruit sauce"), a **Make a recipe for it** button
   opens a new blank recipe named after the line and, on save, binds that line to it.

This reverses one part of the 2026-09-24 multipart decision (`RecipeComponents.swift` header): parts
were kept inside one recipe so that nothing could dangle or loop. This design keeps both of those
guarantees with a different mechanism (§1, §4).

## Today

- `RecipeIngredient` holds `foodItemId`, `quantity`, `unit`, optional `householdMeasure`. Nutrition is
  never stored on the line: `MealBuilder.componentSnapshots` resolves each line against its `FoodItem`
  through `RecipeServingConversion`. One unresolvable line rejects the whole recipe (totals read 0, the
  meal is not built).
- `RecipeDefinition.components` is a partition over the flat `ingredients`/`steps` by id. Every
  consumer (nutrition, scaling, grocery, logging) reads the flat arrays, so parts are display-only.
- Logged meals freeze `MealComponentSnapshot`s at log time. Editing a recipe never changes a past meal.
- Pasted recipes (PR #157): an unmatched line becomes a zero-nutrition custom ingredient, the row shows
  "Pick a food for …", and the recipe shows "Totals are low" (`RecipeNutritionGaps`).

## The core idea: every saved recipe has a "recipe food"

A recipe used as an ingredient is represented to everything that totals nutrition as an ordinary
`FoodItem`: the **recipe food**.

- `id` = the recipe's own `id` (recipe ids and food ids are both random UUIDs in separate stores, so
  they cannot collide in practice). A line `foodItemId == someRecipe.id` **is** a recipe line. No new
  field on `RecipeIngredient` is needed, so nothing an older device strips can break the link (§10).
- `source` = a new `FoodItemSource.recipe` token (decoded tolerantly; older builds park unknown source
  tokens through `EnumDecodeCompat`).
- `name` = the recipe's name. `servingSize 1`, `servingUnit "serving"`, macros and micronutrients = the
  recipe's whole-batch totals ÷ its servings.
- `portions` carry the optional **Makes** amount (§2): one "batch", and grams or a volume when known.
- It is never shown in "My foods" and never offered by the meal composer's food search (§11).

Because a parent's line points at a plain food, **`MealBuilder`, `RecipeScaling`, grocery aggregation,
the share codec and every older build total a nested recipe correctly with no change.** The nesting
only matters to three new readers: the editor's picker, the steps view / cooking mode, and the
"recipe food" refresher.

**Alternative considered (B):** a new optional `recipeId` on `RecipeIngredient` that totals live by
walking the child. Rejected: an older paired device decodes the line, strips `recipeId` on re-encode,
and the line is left pointing at nothing (`foodItemId` must be some id), so the whole parent totals 0
on every device. (C) copy the child's rows into the parent ("add a part from a saved recipe", the
2026-09-24 follow-up) gives reuse at authoring time only: no live updates and no shared steps, which
is the opposite of what the owner asked.

## 1. How a line references a recipe

`RecipeIngredient(foodItemId: child.id, quantity:, unit:)`, exactly like a food. The app knows it is a
recipe line by looking the id up in the saved recipes (an index built once per recipe-list change).
If the child recipe is gone, the line is still a valid food line (§6).

## 2. Amounts: servings, a batch, or grams / cups

- **Lines are always stored in servings of the child** ("1.5 servings of Dragonfruit sauce"). The recipe
  food declares the whole batch as its serving, counted in servings (`servingSize` = the child's
  servings, unit "serving"), so N servings is exactly N ÷ servings of the batch on every build, and
  "all N servings" totals exactly what the child's own rows did. (Build refinement 2026-11-15: an
  earlier draft stored grams/cups lines; storing servings keeps old builds exact and keeps a later
  change to the "Makes" amount from moving another recipe's numbers.)
- **Batch**: "½ batch" is entered as a unit choice and saved as servings (½ × child servings).
- **Grams or a volume** are entry and display only, when the child has a **Makes** amount (a new
  optional `RecipeDefinition` field, e.g. "2 cups" or "480 g"): "1 cup" of a sauce that makes 2 cups
  in 4 servings saves as 2 servings and reads "1 cup (2 servings)". The editor asks "How much does it
  make? (optional)" under Servings.

## 3. Nutrition rollup: live in recipes, frozen in meals

- **Recipes are live.** Saving a recipe refreshes its recipe food, then the recipe foods of every
  recipe that uses it, nearest first (bounded, §4). Parent totals change on the next read with no
  other work, since they read the food.
- **Meals are frozen**, as today: a meal logged yesterday keeps yesterday's numbers.
- Gaps (PR from branch claude/paste-sim-fixes, b0d85a02): `RecipeNutritionGaps.linesWithoutNutrition`
  counts a recipe's own lines whose food is a `.manual` "custom ingredient"/"recipe ingredient" with no
  macros, and `WebImportEstimateNote.linesWithoutNutrition` shows "Totals are low: no nutrition yet for
  N ingredient(s)." A line bound to a recipe food (`source .recipe`) is never counted, so binding an
  unmatched line to a new recipe clears its count with no change there; `rowsWithoutNutrition` already
  skips a row with a `selectedFoodItemId`.
- A child with its own gaps passes them up: the parent's count adds each child's
  `linesWithoutNutrition` through the same bounded work list as §4 (depth ≤ 3), and the note names the
  child ("Dragonfruit sauce has 1 ingredient with no nutrition yet").

## 4. Cycles and depth (Power of 10)

- **Depth cap 3**: a recipe may use a recipe that uses a recipe, no deeper (`RecipeNestingLimits.maxDepth`).
  A layered cake (cake → frosting → caramel) fits.
- **No cycles at save.** The picker hides any recipe that already uses the one being edited, directly
  or through another, and any recipe whose depth would push the chain past the cap. The save path
  re-checks (a sync can race the picker) and refuses with a plain line.
- **No recursion anywhere.** Totals never walk the tree (they read recipe foods). The refresher and
  the steps reader use an explicit work list with a visited set, bounded by `maxDepth ×
  SharedRecipeLimits.maxIngredients` items, and stop at the bound. A cycle that arrives anyway (two
  devices editing at once) is broken where found: the looping line counts its recipe food as frozen
  and its steps are not pulled in.

## 5. Steps in the parent and in cooking mode

- Child steps are **read live, never copied** into the parent.
- The recipe view lists them first, one titled section per child, in ingredient order, deepest child
  first, then the parent's own steps under the parent's name ("Dragonfruit sauce", then "Pasta").
  This is how multipart parts read today, so it looks familiar.
- A child section notes the amount: "Makes ½ batch for this recipe". Step text is never rewritten.
- **Cooking mode** walks the same sections. Each child section starts with **Already made? Skip** so a
  sauce made yesterday is not cooked twice.
- Older builds show only the parent's own steps (they cannot read the child's). See §10.

## 6. Edit, rename, delete a used recipe

- **Edit**: parents update live. Saving shows "Used in Pasta and 2 more. They'll use the new version."
- **Rename**: the parent's line shows the new name (it reads the recipe food).
- **Delete**: the confirmation names the recipes that use it. Pick (owner):
  - **(a, recommended)** Delete it; each parent keeps it as a **fixed ingredient** with its last
    nutrition (the recipe food stays, source flips to a frozen "was a recipe" food) and **its steps are
    copied into each parent** as a titled section, so no parent loses instructions.
  - (b) Delete it; parents keep the fixed nutrition only, steps are lost.
  - (c) Refuse to delete while it is used.

## 7. Migrating today's multipart recipes

Each multipart recipe becomes one recipe per part, once, on first launch of the new build:

- Every part **except the last** becomes its own saved recipe: name = part name, its ingredient and
  step rows, servings = the parent's servings. The **last part** (the assembly: "Salad") stays in the
  original recipe, which keeps its id, name, photo and history.
- The original gets one line per extracted part: "N servings of Lemon dressing" with N = its servings,
  i.e. the whole batch. **Nutrition is identical to the gram** (a test proves it per recipe).
- New ids are derived from (parent id, part id), so two devices migrating the same recipe make the
  same children and sync merges them instead of doubling.
- `components` stays decodable forever (shares from older peers carry it); an incoming multipart share
  is split the same way on import. The editor stops offering "Split into parts" and offers **Add a
  recipe as an ingredient** and **New recipe for a part** instead.
- Pick (owner): migrate silently with one "Your recipe parts are now their own recipes" note
  (recommended), or ask per recipe.

## 8. Logging a meal from a nested recipe

The meal's components are the parent's lines, as today, so a sub-recipe is **one component named
after it** ("Dragonfruit sauce, ¼ serving") with its full macros and micronutrients. Adjust meal can
change its amount like any component. Pick (owner): one component per sub-recipe (recommended,
readable) or flatten to every leaf food (longer list, each editable).

## 9. Sharing a recipe that uses others

- **Send the children too**, inside the same share, up to the depth cap and the existing whole-share
  caps. The receiver imports each child as its own recipe, then the parent bound to them.
- A child the receiver already has (same origin id, unchanged) is reused, not duplicated.
- Older peers: they read the parent only. Each child line arrives as a plain food with its nutrition,
  so totals are right; the child's steps are added to the parent's steps for them under the child's
  name, the same flattening multipart shares already do for older readers.
- Pick (owner): send children (recommended) or send the parent alone with children as fixed foods.

Wire facts this rests on (checked 2026-11-15): a shared ingredient is
`SharedRecipeIngredient{name, quantity, unit, protein, carbs, fat, preciseMacros?}`, with macros inline
and no food id, so a child line already travels as a correct fixed food to any reader. Every format
carries one recipe today (`SharedRecipePayload` v1, `RecipeExchangePacket`); there is no bundle. The
children ride as a new optional `subRecipes` key on v1 (an older peer ignores it, as it ignores
`steps`), each parent line naming its child by index in that list. The hash-covered exchange packet
(.fernletrecipe, Messages, Shortcuts) takes a version bump for it, as it did for multipart (v2).
Micronutrients do not travel on any share today, nested or not.

## 10. Older paired devices and old app versions

- Nothing on `RecipeIngredient` changes, so an older device can never strip the link: the line's
  `foodItemId` is the child's id on every build.
- An older device that edits the child recipe does not refresh parents. The new build re-checks recipe
  foods against their recipes on launch and after each sync (bounded) and refreshes stale ones.
- An older device shows a parent with the child as one food line, correct totals, parent steps only.
- `yield` is additive and tolerant. An older device's re-encode strips it (the documented blob trade);
  the recipe food keeps its portions, so existing lines keep converting; only the editor's "Makes"
  field reads empty until re-entered.
- Recipe foods live in the synced `foodItems` like any custom food, so a paired device that has the
  parent also has the food its line points at. Web/saved recipes (per-row `SavedRecipeRecord`) can be
  children too: their recipe food is built from their imported nutrition.
- Why not a new field: an old build ignores unknown keys but **requires** `foodItemId`; a line without
  one fails the whole `[RecipeDefinition]` decode, and a line pointing at a missing food makes
  `MealBuilder` total the parent as 0 and refuse to log it.
- Migration (§7) runs only on new builds. An older paired device keeps seeing the original recipe,
  now with sub-recipe lines it totals correctly.

## 11. Where recipes appear in ingredient search

- **Recipe editor only.** Matching saved recipes show first, in a short "Your recipes" group (at most
  3) above catalog results, with the recipe book mark. Plus a **From your recipes** button on the
  ingredient row for browsing.
- Recipes that would loop or go too deep are not offered (§4).
- Not in the meal composer's food search (recipes already log from the recipe book), not in My foods.

## 12. The paste button flow

On a pasted row nothing matched ("Pick a food for “1 cup dragonfruit sauce”."):

1. A **Make a recipe for it** button hangs off that note, which now sits above the unmatched row
   (`RecipeIngredientRows`, `PastedRecipeSeed.RowNote.isUnmatched`, b0d85a02). Rows the reader marks
   "Check" (including a match whose name adds a variety word, `nameAddsOnlyPreparation`) get no button.
2. It opens a new recipe editor over the pasted one (the pasted draft stays unsaved underneath).
   Name = the line without its amount ("Dragonfruit sauce"), Servings 1, **Makes = the line's amount**
   ("1 cup"), no ingredients yet.
3. **Save** saves the new recipe and binds the row to it with the line's amount, so "1 cup" = the
   whole batch. The row's note clears, and the row no longer counts in "Totals are low" (§3).
4. **Cancel** returns to the pasted recipe with the row unchanged.
5. If a saved recipe already matches the line's name, the reader binds to it like a food and shows
   "Check this match", so the button is not needed.

Pick (owner): also offer the button in the ingredient search's empty state ("No food called
‘tahini dressing’. Make a recipe for it") (recommended), or only on pasted rows.

## Owner's picks

Approval page: https://claude.ai/artifact/8qRX5nb61a9s5c1VenkrQk (12 picks, P01–P12, recommended option
marked on each). Answers are recorded below once given.

Answered 2026-11-15 on the approval page. Every pick took the recommended option (a); no notes.

| Pick | Answer |
|---|---|
| P01 How a recipe becomes an ingredient | (a) recipe food with id = recipe id, source `.recipe` (§ core idea) |
| P02 Amounts | (a) servings or part of a batch always; cups/grams once the recipe has a "Makes" amount (§2) |
| P03 Nesting depth | (a) 3 levels; loops always refused (§4) |
| P04 Steps | (a) sub-recipe sections first, live; cooking mode "Already made? Skip" (§5) |
| P05 Editing a used recipe | (a) "Used in Pasta and 2 more. They'll use the new version." on save (§6) |
| P06 Deleting a used recipe | (a) parents keep a fixed ingredient with last nutrition, and its steps are copied in (§6) |
| P07 Existing multipart recipes | (a) convert all once on first launch, one note (§7) |
| P08 Logging | (a) one meal item per sub-recipe with full nutrition (§8) |
| P09 Sharing | (a) send the children too; reuse ones the receiver has (§9) |
| P10 Ingredient search | (a) recipe editor only: "Your recipes" (up to 3) + "From your recipes" (§11) |
| P11 Make a recipe for it | (a) on unmatched pasted lines and in empty ingredient search (§12) |
| P12 New recipe prefill | (a) name from the line, Servings 1, Makes = the line's amount (§12) |

## Build plan (PR-sized, after approval)

1. **Domain: recipe food + nesting rules.** `FoodItemSource.recipe`, `RecipeDefinition.yield`, the
   recipe-food builder, `RecipeNestingLimits`, the bounded cycle/depth checker and refresher. Tests:
   totals identical through a recipe food, cycle/depth refusal, bounds, tolerant decode, old-build
   fixtures.
2. **Store wiring.** Refresh on save/delete/sync, the "used in" index, the stale re-check, delete
   behaviour (§6). Tests in the store suites.
3. **Editor: recipes as ingredients.** "Your recipes" search group, From your recipes, units (serving,
   batch, Makes), the Makes field, "Used in" on save, gap pass-through.
4. **Steps view + cooking mode** sections with Already made? Skip.
5. **Multipart migration** (§7) with per-recipe nutrition-equality tests, import-side split, editor
   loses Split into parts.
6. **Sharing** (§9): children in the share, dedupe on import, older-reader flattening, wire-compat
   tests.
7. **Paste: Make a recipe for it** (§12), plus the search empty state if picked.
8. **Localization** (es, es-MX complete) and accessibility pass, sim look, device check.

Steps 1–2 first; 3, 4 and 6 can run in parallel after 2; 5 after 3; 7 after 3.

Build notes:
- Hotspot files: `NutritionModels.swift`, `FoodView.swift`, `FernletStore.swift`, `Localizable.xcstrings`.
  One writer at a time per file; check running sessions first.
- Step 1 adds `FoodItemSource.recipe`: every `switch` over the source (attribution lines, data-source
  labels, export) needs a case, and "My foods" / the meal composer's search must filter it out.
- Step 5's migration needs a nutrition-equality test per fixture recipe (old multipart vs migrated)
  and an idempotence test (run twice, two devices, same child ids).
- Step 6 needs wire-compat fixtures: a v1 reader without `subRecipes`, and the exchange packet bump.
- Every step: S3 module, no-tracking, Power-of-10 and localization walls green; targeted suites only
  (never the full FernletTests without asking); builds under the heavy-job lock.
