"""Sedan: low-poly replacement for the v0.1 graybox Sedan built by CarFactory.luau.

Sizes are the v0.1 Sedan from src/shared/Config.luau, and part placement follows CarFactory, so
the meshes drop onto the existing Chassis without moving seats, wheels or the cargo crate.
Origin = Chassis centre; front = -Y (Roblox -Z).
"""

import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import style  # noqa: E402

import importlib  # noqa: E402

importlib.reload(style)

# --- v0.1 Sedan (Config.Vehicles.Types.Sedan) -------------------------------------------
WIDTH, HEIGHT, LENGTH = 7.4, 2.4, 15.0  # Size X, Y, Z in studs
CABIN_HEIGHT = 3.0
RIDE_HEIGHT = 1.6
WHEEL_RADIUS = 1.5

HX, HZ, HY = WIDTH / 2, HEIGHT / 2, LENGTH / 2  # half extents (Blender X, Z, Y)
CABIN_LENGTH = LENGTH * 0.5
CABIN_OFFSET = LENGTH * 0.04  # towards the rear (+Y)
CABIN_FRONT = CABIN_OFFSET - CABIN_LENGTH / 2 - 0.25
CABIN_REAR = CABIN_OFFSET + CABIN_LENGTH / 2
CABIN_TOP = HZ + CABIN_HEIGHT + 0.2  # roof included, as in CarFactory
WHEEL_X = HX - 0.5
WHEEL_Y = HY - 2.6
WHEEL_Z = -HZ - RIDE_HEIGHT + WHEEL_RADIUS
PREVIEW_PAINT = style.CAR_COLORS[0]

style.reset_scene()
coll = style.collection("Sedan")
root = bpy.data.objects.new("Sedan", None)
root.empty_display_type = "ARROWS"
coll.objects.link(root)


def part(name, bm, mat, **kw):
    return style.object_from_bmesh(name, bm, mat, coll, parent=root, **kw)


# --- body: lower hull with wheel arches, plus the greenhouse --------------------------------
hull_profile = [
    (-HY + 0.3, -HZ),
    (HY - 0.3, -HZ),
    (HY, -HZ + 0.3),
    (HY + 0.05, 0.6),
    (HY - 0.25, HZ - 0.05),
    (CABIN_REAR + 0.1, HZ + 0.05),
    (CABIN_FRONT - 0.2, HZ + 0.05),
    (-HY + 0.35, HZ - 0.15),
    (-HY - 0.05, 0.5),
    (-HY, -HZ + 0.3),
]
hull = part("Hull", style.extrude_profile(hull_profile, WIDTH), "Paint", color=PREVIEW_PAINT)
for i, y in enumerate((-WHEEL_Y, WHEEL_Y)):
    cutter = part(f"ArchCutter{i}", style.cylinder_x(WHEEL_RADIUS + 0.3, WIDTH + 2, (0, y, WHEEL_Z), 16), "Trim")
    style.boolean_cut(hull, cutter)
style.bevel(hull, segments=2)

TOP_SCALE = (WIDTH - 1.7) / (WIDTH - 0.5)  # tumblehome: the roof is narrower than the base
gh_profile = [
    (CABIN_FRONT, HZ - 0.05),
    (CABIN_REAR, HZ - 0.05),
    (CABIN_OFFSET + 2.2, CABIN_TOP),
    (CABIN_OFFSET - 1.6, CABIN_TOP),
]
gh_bm = style.extrude_profile(gh_profile, WIDTH - 0.5)
for v in gh_bm.verts:
    if v.co.z > HZ + 1:
        v.co.x *= TOP_SCALE
greenhouse = part("Greenhouse", gh_bm, "Paint", color=PREVIEW_PAINT)
style.bevel(greenhouse, width=0.1, segments=2)

# --- glass: thin panels floating just off the greenhouse surface ----------------------------
GH_BASE_X = (WIDTH - 0.5) / 2
GH_TOP_X = GH_BASE_X * TOP_SCALE
GH_Z0, GH_Z1 = HZ - 0.05, CABIN_TOP
GLASS_OUT = 0.04


def side_x(z):
    t = (z - GH_Z0) / (GH_Z1 - GH_Z0)
    return GH_BASE_X + (GH_TOP_X - GH_BASE_X) * t + GLASS_OUT


def lerp(a, b, t):
    return a + (b - a) * t


def windshield_y(z):
    return lerp(gh_profile[0][0], gh_profile[3][0], (z - GH_Z0) / (GH_Z1 - GH_Z0))


