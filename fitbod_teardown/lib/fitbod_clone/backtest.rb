# frozen_string_literal: true

module FitbodClone
  # Replays a real Fitbod history: before each logged exercise, predict the weight from
  # everything logged earlier, at the rep target the user actually did, and compare.
  # Logged weights are Fitbod's prescriptions plus whatever the user changed, so the error
  # is an upper bound on how far the engine is from Fitbod.
  class Backtest
    Case = Struct.new(:exercise, :time, :reps, :actual, :predicted, :last, :gap_days, keyword_init: true)

    def initialize(library:, history:, profile: UserProfile.new, settings: PlanSettings.new)
      @library = library
      @history = history
      @profile = profile
      @settings = settings
    end

    def cases
      @cases ||= @library.select(&:weighted?).flat_map { |ex| cases_for(ex) }
    end

    def summary(subset = cases)
      {
        n: subset.size,
        engine: errors(subset.map { |c| [c.predicted, c.actual] }),
        repeat_last_weight: errors(subset.map { |c| [c.last, c.actual] })
      }
    end

    private

    def cases_for(exercise)
      sessions = (@history.by_exercise[exercise.id] || [])
                 .select { |s| s.weight.to_f.positive? && s.reps.to_i.between?(1, 20) }
                 .group_by { |s| s.performed_at.to_date }.values
      sessions.each_cons(2).each_with_index.map do |(prev, cur), i|
        prior = sessions[0..i].flatten
        now = cur.first.performed_at
        reps = mode(cur.map(&:reps))
        Case.new(exercise: exercise.id, time: now, reps:, actual: mode(cur.map(&:weight)),
                 predicted: predict(exercise, prior, now, reps), last: mode(prev.map(&:weight)),
                 gap_days: ((now - prev.first.performed_at) / 86_400).round)
      end
    end

    def predict(exercise, prior, now, reps)
      history = History.new(sets: prior)
      caps = CapabilityEstimator.new(library: @library, history:, profile: @profile, now:)
      Prescriber.new(history:, capabilities: caps, settings: @settings).weight_for_reps(exercise, reps)
    end

    def errors(pairs)
      pct = pairs.map { |pred, actual| (pred - actual).abs / actual }.sort
      return {} if pct.empty?

      { median_error: pct[pct.size / 2].round(3),
        within_5pct: (pct.count { |e| e <= 0.05 }.to_f / pct.size).round(3),
        within_10pct: (pct.count { |e| e <= 0.10 }.to_f / pct.size).round(3) }
    end

    def mode(values) = values.tally.max_by { |v, n| [n, v] }.first
  end
end
