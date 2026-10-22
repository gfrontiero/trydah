# frozen_string_literal: true

require_relative "test_helper"

class OneRepMaxTest < Minitest::Test
  include FitbodClone

  def test_brzycki_low_reps_and_round_trip
    assert_in_delta 225.0, OneRepMax.estimate(200, 5), 0.01
    assert_in_delta 200.0, OneRepMax.weight_for(225.0, 5), 0.01
    assert_in_delta 5.0, OneRepMax.reps_at(225.0, 200), 0.01
  end

  def test_epley_high_reps_and_single
    assert_in_delta 150.0, OneRepMax.estimate(100, 15), 0.01
    assert_in_delta 15.0, OneRepMax.reps_at(150.0, 100), 0.01
    assert_equal 315.0, OneRepMax.estimate(315, 1)
  end
end

class CapabilityEstimatorTest < Minitest::Test
  include TestHelper

  def test_smoothed_moving_average_of_daily_best
    h = History.new(sets: lift(:barbell_bench_press, 200, 5, days_ago: 4) +
                          lift(:barbell_bench_press, 180, 5, days_ago: 4) +
                          lift(:barbell_bench_press, 210, 5, days_ago: 1))
    est = capabilities(h).estimate(library.fetch(:barbell_bench_press))
    assert_equal :history, est.source
    # day 1 best 225, day 2 best 236.25, alpha 0.7
    assert_in_delta 232.875, est.value, 0.01
  end

  def test_holds_for_six_weeks_then_decays
    squat = library.fetch(:back_squat)
    recent = History.new(sets: lift(:back_squat, 300, 1, days_ago: 35))
    assert_in_delta 300, capabilities(recent).estimate(squat).value, 0.01

    stale = History.new(sets: lift(:back_squat, 300, 1, days_ago: 70))
    assert_in_delta 300 * (1 - 0.009 * 4), capabilities(stale).estimate(squat).value, 0.01

    ancient = History.new(sets: lift(:back_squat, 300, 1, days_ago: 400))
    assert_in_delta 300 * 0.85, capabilities(ancient).estimate(squat).value, 0.01
  end

  def test_transfers_from_sibling_exercise
    h = History.new(sets: lift(:barbell_bench_press, 225, 1, days_ago: 2))
    est = capabilities(h).estimate(library.fetch(:incline_db_bench_press))
    assert_equal :transfer, est.source
    assert_in_delta 225 * 0.32 / 0.90 * 0.9, est.value, 0.01
  end

  def test_population_prior_is_conservative
    est = capabilities(History.new).estimate(library.fetch(:back_squat))
    assert_equal :population, est.source
    assert_in_delta 180 * 1.15 * 0.8, est.value, 0.01
  end
end

class RecoveryModelTest < Minitest::Test
  include TestHelper

  def recovery(history, now: NOW)
    RecoveryModel.new(library:, capabilities: capabilities(history, now:)).recovery(history, now)
  end

  def test_untrained_muscles_are_fully_recovered
    assert(recovery(History.new).values.all? { |v| v == 100.0 })
  end

  def test_fatigue_hits_trained_muscles_and_clears_linearly
    h = History.new(sets: lift(:barbell_bench_press, 200, 8, days_ago: 0, rir: 0, sets: 4))
    fresh = recovery(h)
    assert_operator fresh[:chest], :<, fresh[:triceps]
    assert_equal 100.0, fresh[:quads]

    later = recovery(h, now: NOW + 48 * 3600)
    assert_in_delta [fresh[:chest] + 48 * 100.0 / 144, 100].min, later[:chest], 0.5
    assert_equal 100.0, recovery(h, now: NOW + 6 * DAY)[:chest]
  end

  def test_cardio_fatigues_legs
    h = History.new(cardio: [CardioSession.new(minutes: 60, intensity: 1.0, performed_at: NOW)])
    r = recovery(h)
    assert_operator r[:quads], :<, 100
    assert_equal 100.0, r[:chest]
  end
