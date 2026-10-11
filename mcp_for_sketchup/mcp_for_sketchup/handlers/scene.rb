# mcp_for_sketchup/mcp_for_sketchup/handlers/scene.rb
#
# Tools that act on the scene rather than on geometry: the selection, tags
# and visibility, attribute dictionaries, an isolated and framed capture of
# chosen entities, and a frame-time profile of the viewport.
#
# Every model edit is one operation, so it is one Undo step. capture_view
# hides things inside an operation it always aborts, so the shot leaves no
# trace — not even an Undo entry — and restores the camera and rendering
# options it touched.
require "base64"
require "set"
require "tempfile"

module MCPforSketchUp
  module Handlers
    module Scene
      V  = MCPforSketchUp::Helpers::Validation
      EH = MCPforSketchUp::Helpers::Entities
      U  = MCPforSketchUp::Helpers::Units
      S  = MCPforSketchUp::Helpers::Space
      M  = MCPforSketchUp::Helpers::Mesh
      E  = MCPforSketchUp::Core::StructuredError

      # ===== select_entities =================================================

      SELECT_MODES = %w[replace add remove toggle clear].freeze

      # SketchUp selects only inside the context the user is editing, so ids
      # elsewhere are reported back instead of being half-selected.
      def self.select_entities(params)
        mode = V.optional_enum(params, "mode", SELECT_MODES, "replace")
        ids = mode == "clear" ? [] : V.require_id_list(params, "ids", min: 1, max: 1000)
        model = EH.active_model!
        here = model.active_entities.parent
        found = []
        missing = []
        elsewhere = []
        ids.each do |id|
          e = model.find_entity_by_id(id)
          if e.nil? || !e.valid?
            missing << id
          elsif e.parent != here
            elsewhere << id
          else
            found << e
          end
        end
        selection = model.selection
        case mode
        when "replace"
          selection.clear
          selection.add(found) unless found.empty?
        when "add"    then selection.add(found) unless found.empty?
        when "remove" then selection.remove(found) unless found.empty?
        when "toggle" then selection.toggle(found) unless found.empty?
        when "clear"  then selection.clear
        end
        {
          "mode" => mode,
          "applied" => found.length,
          "selected" => selection.length,
          "missing_ids" => missing,
          "not_in_active_context" => elsewhere,
        }
      end

      # ===== set_entity_properties ===========================================

      def self.set_entity_properties(params)
        ids = V.require_id_list(params, "ids", min: 1, max: 1000)
        tag = V.optional_string(params, "tag")
        create_tag = V.optional_bool(params, "create_tag", true)
        hidden = params.key?("hidden") ? V.optional_bool(params, "hidden") : nil
        locked = params.key?("locked") ? V.optional_bool(params, "locked") : nil
        name = nil
        if params.key?("name")
          name = params["name"]
          raise E.new(-32602, "field name must be a string") unless name.is_a?(String)
        end
        if [tag, hidden, locked, name].all?(&:nil?)
          raise E.new(-32602, "nothing to set: pass tag, hidden, locked or name")
        end

        model = EH.active_model!
        entities = ids.map { |id| EH.find!(id) }   # every id checked before anything changes
        layer = tag && find_tag(model, tag)
        if tag && layer.nil? && !create_tag
          raise E.new(-32602, "tag #{tag.inspect} does not exist; pass create_tag: true to add it")
        end

        model.start_operation("Set Entity Properties", true)
        begin
          created = false
          if tag && layer.nil?
            layer = model.layers.add(tag)
            created = true
          end
          updated = 0
          not_applied = []
          entities.each do |e|
            why = []
            applied = 0
            if layer
              if e.respond_to?(:layer=) then e.layer = layer; applied += 1
              else why << "has no tag"
              end
            end
            unless hidden.nil?
              if e.respond_to?(:hidden=) then e.hidden = hidden; applied += 1
              else why << "cannot be hidden"
              end
            end
            unless locked.nil?
              if e.respond_to?(:locked=) then e.locked = locked; applied += 1
              else why << "only groups and components lock"
              end
            end
            unless name.nil?
              if S.instance?(e) then e.name = name; applied += 1
              else why << "only groups and components have names"
              end
            end
            updated += 1 if applied > 0
            unless why.empty?
              not_applied << { "id" => e.entityID, "type" => S.type_name(e), "reason" => why.join("; ") }
            end
          end
          model.commit_operation
          { "updated" => updated, "not_applied" => not_applied, "tag" => layer&.name,
            "tag_created" => created }
        rescue StandardError
          MCPforSketchUp::Handlers::Geometry.safe_abort(model)
          raise
        end
      end

      # SketchUp 2020 renamed layers to tags and shows Layer0 as "Untagged".
      def self.find_tag(model, tag)
        return model.layers[0] if %w[Untagged Layer0].include?(tag)
        model.layers[tag]
      end

      # ===== set_attributes ==================================================

      SCALARS = [String, Integer, Float, TrueClass, FalseClass].freeze

      def self.set_attributes(params)
        id = V.require_id(params)
        dict = V.require_string(params, "dictionary")
        target = V.optional_enum(params, "target", %w[instance definition], "instance")
        values = params["values"]
        unless values.is_a?(Hash) && values.length.between?(1, 200)
          raise E.new(-32602, "field values must be an object with 1..200 keys")
        end
        values.each do |key, value|
          raise E.new(-32602, "attribute keys must be non-empty strings") if key.to_s.empty?
          next if value.nil? || SCALARS.any? { |c| value.is_a?(c) }
          next if value.is_a?(Array) && value.all? { |x| x.nil? || SCALARS.any? { |c| x.is_a?(c) } }
          raise E.new(-32602, "attribute #{key.inspect}: values must be strings, numbers, " \
                              "booleans, null (deletes the key) or flat arrays of those")
        end
        entity = EH.find!(id)
        holder =
          if target == "definition"
            unless entity.respond_to?(:definition)
              raise E.new(-32602, "target definition needs a group or component, got #{S.type_name(entity)}")
            end
            entity.definition
          else
            entity
          end

        model = EH.active_model!
        model.start_operation("Set Attributes", true)
        begin
          set = []
          deleted = []
          absent = []
          values.each do |key, value|
            if value.nil?
              if holder.delete_attribute(dict, key.to_s) then deleted << key.to_s
              else absent << key.to_s
              end
            else
              holder.set_attribute(dict, key.to_s, value)
              set << key.to_s
            end
          end
          model.commit_operation
          { "id" => entity.entityID, "target" => target, "dictionary" => dict,
            "set" => set, "deleted" => deleted, "absent" => absent }
        rescue StandardError
          MCPforSketchUp::Handlers::Geometry.safe_abort(model)
          raise
        end
      end

      # ===== capture_view ====================================================

      # Rendering options that hide or fade what lies outside the group being
      # edited. A shot framed on entities outside it would come out empty or
      # faint, so they are switched off for the shot and put back. The fades
      # are opacities: 1.0 draws the rest of the model unfaded (checked on
      # SketchUp 2026 by rendering 0.0 and 1.0 side by side).
      CONTEXT_RO = { "InactiveHidden" => false, "InactiveFade" => 1.0,
                     "InstanceHidden" => false, "InstanceFade" => 1.0 }.freeze

      # Copies of View's lists, so parameters are checked without loading
      # view.rb (its PRESET_DIR builds Geom vectors at load time).
      # test_jini_tools.rb pins them to view.rb's.
      PRESETS = %w[current front back left right top bottom iso].freeze
      STYLES  = %w[default shaded hidden_line wireframe].freeze
      MIN_SIZE = 64
      MAX_SIZE = 4096

      def self.capture_view(params)
        ids = params.key?("ids") ? V.require_id_list(params, "ids", min: 1, max: 500) : []
        isolate = V.optional_bool(params, "isolate", !ids.empty?)
        fit = V.optional_bool(params, "fit", !ids.empty?)
        preset = V.optional_enum(params, "view_preset", PRESETS, "current")
        style = V.optional_enum(params, "style", STYLES, "default")
        max_size = V.optional_int_range(params, "max_size", min: MIN_SIZE, max: MAX_SIZE,
                                                            default: 1024)
        margin = V.optional_number_range(params, "margin", min: 1.0, max: 3.0, default: 1.15)
        if (isolate || fit) && ids.empty?
          raise E.new(-32602, "isolate and fit need ids")
        end
        model = EH.active_model!
        view = model.active_view
        raise E.new(-32000, "no active view") if view.nil?

        vw = view.vpwidth.to_f
        vh = view.vpheight.to_f
        raise E.new(-32603, "viewport has zero dimensions (vw=#{vw}, vh=#{vh})") if vw <= 0 || vh <= 0
        cam = view.camera
        if cam.respond_to?(:is_2d?) && cam.is_2d?
          raise E.new(-32000, "capture_view can't restore a 2D / match-photo camera; " \
                              "use get_viewport_screenshot with restore_view=false")
        end

        ctx = S.context(model)
        targets = ids.map do |id|
          e = EH.find!(id)
          raise E.new(-32602, "entity #{id} (#{S.type_name(e)}) has no extent") unless e.respond_to?(:bounds)
          chain = S.chain_to(e, ctx)
          raise E.new(-32602, "entity #{id} is not placed in the model") unless chain
          [e, chain]
        end
        box = targets.reduce(nil) do |acc, (e, chain)|
          M.union(acc, S.box_through(e.bounds, S.frame(chain, ctx).to_a))
        end
        warnings = []
        targets.each do |e, chain|
          hidden_tags = (chain + [e]).map(&:layer).reject(&:visible?).map(&:name).uniq
          unless hidden_tags.empty?
            warnings << "entity #{e.entityID} sits on hidden tag(s) #{hidden_tags.join(', ')}"
          end
        end

        snap_camera = copy_camera(cam)
        ro = model.rendering_options
        touched = {}
        touched.merge!(View::STYLE_RO[style]) if style != "default"
        touched.merge!(CONTEXT_RO) if ctx.open.any? && (isolate || fit)
        known = ro.keys
        touched.select! { |k, _| known.include?(k) }
        saved_ro = touched.keys.to_h { |k| [k, ro[k]] }

        out_w, out_h = scaled(vw, vh, max_size)
        hidden_count = 0
        op = false
        data = nil
        begin
          if isolate
            model.start_operation("Capture View", true)
            op = true
            hidden_count = isolate!(model, targets)
          end
          touched.each do |k, v|
            begin
              ro[k] = v
            rescue StandardError => e
              warnings << "rendering option #{k} could not be set: #{e.message}"
            end
          end
          if fit && box
            view.camera = fit_camera(preset, box, cam, vw / vh, margin)
          elsif preset != "current"
            view.camera = View.build_preset_camera(
              preset, MCPforSketchUp::Helpers::Geometry.visible_bounds(model), cam)
          end
          data = write_png(view, out_w, out_h)
        ensure
          MCPforSketchUp::Handlers::Geometry.safe_abort(model) if op
          saved_ro.each do |k, v|
            begin
              ro[k] = v
            rescue StandardError
              nil
            end
          end
          view.camera = snap_camera
        end

        {
          "png_base64"     => Base64.strict_encode64(data),
          "width"          => out_w,
          "height"         => out_h,
          "preset_used"    => preset,
          "style_used"     => style,
          "fitted_bbox_mm" => fit ? S.box_mm(box) : nil,
          "hidden_count"   => hidden_count,
          "warnings"       => warnings,
        }
      end

      # Hide everything that isn't a target or on the way to one, level by
      # level: the model's top level, then inside each instance on a
      # target's path. Targets and their path are unhidden if they were
      # hidden. Runs inside an operation the caller aborts.
      def self.isolate!(model, targets)
        keep = Hash.new { |h, k| h[k] = Set.new }
        levels = {}
        targets.each do |target, chain|
          entities = model.entities
          key = :model
          (chain + [target]).each do |node|
            levels[key] = entities
            keep[key] << node.entityID
            node.hidden = false if node.respond_to?(:hidden?) && node.hidden?
            break if node.equal?(target) || !S.instance?(node)
            entities = EH.entity_collection(node)
            key = node.definition.entityID
          end
        end
        count = 0
        levels.each do |key, entities|
          entities.each do |e|
            next if keep[key].include?(e.entityID)
            next unless e.respond_to?(:hidden=) && !e.hidden?
            e.hidden = true
            count += 1
          end
        end
        count
      end

      # Camera looking at the box from the preset's direction (or the current
      # view direction). A perspective camera backs off until the box's
      # bounding sphere fits; a parallel one is sized to the box's corners as
      # seen along the view, which frames a tall thin part much tighter.
      def self.fit_camera(preset, box, current, aspect, margin)
        if preset == "current"
          dir = current.eye - current.target
          up = current.up
        else
          dir, up = View::PRESET_DIR[preset]
          dir = Geom::Vector3d.new(dir.x, dir.y, dir.z)
        end
        dir = Geom::Vector3d.new(0, 0, 1) if dir.length.to_f == 0.0
        dir.normalize!
        center = Geom::Point3d.new(*3.times.map { |i| (box[0][i] + box[1][i]) / 2.0 })
        radius = [Math.sqrt(3.times.sum { |i| (box[1][i] - box[0][i])**2 }) / 2.0, 1.0].max * margin
        if current.perspective?
          half = half_fov(current, aspect)
          eye = center.offset(dir, radius / Math.sin(half))
          camera = Sketchup::Camera.new(eye, center, up)
          camera.perspective = true
          camera.fov = current.fov
        else
          eye = center.offset(dir, radius * 4)
          camera = Sketchup::Camera.new(eye, center, up)
          camera.perspective = false
          half_w, half_h = projected_half_extents(box, camera.xaxis, camera.yaxis)
          camera.height = 2 * [half_h, half_w / aspect, 1.0].max * margin
        end
        camera
      end

      # Half the width and height of the box seen along a view: its corners
      # measured along the camera's right and up axes.
      def self.projected_half_extents(box, right, up)
        c = 3.times.map { |i| (box[0][i] + box[1][i]) / 2.0 }
        corners = [0, 1].product([0, 1], [0, 1]).map do |i, j, k|
          [box[i][0] - c[0], box[j][1] - c[1], box[k][2] - c[2]]
        end
        [corners.map { |p| (p[0] * right.x + p[1] * right.y + p[2] * right.z).abs }.max,
         corners.map { |p| (p[0] * up.x + p[1] * up.y + p[2] * up.z).abs }.max]
      end

      # Half the narrower field of view, in radians. Camera#fov is vertical
      # unless fov_is_height? says otherwise; without that method both
      # readings are allowed for and the narrower wins.
      def self.half_fov(camera, aspect)
        half = camera.fov.to_f * Math::PI / 360.0
        t = Math.tan(half)
        if camera.respond_to?(:fov_is_height?)
          if camera.fov_is_height?
            [half, Math.atan(t * aspect)].min
          else
            [half, Math.atan(t / aspect)].min
          end
        else
          [half, Math.atan(t * aspect), Math.atan(t / aspect)].min
        end
      end

      def self.copy_camera(c)
        copy = Sketchup::Camera.new(c.eye, c.target, c.up)
        copy.perspective = c.perspective?
        if c.perspective?
          copy.fov = c.fov
        else
          copy.height = c.height
        end
        copy
      end

      def self.scaled(vw, vh, max_size)
        scale = max_size.to_f / [vw, vh].max
        [(vw * scale).round, (vh * scale).round]
      end

      def self.write_png(view, width, height)
        Tempfile.create(["sumcp_cap_", ".png"]) do |tmp|
          tmp.close
          ok = view.write_image(filename: tmp.path, width: width, height: height,
                                antialias: true, compression: 1.0, transparent: false)
          raise E.new(-32000, "viewport write_image failed") unless ok
          size = File.size(tmp.path)
          if size > View::MAX_RAW_BYTES
            raise E.new(-32000, "capture too large: #{size} bytes -- reduce max_size")
          end
          File.binread(tmp.path)
        end
      end

      # ===== profile_view ====================================================

      PROFILE_SECONDS = 30

      # Time full redraws. View#refresh draws synchronously, so its wall time
      # is the cost of one frame. With orbit_degrees the camera swings round
      # its target between frames, the way the Orbit tool moves it, and is
      # put back afterwards.
      def self.profile_view(params)
        frames = V.optional_int_range(params, "frames", min: 1, max: 120, default: 20)
        orbit = V.optional_number_range(params, "orbit_degrees", min: 0, max: 360, default: 0.0)
        model = EH.active_model!
        view = model.active_view
        raise E.new(-32000, "no active view") if view.nil?
        cam = view.camera
        if orbit > 0 && cam.respond_to?(:is_2d?) && cam.is_2d?
          raise E.new(-32000, "can't orbit a 2D / match-photo camera; use orbit_degrees: 0")
        end
        start = copy_camera(cam)
        stop_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PROFILE_SECONDS
        times = []
        begin
          frames.times do |i|
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > stop_at
            if orbit > 0
              turn = Geom::Transformation.rotation(start.target, Geom::Vector3d.new(0, 0, 1),
                                                   (orbit * (i + 1) / frames) * Math::PI / 180.0)
              moved = Sketchup::Camera.new(start.eye.transform(turn), start.target,
                                           start.up.transform(turn))
              moved.perspective = start.perspective?
              if start.perspective? then moved.fov = start.fov
              else moved.height = start.height
              end
              view.camera = moved
            end
            t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            view.refresh
            times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
          end
        ensure
          view.camera = start if orbit > 0
        end
        sorted = times.sort
        median = sorted.empty? ? nil : sorted[sorted.length / 2]
        {
          "frames" => times.length,
          "ms" => sorted.empty? ? nil : {
            "min" => sorted.first.round(2), "median" => median.round(2),
            "mean" => (times.sum / times.length).round(2),
            "p90" => sorted[[(sorted.length * 0.9).ceil - 1, 0].max].round(2),
            "max" => sorted.last.round(2)
          },
          "fps_median" => median && median > 0 ? (1000.0 / median).round(1) : nil,
          "orbit_degrees" => orbit,
          "viewport" => { "width" => view.vpwidth, "height" => view.vpheight },
          "render_mode" => model.rendering_options["RenderMode"],
          "editing" => !model.active_path.nil?,
        }
      end
    end
  end
end
