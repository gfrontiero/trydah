# frozen_string_literal: true

module FitbodClone
  # Reconstruction of US 12,109,454 "Determining a user's current exercise capability":
  #   1. partition the exercise history into time periods (here: training days),
  #   2. compute an aggregate capability per period (strongest set that day),
  #   3. take an exponentially smoothed moving average across periods (claim 5),
  #   4. decay it once a threshold time has passed since the user last trained it (claim 4).
  # Cold start follows US 12,551,757: transfer from a related exercise via a strength ratio,
  # otherwise fall back to a population prior from the user's profile.
  class CapabilityEstimator
    Estimate = Struct.new(:value, :source, keyword_init: true) # :history, :transfer, :population

    # Fitted to a 7-year Fitbod export (README section 7): alpha 0.7 predicts the next
    # prescribed weight best, and capability holds for ~6 weeks off an exercise, then fades
    # just under 1% a week (about -14% at six months).
    SMOOTHING = 0.7           # weight of the newest period in the moving average
    DECAY_GRACE_DAYS = 42
    DECAY_PER_WEEK = 0.009
    MAX_DECAY = 0.15
    TRANSFER_DISCOUNT = 0.9   # be conservative when borrowing from a sibling exercise
    COLD_START_DISCOUNT = 0.8 # help center: first-time exercises start conservative
    DEFAULT_BW_RATIO = 0.3    # for imported exercises with no strength-standard ratio

    EXPERIENCE = { beginner: 0.6, intermediate: 1.0, advanced: 1.35 }.freeze
    SEX = { male: 1.0, female: 0.7 }.freeze
    BODYWEIGHT_START_REPS = { beginner: 6, intermediate: 12, advanced: 20 }.freeze
    TIMED_START_SECONDS = { beginner: 30, intermediate: 60, advanced: 90 }.freeze

    def initialize(library:, history:, profile:, now:)
      @library = library
      @history = history
      @profile = profile
      @now = now
      @cache = {}
    end

    # For weighted exercises the value is an estimated 1RM; for bodyweight it is max reps
    # in a set; for timed exercises it is max seconds.
    def estimate(exercise)
      @cache[exercise.id] ||= from_history(exercise) || transfer(exercise) || population(exercise)
    end

    def known?(exercise)
      @history.by_exercise.key?(exercise.id)
    end

    private

    def from_history(exercise, apply_decay: true)
      sets = @history.by_exercise[exercise.id]
      return nil if sets.nil? || sets.empty?

      per_period = sets.group_by { |s| s.performed_at.to_date }.sort.map do |_day, day_sets|
        day_sets.map { |s| set_capability(exercise, s) }.max
      end
      smoothed = per_period.reduce { |avg, x| SMOOTHING * x + (1 - SMOOTHING) * avg }
      smoothed *= decay_factor(sets.last.performed_at) if apply_decay
      Estimate.new(value: smoothed, source: :history)
    end

    def set_capability(exercise, set)
      case exercise.load_type
      when :weighted then OneRepMax.estimate(set.weight, set.reps.to_i + set.rir.to_i)
      when :bodyweight then set.reps.to_f + set.rir.to_i
      when :timed then set.seconds.to_f
      end
    end

    def decay_factor(last_time)
      days = (@now - last_time) / 86_400.0
      return 1.0 if days <= DECAY_GRACE_DAYS

      1.0 - [DECAY_PER_WEEK * (days - DECAY_GRACE_DAYS) / 7.0, MAX_DECAY].min
    end

    def transfer(exercise)
      return nil unless exercise.weighted? && exercise.bw_ratio

      @library.siblings(exercise).each do |sib|
        next unless sib.weighted? && sib.bw_ratio

        known = from_history(sib)
        next unless known

        value = known.value * exercise.bw_ratio / sib.bw_ratio * TRANSFER_DISCOUNT
        return Estimate.new(value:, source: :transfer)
      end
      nil
    end

    # Stand-in for Fitbod's population model (the patent describes a random forest over
    # profile features); a strength-standards table gives the same shape of answer.
    def population(exercise)
      exp = @profile.experience
      value =
        case exercise.load_type
        when :weighted
          @profile.bodyweight * (exercise.bw_ratio || DEFAULT_BW_RATIO) * EXPERIENCE.fetch(exp) * SEX.fetch(@profile.sex) * COLD_START_DISCOUNT
        when :bodyweight then BODYWEIGHT_START_REPS.fetch(exp).to_f
        when :timed then TIMED_START_SECONDS.fetch(exp).to_f
        end
      Estimate.new(value:, source: :population)
    end
  end
end
