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

**Barriers.** Track edges were given Kenney `railDouble` guardrails (2.8 m)
placed along the same offset polyline the collision boxes follow. **Since
disabled** — see M3d.

> Two dead ends worth recording. `barrierWall` at 1.3 m was too low to read as a
> boundary from the chase camera — from above it looked like a road marking.
> More importantly, the barriers were first built as a **MultiMesh, whose
> instance transforms live in its `buffer` property, and that is not serialised
> by `ResourceSaver` into a packed scene.** The saved scene kept
> `instance_count = 192` but every transform collapsed to identity, stacking all
> the barriers invisibly at the origin. Plain `MeshInstance3D` nodes serialise
> correctly. If a generator's output must be saved as a scene, check the saved
> `.tscn`, not just the in-memory result.

### M3c — wider track

Kenney has no wider road tiles, so road width, corner radii and lap length all
come from one number: metres per tile unit, raised 10 -> 14. The car does not
scale, so this widens the track relative to the car and opens the corners at the
same time.

| | Before | After |
|---|---|---|
| Road width | 10 m | 14 m |
| Corner radii | 15 / 25 m | 21 / 35 m |
| Corner speeds at 3.65 g | 83 / 108 km/h | 98 / 127 km/h |
| Lap length | 913 m | 1278 m |

Barrier scale was decoupled from track scale in the process — guardrails were
sized off the track scale, so widening would have grown them to 3.9 m alongside
an unchanged 2.5 m car. They now have their own fixed scale.

### M3d — guardrails switched off

They cut across the racing line at corners. The cause is in `_offset_line`:
each vertex of the offset polyline is offset by the **preceding segment's
normal only**, with no mitring. At every direction change the offset therefore
lags a segment and kinks inward, which on the inside of a corner puts rail —
and its collision — across drivable road.

Offsetting a polyline properly needs the averaged normal of the two adjacent
segments at each vertex, plus arcs on outer corners where the offset opens up.
Not worth building now, so `BARRIERS_ENABLED` defaults to `false` and the code
is left intact behind the flag.

Nothing is lost by having them off: collision is a single flat ground plane, so
the car simply drives on grass off-track and can rejoin. What is lost is any
penalty for leaving the circuit, which lap timing (M4) will need to care about.

## M4 — checkpoints and lap timing

16 gates generated along the centreline, index 0 on the start line, spaced 80 m
apart on the 1278 m lap. They are `Area3D` triggers that never block the car.

Ordering is the whole point. Collision is a single flat ground plane and the
guardrails are off, so nothing physically stops a corner being cut — a lap only
counts if every gate is taken in sequence, and an out-of-order gate is ignored
(the driver has to go back for it). Gates are 4 tile units wide, deliberately
wider than the road, so running wide onto the grass still counts: the point is
to prove the lap was driven, not to punish a bad line.

The first crossing of the start line begins timing, so lap 1 is preceded by an
out lap. Best lap persists to `user://records.cfg`.

> Lap time accumulates in `_physics_process`, not `_process`. The physics delta
> is fixed, so times track the simulation rather than the render framerate —
> which also means headless runs, which are not framerate-locked, produce the
> same times as the game.

Verified in two parts, because they fail differently:

- **Rules**, by driving the tracker directly: out lap ignored, timing starts on
  the line, gates enforced in order, a deliberate cut (1 → 2 → 9) rejected with
  `_next_required` held at 3, an early line crossing ignored, second lap still
  recorded correctly, best lap stored.
- **Physical triggering**, by driving down the opening straight: gates 1, 2 and
  3 fired in order at 77 m, 157 m and 249 m, matching the 80 m spacing. The
  rules test emits signals directly and so never exercises `Area3D` detection,
  box size or gate orientation.

An autonomous pure-pursuit driver was written to attempt a full timed lap but
did not complete one in reasonable time and was abandoned; it is worth revisiting
alongside AI opponents rather than as a test harness.

## M5 — verticality

Two elevated sections: ramp up, a short plateau, ramp back down. Peak 3.5 m,
gradient ~12%, and the car goes properly light over each crest at ~100 km/h.

Height is carried the same way headings are. Each connection gets a `conn_y`, a
piece's rise is `conn_y[exit] - conn_y[entry]`, and the walker carries a running
height. That means one ramp mesh climbs *or* descends depending only on which
end is entered — the layout just says which it wanted (`rise_sign`), and the
placement search finds the matching rotation. Each climb replaces exactly 6
units of straight (ramp 2 + bridge 2 + ramp 2), so the loop still closes with no
re-solving.

