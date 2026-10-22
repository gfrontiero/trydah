# frozen_string_literal: true

module FitbodClone
  class WorkoutGenerator
    Workout = Struct.new(:day, :target_muscles, :prescriptions, :recovery, :est_minutes, keyword_init: true)

    SET_SECONDS = 45
    TRANSITION_SECONDS = 90
    WARMUP_SET_SECONDS = 60
    MIN_EXERCISES = 3
    MAX_EXERCISES = 10

    PUSH_PULL_LEGS = {
      push: %i[chest shoulders triceps],
      pull: %i[lats upper_back traps biceps forearms lower_back],
      legs: %i[quads hamstrings glutes calves adductors abductors abs]
    }.freeze
    UPPER_LOWER = {
      upper: %i[chest shoulders triceps biceps forearms lats upper_back traps],
      lower: %i[quads hamstrings glutes calves adductors abductors lower_back abs]
    }.freeze
    # "Upper/Lower x3 + Full Body": in the export, sessions alternate upper/lower, with a
    # mostly-upper mixed day roughly every seventh session.
    FULL_BODY_EVERY = 6         # upper/lower sessions between full-body days
    PURE_SESSION_SHARE = 0.9    # share of sets on one half for a session to count as U or L

    def initialize(library:, history:, profile:, settings:, preferences: Preferences.new,
                   now: Time.now, recovery_overrides: {}, rng: Random.new)
      @library = library
      @history = history
      @settings = settings
      @now = now
      @overrides = recovery_overrides
      @capabilities = CapabilityEstimator.new(library:, history:, profile:, now:)
      @recovery_model = RecoveryModel.new(library:, capabilities: @capabilities)
      @selector = ExerciseSelector.new(library:, history:, preferences:, settings:, now:, rng:)
      @prescriber = Prescriber.new(history:, capabilities: @capabilities, settings:, rng:)
    end

    def recovery
      @recovery ||= @recovery_model.recovery(@history, @now, overrides: @overrides)
    end

    def generate
      day, targets = split_targets
      plan = []
      projected = recovery
      seconds = 0
      budget = @settings.duration_min * 60

      while plan.size < MAX_EXERCISES
        ranked = @selector.rank(projected, targets, exclude: plan.map { |rx| rx.exercise.id },
                                                    planned_families: plan.map { |rx| rx.exercise.family })
        break if ranked.empty?

        rx = @prescriber.prescribe(ranked.first.first)
        cost = seconds_for(rx)
        break if seconds + cost > budget && plan.size >= MIN_EXERCISES

        plan << rx
        seconds += cost
        # Count this exercise's fatigue before picking the next one, so the workout spreads
        # across muscles instead of stacking four chest presses.
        projected = @recovery_model.apply(projected, rx.exercise, planned_sets(rx))
      end

      ordered = plan.each_with_index.sort_by { |rx, i| [rx.exercise.compound? ? 0 : 1, i] }.map(&:first)
      Workout.new(day:, target_muscles: targets, prescriptions: ordered, recovery:,
                  est_minutes: (seconds / 60.0).round)
    end

    private

    def split_targets
      case @settings.split
      when :full_body then [:full_body, MUSCLES]
      when :push_pull_legs then freshest_day(PUSH_PULL_LEGS)
      when :upper_lower then freshest_day(UPPER_LOWER)
      when :upper_lower_full then upper_lower_full_day
      when :fresh_muscle_groups
        groups = MUSCLE_GROUPS.max_by(2) { |_, ms| mean_recovery(ms) }
        [groups.map(&:first).join("+").to_sym, groups.flat_map(&:last)]
      else raise ArgumentError, "unknown split #{@settings.split}"
      end
    end

    # Rotating splits pick the day whose muscles are most recovered, which rotates naturally.
    def freshest_day(days)
      days.max_by { |_, ms| mean_recovery(ms) }
    end

    def upper_lower_full_day
      kinds = @history.sessions.sort.map { |_, sets| self.class.session_kind(@library, sets) }.compact
      since_full = kinds.reverse.take_while { |k| k != :full_body }
      return [:full_body, MUSCLES] if kinds.include?(:full_body) && since_full.size >= FULL_BODY_EVERY

      last = kinds.reverse.find { |k| k != :full_body }
      day = last == :upper ? :lower : :upper
      [day, UPPER_LOWER.fetch(day)]
    end

    # :upper, :lower or :full_body by where the session's sets landed (abs count for neither).
    def self.session_kind(library, sets)
      upper = lower = 0
      sets.each do |s|
        prime = library[s.exercise_id]&.primary_muscles || []
        upper += 1 if prime.intersect?(UPPER_LOWER[:upper])
        lower += 1 if prime.intersect?(UPPER_LOWER[:lower] - %i[abs])
      end
      total = upper + lower
      return nil if total.zero?
      return :upper if upper >= PURE_SESSION_SHARE * total
      return :lower if lower >= PURE_SESSION_SHARE * total

      :full_body
    end

    def mean_recovery(muscles)
      muscles.sum { |m| recovery[m] } / muscles.size
    end

    def seconds_for(rx)
      work = rx.sets * (SET_SECONDS + rx.rest_sec)
      work + rx.warmups.size * WARMUP_SET_SECONDS + TRANSITION_SECONDS
    end

    def planned_sets(rx)
      Array.new(rx.sets) do
        LoggedSet.new(exercise_id: rx.exercise.id, weight: rx.weight, reps: rx.reps,
                      seconds: rx.seconds, rir: RecoveryModel::DEFAULT_RIR, performed_at: @now)
      end
    end
  end
end
