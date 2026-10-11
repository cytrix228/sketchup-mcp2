# mcp_for_sketchup/mcp_for_sketchup/helpers/mesh.rb
#
# Pure geometry over plain arrays — no SketchUp API in this file, so every
# rule here is unit-tested without stubs (test/test_mesh.rb). A point is an
# [x, y, z] array, a triangle is [a, b, c], a box is [[minx, miny, minz],
# [maxx, maxy, maxz]], and a transformation is SketchUp's 16-element,
# column-major Transformation#to_a. Units are whatever the caller passes; the
# handlers pass inches and convert to mm at the boundary.
module MCPforSketchUp
  module Helpers
    module Mesh
      # Signed volume of a closed triangle mesh (divergence theorem). Positive
      # when the triangles wind counter-clockwise seen from outside, i.e. when
      # the faces point outward.
      def self.signed_volume(tris)
        tris.sum(0.0) do |a, b, c|
          (a[0] * (b[1] * c[2] - b[2] * c[1]) -
           a[1] * (b[0] * c[2] - b[2] * c[0]) +
           a[2] * (b[0] * c[1] - b[1] * c[0])) / 6.0
        end
      end

      def self.triangle_area(a, b, c)
        nx, ny, nz = cross(sub(b, a), sub(c, a))
        0.5 * Math.sqrt(nx * nx + ny * ny + nz * nz)
      end

      def self.area(tris)
        tris.sum(0.0) { |a, b, c| triangle_area(a, b, c) }
      end

      # The triangle wound so its normal agrees with `normal`.
      def self.orient(tri, normal)
        a, b, c = tri
        dot(cross(sub(b, a), sub(c, a)), normal) < 0 ? [a, c, b] : tri
      end

      # ---- transformations ---------------------------------------------------

      # SketchUp keeps a uniform scale in the 16th element as a divisor, not
      # in the axis columns, so every point is divided by m[15].
      def self.apply(m, p)
        w = m[15].to_f
        w = 1.0 if w.zero?
        [(m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12]) / w,
         (m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13]) / w,
         (m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14]) / w]
      end

      def self.determinant(m)
        dot([m[0], m[1], m[2]], cross([m[4], m[5], m[6]], [m[8], m[9], m[10]]))
      end

      # A normal carried through m by the inverse transpose of its linear
      # part, which keeps it perpendicular to the surface under non-uniform
      # scale and keeps it pointing out of the same side under a mirror.
      # Returns a unit vector, or nil for a singular m or a zero normal.
      def self.normal_through(m, n)
        c0 = [m[0], m[1], m[2]]
        c1 = [m[4], m[5], m[6]]
        c2 = [m[8], m[9], m[10]]
        det = dot(c0, cross(c1, c2))
        return nil if det.abs < 1e-12
        a = cross(c1, c2)
        b = cross(c2, c0)
        c = cross(c0, c1)
        v = [(n[0] * a[0] + n[1] * b[0] + n[2] * c[0]) / det,
             (n[0] * a[1] + n[1] * b[1] + n[2] * c[1]) / det,
             (n[0] * a[2] + n[1] * b[2] + n[2] * c[2]) / det]
        unit(v)
      end

      # Triangles carried through m. A mirroring m reverses the winding, so
      # the triangles are rewound to keep facing the side they faced before.
      def self.transform_triangles(tris, m)
        flip = determinant(m) < 0
        tris.map do |a, b, c|
          a2, b2, c2 = apply(m, a), apply(m, b), apply(m, c)
          flip ? [a2, c2, b2] : [a2, b2, c2]
        end
      end

      # ---- boxes -------------------------------------------------------------

      def self.bounds(points)
        return nil if points.empty?
        min = points.first.map(&:to_f)
        max = points.first.map(&:to_f)
        points.each do |p|
          3.times do |i|
            min[i] = p[i] if p[i] < min[i]
            max[i] = p[i] if p[i] > max[i]
          end
        end
        [min, max]
      end

      def self.union(a, b)
        return b if a.nil?
        return a if b.nil?
        [3.times.map { |i| [a[0][i], b[0][i]].min },
         3.times.map { |i| [a[1][i], b[1][i]].max }]
      end

      # The common part of two boxes, or nil when they share no volume.
      def self.intersection(a, b)
        min = 3.times.map { |i| [a[0][i], b[0][i]].max }
        max = 3.times.map { |i| [a[1][i], b[1][i]].min }
        return nil if 3.times.any? { |i| min[i] >= max[i] }
        [min, max]
      end

      # The box pulled in by d on every side, or nil when that empties it.
      # Two parts that only touch share a box no thicker than a weld; pulling
      # it in is what keeps a shared face from reading as an overlap.
      def self.shrink(box, d)
        min = box[0].map { |v| v + d }
        max = box[1].map { |v| v - d }
        return nil if 3.times.any? { |i| min[i] >= max[i] }
        [min, max]
      end

      def self.volume(box)
        3.times.reduce(1.0) { |acc, i| acc * (box[1][i] - box[0][i]) }
      end

      def self.overlaps?(a, b)
        3.times.all? { |i| a[0][i] <= b[1][i] && b[0][i] <= a[1][i] }
      end

      # n x n x n points spread through the box: one per cell, each nudged off
      # the cell centre by a fixed irrational fraction that differs per cell.
      # Drawn geometry lives on round coordinates, and a sample sitting
      # exactly on a face or edge is the one place a parity test can't decide.
      def self.samples(box, n)
        min, max = box
        step = 3.times.map { |i| (max[i] - min[i]).to_f / n }
        out = []
        n.times do |i|
          n.times do |j|
            n.times do |k|
              cell = [i, j, k]
              out << 3.times.map do |axis|
                jitter = ((cell[axis] * 0.6180339887 + cell[(axis + 1) % 3] * 0.4142135623 +
                           axis * 0.7320508075) % 1.0 - 0.5) * 0.6
                min[axis] + step[axis] * (cell[axis] + 0.5 + jitter)
              end
            end
          end
        end
        out
      end

      # ---- inside / outside ----------------------------------------------------

      # A closed triangle mesh that answers "is this point inside?" by the
      # parity of ray crossings. Three axis-aligned rays vote: a ray that
      # grazes an edge or a vertex can miscount, but it would take two of
      # the three to do so at the same point. Each axis keeps a grid of the
      # triangles over the two other axes, so a ray only tests the triangles
      # in its own cell.
      class Solid
        attr_reader :box, :triangles

        CELLS = 24

        def initialize(tris)
          @triangles = tris
          @box = Mesh.bounds(tris.flatten(1))
          @grids = []
        end

        def empty?
          @triangles.empty?
        end

        def inside?(p)
          return false if @box.nil? || !contains?(p)
          first = crossings(p, 0).odd?
          second = crossings(p, 1).odd?
          return first if first == second
          crossings(p, 2).odd?
        end

        # True when a triangle lies within d of p. Only the triangles filed
        # under the (y, z) window around p are measured.
        def near_surface?(p, d)
          return false if @box.nil?
          grid = (@grids[0] ||= build_grid(0))
          i0 = slot(grid, :umin, :du, p[1] - d)
          i1 = slot(grid, :umin, :du, p[1] + d)
          j0 = slot(grid, :vmin, :dv, p[2] - d)
          j1 = slot(grid, :vmin, :dv, p[2] + d)
          (i0..i1).each do |i|
            (j0..j1).each do |j|
              cell = grid[:cells][i * (CELLS + 1) + j] or next
              cell.each { |tri| return true if Mesh.distance_to_triangle(p, tri) <= d }
            end
          end
          false
        end

        # Distance from p to the nearest triangle.
        def distance(p)
          @triangles.map { |tri| Mesh.distance_to_triangle(p, tri) }.min || Float::INFINITY
        end

        # Crossings of the ray from p towards +axis.
        def crossings(p, axis)
          u = (axis + 1) % 3
          v = (axis + 2) % 3
          grid = (@grids[axis] ||= build_grid(axis))
          cell = grid[:cells][cell_index(grid, p[u], p[v])]
          return 0 unless cell
          pu = p[u]
          pv = p[v]
          count = 0
          cell.each do |a, b, c|
            # Edge functions of the triangle projected along the ray.
            w0 = (b[u] - pu) * (c[v] - pv) - (b[v] - pv) * (c[u] - pu)
            w1 = (c[u] - pu) * (a[v] - pv) - (c[v] - pv) * (a[u] - pu)
            w2 = (a[u] - pu) * (b[v] - pv) - (a[v] - pv) * (b[u] - pu)
            sum = w0 + w1 + w2
            next if sum.abs < 1e-12   # the triangle is edge-on to the ray
            next unless (w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0)
            hit = (w0 * a[axis] + w1 * b[axis] + w2 * c[axis]) / sum
            count += 1 if hit > p[axis]
          end
          count
        end

        private

        def contains?(p)
          3.times.all? { |i| p[i] >= @box[0][i] && p[i] <= @box[1][i] }
        end

        def build_grid(axis)
          u = (axis + 1) % 3
          v = (axis + 2) % 3
          grid = {
            u: u, v: v,
            umin: @box[0][u], vmin: @box[0][v],
            du: [(@box[1][u] - @box[0][u]).to_f / CELLS, 1e-9].max,
            dv: [(@box[1][v] - @box[0][v]).to_f / CELLS, 1e-9].max,
            cells: {}
          }
          @triangles.each do |tri|
            us = tri.map { |pt| pt[u] }
            vs = tri.map { |pt| pt[v] }
            i0, i1 = slot(grid, :umin, :du, us.min), slot(grid, :umin, :du, us.max)
            j0, j1 = slot(grid, :vmin, :dv, vs.min), slot(grid, :vmin, :dv, vs.max)
            (i0..i1).each do |i|
              (j0..j1).each { |j| (grid[:cells][i * (CELLS + 1) + j] ||= []) << tri }
            end
          end
          grid
        end

        def slot(grid, min_key, step_key, value)
          ((value - grid[min_key]) / grid[step_key]).floor.clamp(0, CELLS)
        end

        def cell_index(grid, pu, pv)
          slot(grid, :umin, :du, pu) * (CELLS + 1) + slot(grid, :vmin, :dv, pv)
        end
      end

      # The point of triangle abc nearest to p (Ericson, Real-Time Collision
      # Detection, 5.1.5): which Voronoi region of the triangle p falls in
      # decides between a vertex, an edge and the face.
      def self.closest_point(p, a, b, c)
        p, a, b, c = [p, a, b, c].map { |v| v.map(&:to_f) }
        ab = sub(b, a)
        ac = sub(c, a)
        ap = sub(p, a)
        d1 = dot(ab, ap)
        d2 = dot(ac, ap)
        return a if d1 <= 0 && d2 <= 0
        bp = sub(p, b)
        d3 = dot(ab, bp)
        d4 = dot(ac, bp)
        return b if d3 >= 0 && d4 <= d3
        vc = d1 * d4 - d3 * d2
        return along(a, ab, ratio(d1, d1 - d3)) if vc <= 0 && d1 >= 0 && d3 <= 0
        cp = sub(p, c)
        d5 = dot(ab, cp)
        d6 = dot(ac, cp)
        return c if d6 >= 0 && d5 <= d6
        vb = d5 * d2 - d1 * d6
        return along(a, ac, ratio(d2, d2 - d6)) if vb <= 0 && d2 >= 0 && d6 <= 0
        va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0
          return along(b, sub(c, b), ratio(d4 - d3, (d4 - d3) + (d5 - d6)))
        end
        sum = va + vb + vc
        return a if sum.zero?   # a degenerate triangle
        v = vb / sum
        w = vc / sum
        [a[0] + ab[0] * v + ac[0] * w, a[1] + ab[1] * v + ac[1] * w, a[2] + ab[2] * v + ac[2] * w]
      end

      def self.distance_to_triangle(p, tri)
        q = closest_point(p, *tri)
        d = sub(p, q)
        Math.sqrt(dot(d, d))
      end

      # n / d, or 0 where a degenerate triangle makes d zero.
      def self.ratio(n, d)
        d.zero? ? 0.0 : n / d
      end

      def self.along(origin, dir, t)
        [origin[0] + dir[0] * t, origin[1] + dir[1] * t, origin[2] + dir[2] * t]
      end

      # ---- vector bits -----------------------------------------------------------

      def self.sub(a, b)
        [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
      end

      def self.dot(a, b)
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
      end

      def self.cross(a, b)
        [a[1] * b[2] - a[2] * b[1],
         a[2] * b[0] - a[0] * b[2],
         a[0] * b[1] - a[1] * b[0]]
      end

      def self.unit(v)
        len = Math.sqrt(dot(v, v))
        return nil if len < 1e-12
        [v[0] / len, v[1] / len, v[2] / len]
      end

      # Angle between two vectors in degrees (0 for parallel, same sense).
      def self.angle_deg(a, b)
        ua = unit(a)
        ub = unit(b)
        return nil unless ua && ub
        Math.acos(dot(ua, ub).clamp(-1.0, 1.0)) * 180.0 / Math::PI
      end
    end
  end
end
