"""Environment kit for the v0.1 map: road tiles, sand, water and clouds.

Same look as the cars, buildings and nature props (style.py): low poly, flat shading, flat
Palette colors, small chamfers. Each piece is a few objects, one material each, so it imports as
a few MeshParts that MapBuilder can tint: roads are Asphalt (or Dirt) + line objects, sand is
Sand (+ WetSand, Grass), water is Water (+ Foam), clouds are Puffs + Shade.

Sizes come from MapBuilder.luau. Road and water tiles are TILE studs long and repeat seamlessly
end to end (wave heights are periodic over the tile, and only interior vertices are jittered).

Origins:
- Road tiles: centre of the footprint, on the ground; the driving surface is ROAD_TOP above it.
  RoadCurve's origin is the centre of its arc instead, so it can be turned in 90-degree steps.
- Sand and beach pieces: on the ground at the centre of the footprint.
- Water tiles: centre of the tile at mean water level.
- Clouds: centre of the flat underside.

    blender --background --python art/blender/environment.py
"""

import importlib
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nature  # noqa: E402
import style  # noqa: E402

importlib.reload(style)
importlib.reload(nature)

rgb = style.rgb
Prop = nature.Prop

FOLDER = "environment"
TILE = 48  # road and water tiles repeat every TILE studs (a 12-stud dash + 12-stud gap, twice)
ROAD_TOP = 1.0

# MapBuilder widths
STREET_WIDTH = 36
HIGHWAY_WIDTH = 56
DIRT_WIDTH = 28

ASPHALT = rgb(74, 80, 98)
LINE_WHITE = rgb(236, 234, 224)
LINE_YELLOW = rgb(240, 196, 64)
CURB = rgb(170, 164, 154)
DIRT = rgb(190, 148, 102)
RUT = rgb(160, 120, 86)
PEBBLE = rgb(150, 150, 158)
SAND = rgb(232, 214, 162)
WET_SAND = rgb(204, 182, 130)
BEACH_GRASS = rgb(170, 184, 98)
STARFISH = rgb(240, 128, 96)
WATER = rgb(72, 188, 226)
WATER_DEEP = rgb(40, 96, 150)
FOAM = rgb(240, 250, 255)
CLOUD = rgb(255, 255, 255)
CLOUD_SHADE = rgb(150, 170, 210)  # SkyController's CLOUD_SHADE


# --- geometry helpers (all append to an existing bmesh) -------------------------------------


def prism(bm, pts, z0, z1):
    """Straight prism from a counter-clockwise 2D outline [(x, y), ...]."""
    bottom = [bm.verts.new((x, y, z0)) for x, y in pts]
    top = [bm.verts.new((x, y, z1)) for x, y in pts]
    bm.faces.new(list(reversed(bottom)))
    bm.faces.new(top)
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((bottom[i], bottom[j], top[j], top[i]))


def rect(x0, x1, y0, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def extrude_y(bm, profile, y0, y1, steps=1, warp=None):
    """Cross-section [(x, z), ...] (counter-clockwise seen from -Y) swept from y0 to y1.

    `warp(step, index, x, z)` may move interior rings' points (never the end rings, so tiles
    still meet their neighbours)."""
    rings = []
    for k in range(steps + 1):
        y = y0 + (y1 - y0) * k / steps
        ring = []
        for idx, (x, z) in enumerate(profile):
            if warp and 0 < k < steps:
                x, z = warp(k, idx, x, z)
            ring.append(bm.verts.new((x, y, z)))
        rings.append(ring)
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[-1])
    n = len(profile)
    for a, b in zip(rings, rings[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))


def chamfer_profile(half_width, top, chamfer):
    return [(-half_width, 0), (half_width, 0), (half_width, top - chamfer), (half_width - chamfer, top),
            (-half_width + chamfer, top), (-half_width, top - chamfer)]