end

class ExerciseSelectorTest < Minitest::Test
  include TestHelper

  def selector(settings: PlanSettings.new, preferences: Preferences.new, history: History.new, seed: 1)
    ExerciseSelector.new(library:, history:, preferences:, settings:, now: NOW, rng: Random.new(seed))
  end

  def fresh = MUSCLES.to_h { |m| [m, 100.0] }

  def test_respects_equipment_and_exclusions
    s = selector(settings: PlanSettings.new(equipment: %i[dumbbell]), preferences: Preferences.new(db_curl: :exclude))
    ids = s.candidates.map(&:id)
    assert_includes ids, :push_up
    assert_includes ids, :hammer_curl
    refute_includes ids, :barbell_bench_press
    refute_includes ids, :db_curl
  end

  def test_skips_fatigued_prime_movers
    tired = fresh.merge(chest: 10.0)
    ids = selector.rank(tired, MUSCLES).map { |ex, _| ex.id }
    refute_includes ids, :barbell_bench_press
    assert_includes ids, :overhead_press
  end

  def test_preferences_shift_ranking
    plain = selector.rank(fresh, %i[shoulders]).map { |ex, _| ex.id }
    boosted = selector(preferences: Preferences.new(lateral_raise: :more)).rank(fresh, %i[shoulders]).map { |ex, _| ex.id }
    assert_operator boosted.index(:lateral_raise), :<, plain.index(:lateral_raise)
  end

  def test_higher_variability_perturbs_more_recent_exercises
    ids = %i[barbell_bench_press overhead_press barbell_row back_squat lat_pulldown db_curl lateral_raise leg_press]
    h = History.new(sets: ids.flat_map { |id| lift(id, 100, 8, days_ago: 3) })
    familiarity = 1 + ExerciseSelector::FAMILIARITY_BONUS / ExerciseSelector::FAMILIARITY_SATURATION
    perturbed = lambda do |level|
      s = selector(settings: PlanSettings.new(variability: level), history: h)
      ids.count { |id| s.score(library.fetch(id), fresh) < library.fetch(id).effectiveness * familiarity - 1e-9 }
    end
    assert_equal 2, perturbed.call(:consistent) # ceil(0.15 * 8)
    assert_equal 6, perturbed.call(:varied)     # ceil(0.75 * 8)
  end
end

