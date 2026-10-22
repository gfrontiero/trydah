# frozen_string_literal: true

require "set"

module FitbodClone
  MUSCLES = %i[
    chest shoulders triceps biceps forearms
    lats upper_back traps lower_back abs
    quads hamstrings glutes calves adductors abductors
  ].freeze

  # Coarse groups used by the "Fresh Muscle Groups" split and the recovery UI.
  MUSCLE_GROUPS = {
    chest:     %i[chest],
    back:      %i[lats upper_back traps lower_back],
    shoulders: %i[shoulders],
    arms:      %i[biceps triceps forearms],
    legs:      %i[quads hamstrings glutes calves adductors abductors],
    core:      %i[abs]
  }.freeze

  # Muscles with activation at or above this count as "primary" movers.
  PRIMARY_ACTIVATION = 0.8

  # Weight increments per equipment type (lb). Dumbbells are per hand. 5 lb everywhere
  # matched a real Fitbod export best (machines at 10 lb did worse in the backtest).
  INCREMENTS = {
    barbell: 5.0, ez_bar: 5.0, dumbbell: 5.0, kettlebell: 5.0,
    cable: 5.0, machine: 5.0
  }.freeze

  Exercise = Struct.new(
    :id, :name,
    :muscles,       # { muscle => activation 0..1 }, 1.0 = prime mover
    :equipment,     # all required; [] means bodyweight anywhere
    :mechanic,      # :compound or :isolation
    :load_type,     # :weighted, :bodyweight, :timed
    :effectiveness, # 0..1 prior on goal effectiveness (Fitbod mines this from logged workouts)
    :bw_ratio,      # reference 1RM / bodyweight for cold start (per hand for dumbbells)
    :family,        # movement family, used for cross-exercise capability transfer
    keyword_init: true
  ) do
    def primary_muscles
      muscles.select { |_, a| a >= PRIMARY_ACTIVATION }.keys
    end

    def compound? = mechanic == :compound
    def weighted? = load_type == :weighted

    def load_equipment
      (equipment & INCREMENTS.keys).first
    end

    def increment
      INCREMENTS.fetch(load_equipment, 5.0)
    end
  end

  class ExerciseLibrary
    include Enumerable

    def self.default
      new(DEFAULT_EXERCISES)
    end

    def initialize(exercises)
      @by_id = exercises.to_h { |e| [e.id, e] }
    end

    def each(&) = @by_id.each_value(&)
    def fetch(id) = @by_id.fetch(id)
    def [](id) = @by_id[id]

    def available(equipment)
      have = equipment.to_set
      select { |e| e.equipment.all? { |req| have.include?(req) } }
    end

    def siblings(exercise)
      select { |e| e.family == exercise.family && e.id != exercise.id }
    end
  end

  def self.ex(id, name, muscles, equipment, mechanic, load_type, effectiveness, bw_ratio, family)
    Exercise.new(id:, name:, muscles:, equipment:, mechanic:, load_type:,
                 effectiveness:, bw_ratio:, family:)
  end
  private_class_method :ex

  # A small seed library. Fitbod ships 1,000+ exercises; the shape is what matters here.
  DEFAULT_EXERCISES = [
    # Chest
    ex(:barbell_bench_press, "Barbell Bench Press", { chest: 1.0, triceps: 0.6, shoulders: 0.5 }, %i[barbell bench], :compound, :weighted, 0.95, 0.90, :horizontal_press),
    ex(:incline_db_bench_press, "Incline Dumbbell Bench Press", { chest: 1.0, shoulders: 0.6, triceps: 0.5 }, %i[dumbbell bench], :compound, :weighted, 0.85, 0.32, :horizontal_press),
    ex(:machine_chest_press, "Machine Chest Press", { chest: 1.0, triceps: 0.5, shoulders: 0.4 }, %i[machine], :compound, :weighted, 0.75, 0.80, :horizontal_press),
    ex(:push_up, "Push Up", { chest: 1.0, triceps: 0.6, shoulders: 0.4, abs: 0.3 }, [], :compound, :bodyweight, 0.70, nil, :horizontal_press),
    ex(:db_fly, "Dumbbell Fly", { chest: 1.0, shoulders: 0.3 }, %i[dumbbell bench], :isolation, :weighted, 0.65, 0.14, :chest_fly),
    ex(:cable_crossover, "Cable Crossover", { chest: 1.0, shoulders: 0.3 }, %i[cable], :isolation, :weighted, 0.65, 0.25, :chest_fly),
    # Shoulders
    ex(:overhead_press, "Barbell Overhead Press", { shoulders: 1.0, triceps: 0.6, upper_back: 0.3, abs: 0.3 }, %i[barbell], :compound, :weighted, 0.90, 0.55, :vertical_press),
    ex(:db_shoulder_press, "Dumbbell Shoulder Press", { shoulders: 1.0, triceps: 0.6 }, %i[dumbbell], :compound, :weighted, 0.85, 0.22, :vertical_press),
    ex(:lateral_raise, "Dumbbell Lateral Raise", { shoulders: 1.0, traps: 0.3 }, %i[dumbbell], :isolation, :weighted, 0.75, 0.08, :lateral_raise),
    ex(:face_pull, "Face Pull", { shoulders: 0.8, upper_back: 0.8, traps: 0.4 }, %i[cable], :isolation, :weighted, 0.70, 0.30, :rear_delt),
    # Arms
    ex(:tricep_pushdown, "Cable Tricep Pushdown", { triceps: 1.0 }, %i[cable], :isolation, :weighted, 0.75, 0.35, :triceps_ext),
    ex(:skull_crusher, "EZ-Bar Skull Crusher", { triceps: 1.0 }, %i[ez_bar bench], :isolation, :weighted, 0.70, 0.30, :triceps_ext),
    ex(:barbell_curl, "Barbell Curl", { biceps: 1.0, forearms: 0.4 }, %i[barbell], :isolation, :weighted, 0.80, 0.35, :curl),
    ex(:db_curl, "Dumbbell Bicep Curl", { biceps: 1.0, forearms: 0.4 }, %i[dumbbell], :isolation, :weighted, 0.80, 0.15, :curl),
    ex(:hammer_curl, "Hammer Curl", { biceps: 0.8, forearms: 0.8 }, %i[dumbbell], :isolation, :weighted, 0.70, 0.16, :curl),
    # Back
    ex(:pull_up, "Pull Up", { lats: 1.0, biceps: 0.6, upper_back: 0.5, forearms: 0.3 }, %i[pullup_bar], :compound, :bodyweight, 0.90, nil, :vertical_pull),
    ex(:lat_pulldown, "Lat Pulldown", { lats: 1.0, biceps: 0.5, upper_back: 0.4 }, %i[cable], :compound, :weighted, 0.85, 0.70, :vertical_pull),
    ex(:barbell_row, "Barbell Row", { upper_back: 1.0, lats: 0.8, biceps: 0.5, lower_back: 0.4 }, %i[barbell], :compound, :weighted, 0.90, 0.70, :horizontal_pull),
    ex(:db_row, "Single-Arm Dumbbell Row", { lats: 1.0, upper_back: 0.8, biceps: 0.5 }, %i[dumbbell bench], :compound, :weighted, 0.85, 0.30, :horizontal_pull),
    ex(:seated_cable_row, "Seated Cable Row", { upper_back: 1.0, lats: 0.8, biceps: 0.5 }, %i[cable], :compound, :weighted, 0.80, 0.65, :horizontal_pull),
    ex(:deadlift, "Deadlift", { hamstrings: 0.8, glutes: 1.0, lower_back: 1.0, traps: 0.6, quads: 0.5, forearms: 0.5 }, %i[barbell], :compound, :weighted, 0.95, 1.40, :hinge),
    ex(:back_extension, "Back Extension", { lower_back: 1.0, glutes: 0.6, hamstrings: 0.5 }, [], :isolation, :bodyweight, 0.60, nil, :back_ext),
    ex(:db_shrug, "Dumbbell Shrug", { traps: 1.0, forearms: 0.4 }, %i[dumbbell], :isolation, :weighted, 0.60, 0.40, :shrug),
    # Legs
    ex(:back_squat, "Back Squat", { quads: 1.0, glutes: 0.9, adductors: 0.5, lower_back: 0.4, hamstrings: 0.3 }, %i[barbell squat_rack], :compound, :weighted, 0.95, 1.15, :squat),
    ex(:goblet_squat, "Goblet Squat", { quads: 1.0, glutes: 0.8, adductors: 0.4, abs: 0.3 }, %i[dumbbell], :compound, :weighted, 0.75, 0.35, :squat),
    ex(:leg_press, "Leg Press", { quads: 1.0, glutes: 0.7, adductors: 0.4 }, %i[machine], :compound, :weighted, 0.85, 2.00, :squat),
    ex(:bodyweight_squat, "Bodyweight Squat", { quads: 1.0, glutes: 0.7 }, [], :compound, :bodyweight, 0.50, nil, :squat),
    ex(:romanian_deadlift, "Romanian Deadlift", { hamstrings: 1.0, glutes: 0.9, lower_back: 0.6 }, %i[barbell], :compound, :weighted, 0.90, 1.00, :hinge),
    ex(:walking_lunge, "Dumbbell Walking Lunge", { quads: 1.0, glutes: 0.9, hamstrings: 0.4, adductors: 0.4 }, %i[dumbbell], :compound, :weighted, 0.80, 0.20, :lunge),
    ex(:hip_thrust, "Barbell Hip Thrust", { glutes: 1.0, hamstrings: 0.5 }, %i[barbell bench], :compound, :weighted, 0.85, 1.20, :hip_thrust),
    ex(:leg_extension, "Leg Extension", { quads: 1.0 }, %i[machine], :isolation, :weighted, 0.65, 0.50, :knee_ext),
    ex(:leg_curl, "Lying Leg Curl", { hamstrings: 1.0, calves: 0.3 }, %i[machine], :isolation, :weighted, 0.70, 0.40, :knee_flex),
    ex(:calf_raise, "Standing Calf Raise", { calves: 1.0 }, %i[machine], :isolation, :weighted, 0.65, 0.90, :calf),
    ex(:hip_abduction, "Machine Hip Abduction", { abductors: 1.0, glutes: 0.5 }, %i[machine], :isolation, :weighted, 0.55, 0.60, :abduction),
    ex(:hip_adduction, "Machine Hip Adduction", { adductors: 1.0 }, %i[machine], :isolation, :weighted, 0.55, 0.60, :adduction),
    # Core
    ex(:plank, "Plank", { abs: 1.0, shoulders: 0.2 }, [], :isolation, :timed, 0.60, nil, :anti_extension),
    ex(:hanging_leg_raise, "Hanging Leg Raise", { abs: 1.0, forearms: 0.3 }, %i[pullup_bar], :isolation, :bodyweight, 0.70, nil, :hip_flexion),
    ex(:cable_crunch, "Cable Crunch", { abs: 1.0 }, %i[cable], :isolation, :weighted, 0.65, 0.50, :spinal_flexion)
  ].freeze
end
