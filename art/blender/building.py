"""Building kit: parametric low-poly buildings in the same style as the cars.

Roblox can't resize a MeshPart without stretching its windows, so buildings are exported as a
fixed set of variants (buildings.py) built from these pieces at the sizes MapBuilder.luau uses.

Conventions on top of style.py:
- Origin at the centre of the footprint, on the ground (MapBuilder's `base`).
- The street face is the front, -Y (Roblox -Z), like the cars.
- Each Building collects geometry into a few batches, one material each, so a building imports
  as a handful of MeshParts: Body (tintable wall color), Trim, Windows, Roof and a few extras.
"""

import importlib
import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import style  # noqa: E402

importlib.reload(style)

PAL = style.PALETTE
rgb = style.rgb
BUILDINGS = {  # src/shared/Palette.luau Buildings / Industrial
    "cream": rgb(232, 220, 196),
    "terracotta": rgb(206, 124, 94),
    "sand": rgb(222, 192, 142),
    "slate": rgb(116, 136, 166),
    "mint": rgb(152, 192, 172),
    "pink": rgb(212, 164, 162),
    "concrete": rgb(168, 168, 176),
    "brick": rgb(178, 100, 72),
    "steel": rgb(142, 152, 162),
    "rust": rgb(156, 96, 64),
    "teal": rgb(64, 132, 142),
}
CONTAINERS = [rgb(198, 74, 64), rgb(62, 112, 172), rgb(82, 142, 92), rgb(222, 172, 62), rgb(222, 122, 52)]
CURB = rgb(170, 164, 154)
SIDEWALK = rgb(200, 194, 182)
ROCK = rgb(140, 140, 146)
TRUNK = rgb(112, 82, 60)
YELLOW = rgb(240, 180, 40)
INTERIOR = rgb(40, 38, 42)

FLOOR = 12.0  # studs per storey, as in MapBuilder


def faces(w, d):
    """The four walls of a w x d footprint: (name, centre, tangent, outward normal, width).
    tangent x up = normal, so (u, z) quads built from them face outward."""
    return [
        ("front", Vector((0, -d / 2, 0)), Vector((1, 0, 0)), Vector((0, -1, 0)), w),
        ("back", Vector((0, d / 2, 0)), Vector((-1, 0, 0)), Vector((0, 1, 0)), w),
        ("right", Vector((w / 2, 0, 0)), Vector((0, 1, 0)), Vector((1, 0, 0)), d),
        ("left", Vector((-w / 2, 0, 0)), Vector((0, -1, 0)), Vector((-1, 0, 0)), d),
    ]


def bays(width, spacing, margin=3.0):
    """Centres of evenly spread bays along a wall of `width`."""
    usable = width - 2 * margin
    n = max(1, int(usable / spacing))
    return [-usable / 2 + (i + 0.5) * usable / n for i in range(n)]


