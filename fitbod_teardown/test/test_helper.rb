# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../lib/fitbod_clone"

module TestHelper
  include FitbodClone

  NOW = Time.new(2026, 10, 22, 18, 0, 0)
  DAY = 86_400

  def library = ExerciseLibrary.default
  def profile = UserProfile.new(bodyweight: 180, experience: :intermediate)

  def lift(id, weight, reps, days_ago:, rir: nil, sets: 1)
    Array.new(sets) do |i|
      LoggedSet.new(exercise_id: id, weight:, reps:, rir:, performed_at: NOW - days_ago * DAY + i * 120)
    end
  end

  def capabilities(history, now: NOW)
    CapabilityEstimator.new(library:, history:, profile:, now:)
  end

  def generator(history: History.new, now: NOW, preferences: Preferences.new, seed: 1, **settings)
    WorkoutGenerator.new(library:, history:, profile:, settings: PlanSettings.new(**settings),
                         preferences:, now:, rng: Random.new(seed))
  end
end
