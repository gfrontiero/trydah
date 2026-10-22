# frozen_string_literal: true

module FitbodClone
  # Approximation of Fitbod's mStrength / Strength Score. Public facts: a relative per-muscle
  # scale (not lb, not a percentile), at least 6 sets on a primary muscle before it is scored,
  # and the overall score is the mean of the muscle scores. Fitbod puts every exercise on one
  # scale with population statistics; we use the library's bodyweight ratios for that.
  class StrengthScore
    MIN_SETS = 6

    def initialize(library:, history:, profile:, capabilities:)
      @library = library
      @history = history
      @profile = profile
      @capabilities = capabilities
    end

    def muscle_scores
      MUSCLES.filter_map do |muscle|
        rows = scored_exercises(muscle)
        next if rows.sum { |_, _, n| n } < MIN_SETS

        weight_total = rows.sum { |_, a, _| a }
        [muscle, (rows.sum { |rel, a, _| rel * a } / weight_total * 100).round]
      end.to_h
    end

    def overall
      scores = muscle_scores.values
      scores.empty? ? nil : (scores.sum.to_f / scores.size).round
    end

    private

    # => [[relative strength, activation, set count], ...]
    def scored_exercises(muscle)
      @history.by_exercise.filter_map do |id, sets|
        ex = @library[id]
        next unless ex&.weighted? && ex.bw_ratio
        next unless ex.primary_muscles.include?(muscle)

        rel = @capabilities.estimate(ex).value / (@profile.bodyweight * ex.bw_ratio)
        [rel, ex.muscles[muscle], sets.size]
      end
    end
  end
end