class PrescriberTest < Minitest::Test
  include TestHelper

  def prescribe(id, history:, goal: :hypertrophy, warmups: true)
    settings = PlanSettings.new(goal:, warmups:)
    Prescriber.new(history:, capabilities: capabilities(history), settings:).prescribe(library.fetch(id))
  end

  def test_weight_reads_capability_off_the_curve_at_the_rep_target
    h = History.new(sets: lift(:back_squat, 275, 5, days_ago: 3))
    rx = prescribe(:back_squat, history: h, goal: :strength)
    assert_equal 4, rx.sets
    assert_equal 0.0, rx.weight % 5
    one_rm = OneRepMax.estimate(275, 5)
    assert_in_delta OneRepMax.weight_for(one_rm, rx.reps), rx.weight, 2.5
  end

  def test_rep_targets_follow_goal_distribution_and_are_stable_per_day
    settings = PlanSettings.new(goal: :hypertrophy)
    caps = capabilities(History.new)
    targets = (0...400).map do |d|
      Prescriber.new(history: History.new, capabilities: caps, settings:, now: NOW + d * DAY)
                    .rep_target(library.fetch(:barbell_bench_press))
    end
    assert_equal [5, 6, 8, 10, 12, 15], targets.uniq.sort
    assert_operator targets.count(8), :>, targets.count(15) * 2
    again = Prescriber.new(history: History.new, capabilities: caps, settings:, now: NOW)
    assert_equal targets.first, again.rep_target(library.fetch(:barbell_bench_press))
  end

  def test_one_warmup_at_sixty_percent_once_working_weight_reaches_fifty
    heavy = prescribe(:leg_extension, history: History.new(sets: lift(:leg_extension, 120, 10, days_ago: 2)))
    assert_equal 1, heavy.warmups.size
    assert_equal 8, heavy.warmups.first.reps
    assert_in_delta heavy.weight * 0.6, heavy.warmups.first.weight, 2.5

    light = prescribe(:lateral_raise, history: History.new(sets: lift(:lateral_raise, 20, 12, days_ago: 2)))
    assert_empty light.warmups
    assert_empty prescribe(:leg_extension, history: History.new(sets: lift(:leg_extension, 120, 10, days_ago: 2)), warmups: false).warmups
  end

  def test_backs_off_after_grinding_session
    # Same reps and weight, so the same capability; only the reported effort differs.
    unrated = History.new(sets: lift(:barbell_row, 155, 8, days_ago: 3))
    ground = History.new(sets: lift(:barbell_row, 155, 8, days_ago: 3, rir: 0))
    assert_operator prescribe(:barbell_row, history: ground).weight, :<, prescribe(:barbell_row, history: unrated).weight
  end

  def test_bodyweight_and_timed_exercises
    h = History.new(sets: lift(:pull_up, 0, 10, days_ago: 2) +
                          [LoggedSet.new(exercise_id: :plank, seconds: 90, performed_at: NOW - 2 * DAY)])
    assert_equal 10, prescribe(:pull_up, history: h).reps
    assert_equal 70, prescribe(:plank, history: h).seconds
    assert_empty prescribe(:pull_up, history: h).warmups
  end
end

class WorkoutGeneratorTest < Minitest::Test
  include TestHelper

  def test_full_workout_fits_duration_and_orders_compounds_first
    w = generator(duration_min: 45, split: :full_body).generate
    assert_operator w.prescriptions.size, :>=, WorkoutGenerator::MIN_EXERCISES
    assert_operator w.est_minutes, :<=, 45
    kinds = w.prescriptions.map { |rx| rx.exercise.compound? ? 0 : 1 }
    assert_equal kinds.sort, kinds
    assert_equal w.prescriptions.map { |rx| rx.exercise.id }.uniq.size, w.prescriptions.size
  end

  def test_push_pull_legs_rotates_to_freshest_day
    h = History.new(sets: lift(:barbell_bench_press, 185, 8, days_ago: 0, rir: 1, sets: 4) +
                          lift(:overhead_press, 105, 8, days_ago: 0, rir: 1, sets: 4) +
                          lift(:back_squat, 225, 8, days_ago: 1, rir: 1, sets: 4))
    w = generator(history: h, split: :push_pull_legs).generate
    assert_equal :pull, w.day
  end

  def test_fresh_muscle_groups_avoids_yesterdays_muscles
    h = History.new(sets: lift(:back_squat, 225, 8, days_ago: 1, rir: 0, sets: 5) +
                          lift(:romanian_deadlift, 185, 8, days_ago: 1, rir: 0, sets: 4))
    w = generator(history: h, split: :fresh_muscle_groups).generate
    refute_includes w.day.to_s, "legs"
  end

  def test_same_inputs_same_workout
    a = generator(seed: 7).generate.prescriptions.map { |rx| rx.exercise.id }
    b = generator(seed: 7).generate.prescriptions.map { |rx| rx.exercise.id }
    assert_equal a, b
  end
end

class StrengthScoreTest < Minitest::Test
  include TestHelper

  def test_needs_six_sets_and_averages_muscles
    h = History.new(sets: lift(:barbell_bench_press, 162, 1, days_ago: 1, sets: 6) +
                          lift(:back_squat, 207, 1, days_ago: 1, sets: 3))
    s = StrengthScore.new(library:, history: h, profile:, capabilities: capabilities(h))
    assert_equal({ chest: 100 }, s.muscle_scores)
    assert_equal 100, s.overall
  end
end