class Building:
    def __init__(self, name, wall, seed=1):
        self.name = name
        self.wall = wall
        self.rng = random.Random(seed)
        self.coll = style.collection(name)
        self.root = bpy.data.objects.new(name, None)
        self.root.empty_display_type = "ARROWS"
        self.coll.objects.link(self.root)
        self.batches = {}

    # --- batches -------------------------------------------------------------------------------
    def batch(self, key, color=None, surface=None, bevel=0.0):
        """Geometry bucket that becomes one object/material. Common keys get house defaults."""
        if key not in self.batches:
            defaults = {
                "Body": (self.wall, "Wall", 0.15),
                "Trim": (SIDEWALK, "Concrete", 0.0),  # too small to bevel at building scale
                "Windows": (PAL["Glass"], "Glass", 0.0),
                "Roof": (PAL["Roof"], "Roof", 0.0),
                "Frame": (PAL["Trim"], "Frame", 0.0),
                "RoofUnits": (ROCK, "Metal", 0.1),
            }
            dc, ds, db = defaults.get(key, (None, "Accent", 0.0))
            self.batches[key] = {
                "bm": bmesh.new(),
                "color": color or dc,
                "surface": surface or ds,
                "bevel": bevel or db,
            }
        return self.batches[key]["bm"]

    def box(self, key, size, center, rot_x=0.0):
        """Axis-aligned box (optionally tilted about X) added to batch `key`."""
        bm = self.batch(key)
        m = Matrix.Translation(Vector(center)) @ Matrix.Rotation(rot_x, 4, "X") @ Matrix.Diagonal((*size, 1))
        bmesh.ops.create_cube(bm, size=1.0, matrix=m)

    def cylinder(self, key, radius, height, base, segments=10):
        bm = self.batch(key)
        m = Matrix.Translation(Vector(base) + Vector((0, 0, height / 2)))
        bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=radius, radius2=radius,
                              depth=height, matrix=m)

    def quad(self, key, points):
        bm = self.batch(key)
        bm.faces.new([bm.verts.new(p) for p in points])

    def ring(self, key, w, d, z0, z1, thick, out=0.0):
        """Four boxes around a w x d footprint (parapets, cornices, ledges), `out` past the wall."""
        h, zc = z1 - z0, (z0 + z1) / 2
        ow, od = w + 2 * out, d + 2 * out
        self.box(key, (ow, thick, h), (0, -od / 2 + thick / 2, zc))
        self.box(key, (ow, thick, h), (0, od / 2 - thick / 2, zc))
        self.box(key, (thick, od - 2 * thick, h), (ow / 2 - thick / 2, 0, zc))
        self.box(key, (thick, od - 2 * thick, h), (-ow / 2 + thick / 2, 0, zc))

    def band(self, key, w, d, z0, z1, out):
        """A solid slab slightly bigger than the footprint: reads as a band on all four walls."""
        self.box(key, (w + 2 * out, d + 2 * out, z1 - z0), (0, 0, (z0 + z1) / 2))

    # --- facade helpers ------------------------------------------------------------------------
    def face_box(self, key, face, u, z, su, sn, sz, out):
        """Box on a wall: su along the wall, sn out of it, its inner face `out` from the wall."""
        _, c, t, n, _ = face
        center = c + t * u + n * (out + sn / 2) + Vector((0, 0, z))
        size = (su, sn, sz) if abs(t.x) > 0.5 else (sn, su, sz)
        self.box(key, size, center)

    def face_quad(self, key, face, u0, u1, z0, z1, out=0.05):
        _, c, t, n, _ = face
        p = lambda u, z: c + t * u + n * out + Vector((0, 0, z))  # noqa: E731
        self.quad(key, [p(u0, z0), p(u1, z0), p(u1, z1), p(u0, z1)])

    def punched_windows(self, w, d, floors, z_first, win_w=4.0, win_h=5.5, spacing=8.0,
                        skip=(), sill=True, z_offset=0.0):
        """One glass pane per bay per floor with a sill and header in Trim."""
        for face in faces(w, d):
            if face[0] in skip:
                continue
            for f in range(floors):
                z = z_offset + z_first + f * FLOOR
                for u in bays(face[4], spacing):
                    self.face_quad("Windows", face, u - win_w / 2, u + win_w / 2, z, z + win_h)
                    if sill:
                        self.face_box("Trim", face, u, z - 0.2, win_w + 1.0, 0.6, 0.4, 0)
                        self.face_box("Trim", face, u, z + win_h + 0.25, win_w + 0.6, 0.3, 0.5, 0)

    def curtain_wall(self, w, d, z0, floors, bay=7.0, glass=0.62, offset=(0, 0)):
        """Office facade: glass band per floor, spandrel ledges between, pilasters between bays."""
        ox, oy = offset
        for f in range(floors):
            zf = z0 + f * FLOOR
            self.box("Windows", (w + 0.1, d + 0.1, FLOOR * glass), (ox, oy, zf + 1.6 + FLOOR * glass / 2))
            self.box("Trim", (w + 0.7, d + 0.7, 0.7), (ox, oy, zf + 0.35))
        top = z0 + floors * FLOOR
        for face in faces(w, d):
            ups = bays(face[4], bay, margin=0.0)
            step = ups[1] - ups[0] if len(ups) > 1 else face[4]
            for u in [x - step / 2 for x in ups] + [ups[-1] + step / 2]:
                c = face[1] + Vector((ox, oy, 0))
                self.face_box("Body", (face[0], c, *face[2:]), u, (z0 + top) / 2, 0.9, 0.5, top - z0, 0)

    def parapet(self, w, d, h, height=1.6, cornice=True, offset=(0, 0), body="Body"):
        """Flat roof inside a parapet (in the `body` batch), with an optional Trim cornice."""
        ox, oy = offset
        self.box("Roof", (w - 1.2, d - 1.2, 0.3), (ox, oy, h + 0.15))
        bm_offset = Vector((ox, oy, 0))
        self._ring_at(body, w, d, h, h + height, 0.8, 0.0, bm_offset)
        if cornice:
            self._ring_at("Trim", w, d, h + height - 0.5, h + height + 0.1, 1.0, 0.3, bm_offset)

    def _ring_at(self, key, w, d, z0, z1, thick, out, offset):
        before = len(self.batch(key).verts)
        self.ring(key, w, d, z0, z1, thick, out)
        bm = self.batch(key)
        bm.verts.ensure_lookup_table()
        for v in bm.verts[before:]:
            v.co += offset

    def roof_units(self, w, d, h, count=3, offset=(0, 0)):
        ox, oy = offset
        for _ in range(count):
            sx, sy = self.rng.uniform(4, 8), self.rng.uniform(4, 7)
            x = ox + self.rng.uniform(-w / 2 + sx, w / 2 - sx)
            y = oy + self.rng.uniform(-d / 2 + sy, d / 2 - sy)
            self.box("RoofUnits", (sx, sy, 3.0), (x, y, h + 1.8))
            self.box("RoofUnits", (sx * 0.6, sy * 0.6, 0.4), (x, y, h + 3.5))

    def storefront(self, face, width, height=10.0, awning=None, door=True, z=0.0):
        """Ground-floor shop glass with mullions, a door and an optional sloped awning."""
        half = width / 2
        self.face_quad("Windows", face, -half, half, z + 0.8, z + height - 1.0, out=0.08)
        self.face_box("Frame", face, 0, z + 0.4, width + 0.6, 0.5, 0.8, 0)
        self.face_box("Frame", face, 0, z + height - 0.8, width + 0.6, 0.5, 0.6, 0)
        for u in bays(width, 6.0, margin=0)[:-1]:
            step = width / max(1, len(bays(width, 6.0, margin=0)))
            self.face_box("Frame", face, u + step / 2, z + height / 2, 0.35, 0.3, height - 1.4, 0)
        if door:
            self.batch("Door", color=PAL["Glass"], surface="Glass")
            self.face_box("Frame", face, 0, z + 3.8, 4.6, 0.35, 7.6, 0)
            self.face_quad("Door", face, -1.9, 1.9, z + 0.2, z + 7.4, out=0.4)
        if awning:
            self.batch("Awning", color=awning, surface="Accent", bevel=0.1)
            _, c, t, n, _ = face
            depth = 4.5
            center = c + n * (depth / 2) + Vector((0, 0, z + height + 0.4))
            tilt = math.radians(14)  # outer edge lower
            rot = Matrix.Rotation(math.atan2(n.x, -n.y), 4, "Z") @ Matrix.Rotation(tilt, 4, "X")
            m = Matrix.Translation(center) @ rot @ Matrix.Diagonal((width + 1.0, depth, 0.5, 1))
            bmesh.ops.create_cube(self.batch("Awning"), size=1.0, matrix=m)

    def gable(self, key, w, d, z0, rise, overhang=1.5, thick=0.6):
        """Pitched roof with the ridge along X."""
        bm = self.batch(key)
        hw, hd = w / 2 + overhang, d / 2 + overhang
        # roof slab cross-section (a chevron) extruded along X
        profile = [(-hd, z0), (0, z0 + rise), (hd, z0), (hd, z0 + thick), (0, z0 + rise + thick), (-hd, z0 + thick)]
        # the profile runs counter-clockwise seen from +X; faces are wound to point outward
        left = [bm.verts.new((-hw, y, z)) for y, z in profile]
        right = [bm.verts.new((hw, y, z)) for y, z in profile]
        bm.faces.new(list(reversed(left)))
        bm.faces.new(right)
        for i in range(len(profile)):
            j = (i + 1) % len(profile)
            bm.faces.new((left[i], left[j], right[j], right[i]))

    def gable_wall(self, key, w, d, z0, rise):
        """Triangular wall infill under a gable, both ends."""
        bm = self.batch(key)
        for x in (-w / 2, w / 2):
            tri = [bm.verts.new((x, -d / 2, z0)), bm.verts.new((x, d / 2, z0)), bm.verts.new((x, 0, z0 + rise))]
            bm.faces.new(tri if x > 0 else list(reversed(tri)))

    # --- output --------------------------------------------------------------------------------
    def finish(self, export=True):
        """Turn batches into objects (one material each), export FBX, return the root."""
        objs = []
        for key, b in self.batches.items():
            bm = b["bm"]
            if not bm.faces:
                bm.free()
                continue
            # every piece is built wound outward; recalculating would flip lone glass quads
            mesh = bpy.data.meshes.new(f"{self.name}_{key}")
            bm.to_mesh(mesh)
            bm.free()
            obj = bpy.data.objects.new(f"{self.name}_{key}", mesh)
            mesh.materials.append(style.material(f"{self.name}_{key}", b["color"], b["surface"]))
            for poly in mesh.polygons:
                poly.use_smooth = False
            self.coll.objects.link(obj)
            obj.parent = self.root
            if b["bevel"]:
                style.bevel(obj, width=b["bevel"], segments=1)
            objs.append(obj)
        style.apply_modifiers(objs)
        if export:
            style.export_fbx(self.coll, os.path.join("buildings", f"{self.name}.fbx"))
        return self.root
