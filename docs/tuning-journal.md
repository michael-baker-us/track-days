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

Took 1.6 at this point — superseded in M2b below, where top speed came down
further.

**Grip balance.** Rear `wheel_friction_slip` set slightly *above* front so the
car washes into mild understeer at the limit rather than snapping into
oversteer. The *ratio* survived; the absolute values (10.5/11.5) did not — see
M2b, where they turn out to be the cause of the sudden braking.

**Handbrake provokes slides.** Rather than only braking, the handbrake drops
rear `wheel_friction_slip` while held, so the back end comes around on demand.

Re-ran the slalom afterwards to confirm the grip/drag rework did not regress
roll stability: **0/600 frames** with any wheel off the ground at 224 km/h.

### M2b — top speed and braking

Feedback: top speed too high, braking too sudden. Braking measured at **20 g**
(100 km/h to a stop in 0.14 s / 2.0 m), which is why it felt like hitting a wall.

**Two saturation ceilings were hiding the real problem.**

`wheel_friction_slip` at Godot's default 10.5 is far past anything physical.
Everything was traction-limited at absurd grip: ~20 g braking and ~9 g
cornering. Sweeping grip against braking from 100 km/h:

| friction f/r | Stop time | Distance | Decel |
|---|---|---|---|
| 10.5 / 11.5 | 0.14 s | 2.0 m | 20.0 g |
| 2.0 / 2.4 | 0.62 s | 8.9 m | 4.6 g |
| 1.4 / 1.7 | 0.86 s | 12.3 m | 3.3 g |
| 0.7 / 0.85 | 1.60 s | 22.5 m | 1.8 g |

But grip drives cornering too, and dropping it far enough to fix braking made
the car push wide badly — yaw rate at 100 km/h fell from 4.33 rad/s to
0.30 rad/s. Grip alone could not fix braking without ruining cornering.

`brake_force` **saturates around 150**. Everything from 300 to 3000 produced
byte-identical results because the wheels simply lock and grip takes over. The
shipped value was 3000, i.e. 20× past the point where the control does anything.
Once below saturation it behaves sensibly:

| brake_force | Stop time | Distance | Decel |
|---|---|---|---|
| 0 | never stopped | — | — |
| 20 | 2.74 s | 37.8 m | 1.03 g |
| 32 | 1.83 s | 25.8 m | 1.55 g |
| 60 | 1.04 s | 14.9 m | 2.72 g |
| 150+ | 0.86 s | 12.3 m | 3.30 g (saturated) |

So the fix is both: grip at 1.4/1.7 for realistic cornering (~1.3 g lateral),
and brake force at 32 — below saturation, so braking is brake-limited and
progressive rather than an instant traction-limited stop.

**Top speed** lowered via drag, which is the honest lever since it also shapes
the acceleration curve: 1.6 → 249 km/h, 3.0 → 200, 4.0 → 180, 5.0 → 165.
Kept 5.0.

**Handbrake rescaled.** `handbrake_rear_friction` was 2.0 — above the new rear
grip of 1.7, so it would have *increased* rear grip. Now 0.5. `handbrake_force`
was likewise saturated at 4000; now 40.

Final: top speed 165 km/h, 0–100 in 3.54 s, 100→0 in 1.75 s / 24.1 m (1.62 g),
cornering 0.46 rad/s yaw at 100 km/h with no spin, and the slalom still shows
0/600 frames with any wheel off the ground at 161 km/h.

### M2c — CarTuning resource, and the camera

**Tuning moved into a resource.** Every feel parameter now lives on
`CarTuning` (`resources/tuning/car_tuning.gd`) instead of being scattered as
`@export`s on the controller and hand-set values on the wheel nodes in
`car.tscn`. Suspension is included, so the wheels are configured from the
resource in `_ready()` and the scene holds only geometry — wheel positions,
radius, and which wheels steer or drive.

Godot only serialises properties that differ from a script's defaults, so the
defaults *are* the grippy baseline, `grippy.tres` is intentionally empty, and
every other preset records just its deltas. `drifty.tres` is four lines, and
those four lines are exactly what makes it drifty. Verified the refactor was
behaviour-preserving by re-running the whole battery: t100 3.54 s, 100→0 in
1.75 s / 24.1 m / 1.62 g, top speed 164.9 km/h, slalom 0/600 — all identical.