def height_grid(bm, x0, x1, y0, y1, nx, ny, zfun, bottom):
    """A closed slab whose top is a (nx x ny) grid at heights zfun(x, y, i, j), with flat sides
    down to `bottom`."""
    top = [[bm.verts.new((x0 + (x1 - x0) * i / nx, y0 + (y1 - y0) * j / ny, 0)) for j in range(ny + 1)]
           for i in range(nx + 1)]
    for i in range(nx + 1):
        for j in range(ny + 1):
            v = top[i][j]
            v.co.z = zfun(v.co.x, v.co.y, i, j)
    for i in range(nx):
        for j in range(ny):
            bm.faces.new((top[i][j], top[i + 1][j], top[i + 1][j + 1], top[i][j + 1]))
    loop = ([top[i][0] for i in range(nx)] + [top[nx][j] for j in range(ny)]
            + [top[i][ny] for i in range(nx, 0, -1)] + [top[0][j] for j in range(ny, 0, -1)])
    base = [bm.verts.new((v.co.x, v.co.y, bottom)) for v in loop]
    n = len(loop)
    for k in range(n):
        m = (k + 1) % n
        bm.faces.new((loop[m], loop[k], base[k], base[m]))
    bm.faces.new(list(reversed(base)))


def sector(bm, r0, r1, a0, a1, segments, z0, z1):
    """A flat ring sector (angles in radians, counter-clockwise from +X) between radii r0 and r1."""
    pts = [(r1 * math.cos(a0 + (a1 - a0) * k / segments), r1 * math.sin(a0 + (a1 - a0) * k / segments))
           for k in range(segments + 1)]
    pts += [(r0 * math.cos(a1 - (a1 - a0) * k / segments), r0 * math.sin(a1 - (a1 - a0) * k / segments))
            for k in range(segments + 1)]
    prism(bm, pts, z0, z1)


def line(bm, x0, x1, y0, y1):
    """A painted marking: a thin plate sunk into the road top so only its face shows."""
    prism(bm, rect(x0, x1, y0, y1), ROAD_TOP - 0.05, ROAD_TOP + 0.04)


def centre_dashes(bm, x, width=0.8, dash=12):
    """Two dashes per tile, centred in each half so the pattern continues across tiles."""
    for c in (-TILE / 4, TILE / 4):
        line(bm, x - width / 2, x + width / 2, c - dash / 2, c + dash / 2)


# --- roads ----------------------------------------------------------------------------------


def road_street(name="RoadStreet"):
    """Two-lane town street: chamfered asphalt, dashed yellow centre, white edge lines."""
    p = Prop(name, 21)
    hw = STREET_WIDTH / 2
    extrude_y(p.batch("Asphalt", ASPHALT, "Trim"), chamfer_profile(hw, ROAD_TOP, 0.35), -TILE / 2, TILE / 2)
    centre_dashes(p.batch("LineYellow", LINE_YELLOW, "Paint"), 0)
    white = p.batch("LineWhite", LINE_WHITE, "Paint")
    for side in (-1, 1):
        x = side * (hw - 2)
        line(white, x - 0.35, x + 0.35, -TILE / 2, TILE / 2)
    return p


def road_highway(name="RoadHighway"):
    """Four-lane highway: double solid yellow centre, dashed white lane lines, a low curb each side."""
    p = Prop(name, 22)
    hw = HIGHWAY_WIDTH / 2
    extrude_y(p.batch("Asphalt", ASPHALT, "Trim"), chamfer_profile(hw, ROAD_TOP, 0.35), -TILE / 2, TILE / 2)
    yellow = p.batch("LineYellow", LINE_YELLOW, "Paint")
    for x in (-0.7, 0.7):
        line(yellow, x - 0.3, x + 0.3, -TILE / 2, TILE / 2)
    white = p.batch("LineWhite", LINE_WHITE, "Paint")
    for side in (-1, 1):
        centre_dashes(white, side * hw / 2, width=0.6)
        x = side * (hw - 2.5)
        line(white, x - 0.35, x + 0.35, -TILE / 2, TILE / 2)
    curb = p.batch("Curb", CURB, "Concrete")
    for side in (-1, 1):
        x = side * (hw - 0.6)
        extrude_y(curb, [(x - 0.6, ROAD_TOP - 0.1), (x + 0.6, ROAD_TOP - 0.1), (x + 0.6, ROAD_TOP + 0.5),
                         (x + 0.3, ROAD_TOP + 0.8), (x - 0.3, ROAD_TOP + 0.8), (x - 0.6, ROAD_TOP + 0.5)],
                  -TILE / 2, TILE / 2)
    return p


