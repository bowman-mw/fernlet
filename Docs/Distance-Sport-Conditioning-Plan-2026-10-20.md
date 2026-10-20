# Distance-sport conditioning sessions — plan for the owner's review (2026-10-20)

**Status:** DRAFT. Nothing here is built. The owner asked for this plan first ("Write a plan first",
2026-10-20), after saying that distance sports "should have their own muscle targets, muscle growth, and
overall conditioning/cardio." Section 7 lists the decisions that are the owner's to make before a build
round starts.

**Scope:** the "Sport conditioning" gym session, for a person whose sport in Workout setup is a distance
sport: running (trail running included), cycling, rowing, swimming, hiking or cross-country skiing. These
are the sports in `WorkoutSportActivity.distanceSports` (round 2, R5). Every other sport keeps today's
session.

**Evidence caveat:** a research pass checked each source against PubMed, publisher or repository
records. It could read abstracts only, not full texts, so every number below is at abstract level. Items
it could not verify are marked *unverified* or left out.

---

## 1. What happens today

- **Where the session comes from.** The Sport Prep split (`WorkoutSplitCatalog.sportPrep`) is the only
  split that uses it:

  | Day | Sessions |
  | --- | --- |
  | 1 | Sport conditioning (morning), then Lower (evening) |
  | 2 | Upper |
  | 3 | Sport conditioning (morning), then Push (evening) |
  | 4 | Pull |

- **The session is the same for every sport** (`WorkoutSessions.sportConditioning`):

  | Slot | Pattern | Muscles |
  | --- | --- | --- |
  | "Lower power" (main) | squat | quads, glutes |
  | "Carry / loaded" | carry | forearms, traps |
  | "Core" | — | abs, obliques |

  The activation block adds a single-leg stance. Trained lifters on a day that isn't light also get
  squat jumps 2 × 4.
- **Sets and reps.** The Sports prep goal gives main lifts 4 × 5, accessories 3 × 8–12, and holds of
  40 s (`WorkoutGoalStyle.style(for:energy:sport:)`).
- **Conditioning.** The session ends with "\<Sport\> drills / conditioning – 15 min". "drill" and "/"
  are untimed words (`WorkoutTimedSessions.untimedWords`), so the runner never counts this line down.
  It shows as a step to mark done.
- **Apple Health.** A distance sport's session logs as Other (owner's pick, R5): it is gym work, not a
  run without a distance.

## 2. What the evidence says

### 2.1 Strength training helps endurance athletes

| Finding | Source |
| --- | --- |
| A strength block improves middle- and long-distance performance moderately (SMD 0.52, 28 studies: running, cycling, XC skiing, swimming), mainly through economy, maximal force and power. Maximal-force training beat other intensities, at every level. | [1] |
| Running economy improves by 2–8% | [4] |
| In trained endurance athletes, time trials, economy and speed or power at VO₂max improve | [2] |
| Heavy or explosive work improves running economy; heavy work is recommended for cycling | [3] |
| XC skiing: maximal strength training improves performance, double-poling economy and strength, but not VO₂peak | [24] |
| Rowing: small effects on leg strength (SMD 0.42) and rowing performance (SMD 0.32) at every level, recreational included | [18] |
| Swimming: dryland strength training beats swimming alone by about 2–2.5%, with no one method clearly best | [20] |

### 2.2 What kind of strength work

**Running.**

- Heavy-load training improves time-trial and time-to-exhaustion results, and combining methods may
  add more [5].
- Heavy-load training, plyometrics and combined methods all improve economy. Plyometrics may help more
  at ≤12 km/h, which is typical recreational pace. Heavy loads help more at high speed and in runners
  with a high VO₂max. Submaximal-load and isometric programs did less [6].
- Very heavy loads (>90 % 1RM or <4RM) improved economy most reliably, and longer programs did more [7].
- Explosive training improved economy by about 4.8 % and heavy training by about 3.7 % [8].
- A half squat at 4 × 4RM, 3×/week for 8 weeks, improved economy by 5 % and time to exhaustion by
  21 % [10].

**Cycling.** Four lower-body exercises at 3 × 4–10RM, 2×/week for 12 weeks:

