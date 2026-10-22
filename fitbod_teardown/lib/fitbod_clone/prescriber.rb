# frozen_string_literal: true

module FitbodClone
  # Fitbod's "Capability Recommender": sets, reps, weight and rest for one exercise.
  #
  # Public behaviour reproduced here:
  # - goal-specific rep ranges (strength ~1-6, hypertrophy ~6-12, plus higher-rep work),
  # - intensity varies between sessions (daily undulation),
  # - load goes up after an easy session and down after a hard one (RIR feedback),
  # - progressive overload once the target reps are hit with reps to spare,
  # - optional warm-up ramps, skipped for bodyweight / timed / light lifts.
  class Prescriber
    Prescription = Struct.new(:exercise, :sets, :reps, :weight, :seconds, :rest_sec, :warmups,
                              :capability, keyword_init: true)
    WarmupSet = Struct.new(:weight, :reps)

    # [rep_low, rep_high, sets, rest_seconds]
    GOALS = {
      strength:    { compound: [3, 6, 4, 180],   isolation: [6, 10, 3, 120], rir: 2 },
      hypertrophy: { compound: [6, 10, 3, 120],  isolation: [10, 15, 3, 75], rir: 2 },
      endurance:   { compound: [12, 15, 3, 60],  isolation: [15, 20, 2, 45], rir: 3 },
      general:     { compound: [8, 12, 3, 90],   isolation: [10, 15, 3, 60], rir: 2 }
    }.freeze
    WAVE = %i[heavy medium light].freeze
    TOO_HARD_RIR = 0
    TOO_EASY_RIR = 4
    FEEDBACK_STEP = 0.05
    BAR_WEIGHT = 45.0
    BARBELL_RAMP = [[0.4, 10], [0.6, 5], [0.8, 3]].freeze
    SIMPLE_RAMP = [[0.5, 8]].freeze
    MIN_WARMUP_WORKING_WEIGHT = { barbell: 95.0 }.freeze

    def initialize(history:, capabilities:, settings:)
      @history = history
      @capabilities = capabilities
      @settings = settings
    end

    def wave
      WAVE[@history.session_count % WAVE.size]
    end

    def prescribe(exercise)
      low, high, sets, rest = GOALS.fetch(@settings.goal).fetch(exercise.mechanic)
      rir = GOALS.fetch(@settings.goal)[:rir]
      cap = @capabilities.estimate(exercise)
      rx = Prescription.new(exercise:, sets:, rest_sec: rest, warmups: [], capability: cap)

      case exercise.load_type
      when :weighted
        rx.reps = target_reps(low, high)
        rx.weight = working_weight(exercise, cap.value, rx.reps, rir)
        rx.warmups = warmups(exercise, rx.weight) if @settings.warmups
      when :bodyweight
        rx.reps = [(cap.value - rir).floor, 1].max
      when :timed
        rx.seconds = [((cap.value * 0.8) / 5).round * 5, 15].max
      end
      rx
    end

    private

    def target_reps(low, high)
      case wave
      when :heavy then low
      when :medium then ((low + high) / 2.0).round
      else high
      end
    end

    def working_weight(exercise, one_rm, reps, rir)
      weight = OneRepMax.weight_for(one_rm, reps + rir) * feedback_factor(exercise)
      weight = overload(exercise, weight, reps)
      round_down(weight, exercise.increment)
    end

    def feedback_factor(exercise)
      rirs = @history.last_session_sets(exercise.id).filter_map(&:rir)
      return 1.0 if rirs.empty?

      avg = rirs.sum.to_f / rirs.size
      return 1.0 - FEEDBACK_STEP if avg <= TOO_HARD_RIR
      return 1.0 + FEEDBACK_STEP if avg >= TOO_EASY_RIR

      1.0
    end

    # Beat last time: if the user hit at least today's reps at their last top weight with
    # reps to spare, add one increment.
    def overload(exercise, weight, reps)
      top = @history.last_session_sets(exercise.id).max_by { |s| [s.weight.to_f, s.reps.to_i] }
      return weight unless top && top.weight.to_f.positive?
      return weight unless top.reps.to_i >= reps && (top.rir.nil? || top.rir >= 1)

      [weight, top.weight + exercise.increment].max
    end

    def round_down(weight, increment)
      [(weight / increment).floor * increment, increment].max
    end

    def warmups(exercise, working)
      equip = exercise.load_equipment
      return [] unless exercise.compound? && working >= MIN_WARMUP_WORKING_WEIGHT.fetch(equip, 4 * exercise.increment)

      floor = equip == :barbell ? BAR_WEIGHT : exercise.increment
      ramp = equip == :barbell ? BARBELL_RAMP : SIMPLE_RAMP
      ramp.filter_map do |pct, reps|
        w = round_down(working * pct, exercise.increment)
        WarmupSet.new(w, reps) if w >= floor && w < working
      end.uniq(&:weight)
    end
  end
end