def road_dirt(name="RoadDirt"):
    """Country dirt road: rounded, ragged shoulders, two darker wheel ruts and a few pebbles."""
    p = Prop(name, 23)
    hw = DIRT_WIDTH / 2
    profile = [(-hw, 0), (hw, 0), (hw, 0.35), (hw - 1.4, 0.8), (hw - 3.2, ROAD_TOP),
               (-hw + 3.2, ROAD_TOP), (-hw + 1.4, 0.8), (-hw, 0.35)]
    shoulders = {2, 3, 6, 7}  # profile points on the road's edges

    def ragged(_k, idx, x, z):
        if idx in shoulders:
            return x + p.rng.uniform(-0.9, 0.9), z + p.rng.uniform(-0.12, 0.12)
        return x, z

    extrude_y(p.batch("Dirt", DIRT, "Concrete"), profile, -TILE / 2, TILE / 2, steps=6, warp=ragged)
    ruts = p.batch("Ruts", RUT, "Concrete")
    for side in (-1, 1):
        x = side * DIRT_WIDTH * 0.2
        line(ruts, x - 1.5, x + 1.5, -TILE / 2, TILE / 2)
    p.batch("Pebbles", PEBBLE, "Concrete")
    for _ in range(9):
        side = p.rng.choice((-1, 1))
        x = side * p.rng.uniform(hw - 2.6, hw - 0.6)
        y = p.rng.uniform(-TILE / 2 + 2, TILE / 2 - 2)
        r = p.rng.uniform(0.6, 1.1)
        p.blob("Pebbles", (x, y, 0.7), r, squash=0.7, subdivisions=1, jitter=0.2)
    return p


def road_intersection(name="RoadIntersection"):
    """A street crossing: a square of asphalt with zebra crosswalks on all four sides."""
    p = Prop(name, 24)
    hw = STREET_WIDTH / 2
    extrude_y(p.batch("Asphalt", ASPHALT, "Trim"), chamfer_profile(hw, ROAD_TOP, 0.35), -hw, hw)
    white = p.batch("LineWhite", LINE_WHITE, "Paint")
    # bars stop short of the corners so the four crosswalks never overlap
    stripes = 6
    span = STREET_WIDTH - 12
    for k in range(stripes):
        a = -span / 2 + span * (k + 0.5) / stripes
        for side in (-1, 1):
            edge = side * (hw - 3.5)
            line(white, a - 1.0, a + 1.0, edge - 2.5, edge + 2.5)  # crossing the north/south arms
            line(white, edge - 2.5, edge + 2.5, a - 1.0, a + 1.0)  # crossing the east/west arms
    return p