- raised thigh muscle cross-section, power at 2 mmol lactate and 40-minute time-trial power [13];
- did the same for female cyclists, with better economy and fractional VO₂max use [15].

**XC skiing.**

- Heavy pull-downs, half squats and double-poling cable pulls are the trained movements [22, 23].
- Pull-down 1RM rose 19 % in 12 weeks [23].

**Swimming.**

- Low-volume, high-velocity or high-force programs transfer best [19].
- Dryland plyometrics had the highest mean gain (3.6 %) [20].

### 2.3 Which muscles matter

These are the targets the sessions in section 3 are built from.

- **Running.**
  - The quads dominate braking and support early in stance; soleus and gastrocnemius dominate late
    stance; the arms add under 1 % [27].
  - The calves carry most vertical support up to about 7 m/s. At sprint speeds the hip muscles take
    over: iliopsoas, glutes and hamstrings [28].
  - Hip-abductor weakness may be linked to IT-band syndrome, but not established for other running
    injuries [29].
- **Cycling.** The effective protocols trained the quads, glutes, hip flexors and calves, and the gains
  were credited to bigger quads [13, 15].
- **Rowing.** Leg press and prone bench pull are the reliable strength tests tied to performance [17].
- **Swimming.** Dryland rotator-cuff (external and internal rotation) work improved rotator strength and
  endurance; low-quality evidence [21].
- **XC skiing.** Double poling uses the upper and lower body together; better skiers show faster elbow
  and hip flexion and higher pole force [25, 26]. The triceps grew with heavy training [23].
- **Hiking and downhill trail.** A short bout of easy downhill walking a week before a long descent cut
  strength loss and soreness by 47–64 % [33]. The gym version (eccentric quad work, balance) is
  inference, anchored only by ACSM's general neuromotor advice [39].
- **Gaps (coaching consensus, not verified):**
  - single-leg and foot/ankle work for runners;
  - the hip hinge for rowers;
  - the lats and core for swimmers.

### 2.4 Muscle growth

The owner asked for muscle growth. For distance athletes the evidence is two-sided.

- **Heavy, low-rep work grows muscle without adding much body mass.**
  - Thigh cross-section rose with no change in body mass [13].
  - Body weight was unchanged after heavy half squats [10].
  - Body composition did not change over 40 weeks in distance runners, in a non-randomized trial [12].
  - In elite skiers the quads barely changed while the triceps grew [23].
- **Some growth helps where body weight is carried for you.** In female cyclists, more lower-body lean
  mass went with more power per kilogram of it [16].
- **Concurrent endurance training does not stop growth or maximal strength** [36]. So high-volume
  "hypertrophy" work would likely add mass in runners, hikers and skiers, who carry it.
- **Strength work prevents injury.** It is the most protective exercise intervention studied (6 RCTs,
  7,738 people, relative risk 0.338), and it works dose-dependently [31, 30]. One caveat: a 10-minute,
  3×/week program did not reduce injuries in first-time marathoners [32]. A very low dose may not be
  enough.

### 2.5 Dose and timing

- **Frequency.** 2–3 sessions a week for 8–12 weeks [9, 13, 23]. One session a week maintained size
  and strength in-season, though the groups were small [14].
- **Intensity.** Heavy loads, 4–10RM [13, 1, 7].
- **General guidelines.** Muscle-strengthening work on two or more days a week (WHO [40]; ACSM [39]).
  ACSM's specific sets, reps and rest are *unverified* here.
- **Order and spacing.**
  - Interference grows with how often and how long the endurance training runs [34].
  - Lifting before endurance in the same session gave more lower-body strength (+3.96 kg 1RM) with no
    VO₂max cost [35].
  - Same-session concurrent work blunts explosive strength (ES −0.28) [36].
  - At least 6 hours between the two protected strength gains, in amateur rugby players [37].
- **No verified source for rest between sets or RIR.** The plan keeps the planner's existing rest
  table (`WorkoutRestGuidance`).

### 2.6 Conditioning in the gym session

- Adding HIIT to strength training kept muscle growth and upper-body strength but cut lower-body
  strength gains (ES −0.25). Cycling HIIT cut them more than running HIIT [38].
