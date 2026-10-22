# frozen_string_literal: true

module FitbodClone
  # Per-muscle recovery on a 0-100% scale.
  #
  # Public facts: Fitbod scores fatigue from sets x reps x weight per muscle, folds in imported
  # cardio, and treats a muscle as fully recovered after six days at most, while typical
  # sessions clear in the 48-72h range. A linear recovery slope of 100% per 144h satisfies both:
  # a 100%-fatigued muscle takes six days, a typical ~40% session takes ~2.4 days.
  # The per-set constants below are our calibration, not Fitbod's.
  class RecoveryModel
    FULL_RECOVERY_HOURS = 144.0
    RECOVERY_PER_HOUR = 100.0 / FULL_RECOVERY_HOURS
    HARD_SET_FATIGUE = 10.0 # % added to a prime mover by one all-out set
    MIN_EFFORT = 0.35
    DEFAULT_RIR = 2
    CARDIO_MUSCLES = { quads: 1.0, hamstrings: 0.7, glutes: 0.7, calves: 1.0 }.freeze
    CARDIO_FATIGUE_PER_MIN = 0.5

    def initialize(library:, capabilities:)
      @library = library
      @capabilities = capabilities
    end

    # => { muscle => recovery % }
    def recovery(history, now, overrides: {})
      fatigue = Hash.new(0.0)
      last = nil
      events(history).each do |time, contribution|
        decay!(fatigue, (time - last) / 3600.0) if last
        contribution.each { |m, f| fatigue[m] = [fatigue[m] + f, 100.0].min }
        last = time
      end
      decay!(fatigue, (now - last) / 3600.0) if last
      MUSCLES.to_h { |m| [m, overrides.fetch(m) { (100.0 - fatigue[m]).round(1) }] }
    end

    # Fatigue a planned or logged set adds to each muscle.
    def set_fatigue(exercise, set)
      effort = effort(exercise, set)
      exercise.muscles.transform_values { |activation| HARD_SET_FATIGUE * activation * effort }
    end

    # Apply planned work to a recovery map (used while building a workout).
    def apply(recovery_map, exercise, sets)
      sets.reduce(recovery_map.dup) do |map, set|
        set_fatigue(exercise, set).each { |m, f| map[m] = [map[m] - f, 0.0].max }
        map
      end
    end

    private

    def events(history)
      lifts = history.sets.filter_map do |s|
        ex = @library[s.exercise_id]
        [s.performed_at, set_fatigue(ex, s)] if ex
      end
      cardio = history.cardio.map do |c|
        per = c.minutes * c.intensity * CARDIO_FATIGUE_PER_MIN
        [c.performed_at, CARDIO_MUSCLES.transform_values { |a| per * a }]
      end
      (lifts + cardio).sort_by(&:first)
    end

    def decay!(fatigue, hours)
      fatigue.each_key { |m| fatigue[m] = [fatigue[m] - hours * RECOVERY_PER_HOUR, 0.0].max }
    end

    # How close to failure the set was, 0.35..1.0.
    def effort(exercise, set)
      rir = set.rir || inferred_rir(exercise, set)
      (1.0 - 0.1 * rir).clamp(MIN_EFFORT, 1.0)
    end

    def inferred_rir(exercise, set)
      return DEFAULT_RIR unless exercise.weighted? && set.weight.to_f.positive?

      one_rm = @capabilities.estimate(exercise).value
      [OneRepMax.reps_at(one_rm, set.weight) - set.reps.to_i, 0.0].max
    end
  end
end
