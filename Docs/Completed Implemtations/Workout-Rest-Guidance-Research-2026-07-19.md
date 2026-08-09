> **CLOSED 2026-08-09 — REFERENCE.** The evidence base behind the shipped `FernletKit/Sources/FernletDomainModel/WorkoutRestGuidance.swift`. No implementation work outstanding; archived alongside [PeriodAlgorithimResearch.md](PeriodAlgorithimResearch.md) as standing research. Every value it recommends is a default and stays overridable per exercise.

# Inter-set rest guidance — evidence base (2026-07-19)

Research behind `FernletDomainModel/WorkoutRestGuidance.swift`: how long the guided-workout rest
timer should count down between sets, by training goal and exercise type. Produced by a fan-out
web-research pass (5 angles, 18 sources fetched, 80 claims extracted, 25 adversarially verified — 20
confirmed, 5 refuted). Numbers below are **defaults**; every value is overridable per exercise (the
in-app editor and the future coach app both write per-exercise rest).

## Headline defaults (confirmed, high confidence)

| Goal category | Heavy compound (squat/hinge, main lifts) | Other compound (accessory multi-joint) | Isolation (single-joint) | Core |
| --- | --- | --- | --- | --- |
| **Maximal strength** | 180 s (ACSM ≥2–3 min; 3–5 min optimum for trained) | 120 s | 90 s | 60 s |
| **Power / sport prep** | 180 s (heavy core ≥2–3 min; light-load fast 3–5 min) | 120 s | 90 s | 60 s |
| **Hypertrophy** (wellness / weight-mgmt / exploring) | 120 s (~2 min) | 90 s | 75 s (60–90 s band) | 45 s |
| **Gentle / brisk** (mental health) | 90 s | 75 s | 60 s | 40 s |
| **Recovery** (gentlest) | 75 s | 60 s | 45 s | 30 s |

Clamped to `[20 s, 300 s]`. The last two rows are Fernlet-specific: those goals prescribe light,
higher-rep work, where the endurance-style short rest (ACSM: <1 min for moderate-rep, 1–2 min for
high-rep) keeps a session brisk and unintimidating — matching the app's gentle-care philosophy.

## What the evidence says

- **Maximal strength / heavy compounds** — ACSM 2009 Progression Models position stand: *"rest
  periods of at least 2–3 min ... for core exercises using heavier loads (squat, bench press)"*, and
  *"1–2 min may suffice"* for assistance exercises. de Salles et al. 2009 (Sports Med, PMID 19691365):
  3–5 min between sets produced the greatest absolute-strength gains, most pronounced in **trained**
  lifters (untrained do fine on 60–120 s). Corroborated by a 2025 meta-analysis (longer >60 s rest
  favoured strength, SMD ≈ −0.74).
- **Power** — ACSM: ≥2–3 min for heavy high-intensity core lifts; **3–5 min** for light-load
  fast-velocity power sets; 1–2 min for assistance. (ACSM evidence category D — consensus — so a good
  candidate for user adjustment.)
- **Hypertrophy** — ACSM: 1–2 min (novice/intermediate), up to 2–3 min for heavy advanced core work.
  Singer et al. 2024 Bayesian meta-analysis ("Give it a Rest", Frontiers): a **small** hypertrophy
  benefit to >60 s (volume-load mediated), equivocal beyond ~90 s. The old "short 30–60 s rest for
  hypertrophy (growth-hormone)" idea was **refuted** in verification — never default below 60 s for a
  hypertrophy goal.
- **Muscular endurance** — ACSM: 1–2 min for high-rep (15–20+), <1 min for moderate (10–15); circuits
  rest only the station-transition time.
- **Exercise size** — the compound/large-muscle vs isolation/small-muscle split is explicit in ACSM
  (core 2–3 min vs assistance 1–2 min) — the axis the code keys off via movement pattern + role.

## Important caveat (why rest is *editable*, not fixed)

The newest, highest-tier source — the **2026 ACSM Position Stand** (umbrella review of ~137 systematic
reviews, 30,000+ participants, PMC12965823) — found short (<1 min) vs long (>1 min) between-set rest
**did not significantly affect strength gains**, with **insufficient data** to link rest to
hypertrophy. Reconciliation: longer rest mainly helps by preserving volume-load, so once volume is
equated the effect shrinks. Practical upshot: treat these numbers as helpful defaults, frame long rest
to users as "keeping your reps up," and let people (and the coach app) shorten/lengthen freely.

## Adjustable knobs worth exposing later (per the research)

1. Per-exercise rest (done — editor + coach app).
2. Muscle-group / exercise size (done — the demand tiers).
3. Superset / circuit mode → rest = transition time (open; see open questions).
4. Training experience (trained benefit more from long strength rests).
5. Adaptive / readiness-based shortening (shorten when the user still hits target reps / low RPE).

## Open questions (not encoded)

- Tight numbers for antagonist/agonist supersets & drop sets (literature only gives "transition time"
  for circuits).
- Whether the ~90 s hypertrophy plateau holds specifically for heavy compounds (studies pool mixed
  exercises).
- Sex differences (strongest recent strength/power meta-analyses are trained-males only).
- Whether deadlift warrants a longer default than squat/bench (rarely isolated in studies).

## Primary sources

- ACSM 2009 Progression Models position stand — <https://tourniquets.org/wp-content/uploads/PDFs/ACSM-Progression-models-in-resistance-training-for-healthy-adults-2009.pdf>
- 2026 ACSM Position Stand (overview of reviews) — <https://pmc.ncbi.nlm.nih.gov/articles/PMC12965823/>
- de Salles et al. 2009, Rest Interval between Sets in Strength Training — <https://pubmed.ncbi.nlm.nih.gov/19691365/>
- Singer et al. 2024, "Give it a Rest" (Frontiers, Bayesian meta-analysis on rest & hypertrophy) — <https://www.frontiersin.org/journals/sports-and-active-living/articles/10.3389/fspor.2024.1429789/full>
- 2025 inter-set rest meta-analysis (preprint; trained males) — <https://www.medrxiv.org/content/10.1101/2025.09.22.25336351v2.full>
