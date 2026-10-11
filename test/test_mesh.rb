# test/test_mesh.rb — Helpers::Mesh, the pure geometry behind solid_report,
# query_faces and find_overlaps. No SketchUp stubs: the module works on
# plain arrays by design.

require "minitest/autorun"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/helpers/mesh"

class TestMesh < Minitest::Test
  M = MCPforSketchUp::Helpers::Mesh

  IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1].map(&:to_f).freeze

  # An axis-aligned box as 12 outward-wound triangles. Every face is split
  # along the diagonal through its (lo, lo) and (hi, hi) corners, the way a
  # mesh of a drawn box comes out, so rays through the centre hit diagonals.
  def box(x0, y0, z0, x1, y1, z1)
    quads = [
      [[x0, y0, z0], [x0, y1, z0], [x1, y1, z0], [x1, y0, z0]], # bottom, -z
      [[x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]], # top, +z
      [[x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1]], # front, -y
      [[x0, y1, z0], [x0, y1, z1], [x1, y1, z1], [x1, y1, z0]], # back, +y
      [[x0, y0, z0], [x0, y0, z1], [x0, y1, z1], [x0, y1, z0]], # left, -x
      [[x1, y0, z0], [x1, y1, z0], [x1, y1, z1], [x1, y0, z1]], # right, +x
    ]
    quads.flat_map { |a, b, c, d| [[a, b, c], [a, c, d]] }
  end

  def reversed(tris)
    tris.map { |a, b, c| [a, c, b] }
  end

  # ---- volume, area, orientation ----------------------------------------------

  def test_signed_volume_of_outward_box
    assert_in_delta 24.0, M.signed_volume(box(0, 0, 0, 2, 3, 4)), 1e-9
  end

  def test_signed_volume_is_negative_for_inward_faces
    assert_in_delta(-24.0, M.signed_volume(reversed(box(0, 0, 0, 2, 3, 4))), 1e-9)
  end

  def test_signed_volume_does_not_depend_on_position
    assert_in_delta 1.0, M.signed_volume(box(100, -50, 7, 101, -49, 8)), 1e-6
  end

  def test_area_of_box
    assert_in_delta 2 * (6 + 8 + 12), M.area(box(0, 0, 0, 2, 3, 4)), 1e-9
  end

  def test_orient_rewinds_a_triangle_against_the_normal
    tri = [[0, 0, 0], [1, 0, 0], [0, 1, 0]]   # winds to +z
    assert_equal tri, M.orient(tri, [0, 0, 1])
    assert_equal [[0, 0, 0], [0, 1, 0], [1, 0, 0]], M.orient(tri, [0, 0, -1])
  end

  # ---- transformations -----------------------------------------------------------

  def test_apply_moves_and_divides_by_the_scale_slot
    m = IDENTITY.dup
    m[12], m[13], m[14] = 10.0, 20.0, 30.0
    assert_equal [11.0, 22.0, 33.0], M.apply(m, [1, 2, 3])
    # Uniform scale 2 the way SketchUp stores it: 0.5 in slot 15.
    m[15] = 0.5
    assert_equal [22.0, 44.0, 66.0], M.apply(m, [1, 2, 3])
  end

  def test_mirror_keeps_volume_positive
    mirror = IDENTITY.dup
    mirror[0] = -1.0
    assert_operator M.determinant(mirror), :<, 0
    moved = M.transform_triangles(box(0, 0, 0, 2, 3, 4), mirror)
    assert_in_delta 24.0, M.signed_volume(moved), 1e-9
  end

  def test_scaled_volume
    m = IDENTITY.dup
    m[15] = 0.5   # uniform x2
    assert_in_delta 8.0, M.signed_volume(M.transform_triangles(box(0, 0, 0, 1, 1, 1), m)), 1e-9
  end

  def test_normal_through_rotation
    # 90 degrees about z: x -> y.
    rot = [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1].map(&:to_f)
    n = M.normal_through(rot, [1, 0, 0])
    [0.0, 1.0, 0.0].each_with_index { |v, i| assert_in_delta v, n[i], 1e-12 }
  end

  def test_normal_through_non_uniform_scale_stays_perpendicular
    # Stretch x by 4: a 45-degree face's normal must lean towards y.
    m = IDENTITY.dup
    m[0] = 4.0
    n = M.normal_through(m, [Math.sqrt(0.5), Math.sqrt(0.5), 0])
    # The face direction (1, -1, 0) becomes (4, -1, 0); n must be perpendicular.
    assert_in_delta 0.0, M.dot(n, [4, -1, 0]), 1e-12
    assert_in_delta 1.0, Math.sqrt(M.dot(n, n)), 1e-12
  end

  def test_normal_through_mirror_points_out_of_the_mirrored_side
    mirror = IDENTITY.dup
    mirror[0] = -1.0
    n = M.normal_through(mirror, [1, 0, 0])
    [-1.0, 0.0, 0.0].each_with_index { |v, i| assert_in_delta v, n[i], 1e-12 }
  end

  def test_normal_through_singular_is_nil
    flat = IDENTITY.dup
    flat[10] = 0.0
    assert_nil M.normal_through(flat, [0, 0, 1])
  end

  # ---- boxes ---------------------------------------------------------------------------

  def test_bounds_union_intersection
    a = M.bounds([[0, 0, 0], [2, 2, 2]])
    b = M.bounds([[1, 1, 1], [3, 3, 3]])
    assert_equal [[0, 0, 0], [3, 3, 3]], M.union(a, b)
    assert_equal [[1, 1, 1], [2, 2, 2]], M.intersection(a, b)
    assert_equal a, M.union(nil, a)
    assert_nil M.bounds([])
  end

  def test_touching_boxes_share_no_volume
    assert_nil M.intersection([[0, 0, 0], [1, 1, 1]], [[1, 0, 0], [2, 1, 1]])
    assert M.overlaps?([[0, 0, 0], [1, 1, 1]], [[1, 0, 0], [2, 1, 1]])
  end

  def test_shrink_empties_a_thin_box
    assert_equal [[1, 1, 1], [3, 3, 3]], M.shrink([[0, 0, 0], [4, 4, 4]], 1)
    assert_nil M.shrink([[0, 0, 0], [4, 4, 1.5]], 1)
  end

  def test_samples_fill_the_box_off_round_coordinates
    pts = M.samples([[0, 0, 0], [10, 10, 10]], 10)
    assert_equal 1000, pts.length
    pts.each do |p|
      p.each do |v|
        assert_operator v, :>, 0
        assert_operator v, :<, 10
        refute_in_delta v.round, v, 1e-6, "sample #{p.inspect} sits on a round coordinate"
      end
    end
    assert_equal pts, M.samples([[0, 0, 0], [10, 10, 10]], 10), "samples must be deterministic"
  end

  # ---- inside / outside --------------------------------------------------------------

  def test_solid_inside_and_outside
    s = M::Solid.new(box(0, 0, 0, 1, 1, 1))
    assert s.inside?([0.31, 0.47, 0.73])
    refute s.inside?([1.31, 0.47, 0.73])
    refute s.inside?([0.31, -0.2, 0.73])
  end

  def test_one_ray_on_a_diagonal_is_outvoted
    s = M::Solid.new(box(0, 0, 0, 1, 1, 1))
    p = [0.5, 0.5, 0.3]
    # The +z ray meets the top face exactly on its diagonal and counts it twice.
    assert s.crossings(p, 2).even?, "precondition: the z ray miscounts here"
    assert s.inside?(p), "the x and y rays must outvote it"
  end

  # A closed prism over a counter-clockwise profile that is star-shaped from
  # its first vertex (so a fan from it triangulates the caps).
  def prism(profile, z0, z1)
    lo = profile.map { |x, y| [x, y, z0] }
    hi = profile.map { |x, y| [x, y, z1] }
    tris = []
    (1...(profile.length - 1)).each do |i|
      tris << [lo[0], lo[i + 1], lo[i]]   # bottom faces -z
      tris << [hi[0], hi[i], hi[i + 1]]   # top faces +z
    end
    profile.length.times do |i|
      j = (i + 1) % profile.length
      tris << [lo[i], lo[j], hi[j]]
      tris << [lo[i], hi[j], hi[i]]
    end
    tris
  end

  def test_concave_solid
    ell = prism([[0, 0], [2, 0], [2, 1], [1, 1], [1, 2], [0, 2]], 0, 1)
    assert_in_delta 3.0, M.signed_volume(ell), 1e-9, "precondition: closed and outward"
    s = M::Solid.new(ell)
    assert s.inside?([0.43, 1.57, 0.61]), "in the upright arm"
    assert s.inside?([1.57, 0.43, 0.61]), "in the bottom arm"
    refute s.inside?([1.57, 1.43, 0.61]), "in the notch, inside the bounding box"
  end

  def test_overlapping_boxes_estimate_their_common_volume
    a = M::Solid.new(box(0, 0, 0, 2, 2, 2))
    b = M::Solid.new(box(1, 1, 1, 3, 3, 3))
    common = M.intersection(a.box, b.box)
    pts = M.samples(common, 8)
    hits = pts.count { |p| a.inside?(p) && b.inside?(p) }
    assert_equal pts.length, hits
    assert_in_delta 1.0, M.volume(common) * hits / pts.length, 1e-9
  end

  def test_partial_overlap_is_estimated_by_the_hit_fraction
    # b pokes 0.5 into a; their boxes' common part is all inside both.
    a = M::Solid.new(box(0, 0, 0, 4, 4, 4))
    b = M::Solid.new(box(3.5, 1, 1, 6, 3, 3))
    common = M.intersection(a.box, b.box)
    pts = M.samples(common, 10)
    hits = pts.count { |p| a.inside?(p) && b.inside?(p) }
    assert_in_delta 0.5 * 2 * 2, M.volume(common) * hits / pts.length, 1e-9
  end

  def test_closest_point_regions
    a, b, c = [0, 0, 0], [4, 0, 0], [0, 4, 0]
    assert_equal [1.0, 1.0, 0.0], M.closest_point([1, 1, 5], a, b, c)
    assert_equal a, M.closest_point([-1, -1, 0], a, b, c)
    assert_equal c, M.closest_point([-1, 6, 0], a, b, c)
    assert_equal [2.0, 0.0, 0.0], M.closest_point([2, -3, 0], a, b, c)
    assert_equal [2.0, 2.0, 0.0], M.closest_point([3, 3, 0], a, b, c)
    assert_in_delta 5.0, M.distance_to_triangle([1, 1, 5], [a, b, c]), 1e-12
  end

  def test_closest_point_on_a_degenerate_triangle_is_finite
    [[[0, 0, 0], [0, 0, 0], [0, 0, 0]], [[0, 0, 0], [1, 0, 0], [2, 0, 0]]].each do |tri|
      assert M.closest_point([1, 1, 1], *tri).all?(&:finite?), tri.inspect
    end
  end

  def test_distance_and_near_surface
    s = M::Solid.new(box(0, 0, 0, 1, 1, 1))
    assert_in_delta 0.3, s.distance([0.5, 0.3, 0.5]), 1e-12
    assert s.near_surface?([0.5, 0.5, 0.99], 0.02)
    refute s.near_surface?([0.5, 0.5, 0.5], 0.4)
    assert s.near_surface?([0.5, 1.01, 0.5], 0.02), "outside but close also counts"
  end

  # Two trapezoid prisms meeting on a slanted face, the second pushed 0.01
  # into the first: inside both by parity, but never deeper than 0.009, so
  # a tolerance above that reads it as contact.
  def test_slanted_contact_is_within_tolerance
    a = M::Solid.new(prism([[0, 0], [2, 0], [3, 2], [0, 2]], 0, 1))
    b = M::Solid.new(prism([[1.99, 0], [5, 0], [5, 2], [2.99, 2]], 0, 1))
    common = M.intersection(a.box, b.box)
    both = M.samples(common, 20).select { |p| a.inside?(p) && b.inside?(p) }
    refute_empty both, "precondition: the sliver is sampled"
    assert both.all? { |p| [a.distance(p), b.distance(p)].min < 0.0095 }
    assert both.all? { |p| a.near_surface?(p, 0.05) || b.near_surface?(p, 0.05) }
  end

  def test_empty_solid_contains_nothing
    s = M::Solid.new([])
    assert s.empty?
    refute s.inside?([0, 0, 0])
  end

  def test_angle_deg
    assert_in_delta 0.0, M.angle_deg([0, 0, 2], [0, 0, 1]), 1e-9
    assert_in_delta 90.0, M.angle_deg([1, 0, 0], [0, 0, 1]), 1e-9
    assert_in_delta 180.0, M.angle_deg([0, 0, -1], [0, 0, 1]), 1e-9
    assert_nil M.angle_deg([0, 0, 0], [0, 0, 1])
  end
end
