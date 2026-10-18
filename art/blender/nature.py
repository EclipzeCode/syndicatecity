"""Nature props for the v0.1 map: trees, a bush, rocks and a grass tuft.

Same look as the cars and buildings (style.py): low poly, flat shading, flat Palette colors, a
little chunky. Each prop is a few objects, one material each, so it imports as a few MeshParts:
trees are Trunk + Leaves (MapBuilder tints Leaves from Palette.Leaves), rocks are Rock and the
tuft is Blades.

Origins: on the ground at the centre of the footprint. Sizes are a typical instance in studs;
MapBuilder scales them.

    blender --background --python art/blender/nature.py
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

rgb = style.rgb
LEAVES = rgb(96, 168, 84)
PINE = rgb(54, 122, 82)
BUSH = rgb(110, 176, 92)
TRUNK = rgb(112, 82, 60)
ROCK = rgb(150, 150, 158)
BLADES = rgb(124, 190, 92)


class Prop:
    """A prop under an empty root, built from batches of geometry (one material each)."""

    def __init__(self, name, seed):
        self.name = name
        self.rng = random.Random(seed)
        self.coll = style.collection(name)
        self.root = bpy.data.objects.new(name, None)
        self.root.empty_display_type = "ARROWS"
        self.coll.objects.link(self.root)
        self.batches = {}

    def batch(self, key, color, surface="Accent"):
        if key not in self.batches:
            self.batches[key] = {"bm": bmesh.new(), "color": color, "surface": surface}
        return self.batches[key]["bm"]

    def jitter(self, verts, amount, keep_floor=None):
        """Nudge vertices for a hand-made, faceted look. Verts at `keep_floor` stay on it."""
        for v in verts:
            if keep_floor is not None and abs(v.co.z - keep_floor) < 1e-4:
                v.co.x += self.rng.uniform(-amount, amount)
                v.co.y += self.rng.uniform(-amount, amount)
                continue
            v.co += Vector([self.rng.uniform(-amount, amount) for _ in range(3)])

    def blob(self, key, center, radius, squash=1.0, subdivisions=2, jitter=0.1, floor=None):
        """A faceted ball (icosphere), optionally squashed and with its underside cut flat at
        `floor` (studs)."""
        bm = self.batches[key]["bm"]
        before = set(bm.verts)
        bmesh.ops.create_icosphere(bm, subdivisions=subdivisions, radius=radius,
                                   matrix=Matrix.Translation(Vector(center)) @ Matrix.Diagonal((1, 1, squash, 1)))
        verts = [v for v in bm.verts if v not in before]
        self.jitter(verts, radius * jitter)
        if floor is not None:
            for v in verts:
                v.co.z = max(v.co.z, floor)

    def cone(self, key, base, height, r0, r1, segments, lean=(0.0, 0.0), jitter=0.0):
        """Tapered cylinder or cone standing on `base`, its top shifted by `lean`."""
        bm = self.batches[key]["bm"]
        before = set(bm.verts)
        bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=r0, radius2=r1, depth=height,
                              matrix=Matrix.Translation(Vector(base) + Vector((0, 0, height / 2))))
        verts = [v for v in bm.verts if v not in before]
        for v in verts:
            t = (v.co.z - base[2]) / height
            v.co.x += lean[0] * t
            v.co.y += lean[1] * t
        if jitter:
            self.jitter(verts, jitter)

    def finish(self, export=True):
        objs = []
        for key, b in self.batches.items():
            bm = b["bm"]
            if not bm.faces:
                bm.free()
                continue
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
            mesh = bpy.data.meshes.new(f"{self.name}_{key}")
            bm.to_mesh(mesh)
            bm.free()
            obj = bpy.data.objects.new(f"{self.name}_{key}", mesh)
            mesh.materials.append(style.material(f"{self.name}_{key}", b["color"], b["surface"]))
            for poly in mesh.polygons:
                poly.use_smooth = False
            self.coll.objects.link(obj)
            obj.parent = self.root
            objs.append(obj)
        if export:
            style.export_fbx(self.coll, os.path.join("nature", f"{self.name}.fbx"))
        return self.root


# --- trees ----------------------------------------------------------------------------------


def tree_round(name="TreeRound", seed=1):
    """Leafy tree: a leaning trunk and a lumpy canopy of three blobs (about 20 studs tall)."""
    p = Prop(name, seed)
    p.batch("Trunk", TRUNK, "Wood")
    p.batch("Leaves", LEAVES, "Accent")
    lean = (p.rng.uniform(-0.8, 0.8), p.rng.uniform(-0.8, 0.8))
    p.cone("Trunk", (0, 0, 0), 11, 1.7, 0.9, 7, lean=lean, jitter=0.08)
    # a stub branch toward the side lump
    top = Vector((lean[0], lean[1], 11))
    p.blob("Leaves", top + Vector((0, 0, 3)), 6.2, squash=0.85)
    p.blob("Leaves", top + Vector((3.6, 1.2, 1.2)), 4.4, squash=0.85)
    p.blob("Leaves", top + Vector((-2.8, -2.2, 1.8)), 4.0, squash=0.85)
    return p


def tree_pine(name="TreePine", seed=2):
    """Conifer: three stacked, slightly crooked cones on a short trunk (about 24 studs tall)."""
    p = Prop(name, seed)
    p.batch("Trunk", TRUNK, "Wood")
    p.batch("Leaves", PINE, "Accent")
    p.cone("Trunk", (0, 0, 0), 6, 1.0, 0.8, 6)
    z = 4.0
    for radius, height in ((7.0, 9.0), (5.4, 8.0), (3.8, 7.5)):
        p.cone("Leaves", (p.rng.uniform(-0.3, 0.3), p.rng.uniform(-0.3, 0.3), z), height, radius, 0.15, 8,
               jitter=0.25)
        z += height * 0.62
    return p


def tree_tall(name="TreeTall", seed=3):
    """Poplar-ish: a slim trunk and a tall egg-shaped crown (about 26 studs tall)."""
    p = Prop(name, seed)
    p.batch("Trunk", TRUNK, "Wood")
    p.batch("Leaves", LEAVES, "Accent")
    p.cone("Trunk", (0, 0, 0), 9, 0.9, 0.6, 6)
    p.blob("Leaves", (0, 0, 16), 5.2, squash=1.9)
    p.blob("Leaves", (1.2, 0.4, 11.5), 3.6, squash=1.2)
    return p


def bush(name="Bush", seed=4):
    """A low clump of blobs with a flat bottom (about 5 studs tall)."""
    p = Prop(name, seed)
    p.batch("Leaves", BUSH, "Accent")
    for x, y, r in ((0, 0, 3.2), (2.6, 1.0, 2.4), (-2.4, 0.8, 2.2), (0.6, -2.2, 2.3)):
        p.blob("Leaves", (x, y, r * 0.75), r, squash=0.9, floor=0.0)
    return p


# --- rocks and grass ------------------------------------------------------------------------


def rock(name, seed, size, squash):
    """A faceted boulder sitting on a flat base."""
    p = Prop(name, seed)
    p.batch("Rock", ROCK, "Concrete")
    p.blob("Rock", (0, 0, size * squash * 0.55), size, squash=squash, subdivisions=2, jitter=0.18, floor=0.0)
    if p.rng.random() < 0.8:
        r = size * 0.5
        p.blob("Rock", (size * 0.9, size * 0.3, r * 0.4), r, squash=0.8, jitter=0.2, floor=0.0)
    return p


def grass_tuft(name="GrassTuft", seed=6):
    """Seven pointy blades fanning out from one spot (about 2.5 studs tall)."""
    p = Prop(name, seed)
    p.batch("Blades", BLADES, "Accent")
    for i in range(7):
        angle = i / 7 * math.tau + p.rng.uniform(-0.3, 0.3)
        out = p.rng.uniform(0.6, 1.4)
        lean = (math.cos(angle) * out, math.sin(angle) * out)
        base = (math.cos(angle) * 0.25, math.sin(angle) * 0.25, 0)
        p.cone("Blades", base, p.rng.uniform(1.6, 2.8), 0.22, 0.0, 3, lean=lean)
    return p


CATALOG = [
    lambda: tree_round(),
    lambda: tree_pine(),
    lambda: tree_tall(),
    lambda: bush(),
    lambda: rock("RockA", 11, 3.0, 0.75),
    lambda: rock("RockB", 12, 3.4, 0.55),
    lambda: rock("RockC", 13, 2.6, 0.95),
    lambda: grass_tuft(),
]

def build_all(export=True):
    roots = []
    for make in CATALOG:
        roots.append(make().finish(export=export))
    x = 0.0
    for root in roots:
        root.location = (x, 300, 0)
        x += 60
    return roots


if __name__ == "__main__":
    style.reset_scene()
    build_all()
    blend = os.path.join(style.ART_DIR, "nature.blend")
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    print("saved", blend)