def road_curve(name="RoadCurve"):
    """A quarter turn of street, centreline radius 36, arc centre at the origin. The road runs
    from the +X axis round to the +Y axis."""
    p = Prop(name, 25)
    hw = STREET_WIDTH / 2
    radius = 36
    segments = 10
    sector(p.batch("Asphalt", ASPHALT, "Trim"), radius - hw, radius + hw, 0, math.pi / 2, segments, 0, ROAD_TOP)
    yellow = p.batch("LineYellow", LINE_YELLOW, "Paint")
    dashes = 3
    for k in range(dashes):
        a0 = (k + 0.25) / dashes * math.pi / 2
        a1 = (k + 0.75) / dashes * math.pi / 2
        sector(yellow, radius - 0.4, radius + 0.4, a0, a1, 3, ROAD_TOP - 0.05, ROAD_TOP + 0.04)
    white = p.batch("LineWhite", LINE_WHITE, "Paint")
    for r in (radius - hw + 2, radius + hw - 2):
        sector(white, r - 0.35, r + 0.35, 0, math.pi / 2, segments, ROAD_TOP - 0.05, ROAD_TOP + 0.04)
    return p


# --- sand -----------------------------------------------------------------------------------


def beach_grass(p, center, count=5):
    for _ in range(count):
        angle = p.rng.uniform(0, math.tau)
        out = p.rng.uniform(0.4, 1.2)
        base = (center[0] + math.cos(angle) * 0.5, center[1] + math.sin(angle) * 0.5, center[2] - 0.2)
        p.cone("Grass", base, p.rng.uniform(1.8, 3.2), 0.22, 0.0, 3,
               lean=(math.cos(angle) * out, math.sin(angle) * out))


def sand_dune(name, seed, size, squash, grass=True):
    """A faceted, flat-bottomed dune with a smaller one leaning on it and some beach grass."""
    p = Prop(name, seed)
    p.batch("Sand", SAND, "Concrete")
    p.blob("Sand", (0, 0, -size * squash * 0.1), size, squash=squash, subdivisions=2, jitter=0.1, floor=0.0)
    r = size * 0.6
    p.blob("Sand", (size * 0.85, size * 0.35, -r * squash * 0.2), r, squash=squash, subdivisions=2, jitter=0.12,
           floor=0.0)
    if grass:
        p.batch("Grass", BEACH_GRASS, "Accent")
        for x, y in ((-size * 0.3, size * 0.2), (size * 0.25, -size * 0.3), (size * 0.9, size * 0.2)):
            top = size * squash * 0.9 * math.sqrt(max(0.05, 1 - (x * x + y * y) / (size * size)))
            beach_grass(p, (x, y, top), count=p.rng.randint(3, 6))
    return p


def sand_patch(name="SandPatch", seed=32, radius=14):
    """A low, lumpy sand pad with a ragged outline, for laying over grass at the coast."""
    p = Prop(name, seed)
    bm = p.batch("Sand", SAND, "Concrete")
    n = 14
    rim = []
    for k in range(n):
        a = k / n * math.tau
        r = radius * p.rng.uniform(0.78, 1.05)
        rim.append((math.cos(a) * r, math.sin(a) * r))
    mid = [(x * 0.55 + p.rng.uniform(-0.6, 0.6), y * 0.55 + p.rng.uniform(-0.6, 0.6)) for x, y in rim]
    bottom = [bm.verts.new((x, y, 0)) for x, y in rim]
    edge = [bm.verts.new((x, y, 0.25)) for x, y in rim]
    ring = [bm.verts.new((x, y, p.rng.uniform(0.55, 0.8))) for x, y in mid]
    peak = bm.verts.new((0, 0, 0.9))
    bm.faces.new(list(reversed(bottom)))
    for k in range(n):
        m = (k + 1) % n
        bm.faces.new((bottom[k], bottom[m], edge[m], edge[k]))
        bm.faces.new((edge[k], edge[m], ring[m], ring[k]))
        bm.faces.new((ring[k], ring[m], peak))
    return p


