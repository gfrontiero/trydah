# frozen_string_literal: true

require "yaml"

module FitbodClone
  # A training plan in YAML: Fitbod's My Plan settings plus per-muscle emphasis and
  # exercise preferences. Claude edits it from the user's goals and body photos
  # (.claude/skills/fitbod-coach/SKILL.md); bin/workout turns it into today's workout.
  class Plan
    SPLITS = %i[upper_lower_full push_pull_legs_full upper_lower push_pull_legs full_body fresh_muscle_groups].freeze
    EMPHASIS_RANGE = (0.5..2.0)

    attr_reader :path

    def self.load(path) = new(YAML.safe_load_file(path, permitted_classes: [Date]), path)

    def initialize(data, path = nil)
      @data = data || {}
      @path = path
      validate!
    end

    def export_path
      file = @data.fetch("export")
      return file if file.start_with?("/") || @path.nil?

      File.expand_path(file, File.join(File.dirname(@path), ".."))
    end

    def profile
      UserProfile.new(bodyweight: @data.fetch("bodyweight_lb", 170).to_f,
                      experience: @data.fetch("experience", "intermediate").to_sym,
                      sex: @data.fetch("sex", "male").to_sym)
    end

    # Equipment = what the user trained with in the last N days, unless the plan lists it.
    def settings(library:, history:, now:)
      equipment = @data["equipment"]&.map(&:to_sym) || begin
        since = now - @data.fetch("equipment_from_recent_days", 90) * 86_400
        history.exercises_since(since).flat_map { |id| library.fetch(id).equipment }.uniq
      end
      PlanSettings.new(
        goal: goal, split: split,
        duration_min: @data.fetch("duration_min", 60), workouts_per_week: @data.fetch("workouts_per_week", 4),
        equipment:, variability: @data.fetch("variability", "balanced").to_sym,
        warmups: @data.fetch("warmups", true), emphasis:, available_weights:
      )
    end

    def preferences(library)
      by_name = library.to_h { |e| [e.name.downcase, e.id] }
      map = {}
      { "more" => :more, "less" => :less, "exclude" => :exclude }.each do |key, pref|
        Array(@data.dig("preferences", key)).each do |name|
          id = by_name[name.downcase] or raise ArgumentError, "#{@path}: unknown exercise #{name.inspect} under preferences.#{key}"
          map[id] = pref
        end
      end
      Preferences.new(map)
    end

    def goal = @data.fetch("goal", "build_muscle").to_sym
    def split = @data.fetch("split", "fresh_muscle_groups").to_sym
    def emphasis = (@data["emphasis"] || {}).to_h { |m, f| [m.to_sym, f.to_f] }

    def available_weights
      (@data["available_weights"] || {}).to_h { |equip, list| [equip.to_sym, Array(list).map(&:to_f).sort] }
    end

    private

    def validate!
      Prescriber.goal_config(goal)
    rescue KeyError
      goals = Prescriber::GOALS.keys + Prescriber::GOAL_ALIASES.keys
      raise ArgumentError, "#{@path}: unknown goal #{goal.inspect}; use one of #{goals.join(', ')}"
    else
      raise ArgumentError, "#{@path}: unknown split #{split.inspect}; use one of #{SPLITS.join(', ')}" unless SPLITS.include?(split)

      emphasis.each do |muscle, factor|
        raise ArgumentError, "#{@path}: unknown muscle #{muscle.inspect}; use #{MUSCLES.join(', ')}" unless MUSCLES.include?(muscle)
        raise ArgumentError, "#{@path}: emphasis for #{muscle} must be within #{EMPHASIS_RANGE}" unless EMPHASIS_RANGE.cover?(factor)
      end
    end
  end
end
