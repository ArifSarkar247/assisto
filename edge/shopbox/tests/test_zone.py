import numpy as np

from shopbox.zone import (box_zone_overlap, normalize_polygon, point_in_polygon,
                          polygon_area, zone_mask)

SQUARE = [(0.2, 0.2), (0.6, 0.2), (0.6, 0.6), (0.2, 0.6)]
# concave "L": the notch at top-right is OUTSIDE
L_SHAPE = [(0.0, 0.0), (0.5, 0.0), (0.5, 0.5), (1.0, 0.5), (1.0, 1.0), (0.0, 1.0)]


def test_point_in_square():
    assert point_in_polygon(0.4, 0.4, SQUARE)
    assert not point_in_polygon(0.1, 0.4, SQUARE)
    assert not point_in_polygon(0.4, 0.9, SQUARE)
    assert not point_in_polygon(0.7, 0.7, SQUARE)


def test_point_in_concave_polygon():
    assert point_in_polygon(0.25, 0.25, L_SHAPE)
    assert point_in_polygon(0.75, 0.75, L_SHAPE)
    assert not point_in_polygon(0.75, 0.25, L_SHAPE)   # the notch


def test_point_in_triangle_and_degenerate():
    tri = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0)]
    assert point_in_polygon(0.2, 0.2, tri)
    assert not point_in_polygon(0.8, 0.8, tri)
    assert not point_in_polygon(0.5, 0.5, [(0, 0), (1, 1)])


def test_normalize_polygon_validates_and_clamps():
    assert normalize_polygon(None) == []
    assert normalize_polygon([[0.1, 0.1], [0.2, 0.2]]) == []           # < 3 points
    assert normalize_polygon([[0, 0], [0.5, 0.5], [1, 1]]) == []      # zero area
    assert normalize_polygon([["a", 1], [0, 0], [1, 0]]) == []
    poly = normalize_polygon([[-1, 0], [2, 0], [0.5, 1.5]])
    assert poly == [(0.0, 0.0), (1.0, 0.0), (0.5, 1.0)]
    assert abs(polygon_area(SQUARE) - 0.16) < 1e-9


def test_mask_agrees_with_point_in_polygon():
    m = zone_mask(L_SHAPE, 100, 100)
    assert m[25, 25] == 255 and m[75, 75] == 255
    assert m[25, 75] == 0


def test_box_zone_overlap():
    m = zone_mask(SQUARE, 200, 200)
    assert box_zone_overlap((0.2, 0.2, 0.6, 0.6), m) > 0.95   # exactly the zone
    assert box_zone_overlap((0.7, 0.7, 0.9, 0.9), m) == 0.0   # disjoint
    # small box fully inside a big zone counts fully (box-side fraction)
    assert box_zone_overlap((0.3, 0.3, 0.35, 0.35), m) > 0.9
    assert box_zone_overlap((0.5, 0.5, 0.5, 0.5), m) == 0.0   # empty box
    assert box_zone_overlap((0, 0, 1, 1), np.zeros((10, 10), np.uint8)) == 0.0
