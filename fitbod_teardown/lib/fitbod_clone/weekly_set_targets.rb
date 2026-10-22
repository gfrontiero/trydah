# frozen_string_literal: true

module FitbodClone
  # Fitbod's "Weekly Set Targets" screen: working sets this week against a target for Push,
  # Pull and Leg muscles, with a ring showing overall progress.
  #
  # [Observed] in screenshots: progress is the mean of the three group percentages
  # (24.5/53, 10.5/29, 19.5/42 -> 43%), weeks start on the user's chosen day, and counts come
  # in half sets. [Inferred]: a set counts 1 for a group it works as a prime mover and 0.5
  # for a group it only works as a secondary mover. Targets scale with workouts per week and
  # duration, split in the proportions of the one configuration seen (7 x 45 min, Build Muscle).
  class WeeklySetTargets
    GROUPS = {
      push: %i[chest shoulders triceps],
      pull: %i[lats upper_back traps biceps forearms lower_back],
      legs: %i[quads hamstrings glutes calves adductors abductors]
    }.freeze
    OBSERVED = { push: 53, pull: 29, legs: 42 }.freeze
    OBSERVED_MINUTES = 7 * 45
    SECONDARY_ACTIVATION = 0.3

    def initialize(library:, history:, settings:, week_start: :sunday)
      @library = library
      @history = history
      @settings = settings
      @week_start = Date::DAYNAMES.index(week_start.to_s.capitalize)
    end

    def targets
      scale = @settings.workouts_per_week * @settings.duration_min / OBSERVED_MINUTES.to_f
      OBSERVED.to_h { |group, t| [group, (t * scale * @settings.mean_emphasis(GROUPS[group])).round] }
    end

    def completed(now)
      start = now.to_date - ((now.to_date.wday - @week_start) % 7)
      sets = @history.sets.select { |s| s.performed_at.to_date >= start && s.performed_at <= now }
      GROUPS.to_h { |group, muscles| [group, sets.sum { |s| credit(s, muscles) }] }
    end

    def progress(now)
      done = completed(now)
      ratios = targets.map { |group, target| [done[group] / target.to_f, 1.0].min }
      (100 * ratios.sum / ratios.size).round
    end

    private

    def credit(set, muscles)
      ex = @library[set.exercise_id] or return 0.0
      worked = ex.muscles.select { |m, _| muscles.include?(m) }
      return 0.0 if worked.empty?
      return 1.0 if worked.values.max >= PRIMARY_ACTIVATION
      return 0.5 if worked.values.max >= SECONDARY_ACTIVATION

      0.0
    end
  end
end
