# frozen_string_literal: true

module FitbodClone
  # Fitbod's blog cites Epley; its public Strength Tester uses Brzycki. We use Brzycki
  # in the low-rep range where it is most accurate and Epley above that.
  module OneRepMax
    BRZYCKI_MAX_REPS = 10
    MAX_ESTIMATION_REPS = 20 # sets beyond this say little about max strength

    module_function

    def estimate(weight, reps)
      return 0.0 if weight.nil? || weight <= 0 || reps.nil? || reps <= 0

      r = [reps, MAX_ESTIMATION_REPS].min
      return weight.to_f if r == 1

      r <= BRZYCKI_MAX_REPS ? weight * 36.0 / (37.0 - r) : weight * (1.0 + r / 30.0)
    end

    # Heaviest weight that can be lifted for `reps` given a 1RM (inverse of #estimate).
    def weight_for(one_rm, reps)
      r = reps.clamp(1, MAX_ESTIMATION_REPS)
      return one_rm.to_f if r == 1

      r <= BRZYCKI_MAX_REPS ? one_rm * (37.0 - r) / 36.0 : one_rm / (1.0 + r / 30.0)
    end

    # Reps possible at `weight` given a 1RM.
    def reps_at(one_rm, weight)
      return MAX_ESTIMATION_REPS.to_f if weight <= 0
      return 0.0 if weight > one_rm

      brzycki = 37.0 - 36.0 * weight / one_rm
      brzycki <= BRZYCKI_MAX_REPS ? brzycki : 30.0 * (one_rm / weight - 1.0)
    end
  end
end