- No verified trial adds HIIT to strength days in endurance athletes specifically.
- **Reading:** these people already train their sport, often a lot. The evidence favors spending the
  session's "conditioning" on explosive and plyometric work for runners [6, 11] and swimmers [20], over
  more aerobic volume. Short intervals, if kept, go after the lifting [35].

## 3. Proposed sessions

Each session keeps the title "Sport conditioning", the frozen English the rotation, the guided
reconciliation and the log match by. Only its slots change, chosen when the first sport named in
Workout setup is a distance sport (`WorkoutSportActivity.sport(named:region:)`). Every exercise named
is in today's catalog (`App/Fernlet/WorkoutExercises.json`). The planner picks within each slot by
location, gear, injury limits and level, as it does now.

### Running and trail running

| Slot | Role | Pattern | Muscles | Catalog picks | Why |
| --- | --- | --- | --- | --- | --- |
| Single-leg strength | main | lunge | quads, glutes | Bulgarian split squat, step-up, reverse lunge | quads in stance [27] (single-leg emphasis is consensus) |
| Hinge | main | hinge | hamstrings, glutes | Romanian deadlift, dumbbell Romanian deadlift, single-leg glute bridge | hip extension at speed [28] |
| Calves | accessory | isolation | calves | seated calf raise, standing calf raise, calf raise | soleus and gastrocnemius carry support [27, 28] |
| Hip abductors | accessory | isolation | abductors | lateral band walk, clamshell | possible IT-band link [29] |
| Core | core | twist | obliques, abs | Pallof press, side plank | — |

Activation: single-leg stance, plus low-rep jumps (squat jump, lateral bound). Plyometrics suit
recreational pace [6].

### Hiking

Running's session, with one change: the main lift is a **step-up** (quads, glutes) instead of the
split squat, and the carry stays, standing in for a loaded pack.

- **Why:** downhill eccentric loading [33] and neuromotor work [39], both inference for the gym.
- **Open question:** a slow lowering phase on the step-up. The runner has no tempo cue today, so this
  would be a note on the step.

### Cycling

| Slot | Role | Pattern | Muscles | Catalog picks |
| --- | --- | --- | --- | --- |
| Squat | main | squat | quads, glutes | back squat, leg press, goblet squat |
| Hinge | main | hinge | hamstrings, glutes | Romanian deadlift, dumbbell Romanian deadlift |
| Single-leg | accessory | lunge | quads, glutes | Bulgarian split squat, step-up |
| Calves | accessory | isolation | calves | standing calf raise, seated calf raise |
| Core | core | — | abs, obliques | plank, dead bug, side plank |

Basis: the Rønnestad and Vikmoen protocols — squat-type and single-leg work, calves [13, 15]. Muscle
growth is most clearly useful here [16], so cycling is where higher accessory reps fit best (section 4).

### Rowing

| Slot | Role | Pattern | Muscles | Catalog picks |
| --- | --- | --- | --- | --- |
| Leg drive | main | squat | quads, glutes | leg press, front squat, back squat |
| Hinge | main | hinge | hamstrings, glutes | deadlift, Romanian deadlift |
| Horizontal pull | accessory | pull | upper back, lats | barbell row, cable row, dumbbell row |
| Vertical pull | accessory | pull | lats | lat pulldown, pull-up |
| Core | core | — | abs | plank, hollow hold, dead bug |

Basis: leg press and prone bench pull are the strength tests linked to performance [17], and effects
hold for recreational rowers [18]. The hinge emphasis is consensus, not verified.

### Swimming

| Slot | Role | Pattern | Muscles | Catalog picks |
| --- | --- | --- | --- | --- |
| Vertical pull | main | pull | lats | pull-up, lat pulldown, band lat pulldown |
| Shoulder health | accessory | pull | rear delts, upper back | face pull, rear delt fly, band pull-apart |
| Press | accessory | push | chest, triceps | dumbbell bench press, push-up |
| Legs | accessory | squat | quads, glutes | goblet squat, leg press |
| Core | core | — | abs | hollow hold, dead bug, plank |

Activation: squat jumps or box jumps for starts and turns; dryland plyometrics had the highest mean
gain [20]. Rotator-cuff external rotation has the best shoulder evidence [21], but it is not in the
catalog; see section 6.

