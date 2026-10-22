# frozen_string_literal: true

module FitbodClone
  # Fitbod's "Capability Recommender": sets, reps, weight and rest for one exercise.
  #
  # Calibrated against a 7-year Fitbod export (1,400+ sessions, see README section 7):
  # - rep target and set count are drawn per exercise from goal-specific distributions, the
  #   same for compound and isolation lifts, with no fixed heavy/medium/light order; the app
  #   re-rolls both when a workout is regenerated (seen in screenshots: 3 x 12 became 5 x 9),
  # - weight = capability (est. 1RM) read off the 1RM curve at that rep target, with no
  #   reps-in-reserve buffer: Fitbod prescribes right at your logged level,
  # - one warm-up at ~60% x 8 once the working weight reaches ~50 lb, on any loaded exercise,
  # - load goes down after a session rated too hard and up after one rated too easy.
  class Prescriber
    Prescription = Struct.new(:exercise, :sets, :reps, :weight, :seconds, :rest_sec, :warmups,
                              :capability, keyword_init: true)
    WarmupSet = Struct.new(:weight, :reps)

    # { value => relative frequency }. Hypertrophy ("Build Muscle") reps and sets are the
    # modal values logged per exercise-session in the export, odd targets included (the app
    # prescribed a 9 in a screenshot); 1-2 set sessions are left out as cut-short workouts.
    # The other goals are [Inferred] from Fitbod's published rep ranges.
    MEASURED_SETS = { 3 => 48, 4 => 44, 5 => 8 }.freeze
    GOALS = {
      hypertrophy: { reps: { 5 => 5, 6 => 3, 7 => 3, 8 => 21, 9 => 4, 10 => 22, 11 => 4, 12 => 18,
                             13 => 4, 14 => 2, 15 => 10 },
                     sets: MEASURED_SETS, rest: { compound: 120, isolation: 75 } },
      strength:    { reps: { 3 => 15, 4 => 15, 5 => 35, 6 => 25, 8 => 10 },
                     sets: { 4 => 60, 5 => 40 }, rest: { compound: 180, isolation: 120 } },
      endurance:   { reps: { 12 => 30, 15 => 40, 20 => 30 },
                     sets: { 2 => 30, 3 => 70 }, rest: { compound: 60, isolation: 45 } },
      general:     { reps: { 8 => 25, 10 => 35, 12 => 25, 15 => 15 },
                     sets: MEASURED_SETS, rest: { compound: 90, isolation: 60 } }
    }.freeze
    BODYWEIGHT_RIR = 0 # export: prescribed reps sit at the recent max-rep average
    TOO_HARD_RIR = 0
    TOO_EASY_RIR = 4
    FEEDBACK_STEP = 0.05
    WARMUP_MIN_WORKING_WEIGHT = 50.0
    WARMUP_RAMP = [[0.6, 8]].freeze

    def initialize(history:, capabilities:, settings:, rng: Random.new)
      @history = history
      @capabilities = capabilities
      @settings = settings
      @rng = rng
    end

    def prescribe(exercise)
      goal = GOALS.fetch(@settings.goal)
      cap = @capabilities.estimate(exercise)
      rx = Prescription.new(exercise:, sets: draw(goal[:sets]),
                            rest_sec: goal[:rest].fetch(exercise.mechanic), warmups: [], capability: cap)

      case exercise.load_type
      when :weighted
        rx.reps = draw(goal[:reps])
        rx.weight = weight_for_reps(exercise, rx.reps)
        rx.warmups = warmups(exercise, rx.weight) if @settings.warmups
      when :bodyweight
        rx.reps = [(cap.value - BODYWEIGHT_RIR).floor, 1].max
      when :timed
        rx.seconds = [((cap.value * 0.8) / 5).round * 5, 15].max
      end
      rx
    end

    def weight_for_reps(exercise, reps)
      one_rm = @capabilities.estimate(exercise).value
      round(OneRepMax.weight_for(one_rm, reps) * feedback_factor(exercise), exercise.increment)
    end

    private

    def draw(dist)
      roll = @rng.rand(dist.values.sum)
      dist.each { |value, w| return value if (roll -= w).negative? }
    end

    def feedback_factor(exercise)
      rirs = @history.last_session_sets(exercise.id).filter_map(&:rir)
      return 1.0 if rirs.empty?

      avg = rirs.sum.to_f / rirs.size
      return 1.0 - FEEDBACK_STEP if avg <= TOO_HARD_RIR
      return 1.0 + FEEDBACK_STEP if avg >= TOO_EASY_RIR

      1.0
    end

    def round(weight, increment)
      [(weight / increment).round * increment, increment].max
    end

    def warmups(exercise, working)
      return [] if working < WARMUP_MIN_WORKING_WEIGHT

      WARMUP_RAMP.filter_map do |pct, reps|
        w = round(working * pct, exercise.increment)
        WarmupSet.new(w, reps) if w < working
      end
    end
  end
end