Kenney's ramp is 0.5 units over 2, a 25% grade — very steep for a circuit, and
with no barriers a fall off an elevated section hurts. `VERT` scales height on
top of `SCALE`, at 0.5, giving ~12% and a 3.5 m plateau. It is the one knob for
how dramatic the hills are.

**The flat ground plane could no longer be the driving surface.** It was only
ever viable because every tile sat at y=0. The road surface is now a generated
ribbon of quads along the centreline, used as a `ConcavePolygonShape3D`: still
seamless for the raycast wheels, but it follows elevation. The ground plane
underneath is just grass now.

> The bug that mattered: `ConcavePolygonShape3D` is **one-sided by default**, so
> whether the ribbon collides at all depends on triangle winding — and getting
> it wrong means the car silently falls through every elevated section. Setting
> `backface_collision = true` makes it collide from both faces. This was found
> by raycasting down at each checkpoint and comparing the surface height to the
> expected road height: the two elevated gates reported a surface at y=0 while
> the saved collision data clearly contained vertices up to y=3.5.

That probe is the useful technique here. Driving tests kept failing for
unrelated reasons — a car with no steering leaves the circuit long before it
reaches a hill — whereas casting a ray at each gate tests the surface itself,
independently of anyone's ability to drive to it.

### Tried and rejected: downforce and airborne stabilisation

The car getting away from you over the hills was investigated and a fix was
built, measured, and then **reverted because it did not feel right**. Recorded
here so it is not re-derived from scratch.

What the measurements said. Launched at Highland's first climb at 150 km/h, a
crest throws the car up at road speed times the grade — 5.5 m/s over Kenney's
12.5% ramp, which matches the arithmetic — and `VehicleBody3D` offers no help in
the air, so it lands crooked. Adding downforce plus a levelling torque while
airborne took airtime from 1.48 s to 0.71 s and sideslip on landing from 18.6 deg
to 1.1 deg, for about 4% more cornering grip and 1 km/h of top speed.

So the numbers were good and the feel was not, which is the whole reason this
journal exists: feel is the deliverable and no measurement substitutes for
driving it. Worth knowing before trying again that the numbers alone will look
convincing.

Two things were also built and thrown out *before* the revert, on measurement
alone, and those are worth not repeating:

- A yaw stability assist meant to engage only past 14 deg of sideslip. Ordinary
  cornering already exceeds that, so it engaged constantly and doubled apparent
  grip, 2.54 g to 5.40 g.
- Landing yaw damping for a moment after touchdown. Measured identical to two
  decimal places in every test.

Rounding the ramp gradients in the collision ribbon was also tried and reverted:
airtime bottomed out at six smoothing passes and then got *worse*, while the
driving surface drifted more than 20 cm from the painted road — further than the
suspension travel. Fixing the track was the wrong answer to a car problem.

> Two measurement traps, both of which cost time. `accelerate` outranks `brake`
> in the controller, so a braking test that forgets to release the throttle
> reports a 290 m stopping distance and looks like a physics bug. And a per-frame
> `(v - v_prev) / dt` *peak* reads several g of suspension jitter — lateral grip
> has to be a mean over a settled window, or every configuration appears to have
> 7 g of grip.

### Still open

- The hills are still the hardest part of the circuit to drive: 0.84 s airborne
  over a crest at 150 km/h in a straight line, and the car keeps whatever
  rotation it took off with. Open deliberately, not overlooked — the fix above
  worked on paper and was rejected on feel, so the next attempt wants a different
  approach rather than a retune of that one.
- Steering is still linear with a speed-based falloff; no countersteer assist.
- Grass has the same friction as tarmac — going off-track costs nothing but
  time, since collision is one flat plane under both. With guardrails off there
  is nothing at all keeping the car on the circuit.
- Suspension squat/roll under load is not yet visible enough to read as weight
  transfer.
- Rear wheels sit at skid 0.66 under full throttle at 100 km/h — the car is
  power-sliding slightly in a straight line. Not obviously wrong for an arcade
  racer, but it has not been deliberately tuned.
- The grid shader aliases badly toward the horizon; wants a distance fade.
- The circuit has no chicane: `roadCurved` always offsets the same way relative
  to travel, so mirroring it needs a negative scale rather than a Y rotation.
- Walls approximate `roadCurved` as a straight line between its endpoints.
- `track_01.tscn` (bare flat plane) is kept deliberately — physics measurements
  want a surface with no walls to run into.