### Cross-country skiing

| Slot | Role | Pattern | Muscles | Catalog picks |
| --- | --- | --- | --- | --- |
| Poling pull | main | pull | lats | lat pulldown, pull-up |
| Leg strength | main | lunge | quads, glutes | Bulgarian split squat, step-up |
| Poling press | accessory | isolation | triceps | triceps pushdown, dip |
| Hinge | accessory | hinge | hamstrings, glutes | Romanian deadlift |
| Core | core | — | abs, obliques | hollow hold, Pallof press |

Activation: lateral bound, for the skating technique.

Basis: pull-down and half squat [23], double-poling cable pulls [22], and upper and lower body together
[25]. The planner has no cable "double-poling pull"; the pulldown stands in.

## 4. Sets and reps — muscle growth versus mass

Recommended starting point for owner decision 7.1: **heavy main lifts, moderate accessories.**

| Part | Prescription | Why |
| --- | --- | --- |
| Main lifts | 3–4 × 4–6, heavy | the economy and strength evidence [1, 7, 10, 13] |
| Accessories | 2–3 × 8–12 | tissue capacity and some growth without a big jump in mass [13, 23] |
| Calves and hip abductors | 2–3 × 12–15 | — |
| Core | timed holds, as today | — |

The planner's existing pieces cover the rest:

- the load engine's suggested weights;
- the warm-up sets on a heavy first barbell or dumbbell lift (R1);
- the light-day trims and the time budget.

Alternatives for the owner:

- **All growth:** 3 × 8–12 everywhere. More muscle and less economy carry-over; more mass for runners
  and hikers.
- **All strength:** 3–4 × 4–6 everywhere, the Rønnestad and Støren shape. Least growth.

A distance-sport style would be a variant of the Sports prep goal's `WorkoutGoalStyle`, chosen by the
same distance-sport check.

## 5. Conditioning and cardio block

Today's untimed "\<Sport\> drills / conditioning – 15 min" goes. The proposal has two parts.

