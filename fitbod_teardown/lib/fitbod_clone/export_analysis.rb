# frozen_string_literal: true

module FitbodClone
  # Measures Fitbod's prescription behaviour from an export: the numbers README section 7
  # calibrates against. Works on any user's export.
  class ExportAnalysis
    GAP_BUCKETS = [[7, "<=1w"], [14, "1-2w"], [28, "2-4w"], [42, "4-6w"], [56, "6-8w"], [84, "8-12w"],
                   [120, "12-17w"], [182, "17-26w"], [Float::INFINITY, "26w+"]].freeze

    def initialize(import)
      @library = import.library
      @history = import.history
      @warmups = import.warmups
    end

    def report
      [overview, rep_targets, sets_per_exercise, warmups, capability_after_time_off, variety, structure_by_year]
        .join("\n\n")
    end

    def overview
      days = @history.sets.map { |s| s.performed_at.to_date }
      "Overview: #{days.uniq.size} sessions, #{days.min} to #{days.max}, " \
        "#{@history.by_exercise.size} exercises, #{@history.sets.size} working sets, #{@warmups.size} warm-up sets"
    end

    def rep_targets
      modal = weighted_sessions.map { |sets| mode(sets.map(&:reps)) }
      "Rep target per exercise-session (loaded lifts):\n  " + share(modal, min: 0.01)
    end

    def sets_per_exercise
      counts = exercise_sessions.map(&:size)
      "Working sets per exercise:\n  " + share(counts, min: 0.01)
    end

    def warmups
      by_key = @warmups.group_by { |s| [s.exercise_id, s.performed_at.to_date] }
      rows = weighted_sessions.filter_map do |sets|
        working = sets.map(&:weight).max
        wu = by_key[[sets.first.exercise_id, sets.first.performed_at.to_date]] || []
        [working, wu.size, wu.map { |w| [w.weight / working, w.reps] }]
      end
      lines = rows.group_by { |w, _| [(w / 25).floor * 25, 300].min }.sort.map do |bucket, rs|
        format("  %3d+ lb: n=%-5d %s", bucket, rs.size, share(rs.map { |_, n| n }, prefix: "warm-ups="))
      end
      singles = rows.select { |_, n, _| n == 1 }.map { |*, ramp| ramp.first }
      pct = median(singles.map(&:first))
      reps = singles.empty? ? "-" : mode(singles.map(&:last))
      "Warm-up sets by working weight:\n#{lines.join("\n")}\n  single warm-up: median #{pct ? (pct * 100).round : '-'}% of working weight x #{reps}"
    end

    def capability_after_time_off
      ratios = Hash.new { |h, k| h[k] = [] }
      @history.by_exercise.each do |id, sets|
        ex = @library[id]
        next unless ex&.weighted?

        days = sets.select { |s| s.weight.to_f.positive? && s.reps.to_i.between?(1, 20) }
                   .group_by { |s| s.performed_at.to_date }.sort
        ema = nil
        days.each_with_index do |(day, ss), i|
          cap = ss.map { |s| OneRepMax.estimate(s.weight, s.reps) }.max
          if ema
            gap = (day - days[i - 1].first).to_i
            ratios[GAP_BUCKETS.find { |lim, _| gap <= lim }.last] << cap / ema
          end
          ema = ema ? CapabilityEstimator::SMOOTHING * cap + (1 - CapabilityEstimator::SMOOTHING) * ema : cap
        end
      end
      lines = GAP_BUCKETS.filter_map do |_, label|
        r = ratios[label]
        format("  %-7s n=%-5d %.3f", label, r.size, median(r)) unless r.empty?
      end
      "Logged capability vs prior average, by time since the exercise was last done:\n#{lines.join("\n")}"
    end

    def variety
      weeks = @history.sets.group_by { |s| s.performed_at.to_date.cwyear * 100 + s.performed_at.to_date.cweek }
                      .sort.map { |_, ss| ss.map(&:exercise_id).uniq }
      repeat = weeks.each_cons(5).map { |w| (w.last & w.first(4).flatten).size.to_f / w.last.size }
      gaps = exercise_sessions.group_by { |ss| ss.first.exercise_id }.values.flat_map do |list|
        list.map { |ss| ss.first.performed_at.to_date }.each_cons(2).map { |a, b| (b - a).to_i }
      end
      "Variety: #{(median(repeat).to_f * 100).round}% of a week's exercises were done in the previous 4 active weeks; " \
        "median #{median(gaps)} days between repeats of the same exercise"
    end

    def structure_by_year
      lines = @history.sessions.group_by { |day, _| day.year }.sort.map do |year, sessions|
        weeks = sessions.map { |day, _| day.cweek }.uniq.size
        ex = sessions.map { |_, ss| ss.map(&:exercise_id).uniq.size }
        format("  %d: %3d sessions, %.1f per active week, median %d exercises / %d sets per session",
               year, sessions.size, sessions.size.to_f / weeks, median(ex), median(sessions.map { |_, ss| ss.size }))
      end
      "Session structure:\n#{lines.join("\n")}"
    end

    private

    def exercise_sessions
      @exercise_sessions ||= @history.sets.group_by { |s| [s.exercise_id, s.performed_at.to_date] }.values
    end

    def weighted_sessions
      exercise_sessions.filter_map do |ss|
        loaded = ss.select { |s| s.weight.to_f.positive? }
        loaded if loaded.any? && @library[ss.first.exercise_id]&.weighted?
      end
    end

    def share(values, min: 0.0, prefix: "")
      n = values.size.to_f
      values.tally.sort.filter_map { |v, c| "#{prefix}#{v}: #{(100 * c / n).round}%" if c / n >= min }.join("  ")
    end

    def median(values)
      return nil if values.empty?

      values.sort[values.size / 2]
    end

    def mode(values) = values.tally.max_by { |v, n| [n, v] }.first
  end
end