def rear_glass_y(z):
    return lerp(gh_profile[1][0], gh_profile[2][0], (z - GH_Z0) / (GH_Z1 - GH_Z0))


glass_bm = bmesh.new()


def quad(points):
    glass_bm.faces.new([glass_bm.verts.new(p) for p in points])


def slanted_panel(y_of_z, z_lo, z_hi, margin, push):
    xs_lo, xs_hi = side_x(z_lo) - GLASS_OUT - margin, side_x(z_hi) - GLASS_OUT - margin
    quad([
        (-xs_lo, y_of_z(z_lo) + push, z_lo),
        (xs_lo, y_of_z(z_lo) + push, z_lo),
        (xs_hi, y_of_z(z_hi) + push, z_hi),
        (-xs_hi, y_of_z(z_hi) + push, z_hi),
    ])


Z_LO, Z_HI = HZ + 0.45, CABIN_TOP - 0.35
slanted_panel(windshield_y, Z_LO, Z_HI, 0.35, -GLASS_OUT)  # windshield
slanted_panel(rear_glass_y, Z_LO + 0.1, Z_HI, 0.35, GLASS_OUT)  # rear window

B_PILLAR = (CABIN_OFFSET - 0.3, CABIN_OFFSET + 0.25)
for sx in (-1, 1):
    front = [
        (windshield_y(Z_LO) + 0.4, Z_LO),
        (B_PILLAR[0], Z_LO),
        (B_PILLAR[0], Z_HI),
        (windshield_y(Z_HI) + 0.4, Z_HI),
    ]
    rear = [
        (B_PILLAR[1], Z_LO),
        (rear_glass_y(Z_LO) - 0.4, Z_LO),
        (rear_glass_y(Z_HI) - 0.4, Z_HI),
        (B_PILLAR[1], Z_HI),
    ]
    for window in (front, rear):
        pts = [(sx * side_x(z), y, z) for y, z in window]
        quad(pts if sx > 0 else list(reversed(pts)))
bmesh.ops.recalc_face_normals(glass_bm, faces=glass_bm.faces)
windows = part("Windows", glass_bm, "Glass")

# --- trim, lights --------------------------------------------------------------------------
for name, y in (("BumperFront", -HY - 0.3), ("BumperRear", HY + 0.3)):
    bumper = part(name, style.box((WIDTH + 0.2, 0.8, 0.9), (0, y, -HZ + 0.6)), "Trim")
    style.bevel(bumper, width=0.15, segments=2)

grille = part("Grille", style.box((2.6, 0.12, 0.55), (0, -HY - 0.02, 0.45)), "Trim")

for sx, side in ((-1, "L"), (1, "R")):
    x = sx * (HX - 1.2)
    head = part(f"Headlight{side}", style.box((1.6, 0.3, 0.6), (x, -HY + 0.05, 0.55)), "Headlight")
    tail = part(f"Taillight{side}", style.box((1.6, 0.3, 0.6), (x, HY - 0.05, 0.55)), "Taillight")
    for light in (head, tail):
        style.bevel(light, width=0.08)

# --- wheels: origin at each hub so they can spin later ------------------------------------
for fy, fname in ((-1, "F"), (1, "R")):
    for sx, sname in ((-1, "L"), (1, "R")):
        center = Vector((sx * WHEEL_X, fy * WHEEL_Y, WHEEL_Z))
        tire = part(f"Wheel{fname}{sname}", style.cylinder_x(WHEEL_RADIUS, 1.5, segments=14), "Tire")
        tire.location = center
        style.bevel(tire, width=0.2, segments=2)
        hub = part(f"Hubcap{fname}{sname}", style.cylinder_x(WHEEL_RADIUS * 0.5, 1.6, segments=10), "Hubcap")
        hub.location = center

# --- finish --------------------------------------------------------------------------------
style.apply_modifiers([o for o in coll.objects if o.type == "MESH"])

bpy.ops.object.select_all(action="DESELECT")
hull.select_set(True)
greenhouse.select_set(True)
bpy.context.view_layer.objects.active = hull
bpy.ops.object.join()
hull.name = hull.data.name = "Body"

style.preview_setup(LENGTH)

if __name__ == "__main__":
    blend = os.path.join(style.ART_DIR, "sedan.blend")
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    fbx = style.export_fbx(coll, "Sedan.fbx")
    print("saved", blend, "and", fbx)
