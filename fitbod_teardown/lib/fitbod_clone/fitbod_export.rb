# frozen_string_literal: true

require "csv"
require "time"

module FitbodClone
  # Reads Fitbod's "Export Workout Data" CSV:
  #   Date,Exercise,Reps,Weight(kg),Duration(s),Distance(m),Incline,Resistance,isWarmup,Note,multiplier
  # Weights are stored in kg even for lb users (180 lb -> 81.6466 kg), so we convert back.
  # `multiplier` is Fitbod's volume multiplier: 1 barbell/machine, 2 dumbbell pairs,
  # 4 alternating unilateral dumbbell work, 0 timed/cardio.
  #
  # Every exercise name becomes an Exercise; muscles, equipment and mechanic come from
  # keyword rules (first match wins), which cover Fitbod's naming well but not perfectly.
  class FitbodExport
    LB_PER_KG = 1 / 0.45359237

    Import = Struct.new(:library, :history, :warmups, :skipped, keyword_init: true)
    Row = Struct.new(:time, :name, :reps, :lb, :seconds, :meters, :warmup, :multiplier, keyword_init: true)

    CARDIO = /\b(hiking|running|run|walking|walk|cycling|bike|elliptical|stair stepper|stairmaster|swim|rowing machine|jump rope|treadmill)\b/i
    MOBILITY = /stretch|pose|\bdog\b|child|cobra|reach behind|foam roll|rotation|circles|vacuum|open book|cat cow/i

    # [pattern, muscles, mechanic, family]
    RULES = [
      [/calf/i, { calves: 1.0 }, :isolation, :calf],
      [/shrug/i, { traps: 1.0, forearms: 0.4 }, :isolation, :shrug],
      [/abduct/i, { abductors: 1.0, glutes: 0.5 }, :isolation, :abduction],
      [/adduct/i, { adductors: 1.0 }, :isolation, :adduction],
      [/side leg raise|side[- ]lying leg/i, { abductors: 1.0, glutes: 0.5 }, :isolation, :abduction],
      [/leg crossover|scissor crossover|donkey kick|fire hydrant|clamshell|(single|straight) leg kickback|glute kickback|kickback machine/i,
       { glutes: 1.0, hamstrings: 0.3 }, :isolation, :glute_iso],
      [/glute ham raise|nordic/i, { hamstrings: 1.0, glutes: 0.5 }, :isolation, :knee_flex],
      [/side bridge|plank|crunch|sit ?up|leg raise|knee raise|knee tuck|scissor kick|\bab\b|rollout|russian twist|v-up|toe touch|dead bug|mountain climber|bicycle|flutter|hollow|woodchop|pallof|oblique|side bend|jackknife|windshield/i,
       { abs: 1.0 }, :isolation, :core],
      [/hip thrust|glute bridge|hip bridge|(?<!side )bridge|kickback.*glute|glute.*kickback|frog pump/i,
       { glutes: 1.0, hamstrings: 0.5 }, :compound, :hip_thrust],
      [/good morning/i, { hamstrings: 1.0, lower_back: 0.8, glutes: 0.8 }, :compound, :hinge],
      [/hyperextension|superman|back extension/i, { lower_back: 1.0, glutes: 0.6, hamstrings: 0.5 }, :isolation, :back_ext],
      [/romanian|rdl|stiff[- ]leg/i, { hamstrings: 1.0, glutes: 0.9, lower_back: 0.6 }, :compound, :hinge],
      [/deadlift|rack pull/i, { glutes: 1.0, lower_back: 1.0, hamstrings: 0.8, traps: 0.6, quads: 0.5, forearms: 0.5 }, :compound, :deadlift],
      [/hamstring|leg curl/i, { hamstrings: 1.0 }, :isolation, :knee_flex],
      [/leg extension/i, { quads: 1.0 }, :isolation, :knee_ext],
      [/lunge|step ?up|split squat|kneel to stand/i, { quads: 1.0, glutes: 0.9, hamstrings: 0.4, adductors: 0.4 }, :compound, :lunge],
      [/squat|leg press|wall sit|hack/i, { quads: 1.0, glutes: 0.8, adductors: 0.4 }, :compound, :squat],
      [/pull ?up|chin ?up|pulldown|pullover|muscle up/i, { lats: 1.0, biceps: 0.6, upper_back: 0.5 }, :compound, :vertical_pull],
      [/rear delt|face pull|reverse fly|band pull apart/i, { shoulders: 0.8, upper_back: 0.8, traps: 0.3 }, :isolation, :rear_delt],
      [/upright row/i, { shoulders: 1.0, traps: 0.6 }, :compound, :lateral_raise],
      [/\brow\b|inverted row/i, { upper_back: 1.0, lats: 0.8, biceps: 0.5 }, :compound, :horizontal_pull],
      [/hammer curl|reverse curl|wrist|farmer|plate pinch/i, { forearms: 1.0, biceps: 0.6 }, :isolation, :forearm],
      [/curl/i, { biceps: 1.0, forearms: 0.4 }, :isolation, :curl],
      [/close[- ]grip|\bdips?\b|diamond push|tricep push ?up/i, { triceps: 1.0, chest: 0.6, shoulders: 0.4 }, :compound, :triceps_press],
      [/tricep|skull ?crusher|kickback|pushdown|french press/i, { triceps: 1.0 }, :isolation, :triceps_ext],
      [/shoulder press|overhead press|military|arnold|push press|landmine press|pike push/i,
       { shoulders: 1.0, triceps: 0.6 }, :compound, :vertical_press],
      [/raise|scaption|upright row/i, { shoulders: 1.0, traps: 0.3 }, :isolation, :lateral_raise],
      [/\bfly\b|flye|crossover|pec deck/i, { chest: 1.0, shoulders: 0.3 }, :isolation, :chest_fly],
      [/bench|chest press|push ?up|floor press|svend/i, { chest: 1.0, triceps: 0.6, shoulders: 0.5 }, :compound, :horizontal_press]
    ].freeze

    EQUIPMENT = [
      [/ez[- ]?bar/i, :ez_bar], [/dumbbell/i, :dumbbell], [/kettlebell/i, :kettlebell],
      [/cable|pulldown|face pull|rope/i, :cable],
      [/machine|leg press|leg extension|hamstrings? curl|leg curl|smith|calf press|hack|pec deck|assisted/i, :machine],
      [/barbell|bench press|squat|deadlift|good morning|hip thrust|military|shoulder press|clean|snatch/i, :barbell],
      [/pull ?up|chin ?up|hanging|muscle up/i, :pullup_bar]
    ].freeze

    def self.load(path) = new(CSV.read(path, headers: true, encoding: "bom|utf-8")).import

    def initialize(table)
      @rows = table.select { |r| r["Date"] }.map { |r| parse(r) }.sort_by(&:time)
    end

    def import
      groups = @rows.group_by(&:name)
      skipped = []
      exercises = groups.filter_map do |name, rows|
        ex = build_exercise(name, rows, groups)
        skipped << name unless ex
        ex
      end
      library = ExerciseLibrary.new(exercises)
      ids = library.to_h { |e| [e.name, e.id] }
      lifting = @rows.select { |r| ids.key?(r.name) }
      sets = lifting.reject(&:warmup).map { |r| to_set(r, ids) }
      warmups = lifting.select(&:warmup).map { |r| to_set(r, ids) }
      cardio = @rows.select { |r| cardio?(r) }.map do |r|
        CardioSession.new(minutes: r.seconds / 60.0, intensity: 0.6, performed_at: r.time)
      end
      Import.new(library:, history: History.new(sets:, cardio:), warmups:, skipped:)
    end

    private

    def parse(r)
      Row.new(
        time: Time.strptime(r["Date"], "%Y-%m-%d %H:%M:%S %z"),
        name: r["Exercise"].strip,
        reps: r["Reps"].to_i,
        lb: (r["Weight(kg)"].to_f * LB_PER_KG).round(1),
        seconds: r["Duration(s)"].to_f,
        meters: r["Distance(m)"].to_f,
        warmup: r["isWarmup"].to_s.strip == "true",
        multiplier: r["multiplier"].to_f
      )
    end

    def cardio?(row)
      row.name.match?(CARDIO) && row.lb.zero? && row.seconds.positive?
    end

    def build_exercise(name, rows, groups)
      return nil if name.match?(CARDIO) && rows.all? { |r| r.lb.zero? && r.reps.zero? }
      return nil if name.match?(MOBILITY)

      _, muscles, mechanic, family = RULES.find { |pattern, *| name.match?(pattern) }
      return nil unless muscles

      Exercise.new(
        id: slug(name), name:, muscles:, mechanic:, family:,
        load_type: load_type(rows), equipment: equipment(name, rows),
        effectiveness: effectiveness(rows, groups), bw_ratio: nil
      )
    end

    def load_type(rows)
      work = rows.reject(&:warmup)
      return :weighted if work.count { |r| r.lb.positive? } * 2 >= work.size
      return :timed if work.count { |r| r.seconds.positive? } * 2 > work.size

      :bodyweight
    end

    def equipment(name, rows)
      found = EQUIPMENT.select { |pattern, _| name.match?(pattern) }.map(&:last).uniq
      found << :dumbbell if found.empty? && rows.any? { |r| r.multiplier >= 2 && r.lb.positive? }
      found
    end

    # How often Fitbod put this exercise in front of the user is the best available stand-in
    # for its goal-effectiveness prior (it is literally the selector's past output).
    def effectiveness(rows, groups)
      @max_days ||= groups.values.map { |rs| rs.map { |r| r.time.to_date }.uniq.size }.max
      days = rows.map { |r| r.time.to_date }.uniq.size
      0.4 + 0.6 * Math.log(1 + days) / Math.log(1 + @max_days)
    end

    def to_set(row, ids)
      LoggedSet.new(exercise_id: ids.fetch(row.name), weight: row.lb, reps: row.reps,
                    seconds: row.seconds.positive? ? row.seconds : nil, performed_at: row.time)
    end

    def slug(name) = name.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "").to_sym
  end
end
