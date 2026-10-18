"""Sedan: low-poly replacement for the v0.1 graybox Sedan built by CarFactory.luau.

Sizes are the v0.1 Sedan from src/shared/Config.luau, and part placement follows CarFactory, so
the meshes drop onto the existing Chassis without moving seats, wheels or the cargo crate.
Origin = Chassis centre; front = -Y (Roblox -Z); left = +X (Roblox -X).

build() is shared with other sedan-bodied cars (police.py).
"""

import importlib
import os
import sys
from types import SimpleNamespace

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import style  # noqa: E402

importlib.reload(style)


def build(name="Sedan", width=7.4, height=2.4, length=15.0, cabin_height=3.0, ride_height=1.6,
          wheel_radius=1.5, paint=style.CAR_COLORS[0]):
    """Build a sedan body from Config.Vehicles.Types sizes. Returns the dimensions as a namespace."""
    d = SimpleNamespace(width=width, length=length, cabin_height=cabin_height)
    d.hx, d.hz, d.hy = width / 2, height / 2, length / 2  # half extents (Blender X, Z, Y)
    d.cabin_length = length * 0.5
    d.cabin_offset = length * 0.04  # towards the rear (+Y)
    d.cabin_front = d.cabin_offset - d.cabin_length / 2 - 0.25
    d.cabin_rear = d.cabin_offset + d.cabin_length / 2
    d.cabin_top = d.hz + cabin_height + 0.2  # roof included, as in CarFactory
    d.wheel_x = d.hx - 0.5
    d.wheel_y = d.hy - 2.6
    d.wheel_z = -d.hz - ride_height + wheel_radius
    d.wheel_radius = wheel_radius
    hx, hz, hy = d.hx, d.hz, d.hy

    style.reset_scene()
    coll = style.collection(name)
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "ARROWS"
    coll.objects.link(root)
    d.coll, d.root = coll, root

    def part(part_name, bm, mat, **kw):
        return style.object_from_bmesh(part_name, bm, mat, coll, parent=root, **kw)

    d.part = part

    # --- body: lower hull with wheel arches, plus the greenhouse ----------------------------
    hull_profile = [
        (-hy + 0.3, -hz),
        (hy - 0.3, -hz),
        (hy, -hz + 0.3),
        (hy + 0.05, 0.6),
        (hy - 0.25, hz - 0.05),
        (d.cabin_rear + 0.1, hz + 0.05),
        (d.cabin_front - 0.2, hz + 0.05),
        (-hy + 0.35, hz - 0.15),
        (-hy - 0.05, 0.5),
        (-hy, -hz + 0.3),
    ]
    hull = part("Hull", style.extrude_profile(hull_profile, width), "Paint", color=paint)
    for i, y in enumerate((-d.wheel_y, d.wheel_y)):
        cutter = part(f"ArchCutter{i}", style.cylinder_x(wheel_radius + 0.3, width + 2, (0, y, d.wheel_z), 16), "Trim")
        style.boolean_cut(hull, cutter)
    style.bevel(hull, segments=2)

    top_scale = (width - 1.7) / (width - 0.5)  # tumblehome: the roof is narrower than the base
    gh_profile = [
        (d.cabin_front, hz - 0.05),
        (d.cabin_rear, hz - 0.05),
        (d.cabin_offset + 2.2, d.cabin_top),
        (d.cabin_offset - 1.6, d.cabin_top),
    ]
    d.roof_front, d.roof_rear = gh_profile[3][0], gh_profile[2][0]
    gh_bm = style.extrude_profile(gh_profile, width - 0.5)
    for v in gh_bm.verts:
        if v.co.z > hz + 1:
            v.co.x *= top_scale
    greenhouse = part("Greenhouse", gh_bm, "Paint", color=paint)
    style.bevel(greenhouse, width=0.1, segments=2)

    # --- glass: thin panels floating just off the greenhouse surface ------------------------
    gh_base_x = (width - 0.5) / 2
    gh_top_x = gh_base_x * top_scale
    gh_z0, gh_z1 = hz - 0.05, d.cabin_top
    glass_out = 0.04

    def lerp(a, b, t):
        return a + (b - a) * t

    def side_x(z):
        return lerp(gh_base_x, gh_top_x, (z - gh_z0) / (gh_z1 - gh_z0)) + glass_out

    def windshield_y(z):
        return lerp(gh_profile[0][0], gh_profile[3][0], (z - gh_z0) / (gh_z1 - gh_z0))

    def rear_glass_y(z):
        return lerp(gh_profile[1][0], gh_profile[2][0], (z - gh_z0) / (gh_z1 - gh_z0))

    glass_bm = bmesh.new()

    def quad(points):
        glass_bm.faces.new([glass_bm.verts.new(p) for p in points])

    def slanted_panel(y_of_z, z_lo, z_hi, margin, push):
        xs_lo, xs_hi = side_x(z_lo) - glass_out - margin, side_x(z_hi) - glass_out - margin
        quad([
            (-xs_lo, y_of_z(z_lo) + push, z_lo),
            (xs_lo, y_of_z(z_lo) + push, z_lo),
            (xs_hi, y_of_z(z_hi) + push, z_hi),
            (-xs_hi, y_of_z(z_hi) + push, z_hi),
        ])

    z_lo, z_hi = hz + 0.45, d.cabin_top - 0.35
    slanted_panel(windshield_y, z_lo, z_hi, 0.35, -glass_out)  # windshield
    slanted_panel(rear_glass_y, z_lo + 0.1, z_hi, 0.35, glass_out)  # rear window

    b_pillar = (d.cabin_offset - 0.3, d.cabin_offset + 0.25)
    for sx in (-1, 1):
        front = [
            (windshield_y(z_lo) + 0.4, z_lo),
            (b_pillar[0], z_lo),
            (b_pillar[0], z_hi),
            (windshield_y(z_hi) + 0.4, z_hi),
        ]
        rear = [
            (b_pillar[1], z_lo),
            (rear_glass_y(z_lo) - 0.4, z_lo),
            (rear_glass_y(z_hi) - 0.4, z_hi),
            (b_pillar[1], z_hi),
        ]
        for window in (front, rear):
            pts = [(sx * side_x(z), y, z) for y, z in window]
            quad(pts if sx > 0 else list(reversed(pts)))
    bmesh.ops.recalc_face_normals(glass_bm, faces=glass_bm.faces)
    part("Windows", glass_bm, "Glass")

    # --- trim, lights -----------------------------------------------------------------------
    for part_name, y in (("BumperFront", -hy - 0.3), ("BumperRear", hy + 0.3)):
        bumper = part(part_name, style.box((width + 0.2, 0.8, 0.9), (0, y, -hz + 0.6)), "Trim")
        style.bevel(bumper, width=0.15, segments=2)

    part("Grille", style.box((2.6, 0.12, 0.55), (0, -hy - 0.02, 0.45)), "Trim")

    for sx, side in ((1, "L"), (-1, "R")):  # facing -Y, the car's left is +X
        x = sx * (hx - 1.2)
        head = part(f"Headlight{side}", style.box((1.6, 0.3, 0.6), (x, -hy + 0.05, 0.55)), "Headlight")
        tail = part(f"Taillight{side}", style.box((1.6, 0.3, 0.6), (x, hy - 0.05, 0.55)), "Taillight")
        for light in (head, tail):
            style.bevel(light, width=0.08)

    # --- wheels: origin at each hub so they can spin later ----------------------------------
    for fy, fname in ((-1, "F"), (1, "R")):
        for sx, sname in ((1, "L"), (-1, "R")):
            center = Vector((sx * d.wheel_x, fy * d.wheel_y, d.wheel_z))
            tire = part(f"Wheel{fname}{sname}", style.cylinder_x(wheel_radius, 1.5, segments=14), "Tire")
            tire.location = center
            style.bevel(tire, width=0.2, segments=2)
            hub = part(f"Hubcap{fname}{sname}", style.cylinder_x(wheel_radius * 0.5, 1.6, segments=10), "Hubcap")
            hub.location = center

    d.hull, d.greenhouse = hull, greenhouse
    return d


def finish(d, export_name):
    """Bake modifiers, merge the paint into one Body mesh, then save the .blend and export FBX."""
    style.apply_modifiers([o for o in d.coll.objects if o.type == "MESH"])
    bpy.ops.object.select_all(action="DESELECT")
    d.hull.select_set(True)
    d.greenhouse.select_set(True)
    bpy.context.view_layer.objects.active = d.hull
    bpy.ops.object.join()
    d.hull.name = d.hull.data.name = "Body"
    style.preview_setup(d.length)

    blend = os.path.join(style.ART_DIR, f"{export_name.lower()}.blend")
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    fbx = style.export_fbx(d.coll, f"{export_name}.fbx")
    print("saved", blend, "and", fbx)


if __name__ == "__main__":
    # Config.Vehicles.Types.Sedan
    finish(build("Sedan", length=15.0), "Sedan")
