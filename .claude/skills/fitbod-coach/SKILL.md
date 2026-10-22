---
name: fitbod-coach
description: Adjust the user's training plan (fitbod_teardown/plans/my_plan.yml) from their goals, body photos, Fitbod screenshots or a new Fitbod export, then generate today's workout with the calibrated Fitbod-style engine. Use when the user shares physique photos, states a goal ("bring up my shoulders", "get leaner", "stronger squat"), sends a new export or My Plan screenshots, or asks what to train today.
---

# Fitbod coach

The engine in `fitbod_teardown/` reproduces Fitbod's workout generator and is calibrated on
the user's own export (see `fitbod_teardown/README.md`, section 7). This skill is how you
steer it for the user. The plan file is the only thing you edit; the engine reads it.

| File | Role |
|---|---|
| `fitbod_teardown/plans/my_plan.yml` | goal, split, schedule, per-muscle `emphasis`, exercise preferences, dated `assessments` |
| `fitbod_teardown/data/fitbod_export_*.csv` | the user's Fitbod export (history the engine works from) |
| `fitbod_teardown/bin/workout` | prints today's workout for the plan |
| `fitbod_teardown/bin/analyze` | behaviour profile + backtest of an export |

## Workflow

1. Read `plans/my_plan.yml`, especially the latest `assessments` entry, so changes build on
   the last review instead of starting over.
2. Turn each input into plan changes:
   - **Goal in words.** Set `goal` (table below) and any muscles they name in `emphasis`.
   - **Body photos.** Do the assessment below.
   - **My Plan or other app screenshots.** Sync `split`, `workouts_per_week`, `duration_min`,
     `experience`, `variability`, `warmups`, equipment weights.
   - **New Fitbod export.** Save it as `fitbod_teardown/data/fitbod_export_<from>_<to>.csv`
     and point `export:` at it. Run
     `ruby fitbod_teardown/bin/analyze <file>` and check that the backtest's "done within 6
     weeks" median error is still ≤ 6.5%. If it is worse, say so before trusting the workouts.
3. Edit the plan. Change only what the evidence supports. Add an entry at the top of
   `assessments`:
   ```yaml
   assessments:
     - date: "2026-10-22"
       inputs: front, back, left side photos; relaxed; gym lighting
       observations:
         shoulders: side delts narrow relative to chest and arms
         calves: in line with thighs
       changes:
         emphasis.shoulders: 1.0 -> 1.3
   ```
4. Run `ruby fitbod_teardown/bin/workout` and the tests
   (`cd fitbod_teardown && for t in test/*_test.rb; do ruby -Ilib $t; done`). `Plan.load`
   rejects unknown goals, splits, muscles, exercise names and out-of-range emphasis, so a
   failed run usually means a typo in the plan.
5. Reply with: what you saw, what changed in the plan (old → new) and why, and today's
   workout. Mark the exercises picked partly for emphasis; `bin/workout` lists them.

## Physique assessment from photos

**Ask for:** front, back and both sides; relaxed; same lighting, distance and time of day each
time. Front and back double-biceps poses help. Compare with the previous assessment when there
is one: progress since last time matters more than a single snapshot.

**Judge relative development.** Ask which muscles look behind the rest of this person's own
physique, given their goal. Don't compare them with other people.

| What you see | `emphasis` |
|---|---|
| clearly behind the rest | 1.4-1.5 |
| slightly behind | 1.2-1.3 |
| in balance | leave at 1.0 (omit) |
| clearly ahead, or the user wants it de-prioritised | 0.7-0.8 |

Rules:
- At most 3-4 muscles away from 1.0 at a time. Raising everything raises nothing, because
  emphasis works by ranking muscles against each other.
- Move a value by at most ±0.3 per review unless the user asks for more.
- The 16 muscles are: chest shoulders triceps biceps forearms lats upper_back traps
  lower_back abs quads hamstrings glutes calves adductors abductors.
- Photos cannot show strength, exact body-fat percentage, or muscle hidden by pose or
  lighting. Say what you couldn't judge and leave it unchanged. Don't estimate body-fat numbers.
- If the photos can't support a call (blurry, cropped, inconsistent), change nothing and ask
  for better ones.
- Tone: plain, neutral and about training. No comments on attractiveness, no diet or
  weight-loss prescriptions beyond the goal setting, no medical claims. If the user mentions
  pain or injury, exclude the exercises they name (`preferences.exclude`) and suggest a
  professional rather than programming around it.

## Goals and splits

| The user says | `goal` |
|---|---|
| build muscle, get bigger, hypertrophy | `build_muscle` |
| lose fat, get lean, cut, more definition | `get_lean` |
| burn calories, conditioning, circuits | `reduce_bodyweight` |
| get stronger, lift heavier | `get_stronger` |
| powerlifting, squat/bench/deadlift total | `powerlifting` |
| Olympic lifting, cleans, snatches | `olympic_weightlifting` |
| general fitness, health | `improve_fitness` |

Splits: `upper_lower_full`, `push_pull_legs_full`, `upper_lower`, `push_pull_legs`,
`full_body`, `fresh_muscle_groups`. Keep the user's chosen split. For 7 workouts/week the app
recommends `push_pull_legs_full`, so mention it if they ask.

## What emphasis does in the engine

- Exercise scoring is multiplied by the activation-weighted emphasis of the muscles an
  exercise trains, so prioritised muscles get picked more often.
- Prime-mover emphasis ≥ 1.3 adds a set; ≤ 0.75 drops one (range 2-6).
- Fresh Muscle Groups ranks groups by recovery × emphasis.
- Weekly set targets for push/pull/legs scale with the group's mean emphasis.

These rules are inferred (the app has a muscle-focus setting, but its exact effect isn't
public), so judge the result by the workouts it produces.

## Privacy

The repository is public, and the user has agreed that their workout data may be public.
**Never copy photos into the repository**: read them from wherever they were uploaded.
`photos/` and image files under `fitbod_teardown/` are git-ignored as a backstop. Assessment
entries record training-relevant observations (which muscles to prioritise and why) and
nothing else about the person's body.
