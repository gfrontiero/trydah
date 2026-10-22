# frozen_string_literal: true

require "time"

module FitbodClone
  # One logged set. `rir` = reps in reserve the user reported (optional).
  LoggedSet = Struct.new(:exercise_id, :weight, :reps, :seconds, :rir, :performed_at, keyword_init: true)

  # Cardio imported from Apple Health / Strava etc. Fitbod counts it toward leg fatigue.
  CardioSession = Struct.new(:minutes, :intensity, :performed_at, keyword_init: true) # intensity 0..1

  UserProfile = Struct.new(:bodyweight, :experience, :sex, keyword_init: true) do
    def initialize(bodyweight: 170.0, experience: :intermediate, sex: :male) = super
  end

  # Mirrors Fitbod's Gym Profile + My Plan settings.
  PlanSettings = Struct.new(
    :goal,          # :strength, :hypertrophy, :endurance, :general
    :split,         # :fresh_muscle_groups, :push_pull_legs, :upper_lower, :upper_lower_full, :full_body
    :duration_min,
    :workouts_per_week,
    :equipment,     # Array of equipment symbols
    :variability,   # :consistent, :balanced, :varied
    :warmups,       # true/false
    :emphasis,      # { muscle => factor }: 1.0 neutral, >1 prioritise, <1 maintain
    :available_weights, # { :dumbbell => [lb, ...], :kettlebell => [...], :plates => [...], :barbell => [45] }
    keyword_init: true
  ) do
    def initialize(goal: :hypertrophy, split: :fresh_muscle_groups, duration_min: 60, workouts_per_week: 4,
                   equipment: %i[barbell dumbbell bench squat_rack cable machine pullup_bar ez_bar],
                   variability: :balanced, warmups: true, emphasis: {}, available_weights: {})
      super
    end

    # Activation-weighted mean emphasis over the muscles an exercise trains (1.0 = neutral).
    def emphasis_factor(exercise)
      return 1.0 if emphasis.empty?

      exercise.muscles.sum { |m, a| a * emphasis.fetch(m, 1.0) } / exercise.muscles.values.sum
    end

    def mean_emphasis(muscles)
      return 1.0 if muscles.empty?

      muscles.sum { |m| emphasis.fetch(m, 1.0) } / muscles.size
    end
  end

  # Recommend More / Less / Exclude, keyed by exercise id.
  class Preferences
    FACTORS = { more: 1.5, less: 0.7 }.freeze # help center: More = +40-60%, Less = -20-40%

    def initialize(map = {})
      @map = map
    end

    def excluded?(id) = @map[id] == :exclude
    def factor(id) = FACTORS.fetch(@map[id], 1.0)
  end

  class History
    attr_reader :sets, :cardio

    def initialize(sets: [], cardio: [])
      @sets = sets.sort_by(&:performed_at)
      @cardio = cardio.sort_by(&:performed_at)
    end

    def for_exercise(id)
      sets.select { |s| s.exercise_id == id }
    end

    def by_exercise
      @by_exercise ||= sets.group_by(&:exercise_id)
    end

    def sessions
      sets.group_by { |s| s.performed_at.to_date }
    end

    def session_count
      sets.map { |s| s.performed_at.to_date }.uniq.size
    end

    def exercises_since(time)
      sets.select { |s| s.performed_at >= time }.map(&:exercise_id).uniq
    end

    def last_session_sets(id)
      mine = for_exercise(id)
      return [] if mine.empty?

      day = mine.last.performed_at.to_date
      mine.select { |s| s.performed_at.to_date == day }
    end
  end
end
