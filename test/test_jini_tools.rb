# test/test_jini_tools.rb — the jini-tools handlers (docs/jini-tools.md):
# routing, parameter checks, and every rule that can run without SketchUp —
# the edit-mode frame rule, snapshot diffs, attribute value conversion,
# isolation, camera maths, the dry run's rollback bookkeeping, reload_ruby.
# Geometry maths lives in test_mesh.rb.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"

# Bare classes only, guarded and without superclasses, like the other test
# files' stubs, so whichever file loads first they stay compatible.
module Sketchup
  class Group; end unless const_defined?(:Group)
  class ComponentInstance; end unless const_defined?(:ComponentInstance)
  class ComponentDefinition; end unless const_defined?(:ComponentDefinition)
  class Model; end unless const_defined?(:Model)
  class Face; end unless const_defined?(:Face)
  class Edge; end unless const_defined?(:Edge)
end

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/compat"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/units"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/validation"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/entities"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/geometry"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/mesh"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/space"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/eval"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/inspect"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/scene"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/devtools"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/handlers/dispatch"
require_relative "support/config_reset"

class TestJiniTools < Minitest::Test
  D   = MCPforSketchUp::Handlers::Dispatch
  I   = MCPforSketchUp::Handlers::Inspect
  SC  = MCPforSketchUp::Handlers::Scene
  DT  = MCPforSketchUp::Handlers::DevTools
  V   = MCPforSketchUp::Helpers::Validation
  EH  = MCPforSketchUp::Helpers::Entities
  S   = MCPforSketchUp::Helpers::Space
  SE  = MCPforSketchUp::Core::StructuredError
  CFG = MCPforSketchUp::Core::Config

  HANDLERS = File.expand_path("../mcp_for_sketchup/mcp_for_sketchup/handlers", __dir__)

  ROUTES = {
    "get_edit_context"      => [I, :get_edit_context],
    "solid_report"          => [I, :solid_report],
    "query_faces"           => [I, :query_faces],
    "find_overlaps"         => [I, :find_overlaps],
    "raycast"               => [I, :raycast],
    "scene_stats"           => [I, :scene_stats],
    "get_attributes"        => [I, :get_attributes],
    "select_entities"       => [SC, :select_entities],
    "set_entity_properties" => [SC, :set_entity_properties],
    "set_attributes"        => [SC, :set_attributes],
    "capture_view"          => [SC, :capture_view],
    "profile_view"          => [SC, :profile_view],
    "eval_ruby_dry_run"     => [DT, :eval_ruby_dry_run],
    "reload_ruby"           => [DT, :reload_ruby],
  }.freeze

  def setup
    ConfigReset.reset_all!
  end

  def teardown
    ConfigReset.reset_all!
  end

  def request(tool, args = {})
    D.handle({ "jsonrpc" => "2.0", "method" => "tools/call",
               "params" => { "name" => tool, "arguments" => args }, "id" => 1 })
  end

  def payload(resp)
    refute resp.key?("error"), "unexpected error: #{resp["error"].inspect}"
    JSON.parse(resp["result"]["content"][0]["text"])
  end

  # Swap Helpers::Entities.active_model! for the block's duration.
  def with_model(model)
    saved = EH.method(:active_model!)
    EH.define_singleton_method(:active_model!) { model }
    yield
  ensure
    EH.define_singleton_method(:active_model!, saved)
  end

  # ---- routing ------------------------------------------------------------------

  def test_every_new_tool_routes_to_its_handler
    ROUTES.each do |tool, (mod, meth)|
      original = mod.method(meth)
      mod.define_singleton_method(meth) { |params| { "routed" => tool, "params" => params } }
      begin
        out = payload(request(tool, { "x" => 1 }))
        assert_equal tool, out["routed"]
        assert_equal({ "x" => 1 }, out["params"])
      ensure
        mod.define_singleton_method(meth, original)
      end
    end
  end

  def test_plugin_loads_every_new_file
    main = File.read(File.expand_path("../mcp_for_sketchup/mcp_for_sketchup/main.rb", __dir__))
    order = main[/LOAD_ORDER = %w\[(.*?)\]/m, 1].split
    %w[helpers/mesh helpers/space handlers/inspect handlers/scene handlers/devtools].each do |f|
      assert_includes order, f
    end
    assert_operator order.index("helpers/space"), :>, order.index("helpers/entities")
  end

  # ---- validation comes before the model ----------------------------------------------

  class TouchedModel < StandardError; end

  BAD_PARAMS = [
    ["solid_report", {}, "missing required field: ids"],
    ["solid_report", { "ids" => [] }, "must hold 1..200 IDs"],
    ["solid_report", { "ids" => ["1"], "max_samples" => 51 }, "0..50"],
    ["solid_report", { "ids" => ["1"], "max_seconds" => 60 }, "1..55"],
    ["query_faces", { "orientation" => "left" }, "must be one of"],
    ["query_faces", { "normal" => [0, 0, 0] }, "zero vector"],
    ["query_faces", { "within_mm" => { "min" => [0, 0, 0] } }, "must be an object"],
    ["query_faces", { "limit" => 0 }, "1..500"],
    ["query_faces", { "id" => "abc" }, "integer ID"],
    ["find_overlaps", {}, "pass ids"],
    ["find_overlaps", { "ids" => ["1"] }, "must hold 2..200 IDs"],
    ["find_overlaps", { "ids" => %w[1 2], "container_id" => "3" }, "not both"],
    ["find_overlaps", { "ids" => %w[1 2], "samples_per_axis" => 3 }, "4..40"],
    ["raycast", { "origin_mm" => [0, 0, 0], "direction" => [0, 0, 0] }, "zero vector"],
    ["raycast", { "origin_mm" => [0, 0], "direction" => [0, 0, 1] }, "3-element"],
    ["raycast", { "origin_mm" => [0, 0, 0], "direction" => [0, 0, 1], "max_hits" => 0 }, "1..50"],
    ["scene_stats", { "top" => 99 }, "1..50"],
    ["get_attributes", {}, "missing required field: id"],
    ["select_entities", {}, "missing required field: ids"],
    ["select_entities", { "mode" => "invert" }, "must be one of"],
    ["set_entity_properties", { "ids" => ["1"] }, "nothing to set"],
    ["set_entity_properties", { "ids" => ["1"], "hidden" => "yes" }, "must be a boolean"],
    ["set_entity_properties", { "ids" => ["1"], "name" => 5 }, "must be a string"],
    ["set_attributes", { "id" => "1", "dictionary" => "d", "values" => {} }, "1..200 keys"],
    ["set_attributes", { "id" => "1", "dictionary" => "d", "values" => { "k" => { "a" => 1 } } },
     "values must be"],
    ["set_attributes", { "id" => "1", "dictionary" => "d", "values" => { "k" => 1 },
                         "target" => "both" }, "must be one of"],
    ["capture_view", { "isolate" => true }, "need ids"],
    ["capture_view", { "max_size" => 10 }, "64..4096"],
    ["capture_view", { "view_preset" => "side" }, "must be one of"],
    ["capture_view", { "ids" => ["1"], "margin" => 0.5 }, "1.0..3.0"],
    ["profile_view", { "frames" => 0 }, "1..120"],
    ["profile_view", { "orbit_degrees" => 400 }, "0..360"],
  ].freeze

  def test_bad_parameters_are_refused_before_the_model_is_touched
    saved = EH.method(:active_model!)
    EH.define_singleton_method(:active_model!) { raise TouchedModel, "model touched" }
    BAD_PARAMS.each do |tool, args, message|
      resp = nil
      capture_io { resp = request(tool, args) }   # the plugin logs every error
      assert resp["error"], "#{tool} #{args.inspect} should fail"
      assert_equal(-32602, resp["error"]["code"], "#{tool} #{args.inspect}: #{resp["error"]["message"]}")
      assert_includes resp["error"]["message"], message, "#{tool} #{args.inspect}"
    end
  ensure
    EH.define_singleton_method(:active_model!, saved)
  end

  def test_id_lists
    assert_equal [1, 2], V.require_id_list({ "ids" => [1, "2", "1"] }, "ids")
    err = assert_raises(SE) { V.require_id_list({ "ids" => [1, "x"] }, "ids") }
    assert_includes err.message, "ids[1]"
    assert_raises(SE) { V.require_id_list({ "ids" => "1" }, "ids") }
    assert_raises(SE) { V.require_id_list({ "ids" => [1] }, "ids", min: 2) }
    assert_raises(SE) { V.require_id_list({ "ids" => [true] }, "ids") }
  end

  def test_optional_number_range
    assert_equal 2.5, V.optional_number_range({ "n" => 2.5 }, "n", min: 0, max: 3, default: 1)
    assert_equal 1, V.optional_number_range({}, "n", min: 0, max: 3, default: 1)
    assert_raises(SE) { V.optional_number_range({ "n" => "2" }, "n", min: 0, max: 3, default: 1) }
    assert_raises(SE) { V.optional_number_range({ "n" => 4 }, "n", min: 0, max: 3, default: 1) }
  end

  # ---- the edit-mode frame rule (helpers/space.rb) ---------------------------------------

  # Translation-only transformations are enough to tell the frames apart.
  class FakeT
    attr_reader :offset

    def initialize(offset)
      @offset = offset
    end

    def *(other)
      FakeT.new(offset + other.offset)
    end

    def inverse
      FakeT.new(-offset)
    end
  end

  FakeInst = Struct.new(:name, :transformation, :definition)

  # The user is inside B, which sits inside A. True placements: A +100,
  # B +10. While open, both report the identity, the open group's contents
  # report edit_transform * local, and a second instance of B's definition
  # elsewhere still sees its contents in B's (world) frame.
  def edit_mode_scene
    defn_a = Object.new
    defn_b = Object.new
    a = FakeInst.new("A", FakeT.new(0), defn_a)
    b = FakeInst.new("B", FakeT.new(0), defn_b)
    ctx = S::Context.new([a, b], [defn_a, defn_b], FakeT.new(-110), false)
    [a, b, ctx]
  end

  def test_step_follows_the_open_path_in_world_space
    a, b, ctx = edit_mode_scene
    frame = S.step(S.step(FakeT.new(0), a, ctx), b, ctx)
    assert_equal 0, frame.offset, "the open group's contents already report world coordinates"
    c = FakeInst.new("C", FakeT.new(111), Object.new)   # inside B, true local +1
    assert_equal 111, S.step(frame, c, ctx).offset
    refute ctx.ambiguous
  end

  def test_step_corrects_a_second_instance_of_the_open_definition
    _a, b, ctx = edit_mode_scene
    twin = FakeInst.new("B2", FakeT.new(1000), b.definition)   # true local +1000
    frame = S.step(FakeT.new(0), twin, ctx)
    # A point at local x=5 inside the definition reports 110 + 5.
    assert_equal 1000 + 5, frame.offset + 115
    refute ctx.ambiguous
  end

  def test_step_flags_a_second_instance_of_an_outer_open_definition
    a, _b, ctx = edit_mode_scene
    twin = FakeInst.new("A2", FakeT.new(500), a.definition)
    S.step(FakeT.new(0), twin, ctx)
    assert ctx.ambiguous
  end

  def test_step_outside_edit_mode_multiplies_placements
    ctx = S::Context.new([], [], nil, false)
    inst = FakeInst.new("X", FakeT.new(7), Object.new)
    assert_equal 12, S.step(FakeT.new(5), inst, ctx).offset
  end

  # A definition whose parent chain is wired by hand.
  def fake_definition(instances)
    d = Sketchup::ComponentDefinition.allocate
    d.define_singleton_method(:instances) { instances }
    d
  end

  def placed(parent)
    inst = Object.new
    inst.define_singleton_method(:parent) { parent }
    inst
  end

  def test_chain_to_climbs_to_the_root_and_skips_unplaced_instances
    model = Sketchup::Model.allocate
    outer = placed(model)
    outer_def = fake_definition([outer])
    orphan_parent = fake_definition([])          # a definition never placed
    stray = placed(orphan_parent)
    inner = placed(outer_def)
    inner_def = fake_definition([stray, inner])
    face = placed(inner_def)
    ctx = S::Context.new([], [], nil, false)
    assert_equal [outer, inner], S.chain_to(face, ctx)
    assert_equal [], S.chain_to(placed(model), ctx)
    assert_nil S.chain_to(placed(orphan_parent), ctx)
  end

  def test_chain_to_prefers_the_instance_being_edited
    model = Sketchup::Model.allocate
    first = placed(model)
    second = placed(model)
    defn = fake_definition([first, second])
    ctx = S::Context.new([second], [defn], nil, false)
    assert_equal [second], S.chain_to(placed(defn), ctx)
  end

  # ---- solid_report snapshots ------------------------------------------------------------

  def row(name, faces: 6, volume: 1000.0, box: [[0, 0, 0], [10, 10, 10]])
    { "name" => name, "faces" => faces, "edges" => 12, "nested_instances" => 0,
      "manifold" => true, "volume_mm3" => volume, "area_mm2" => 600.0, "open_edges" => 0,
      "nonmanifold_edges" => 0, "stray_edges" => 0,
      "bbox_mm" => { "min" => box[0], "max" => box[1] } }
  end

  def test_diff_matches_parts_by_name_and_counts_repeats
    before = [row("Wall 1"), row("Wall 1"), row("Column 1"), row("Gone")]
    after = [row("Wall 1"), row("Wall 1", faces: 8), row("Column 1", volume: 1000.4),
             row("New")]
    diff = I.diff_rows(before, after)
    assert_equal ["New"], diff["added"]
    assert_equal ["Gone"], diff["removed"]
    assert_equal 2, diff["unchanged"], "a 0.4 mm³ drift is not a change"
    assert_equal [{ "part" => "Wall 1 #2", "changes" => { "faces" => [6, 8] } }], diff["changed"]
  end

  def test_diff_sees_a_moved_box
    diff = I.diff_rows([row("A")], [row("A", box: [[0, 0, 0], [10, 10, 10.05]])])
    assert_equal ["bbox_mm"], diff["changed"].first["changes"].keys
    diff = I.diff_rows([row("A")], [row("A", box: [[0, 0, 0], [10, 10, 10.005]])])
    assert_empty diff["changed"]
  end

  def test_snapshots_keep_the_newest_twenty
    I.snapshots.clear
    25.times { |i| I.store_snapshot("s#{i}", [], true) }
    assert_equal 20, I.snapshots.length
    assert_equal "s5", I.snapshots.keys.first
    I.store_snapshot("s5", [row("x")], true)
    assert_equal "s5", I.snapshots.keys.last, "re-saving a label makes it the newest"
  ensure
    I.snapshots.clear
  end

  def test_compare_with_an_unknown_label_is_refused
    I.snapshots.clear
    err = assert_raises(SE) { I.solid_report({ "ids" => ["1"], "compare_with" => "nope" }) }
    assert_equal(-32602, err.code)
    assert_includes err.message, "no snapshot named"
  end

  # ---- attribute values ---------------------------------------------------------------------

  def test_json_value_converts_what_json_cannot_carry
    point = Struct.new(:x, :y, :z).new(1, 2, 3)
    assert_equal [1.0, 2.0, 3.0], I.json_value(point)
    assert_equal "2026-10-11T00:00:00Z", I.json_value(Time.utc(2026, 10, 11))
    assert_equal "Infinity", I.json_value(Float::INFINITY)
    assert_equal [1, "a", [true, nil]], I.json_value([1, "a", [true, nil]])
    assert_equal({ "k" => 1.5 }, I.json_value({ k: 1.5 }))
    long = I.json_value("x" * 5000)
    assert_equal I::MAX_STRING + 1, long.length
    assert_match(/\A#<Object/, I.json_value(Object.new))
  end

  # ---- query_faces orientation ----------------------------------------------------------

  def test_facing
    tol = 1.0
    assert I.facing?([0, 0, 1], "up", tol)
    refute I.facing?([0, 0.1, 0.995], "up", tol)
    assert I.facing?([0, 0, -1], "down", tol)
    assert I.facing?([1, 0, 0.01], "vertical", tol)
    refute I.facing?([1, 0, 0.1], "vertical", tol)
    assert I.facing?([0.7071, 0, 0.7071], "sloped", tol)
    assert I.facing?([0.7071, 0, 0.7071], "any", tol)
  end

  # ---- capture_view helpers ------------------------------------------------------------------

  def test_capture_lists_match_view_rb
    src = File.read(File.join(HANDLERS, "view.rb"))
    assert_equal src[/ALLOWED_PRESETS = %w\[(.*?)\]/, 1].split, SC::PRESETS
    assert_equal src[/ALLOWED_STYLES  = %w\[(.*?)\]/, 1].split, SC::STYLES
    assert_equal src[/MIN_MAX_SIZE = (\d+)/, 1].to_i, SC::MIN_SIZE
    assert_equal src[/MAX_MAX_SIZE = (\d+)/, 1].to_i, SC::MAX_SIZE
  end

  class FakeCamera
    def initialize(fov, height = nil)
      @fov = fov
      @height = height
    end

    def fov
      @fov
    end

    def fov_is_height?
      @height
    end
  end

  def test_half_fov_takes_the_narrower_side
    deg = ->(r) { r * 180.0 / Math::PI }
    # 60 degrees measured vertically on a 2:1 viewport: vertical is narrower.
    assert_in_delta 30.0, deg.(SC.half_fov(FakeCamera.new(60.0, true), 2.0)), 1e-9
    # Measured horizontally: the vertical half-angle is atan(tan 30 / 2).
    expected = deg.(Math.atan(Math.tan(Math::PI / 6) / 2))
    assert_in_delta expected, deg.(SC.half_fov(FakeCamera.new(60.0, false), 2.0)), 1e-9
    plain = Object.new
    plain.define_singleton_method(:fov) { 60.0 }
    assert_in_delta expected, deg.(SC.half_fov(plain, 2.0)), 1e-9
  end

  def test_scaled
    assert_equal [800, 450], SC.scaled(1600.0, 900.0, 800)
    assert_equal [450, 800], SC.scaled(900.0, 1600.0, 800)
  end

  # Entities for isolate!: hidden flags, ids, and (for groups) a definition.
  class Leaf
    attr_accessor :hidden
    attr_reader :entityID

    def initialize(id, hidden: false)
      @entityID = id
      @hidden = hidden
    end

    def hidden?
      @hidden
    end
  end

  class Box < Sketchup::Group
    attr_accessor :hidden
    attr_reader :entityID, :entities, :definition

    def initialize(id, entities, hidden: false)
      @entityID = id
      @entities = entities
      @hidden = hidden
      def_id = id + 1000
      @definition = Object.new.tap { |d| d.define_singleton_method(:entityID) { def_id } }
    end

    def hidden?
      @hidden
    end
  end

  def test_isolate_hides_everything_off_the_path_and_shows_the_target
    target = Leaf.new(3, hidden: true)
    sibling = Leaf.new(4)
    already_hidden = Leaf.new(5, hidden: true)
    container = Box.new(2, [target, sibling, already_hidden])
    other = Box.new(6, [Leaf.new(7)])
    loose = Leaf.new(8)
    model = Struct.new(:entities).new([container, other, loose])

    count = SC.isolate!(model, [[target, [container]]])
    assert_equal 3, count, "sibling, other and loose; the already hidden one isn't counted"
    refute target.hidden?, "a hidden target is shown for the shot"
    refute container.hidden?
    assert sibling.hidden?
    assert other.hidden?
    assert loose.hidden?
    refute other.entities.first.hidden?, "nothing inside a hidden container is touched"
  end

  def test_isolate_keeps_every_target
    a = Leaf.new(3)
    b = Leaf.new(4)
    container = Box.new(2, [a, b, Leaf.new(5)])
    model = Struct.new(:entities).new([container])
    assert_equal 1, SC.isolate!(model, [[a, [container]], [b, [container]]])
    refute a.hidden?
    refute b.hidden?
  end

  # ---- scene edits with a fake model ------------------------------------------------------

  class OpModel
    attr_reader :log, :layers, :selection, :active_entities

    def initialize(entities: {}, layers: nil)
      @entities = entities
      @log = []
      @observers = []
      @layers = layers
    end

    def find_entity_by_id(id)
      @entities[id]
    end

    def start_operation(name, *)
      @log << [:start, name]
      true
    end

    def commit_operation
      @log << :commit
      @observers.each { |o| o.onTransactionCommit(self) }
      true
    end

    def abort_operation
      @log << :abort
      true
    end

    def add_observer(o)
      @observers << o
      true
    end

    def remove_observer(o)
      @observers.delete(o)
      true
    end

    def observers
      @observers
    end

    attr_writer :selection, :active_entities
  end

  class Tags
    attr_reader :added

    def initialize(names)
      @layers = names.to_h { |n| [n, Struct.new(:name).new(n)] }
      @added = []
    end

    def [](key)
      key.is_a?(Integer) ? @layers.values[key] : @layers[key]
    end

    def add(name)
      @added << name
      @layers[name] = Struct.new(:name).new(name)
    end
  end

  class Thing
    attr_accessor :layer, :hidden
    attr_reader :entityID

    def initialize(id)
      @entityID = id
    end

    def valid?
      true
    end

    def typename
      "Face"
    end
  end

  class Part < Sketchup::Group
    attr_accessor :layer, :hidden, :locked, :name
    attr_reader :entityID

    def initialize(id)
      @entityID = id
    end

    def valid?
      true
    end
  end

  def test_set_entity_properties_sets_what_applies_and_reports_the_rest
    face = Thing.new(1)
    part = Part.new(2)
    model = OpModel.new(entities: { 1 => face, 2 => part }, layers: Tags.new(%w[Layer0]))
    out = with_model(model) do
      SC.set_entity_properties({ "ids" => %w[1 2], "tag" => "Walls", "hidden" => true,
                                 "locked" => true })
    end
    assert_equal [[:start, "Set Entity Properties"], :commit], model.log
    assert_equal ["Walls"], model.layers.added
    assert out["tag_created"]
    assert_equal 2, out["updated"], "the face took the tag and the hidden flag"
    assert_equal [{ "id" => 1, "type" => "face", "reason" => "only groups and components lock" }],
                 out["not_applied"]
    assert_equal "Walls", face.layer.name
    assert face.hidden
    assert part.locked
  end

  def test_an_entity_nothing_applies_to_is_not_counted
    face = Thing.new(1)
    model = OpModel.new(entities: { 1 => face }, layers: Tags.new(%w[Layer0]))
    out = with_model(model) { SC.set_entity_properties({ "ids" => ["1"], "name" => "x" }) }
    assert_equal 0, out["updated"]
    assert_equal 1, out["not_applied"].length
  end

  def test_set_entity_properties_with_a_missing_tag_changes_nothing
    model = OpModel.new(entities: { 1 => Thing.new(1) }, layers: Tags.new(%w[Layer0]))
    err = with_model(model) do
      assert_raises(SE) do
        SC.set_entity_properties({ "ids" => ["1"], "tag" => "Nope", "create_tag" => false })
      end
    end
    assert_includes err.message, "does not exist"
    assert_empty model.log, "no operation is opened for a refused call"
  end

  def test_untagged_means_layer0
    tags = Tags.new(%w[Layer0 Walls])
    model = Struct.new(:layers).new(tags)
    assert_equal "Layer0", SC.find_tag(model, "Untagged").name
    assert_equal "Walls", SC.find_tag(model, "Walls").name
    assert_nil SC.find_tag(model, "Roof")
  end

  class Dictionaries
    attr_reader :calls

    def initialize
      @calls = []
    end

    def set_attribute(dict, key, value)
      @calls << [:set, dict, key, value]
    end

    # Like SketchUp: true when the key was there to delete.
    def delete_attribute(dict, key)
      @calls << [:delete, dict, key]
      key != "never_set"
    end

    def valid?
      true
    end

    def entityID
      9
    end
  end

  def test_set_attributes_sets_and_deletes_in_one_operation
    holder = Dictionaries.new
    model = OpModel.new(entities: { 9 => holder })
    out = with_model(model) do
      SC.set_attributes({ "id" => 9, "dictionary" => "wb2",
                          "values" => { "a" => 1, "b" => nil, "c" => [1, "x"],
                                        "never_set" => nil } })
    end
    assert_equal [[:set, "wb2", "a", 1], [:delete, "wb2", "b"], [:set, "wb2", "c", [1, "x"]],
                  [:delete, "wb2", "never_set"]], holder.calls
    assert_equal %w[a c], out["set"]
    assert_equal %w[b], out["deleted"]
    assert_equal %w[never_set], out["absent"]
    assert_equal [[:start, "Set Attributes"], :commit], model.log
  end

  def test_projected_half_extents_follow_the_view
    axis = Struct.new(:x, :y, :z)
    box = [[0, 0, 0], [2, 10, 4]]
    # Looking down: right is x, up is y.
    assert_equal [1.0, 5.0], SC.projected_half_extents(box, axis.new(1, 0, 0), axis.new(0, 1, 0))
    # Looking along y: up is z.
    assert_equal [1.0, 2.0], SC.projected_half_extents(box, axis.new(1, 0, 0), axis.new(0, 0, 1))
  end

  class Picks
    attr_reader :items

    def initialize
      @items = []
    end

    def clear
      @items.clear
    end

    def add(list)
      @items.concat(list)
    end

    def remove(list)
      @items -= list
    end

    def toggle(list)
      list.each { |e| @items.include?(e) ? @items.delete(e) : @items << e }
    end

    def length
      @items.length
    end
  end

  def test_select_entities_reports_what_it_cannot_select
    here = Object.new
    elsewhere = Object.new
    mine = Thing.new(1)
    mine.define_singleton_method(:parent) { here }
    far = Thing.new(2)
    far.define_singleton_method(:parent) { elsewhere }
    model = OpModel.new(entities: { 1 => mine, 2 => far })
    model.selection = Picks.new
    model.active_entities = Struct.new(:parent).new(here)
    out = with_model(model) { SC.select_entities({ "ids" => [1, 2, 3] }) }
    assert_equal [mine], model.selection.items
    assert_equal 1, out["applied"]
    assert_equal [3], out["missing_ids"]
    assert_equal [2], out["not_in_active_context"]
    with_model(model) { SC.select_entities({ "mode" => "clear" }) }
    assert_empty model.selection.items
  end

  # ---- eval_ruby_dry_run ---------------------------------------------------------------------

  def test_dry_run_is_gated
    CFG.eval_enabled = false
    %w[eval_ruby_dry_run reload_ruby].each do |tool|
      resp = nil
      capture_io { resp = request(tool, { "code" => "1", "paths" => ["x.rb"] }) }
      assert_equal(-32010, resp["error"]["code"], tool)
    end
  end

  def test_dry_run_always_aborts
    CFG.eval_enabled = true
    model = OpModel.new
    out = with_model(model) { DT.eval_ruby_dry_run({ "code" => "[1, 2].sum" }) }
    assert_equal({ "ok" => true, "result" => "3", "rolled_back" => true }, out)
    assert_equal [[:start, "MCP Dry Run"], :abort], model.log
    assert_empty model.observers, "the spy is removed"
  end

  def test_dry_run_reports_errors_and_still_aborts
    CFG.eval_enabled = true
    model = OpModel.new
    out = with_model(model) { DT.eval_ruby_dry_run({ "code" => "raise ArgumentError, 'nope'" }) }
    refute out["ok"]
    assert_equal "ArgumentError: nope", out["error"]
    assert out["rolled_back"]
    assert_equal :abort, model.log.last
    out = with_model(model) { DT.eval_ruby_dry_run({ "code" => "def (" }) }
    assert_match(/\ASyntaxError/, out["error"])
  end

  def test_dry_run_owns_up_when_the_code_commits
    CFG.eval_enabled = true
    model = OpModel.new
    $jini_dry_run_model = model
    out = with_model(model) do
      DT.eval_ruby_dry_run({ "code" => "$jini_dry_run_model.commit_operation; :done" })
    end
    assert out["ok"]
    refute out["rolled_back"]
    assert_match(/committed 1 operation/, out["warning"])
  ensure
    $jini_dry_run_model = nil
  end

  # ---- reload_ruby ----------------------------------------------------------------------------

  def test_reload_ruby_loads_in_order_and_stops_at_the_first_failure
    CFG.eval_enabled = true
    Dir.mktmpdir("jini-reload") do |dir|
      File.write(File.join(dir, "a.rb"), "$jini_reload = ($jini_reload || []) << :a\nJINI_RELOAD_CONST = 1\n")
      File.write(File.join(dir, "b.rb"), "def broken(\n")
      File.write(File.join(dir, "c.rb"), "$jini_reload << :c\n")
      $jini_reload = nil
      verbose = $VERBOSE
      out = DT.reload_ruby({ "paths" => ["#{dir}/*.rb"] })
      assert_equal [File.join(dir, "a.rb")], out["loaded"].map { |l| l["path"] }
      assert_equal 1, out["failed"].length
      assert_match(/SyntaxError/, out["failed"].first["error"])
      assert_equal 1, out["skipped"]
      assert_equal [:a], $jini_reload
      assert_equal verbose, $VERBOSE, "$VERBOSE is put back"

      out = DT.reload_ruby({ "paths" => ["#{dir}/a.rb", "#{dir}/b.rb", "#{dir}/c.rb"],
                             "stop_on_error" => false })
      assert_equal 2, out["loaded"].length
      assert_equal [:a, :a, :c], $jini_reload
    end
  ensure
    $jini_reload = nil
    Object.send(:remove_const, :JINI_RELOAD_CONST) if Object.const_defined?(:JINI_RELOAD_CONST)
  end

  def test_reload_ruby_refuses_bad_paths
    CFG.eval_enabled = true
    Dir.mktmpdir("jini-reload") do |dir|
      File.write(File.join(dir, "notes.txt"), "x")
      [
        [{ "paths" => "a.rb" }, "array"],
        [{ "paths" => [] }, "array"],
        [{ "paths" => ["#{dir}/missing.rb"] }, "no such file"],
        [{ "paths" => ["#{dir}/notes.txt"] }, "not a .rb file"],
        [{ "paths" => ["#{dir}/*.rb"] }, "matched no .rb files"],
      ].each do |params, message|
        err = assert_raises(SE) { DT.reload_ruby(params) }
        assert_equal(-32602, err.code)
        assert_includes err.message, message
      end
    end
  end

  # ---- source guards -------------------------------------------------------------------------------

  def test_new_operation_labels_are_title_case
    %w[scene.rb devtools.rb].each do |file|
      src = File.read(File.join(HANDLERS, file))
      src.scan(/start_operation\("([^"]+)"/).flatten.each do |label|
        assert_match(/\A[A-Z]/, label, "#{file}: #{label}")
      end
    end
    refute_match(/start_operation/, File.read(File.join(HANDLERS, "inspect.rb")),
                 "inspect.rb is read-only")
  end
end