def beach_slope(name="BeachSlope", seed=33):
    """A TILE x TILE beach that falls from dry sand (+Y, inland) to wet sand at the waterline (-Y).
    Its top is 2 studs above the origin at the back edge and 1.5 below it at the front."""
    p = Prop(name, seed)
    n = 8
    wet_rows = 3  # front rows of the grid that are wet sand

    def z(x, y, i, j):
        t = (y + TILE / 2) / TILE
        h = -1.5 + 3.5 * t ** 1.4
        if 0 < i < n and 0 < j < n:
            h += p.rng.uniform(-0.25, 0.25)
        return h

    heights = {}

    def cached(x, y, i, j):  # the dry and wet halves share their seam
        key = (round(x, 3), round(y, 3))
        if key not in heights:
            heights[key] = z(x, y, i, j)
        return heights[key]

    split = -TILE / 2 + TILE * wet_rows / n
    height_grid(p.batch("WetSand", WET_SAND, "Concrete"), -TILE / 2, TILE / 2, -TILE / 2, split, n, wet_rows,
                cached, -3)
    height_grid(p.batch("Sand", SAND, "Concrete"), -TILE / 2, TILE / 2, split, TILE / 2, n, n - wet_rows,
                lambda x, y, i, j: cached(x, y, i, j + wet_rows), -3)
    return p


def starfish(name="Starfish", seed=34):
    """A small five-armed starfish (about 3 studs across) for dressing beaches."""
    p = Prop(name, seed)
    bm = p.batch("Starfish", STARFISH, "Paint")
    pts = []
    for k in range(10):
        a = math.pi / 2 + k / 10 * math.tau
        r = 1.5 if k % 2 == 0 else 0.6
        pts.append((math.cos(a) * r, math.sin(a) * r))
    bottom = [bm.verts.new((x, y, 0)) for x, y in pts]
    rim = [bm.verts.new((x, y, 0.18 if k % 2 == 0 else 0.3)) for k, (x, y) in enumerate(pts)]
    hub = bm.verts.new((0, 0, 0.5))
    bm.faces.new(list(reversed(bottom)))
    for k in range(10):
        m = (k + 1) % 10
        bm.faces.new((bottom[k], bottom[m], rim[m], rim[k]))
        bm.faces.new((rim[k], rim[m], hub))
    return p


# --- water ----------------------------------------------------------------------------------


def water_tile(name, seed, color, amplitude, cells=12):
    """A TILE x TILE patch of faceted sea. Heights repeat over the tile so copies line up, and a
    skirt underneath keeps it a closed solid."""
    p = Prop(name, seed)

    def z(x, y, i, j):
        u, v = x / TILE * math.tau, y / TILE * math.tau
        h = amplitude * (0.6 * math.sin(2 * u + v) + 0.4 * math.sin(3 * v - u))
        if 0 < i < cells and 0 < j < cells:
            h += p.rng.uniform(-0.2, 0.2) * amplitude
        return h

    height_grid(p.batch("Water", color, "Paint"), -TILE / 2, TILE / 2, -TILE / 2, TILE / 2, cells, cells, z,
                -amplitude - 2)
    return p


def wave_crest(name="WaveCrest", seed=42, length=22):
    """A curling cartoon wave crest: a hooked profile swept along X, pinched at both ends."""
    p = Prop(name, seed)
    bm = p.batch("Foam", FOAM, "Paint")
    profile = [(-2.2, 0), (2.2, 0), (1.6, 1.4), (0.6, 2.4), (-0.8, 2.7), (-2.2, 2.2), (-2.8, 1.5),
               (-1.9, 1.5), (-1.0, 1.7), (-0.6, 1.0)]
    steps = 8
    rings = []
    for k in range(steps + 1):
        t = k / steps
        x = -length / 2 + length * t
        s = 0.25 + 0.75 * math.sin(math.pi * t) ** 0.6
        wobble = p.rng.uniform(-0.25, 0.25) if 0 < k < steps else 0
        rings.append([bm.verts.new((x, y * s + wobble, z * s)) for y, z in profile])
    bm.faces.new(rings[0])
    bm.faces.new(list(reversed(rings[-1])))
    n = len(profile)
    for a, b in zip(rings, rings[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], b[i], b[j], a[j]))
    return p


