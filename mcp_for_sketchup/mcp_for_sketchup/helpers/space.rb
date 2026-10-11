# mcp_for_sketchup/mcp_for_sketchup/helpers/space.rb
#
# World coordinates for anything in the model — also while the user is
# editing inside a group, which is when SketchUp reports placements in a
# mixed frame (verified on SketchUp 2026):
#
# - every instance on the open path reports the identity;
# - entities whose parent is the definition of open-path instance k report
#   prefix(0..k) * local, where prefix(last) = model.edit_transform — the
#   contents of the open group come back in world coordinates;
# - everything else reports its true local placement.
#
# So walking down from the model root and multiplying the REPORTED
# transformations lands in world space everywhere but one place: inside a
# second instance of a definition that is open elsewhere, whose contents
# still report in the open instance's frame. `step` corrects that for the
# innermost open definition (whose frame is edit_transform) and flags it as
# ambiguous for an outer one, whose frame can't be read while it is open.
module MCPforSketchUp
  module Helpers
    module Space
      Context = Struct.new(:open, :open_defs, :edit_inverse, :ambiguous)

      MAX_DEPTH = 64

      def self.context(model)
        open = model.active_path ? model.active_path.to_a : []
        edit_inverse = open.empty? ? nil : model.edit_transform.inverse
        Context.new(open, open.map(&:definition), edit_inverse, false)
      end

      def self.instance?(e)
        e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      end

      # The name a person would read: the instance name, or the definition
      # name for an unnamed group ("Group#12").
      def self.label(inst)
        inst.name.to_s.empty? ? inst.definition.name : inst.name
      end

      def self.type_name(e)
        return "group" if e.is_a?(Sketchup::Group)
        return "component" if e.is_a?(Sketchup::ComponentInstance)
        e.typename.downcase
      end

      def self.ref(inst)
        { "id" => inst.entityID, "name" => label(inst), "type" => type_name(inst) }
      end

      # Instances from the model root down to the context `entity` sits in:
      # its last element's definition is entity.parent, and [] means the
      # entity is in model.entities. nil when no placed instance leads there
      # (a definition that was never placed).
      #
      # A definition can have many instances. The one on the open path wins,
      # so a part inside the group the user is editing resolves through
      # that group; otherwise the first instance that reaches the root.
      def self.chain_to(entity, ctx)
        budget = [10_000]
        climb(entity.parent, ctx, 0, budget)
      end

      def self.climb(parent, ctx, depth, budget)
        return [] if parent.is_a?(Sketchup::Model)
        return nil unless parent.is_a?(Sketchup::ComponentDefinition)
        return nil if depth > MAX_DEPTH || (budget[0] -= 1) < 0
        insts = parent.instances.to_a
        open, rest = insts.partition { |i| ctx.open.include?(i) }
        (open + rest).each do |inst|
          above = climb(inst.parent, ctx, depth + 1, budget)
          return above + [inst] if above
        end
        nil
      end

      # One step down: the frame of inst's contents, given the frame inst
      # itself was reported in.
      def self.step(frame, inst, ctx)
        t = frame * inst.transformation
        return t if ctx.open.empty? || ctx.open.include?(inst)
        k = ctx.open_defs.index(inst.definition)
        return t unless k
        if k == ctx.open.length - 1
          t * ctx.edit_inverse
        else
          ctx.ambiguous = true
          t
        end
      end

      # The frame of the contents of chain.last — what maps coordinates
      # reported inside it to world.
      def self.frame(chain, ctx)
        chain.reduce(Geom::Transformation.new) { |t, inst| step(t, inst, ctx) }
      end

      # World frame of an instance's own contents, or nil when it isn't
      # placed in the model. `chain` is the path to its parent context when
      # the caller already knows it.
      def self.contents_frame(inst, ctx, chain = nil)
        chain ||= chain_to(inst, ctx)
        return nil unless chain
        step(frame(chain, ctx), inst, ctx)
      end

      # ---- geometry in world space ------------------------------------------

      # A face as world-space triangles wound with its front side.
      def self.face_triangles(face, m)
        mesh = face.mesh(0)
        pts = (1..mesh.count_points).map do |i|
          p = mesh.point_at(i)
          [p.x.to_f, p.y.to_f, p.z.to_f]
        end
        n = face.normal
        normal = [n.x.to_f, n.y.to_f, n.z.to_f]
        local = mesh.polygons.map do |poly|
          Mesh.orient(poly.map { |i| pts[i.abs - 1] }, normal)
        end
        Mesh.transform_triangles(local, m)
      end

      # Every face under an instance, nested ones included, as world-space
      # triangles. Stops early (returning what it has) past the deadline.
      def self.deep_triangles(inst, frame, ctx, deadline = nil, depth = 0, out = [])
        return out if depth > MAX_DEPTH
        m = frame.to_a
        Entities.entity_collection(inst).each do |e|
          break if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          if e.is_a?(Sketchup::Face)
            out.concat(face_triangles(e, m))
          elsif instance?(e)
            deep_triangles(e, step(frame, e, ctx), ctx, deadline, depth + 1, out)
          end
        end
        out
      end

      def self.point(p, m)
        Mesh.apply(m, [p.x.to_f, p.y.to_f, p.z.to_f])
      end

      # The eight corners of a SketchUp bounding box carried through m and
      # boxed again. A rotated frame makes this looser than the geometry,
      # never tighter.
      def self.box_through(bb, m)
        return nil if Geometry.empty_bbox?(bb)
        corners = (0..7).map { |i| point(bb.corner(i), m) }
        Mesh.bounds(corners)
      end

      def self.mm(p)
        p.map { |v| (v * Units::MM).round(2) }
      end

      def self.box_mm(box)
        return nil unless box
        { "min" => mm(box[0]), "max" => mm(box[1]) }
      end

      def self.box_from_mm(min, max)
        lo = min.map { |v| Units.mm_to_inch(v) }
        hi = max.map { |v| Units.mm_to_inch(v) }
        [3.times.map { |i| [lo[i], hi[i]].min }, 3.times.map { |i| [lo[i], hi[i]].max }]
      end
    end
  end
end
