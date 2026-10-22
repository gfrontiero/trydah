# Fitbod teardown

A clean-room reverse engineering of the Fitbod strength-training app: what it does, how its
workout engine works, the data model it implies, and a runnable reference engine
(`lib/fitbod_clone`) that reproduces the behaviour.

## Method and ground rules

- **Sources:** only public material. That means Fitbod's granted patents and published
  applications, its help center, its blog, app-store listings, and third-party reviews.
- **Black-box calibration:** a real user's Fitbod data export (about 7.5 years, roughly 1,400
  sessions and 35,000 working sets) is used to measure what the app actually prescribed and to
  backtest the engine. See [section 7](#7-calibration-against-a-real-fitbod-export). The export
  itself is personal data and is not in this repo.
- **No binary or traffic analysis.** The APK/IPA was not decompiled and the API was not
  intercepted. Fitbod's Terms of Use forbid both, and the patents describe the engine in more
  useful detail anyway.
- **Network limits in the build environment.** `fitbod.me`, `help.fitbod.me` and Google
  Patents could not be fetched directly. Every fact below comes from search-engine extracts of
  those pages. Read the primary documents linked in [Sources](#sources) before relying on a
  specific number.
- **Confidence labels** used throughout:
  - **[Stated]**: Fitbod says this in its help center or blog.
  - **[Patent]**: from a Fitbod patent's abstract or claims. A patent shows what Fitbod built
    or planned, not necessarily what ships today.
  - **[Measured]**: fitted to the real export and checked by backtest.
  - **[Inferred]**: our reconstruction, chosen to match the stated behaviour. These are the
    tunable constants that the data could not pin down.

## TL;DR

Fitbod is a **recommendation engine with a workout logger around it**. Every time you open the
Workout tab it builds one session by running three models in sequence:

1. **Muscle recovery model**: a 0-100% recovery value per muscle, from logged
   sets × reps × weight plus imported cardio. Recovery takes at most about 6 days.
2. **Exercise Selector**: an ML ranking of the exercise library, filtered by equipment and
   exclusions and weighted by recovery, goal effectiveness, More/Less feedback and the
   variability setting.
3. **Capability Recommender**: sets, reps and weight for each picked exercise. It works from a
   per-exercise "capability" (an estimated 1RM), computed as a smoothed moving average of the
   strongest daily performance, decayed after a layoff. Exercises with no history borrow from
   related lifts or a population model. Each day the rep target is drawn at random from
   5/6/8/10/12/15, and the weight is read straight off the 1RM curve at that rep count. **[Measured]**

Calibrated this way, the engine predicts the weight Fitbod gave within 5% about half the time
for lifts done in the last 6 weeks, with a median error of 5.9%
([section 7](#7-calibration-against-a-real-fitbod-export)).

Everything else is UI on top of that loop: the logger, rest timers, the Apple Watch app,
strength charts and Strength Score, gym profiles, and integrations.

## 1. Product teardown

### Core loop
```
Onboarding ──► My Plan / Gym Profile ──► Workout tab: today's generated workout
                                              │  (regenerates on any input change)
                                              ▼
                                   Start workout ──► log sets (weight, reps, RIR)
                                              │
                                              ▼
                  history updates recovery, capability, Strength Score ──► next workout
```

### Inputs collected
| Where | Inputs | Confidence |
|---|---|---|
| Onboarding | sex, age, bodyweight, experience level, goal, workouts per week, equipment | [Stated] |
| My Plan | fitness goal, exercise variability, split, workouts/week, muscle focus, training format (warm-ups, supersets, etc.) | [Stated] |
| Gym Profile (multiple per user) | available equipment, workout duration (15 min to 1 h 30, or custom; older docs say 1 min to 4 h) | [Stated] |
| Per exercise | Recommend More / Recommend Less / Don't Recommend Again; Replace; manual add/remove | [Stated] |
| Per set | weight, reps (or time/distance), Reps in Reserve rating | [Stated] |
| Integrations | Apple Health, Health Connect, Fitbit, Strava (cardio counts toward fatigue) | [Stated] |
| Manual | override a muscle's recovery % | [Stated] |

### Settings and their options
- **Goals:** strength (mostly 1-6 reps, about 85-100% 1RM, 3-5 min rest), hypertrophy (mostly
  6-12 reps with some 1-5 and 15-25 work, 60-180 s rest), plus endurance and general fitness
  (higher reps, shorter rest). Weekly volume target is about 10-20 working sets per muscle. **[Stated]**
- **Splits:** Push/Pull/Legs, Upper/Lower, Full Body, and **Fresh Muscle Groups** (trains your
  two most-recovered groups). More splits appear when Focus Exercises are enabled. A split is
  recommended from workouts per week. **[Stated]**
- **Exercise variability:** More Consistent (keeps about 70-80% of exercises week to week),
  Balanced (default), More Variety. **[Stated]**
- **Quick edits:** regenerate today's workout at 15/30/45/60/90 min without touching the
  profile. **[Stated]**
- **Warm-up sets:** optional ramp of lighter, lower-rep sets. Not generated for bodyweight,
  band, accessory, core, assisted, timed or Max Effort exercises, or when the working weight is
  too light to ramp. **[Stated]** In practice this is usually a **single set at 60% × 8** once
  the working weight reaches about 50 lb, on machines, cables and isolation lifts too.
  **[Measured]**

### Exercise feedback numbers
- Recommend More raises an exercise's chance of appearing by **40-60%**. Recommend Less lowers it by
  **20-40%**. Exclude removes it and immediately replaces it if it is in the current, unstarted
  workout. **[Stated]**

### Workout refresh triggers
The workout regenerates when you log a workout, when an Apple Health/Strava/Fitbit sync arrives
(even in the background, overnight), or when you change gym, equipment, duration, goal,
experience, split, focus, workouts/week or a recovery override. Edits made before tapping
**Start** are lost on refresh. Once started, the workout is frozen. **[Stated]** This tells us
the engine is **stateless and cheap**: a pure function of (history, settings, now) that the app
can re-run freely.

### Business
- About $15.99/month or $95.99/year in 2026, with older legacy pricing of $12.99 and $79.99.
  Free access is a short trial or a few free workouts; sources disagree. iOS, Android, Apple Watch.
- Founded 2015 in San Francisco by Allen Chen (CEO, engineering) and Jesse Venticinque
  (product/design). About $5M raised per public databases.
- Claims "1,000+"/"1,600+" exercises with video demos, and "150M+ logged workouts / 2.8B sets"
  of training data. These are marketing figures and have not been independently verified.

## 2. Engine architecture

```
                 ┌─────────────────────┐
 logged sets ───►│ Capability          │── capability per exercise (est. 1RM, max reps, max secs)
 profile     ───►│ Estimator           │        │
                 └─────────────────────┘        │
                                                ▼
 logged sets ───►┌─────────────────────┐   ┌──────────────────┐
 cardio      ───►│ Recovery Model      │──►│ Exercise         │◄── equipment, exclusions,
 overrides   ───►└─────────────────────┘   │ Selector (rank)  │    More/Less, variability, goal
                                           └────────┬─────────┘
                       split ─► target muscles ─────┤ greedy pick until time budget is used,
                                                    │ re-scoring with projected fatigue
                                                    ▼
                                           ┌──────────────────┐
                                           │ Capability       │── sets × reps @ weight, rest,
                                           │ Recommender      │   warm-ups
                                           └──────────────────┘
```

Code map:

| Component | File |
|---|---|
| Exercise library, muscles, equipment | `lib/fitbod_clone/exercise_library.rb` |
| History, profile, plan settings, preferences | `lib/fitbod_clone/history.rb` |
| 1RM math | `lib/fitbod_clone/one_rep_max.rb` |
| Capability estimator | `lib/fitbod_clone/capability_estimator.rb` |
| Recovery model | `lib/fitbod_clone/recovery_model.rb` |
| Exercise selector | `lib/fitbod_clone/exercise_selector.rb` |
| Capability recommender | `lib/fitbod_clone/prescriber.rb` |
| Workout generator (splits, time budget, ordering) | `lib/fitbod_clone/workout_generator.rb` |
| Strength Score / mStrength | `lib/fitbod_clone/strength_score.rb` |
| Fitbod CSV export importer | `lib/fitbod_clone/fitbod_export.rb` |
| Behaviour profile of an export | `lib/fitbod_clone/export_analysis.rb` |
| Backtest against an export | `lib/fitbod_clone/backtest.rb` |

## 3. Components in detail

### 3.1 Muscle recovery model
**Public facts.** Fatigue per muscle is estimated from sets, reps and weight. Body stats and
Apple Health refine it, and cardio counts, especially if logged often. The scale is 0-100%.
Muscles are "fully recovered after six days unless other factors affect it". The blog describes
prioritising muscles not heavily trained in the last 48-72 h. Fully fatigued (0%) muscles are
normally not recommended, but you need not wait for 100%. **[Stated]**

**Reconstruction. [Inferred]**
- Each set adds `10% × activation × effort` fatigue to every muscle the exercise works.
  - `activation` is 1.0 for prime movers and 0.3-0.6 for synergists.
  - `effort = clamp(1 - 0.1 × RIR, 0.35, 1)`. RIR is the logged value, or inferred from the
    current 1RM estimate and the weight × reps logged.
- Fatigue stacks across sessions, capped at 100%.
- Recovery is linear at 100% per 144 h. This one rule meets both public statements: a maxed-out
  muscle takes the full 6 days, while a typical session (30-50% fatigue) clears in 2-3 days.
- Cardio adds `minutes × intensity × 0.5%` to quads, calves, hamstrings and glutes.

### 3.2 Capability estimator
**Patent US 12,109,454, "Determining a user's current exercise capability"** (filed
2021-04-16, granted 2024-10-08). Capability is defined as the maximum weight for one rep. **[Patent]**
1. Partition the user's history for an exercise into time periods.
2. Compute an aggregate capability for each period.
3. Take a moving average of those aggregates, with exponential smoothing (claim 5).
4. Once a threshold time has passed since the user last trained (the spec's example is
   "more than a week"), decay the capability (claim 4).

**Patent US 12,551,757, "Machine-learned exercise capability prediction model".** If the user
has never done an exercise, feed their profile to a **random forest** trained on other users'
capabilities, or estimate it from a **ratio** to an exercise they have done. **[Patent]**

**Help center.** The engine weights your *strongest* and *most recent* performances. First-time
exercises start conservative. Weights drop automatically after a break. **[Stated]**

**Reconstruction.**
- Period = training day. The per-day aggregate is the best set e1RM, computed with reps + logged RIR.
- e1RM formula: Brzycki for ≤10 reps, Epley above, capped at 20 reps. The blog names Epley
  and the public Strength Tester uses Brzycki. The weights Fitbod actually prescribed fit this
  combined curve closely at every rep count from 5 to 15. **[Measured]**
- EMA with **α = 0.7**. That predicted the next prescription better than α = 0.3 or 0.5,
  "best of last 3", or "last session only". **[Measured]**
- Decay: none for **42 days** off an exercise, then **0.9% per week**, capped at 15%. The
  original guess (7 days, 3%/week) raised median backtest error on lifts returning after a
  layoff from 12.5% to 20%. **[Measured]**
- Cold start: transfer from a sibling in the same movement family using the strength-standard
  ratio × 0.9. Otherwise use a population prior of
  `bodyweight × ratio × experience factor × sex factor × 0.8`. A random forest needs
  population data we do not have; the standards table gives the same shape of answer.
- Bodyweight exercises track max reps; timed exercises track max seconds.

### 3.3 Exercise Selector
**Public facts.** The selector scores the library every time it builds a workout. Its inputs are
goal effectiveness (mined from tens of millions of logged workouts), available equipment, muscle
recovery, requested variety, and per-exercise feedback. Manual swaps also count as feedback. **[Stated]**

**Patent US 12,347,542, "Predicting exercises based on user-selected variance"** (granted
2025-07-01). An ML model is trained on population exercise histories labelled with equipment,
goals and profile. It may include **per-user models**. It ranks candidate exercises. The system
then picks a **random subset of exercises the user did within a recent window, sized by the
variance level**, and re-ranks them. Higher variance perturbs more and surfaces more distinct
exercises. **[Patent]**

**Patent application, "ML-based exercise recommendation adjustment based on user feedback"**
(filed 2023-03-09). Covers modifying the model's ranking with More/Less/Never requests. **[Patent]**

**Reconstruction. [Inferred]**
```
score = effectiveness
      × (activation-weighted mean recovery)²      # 0 if any prime mover < 30%
      × {More: 1.5, Less: 0.7, none: 1.0}
      × (1 + 0.3 × min(sessions_done / 4, 1))     # stands in for the per-user model
      × variance_factor                           # 0.3-0.9 for the random recent subset
```
Variability sets the fraction of the last 14 days' exercises that get perturbed: Consistent
0.15, Balanced 0.4, Varied 0.75. The generator picks greedily. After each pick it applies
the planned sets' fatigue to a projected recovery map and penalises exercises from the same
movement family (× 0.35). That makes the session spread across muscles instead of stacking
presses. Exercises are then ordered compound first.

**Split → target muscles.** Full Body targets everything. Fresh Muscle Groups targets the two
most-recovered of chest, back, shoulders, arms, legs and core. PPL and Upper/Lower pick the day
whose muscles are most recovered, which rotates naturally without storing a pointer. **[Inferred]**

**Session length. [Inferred]** Each exercise costs `sets × (45 s + rest) + 60 s per warm-up + 90 s`
transition. Exercises are added until the duration budget is spent, with a minimum of 3 and a maximum of 10.

### 3.4 Capability Recommender
**Public facts.** Reps, sets and weight come from your history, and intensity varies between
sessions. After an easy exercise the engine raises load or reps; after a hard one it eases back.
RIR ratings feed it. **[Stated]**

**Reconstruction.**
- **Rep target:** drawn per exercise per day from a weighted distribution. The draw is seeded by
  exercise and date, so regenerating keeps it stable. There is no fixed heavy → medium → light
  order: in the export, consecutive rep targets look independent. Compound and isolation lifts
  use the **same** distribution. **[Measured]** for hypertrophy, **[Inferred]** for the rest.

  | Goal | Rep target distribution | Sets (compound / isolation) | Rest |
  |---|---|---|---|
  | Hypertrophy | 5: 7%, 6: 5%, 8: 30%, 10: 25%, 12: 22%, 15: 11% | 4 / 3 | 120 s / 75 s |
  | Strength | 3: 15%, 4: 15%, 5: 35%, 6: 25%, 8: 10% | 4 / 3 | 180 s / 120 s |
  | Endurance | 12: 30%, 15: 40%, 20: 30% | 3 / 2 | 60 s / 45 s |
  | General | 8: 25%, 10: 35%, 12: 25%, 15: 15% | 3 / 3 | 90 s / 60 s |

- **Weight:** `weight_for(capability, reps)`, rounded to the **nearest** 5 lb (machines
  included). Fitbod prescribes at your logged level with no reps-in-reserve buffer: the original
  guess of a 2-rep buffer under-prescribed by 5-7%, and rounding down instead of to nearest
  raised median error from 8.7% to 12.5%. **[Measured]**
- **Progression** needs no explicit rule. When you log more than prescribed, the α = 0.7 EMA
  carries most of it into the next prescription; the export drifts up about 1-2% per session.
  An explicit "+1 increment after a good session" rule made the backtest worse (median error
  8.7% → 12.5%) and was removed.
  **[Measured]**
- **Effort feedback:** last session's average RIR ≤ 0 → −5%; ≥ 4 → +5%. **[Inferred]**: the
  export has no RIR column.
- **Warm-ups:** one set at 60% × 8 when the working weight is ≥ 50 lb, on any loaded exercise.
  This is the most common pattern at every weight. Two-set (≈40%×10, 75%×5) and three-set
  ramps show up in 10-20% of heavier lifts and are not modelled. **[Measured]**

### 3.5 Strength Score / mStrength
**Public facts.** mStrength is a relative per-muscle scale, "neither a percentile nor pounds".
It comes from an ML model of how each exercise loads each muscle, normalised with population
statistics. A muscle needs at least 6 sets to get a score. The overall score is the mean of the
muscle scores. Muscles are grouped as Push, Pull and Legs. **[Stated]**

**Reconstruction. [Inferred]** For each muscle, take the activation-weighted mean of
`capability / (bodyweight × reference ratio) × 100` over weighted exercises where it is a prime
mover. 100 means the library's reference standard. The scale is arbitrary, like Fitbod's.

### 3.6 Plateaus and trends
A Fitbod filing, **"Workout modification based on muscle strength measurement trends"**
(US 12,551,760 / US 2024/0299808), plus help-center text describe changing volume, intensity or
exercise choice when strength trends flatten or drop. **[Patent]/[Stated]** This is *not*
implemented in the reference engine. It would sit in the Prescriber as a deload rule keyed on
the slope of the capability EMA.

## 4. Implied data model

```
users            id, sex, birth_year, bodyweight, experience, units
plans            user_id, goal, split, workouts_per_week, variability, warmups, focus_muscles[]
gym_profiles     id, user_id, name, equipment[], duration_min, is_active
exercises        id, name, mechanic, load_type, equipment[], family, video_url, effectiveness_by_goal{}
exercise_muscles exercise_id, muscle, activation               # many-to-many with weights
exercise_prefs   user_id, exercise_id, pref (more|less|exclude)
workouts         id, user_id, gym_profile_id, started_at, finished_at, generated_snapshot(json)
workout_sets     workout_id, exercise_id, set_index, kind (warmup|working),
                 target_reps, target_weight, reps, weight, seconds, distance, rir, completed_at
cardio_imports   user_id, source (healthkit|strava|fitbit), started_at, minutes, intensity, external_id
recovery_overrides user_id, muscle, value, set_at
```
Capability, recovery and strength scores are **derived**, so there is no need to store them.
Cache them per user if generating on the server.

**Where the engine runs: unknown.** Fast regeneration after background HealthKit syncs points
to either an on-device engine or a cheap server call. The patents describe a server-side
"exercise recommendation system". A clone can do either, since generation is a pure function.

## 5. What is still unknown, and how to find out legitimately

Resolved from the export ([section 7](#7-calibration-against-a-real-fitbod-export)): the
rep↔weight curve, the capability smoothing, layoff decay, rep-target selection, warm-ups, and
weight rounding.

Still open:

| Unknown | Black-box experiment (as a normal user of the app) |
|---|---|
| Recovery curve shape | Log a fixed session; screenshot the recovery map every 12 h for 6 days. Linear vs exponential falls out of the plot. The export has no recovery values. |
| Per-set fatigue constant | Vary sets (2, 4, 6) and RIR on the same lift; compare the initial recovery drop. |
| Cold-start ratios | New account with set bodyweight/experience; record first recommendations for 20 lifts. |
| Selector weights | Variety is much higher in the export than the reference selector produces; see section 7. |
| Effect of RIR ratings | Rate the same lift "easy" vs "hard" on alternate sessions and compare the next weight. |

## 6. Building a clone on this

MVP scope, in order:
1. Exercise catalogue with muscle activations and equipment. This is the biggest content cost:
   Fitbod's moat is 1,000+ filmed exercises and per-goal effectiveness priors mined from its user base.
2. Logger (sets, RIR, rest timer) and history storage.
3. This engine as a pure function `generate(history, profile, settings, now)`. Port it to the
   client (Swift/Kotlin) or put it behind `POST /workouts/generate`.
4. Recovery map and per-exercise e1RM charts. Both are already computed by the engine.
5. HealthKit / Health Connect import for cardio fatigue.
6. Later: replace the heuristic ranker with a learned model once there is data. The patents
   describe training the ranker on population histories labelled with equipment, goal and profile.

## 7. Calibration against a real Fitbod export

Fitbod can export every logged set as a CSV file. Since most users log what
the app prescribes, an export shows Fitbod's actual recommendations. User edits add noise, so
the error figures below are upper bounds. One long-time user's export was used: about 7.5 years,
1,400+ sessions, 35,000 working sets, 1,600 warm-up sets and 675 distinct exercise names.

### Export format
```
Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier
2026-03-10 18:00:00 +0000,Barbell Bench Press, 8,61.23497,0.0,0.0,0.0,0.0,false,, 1.0
```
- Weights are always stored in **kg**, even for lb users. 61.23497 kg is exactly 135 lb, so
  convert back before looking for increments.
- `multiplier` is the **volume multiplier**: 1 for barbell, machine, cable and bodyweight reps;
  2 for dumbbell pairs; 4 for alternating unilateral dumbbell work (lunges, step-ups); 0 for
  timed holds, stretches and cardio. Fitbod's volume is `reps × weight × multiplier`.
- `isWarmup` marks warm-up sets. Cardio rows carry duration and distance with reps = 0. The file
  is UTF-8 (names like "…at 90°") with occasional blank lines.

### What the data says
| Behaviour | Measured | What the engine originally assumed |
|---|---|---|
| Rep targets | 8: 30%, 10: 25%, 12: 22%, 15: 11%, 5: 7%, 6: 5% (odd counts are user deviations); same for compound and isolation | goal ranges split by compound/isolation |
| Rep order | no fixed cycle; consecutive targets look independent | heavy → medium → light rotation |
| Weight vs reps | weight moves opposite to reps (reps down → weight up 6× more often than down) and sits on the 1RM curve | same |
| Weight level | right at the logged capability, no reps-in-reserve buffer | 2-rep buffer |
| Capability smoothing | α ≈ 0.7 fits best | α = 0.5 |
| After time off an exercise | flat to 6 weeks; ×0.975 at 6-8 weeks, ×0.94 at 2-4 months, ×0.85 at 4-6 months | −3%/week after 1 week |
| Increments | 5 lb (and 2.5 lb for some dumbbells), machines included | machines 10 lb |
| Warm-ups | none < 50 lb; one at 60% × 8 is the most common pattern at every weight above that, on any loaded lift | barbell 3-step ramp, compound only |
| Sets per exercise | 3 (41%) or 4 (38%) | 3-4 |
| Variety | only ~32% of a week's exercises appeared in the previous 4 active weeks; the same exercise comes back a median of 36 days later | not measured |

### Backtest
Before each logged exercise, the engine predicts the weight from earlier data only, at the rep
target the user actually logged:

| Slice | Cases | Engine: median error / within 5% / within 10% | "Repeat last weight" baseline |
|---|---|---|---|
| All | 5,838 | 8.7% / 41% / 54% | 12.5% / 32% / 44% |
| Exercise done within 6 weeks | 3,264 | **5.9% / 47% / 62%** | 10.0% / 38% / 52% |
| Returning after 6+ weeks | 2,574 | 12.5% / 33% / 43% | 15.4% / 25% / 35% |

Errors are lumpy because one 5 lb step is already 9% of a 55 lb lift. Median signed error is
0 at every rep target: predictions are about as often high (28%) as low (32%).

### Known gaps
- **Selector variety.** Fitbod rotated through hundreds of exercises. The reference selector's
  familiarity bonus pushes toward repeats. Exercise choice cannot be backtested from an export
  the way weights can, because the export records what was picked, not what was offered.
- **Returning lifts** are still the weakest slice. Fitbod probably also uses cross-exercise
  information (the patents describe it) that a per-exercise EMA cannot see.
- **Exercise mapping.** 481 of the 675 names map to muscles via keyword rules in
  `fitbod_export.rb`. The rest are mobility, cardio or unusual movements and are skipped.

## Running the reference engine

Needs Ruby ≥ 3.1 and only the standard library (tests use minitest, a bundled gem).

```sh
cd fitbod_teardown
for t in test/*_test.rb; do ruby -Ilib $t; done      # tests
ruby bin/demo                                        # simulated history: hypertrophy, PPL, 60 min
ruby bin/demo strength fresh_muscle_groups 45        # goal, split, minutes

# With your own Fitbod export (keep it in data/, which git ignores):
ruby bin/analyze data/WorkoutExport.csv              # behaviour profile + backtest
ruby bin/demo --export data/WorkoutExport.csv hypertrophy push_pull_legs 45
```

Example output (simulated history: three weeks of PPL, ending in a legs and push day plus a run):

```
Pull (~55 min)
1. Barbell Row  [history]
     warm-up  100 lb x 8
     4 x 10 @ 165 lb  rest 120s
2. Deadlift  [transfer]
     warm-up  160 lb x 8
     4 x 8 @ 270 lb  rest 120s
3. Pull Up  [population]
     4 x 10 reps  rest 120s
...
```
The tag shows where the capability came from: `history` means the user's own logs, `transfer`
means borrowed from a related lift, and `population` means the cold-start prior.

## Sources

Patents (Fitbod, Inc.; inventors Allen Chen and Jess Venticinque):
- [US 12,109,454: Determining a user's current exercise capability](https://patents.google.com/patent/US12109454) ([USPTO PDF](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12109454), publication [US20240424346A1](https://patents.google.com/patent/US20240424346A1/en))
- [US 12,347,542: Predicting exercises based on user-selected variance](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12347542)
- [US 12,551,757: Machine-learned exercise capability prediction model](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12551757)
- [US 12,551,760: Workout modification based on muscle strength measurement trends](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12551760)
- [Machine learning-based exercise recommendation adjustment based on user feedback](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12555666)
- [US20190262664A1: Creating customized adaptive workout program](https://patents.google.com/patent/US20190262664A1/en)
- [Justia: patents assigned to Fitbod, Inc.](https://patents.justia.com/assignee/fitbod-inc)

Fitbod help center and blog:
- [How Fitbod Generates Your Personalized Workouts: Meet The Fitbod Algorithm](https://fitbod.me/blog/fitbod-algorithm/)
- [How Fitbod Creates Your Workout](https://help.fitbod.me/hc/en-us/articles/360004429814-How-Fitbod-Creates-Your-Workout)
- [Muscle Recovery](https://help.fitbod.me/hc/en-us/articles/360006269014-Muscle-Recovery)
- [How does Fitbod decide my sets, reps and weight?](https://help.fitbod.me/hc/en-us/articles/43489869175063-How-does-Fitbod-decide-my-sets-reps-and-weight)
- [Warm-Up Sets](https://help.fitbod.me/hc/en-us/articles/360006337634-Warm-Up-Sets)
- [My Plan](https://help.fitbod.me/hc/en-us/articles/34336407191191-My-Plan)
- [Why did my workout change? Understanding workout refreshes](https://help.fitbod.me/hc/en-us/articles/42333470514455-Why-did-my-workout-change-Understanding-workout-refreshes)
- [Took a Break? How to Recalibrate Your Fitbod Recommendations](https://help.fitbod.me/hc/en-us/articles/34320813009431-Took-a-Break-Here-s-How-to-Recalibrate-Your-Fitbod-Recommendations)
- [How Fitbod Tracks Your Strength Gains with Real Time Metrics and Scores](https://help.fitbod.me/hc/en-us/articles/35065164178327-How-Fitbod-Tracks-Your-Strength-Gains-with-Real-Time-Metrics-and-Scores)
- [Recommend More / Less / Exclude](https://fitbod.me/blog/recommend-more-less-exclude/)
- [Your Gym Profile](https://fitbod.me/blog/your-gym-profile/)
- [Muscle Strength (mStrength)](https://fitbod.me/blog/muscle-strength/)
- [Tracking volume, intensity and recovery](https://fitbod.me/blog/tracking-volume-intensity-and-recovery-with-fitbod/)
- [Fitbod Strength Tester](https://fitbod.me/strength-tester)

Third party:
- [SensAI: Fitness app pricing 2026](https://www.sensai.fit/blog/fitness-app-pricing-free-tier-comparison) (competitor; treat as biased)
- [The Pricer: How much does Fitbod cost](https://www.thepricer.org/how-much-does-fitbod-cost/)
- [Seedtable: Fitbod](https://seedtable.com/companies/fitbod), [CB Insights: Fitbod](https://www.cbinsights.com/company/fitbod)
