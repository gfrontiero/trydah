# frozen_string_literal: true

require_relative "test_helper"

# Guards the calibration in README section 7: replaying the bundled export must keep the
# engine's weight predictions at least this close to what Fitbod prescribed.
class CalibrationTest < Minitest::Test
  include FitbodClone

  EXPORT = File.expand_path("../data/fitbod_export_2019-04_2026-10.csv", __dir__)

  def test_backtest_accuracy_on_bundled_export
    skip "export not present" unless File.exist?(EXPORT)

    import = FitbodExport.load(EXPORT)
    backtest = Backtest.new(library: import.library, history: import.history)
    recent = backtest.summary(backtest.cases.select { |c| c.gap_days <= 42 })

    assert_operator recent[:engine][:median_error], :<=, 0.065
    assert_operator recent[:engine][:within_5pct], :>=, 0.45
    assert_operator recent[:engine][:within_5pct], :>, recent[:repeat_last_weight][:within_5pct]
  end
end
