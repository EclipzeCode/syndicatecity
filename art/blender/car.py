"""Shared car builder: the pieces every v0.1 vehicle has, laid out like CarFactory.luau.

A car script calls dims() with its Config.Vehicles.Types sizes, start() to open the model, then
supplies its own side profiles (hull(), greenhouse()) and window layout (Glass), and finishes
with trim_and_lights(), wheels() and finish(). Conventions are in style.py.
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


def dims(width, height, length, cabin_height, ride_height, wheel_radius, cabin_length, cabin_offset):
    """Config sizes plus CarFactory's derived layout. cabin_length/offset are fractions of length."""
    d = SimpleNamespace(width=width, height=height, length=length, cabin_height=cabin_height,
                        wheel_radius=wheel_radius)
    d.hx, d.hz, d.hy = width / 2, height / 2, length / 2  # half extents (Blender X, Z, Y)
    d.cabin_length = length * cabin_length
    d.cabin_offset = length * cabin_offset  # towards the rear (+Y)
    d.cabin_front = d.cabin_offset - d.cabin_length / 2 - 0.25
    d.cabin_rear = d.cabin_offset + d.cabin_length / 2
    d.cabin_top = d.hz + cabin_height + 0.2  # roof included, as in CarFactory
    d.wheel_x = d.hx - 0.5
    d.wheel_y = d.hy - 2.6
    d.wheel_z = -d.hz - ride_height + wheel_radius
    return d


def start(d, name):
    style.reset_scene()
    d.name = name
    d.coll = style.collection(name)
    d.root = bpy.data.objects.new(name, None)
    d.root.empty_display_type = "ARROWS"
    d.coll.objects.link(d.root)

    def part(part_name, bm, mat, **kw):
        return style.object_from_bmesh(part_name, bm, mat, d.coll, parent=d.root, **kw)

    d.part = part
    return d


def hull(d, profile, paint):
    """Lower body: side profile [(y, z), ...] extruded to full width, wheel arches cut out."""
    obj = d.part("Hull", style.extrude_profile(profile, d.width), "Paint", color=paint)
    for i, y in enumerate((-d.wheel_y, d.wheel_y)):
        cutter = d.part(f"ArchCutter{i}",
                        style.cylinder_x(d.wheel_radius + 0.3, d.width + 2, (0, y, d.wheel_z), 16), "Trim")
        style.boolean_cut(obj, cutter)
    style.bevel(obj, segments=2)
    d.hull = obj
    return obj


def greenhouse(d, profile, paint, top_inset=1.2):
    """Cabin: side profile extruded to CarFactory's cabin width, roof narrowed by top_inset."""
    base_w = d.width - 0.5
    top_scale = (base_w - top_inset) / base_w
    bm = style.extrude_profile(profile, base_w)
    for v in bm.verts:
        if v.co.z > d.hz + 1:
            v.co.x *= top_scale
    obj = d.part("Greenhouse", bm, "Paint", color=paint)
    style.bevel(obj, width=0.1, segments=2)
    d.greenhouse = obj
    d.gh_profile = profile
    d.gh_base_x, d.gh_top_x = base_w / 2, base_w / 2 * top_scale
    return obj


def _lerp(a, b, t):
    return a + (b - a) * t


class Glass:
    """Thin glass panels floating just off a greenhouse built from a 4-point profile:
    [front-bottom, rear-bottom, rear-top, front-top]."""

    OUT = 0.04

    def __init__(self, d):
        self.d = d
        self.bm = bmesh.new()
        p = d.gh_profile
        self.z0, self.z1 = p[0][1], p[3][1]
        self.front_line = (p[0][0], p[3][0])
        self.rear_line = (p[1][0], p[2][0])

    def _t(self, z):
        return (z - self.z0) / (self.z1 - self.z0)

    def side_x(self, z):
        return _lerp(self.d.gh_base_x, self.d.gh_top_x, self._t(z)) + self.OUT

    def front_y(self, z):
        return _lerp(*self.front_line, self._t(z))

    def rear_y(self, z):
        return _lerp(*self.rear_line, self._t(z))

    def quad(self, points):
        self.bm.faces.new([self.bm.verts.new(p) for p in points])

    def end_panel(self, front, z_lo, z_hi, margin, x_lo=None):
        """Windshield (front=True) or rear window across the end face. x_lo splits it into a
        left and right pane with a centre bar of width 2 * x_lo."""
        y_of = self.front_y if front else self.rear_y
        push = -self.OUT if front else self.OUT
        xs_lo = self.side_x(z_lo) - self.OUT - margin
        xs_hi = self.side_x(z_hi) - self.OUT - margin
        spans = [(-1, 1)] if x_lo is None else [(-1, -x_lo), (x_lo, 1)]
        for a, b in spans:
            def x(s, xs):
                return xs * s if abs(s) == 1 else s
            self.quad([
                (x(a, xs_lo), y_of(z_lo) + push, z_lo),
                (x(b, xs_lo), y_of(z_lo) + push, z_lo),
                (x(b, xs_hi), y_of(z_hi) + push, z_hi),
                (x(a, xs_hi), y_of(z_hi) + push, z_hi),
            ])

    def side_window(self, window):
        """window = [(y, z), ...] on the side, mirrored to both sides."""
        for sx in (-1, 1):
            pts = [(sx * self.side_x(z), y, z) for y, z in window]
            self.quad(pts if sx > 0 else list(reversed(pts)))

    def build(self):
        bmesh.ops.recalc_face_normals(self.bm, faces=self.bm.faces)
        return self.d.part("Windows", self.bm, "Glass")


def trim_and_lights(d):
    """Bumpers, grille, head- and taillights where CarFactory puts them."""
    hx, hy, hz = d.hx, d.hy, d.hz
    for part_name, y in (("BumperFront", -hy - 0.3), ("BumperRear", hy + 0.3)):
        bumper = d.part(part_name, style.box((d.width + 0.2, 0.8, 0.9), (0, y, -hz + 0.6)), "Trim")
        style.bevel(bumper, width=0.15, segments=2)

    d.part("Grille", style.box((2.6, 0.12, 0.55), (0, -hy - 0.02, hz - 0.75)), "Trim")

    for sx, side in ((1, "L"), (-1, "R")):  # facing -Y, the car's left is +X
        x = sx * (hx - 1.2)
        z = hz - 0.65
        head = d.part(f"Headlight{side}", style.box((1.6, 0.3, 0.6), (x, -hy + 0.05, z)), "Headlight")
        tail = d.part(f"Taillight{side}", style.box((1.6, 0.3, 0.6), (x, hy - 0.05, z)), "Taillight")
        for light in (head, tail):
            style.bevel(light, width=0.08)


def wheels(d):
    """Tire and hubcap per corner, origin at the hub so they can spin later."""
    for fy, fname in ((-1, "F"), (1, "R")):
        for sx, sname in ((1, "L"), (-1, "R")):
            center = Vector((sx * d.wheel_x, fy * d.wheel_y, d.wheel_z))
            tire = d.part(f"Wheel{fname}{sname}", style.cylinder_x(d.wheel_radius, 1.5, segments=14), "Tire")
            tire.location = center
            style.bevel(tire, width=0.2, segments=2)
            hub = d.part(f"Hubcap{fname}{sname}",
                         style.cylinder_x(d.wheel_radius * 0.5, 1.6, segments=10), "Hubcap")
            hub.location = center


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


def join(target, others):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in [target, *others]:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.join()