def shore_foam(name="ShoreFoam", seed=43):
    """A TILE-long strip of scalloped foam for the edge where water meets sand. The straight
    edge is at y = 0, the scallops reach out towards -Y."""
    p = Prop(name, seed)
    bm = p.batch("Foam", FOAM, "Paint")
    bumps = 6
    width = TILE / bumps
    pts = [(TILE / 2, 1.2), (-TILE / 2, 1.2)]
    for b in range(bumps):
        x0 = -TILE / 2 + b * width
        depth = 2.6 if b % 2 == 0 else 2.0
        for k in range(5):
            t = k / 5
            pts.append((x0 + width * t, -math.sin(math.pi * t) * depth))
    pts.append((TILE / 2, 0))
    prism(bm, pts, 0, 0.3)
    return p


# --- clouds ---------------------------------------------------------------------------------


def cloud(name, seed, width, puffs):
    """A chunky low-poly cloud: big faceted puffs on one flat base, with a darker shade slab
    underneath (the same trick SkyController's billboard clouds use). About `width` studs wide."""
    p = Prop(name, seed)
    p.batch("Puffs", CLOUD, "Accent")
    for k in range(puffs):
        t = (k + 0.5) / puffs
        # biggest in the middle, like SkyController's billboards
        r = width * (0.24 - abs(t - 0.5) * 0.16) * p.rng.uniform(0.9, 1.1)
        x = (t - 0.5) * width * 0.78
        y = p.rng.uniform(-0.12, 0.12) * width
        p.blob("Puffs", (x, y, r * 0.35), r, squash=0.85, subdivisions=2, jitter=0.05, floor=0.0)
    # a second, smaller row of puffs behind for depth
    for k in range(max(1, puffs - 2)):
        t = (k + 0.5) / max(1, puffs - 2)
        r = width * 0.14 * p.rng.uniform(0.85, 1.1)
        p.blob("Puffs", ((t - 0.5) * width * 0.55, width * 0.16, r * 0.4), r, squash=0.85, subdivisions=2,
               jitter=0.05, floor=0.0)
    bm = p.batch("Shade", CLOUD_SHADE, "Accent")
    rx, ry = width * 0.46, width * 0.2
    n = 10
    pts = [(math.cos(k / n * math.tau) * rx * p.rng.uniform(0.92, 1.0),
            math.sin(k / n * math.tau) * ry * p.rng.uniform(0.92, 1.0)) for k in range(n)]
    prism(bm, pts, -width * 0.03, 0.5)
    return p


CATALOG = [
    road_street,
    road_highway,
    road_dirt,
    road_intersection,
    road_curve,
    lambda: sand_dune("SandDuneA", 30, 14, 0.55),
    lambda: sand_dune("SandDuneB", 31, 9, 0.65),
    sand_patch,
    beach_slope,
    starfish,
    lambda: water_tile("WaterTile", 40, WATER, 0.8),
    lambda: water_tile("WaterDeep", 41, WATER_DEEP, 1.6),
    wave_crest,
    shore_foam,
    lambda: cloud("CloudA", 50, 300, 5),
    lambda: cloud("CloudB", 51, 220, 4),
    lambda: cloud("CloudC", 52, 380, 6),
]


def build_all(export=True):
    """Build every piece in its own collection and lay them out in a row along +X."""
    roots = []
    for make in CATALOG:
        roots.append(make().finish(export=export, folder=FOLDER))
    bpy.context.view_layer.update()
    x = 0.0
    for root in roots:
        xs = [(c.matrix_world @ Vector(corner)).x for c in root.children for corner in c.bound_box]
        lo, hi = min(xs), max(xs)
        root.location = (x - lo, 600, 0)
        x += hi - lo + 20
    return roots


if __name__ == "__main__":
    style.reset_scene()
    build_all()
    blend = os.path.join(style.ART_DIR, "environment.blend")
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    print("saved", blend)
