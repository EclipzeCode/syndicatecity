"""Police: the sedan body in PoliceWhite with the v0.1 police parts from CarFactory.luau.

Sizes are Config.Vehicles.Types.Police (the Sedan, 0.5 studs longer). SirenRed and SirenBlue
keep their CarFactory names because EffectsController flashes them by name.
"""

import importlib
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sedan  # noqa: E402

importlib.reload(sedan)
style = sedan.style


def build():
    d = sedan.build("Police", length=15.5, paint=style.PALETTE["PoliceWhite"])
    part, hx, hy, hz = d.part, d.hx, d.hy, d.hz

    # navy band across the doors, stopping short of the wheel arches
    stripe_len = 2 * (d.wheel_y - d.wheel_radius - 0.5)
    stripe = part("DoorStripe", style.box((0.06, stripe_len, 0.9), (hx + 0.01, 0, 0.05)), "PoliceNavy")
    other = part("DoorStripeR", style.box((0.06, stripe_len, 0.9), (-hx - 0.01, 0, 0.05)), "PoliceNavy")
    join(stripe, [other])

    # light bar on the flat of the roof
    base = part("LightBarBase", style.box((4.6, 1.2, 0.4), (0, d.cabin_offset, d.cabin_top + 0.2)), "Trim")
    style.bevel(base, width=0.08)
    # red on the car's left (+X here, Roblox -X), as in CarFactory
    for sx, name in ((1, "SirenRed"), (-1, "SirenBlue")):
        siren = part(name, style.box((2.0, 1.0, 0.5), (sx * 1.1, d.cabin_offset, d.cabin_top + 0.65)), name)
        style.bevel(siren, width=0.12, segments=2)

    # push bar bolted to the front bumper
    y = -hy - 0.85
    bar = part("PushBar", style.box((0.3, 0.3, 1.7), (1.6, y, -0.15)), "Trim")
    pieces = [
        part("PushBarR", style.box((0.3, 0.3, 1.7), (-1.6, y, -0.15)), "Trim"),
        part("PushBarTop", style.box((3.8, 0.3, 0.25), (0, y, 0.55)), "Trim"),
        part("PushBarLow", style.box((3.8, 0.3, 0.25), (0, y, -0.55)), "Trim"),
    ]
    join(bar, pieces)
    return d


def join(target, others):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in [target, *others]:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.join()


if __name__ == "__main__":
    sedan.finish(build(), "Police")
