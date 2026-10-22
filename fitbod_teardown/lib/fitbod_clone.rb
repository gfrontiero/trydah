# frozen_string_literal: true

require "date"
require_relative "fitbod_clone/exercise_library"
require_relative "fitbod_clone/history"
require_relative "fitbod_clone/one_rep_max"
require_relative "fitbod_clone/capability_estimator"
require_relative "fitbod_clone/recovery_model"
require_relative "fitbod_clone/exercise_selector"
require_relative "fitbod_clone/prescriber"
require_relative "fitbod_clone/workout_generator"
require_relative "fitbod_clone/strength_score"

# Clean-room reconstruction of Fitbod's workout engine from public sources.
# See ../README.md for the teardown and where each piece comes from.
module FitbodClone
  module_function

  def format_workout(workout)
    lines = ["#{workout.day.to_s.tr('_', ' ').capitalize} (~#{workout.est_minutes} min)"]
    workout.prescriptions.each_with_index do |rx, i|
      lines << "#{i + 1}. #{rx.exercise.name}  [#{rx.capability.source}]"
      rx.warmups.each { |w| lines << "     warm-up  #{fmt(w.weight)} lb x #{w.reps}" }
      lines << "     #{rx.sets} x #{dose(rx)}  rest #{rx.rest_sec}s"
    end
    lines.join("\n")
  end

  def dose(rx)
    case rx.exercise.load_type
    when :weighted
      per_hand = rx.exercise.load_equipment == :dumbbell ? " each" : ""
      "#{rx.reps} @ #{fmt(rx.weight)} lb#{per_hand}"
    when :bodyweight then "#{rx.reps} reps"
    when :timed then "#{rx.seconds}s"
    end
  end

  def fmt(n) = (n % 1).zero? ? n.to_i.to_s : n.round(1).to_s
end
