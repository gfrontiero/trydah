# frozen_string_literal: true

require "set"

module FitbodClone
  # Fitbod's "Exercise Selector". Public inputs: goal effectiveness, available equipment,
  # muscle recovery, requested variety, per-exercise feedback (More/Less/Exclude).
  #
  # Variety follows US 12,347,542: rank exercises, then take a random subset of the exercises
  # the user did in a recent window, sized by the selected variance level, and re-rank them.
  # Higher variance perturbs more exercises, so more new movements surface.
  class ExerciseSelector
    VARIABILITY = { consistent: 0.15, balanced: 0.4, varied: 0.75 }.freeze
    RECENT_WINDOW_DAYS = 14
    MIN_PRIMARY_RECOVERY = 30.0 # Fitbod "normally won't recommend" fully fatigued muscles
    FAMILIARITY_BONUS = 0.3     # per-user ranking favours exercises the user actually does
    FAMILIARITY_SATURATION = 4  # sessions
    SAME_FAMILY_PENALTY = 0.35

    def initialize(library:, history:, preferences:, settings:, now:, rng: Random.new)
      @library = library
      @history = history
      @preferences = preferences
      @settings = settings
      @now = now
      @variance = variance_factors(rng)
    end

    def candidates
      @candidates ||= @library.available(@settings.equipment).reject { |e| @preferences.excluded?(e.id) }
    end

    # => [[exercise, score], ...] best first, zero scores dropped.
    def rank(recovery, targets, exclude: [], planned_families: [])
      targets = targets.to_set
      candidates.filter_map do |ex|
        next if exclude.include?(ex.id)
        next unless ex.primary_muscles.any? { |m| targets.include?(m) }

        s = score(ex, recovery)
        s *= SAME_FAMILY_PENALTY if planned_families.include?(ex.family)
        [ex, s] if s.positive?
      end.sort_by { |ex, s| [-s, ex.id] }
    end

    def score(ex, recovery)
      return 0.0 if ex.primary_muscles.any? { |m| recovery[m] < MIN_PRIMARY_RECOVERY }

      ex.effectiveness *
        recovery_factor(ex, recovery) *
        @preferences.factor(ex.id) *
        familiarity(ex) *
        @variance.fetch(ex.id, 1.0)
    end

    private

    def recovery_factor(ex, recovery)
      total = ex.muscles.values.sum
      weighted = ex.muscles.sum { |m, a| a * recovery[m] / 100.0 }
      (weighted / total)**2
    end

    def familiarity(ex)
      days = (@history.by_exercise[ex.id] || []).map { |s| s.performed_at.to_date }.uniq.size
      1.0 + FAMILIARITY_BONUS * [days.to_f / FAMILIARITY_SATURATION, 1.0].min
    end

    def variance_factors(rng)
      level = VARIABILITY.fetch(@settings.variability)
      recent = @history.exercises_since(@now - RECENT_WINDOW_DAYS * 86_400).sort
      picked = recent.sample((level * recent.size).ceil, random: rng)
      picked.to_h { |id| [id, rng.rand(0.3..0.9)] }
    end
  end
end
