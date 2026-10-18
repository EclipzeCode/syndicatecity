"""Shared Blender style for Smuggling Game assets.

Every asset script imports this module so models share one look and one set of conventions:

- Units: 1 Blender unit = 1 Roblox stud. Sizes come straight from src/shared/Config.luau.
- Axes: Blender +Z is up and -Y is the front of a vehicle, so the vehicle's left is +X. Export
  turns the model 180 degrees about up: Blender -Y becomes Roblox -Z (LookVector, where
  CarFactory puts the headlights) and Blender +X becomes Roblox -X (CarFactory's left side).
  Name sides by the vehicle's own left/right (L = +X), never by the Blender axis.
- Origin: a vehicle's origin is the centre of its v0.1 Chassis part, so meshes line up with the
  chassis CFrame when welded in Roblox.
- One material per object. Roblox imports each object as one MeshPart and colors it with
  MeshPart.Color, so splitting by material keeps every piece tintable (car paint included).
- Look: flat colors from src/shared/Palette.luau, low poly, small bevels, flat shading.

Run an asset script from Blender's Text Editor or with:
    blender --background --python art/blender/sedan.py
"""

import os

import bmesh
import bpy
from mathutils import Vector

ART_DIR = os.path.dirname(os.path.abspath(__file__))
EXPORT_DIR = os.path.join(os.path.dirname(ART_DIR), "export")


def rgb(r, g, b):
    return (r / 255, g / 255, b / 255)


# Mirrors src/shared/Palette.luau (plus the vehicle trims from CarFactory.luau).
PALETTE = {
    "Asphalt": rgb(62, 64, 72),
    "Sidewalk": rgb(200, 194, 182),
    "Grass": rgb(112, 164, 82),
    "Wood": rgb(150, 108, 74),
    "Glass": rgb(54, 62, 76),
    "Roof": rgb(92, 92, 100),
    "PoliceWhite": rgb(240, 242, 246),
    "PoliceNavy": rgb(36, 56, 108),
    "SirenRed": rgb(255, 60, 60),
    "SirenBlue": rgb(60, 120, 255),
    "Tire": rgb(34, 34, 38),
    "Trim": rgb(70, 72, 80),
    "Hubcap": rgb(196, 198, 204),
    "Headlight": rgb(255, 244, 214),
    "Taillight": rgb(220, 40, 40),
}

CAR_COLORS = [
    rgb(214, 70, 62),
    rgb(60, 120, 200),
    rgb(240, 180, 50),
    rgb(90, 170, 110),
    rgb(170, 90, 180),
    rgb(240, 240, 236),
]

# name: (roughness, metallic, emission strength)
SURFACES = {
    "Paint": (0.35, 0.0, 0.0),
    "Glass": (0.1, 0.0, 0.0),
    "Tire": (0.9, 0.0, 0.0),
    "Trim": (0.6, 0.0, 0.0),
    "Hubcap": (0.3, 0.6, 0.0),
    "Headlight": (0.3, 0.0, 2.0),
    "Taillight": (0.3, 0.0, 2.0),
    "PoliceNavy": (0.35, 0.0, 0.0),
    "Wall": (0.8, 0.0, 0.0),
    "Concrete": (0.85, 0.0, 0.0),
    "Roof": (0.9, 0.0, 0.0),
    "Frame": (0.5, 0.0, 0.0),
    "Accent": (0.7, 0.0, 0.0),
    "Metal": (0.45, 0.3, 0.0),
    # sirens stay unlit here; EffectsController lights them in game
    "SirenRed": (0.2, 0.0, 0.0),
    "SirenBlue": (0.2, 0.0, 0.0),
}

BEVEL = 0.12  # studs; keeps silhouettes soft without adding many faces


def _srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def material(name, color=None, surface=None):
    """Return the material `name`, colored from PALETTE (or `color`) with the SURFACES finish
    of `surface` (default: `name`)."""
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
    color = color or PALETTE.get(name, (1, 1, 1))
    rough, metal, emit = SURFACES.get(surface or name, (0.5, 0.0, 0.0))
    linear = tuple(_srgb_to_linear(c) for c in color) + (1.0,)
    bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = linear
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if emit > 0:
        bsdf.inputs["Emission Color"].default_value = linear
        bsdf.inputs["Emission Strength"].default_value = emit
    mat.diffuse_color = linear  # viewport solid mode
    return mat


def reset_scene():
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras, bpy.data.lights):
        for item in list(block):
            if item.users == 0:
                block.remove(item)
    for coll in list(bpy.data.collections):
        bpy.data.collections.remove(coll)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0


