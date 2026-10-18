"""Van: low-poly replacement for the v0.1 graybox Van built by CarFactory.luau.

Sizes are Config.Vehicles.Types.Van. Like CarFactory, the cabin runs 78% of the length set back
10%, with glass only on the front 4 studs of the sides. Split rear-door windows let cops see the
cargo crate CarFactory parks behind them.
Origin = Chassis centre; front = -Y (Roblox -Z); left = +X (Roblox -X).
"""

import importlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import car  # noqa: E402

importlib.reload(car)
style = car.style


def build(name="Van", paint=style.CAR_COLORS[1]):
    d = car.dims(width=8.4, height=3.0, length=17.0, cabin_height=4.4, ride_height=1.8,
                 wheel_radius=1.7, cabin_length=0.78, cabin_offset=0.1)
    car.start(d, name)
    hy, hz = d.hy, d.hz
    back = hy - 0.05  # the box runs flush to the rear

    car.hull(d, [
        (-hy + 0.3, -hz),
        (hy - 0.3, -hz),
        (hy, -hz + 0.3),
        (hy, hz + 0.05),
        (d.cabin_front - 0.2, hz + 0.05),
        (-hy + 0.4, hz - 0.1),
        (-hy - 0.05, hz - 0.8),
        (-hy, -hz + 0.3),
    ], paint)

    car.greenhouse(d, [
        (d.cabin_front, hz - 0.05),
        (back, hz - 0.05),
        (back, d.cabin_top),
        (d.cabin_front + 1.5, d.cabin_top),
    ], paint, top_inset=0.6)

    glass = car.Glass(d)
    glass.end_panel(True, hz + 0.4, d.cabin_top - 0.4, 0.35)
    # cab door windows: CarFactory's 4-stud band behind the windshield
    z_lo, z_hi = hz + 1.3, d.cabin_top - 0.45
    cab_back = d.cabin_front + 4.0
    glass.side_window([
        (glass.front_y(z_lo) + 0.4, z_lo),
        (cab_back, z_lo),
        (cab_back, z_hi),
        (glass.front_y(z_hi) + 0.4, z_hi),
    ])
    glass.end_panel(False, hz + 1.8, d.cabin_top - 0.5, 0.5, x_lo=0.2)
    glass.build()

    # seam between the rear doors, from bumper to roof
    seam_lo, seam_hi = -hz + 1.05, d.cabin_top - 0.3
    d.part("RearDoorSeam",
           style.box((0.08, 0.12, seam_hi - seam_lo), (0, hy - 0.01, (seam_lo + seam_hi) / 2)), "Trim")

    car.trim_and_lights(d)
    car.wheels(d)
    return d


if __name__ == "__main__":
    car.finish(build(), "Van")
