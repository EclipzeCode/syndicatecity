"""Dump every car, building, nature prop and environment piece as JSON mesh data for src/tools/MeshImporter.luau.

FBX needs Studio's 3D importer, which only runs from its UI. This writes the same geometry as
art/export/roblox/<Name>.json so MeshImporter can rebuild each object as an EditableMesh in
Studio and upload it as a mesh asset.

Each file: {"name", "parts": [{"name", "color": [r, g, b] 0-255, "kind": "solid"|"glass"|"neon",
"center": [x, y, z], "positions": [x, y, z, ...], "triangles": [a, b, c, ...]}]}
Coordinates are Roblox studs relative to the asset origin (Roblox = (-x, z, y) of Blender, the
same turn the FBX export makes), and positions are relative to the part's bounding-box centre,
which is where Roblox puts a MeshPart's origin.

    blender --background --python art/blender/roblox_export.py
"""

import importlib
import json
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import buildings  # noqa: E402
import car  # noqa: E402
import environment  # noqa: E402
import nature  # noqa: E402
import police  # noqa: E402
import sedan  # noqa: E402
import style  # noqa: E402
import van  # noqa: E402

for mod in (style, car, sedan, police, van, buildings, nature, environment):
    importlib.reload(mod)

OUT_DIR = os.path.join(style.EXPORT_DIR, "roblox")


def to_roblox(v):
    return Vector((-v.x, v.z, v.y))


def linear_to_srgb(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def describe(mat):
    bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    color = [round(linear_to_srgb(c) * 255) for c in bsdf.inputs["Base Color"].default_value[:3]]
    if bsdf.inputs["Emission Strength"].default_value > 0:
        kind = "neon"
    elif bsdf.inputs["Roughness"].default_value < 0.15:  # glass is 0.1, stored as 0.100000001
        kind = "glass"
    else:
        kind = "solid"
    return color, kind


def dump(root, name):
    to_local = root.matrix_world.inverted()
    parts = []
    for obj in root.children:
        if obj.type != "MESH" or not obj.data.polygons:
            continue
        mesh = obj.data
        mesh.calc_loop_triangles()
        m = to_local @ obj.matrix_world
        verts = [to_roblox(m @ v.co) for v in mesh.vertices]
        lo = Vector([min(v[i] for v in verts) for i in range(3)])
        hi = Vector([max(v[i] for v in verts) for i in range(3)])
        center = (lo + hi) / 2
        positions = []
        for v in verts:
            positions.extend(round(c, 3) for c in v - center)
        triangles = []
        for tri in mesh.loop_triangles:
            a, b, c = tri.vertices
            # the Blender -> Roblox turn is a proper rotation, so winding is kept
            triangles.extend((a, b, c))
        color, kind = describe(mesh.materials[0])
        part_name = obj.name.split(".")[0]
        if part_name.startswith(name + "_"):
            part_name = part_name[len(name) + 1:]
        parts.append({
            "name": part_name,
            "color": color,
            "kind": kind,
            "center": [round(c, 3) for c in center],
            "positions": positions,
            "triangles": triangles,
        })
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, f"{name}.json"), "w") as f:
        json.dump({"name": name, "parts": parts}, f, separators=(",", ":"))
    tris = sum(len(p["triangles"]) // 3 for p in parts)
    print(f"{name}: {len(parts)} parts, {tris} tris")


def main():
    car.finish(sedan.build("Sedan", length=15.0), "Sedan")
    dump(bpy.data.objects["Sedan"], "Sedan")
    car.finish(police.build(), "Police")
    dump(bpy.data.objects["Police"], "Police")
    car.finish(van.build(), "Van")
    dump(bpy.data.objects["Van"], "Van")
    roots = buildings.build_all(export=False)
    for root in roots:
        dump(root, root.name)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(style.ART_DIR, "buildings.blend"))
    style.reset_scene()
    for root in nature.build_all(export=False):
        dump(root, root.name)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(style.ART_DIR, "nature.blend"))
    style.reset_scene()
    for root in environment.build_all(export=False):
        dump(root, root.name)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(style.ART_DIR, "environment.blend"))


if __name__ == "__main__":
    main()