def collection(name):
    coll = bpy.data.collections.get(name) or bpy.data.collections.new(name)
    if coll.name not in bpy.context.scene.collection.children:
        bpy.context.scene.collection.children.link(coll)
    return coll


def object_from_bmesh(name, bm, mat_name, coll, parent=None, color=None):
    mesh = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    obj.data.materials.append(material(mat_name, color))
    coll.objects.link(obj)
    if parent is not None:
        obj.parent = parent
    for poly in mesh.polygons:
        poly.use_smooth = False
    return obj


def extrude_profile(profile, width, x=0.0):
    """Side profile [(y, z), ...] (counter-clockwise seen from +X) extruded across X."""
    bm = bmesh.new()
    left = [bm.verts.new((x - width / 2, y, z)) for y, z in profile]
    right = [bm.verts.new((x + width / 2, y, z)) for y, z in profile]
    n = len(profile)
    bm.faces.new(list(reversed(left)))
    bm.faces.new(right)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((left[i], left[j], right[j], right[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def box(size, center=(0, 0, 0)):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2])) + Vector(center)
    return bm


def cylinder_x(radius, width, center=(0, 0, 0), segments=12):
    """Cylinder whose axis runs along X (wheels)."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=radius, radius2=radius, depth=width)
    # (x, y, z) -> (z, x, y) is a rotation, so create_cone's outward winding survives. Don't
    # recalc normals here: it guesses inside-out for short, wide cylinders like tires.
    for v in bm.verts:
        v.co = Vector((v.co.z, v.co.x, v.co.y)) + Vector(center)
    return bm


def bevel(obj, width=BEVEL, segments=1, angle=30):
    import math

    mod = obj.modifiers.new("Bevel", "BEVEL")
    mod.width = width
    mod.segments = segments
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(angle)
    mod.harden_normals = False
    return mod


def boolean_cut(obj, cutter):
    mod = obj.modifiers.new(f"Cut_{cutter.name}", "BOOLEAN")
    mod.operation = "DIFFERENCE"
    mod.object = cutter
    try:
        mod.solver = "EXACT"
    except TypeError:
        pass
    cutter.hide_viewport = True
    cutter.hide_render = True
    return mod


def apply_modifiers(objs):
    """Bake modifiers into the meshes, then delete boolean cutters that are no longer needed."""
    deps = bpy.context.evaluated_depsgraph_get()
    cutters = {m.object for o in objs for m in o.modifiers if m.type == "BOOLEAN" and m.object}
    for obj in objs:
        if obj.type != "MESH" or not obj.modifiers:
            continue
        evaluated = obj.evaluated_get(deps)
        mesh = bpy.data.meshes.new_from_object(evaluated)
        old = obj.data
        obj.modifiers.clear()
        obj.data = mesh
        mesh.name = old.name
        if old.users == 0:
            bpy.data.meshes.remove(old)
    for cutter in cutters:
        bpy.data.objects.remove(cutter, do_unlink=True)


def preview_setup(target_size=16.0):
    """Studio-style key light, sun and camera so `look`/renders read the same across assets."""
    scene = bpy.context.scene
    world = scene.world or bpy.data.worlds.new("World")
    scene.world = world
    world.use_nodes = True
    bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Color"].default_value = (0.62, 0.68, 0.76, 1)
    bg.inputs["Strength"].default_value = 0.8

    sun_data = bpy.data.lights.new("Sun", "SUN")
    sun_data.energy = 3.0
    sun = bpy.data.objects.new("Sun", sun_data)
    sun.rotation_euler = (0.9, 0.2, 0.7)
    scene.collection.objects.link(sun)

    cam_data = bpy.data.cameras.new("Camera")
    cam = bpy.data.objects.new("Camera", cam_data)
    d = target_size * 1.4
    cam.location = (d * 0.8, -d, d * 0.55)
    direction = Vector((0, 0, 1.5)) - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(cam)
    scene.camera = cam


def export_fbx(coll, filename):
    """Export one collection as FBX for Roblox's 3D importer: Y up, Blender -Y -> Roblox -Z.

    axis_forward names the target axis Blender's +Y maps to, so "Z" (not "-Z") is what puts a
    vehicle's -Y front at Roblox -Z.
    """
    path = os.path.join(EXPORT_DIR, filename)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in coll.objects:
        if obj and obj.type == "MESH" and not obj.hide_render:
            obj.hide_viewport = False
            obj.select_set(True)
    bpy.ops.export_scene.fbx(
        filepath=path,
        use_selection=True,
        object_types={"EMPTY", "MESH"},
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_ALL",
        axis_forward="Z",
        axis_up="Y",
        mesh_smooth_type="FACE",
        use_mesh_modifiers=True,
        bake_space_transform=True,
    )
    return path
