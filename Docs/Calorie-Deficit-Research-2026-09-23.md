# A gentler starting calorie deficit for Weight Management — research note (2026-09-23)

> **OWNER SIGN-OFF NEEDED on the chosen value.** The code now ships the recommendation below
> (10% below estimated maintenance, with a floor). The constant is
> `NutritionTargetCalculator.weightManagementDeficitFraction` in
> `FernletKit/Sources/FernletDomainModel/NutritionModels.swift`, and the floor is
> `NutritionTargetCalculator.deficitFloorKilocalories(for:)`. Changing the value is a one-line edit.
> The pinning tests are in `Tests/FernletTests/WeightManagementDeficitTests.swift`.

## Why this note exists

The owner, on the 12% deficit: *"12% seem a tad bit agressive, need to research what a good
starting place is".*

Before this change, `NutritionTargetCalculator.adjustedCalories` gave the Weight Management goal
`maintenance × 0.88`. Maintenance is Mifflin–St Jeor RMR × an activity multiplier (1.2 to 1.9).
The result is rounded to 25 kcal, and **there was no floor**. The goal card calls this "A gentle
calorie deficit · higher protein" (`GoalType.nutritionSummary`). That copy appears in onboarding and
in Settings.

**A spec conflict to settle first.** `Docs/FernletSpecificationV3.md` says:

- L349: "Weight management goal does not involve calorie targets or deficits."
- L846: "Food shows macro rings only, no calorie number or deficit goal."
- L1131: "No calorie goals or deficits."

`Docs/ImplementationPlan.md` (L172–173, L400, L406) records the deficit copy as removed. The code
ships both a deficit and deficit copy anyway. This note assumes the owner's comment means "keep a
deficit, make it gentler". Option F below is the spec-faithful alternative (no deficit).

## What the numbers do today

Worked with the app's own formula. Deficits are shown in parentheses. "Floor" means 1,200 kcal
(female) or 1,500 kcal (male), never below estimated RMR, and never above maintenance.

