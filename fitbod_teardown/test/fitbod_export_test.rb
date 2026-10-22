# frozen_string_literal: true

require_relative "test_helper"

class FitbodExportTest < Minitest::Test
  include FitbodClone

  def import = FitbodExport.load(File.join(__dir__, "fixtures", "sample_export.csv"))

  def test_maps_exercises_and_converts_kg_back_to_lb
    imp = import
    bench = imp.library.fetch(:barbell_bench_press)
    assert_equal :horizontal_press, bench.family
    assert_equal %i[barbell], bench.equipment
    assert_equal :weighted, bench.load_type
    assert_equal [135.0, 135.0, 150.0, 150.0], imp.history.for_exercise(:barbell_bench_press).map(&:weight)
    assert_equal :dumbbell, imp.library.fetch(:dumbbell_bicep_curl).load_equipment
    assert_equal :bodyweight, imp.library.fetch(:pull_up).load_type
    assert_equal :timed, imp.library.fetch(:plank).load_type
  end

  def test_separates_warmups_cardio_and_mobility
    imp = import
    assert_equal [90.0], imp.warmups.map(&:weight)
    assert_equal [30.0], imp.history.cardio.map(&:minutes)
    assert_includes imp.skipped, "Chest Doorway Stretch"
    assert_includes imp.skipped, "Loop Band Shoulder External Rotation at 90°"
  end

  def test_backtest_predicts_from_prior_sessions_only
    imp = import
    cases = Backtest.new(library: imp.library, history: imp.history).cases
    bench = cases.find { |c| c.exercise == :barbell_bench_press }
    assert_equal 5, bench.reps
    assert_equal 150.0, bench.actual
    assert_equal 135.0, bench.last
    # 135 x 8 -> e1RM ~167.5, read off at 5 reps -> ~150
    assert_equal 150.0, bench.predicted
  end
end

class ExportAnalysisTest < Minitest::Test
  include FitbodClone

  def test_report_covers_every_section
    imp = FitbodExport.load(File.join(__dir__, "fixtures", "sample_export.csv"))
    report = ExportAnalysis.new(imp).report
    ["Overview: 2 sessions", "Rep target", "Working sets", "Warm-up sets", "single warm-up: median 67%",
     "Logged capability", "Variety", "Session structure"].each { |s| assert_includes report, s }
  end
end
