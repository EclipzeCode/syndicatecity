"""Sedan: low-poly replacement for the v0.1 graybox Sedan built by CarFactory.luau.

Sizes are the v0.1 Sedan from src/shared/Config.luau, and part placement follows CarFactory, so
the meshes drop onto the existing Chassis without moving seats, wheels or the cargo crate.
Origin = Chassis centre; front = -Y (Roblox -Z); left = +X (Roblox -X).

build() is shared with other sedan-bodied cars (police.py).
"""

import importlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import car  # noqa: E402

importlib.reload(car)
style = car.style


def build(name="Sedan", length=15.0, paint=style.CAR_COLORS[0]):
    """Sedan body for Config.Vehicles.Types sizes (Sedan and Police share all but length)."""
    d = car.dims(width=7.4, height=2.4, length=length, cabin_height=3.0, ride_height=1.6,
                 wheel_radius=1.5, cabin_length=0.5, cabin_offset=0.04)
    car.start(d, name)
    hx, hy, hz = d.hx, d.hy, d.hz

    car.hull(d, [
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
    ], paint)

    car.greenhouse(d, [
        (d.cabin_front, hz - 0.05),
        (d.cabin_rear, hz - 0.05),
        (d.cabin_offset + 2.2, d.cabin_top),
        (d.cabin_offset - 1.6, d.cabin_top),
    ], paint)

    glass = car.Glass(d)
    z_lo, z_hi = hz + 0.45, d.cabin_top - 0.35
    glass.end_panel(True, z_lo, z_hi, 0.35)
    glass.end_panel(False, z_lo + 0.1, z_hi, 0.35)
    b_pillar = (d.cabin_offset - 0.3, d.cabin_offset + 0.25)
    glass.side_window([
        (glass.front_y(z_lo) + 0.4, z_lo),
        (b_pillar[0], z_lo),
        (b_pillar[0], z_hi),
        (glass.front_y(z_hi) + 0.4, z_hi),
    ])
    glass.side_window([
        (b_pillar[1], z_lo),
        (glass.rear_y(z_lo) - 0.4, z_lo),
        (glass.rear_y(z_hi) - 0.4, z_hi),
        (b_pillar[1], z_hi),
    ])
    glass.build()

    car.trim_and_lights(d)
    car.wheels(d)
    return d


if __name__ == "__main__":
    # Config.Vehicles.Types.Sedan
    car.finish(build("Sedan", length=15.0), "Sedan")