| Profile | Est. RMR | Est. maintenance | Today: 12% | Recommended: 10% + floor | Classic fixed 500 kcal |
|---|---|---|---|---|---|
| App default (M 30y 170 lb 5'8" moderate) | 1,706 | 2,644 | 2,325 (−319) | 2,375 (−269) | 2,150 |
| F 35y 150 lb 5'4" light | 1,360 | 1,871 | 1,650 (−221) | 1,675 (−196) | 1,375 |
| F 60y 130 lb 5'2" sedentary | 1,113 | 1,336 | **1,175** (−161) | 1,200 (−136) | **825** |
| F 65y 125 lb 5'1" sedentary | 1,049 | 1,259 | **1,100** (−159) | 1,200 (−59) | **750** |
| F 75y 110 lb 4'11" sedentary | 900 | 1,079 | **950** (−129) | 1,075 (none) | **575** |
| M 70y 130 lb 5'4" sedentary | 1,261 | 1,513 | **1,325** (−188) | 1,500 (−13) | **1,025** |
| M 45y 250 lb 5'10" sedentary | 2,025 | 2,430 | 2,150 (−280) | 2,175 (−255) | 1,925 |
| M 25y 200 lb 6'0" very active | 1,930 | 3,667 | 3,225 (−442) | 3,300 (−367) | 3,175 |

Bold = below the commonly cited floor for eating less without clinical supervision.

Twelve percent is modest in absolute terms: 130–440 kcal/day, below the classic clinical 500 kcal.
The real problem is that it has no floor. Four of these eight ordinary profiles land under
1,200/1,500 kcal today, all of them small, older or sedentary. A fixed 500 kcal deficit would be
worse, at 575–825 kcal/day for the same people. A fixed-kcal deficit is harshest exactly where
bodies are smallest.

## Evidence

**Authoritative guidance**

- **CDC.** People who lose weight "at a gradual, steady pace—about 1 to 2 pounds a week" are more
  likely to keep it off, and a 5% loss can lower chronic-disease risk. The CDC gives no daily kcal
  deficit.
- **NIH NHLBI Practical Guide (1998/2000).** For *clinical obesity treatment*: a 500–1,000 kcal/day
  deficit, at no less than 1,000–1,200 kcal/day for women and 1,200–1,600 kcal/day for men.
- **AHA/ACC/TOS 2013 (Jensen et al.).** Inside comprehensive, professionally supported lifestyle
  programs: 1,200–1,500 kcal/day for women and 1,500–1,800 for men. Alternatively, a 500 or
  750 kcal/day deficit, or a 30% deficit.
- **NICE NG246 (January 2025).** Recommends an energy deficit but **deliberately dropped** its
  earlier 600 kcal/day figure as "arbitrarily specific". Low- and very-low-energy diets belong in
  specialist services only. The accompanying guidance warns that excessive restriction can lead to
  weight cycling.
- **Dietary Guidelines for Americans (2020–2025; 2025–2030, released January 2026).** Both set calorie
  *needs* by age, sex, size and activity. Neither sets a deficit size.
- **NIDDK Body Weight Planner (Hall).** Replaces the 3,500-kcal-per-pound rule, which overstates
  loss because the body adapts to a deficit over time. The planner is for adults.

**Peer-reviewed work**

- **Hill, Wyatt, Reed & Peters, *Science* 2003.** A ~100 kcal/day change in energy balance could
  prevent weight gain in most adults: "a few less bites at each meal".
- **Hills, Byrne, Lindstrom & Hill, *Obesity Facts* 2013.** A review of "small changes". Small,
  sustainable changes mainly prevent gain, and can produce modest loss.
- **Hall et al., *Lancet* 2011.** Each sustained 100 kJ/day (≈24 kcal/day) change moves eventual
  weight by about 1 kg. Half of the change arrives in about a year, 95% in about three years.
  - For the app default, the recommended 269 kcal/day works out to roughly 0.5 lb/week at first,
    slowing over time. That is about 11 kg over ~3 years if followed exactly.
  - This is gentle, and slower than the CDC's 1–2 lb/week, which is appropriate for a
    self-directed, non-optimizing app.
- **Polidori et al., *Obesity* 2016.** Appetite rises by ~100 kcal/day for every kg lost, more than
  three times the metabolic adaptation. The bigger the deficit, the harder the body pushes back.
- **CALERIE 2 (Kraus et al., *Lancet Diabetes Endocrinol* 2019).** Healthy non-obese adults were
  prescribed 25% restriction with intensive support. They *achieved* 11.9% over two years and lost
  10% of body weight.
  - So a sustained ~12% is a research-grade dose that needed a trial's support to reach.
  - That supports the owner's instinct for a self-directed default.
- **Purcell et al., *Lancet Diabetes Endocrinol* 2014.** Rapid and gradual loss were regained
  equally (~71% at 3 years). The case for "gentle" therefore rests on adherence, nutrient adequacy,
  mood and eating-disorder risk. It does not rest on a regain myth.
- **Frankenfield et al., *JADA* 2005.** Mifflin–St Jeor is the most reliable RMR equation. Even so,
  it misses measured RMR by more than 10% for a sizeable minority, and activity multipliers add more
  error.
  - A 10% "deficit" is inside the estimate's own error bars.
  - That is one more reason to keep the deficit small and the floor firm.

**Safety floors**

- **Harvard Health.** Intake "should not fall below 1,200 a day in women or 1,500 a day in men,
  except under the supervision of a health professional." This matches the lower bounds of the
  AHA/ACC/TOS ranges. The NHLBI's lower 1,000 kcal bound is for supervised treatment.
- **Never below estimated RMR.** A widely used coaching rule. With a 10% deficit and the app's
  lowest multiplier (1.2), the target is at least 1.08 × RMR, so this guard cannot bind today. It is
  kept so that a future multiplier or percentage change cannot slip under it.

**Gentle-approach sources**

- **AAP clinical report (Golden et al., *Pediatrics* 2016).** For adolescents: discourage dieting and
  "weight talk", and focus on habits.
- **Tylka et al., *J Obesity* 2014.** Weight-inclusive care. Weight cycling and weight stigma both
  harm health and wellbeing.
- **Obesity Canada guideline (Wharton et al., *CMAJ* 2020).** Care is judged by health, not body size.

## Options

| Option | What it is | For | Against |
|---|---|---|---|
| **A. Keep 12%, no floor** (status quo) | maintenance × 0.88 | Modest for most adults (130–440 kcal) | Four of eight example profiles fall under the 1,200/1,500 floor; the owner already finds it a tad aggressive |
| **B. 10% + floor (recommended)** | max(maintenance × 0.90, min(maintenance, max(1,200 F / 1,500 M, RMR))) | Scales with body size; a small, sustainable dose (≈130–370 kcal/day); never under the unsupervised floor; never a surplus | The floor removes almost all of the deficit for small, older, sedentary users (by design) |
| C. 8% + floor | as B at 0.92 | Gentler still | Inside the ±10% RMR error for most users, so it is close to maintenance in practice |
| D. Fixed "small change" 100–200 kcal + floor | maintenance − 150 | Maps straight onto the small-changes literature; easy to explain | A fixed kcal amount is proportionally harsher for small bodies; mainly prevents gain rather than producing loss |
| E. Classic fixed 500 kcal | maintenance − 500 | The textbook "1 lb/week" figure | Clinical, supervised dose; lands at 575–825 kcal/day for small older women; wrong for this app |
| F. Maintenance + higher protein (0%) | no deficit | Matches the spec (L349/L846/L1131); zero risk | The goal no longer changes calories, only protein and training; the owner's comment implies a deficit is wanted |

## Recommendation

**Option B.**

- The daily target is 10% below estimated maintenance.
- It never goes below 1,200 kcal (female) or 1,500 kcal (male), and never below estimated RMR.
- It never goes above maintenance. When maintenance is already under the floor, the goal simply
  doesn't cut calories.
- Higher protein is unchanged (1.5 g/kg).

The goal card now reads "A gentle calorie deficit (up to 10%) · higher protein". It says "up to"
because the floor can make the cut smaller. The copy makes no health claim and uses no rate or
weight-loss promise. The percentage in the copy is interpolated from the constant, so it cannot
drift from the math.

## Owner decisions

1. **OWNER SIGN-OFF NEEDED on the chosen value**: 10% plus the 1,200/1,500 kcal and RMR floor, or
   another row from the table above.
2. **The spec conflict.** Either amend §5 L349/L846/L1131 (proposed wording below), or take option F.
3. **Minors.** `UserNutritionProfile.age` accepts 5–120, Mifflin–St Jeor is an adult equation, and
   the AAP advises against dieting for adolescents. Recommendation: no deficit under 18 (maintenance
   plus the goal's protein). **Not implemented.** It is a behaviour change beyond "numbers and
   copy", and it depends on the app's age-gating decisions.
4. **Showing a number on the card.** The card now says "up to 10%". If the owner prefers no number
   at all, drop the parenthetical. The math is unaffected.

Proposed spec wording (§5, replacing L349's first sentence): *"The Weight Management goal applies a
gentle starting deficit — 10% below estimated maintenance, never below 1,200 kcal (female) /
1,500 kcal (male) or the estimated resting metabolic rate, and never above maintenance — plus higher
protein. No weight-loss rate, target weight, or streak is ever shown."* L846 and L1131 would then
need "no calorie number" to read "no calorie number by default" and "No calorie goals or deficits"
to read "No aggressive deficits or calorie goals".

## Sources

- CDC, Steps for Losing Weight (reviewed 2025-01-17): https://www.cdc.gov/healthy-weight-growth/losing-weight/index.html
- NHLBI Practical Guide to the Identification, Evaluation, and Treatment of Overweight and Obesity in Adults: https://www.nhlbi.nih.gov/files/docs/guidelines/prctgd_c.pdf
- Jensen MD et al., 2013 AHA/ACC/TOS Guideline for the Management of Overweight and Obesity in Adults, *Circulation* 2014: https://www.ahajournals.org/doi/10.1161/01.cir.0000437739.71477.ee
- NICE NG246, Overweight and obesity management (2025), Physical activity and diet: https://www.nice.org.uk/guidance/ng246/chapter/Physical-activity-and-diet ; evidence review on diets: https://www.ncbi.nlm.nih.gov/books/NBK612514/ ; summary of changes: https://diabetesonthenet.com/diabetes-primary-care/factsheet-nice-obesity-whats-new/
- Dietary Guidelines for Americans 2020–2025: https://www.dietaryguidelines.gov/sites/default/files/2021-03/Dietary_Guidelines_for_Americans-2020-2025.pdf ; 2025–2030: https://odphp.health.gov/our-work/nutrition-physical-activity/dietary-guidelines/current-dietary-guidelines
- NIDDK, NIH Body Weight Planner: https://www.niddk.nih.gov/health-information/professionals/diabetes-discoveries-practice/nih-body-weight-planner
- Hill JO, Wyatt HR, Reed GW, Peters JC. Obesity and the environment: where do we go from here? *Science* 2003;299:853: https://www.science.org/doi/10.1126/science.1079857
- Hills AP, Byrne NM, Lindstrom R, Hill JO. 'Small changes' to diet and physical activity behaviors for weight management. *Obes Facts* 2013;6:228: https://karger.com/ofa/article/6/3/228/239886/Small-Changes-to-Diet-and-Physical-Activity
- Hall KD et al. Quantification of the effect of energy imbalance on bodyweight. *Lancet* 2011;378:826: https://pubmed.ncbi.nlm.nih.gov/21872751/
- Polidori D et al. How strongly does appetite counter weight loss? *Obesity* 2016;24:2289: https://pubmed.ncbi.nlm.nih.gov/27804272/
- Kraus WE et al. 2 years of calorie restriction and cardiometabolic risk (CALERIE). *Lancet Diabetes Endocrinol* 2019;7:673: https://pubmed.ncbi.nlm.nih.gov/31303390/
- Purcell K et al. The effect of rate of weight loss on long-term weight management. *Lancet Diabetes Endocrinol* 2014;2:954: https://www.thelancet.com/journals/landia/article/PIIS2213-8587(14)70200-1/abstract
- Frankenfield D et al. Comparison of predictive equations for resting metabolic rate. *J Am Diet Assoc* 2005;105:775: https://www.jandonline.org/article/S0002-8223(05)00149-5/abstract
- Harvard Health, Calorie counting made easy: https://www.health.harvard.edu/healthy-aging-and-longevity/calorie-counting-made-easy
- Golden NH et al. Preventing Obesity and Eating Disorders in Adolescents. *Pediatrics* 2016;138:e20161649: https://publications.aap.org/pediatrics/article/138/3/e20161649/52684/Preventing-Obesity-and-Eating-Disorders-in
- Tylka TL et al. The Weight-Inclusive versus Weight-Normative Approach to Health. *J Obes* 2014:983495: https://onlinelibrary.wiley.com/doi/10.1155/2014/983495
- Wharton S et al. Obesity in adults: a clinical practice guideline. *CMAJ* 2020;192:E875: https://www.cmaj.ca/content/192/31/E875

Several primary pages (PMC, NCBI Bookshelf, NICE, AHA) refuse automated fetching. Their figures
above come from the guideline text as quoted in search results and secondary summaries, and
should be spot-checked against the originals before any of them is quoted in user-facing copy.
None is quoted there today.