**1. Explosive work in the activation block (every distance sport, on days that aren't light).**

- Low-rep jumps (2–3 × 4–6) that the activation block already knows how to place: squat jump, box
  jump, lateral bound.
- This is the "conditioning" the evidence supports for runners and swimmers [6, 11, 20].
- Beginners keep their low-impact first block, as today (`WorkoutSessionBlocks.balanceAndJumps`).

**2. An optional short interval finisher after the lifting**, for the owner's "overall
conditioning/cardio".

- The descriptor already exists and the runner already times it: "Conditioning intervals – 12 min",
  read as 6 rounds of 1 min hard and 1 min easy (`WorkoutTimedSessions.classify`).
- After the lifting, per [35]; off on light days.
- It would carry a note to keep the person's own sport about 6 hours away from this session [37].
- Interval HIIT costs some lower-body strength gain, cycling more than running [38]. For that reason,
  cyclists get the finisher on a rower or elliptical rather than the bike.

## 6. Building it — what a build round would touch

- **Domain** (FernletDomainModel; no app or HealthKit change):
  - A `WorkoutDistanceSessions` file holding one `WorkoutSessionTemplate` per distance sport (the
    tables in section 3).
  - `WorkoutProgram.dayPlan` swaps `WorkoutSessions.sportConditioning` for the matching one when
    `WorkoutSportActivity.sport(named: profile.sport, region: nil)` is in `distanceSports`. No region is
    needed: distance sports don't depend on it.
  - The distance style from section 4, and the conditioning line from section 5.
- **Frozen names.**
  - The session keeps the title "Sport conditioning".
  - Each new slot label ("Single-leg strength", "Hinge", "Calves", "Hip abductors", "Leg drive",
    "Poling pull", …) is frozen English with a display mapping and a catalog key in
    `WorkoutPlannerNames+Slots.swift`. That's about 12 strings.
- **Catalog gaps** (optional; each needs a JSON row and how-to text — 3–5 cues, a common mistake, an
  easier version — in `ExerciseHowTo+*.swift`):

  | Exercise | Who it's for |
  | --- | --- |
  | Single-leg Romanian deadlift | runners, hikers |
  | Single-leg calf raise | runners |
  | Tibialis raise | runners, hikers |
  | Copenhagen plank | adductors; field and skate athletes |
  | Band external rotation | swimmers [21] |
  | Pogo hops | runners: low-amplitude plyometrics |

- **Split frequency.** Sport Prep puts two sport conditioning sessions a week against four more lifting
  sessions. For an endurance athlete who also trains their sport, that is more lifting than the 2–3
  sessions a week the evidence uses [9, 13], and Day 1 trains legs twice. See decision 7.3.
- **Unchanged:** the 48-hour guard, injury limits, location gear, the time budget, warm-up sets, the
  runner and Live Activity. All of them already work on slots. Apple Health logs these sessions as
  Other.
- **Tests.**
  - Each distance sport's session fills its slots at a full gym and at home.
  - An injury limit swaps a pick.
  - The budget trims it in order.
  - The finisher is timed by the runner and off on light days.
  - Non-distance sports keep today's session.
  - The rotation still matches "Sport conditioning".
- **Lanes:** this is planner work in `WorkoutProgram.swift`. The round 2 plans lane
  (`claude/r2-plans`) doesn't touch that file today, but it should be told before a build starts.

## 7. Decisions for the owner

1. **Reps** (section 4): heavy mains + moderate accessories (recommended), all growth, or all strength?
2. **Conditioning** (section 5): jumps in the activation block, plus the optional 12-minute interval
   finisher? Or jumps only, or the finisher only?
3. **Frequency:** keep the Sport Prep split as it is for distance athletes, or a distance variant? One
   option: two sport conditioning sessions plus one upper session a week, with the sport itself on the
   other days.
4. **Catalog:** add the six missing exercises (section 6), or build with today's catalog first?
5. **Hiking:** its own session (section 3), or the running session?
6. **Triathlon:** today it reads as a sport Fernlet doesn't model. Should it get a combined session —
   running's lower body, swimming's pull and shoulder work, and cycling's single-leg work?

---

## References

All verified at abstract level against PubMed, publisher or repository records.

1. Berryman N, Mujika I, Arvisais D, Roubeix M, Binet C, Bosquet L. Strength training for middle- and long-distance performance: a meta-analysis. *Int J Sports Physiol Perform.* 2018;13(1):57–63. doi:10.1123/ijspp.2017-0032
2. Beattie K, Kenny IC, Lyons M, Carson BP. The effect of strength training on performance in endurance athletes. *Sports Med.* 2014;44(6):845–865. doi:10.1007/s40279-014-0157-y
3. Rønnestad BR, Mujika I. Optimizing strength training for running and cycling endurance performance: a review. *Scand J Med Sci Sports.* 2014;24(4):603–612. doi:10.1111/sms.12104
4. Blagrove RC, Howatson G, Hayes PR. Effects of strength training on the physiological determinants of middle- and long-distance running performance: a systematic review. *Sports Med.* 2018;48(5):1117–1149. doi:10.1007/s40279-017-0835-7
5. Llanos-Lagos C, Ramirez-Campillo R, Moran J, Sáez de Villarreal E. The effect of strength training methods on middle-distance and long-distance runners' athletic performance: a systematic review with meta-analysis. *Sports Med.* 2024;54(7):1801–1833. doi:10.1007/s40279-024-02018-z
6. Llanos-Lagos C, Ramirez-Campillo R, Moran J, Sáez de Villarreal E. Effect of strength training programs in middle- and long-distance runners' economy at different running speeds: a systematic review with meta-analysis. *Sports Med.* 2024;54(4):895–932. doi:10.1007/s40279-023-01978-y
7. Eihara Y, Takao K, Sugiyama T, Maeo S, Terada M, Kanehisa H, Isaka T. Heavy resistance training versus plyometric training for improving running economy and running time trial performance: a systematic review and meta-analysis. *Sports Med Open.* 2022;8:138. doi:10.1186/s40798-022-00511-1
8. Denadai BS, de Aguiar RA, de Lima LCR, Greco CC, Caputo F. Explosive training and heavy weight training are effective for improving running economy in endurance athletes: a systematic review and meta-analysis. *Sports Med.* 2017;47(3):545–554.
9. Balsalobre-Fernández C, Santos-Concejero J, Grivas GV. Effects of strength training on running economy in highly trained runners: a systematic review with meta-analysis of controlled trials. *J Strength Cond Res.* 2016;30(8):2361–2368. doi:10.1519/JSC.0000000000001316
10. Støren Ø, Helgerud J, Støa EM, Hoff J. Maximal strength training improves running economy in distance runners. *Med Sci Sports Exerc.* 2008;40(6):1087–1092. doi:10.1249/MSS.0b013e318168da2f
11. Paavolainen L, Häkkinen K, Hämäläinen I, Nummela A, Rusko H. Explosive-strength training improves 5-km running time by improving running economy and muscle power. *J Appl Physiol.* 1999;86(5):1527–1533. doi:10.1152/jappl.1999.86.5.1527
12. Beattie K, Carson BP, Lyons M, Rossiter A, Kenny IC. The effect of strength training on performance indicators in distance runners. *J Strength Cond Res.* 2017;31(1):9–23. doi:10.1519/JSC.0000000000001464
13. Rønnestad BR, Hansen EA, Raastad T. Effect of heavy strength training on thigh muscle cross-sectional area, performance determinants, and performance in well-trained cyclists. *Eur J Appl Physiol.* 2010;108(5):965–975. doi:10.1007/s00421-009-1307-z
14. Rønnestad BR, Hansen EA, Raastad T. In-season strength maintenance training increases well-trained cyclists' performance. *Eur J Appl Physiol.* 2010;110(6):1269–1282. doi:10.1007/s00421-010-1622-4
15. Vikmoen O, et al. Strength training improves cycling performance, fractional utilization of VO2max and cycling economy in female cyclists. *Scand J Med Sci Sports.* 2016;26(4):384–396. doi:10.1111/sms.12468
16. Mujika I, Rønnestad BR, Martin DT. Effects of increased muscle strength and muscle mass on endurance-cycling performance. *Int J Sports Physiol Perform.* 2016;11(3):283–289. doi:10.1123/IJSPP.2015-0405
17. Lawton TW, Cronin JB, McGuigan MR. Strength testing and training of rowers: a review. *Sports Med.* 2011;41(5):413–432. doi:10.2165/11588540-000000000-00000
18. Thiele D, Prieske O, Chaabene H, Granacher U. Effects of strength training on physical fitness and sport-specific performance in recreational, sub-elite, and elite rowers: a systematic review with meta-analysis. *J Sports Sci.* 2020. (Volume, pages and DOI unverified.)
19. Crowley E, Harrison AJ, Lyons M. The impact of resistance training on swimming performance: a systematic review. *Sports Med.* 2017;47(11):2285–2307. doi:10.1007/s40279-017-0730-2
20. Fone L, van den Tillaar R. Effect of different types of strength training on swimming performance in competitive swimmers: a systematic review. *Sports Med Open.* 2022;8:19. doi:10.1186/s40798-022-00410-5
21. Tavares N, Dias G, Carvalho P, Vilas-Boas JP, Castro MA. Effectiveness of therapeutic exercise in musculoskeletal risk factors related to swimmer's shoulder. *Eur J Investig Health Psychol Educ.* 2022;12(6):601–615. doi:10.3390/ejihpe12060044
22. Hoff J, Gran A, Helgerud J. Maximal strength training improves aerobic endurance performance. *Scand J Med Sci Sports.* 2002;12(5):288–295. doi:10.1034/j.1600-0838.2002.01140.x
23. Losnegard T, et al. The effect of heavy strength training on muscle mass and physical performance in elite cross country skiers. *Scand J Med Sci Sports.* 2011;21(3):389–401.
24. Castañeda-Babarro A, Etayo-Urtasun P, León-Guereño P. Effects of strength training on cross-country skiing performance: a systematic review. *Int J Environ Res Public Health.* 2022;19(11):6522. doi:10.3390/ijerph19116522
25. Holmberg HC, Lindinger S, Stöggl T, Eitzlmair E, Müller E. Biomechanical analysis of double poling in elite cross-country skiers. *Med Sci Sports Exerc.* 2005;37(5):807–818. doi:10.1249/01.MSS.0000162615.47763.C8
26. Sandbakk Ø, Holmberg HC. Physiological capacity and training routines of elite cross-country skiers: approaching the upper limits of human endurance. *Int J Sports Physiol Perform.* 2017;12(8):1003–1011. doi:10.1123/ijspp.2016-0749
27. Hamner SR, Seth A, Delp SL. Muscle contributions to propulsion and support during running. *J Biomech.* 2010;43(14):2709–2716.
28. Dorn TW, Schache AG, Pandy MG. Muscular strategy shift in human running: dependence of running speed on hip and ankle muscle performance. *J Exp Biol.* 2012;215(11):1944–1956. doi:10.1242/jeb.064527
29. Mucha MD, Caldwell W, Schlueter EL, Walters C, Hassen A. Hip abductor strength and lower extremity running related injury in distance runners: a systematic review. *J Sci Med Sport.* 2017;20(4):349–355.
30. Lauersen JB, Bertelsen DM, Andersen LB. The effectiveness of exercise interventions to prevent sports injuries: a systematic review and meta-analysis of randomised controlled trials. *Br J Sports Med.* 2014;48(11):871–877. doi:10.1136/bjsports-2013-092538
31. Lauersen JB, Andersen TE, Andersen LB. Strength training as superior, dose-dependent and safe prevention of acute and overuse sports injuries: a systematic review, qualitative analysis and meta-analysis. *Br J Sports Med.* 2018;52(24):1557–1563. doi:10.1136/bjsports-2018-099078
32. Toresdahl BG, et al. A randomized study of a strength training program to prevent injuries in runners of the New York City Marathon. *Sports Health.* 2020;12(1):74–79. doi:10.1177/1941738119877180
33. Maeo S, Yamamoto M, Kanehisa H, Nosaka K. Prevention of downhill walking-induced muscle damage by non-damaging downhill walking. *PLoS One.* 2017;12(3):e0173909. doi:10.1371/journal.pone.0173909
34. Wilson JM, Marin PJ, Rhea MR, Wilson SMC, Loenneke JP, Anderson JC. Concurrent training: a meta-analysis examining interference of aerobic and resistance exercises. *J Strength Cond Res.* 2012;26(8):2293–2307.
35. Murlasits Z, Kneffel Z, Thalib L. The physiological effects of concurrent strength and endurance training sequence: a systematic review and meta-analysis. *J Sports Sci.* 2018;36(11):1212–1219. doi:10.1080/02640414.2017.1364405
36. Schumann M, Feuerbacher JF, Sünkeler M, Freitag N, Rønnestad BR, Doma K, Lundberg TR. Compatibility of concurrent aerobic and strength training for skeletal muscle size and function: an updated systematic review and meta-analysis. *Sports Med.* 2022;52(3):601–612. doi:10.1007/s40279-021-01587-7
37. Robineau J, Babault N, Piscione J, Lacome M, Bigard AX. Specific training effects of concurrent aerobic and strength exercises depend on recovery duration. *J Strength Cond Res.* 2016;30(3):672–683. doi:10.1519/JSC.0000000000000798
38. Sabag A, et al. The compatibility of concurrent high intensity interval training and resistance training for muscular strength and hypertrophy: a systematic review and meta-analysis. *J Sports Sci.* 2018;36(21):2472–2483. doi:10.1080/02640414.2018.1464636
39. Garber CE, Blissmer B, Deschenes MR, Franklin BA, Lamonte MJ, Lee IM, Nieman DC, Swain DP. American College of Sports Medicine position stand. Quantity and quality of exercise for developing and maintaining cardiorespiratory, musculoskeletal, and neuromotor fitness in apparently healthy adults: guidance for prescribing exercise. *Med Sci Sports Exerc.* 2011;43(7):1334–1359. doi:10.1249/MSS.0b013e318213fefb
40. Bull FC, Al-Ansari SS, Biddle S, et al. World Health Organization 2020 guidelines on physical activity and sedentary behaviour. *Br J Sports Med.* 2020;54(24):1451–1462. doi:10.1136/bjsports-2020-102955
