# frozen_string_literal: true

require_relative "test_helper"

class PlanTest < Minitest::Test
  include TestHelper

  FIXTURE = File.join(__dir__, "fixtures", "plan.yml")

  def plan_with(overrides)
    data = YAML.safe_load_file(FIXTURE, permitted_classes: [Date]).merge(overrides)
    Plan.new(data, FIXTURE)
  end

  def test_loads_settings_preferences_and_export
    plan = Plan.load(FIXTURE)
    import = FitbodExport.load(plan.export_path)
    settings = plan.settings(library: import.library, history: import.history, now: NOW)
    assert_equal :build_muscle, settings.goal
    assert_equal :push_pull_legs_full, settings.split
    assert_equal({ shoulders: 1.4, chest: 0.8 }, settings.emphasis)
    assert_equal [5.0, 8.0, 12.0, 15.0, 20.0, 25.0], settings.available_weights[:dumbbell]
    assert_equal :advanced, plan.profile.experience
    assert_in_delta 0.7, plan.preferences(import.library).factor(:dumbbell_bicep_curl)
  end

  def test_rejects_typos
    assert_raises(ArgumentError) { plan_with("emphasis" => { "shoulder" => 1.3 }) }
    assert_raises(ArgumentError) { plan_with("emphasis" => { "shoulders" => 3.0 }) }
    assert_raises(ArgumentError) { plan_with("goal" => "get_huge") }
    assert_raises(ArgumentError) { plan_with("split" => "bro_split") }
    plan = plan_with("preferences" => { "exclude" => ["Flying Kick"] })
    assert_raises(ArgumentError) { plan.preferences(FitbodExport.load(plan.export_path).library) }
  end

  def test_my_plan_is_valid
    plan = Plan.load(File.expand_path("../plans/my_plan.yml", __dir__))
    assert File.exist?(plan.export_path)
  end
end

class EmphasisTest < Minitest::Test
  include TestHelper

  def fresh = MUSCLES.to_h { |m| [m, 100.0] }

  def selector(settings)
    ExerciseSelector.new(library:, history: History.new, preferences: Preferences.new, settings:, now: NOW,
                         rng: Random.new(1))
  end

  def test_emphasis_reorders_exercises
    plain = selector(PlanSettings.new).rank(fresh, MUSCLES).map { |ex, _| ex.id }
    focused = selector(PlanSettings.new(emphasis: { shoulders: 1.5 })).rank(fresh, MUSCLES).map { |ex, _| ex.id }
    assert_operator focused.index(:lateral_raise), :<, plain.index(:lateral_raise)
  end

  def test_emphasis_changes_set_count
    h = History.new(sets: lift(:lateral_raise, 20, 12, days_ago: 2))
    sets = lambda do |emphasis|
      settings = PlanSettings.new(emphasis:)
      Prescriber.new(history: h, capabilities: capabilities(h), settings:, rng: Random.new(5))
                .prescribe(library.fetch(:lateral_raise)).sets
    end
    base = sets.call({})
    assert_equal base + 1, sets.call({ shoulders: 1.4 })
    assert_equal base - 1, sets.call({ shoulders: 0.7 })
  end

  def test_emphasis_scales_weekly_targets
    settings = PlanSettings.new(workouts_per_week: 7, duration_min: 45, emphasis: { chest: 1.3, shoulders: 1.3, triceps: 1.3 })
    targets = WeeklySetTargets.new(library:, history: History.new, settings:).targets
    assert_equal({ push: 69, pull: 29, legs: 42 }, targets)
  end
end

class AvailableWeightsTest < Minitest::Test
  include TestHelper

  def weight(id, history, available_weights, reps)
    settings = PlanSettings.new(available_weights:)
    Prescriber.new(history:, capabilities: capabilities(history), settings:).weight_for_reps(library.fetch(id), reps)
  end

  def test_rounds_dumbbells_to_listed_weights_and_barbells_to_plate_pairs
    curls = History.new(sets: lift(:db_curl, 22.5, 10, days_ago: 2))
    assert_equal 20.0, weight(:db_curl, curls, { dumbbell: [8, 12, 20, 25] }, 10)

    bench = History.new(sets: lift(:barbell_bench_press, 137.5, 8, days_ago: 2))
    assert_equal 137.5, weight(:barbell_bench_press, bench, { plates: [1.25, 2.5, 5, 10, 25, 45] }, 8)
    assert_equal 140.0, weight(:barbell_bench_press, bench, {}, 8) # 5 lb steps; ties round up
  end
end

class GoalsAndSplitsTest < Minitest::Test
  include TestHelper

  def test_fitbod_goal_names_resolve
    assert_same Prescriber::GOALS[:hypertrophy], Prescriber.goal_config(:build_muscle)
    assert_same Prescriber::GOALS[:strength], Prescriber.goal_config(:get_stronger)
    %i[get_lean reduce_bodyweight improve_fitness powerlifting olympic_weightlifting].each do |g|
      assert Prescriber.goal_config(g)
    end
  end

  def test_powerlifting_favours_the_competition_lifts
    fresh = MUSCLES.to_h { |m| [m, 100.0] }
    rank = lambda do |goal|
      ExerciseSelector.new(library:, history: History.new, preferences: Preferences.new,
                           settings: PlanSettings.new(goal:), now: NOW, rng: Random.new(1))
                      .rank(fresh, %i[quads]).map { |ex, _| ex.id }
    end
    assert_equal :back_squat, rank.call(:powerlifting).first
    assert_operator rank.call(:powerlifting).index(:leg_press), :>, rank.call(:powerlifting).index(:back_squat)
  end

  def session(kind, days_ago)
    ids = { push: %i[barbell_bench_press overhead_press tricep_pushdown],
            pull: %i[barbell_row lat_pulldown db_curl],
            legs: %i[back_squat leg_curl calf_raise],
            full: %i[barbell_bench_press barbell_row back_squat] }.fetch(kind)
    ids.flat_map { |id| lift(id, 100, 8, days_ago:, sets: 3) }
  end

  def day_after(*kinds)
    sets = kinds.reverse.each_with_index.flat_map { |k, i| session(k, i + 1) }
    generator(history: History.new(sets:), split: :push_pull_legs_full).generate.day
  end

  def test_push_pull_legs_full_rotation
    assert_equal :pull, day_after(:push)
    assert_equal :legs, day_after(:push, :pull)
    assert_equal :push, day_after(:pull, :legs)
    assert_equal :full_body, day_after(:full, :push, :pull, :legs, :push, :pull, :legs)
  end

  def test_workouts_open_with_a_compound
    (1..10).each do |seed|
      first = generator(seed:, split: :full_body, duration_min: 45).generate.prescriptions.first
      assert first.exercise.compound?, "seed #{seed} opened with #{first.exercise.name}"
    end
  end
end