> Gotcha while verifying: node `_ready()` callbacks have not been flushed while
> `SceneTree._initialize()` is still running, so a diagnostic that reads wheel
> properties there sees Godot's defaults and looks like the tuning never
> applied. Check on the first physics frame instead.

**Screenshots.** Added a harness that renders the real main scene and saves a
PNG (`RenderingServer.force_draw()` then `root.get_texture().get_image()`, run
non-headless). Camera work had been guesswork up to this point; this makes it
checkable.

**The camera was much further away than it claimed.** The first screenshot
showed the car as a speck filling ~3% of screen width. Pulling the follow
offset from 7 m to 4.2 m barely changed anything, which was the tell:
exponential smoothing trails a moving target by roughly `velocity / lag`, so at
29 m/s with lag 4 the camera sat ~7 m behind its own target. Real distance was
~11 m and the offset had stopped meaning anything.

Fixed by feeding the car's velocity forward into the target position, which
cancels the steady-state trailing error while leaving the smoothing to absorb
acceleration and bumps. The offset is now honest at any speed, and the car
fills ~14% of frame width — a third-person racer view rather than a camera
drone. FOV reference also dropped 180 → 165 km/h so the kick reaches full value
at the actual top speed.

### Current values

| Parameter | Value |
|---|---|
| `mass` | 1200 kg |
| `center_of_mass` | CUSTOM `(0, 0, 0)` |
| `suspension_stiffness` / `max_force` | 60 / 12000 |
| `damping_compression` / `relaxation` | 0.9 / 0.95 |
| `engine_force_value` | 8000 |
| `brake_force` / `reverse_force_value` | 32 / 3000 |
| `drag_coefficient` | 5.0 |
| `friction_front` / `friction_rear` | 1.4 / 1.7 |
| `handbrake_rear_friction` / `handbrake_force` | 0.5 / 40 |
| `antiroll_stiffness` / `antiroll_damping` | 15 / 4 |
| `camera_follow_offset` / `camera_look_offset` | (0, 1.4, -4.2) / (0, 0.45, 0) |
| `camera_position_lag` / `camera_rotation_lag` | 4 / 5 |
| `camera_base_fov` / `max_fov_kick` / `fov_reference_kmh` | 70 / 12 / 165 |

All of the above live in `resources/tuning/car_tuning.gd` as the grippy
baseline; `car.tscn` references `grippy.tres`.

## M3 — a real track

Circuit built by `_build_track.gd` from a layout spec rather than placed by
hand, so the layout can be edited and rebuilt. Kenney road tiles sit on a
1-unit grid with off-centre origins; each piece is normalised so its cell min
corner is at the origin, then placed by matching its entry connection point and
edge normal to a walker's current position and heading. Rotations are found by
searching the four yaw angles and both travel directions for one that matches.

Piece geometry was measured rather than eyeballed — a diagnostic reads mesh
vertices and reports which tile edges the road ribbon actually reaches and where
along each edge it sits. All corners turn out to be quarter arcs centred at
(0.5, 0.5) in cell coordinates, connecting the East and South edges.

Scale is 10 m per tile unit, giving a 10 m road. Corner centreline radii are
5 m (`roadCornerSmall`), 15 m (`Large`), 25 m (`Larger`). Current circuit is
913 m with a closure gap of exactly zero and net −4 turns.

**Collision does not come from the road meshes.** Every tile is flat at y=0, so
the ground plane already is a perfectly smooth driving surface with no seams for
the raycast wheels to catch on. Road tiles are visual only, sitting 2 cm proud
of the grass; walls constrain the car.

Three things worth keeping:

> `roadCornerSmall` has a 5 m centreline radius — its inner road edge is a
> single point, and it is smaller than the wall offset, so the inner wall
> polyline inverts and self-intersects. Wall offset must stay below the smallest
> corner radius in use; the tight corner is currently unused.

