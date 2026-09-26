# test/test_compat.rb
require "minitest/autorun"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/compat"

class TestCompat < Minitest::Test
  # -------- parse --------

  def test_parse_valid
    assert_equal [0, 1, 0], MCPforSketchUp::Core::Compat.parse("0.1.0")
    assert_equal [10, 20, 30], MCPforSketchUp::Core::Compat.parse("10.20.30")
  end

  # Mirrors tests/test_compat.py negatives. ١..٣ are Arabic-Indic
  # digits; Ruby's \d is ASCII-by-default but the regex is [0-9]+ to mirror
  # Python's ASCII-only intent.
  [
    "0.1", "0.1.0.0", "abc", "", "v1",
    "0.1.0-rc1", "v1.0.0",
    " 0.1.0", "0.1.0 ", "0.1.0+", "+1.0.0", "1_0.0.0",
    "١.٢.٣", "0.1.٣",
  ].each_with_index do |bad, i|
    define_method("test_parse_invalid_#{i}_#{bad.gsub(/\W/, '_')}") do
      assert_raises(ArgumentError) { MCPforSketchUp::Core::Compat.parse(bad) }
    end
  end

  def test_parse_non_string_raises
    assert_raises(ArgumentError) { MCPforSketchUp::Core::Compat.parse(nil) }
    assert_raises(ArgumentError) { MCPforSketchUp::Core::Compat.parse(123) }
  end

  # -------- check_python_version --------

  # Safe swap of MIN_PYTHON per-test. The defined?-guard in the ensure block
  # keeps a failed setup from masking the original error with a secondary
  # NameError.
  def with_min(min)
    orig_min = MCPforSketchUp::Core::Compat::MIN_PYTHON
    MCPforSketchUp::Core::Compat.send(:remove_const, :MIN_PYTHON)
    MCPforSketchUp::Core::Compat.const_set(:MIN_PYTHON, min)
    yield
  ensure
    if MCPforSketchUp::Core::Compat.const_defined?(:MIN_PYTHON, false)
      MCPforSketchUp::Core::Compat.send(:remove_const, :MIN_PYTHON)
    end
    MCPforSketchUp::Core::Compat.const_set(:MIN_PYTHON, orig_min) if defined?(orig_min)
  end

  def test_at_min_passes
    with_min("0.1.0") do
      MCPforSketchUp::Core::Compat.check_python_version("0.1.0")  # no raise
    end
  end

  # No upper bound: a client released after this plugin (a Python-only
  # hotfix) passes — the newer side of a pair decides.
  def test_newer_client_accepted
    with_min("0.1.0") do
      MCPforSketchUp::Core::Compat.check_python_version("99.0.0")  # no raise
    end
  end

  def test_too_old_raises_with_upgrade_hint
    with_min("0.1.0") do
      err = assert_raises(MCPforSketchUp::Core::StructuredError) do
        MCPforSketchUp::Core::Compat.check_python_version("0.0.3")
      end
      assert_equal(-32001, err.code)
      assert_includes err.message, "0.0.3"
      assert_includes err.message, "too old"
      assert_includes err.message, "needs client v0.1.0 or newer"
      assert_includes err.message, "uvx sketchup-mcp2@latest"
      assert_includes err.message, "get_version"
    end
  end

  def test_nil_raises_with_pre_dates_hint
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      MCPforSketchUp::Core::Compat.check_python_version(nil)
    end
    assert_equal(-32001, err.code)
    assert_includes err.message, "pre-dates"
    # Review focus 5: both client-facing messages share one upgrade hint.
    assert_includes err.message, "uvx sketchup-mcp2@latest",
      "must carry the same upgrade hint as the too-old message"
  end

  def test_unparseable_raises_clear_message
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      MCPforSketchUp::Core::Compat.check_python_version("v1")
    end
    assert_equal(-32001, err.code)
    assert_includes err.message, "unparseable"
    assert_includes err.message, "v1"
  end
end
