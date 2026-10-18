"""Building variants for the v0.1 map, sized to the lots MapBuilder.luau builds on.

Each variant is exported to art/export/buildings/<Name>.fbx with its origin at the centre of
the footprint on the ground and its street face at -Y (Roblox -Z). Body is the tintable wall,
so MapBuilder can keep picking colors from Palette.Buildings / Palette.Industrial.

    blender --background --python art/blender/buildings.py
"""

import importlib
import math
import os
import sys

import bmesh
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import building  # noqa: E402

importlib.reload(building)
style = building.style
B = building.BUILDINGS
PAL = building.PAL
FLOOR = building.FLOOR
Building, faces = building.Building, building.faces


def offset_face(face, dx, dy):
    name, c, t, n, width = face
    return (name, c + Vector((dx, dy, 0)), t, n, width)


# --- downtown -------------------------------------------------------------------------------


def shop(name, w, d, h, wall, awning, seed):
    """lowBlock storefront: shop on the ground floor, flats above (MapBuilder: ~29 x 56, 18-32 tall)."""
    b = Building(name, wall, seed)
    b.box("Body", (w, d, h), (0, 0, h / 2))
    b.storefront(faces(w, d)[0], w - 6, height=11, awning=awning)
    b.band("Trim", w, d, 12.6, 13.4, 0.35)
    b.punched_windows(w, d, int((h - 15) // FLOOR) + 1, 14.5, spacing=7.0)
    b.parapet(w, d, h)
    b.roof_units(w, d, h, count=2)
    return b


def midrise(name, w, d, h, wall, awning, seed):
    """Apartments over a shop, with balconies on the street face."""
    b = Building(name, wall, seed)
    b.box("Body", (w, d, h), (0, 0, h / 2))
    front = faces(w, d)[0]
    b.storefront(front, w - 10, height=11, awning=awning)
    b.band("Trim", w, d, 12.6, 13.4, 0.35)
    floors = int((h - 15) // FLOOR) + 1
    b.punched_windows(w, d, floors, 14.5, spacing=8.0)
    for f in range(1, floors):
        z = 14.5 + f * FLOOR
        for u in building.bays(w, 8.0)[1::2]:
            b.face_box("Trim", front, u, z - 0.2, 6.0, 2.6, 0.4, 0)
            b.face_box("Frame", front, u, z + 0.8, 6.0, 0.2, 1.6, 2.4)
    b.parapet(w, d, h)
    b.roof_units(w, d, h, count=3)
    return b


def office(name, w, d, floors, wall, seed, crown=False):
    """Glass office: lobby, curtain-wall floors, flat roof; `crown` adds a set-back top and mast."""
    b = Building(name, wall, seed)
    h = 13 + floors * FLOOR + 1
    b.box("Body", (w, d, h), (0, 0, h / 2))
    b.storefront(faces(w, d)[0], w - 12, height=11)
    b.band("Trim", w, d, 12.4, 13.4, 0.4)
    b.curtain_wall(w, d, 13.4, floors)
    b.parapet(w, d, h)
    if crown:
        cw, cd, ch = w - 14, d - 14, 9
        b.box("Body", (cw, cd, ch), (0, 0, h + ch / 2))
        b.box("Windows", (cw + 0.1, cd + 0.1, 3), (0, 0, h + 4))
        b.parapet(cw, cd, h + ch)
        b.cylinder("Frame", 0.4, 18, (0, 0, h + ch), segments=6)
        top = h + ch
    else:
        b.roof_units(w, d, h, count=3)
        top = h
    print(f"  {name}: {w} x {d}, {h} tall ({top} with crown)")
    return b


def tower(name, wall, seed):
    """Downtown tower (MapBuilder's single-building blocks): podium plus a set-back glass shaft."""
    w, d, ph = 100, 100, 26
    b = Building(name, wall, seed)
    b.box("Body", (w, d, ph), (0, 0, ph / 2))
    b.storefront(faces(w, d)[0], 40, height=11)
    b.band("Trim", w, d, 12.4, 13.4, 0.4)
    b.curtain_wall(w, d, 13.4, 1)
    b.parapet(w, d, ph)
    sw, floors = 70, 10
    sh = ph + floors * FLOOR + 1
    b.box("Body", (sw, sw, sh - ph), (0, 0, (ph + sh) / 2))
    b.curtain_wall(sw, sw, ph, floors)
    b.parapet(sw, sw, sh)
    b.box("Body", (28, 28, 8), (0, 0, sh + 4))
    b.parapet(28, 28, sh + 8, cornice=False)
    b.cylinder("Frame", 0.5, 24, (6, 6, sh + 8), segments=6)
    b.roof_units(sw, sw, sh, count=4)
    print(f"  {name}: {w} x {d}, {sh + 8} tall")
    return b


def brick_block(name, w, d, h, wall, seed):
    """Old brick block between downtown and industrial (MapBuilder: ~110 x 110, 24-44 tall)."""
    b = Building(name, wall, seed)
    b.batch("Trim", color=building.SIDEWALK)
    b.box("Body", (w, d, h), (0, 0, h / 2))
    front = faces(w, d)[0]
    for u in (-w / 4, w / 4):
        b.storefront(offset_face(front, u, 0), 36, height=10, awning=building.CONTAINERS[2])
    b.punched_windows(w, d, 1, 3.0, win_w=5, win_h=6.5, spacing=9.0, skip=("front",))
    b.punched_windows(w, d, 2, 3.0 + FLOOR, win_w=5, win_h=6.5, spacing=9.0)
    b.band("Trim", w, d, 11.8, 12.6, 0.3)
    b.parapet(w, d, h, height=2.2)
    # rooftop water tower
    b.batch("WaterTower", color=PAL["Wood"], surface="Wood")
    tx, ty, base = w / 4, d / 4, h + 0.3
    for lx in (-4, 4):
        for ly in (-4, 4):
            b.cylinder("Frame", 0.4, 10, (tx + lx, ty + ly, base), segments=6)
    b.cylinder("WaterTower", 6.5, 10, (tx, ty, base + 10), segments=12)
    bm = b.batch("WaterTower")
    bmesh.ops.create_cone(bm, cap_ends=True, segments=12, radius1=7.2, radius2=0.3, depth=4,
                          matrix=Matrix.Translation((tx, ty, base + 22)))
    b.roof_units(w / 2, d / 2, h, count=2, offset=(-w / 4, -d / 4))
    return b


# --- landmarks ------------------------------------------------------------------------------


def police_station(name):
    """MapBuilder's PoliceStation (100 x 62 x 30). Its street faces Roblox +Z there, so rotate the
    model 180 degrees when placing it. Sign is a flat panel for the "POLICE" SurfaceGui."""
    w, d, h = 100, 62, 30
    b = Building(name, PAL["PoliceWhite"], seed=7)
    b.batch("Stripe", color=PAL["PoliceNavy"], surface="Accent")
    b.batch("Sign", color=PAL["PoliceNavy"], surface="Accent")
    b.box("Body", (w, d, h), (0, 0, h / 2))
    for face in faces(w, d):
        for f, z in enumerate((3.5, 3.5 + FLOOR)):
            for u in building.bays(face[4], 8.0):
                if face[0] == "front" and f == 0 and abs(u) < 10:
                    continue  # entrance
                b.face_quad("Windows", face, u - 2.2, u + 2.2, z, z + 6.5)
                b.face_box("Trim", face, u, z - 0.2, 5.4, 0.6, 0.4, 0)
    b.band("Stripe", w, d, 22.5, 25.0, 0.25)
    b.parapet(w, d, h)
    front = faces(w, d)[0]
    b.face_box("Sign", front, 0, h + 3.8, 30, 0.6, 5, 0)  # stands on the parapet
    # entrance: glass doors, canopy on two columns, steps
    b.face_quad("Windows", front, -6, 6, 1.2, 9.5, out=0.08)
    b.face_box("Frame", front, 0, 5.3, 12.8, 0.4, 0.4, 0)
    b.face_box("Frame", front, 0, 9.7, 12.8, 0.4, 0.4, 0)
    b.face_box("Frame", front, 0, 5.3, 0.4, 0.4, 8.6, 0)
    b.face_box("Trim", front, 0, 11.0, 20, 8, 0.8, 0)
    for u in (-9, 9):
        b.face_box("Trim", front, u, 5.3, 1.2, 1.2, 10.6, 6.5)
    for i in range(3):
        b.face_box("Trim", front, 0, 0.2 + i * 0.4, 16 - i * 2, 9.5 - i * 2, 0.4, 0)
    # flag pole on the front lawn
    b.cylinder("Frame", 0.3, 30, (-38, -d / 2 - 10, 0), segments=6)
    b.box("Stripe", (5, 0.15, 3), (-35.3, -d / 2 - 10, 27.6))
    b.roof_units(w, d, h, count=4)
    return b


def warehouse(name, w, d, h, wall, seed):
    """Industrial warehouse with roll doors on the front (MapBuilder: ~126 x 122, 28-34 tall)."""
    b = Building(name, wall, seed)
    b.batch("RollDoor", color=tuple(c * 0.8 for c in B["steel"]), surface="Metal")
    b.batch("Bollards", color=building.YELLOW, surface="Accent")
    b.box("Body", (w, d, h), (0, 0, h / 2))
    b.band("Windows", w, d, h - 6, h - 3, 0.05)
    front = faces(w, d)[0]
    doors = max(2, int(w // 30))
    door_us = [(-0.5 + (i + 0.5) / doors) * w for i in range(doors)]
    for face in faces(w, d):
        for k in range(int(face[4] // 4)):
            u = -face[4] / 2 + 2 + k * 4
            if face[0] == "front" and any(abs(u - du) < 9 for du in door_us):
                continue
            b.face_box("Body", face, u, h / 2, 0.6, 0.3, h, 0)
    for du in door_us:
        b.face_box("Frame", front, du, 9.4, 17.6, 0.35, 18.8, 0)
        b.face_box("RollDoor", front, du, 9, 16, 0.5, 18, 0)
        for s in range(11):
            b.face_box("RollDoor", front, du, 1.0 + s * 1.6, 16, 0.65, 0.2, 0)
        for side in (-1, 1):
            c = front[1] + front[2] * (du + side * 9.8) + front[3] * 1.2
            b.cylinder("Bollards", 0.5, 3.5, c, segments=8)
    # personnel door near the corner
    b.face_box("Frame", front, w / 2 - 6, 4, 4.4, 0.4, 8, 0)
    b.face_box("Trim", front, w / 2 - 6, 8.6, 6, 2.5, 0.4, 0)
    b.gable("Roof", w, d, h, rise=8, overhang=1.0)
    b.gable_wall("Body", w, d, h, 8)
    return b


def motel(name):
    """Sunset Motel (110 x 26 x 22): two floors of rooms off an open walkway."""
    w, d, h = 110, 26, 22
    b = Building(name, B["pink"], seed=3)
    b.batch("Roof", color=B["terracotta"])
    b.batch("MotelDoors", color=building.CONTAINERS[1], surface="Accent")
    b.box("Body", (w, d, h), (0, 0, h / 2))
    front = faces(w, d)[0]
    yf = -d / 2
    # upper walkway, its posts and railing
    b.box("Trim", (w, 8, 1), (0, yf - 4, 11))
    for x in range(-52, 53, 13):
        b.box("Trim", (0.9, 0.9, 10.5), (x, yf - 7.4, 5.25))
        b.box("Frame", (0.3, 0.3, 3.4), (x, yf - 7.8, 13.2))
    b.box("Frame", (w, 0.3, 0.3), (0, yf - 7.8, 14.8))
    b.box("Frame", (w, 0.2, 0.2), (0, yf - 7.8, 13.1))
    # rooms
    for i in range(8):
        u = -46 + i * 13
        for z in (0.5, 11.5):
            b.face_box("Trim", front, u, z + 4.2, 5.8, 0.25, 8.6, 0)
            b.face_box("MotelDoors", front, u, z + 4, 5, 0.4, 8, 0)
            b.face_quad("Windows", front, u + 4, u + 8.5, z + 2.5, z + 6.5)
            b.face_box("Trim", front, u + 6.25, z + 2.3, 5.1, 0.6, 0.4, 0)
            b.face_box("RoofUnits", front, u + 6.25, z + 1.2, 2.6, 1.2, 1.4, 0)
    for z in (4.5, 15.5):
        for u in building.bays(w, 13.0):
            b.face_quad("Windows", faces(w, d)[1], u - 1.2, u + 1.2, z, z + 2)
    # stairs down from the walkway at the east end
    for s in range(12):
        b.box("Trim", (1.0, 4, 0.9), (w / 2 + 1 + s * 1.0, yf - 5.5, 11 - (s + 1) * 0.95 + 0.45))
    b.box("Roof", (w + 4, 34, 1.4), (0, -4, h + 0.7))
    return b


def gas_station(name):
    """Gas station: canopy over two pumps at the origin, shop 50 studs behind (Roblox +Z)."""
    b = Building(name, PAL["PoliceWhite"], seed=5)
    red = building.CONTAINERS[0]
    b.batch("Accent", color=red, surface="Accent")
    b.batch("Shop", color=B["sand"], surface="Wall", bevel=0.15)
    b.batch("Lights", color=PAL["Headlight"], surface="Headlight")
    b.box("Body", (60, 36, 2.8), (0, 0, 18))
    b.band("Accent", 60, 36, 17.0, 18.8, 0.2)
    for x in (-15, 0, 15):
        for y in (-8, 8):
            b.box("Lights", (5, 2, 0.1), (x, y, 16.55))
    for x in (-20, 20):
        b.box("Trim", (2, 2, 16.6), (x, 0, 8.3))
        b.box("Trim", (4, 14, 0.6), (x, 3, 0.3))
        b.box("Accent", (3, 2, 6), (x, 6, 3.6))
        pump = ("pump", Vector((x, 5, 0)), Vector((1, 0, 0)), Vector((0, -1, 0)), 3)
        b.face_quad("Windows", pump, -1, 1, 4.2, 5.8, out=0.03)
    # shop
    sw, sd, sh, sy = 40, 24, 16, 50
    b.box("Shop", (sw, sd, sh), (0, sy, sh / 2))
    shop_front = offset_face(faces(sw, sd)[0], 0, sy)
    b.storefront(shop_front, 30, height=9)
    b.box("Accent", (sw + 0.6, sd + 0.6, 2), (0, sy, 12.5))
    b.parapet(sw, sd, sh, offset=(0, sy), body="Shop")
    b.roof_units(sw, sd, sh, count=1, offset=(0, sy))
    return b


def sawmill(name):
    """Old Sawmill shed (44 x 28, 18 tall): board-and-batten walls, open front, rusty gable roof."""
    w, d, eave, rise = 44, 28, 13, 6
    b = Building(name, PAL["Wood"], seed=9)
    b.batch("Roof", color=B["rust"])
    b.batch("Battens", color=building.TRUNK, surface="Wood")
    b.batch("Interior", color=building.INTERIOR, surface="Roof")
    b.box("Body", (w, d, eave), (0, 0, eave / 2))
    b.gable_wall("Body", w, d, eave, rise)
    front = faces(w, d)[0]
    for face in faces(w, d):
        for k in range(int(face[4] // 2.5)):
            u = -face[4] / 2 + 1.25 + k * 2.5
            if face[0] == "front" and abs(u) < 11:
                continue
            b.face_box("Battens", face, u, eave / 2, 0.4, 0.2, eave, 0)
    b.face_quad("Interior", front, -10, 10, 0, 10.5, out=0.03)
    b.face_box("Battens", front, 0, 11.0, 22, 0.5, 1.0, 0)
    for side in (-1, 1):
        b.face_box("Battens", front, side * 10.5, 5.25, 1.0, 0.5, 10.5, 0)
    for face in faces(w, d)[2:]:
        b.face_quad("Windows", face, -2, 2, 6, 9)
        b.face_box("Battens", face, 0, 5.8, 5, 0.5, 0.4, 0)
    b.gable("Roof", w, d, eave, rise=rise, overhang=1.5)
    return b


def rest_stop(name):
    """Highway rest stop (40 x 20 x 14): restrooms, a vending machine and a shady overhang."""
    w, d, h = 40, 20, 14
    b = Building(name, B["mint"], seed=11)
    b.batch("Doors", color=building.CONTAINERS[1], surface="Accent")
    b.batch("Accent", color=building.CONTAINERS[0], surface="Accent")
    b.box("Body", (w, d, h), (0, 0, h / 2))
    front = faces(w, d)[0]
    for u in (-13, 13):
        b.face_box("Trim", front, u, 4.2, 5, 0.25, 8.4, 0)
        b.face_box("Doors", front, u, 4, 4.2, 0.4, 8, 0)
        b.face_box("Trim", front, u, 9.4, 2, 0.3, 2, 0)
    b.face_quad("Windows", front, -6, 6, 3, 8.5)
    b.face_box("Frame", front, 0, 2.8, 12.8, 0.5, 0.4, 0)
    b.face_box("Frame", front, 0, 8.7, 12.8, 0.5, 0.4, 0)
    b.box("Trim", (w + 4, 9, 0.8), (0, -d / 2 - 4, 11.4))
    for x in (-19, -7, 7, 19):
        b.box("Frame", (0.6, 0.6, 11), (x, -d / 2 - 8, 5.5))
    b.box("Accent", (3, 2.4, 7), (17.5, -d / 2 - 1.4, 3.5))
    b.face_quad("Windows", ("vend", Vector((17.5, -d / 2 - 2.6, 0)), Vector((1, 0, 0)), Vector((0, -1, 0)), 3),
                -1, 1, 3.5, 6, out=0.02)
    b.parapet(w, d, h)
    b.roof_units(w, d, h, count=1)
    return b


rgb = style.rgb


# --- outskirts and landmarks ----------------------------------------------------------------


def _cone(b, key, base, height, r0, r1, segments=12):
    """Tapered cylinder (or cone, r1 = 0) standing on `base`, into batch `key`."""
    m = Matrix.Translation(Vector(base) + Vector((0, 0, height / 2)))
    bmesh.ops.create_cone(b.batch(key), cap_ends=True, segments=segments, radius1=r0, radius2=r1,
                          depth=height, matrix=m)


def _dome(b, key, center, radius):
    """Upper half of a faceted ball."""
    bm = b.batch(key)
    before = set(bm.verts)
    bmesh.ops.create_icosphere(bm, subdivisions=2, radius=radius, matrix=Matrix.Translation(Vector(center)))
    for v in bm.verts:
        if v not in before:
            v.co.z = max(v.co.z, center[2])


def _brace(b, key, face, u, z, length, angle, thick=0.6, out=0.0):
    """A board on a wall, turned `angle` radians in the wall's plane (barn door X braces)."""
    _, c, t, n, _ = face
    center = c + t * u + n * (out + thick / 2) + Vector((0, 0, z))
    turn = Matrix.Rotation(math.atan2(n.x, -n.y), 4, "Z")
    m = Matrix.Translation(center) @ turn @ Matrix.Rotation(angle, 4, "Y") @ Matrix.Diagonal((length, thick, thick, 1))
    bmesh.ops.create_cube(b.batch(key), size=1.0, matrix=m)


def cabin(name):
    """Pine Ridge cabin (18 x 14, about 16 tall): log walls, green shutters, porch and chimney."""
    w, d, eave, rise = 18, 14, 9, 5
    b = Building(name, PAL["Wood"], seed=21)
    b.batch("Logs", color=building.TRUNK, surface="Wood")
    b.batch("Roof", color=rgb(70, 92, 70))
    b.batch("Shutters", color=rgb(78, 140, 92), surface="Accent")
    b.batch("Stone", color=building.ROCK, surface="Concrete", bevel=0.1)
    b.box("Body", (w, d, eave), (0, 0, eave / 2))
    b.gable_wall("Body", w, d, eave, rise)
    # log courses: a thin band every 1.5 studs
    z = 1.2
    while z < eave:
        b.ring("Logs", w, d, z - 0.25, z + 0.25, 0.3, out=0.15)
        z += 1.5
    front = faces(w, d)[0]
    b.face_box("Frame", front, 0, 3.6, 4.2, 0.3, 7.4, 0)
    b.face_box("Shutters", front, 0, 3.4, 3.4, 0.45, 6.8, 0)
    for u in (-5.5, 5.5):
        b.face_quad("Windows", front, u - 1.6, u + 1.6, 3.4, 6.6, out=0.2)
        for side in (-1, 1):
            b.face_box("Shutters", front, u + side * 2.4, 5.0, 1.4, 0.4, 3.6, 0)
    for face in faces(w, d)[2:]:
        b.face_quad("Windows", face, -1.5, 1.5, 3.4, 6.4, out=0.2)
    # porch: deck, two posts and a small lean-to roof
    b.box("Logs", (w + 2, 5, 0.8), (0, -d / 2 - 2.5, 0.4))
    for x in (-w / 2, w / 2):
        b.box("Logs", (0.8, 0.8, 6.8), (x, -d / 2 - 4.6, 4.2))
    b.box("Roof", (w + 3, 6.4, 0.5), (0, -d / 2 - 2.8, 7.9), rot_x=math.radians(-12))
    b.gable("Roof", w, d, eave, rise=rise, overhang=1.2)
    # stone chimney up the right gable end
    b.box("Stone", (2.8, 2.8, eave + rise + 3), (w / 2 + 1.2, 2.5, (eave + rise + 3) / 2))
    return b


def barn(name):
    """Farmstead barn (36 wide, 50 deep, about 28 tall): red boards, white trim, X-braced doors
    and a hayloft in the gable that faces the street."""
    # built with the ridge along X (the kit's gables face +-X), doors on the -X gable, then
    # turned a quarter so that gable is the -Y street face
    w, d, eave, rise = 50, 36, 16, 11
    b = Building(name, rgb(178, 62, 50), seed=22)
    b.batch("Trim", color=rgb(244, 240, 230))
    b.batch("Roof", color=rgb(84, 84, 92))
    b.batch("Interior", color=building.INTERIOR, surface="Roof")
    b.box("Body", (w, d, eave), (0, 0, eave / 2))
    b.gable_wall("Body", w, d, eave, rise)
    for y in (-d / 2, d / 2):
        for x in (-w / 2, w / 2):
            b.box("Trim", (0.9, 0.9, eave), (x, y, eave / 2))
    b.band("Trim", w, d, eave - 0.6, eave, 0.25)
    gable = faces(w, d)[3]  # the -X wall
    for u in (-6, 6):
        b.face_box("Body", gable, u, 7, 11.6, 0.4, 14, 0.1)
        for z in (0.4, 7, 13.6):
            b.face_box("Trim", gable, u, z, 12, 0.3, 0.8, 0.5)
        for side in (-1, 1):
            b.face_box("Trim", gable, u + side * 5.6, 7, 0.8, 0.3, 14, 0.5)
            _brace(b, "Trim", gable, u, 7, 15.5, side * math.atan2(12.4, 10.8), out=0.5)
    b.face_quad("Interior", gable, -3.5, 3.5, eave + 0.5, eave + 7.5, out=0.03)
    for z in (eave + 0.3, eave + 7.7):
        b.face_box("Trim", gable, 0, z, 8.4, 0.4, 0.6, 0)
    for face in faces(w, d)[:2]:
        for u in (-15, -5, 5, 15):
            b.face_quad("Windows", face, u - 1.8, u + 1.8, 8, 12)
            b.face_box("Trim", face, u, 7.8, 4.8, 0.4, 0.5, 0)
    b.gable("Roof", w, d, eave, rise=rise, overhang=1.8)
    turn = Matrix.Rotation(math.pi / 2, 3, "Z")
    for batch in b.batches.values():
        bmesh.ops.rotate(batch["bm"], verts=batch["bm"].verts, cent=(0, 0, 0), matrix=turn)
    return b


def silo(name):
    """Grain silo (14 across, about 38 tall): ribbed steel with a domed cap."""
    b = Building(name, rgb(206, 208, 214), seed=23)
    b.batch("Roof", color=rgb(178, 62, 50))
    _cone(b, "Body", (0, 0, 0), 30, 7, 7, segments=16)
    for z in range(3, 30, 5):
        _cone(b, "Trim", (0, 0, z), 0.6, 7.3, 7.3, segments=16)
    _dome(b, "Roof", (0, 0, 30), 7.4)
    b.box("Frame", (0.6, 1.8, 30), (0, -7.4, 15))
    return b


def lighthouse(name):
    """Harbor lighthouse (about 56 tall): tapered white tower, red bands, gallery and lamp."""
    b = Building(name, rgb(244, 242, 236), seed=24)
    b.batch("Bands", color=rgb(206, 64, 58), surface="Accent")
    b.batch("Roof", color=rgb(206, 64, 58))
    b.batch("Lamp", color=rgb(255, 236, 190), surface="Headlight")
    h = 42
    levels = 6
    for i in range(levels):
        z0, z1 = h * i / levels, h * (i + 1) / levels
        r0, r1 = 7 - 2.4 * i / levels, 7 - 2.4 * (i + 1) / levels
        _cone(b, "Bands" if i % 2 == 1 else "Body", (0, 0, z0), z1 - z0, r0, r1, segments=14)
    _cone(b, "Frame", (0, 0, h), 1.0, 6.4, 6.4, segments=14)
    for k in range(14):
        a = k / 14 * math.tau
        b.box("Frame", (0.3, 0.3, 2.4), (math.cos(a) * 6.0, math.sin(a) * 6.0, h + 2.2))
    _cone(b, "Frame", (0, 0, h + 3.2), 0.4, 6.2, 6.2, segments=14)
    _cone(b, "Windows", (0, 0, h + 1), 5.5, 3.6, 3.6, segments=10)
    _cone(b, "Lamp", (0, 0, h + 2), 3.0, 1.6, 1.6, segments=8)
    _cone(b, "Roof", (0, 0, h + 6.5), 4.5, 4.4, 0, segments=10)
    b.box("Roof", (0.5, 0.5, 2.5), (0, 0, h + 12))
    # door at the foot
    b.face_box("Frame", ("front", Vector((0, -6.9, 0)), Vector((1, 0, 0)), Vector((0, -1, 0)), 4), 0, 3.5, 3.6, 0.5, 7, 0)
    return b


def water_tower(name):
    """Rail yard water tower (about 92 tall): four legs, cross braces, a tank and a pointed roof."""
    b = Building(name, rgb(156, 96, 64), seed=25)
    b.batch("Legs", color=PAL["Roof"], surface="Metal")
    legs = [(-9, -9), (9, -9), (9, 9), (-9, 9)]
    for x, y in legs:
        _cone(b, "Legs", (x, y, 0), 62, 1.0, 1.0, segments=6)
    for z in (20, 42):
        for i in range(4):
            (x0, y0), (x1, y1) = legs[i], legs[(i + 1) % 4]
            mid = Vector(((x0 + x1) / 2, (y0 + y1) / 2, z))
            length = math.hypot(x1 - x0, y1 - y0)
            angle = math.atan2(y1 - y0, x1 - x0)
            m = Matrix.Translation(mid) @ Matrix.Rotation(angle, 4, "Z") @ Matrix.Diagonal((length, 0.5, 0.5, 1))
            bmesh.ops.create_cube(b.batch("Legs"), size=1.0, matrix=m)
    _cone(b, "Body", (0, 0, 60), 22, 14, 14, segments=18)
    _cone(b, "Trim", (0, 0, 66), 0.8, 14.3, 14.3, segments=18)
    _cone(b, "Trim", (0, 0, 76), 0.8, 14.3, 14.3, segments=18)
    _cone(b, "Roof", (0, 0, 82), 9, 15, 0, segments=18)
    _cone(b, "Frame", (0, 0, 59), 1.0, 15.5, 15.5, segments=18)
    return b


def hangar(name):
    """Old Airstrip hangar (120 x 110, about 40 tall): an arched quonset roof and a wide door."""
    w, d, wall = 120, 110, 8
    b = Building(name, rgb(150, 160, 170), seed=26)
    b.batch("Roof", color=rgb(170, 176, 184), surface="Metal")
    b.batch("Door", color=rgb(96, 104, 116), surface="Metal")
    b.batch("Accent", color=building.CONTAINERS[0], surface="Accent")
    b.box("Body", (w, d, wall), (0, 0, wall / 2))
    # arched roof: a half-ring profile (across X) extruded along Y
    bm = b.batch("Roof")
    rise, segments, thick = 32, 12, 1.2
    outer, inner = [], []
    for i in range(segments + 1):
        a = math.pi * i / segments
        outer.append((math.cos(a) * (w / 2 + thick), wall + math.sin(a) * (rise + thick)))
        inner.append((math.cos(a) * (w / 2), wall + math.sin(a) * rise))
    profile = outer + list(reversed(inner))
    front = [bm.verts.new((x, -d / 2 - 1, z)) for x, z in profile]
    back = [bm.verts.new((x, d / 2 + 1, z)) for x, z in profile]
    n = len(profile)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[i], front[j], back[j], back[i]))
    bm.faces.new(front)
    bm.faces.new(list(reversed(back)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[-(n + 2):])
    # end walls filling the arch
    for y, flip in ((-d / 2, False), (d / 2, True)):
        wall_bm = b.batch("Body")
        pts = [wall_bm.verts.new((x, y, z)) for x, z in inner]
        wall_bm.faces.new(list(reversed(pts)) if not flip else pts)
    front_face = faces(w, d)[0]
    b.face_box("Door", front_face, 0, 14, 76, 0.6, 28, 0)
    for u in range(-36, 37, 12):
        b.face_box("Frame", front_face, u, 14, 0.6, 0.4, 28, 0.6)
    b.face_box("Accent", front_face, 0, 32, 24, 0.5, 5, 0)
    for face in faces(w, d)[2:]:
        for u in range(-45, 46, 15):
            b.face_quad("Windows", face, u - 3, u + 3, 3, 6)
    return b


# --- build everything ---------------------------------------------------------------------

CATALOG = [
    lambda: shop("Shop", 29, 56, 24, B["terracotta"], building.CONTAINERS[3], 1),
    lambda: shop("ShopTall", 29, 56, 34, B["mint"], building.CONTAINERS[1], 2),
    lambda: midrise("Midrise", 50, 50, 50, B["cream"], building.CONTAINERS[4], 3),
    lambda: office("Office", 50, 50, 5, B["slate"], 4),
    lambda: office("OfficeTall", 50, 50, 8, B["sand"], 5, crown=True),
    lambda: tower("Tower", B["concrete"], 6),
    lambda: brick_block("BrickBlock", 104, 104, 36, B["brick"], 7),
    lambda: police_station("PoliceStation"),
    lambda: warehouse("WarehouseLarge", 126, 122, 34, B["steel"], 8),
    lambda: warehouse("WarehouseSmall", 126, 122, 28, B["teal"], 9),
    lambda: motel("Motel"),
    lambda: gas_station("GasStation"),
    lambda: sawmill("Sawmill"),
    lambda: rest_stop("RestStop"),
    lambda: cabin("Cabin"),
    lambda: barn("Barn"),
    lambda: silo("Silo"),
    lambda: lighthouse("Lighthouse"),
    lambda: water_tower("WaterTower"),
    lambda: hangar("Hangar"),
]


def build_all(export=True):
    style.reset_scene()
    roots = []
    for make in CATALOG:
        b = make()
        roots.append(b.finish(export=export))
    # lay them out in rows for review; exports above were made at the origin
    x = 0.0
    for root in roots:
        root.location = (x, 0, 0)
        x += 180
    return roots


if __name__ == "__main__":
    import bpy

    build_all()
    blend = os.path.join(style.ART_DIR, "buildings.blend")
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    print("saved", blend)