> **`main.tscn` carried a stale instance override** pinning `center_of_mass` to
> `(0, -0.3, 0)`. Instance overrides beat the source scene, so the corrected
> `(0, 0, 0)` in `car.tscn` never applied in the actual game — only in
> diagnostics, which load `car.tscn` directly. That is very likely why wheel
> lift persisted after the "fix" and only went away once the anti-roll bar
> masked it. `main.tscn` is now generated programmatically so it carries no
> overrides, and diagnostics that care about real behaviour load `main.tscn`.

> Wall collision boxes were given both an explicit `size` of `seg_len` and a
> transform already scaled by `seg_len`, making each one `seg_len²` long and
> burying the circuit in invisible geometry. A screenshot showed an empty road;
> only a drive test that measured distance travelled revealed the car was
> stopping. Visual checks and behavioural checks catch different bugs.

### M3b — making it drivable

Feedback: hard to stay on track, and gas/brake/turning did not flow.

**Corner speeds were the problem, not the driver.** At grip 1.4/1.7 the car
managed 1.29 g lateral, so the circuit's corners could only be held at 50 km/h
(r=15 m) and 64 km/h (r=25 m) — against a 165 km/h top speed. That gap is what
made it feel like fighting the car.

The fix was cheap because of how braking was set up in M2b: **grip only limits
cornering here, not braking**, since `brake_force` sits below its saturation
point and braking is brake-limited. Measured stopping distance is byte-identical
(1.75 s / 24.1 m / 1.62 g) at grip 1.4, 2.5 and 4.0. So grip could be raised
purely for turning, with no cost to braking progressiveness.

| grip f/r | Lateral | Max on r=15 m | Max on r=25 m |
|---|---|---|---|
| 1.4 / 1.7 | 1.29 g | 50 km/h | 64 km/h |
| 2.5 / 2.9 | 2.29 g | 66 km/h | 85 km/h |
| 4.0 / 4.5 | 3.65 g | 83 km/h | 108 km/h |
| 6.0 / 6.6 | 5.43 g | 102 km/h | 131 km/h |

Took 4.0/4.5. `handbrake_rear_friction` rescaled 0.5 → 1.2 to keep roughly the
same ratio below rear grip. Slalom re-checked at the new grip: still 0/600
frames with any wheel off the ground at 162 km/h.

**Barriers.** Track edges are now Kenney `railDouble` guardrails (2.8 m) placed
along the same offset polyline the collision boxes follow, so what you see is
where you actually get stopped. Wall offset tightened from 8 m to 7 m — 2 m of
runoff past the 5 m road edge — so going off nudges you back rather than letting
you wander into open grass.

> Two dead ends worth recording. `barrierWall` at 1.3 m was too low to read as a
> boundary from the chase camera — from above it looked like a road marking.
> More importantly, the barriers were first built as a **MultiMesh, whose
> instance transforms live in its `buffer` property, and that is not serialised
> by `ResourceSaver` into a packed scene.** The saved scene kept
> `instance_count = 192` but every transform collapsed to identity, stacking all
> the barriers invisibly at the origin. Plain `MeshInstance3D` nodes serialise
> correctly. If a generator's output must be saved as a scene, check the saved
> `.tscn`, not just the in-memory result.

### Still open

- Steering is still linear with a speed-based falloff; no countersteer assist.
- Grass has the same friction as tarmac — going off-track costs nothing but
  time, since collision is one flat plane under both.
- Suspension squat/roll under load is not yet visible enough to read as weight
  transfer.
- Rear wheels sit at skid 0.66 under full throttle at 100 km/h — the car is
  power-sliding slightly in a straight line. Not obviously wrong for an arcade
  racer, but it has not been deliberately tuned.
- The grid shader aliases badly toward the horizon; wants a distance fade.
- No lap timing or checkpoints yet (M4).
- The circuit has no chicane: `roadCurved` always offsets the same way relative
  to travel, so mirroring it needs a negative scale rather than a Y rotation.
- Walls approximate `roadCurved` as a straight line between its endpoints.
- `track_01.tscn` (bare flat plane) is kept deliberately — physics measurements
  want a surface with no walls to run into.
