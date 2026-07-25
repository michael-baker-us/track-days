# Tuning Journal

What we changed, what it did, what we kept. Numbers come from headless physics
tests so that "it feels better" is backed by something reproducible.

## Measurement harness

Feel work is driven by throwaway `_diag_*.gd` scripts run under
`Godot --headless --path . --script <file>`. They instantiate the real
`car.tscn` / `track_01.tscn`, drive them through `Input.action_press` so the
actual `car_controller.gd` is exercised, and print metrics. They are deleted
once the finding is committed — the commit message and this file are the record.

Metrics that proved useful:

| Metric | What it tells you |
|---|---|
| `two_plus_off` (frames with 2+ wheels off ground) | Body roll / rollover behaviour |
| Slip angle (angle between velocity and car forward) | Understeer vs oversteer, and whether a slide is happening |
| Yaw rate (`angular_velocity.y`) | How fast the car rotates; spin detection |
| Time to 100 km/h, top speed | Drivetrain and drag |
| `up_dot` (car up vs world up) | Rollover detection |

A caution that cost real time: **test on a big enough ground plane.** An early
"rollover at speed" was the car running off the edge of the 300 m plane and
free-falling. Diagnostics now enlarge the ground to 20 km before measuring.

## M1 — getting it drivable

**Car would not move.** `suspension_stiffness` default (5.0) is tuned for a
much lighter body than 1200 kg, so the chassis sank until its own collision box
rested on the ground; the wheels carried almost no load and had no traction
despite reporting contact. Raised stiffness to 60 and `suspension_max_force` to
12000. Kept.

**Acceleration and braking were sluggish.** `engine_force` was 800 N against
1200 kg — 0.67 m/s². Swept 800→10000; 8000 N gives 0–60 in 2.4 s, 0–100 in
3.4 s. Separately, the brake input never touched `VehicleBody3D.brake`, only
reversing engine force. Swept brake force 3000/6000/9000 — all stopped
identically (0.47 s from 100 km/h) because deceleration is traction-limited,
not brake-torque-limited, so 3000 is enough. Kept.

**Wheel hop and body roll in turns.** Center of mass had been manually lowered
to `(0, -0.3, 0)` for "rollover resistance"; in this raycast wheel model that
did the opposite — 267/300 frames with a wheel off the ground. The wheel contact
patches sit at y≈0, so a COM below them inverts the roll moment. Setting COM to
an explicit `(0, 0, 0)` fixed it (0/300).

> Note: deleting the override is **not** equivalent — that falls back to
> `center_of_mass_mode = AUTO`, which computes the centroid of the collision box
> (~y=0.42, above the wheel line) and rolls the car outright at speed.

**Two-wheeling on quick steering reversals.** A steady full-lock turn was
stable, but a slalom at 290 km/h had 2+ wheels off the ground on 122/600 frames
(peak roll rate 2.29 rad/s). `VehicleBody3D` has no roll stiffness of its own,
so a virtual anti-roll bar was added: restoring torque about the forward axis
from signed roll angle and roll rate. Even 8/2 fully eliminated lift; kept 15/4
for margin. Result: 0/600.

> Gotcha: `basis.x.dot(basis.y)` is identically 0 for an orthonormal basis, so
> the first roll-angle term was a silent no-op and only damping was doing
> anything. Signed roll is `basis.x.dot(Vector3.UP)`.

## M2 — grippy arcade

Target changed from *arcade/drifty* to *grippy arcade* (Forza Horizon-ish):
planted and predictable, slides only when provoked. Drifty stays reachable later
by lowering rear grip — the parameters are exported.

**Aerodynamic drag added.** There was none, so engine force fought only rolling
resistance and top speed ran to 332 km/h with acceleration climbing more or less
forever. Drag force scales with speed squared, so it sets top speed where engine
force balances it, and makes acceleration taper naturally.

| drag_coefficient | Top speed | 0–100 |
|---|---|---|
| 0.0 | 331.9 km/h | 3.09 s |
| 1.6 | 236.7 km/h | 3.17 s |

Kept 1.6 — barely touches acceleration, brings top speed somewhere controllable.

**Grip balance.** Rear `wheel_friction_slip` (11.5) set slightly *above* front
(10.5) so the car washes into mild understeer at the limit rather than snapping
into oversteer. Measured cornering slip angle at a governed 120 km/h:
**3.3° average, 5.1° peak** — planted, no spin.

**Handbrake provokes slides.** Rather than only braking, the handbrake now drops
rear `wheel_friction_slip` to 2.0 while held. Slip angle reaches ~70°, i.e. the
back end genuinely comes around on demand.

Re-ran the slalom afterwards to confirm the grip/drag rework did not regress
roll stability: **0/600 frames** with any wheel off the ground at 224 km/h.

### Current values

| Parameter | Value |
|---|---|
| `mass` | 1200 kg |
| `center_of_mass` | CUSTOM `(0, 0, 0)` |
| `suspension_stiffness` / `max_force` | 60 / 12000 |
| `damping_compression` / `relaxation` | 0.9 / 0.95 |
| `engine_force_value` | 8000 |
| `brake_force` / `reverse_force_value` | 3000 / 3000 |
| `drag_coefficient` | 1.6 |
| `friction_front` / `friction_rear` | 10.5 / 11.5 |
| `handbrake_rear_friction` / `handbrake_force` | 2.0 / 4000 |
| `antiroll_stiffness` / `antiroll_damping` | 15 / 4 |

### Still open

- Camera lag and FOV kick have not been retuned against the new grip model.
- Steering is still linear with a speed-based falloff; no countersteer assist.
- Suspension squat/roll under load is not yet visible enough to read as weight
  transfer.
- These values live as `@export`s on `car_controller.gd`, not yet as the
  `CarTuning` resource the plan calls for.
