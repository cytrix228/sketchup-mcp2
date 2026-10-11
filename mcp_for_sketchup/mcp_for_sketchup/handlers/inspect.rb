# mcp_for_sketchup/mcp_for_sketchup/handlers/inspect.rb
#
# Read-only inspection: where the user is, what a part is made of, where
# parts overlap, what a ray hits, what the scene costs to draw, and what an
# entity carries in its attribute dictionaries. Nothing here writes to the
# model. Coordinates leave in mm and in WORLD space, also while the user is
# editing inside a group (see helpers/space.rb for why that takes care).
module MCPforSketchUp
  module Handlers
    module Inspect
      V  = MCPforSketchUp::Helpers::Validation
      EH = MCPforSketchUp::Helpers::Entities
      U  = MCPforSketchUp::Helpers::Units
      S  = MCPforSketchUp::Helpers::Space
      M  = MCPforSketchUp::Helpers::Mesh
      E  = MCPforSketchUp::Core::StructuredError

      # Long reads stop at a deadline and say so (complete: false) instead of
      # running into the client's 60 s timeout. A Ruby call that outlives the
      # timeout keeps running and freezes SketchUp until it ends.
      DEFAULT_SECONDS = 20
      MAX_SECONDS     = 55

      SNAPSHOT_LIMIT  = 20

      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def self.deadline(params)
        now + V.optional_number_range(params, "max_seconds", min: 1, max: MAX_SECONDS,
                                                             default: DEFAULT_SECONDS)
      end

      # An id that must name a group or component placed in the model, with
      # the chain of instances leading to it.
      def self.placed_instance!(id, ctx)
        inst = EH.require_group_or_component!(EH.find!(id), "entity #{id}")
        chain = S.chain_to(inst, ctx)
        raise E.new(-32602, "entity #{id} is not placed in the model") unless chain
        [inst, chain]
      end

      def self.vec(v, digits = 6)
        [v.x.to_f.round(digits), v.y.to_f.round(digits), v.z.to_f.round(digits)]
      end

      def self.point_mm(p)
        [U.inch_to_mm(p.x.to_f).round(2), U.inch_to_mm(p.y.to_f).round(2),
         U.inch_to_mm(p.z.to_f).round(2)]
      end

      # ===== get_edit_context ================================================

      def self.get_edit_context(_params)
        model = EH.active_model!
        path = model.active_path ? model.active_path.to_a : []
        selection = model.selection
        by_type = Hash.new(0)
        selection.each { |e| by_type[S.type_name(e)] += 1 }
        view = model.active_view
        {
          "model"            => { "title" => model.title, "path" => model.path },
          "active_path"      => path.map { |i| S.ref(i).merge("definition" => i.definition.name) },
          "edit_transform"   => path.empty? ? nil : transform_json(model.edit_transform),
          "active_entities"  => count_types(model.active_entities),
          "selection"        => { "count" => selection.length, "by_type" => by_type,
                                  "ids" => selection.to_a.first(50).map(&:entityID) },
          "camera"           => view ? camera_json(view.camera) : nil,
          "viewport"         => view ? { "width" => view.vpwidth, "height" => view.vpheight } : nil,
          "active_tool"      => active_tool_name(model),
        }
      end

      def self.transform_json(t)
        { "origin_mm" => point_mm(t.origin), "xaxis" => vec(t.xaxis), "yaxis" => vec(t.yaxis),
          "zaxis" => vec(t.zaxis) }
      end

      def self.camera_json(cam)
        out = { "eye_mm" => point_mm(cam.eye), "target_mm" => point_mm(cam.target),
                "up" => vec(cam.up), "perspective" => cam.perspective? }
        if cam.perspective?
          out["fov_deg"] = cam.fov.to_f.round(3)
        else
          out["height_mm"] = U.inch_to_mm(cam.height.to_f).round(1)
        end
        out
      end

      def self.count_types(entities)
        counts = Hash.new(0)
        entities.each { |e| counts[S.type_name(e)] += 1 }
        counts
      end

      def self.active_tool_name(model)
        model.tools.active_tool_name
      rescue StandardError
        nil
      end

      # ===== solid_report ====================================================

      def self.solid_report(params)
        ids          = V.require_id_list(params, "ids", min: 1, max: 200)
        children     = V.optional_bool(params, "children", false)
        samples      = V.optional_int_range(params, "max_samples", min: 0, max: 50, default: 5)
        save_as      = V.optional_string(params, "save_as")
        compare_with = V.optional_string(params, "compare_with")
        until_time   = deadline(params)
        if compare_with && !snapshots.key?(compare_with)
          raise E.new(-32602, "no snapshot named #{compare_with.inspect}; " \
                              "saved: #{snapshots.keys.inspect}")
        end
        model = EH.active_model!
        ctx = S.context(model)
        parts = []
        ids.each do |id|
          inst, chain = placed_instance!(id, ctx)
          if children
            inner = chain + [inst]
            EH.entity_collection(inst).each { |e| parts << [e, inner] if S.instance?(e) }
          else
            parts << [inst, chain]
          end
        end

        rows = []
        complete = true
        parts.each do |inst, chain|
          if now > until_time
            complete = false
            break
          end
          rows << part_row(inst, S.step(S.frame(chain, ctx), inst, ctx), samples)
        end

        result = { "parts" => rows, "complete" => complete }
        result["edit_mode_ambiguous"] = true if ctx.ambiguous
        result["diff"] = diff_rows(snapshots[compare_with][:rows], rows) if compare_with
        if save_as
          store_snapshot(save_as, rows, complete)
          result["saved_as"] = save_as
        end
        result
      end

      # What a part is made of, from its own faces and edges. Nested groups
      # inside it are counted and boxed, but a solid holds only faces and
      # edges, so their faces stay out of the volume and the edge checks.
      def self.part_row(inst, frame, samples)
        m = frame.to_a
        faces = []
        edges = []
        nested = []
        EH.entity_collection(inst).each do |e|
          if e.is_a?(Sketchup::Face) then faces << e
          elsif e.is_a?(Sketchup::Edge) then edges << e
          elsif S.instance?(e) then nested << e
          end
        end
        tris = faces.flat_map { |f| S.face_triangles(f, m) }
        open = edges.select { |e| e.faces.length == 1 }
        multi = edges.select { |e| e.faces.length > 2 }
        stray = edges.count { |e| e.faces.empty? }

        box = M.bounds(tris.flatten(1))
        edges.each do |e|
          box = M.union(box, M.bounds([S.point(e.start.position, m), S.point(e.end.position, m)]))
        end
        nested.each { |n| box = M.union(box, S.box_through(n.bounds, m)) }

        manifold = inst.respond_to?(:manifold?) ? inst.manifold? : nil
        signed = M.signed_volume(tris)
        {
          "id"                  => inst.entityID,
          "name"                => S.label(inst),
          "type"                => S.type_name(inst),
          "tag"                 => inst.layer.name,
          "faces"               => faces.length,
          "edges"               => edges.length,
          "nested_instances"    => nested.length,
          "manifold"            => manifold,
          "volume_mm3"          => manifold ? (signed.abs * U::MM**3).round(1) : nil,
          "orientation"         => manifold ? (signed >= 0 ? "outward" : "inward") : nil,
          "area_mm2"            => (M.area(tris) * U::MM**2).round(1),
          "bbox_mm"             => S.box_mm(box),
          "open_edges"          => open.length,
          "nonmanifold_edges"   => multi.length,
          "stray_edges"         => stray,
          "open_edge_samples_mm"        => open.first(samples).map { |e| midpoint_mm(e, m) },
          "nonmanifold_edge_samples_mm" => multi.first(samples).map { |e| midpoint_mm(e, m) },
        }
      end

      def self.midpoint_mm(edge, m)
        a = S.point(edge.start.position, m)
        b = S.point(edge.end.position, m)
        S.mm([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2])
      end

      # Snapshots live in memory for the session: a rebuild compared with
      # the build before it. Kept per label, oldest dropped past the limit.
      def self.snapshots
        @snapshots ||= {}
      end

      def self.store_snapshot(label, rows, complete)
        snapshots.delete(label)
        snapshots[label] = { rows: rows, complete: complete, taken_at: Time.now.to_s }
        snapshots.delete(snapshots.keys.first) while snapshots.length > SNAPSHOT_LIMIT
      end

      COMPARED = %w[faces edges nested_instances manifold volume_mm3 area_mm2
                    open_edges nonmanifold_edges stray_edges bbox_mm].freeze

      # Parts are matched by name, the n-th "Wall 1" with the n-th "Wall 1":
      # a rebuild makes new groups with new ids but the same names.
      def self.diff_rows(before, after)
        old = keyed(before)
        new = keyed(after)
        changed = []
        unchanged = 0
        (old.keys & new.keys).each do |key|
          fields = {}
          COMPARED.each do |f|
            fields[f] = [old[key][f], new[key][f]] unless same_value?(old[key][f], new[key][f])
          end
          if fields.empty?
            unchanged += 1
          else
            changed << { "part" => key, "changes" => fields }
          end
        end
        { "added" => new.keys - old.keys, "removed" => old.keys - new.keys,
          "changed" => changed, "unchanged" => unchanged }
      end

      def self.keyed(rows)
        seen = Hash.new(0)
        rows.each_with_object({}) do |row, out|
          n = (seen[row["name"]] += 1)
          out[n == 1 ? row["name"] : "#{row["name"]} ##{n}"] = row
        end
      end

      # Volumes and areas drift in the last digit between identical builds;
      # boxes are compared per coordinate to a hundredth of a millimetre.
      def self.same_value?(a, b)
        return a == b unless a.is_a?(Numeric) && b.is_a?(Numeric) || a.is_a?(Hash) && b.is_a?(Hash)
        if a.is_a?(Hash)
          return %w[min max].all? do |k|
            a[k].zip(b[k]).all? { |x, y| (x - y).abs <= 0.011 }
          end
        end
        (a - b).abs <= [1.0, a.abs * 1e-6].max
      end

      # ===== query_faces =====================================================

      ORIENTATIONS = %w[any up down vertical sloped].freeze

      def self.query_faces(params)
        recursive   = V.optional_bool(params, "recursive", false)
        orientation = V.optional_enum(params, "orientation", ORIENTATIONS, "any")
        tolerance   = V.optional_number_range(params, "angle_tolerance_deg", min: 0, max: 45,
                                                                             default: 1.0)
        normal      = V.optional_coords3(params, "normal")
        if normal && M.unit(normal).nil?
          raise E.new(-32602, "field normal must not be the zero vector")
        end
        box         = optional_box_mm(params, "within_mm")
        min_area    = V.optional_number_range(params, "min_area_mm2", min: 0, max: Float::MAX,
                                                                      default: 0.0)
        tag         = V.optional_string(params, "tag")
        material    = V.optional_string(params, "material")
        vertices    = V.optional_bool(params, "include_vertices", true)
        limit       = V.optional_int_range(params, "limit", min: 1, max: 500, default: 100)
        offset      = V.optional_int_nonneg(params, "offset", 0)
        until_time  = deadline(params)
        id          = params.key?("id") ? V.require_id(params) : nil
        model = EH.active_model!
        ctx = S.context(model)

        if id
          inst, chain = placed_instance!(id, ctx)
          frame = S.step(S.frame(chain, ctx), inst, ctx)
          root = EH.entity_collection(inst)
        else
          # The active context: what SketchUp shows the user as editable,
          # already reported in world coordinates.
          frame = Geom::Transformation.new
          root = model.active_entities
        end

        matches = []
        complete = true
        walk = lambda do |entities, t, owner, depth|
          m = t.to_a
          entities.each do |e|
            if now > until_time
              complete = false
              break
            end
            if e.is_a?(Sketchup::Face)
              n = M.normal_through(m, vec(e.normal, 12))
              next unless n
              next unless facing?(n, orientation, tolerance)
              next if normal && M.angle_deg(n, normal) > tolerance
              next if tag && !tag_matches?(e.layer, tag)
              next if material && !material_matches?(e, material)
              area = U.inch_to_mm(U.inch_to_mm(e.area(t)))
              next if area < min_area
              outer = e.outer_loop.vertices.map { |v| S.point(v.position, m) }
              face_box = M.bounds(outer)
              next if box && !M.overlaps?(face_box, box)
              matches << [e, n, area, outer, face_box, owner]
            elsif recursive && S.instance?(e) && depth < S::MAX_DEPTH
              walk.call(EH.entity_collection(e), S.step(t, e, ctx), e, depth + 1)
            end
          end
        end
        walk.call(root, frame, id ? inst : nil, 0)

        page = (matches[offset, limit] || []).map do |face, n, area, outer, face_box, owner|
          row = {
            "id"             => face.entityID,
            "area_mm2"       => area.round(1),
            "normal"         => n.map { |v| v.round(6) },
            "plane_offset_mm" => (M.dot(n, outer.first) * U::MM).round(2),
            "bbox_mm"        => S.box_mm(face_box),
            "holes"          => face.loops.length - 1,
            "material"       => face.material&.display_name,
            "back_material"  => face.back_material&.display_name,
            "tag"            => face.layer.name,
            "parent_id"      => owner&.entityID,
          }
          row["vertices_mm"] = outer.map { |p| S.mm(p) } if vertices
          row
        end
        result = { "faces" => page, "total" => matches.length, "offset" => offset,
                   "truncated" => offset + page.length < matches.length, "complete" => complete }
        result["edit_mode_ambiguous"] = true if ctx.ambiguous
        result
      end

      def self.facing?(n, orientation, tolerance)
        z = n[2]
        flat = Math.cos(tolerance * Math::PI / 180.0)
        upright = Math.sin(tolerance * Math::PI / 180.0)
        case orientation
        when "up"       then z >= flat
        when "down"     then z <= -flat
        when "vertical" then z.abs <= upright
        when "sloped"   then z.abs > upright && z.abs < flat
        else true
        end
      end

      # SketchUp 2020 renamed layers to tags and shows Layer0 as "Untagged".
      def self.tag_matches?(layer, tag)
        return true if layer.name == tag
        %w[Untagged Layer0].include?(tag) && layer == layer.model.layers[0]
      end

      def self.material_matches?(face, name)
        [face.material, face.back_material].any? do |mat|
          mat && (mat.display_name == name || mat.name == name)
        end
      end

      def self.optional_box_mm(params, key)
        return nil unless params.key?(key)
        v = params[key]
        unless v.is_a?(Hash) && v.key?("min") && v.key?("max")
          raise E.new(-32602, "field #{key} must be an object {min: [x,y,z], max: [x,y,z]} in mm")
        end
        min = V.require_coords3(v, "min")
        max = V.require_coords3(v, "max")
        S.box_from_mm(min, max)
      end

      # ===== find_overlaps ===================================================

      def self.find_overlaps(params)
        per_axis       = V.optional_int_range(params, "samples_per_axis", min: 4, max: 40, default: 12)
        tolerance      = U.mm_to_inch(V.optional_number_range(params, "tolerance_mm", min: 0,
                                                                         max: 1000, default: 1.0))
        include_hidden = V.optional_bool(params, "include_hidden", false)
        until_time     = deadline(params)
        if params.key?("container_id") && params.key?("ids")
          raise E.new(-32602, "pass either ids or container_id, not both")
        end
        container = params.key?("container_id") ? V.require_id(params, "container_id") : nil
        ids = params.key?("ids") ? V.require_id_list(params, "ids", min: 2, max: 200) : nil
        unless container || ids
          raise E.new(-32602, "pass ids (2 or more groups/components) or container_id")
        end
        model = EH.active_model!
        ctx = S.context(model)

        parts =
          if container
            box, chain = placed_instance!(container, ctx)
            inner = chain + [box]
            EH.entity_collection(box).select { |e| S.instance?(e) }.map { |e| [e, inner] }
          else
            ids.map { |id| placed_instance!(id, ctx) }
          end
        parts.reject! { |inst, _| inst.hidden? || !inst.layer.visible? } unless include_hidden
        if parts.length < 2
          raise E.new(-32602, "need at least 2 visible groups/components to compare, got #{parts.length}")
        end

        solids = []
        parts.each do |inst, chain|
          if now > until_time
            return overlap_result(parts, solids, [], 0, 0, false, per_axis, ctx)
          end
          frame = S.step(S.frame(chain, ctx), inst, ctx)
          solids << [inst, M::Solid.new(S.deep_triangles(inst, frame, ctx, until_time))]
        end

        pairs = []
        solids.each_with_index do |(_, a), i|
          next if a.empty?
          solids[(i + 1)..].each_with_index do |(_, b), j|
            next if b.empty?
            common = M.intersection(a.box, b.box)
            common &&= M.shrink(common, tolerance)
            pairs << [i, i + 1 + j, common] if common
          end
        end

        found = []
        shallow = []
        checked = 0
        complete = true
        pairs.each do |i, j, common|
          if now > until_time
            complete = false
            break
          end
          a = solids[i][1]
          b = solids[j][1]
          points = M.samples(common, per_axis)
          hits = []
          skimmed = 0
          points.each_with_index do |p, k|
            if (k & 63).zero? && now > until_time
              complete = false
              break
            end
            next unless a.inside?(p) && b.inside?(p)
            # Within tolerance of either surface: a contact, not a clash. A
            # wall end meeting a slanted column face can sit a hundredth of a
            # millimetre into it, and the box shrink above only trims
            # contacts that are axis-aligned.
            if tolerance > 0 && (a.near_surface?(p, tolerance) || b.near_surface?(p, tolerance))
              skimmed += 1
            else
              hits << p
            end
          end
          break unless complete
          checked += 1
          if hits.empty?
            if skimmed > 0
              shallow << { "a" => S.label(solids[i][0]), "b" => S.label(solids[j][0]),
                           "hits" => skimmed }
            end
            next
          end
          depth = hits.first(DEPTH_SAMPLES).map { |p| [a.distance(p), b.distance(p)].min }.max
          found << {
            "a" => S.ref(solids[i][0]),
            "b" => S.ref(solids[j][0]),
            "hits" => hits.length,
            "samples" => points.length,
            "overlap_volume_mm3" => (M.volume(common) * hits.length / points.length * U::MM**3).round(0),
            "max_depth_mm" => (depth * U::MM).round(2),
            "box_mm" => S.box_mm(common),
            "sample_points_mm" => hits.first(3).map { |p| S.mm(p) },
          }
        end
        result = overlap_result(parts, solids, found, pairs.length, checked, complete, per_axis, ctx)
        result["within_tolerance"] = shallow.first(20) unless shallow.empty?
        result
      end

      # Hits measured for max_depth_mm: the deepest of these, each the
      # distance to the nearer of the two surfaces.
      DEPTH_SAMPLES = 50

      def self.overlap_result(parts, solids, found, total, checked, complete, per_axis, ctx)
        open = solids.select { |inst, _| inst.respond_to?(:manifold?) && !inst.manifold? }
        result = {
          "parts" => parts.length,
          "pairs_total" => total,
          "pairs_checked" => checked,
          "complete" => complete && solids.length == parts.length,
          "samples_per_axis" => per_axis,
          "overlaps" => found.sort_by { |o| -o["overlap_volume_mm3"] },
        }
        unless open.empty?
          result["not_solid"] = open.map { |inst, _| S.ref(inst) }
          result["warning"] = "inside/outside is read by ray parity, which assumes closed parts; " \
                              "results for the parts in not_solid are approximate"
        end
        result["edit_mode_ambiguous"] = true if ctx.ambiguous
        result
      end

      # ===== raycast =========================================================

      def self.raycast(params)
        origin_mm = V.require_coords3(params, "origin_mm")
        dir = V.require_coords3(params, "direction")
        raise E.new(-32602, "field direction must not be the zero vector") unless M.unit(dir)
        max_hits = V.optional_int_range(params, "max_hits", min: 1, max: 50, default: 5)
        include_hidden = V.optional_bool(params, "include_hidden", false)
        max_mm = V.optional_number_range(params, "max_distance_mm", min: 0, max: Float::MAX,
                                                                    default: nil)
        model = EH.active_model!
        ctx = S.context(model)

        origin = Geom::Point3d.new(*origin_mm.map { |v| U.mm_to_inch(v) })
        vector = Geom::Vector3d.new(*M.unit(dir))
        start = origin
        hits = []
        # One hit per call to raytest; the next ray starts just past it. A
        # ray through an edge reports the edge and then the faces beside it
        # at the same distance, so a repeat at the same spot is skipped.
        (max_hits * 4).times do
          break if hits.length >= max_hits
          found = model.raytest([start, vector], !include_hidden)
          break unless found
          point, path = found
          dist = U.inch_to_mm(origin.distance(point))
          break if max_mm && dist > max_mm
          leaf = path.last
          start = point.offset(vector, 0.001)
          next if hits.any? { |h| (h["distance_mm"] - dist).abs < 0.01 && h["entity"]["id"] == leaf.entityID }
          hit = {
            "point_mm"    => point_mm(point),
            "distance_mm" => dist.round(2),
            "entity"      => { "id" => leaf.entityID, "type" => S.type_name(leaf) },
            "tag"         => leaf.respond_to?(:layer) ? leaf.layer.name : nil,
            "path"        => path[0..-2].select { |e| S.instance?(e) }.map { |i| S.ref(i) },
          }
          if leaf.is_a?(Sketchup::Face)
            instances = path[0..-2].select { |e| S.instance?(e) }
            n = M.normal_through(S.frame(instances, ctx).to_a, vec(leaf.normal, 12))
            hit["normal"] = n&.map { |v| v.round(6) }
            hit["material"] = leaf.material&.display_name
          end
          hits << hit
        end
        result = { "hits" => hits }
        result["edit_mode_ambiguous"] = true if ctx.ambiguous
        result
      end

      # ===== scene_stats =====================================================

      def self.scene_stats(params)
        top = V.optional_int_range(params, "top", min: 1, max: 50, default: 10)
        until_time = deadline(params)
        id = params.key?("id") ? V.require_id(params) : nil
        model = EH.active_model!
        if id
          inst = EH.require_group_or_component!(EH.find!(id))
          scope = S.ref(inst)
          root = count_level(EH.entity_collection(inst))
        else
          scope = "model"
          root = count_level(model.entities)
        end

        # Each definition is counted once; how often it occurs is carried
        # down in topological order, so a chair in a table in a room costs
        # one count of the chair, not one per chair.
        own = {}
        order = []
        complete = true
        visit = lambda do |defn, depth|
          return if own.key?(defn) || depth > S::MAX_DEPTH
          if now > until_time
            complete = false
            return
          end
          own[defn] = count_level(defn.entities)
          own[defn][:children].each_key { |child| visit.call(child, depth + 1) }
          order.unshift(defn)
        end
        root[:children].each_key { |defn| visit.call(defn, 0) }

        occurrences = Hash.new(0)
        root[:children].each { |defn, n| occurrences[defn] += n }
        order.each do |defn|
          own[defn][:children].each { |child, n| occurrences[child] += occurrences[defn] * n }
        end

        flat = { "faces" => root[:faces], "edges" => root[:edges], "instances" => root[:instances],
                 "hidden" => root[:hidden] }
        tags = Hash.new(0).merge(root[:tags])
        instance_tags = Hash.new(0).merge(root[:instance_tags])
        own.each do |defn, c|
          k = occurrences[defn]
          flat["faces"] += c[:faces] * k
          flat["edges"] += c[:edges] * k
          flat["instances"] += c[:instances] * k
          flat["hidden"] += c[:hidden] * k
          c[:tags].each { |tag, n| tags[tag] += n * k }
          c[:instance_tags].each { |tag, n| instance_tags[tag] += n * k }
        end
        heaviest = own.map do |defn, c|
          { "definition" => defn.name, "faces_each" => c[:faces], "occurrences" => occurrences[defn],
            "faces_total" => c[:faces] * occurrences[defn] }
        end
        heaviest = heaviest.sort_by { |h| -h["faces_total"] }.first(top)
        layers = model.layers
        {
          "scope" => scope,
          "direct" => { "faces" => root[:faces], "edges" => root[:edges],
                        "groups" => root[:groups], "components" => root[:components],
                        "other" => root[:other] },
          "flattened" => flat,
          "definitions" => { "in_scope" => own.length, "in_model" => model.definitions.length },
          "heaviest_definitions" => heaviest,
          "faces_by_tag" => by_tag(tags, layers, "faces"),
          # Tags usually sit on instances rather than on the faces inside
          # them, and an instance on a hidden tag hides all it holds.
          "instances_by_tag" => by_tag(instance_tags, layers, "instances"),
          "materials" => model.materials.length,
          "complete" => complete,
        }
      end

      def self.by_tag(counts, layers, key)
        counts.sort_by { |_, n| -n }.first(20).map do |name, n|
          layer = layers[name]
          { "tag" => name, key => n, "visible" => layer ? layer.visible? : nil }
        end
      end

      def self.count_level(entities)
        c = { faces: 0, edges: 0, groups: 0, components: 0, other: 0, instances: 0, hidden: 0,
              tags: Hash.new(0), instance_tags: Hash.new(0), children: Hash.new(0) }
        entities.each do |e|
          c[:hidden] += 1 if e.respond_to?(:hidden?) && e.hidden?
          case e
          when Sketchup::Face
            c[:faces] += 1
            c[:tags][e.layer.name] += 1
          when Sketchup::Edge
            c[:edges] += 1
          when Sketchup::Group, Sketchup::ComponentInstance
            c[e.is_a?(Sketchup::Group) ? :groups : :components] += 1
            c[:instances] += 1
            c[:instance_tags][e.layer.name] += 1
            c[:children][e.definition] += 1
          else
            c[:other] += 1
          end
        end
        c
      end

      # ===== get_attributes ==================================================

      MAX_KEYS       = 200
      MAX_STRING     = 2000

      def self.get_attributes(params)
        id = V.require_id(params)
        only = V.optional_string(params, "dictionary")
        with_definition = V.optional_bool(params, "include_definition", true)
        entity = EH.find!(id)
        out = { "id" => entity.entityID, "type" => S.type_name(entity),
                "entity" => dictionaries_json(entity, only) }
        if with_definition && entity.respond_to?(:definition)
          out["definition"] = dictionaries_json(entity.definition, only)
        end
        out
      end

      def self.dictionaries_json(entity, only)
        dicts = entity.attribute_dictionaries
        return {} unless dicts
        dicts.each_with_object({}) do |dict, out|
          next if only && dict.name != only
          values = {}
          dict.each do |key, value|
            break if values.length >= MAX_KEYS
            values[key.to_s] = json_value(value)
          end
          out[dict.name] = values
        end
      end

      # Attribute values as JSON can carry them. Lengths stay in inches —
      # they are raw stored values, not model dimensions.
      def self.json_value(v, depth = 0)
        case v
        when nil, true, false, Integer then v
        # to_f: a Length may be a Float underneath, and JSON must not get it
        # as a formatted length.
        when Float then v.to_f.finite? ? v.to_f : v.to_s
        when String then v.length > MAX_STRING ? "#{v[0, MAX_STRING]}…" : v
        when Array then depth > 4 ? v.inspect[0, 200] : v.map { |x| json_value(x, depth + 1) }
        when Hash then v.to_h { |k, x| [k.to_s, json_value(x, depth + 1)] }
        when Time then v.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        else
          if v.respond_to?(:x) && v.respond_to?(:y) && v.respond_to?(:z)
            [v.x.to_f, v.y.to_f, v.z.to_f]
          elsif v.class.name == "Length"
            v.to_f
          elsif v.respond_to?(:to_a) && v.class.name == "Sketchup::Color"
            v.to_a
          else
            v.inspect[0, 200]
          end
        end
      end
    end
  end
end
