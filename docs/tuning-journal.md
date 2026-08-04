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

## M6 — banked corners and eased slopes

**The ramps were wedges.** `roadRampLong`, the piece every hill had been built
from, is eight vertices: the surface breaks from level into a 25% grade at one
edge and back out at the other. `roadRampLongCurved` was sitting unused in the
kit at 377 vertices. Sampling its top surface along the centre and normalising
gave a curve matching **smootherstep** (`6t⁵ − 15t⁴ + 10t³`) to under 0.01 at
every one of its 25 vertex rows — so the ribbon reproduces it analytically rather
than reading the GLB, which `measure()` cannot afford to do on every mouse move.

| | worst gradient change between collision samples |
|---|---|
| `roadRampLong` wedge | 25% (a step, at each end) |
| `roadRampLongCurved`, 8 samples/tile | 8.4% |
| `roadRampLongCurved`, 16 samples/tile | 4.4% |

Kept at 16. The ramp is also why straights are now sampled every 0.2 units rather
than once per tile — a curve carried on a 14 m sample is a set of facets.

**Banking, first attempt: roll the whole tile.** Rendering it is what caught the
problem; the numbers all looked right. Peak bank 10.00°, edge rise 1.46 m over
the 8.4 m half-width, 19 of 46 tiles deformed, road surface tilted 1.70 m across
its width — every measurement agreed with the design and the result was visibly
broken. The tile's inner edge rolled *below* the 4 km ground plane and the grass
clipped through the road; the outer edge would have stood up as a cliff.

Fixed by making the cross-section an embankment rather than a tilt: inside edge
at ground level, a climb across the middle 3.5 m either side of the centreline,
then a straight grade back to ground by the tile edge. Nothing sits below the
grass at any angle. The grade back down is linear because an eased one peaks at
1.875× its average slope — 39° at the road edge, steep enough to launch a car
that ran wide, against 19° for the linear one.

Widths were the tuning: the banked strip is deliberately narrower than the
tarmac, since widening it steepens the run-off in proportion.

**Banking, second attempt: the car jumped.** Reported from actually driving it,
and it took three measurements to find, two of which said the opposite of what
they looked like they said.

The first cause was real and was mine. `BANK_FULL_HALF` was 3.5 m — inside the
tarmac's 4.83 — so both of the cross-section's gradient changes landed *on the
driving surface*. Dumping the cross-section made it obvious:

| lateral | rise | gradient | |
|---|---|---|---|
| −4.90 m | 0.123 | +19.4° | apron |
| −3.50 m | 0.617 | +19.4° | **ridge, on the tarmac** |
| −2.80 m | 0.494 | −10.0° | the actual bank |
| +3.50 m | −0.617 | −10.0° | **kink, on the tarmac** |
| +4.20 m | −0.617 | 0.0° | flat apron |

Along the racing line it measured as a flawless 10° bank the whole time, because
along the racing line it *was* one. Fixed by widening the banked strip past the
tarmac so every gradient change sits on grass.

The other two measurements were both wrong before they were right:

- An **autopilot lap test** reported 3.5% of frames airborne on banked road
  against 0% flat, which looked conclusive. It was measuring a field: the
  autopilot could not hold the circuit and ended up 592 m off centre *at zero
  bank*, so the "nearest centreline point" it classified by was noise. Its one
  useful output was that of frames actually on or beside the road, 0–0.4% were
  light at every angle.
- A **launch test** replacing it — car placed on the road, aligned and already at
  30 m/s, run free — reported 98.6% of points leaving the ground, worst at 0.0°
  of bank. It was dropping the car 1.2 m and starting to measure while it was
  still falling.

Settled and steered, the same test finally split the circuit by cause:

| | runs | mean airborne frames |
|---|---|---|
| Banked corners | 3 | **0.7** |
| Hills | 4 | 23.0 |
| Plain flat road | 26 | 13.2 |

Banked corners were the most planted part of the lap. Banking never threw the car
*on* the road — it threw it off the road edge, which an embankment model puts
0.5 m above the grass with 2.1 m of verge to come back down.

**Bank angle**, therefore, is set by that edge. 1.5°/2.5°/4° by corner size, 4°
the ceiling: 0.69 m of road edge and an 18° apron, which the suspension follows.
6° is a metre and 26°, and a car drifting a hand's width wide drops off it.
Banked corners now average 0.0 airborne frames.

Rounding the joins in the cross-section (`BANK_FILLET`) is kept because a sharp
convex crest throws the car at *any* crossing speed — curvature is infinite at a
corner — but honesty demands noting it changed nothing measurable here: nine
samples across the crest left the car exactly as planted as three, at six times
the collision triangles. It is sampled at three.

Transition length 1.5 units (21 m) holds the roll rate to 0.87°/m — near 25°/s at
racing speed, quick enough to feel like the road taking the car and slow enough
that the chase camera never snaps. At 1.25 units it was 1.04°/m.

**Banking is off by default**, and the radius-derived default that used to apply
when a corner said nothing is gone entirely — from the editor and from the layout
grammar alike. It was wrong in the way silent defaults usually are: banking
changes how a circuit drives, so a track that leaned everywhere the moment it was
painted was one its author had to notice and undo. The angles still run up with
radius as the editor's cycle order, but nothing applies them on its own, and
Highland now writes its own angles out. A track saved before banking existed
reopens flat rather than inheriting anything.

**The anti-roll bar was fighting it.** `_apply_antiroll` measured roll against
world up. On a flat circuit that is the road's up; on a banked one it saw a
permanently rolled car and spent the corner levelling it against the road. Now
takes the surface normal from one downward ray, falling back to world up when
airborne. Nothing else in the tuning was touched — the reference vector was the
bug, not the stiffness.

> The measurement trap this time was measuring the wrong geometry and being
> reassured by it. A test checking that shipped tracks kept their banked meshes
> passed on **Flats**, which has no banking at all, because `roadStart` paints its
> gantry banner with the same `road` material as the tarmac, 0.65 units up — so
> every circuit reported a 4.5 m "bank" on its start tile. Reading a material name
> is not the same as reading the driving surface.

## M7 — three circuits off a real map

Highland and Flats were replaced by **Ardennes** (Spa-Francorchamps, 1473 m),
**Monte Carlo** (Monaco, 1054 m) and **La Sarthe** (Le Mans, 1768 m). Nothing in
the builder changed; this was layout work, and what it produced was mostly
findings about the constraints the layout grammar already had.

**Closure stopped being trial and error.** The old layouts were solved by
adjusting straight counts until the walker came back to the origin. Each of these
was drawn as a rectilinear polygon first: a leg spans
`straight_cells + N_in + N_out - 1` tile units, where N is the size of the corner
at either end, so picking the outline in whole units *decides* the straight
counts and closure is arithmetic. Two sums — one per axis — say whether the loop
joins up, before anything is built.

**Closure says nothing about the road crossing itself**, and that is the failure
this actually hit. A layout can close perfectly with one straight driven straight
over another. It is not visible in the closure line, and on a 40-tile circuit it
is not obvious in a screenshot either. The check that found it paints the tarmac
onto a grid at quarter-tile resolution and looks for a cell claimed twice by
stretches more than four units apart along the lap, which is what separates a
genuine crossing from an S-bend passing close to itself. Monaco's first draft
failed it in two places; the shipped circuits, checked the same way, are clean.

Monaco needed re-planning rather than re-numbering. Its first corner order —
Casino, Mirabeau, Loews, Portier, chicane, five same-handed corners in a row —
has **no** non-crossing solution at any leg length: the hairpin makes a peninsula
and the straight after it has to cross back over the road that fed it. Ordering
it as a staircase down the hill and a staircase back along the harbour is both
what the real circuit does and the arrangement that closes.

**All three shipped mirrored, and every check passed.** Spa, Monaco and Le Mans
run clockwise; the first draft of all three ran anticlockwise, with La Source and
Sainte Devote as left-handers turning out of the pit straight instead of into it.
They closed, they drove, and nothing in the suite objected — a mirror image has
the same length, the same corner count, the same closure gap and the same
banking. It took someone driving them to say they looked backwards.

The reasoning that produced it: the car's forward is local +Z, and for a Y-up
right-handed basis the driver's right is `cross(forward, up)` = −X, so facing
south the driver's right is *west*. Godot's `Vector2.rotated` turns south to east
for −90°, so the builder's "right" looked inverted, and the layouts were written
with every label flipped to compensate. But `TrackBuilder._rotate` is **not**
`Vector2.rotated` — it is `(x·c + y·s, −x·s + y·c)`, deliberately the other way
round to match a Y rotation acting on (x, z) — and it takes south to west. The
labels always meant what they say. Two correct derivations, one wrong premise
about which function was being called.

`test_shipped_circuits_run_clockwise` now reads the direction off the built
centreline, per point, and asserts the first corner off the line is a right. The
lesson is narrower than "check your signs": the property was derivable and was
derived, twice, and the derivation was still worth nothing next to a measurement.

**Elevation is capped at one level by the art, not by the grammar.**
`roadStraightBridge` is modelled with 0.5 tile units of structure below its deck
— exactly one level of climb. Raised by one it stands on the ground; raised by
two it floats 3.5 m above it, with the supports hanging in mid-air. So every
climb on these three goes up a level, holds, and comes back down inside the same
straight, and corners stay on the ground: the bridge *corner* pieces are
deck-only, with no structure at all. `TrackLayout.MAX_LEVEL` is still 3 and the
editor still offers it, which is a real thing to fix in the art or the piece
choice rather than in the layouts.

> The measurement trap, again in the banking test. `_road_height_spread` compared
> a tile's highest road vertex with its lowest, which is banking only on a circuit
> with no hills — a ramp tile reports 2.02 m of "bank" from its own climb. Flats
> had no elevation at all, so the test never noticed; Monte Carlo has a crest up
> Beau Rivage and failed instantly. It now compares the surface only within thin
> bands along the tile, where a ramp is level and only a lean shows up, and a
> deliberately flat circuit measures 0.00. The old measure was not just noisy — it
> would have let a banked circuit that had silently reverted to level pass on the
> strength of its ramps.

## M8 — analogue throttle

**The triggers were being thrown away.** `car_controller` read steering with
`Input.get_axis`, which is analogue-aware, but throttle, brake and handbrake all
went through `Input.is_action_pressed`. Every device in the game therefore had
exactly two throttle positions, and half-throttle out of a hairpin was impossible
on any of them. Throttle and brake now scale `engine_force` and `brake` by
`Input.get_action_strength`, behind a player setting (analogue or binary) since
the brief pulls both ways — see `docs/architecture.md`.

**Measured, on the 2 km plane, at four trigger positions.** `_diag_throttle.gd`
held a fixed strength from a standing start for 120 s, teleporting the car back
up the plane whenever it neared the edge so velocity was never interrupted — the
slow runs need far longer than the plane is long to converge:

| Throttle | 0–60 km/h | 0–100 km/h | Top speed | % of full |
|---|---|---|---|---|
| 0.25 | 10.65 s | never | 67.4 km/h | 41% |
| 0.50 | 3.87 s | 9.73 s | 107.1 km/h | 65% |
| 0.75 | 2.65 s | 4.67 s | 138.3 km/h | 84% |
| 1.00 | 2.13 s | 3.37 s | 164.9 km/h | 100% |

**Full throttle reproduces M1's figures exactly** — 3.37 s to 100 km/h against
the 3.4 s recorded then, and 164.9 km/h against 165. That is the result that
matters most: the change adds positions between 0 and 1 without moving either
end, so nothing already in this journal was invalidated.

**Top speed falls off faster than the drag model alone predicts.** Drag is
quadratic, so top speed should go as the square root of engine force: 0.25
throttle ought to give 50% of top speed and gives 41%; 0.5 ought to give 71% and
gives 65%. The gap is a speed-independent loss — rolling resistance in the
raycast wheel model — sitting on top of aerodynamic drag. Useful rather than
alarming: it means the bottom of the trigger travel is **less** compressed than
a pure square root would make it, so quarter throttle is a genuinely distinct
thing to ask for rather than most of half throttle.

**The steering curve is not measured and is not claimed to be.**
`steer_response_curve` defaults to 1.5, which is a starting point to drive
against. It is an odd power, so it fixes -1, 0 and 1, and a keyboard and a touch
pad only ever ask for those three — which is exactly why it could be added
without re-measuring anything here, and equally why nothing here can evaluate it.

### Still open, from M8

- **Everything above is arithmetic, not feel.** These runs hold a fixed strength;
  they cannot say whether the pedal is *nice*, which needs a physical pad. The
  three questions waiting on one: is 1.5 the right steering exponent, should
  analogue or binary be the default, and does the InputMap deadzone (0.2, shared
  with steering) produce a step at the bottom of the trigger worth smoothing out.
  Godot zeroes below the deadzone without rescaling what is left, so the pedal
  currently engages at 20% rather than from nothing.
- **Corner-exit figures are still binary-throttle figures.** Nothing in M2 was
  invalidated, because full throttle is unchanged — but no corner has yet been
  driven at partial throttle, which is the whole point of the change. The
  cornering half of this milestone is measured, not assumed, and is not done.
- **Braking was not swept.** It takes the same treatment as throttle and the same
  argument applies, but M1 established that stopping is traction-limited rather
  than brake-torque-limited, so scaling `brake_force` by trigger travel may do
  much less than scaling `engine_force` did. Worth measuring before assuming it
  works.

## M10 — how long a lap ought to take

The editor needed an estimated lap time, and the medals (M15) need a par. Both
have to be the same function or the editor would advertise a target the medals
disagreed with, so it lives in `scripts/game/par_time.gd`.

**Not a fitted constant.** `docs/ideas.md` proposed
`length / effective_average_speed(corners, peak)` calibrated against the shipped
circuits. That has to be re-fitted whenever the handling changes and cannot tell
one long straight from the same metres in short bursts. Instead it runs the
standard quasi-static simulation over the centreline the builder already
produces: cap speed by cornering grip at every point, then sweep forwards under
acceleration and backwards under braking until the profile is reachable.

**Every constant is a measurement from this journal.** 3.65 g lateral, 1.62 g
braking, 164.9 km/h top speed, 0–100 in 3.37 s. Acceleration is modelled as
`A * (1 - (v/v_max)^2)`, the shape drag actually produces; integrating that to
100 km/h in 3.37 s fixes `A` at 9.56 m/s² with nothing left free. It predicts
0–60 in 1.83 s against a measured 2.13, so it is optimistic low down where the
real car is traction-limited off the line.

**The cornering half checks out against M3b.** That milestone measured 98 km/h
on a 21 m radius and 127 km/h on 35 m. The model gives 98.7 and 127.4.

| Circuit | Length | Ideal lap | Average |
|---|---|---|---|
| Ardennes | 1473 m | 0:49.1 | 108 km/h |
| Monte Carlo | 1054 m | 0:40.0 | 95 km/h |
| La Sarthe | 1768 m | 1:01.1 | 104 km/h |

Monte Carlo is the shortest circuit and the slowest per metre, which is what
"fourteen tight corners" should produce — the model is reading difficulty rather
than just length.

**Corner radii are 7 / 21 / 35 m, not 21 / 35.** Worth writing down because the
M3c table lists only two and it is easy to read them as the whole set. From
`PIECES`, radius is `(size - 0.5)` tile units, so the three Kenney corners are
0.5, 1.5 and 2.5 cells. The M3c figures are the middle and largest. **The
smallest is a genuine 7 m, 57 km/h hairpin**, and all three shipped circuits
contain one — which is why they all report the same slowest corner. This was
briefly mistaken for a bug in the curvature code.

**One real bug, in how curvature was sampled.** The centreline is a polyline —
eight chords around a corner arc — so its vertices lie on the real geometry but
the segments between them cut inside it. Measuring curvature *after* resampling
to a fixed step therefore measures the polygon: a sample near a chord junction
reads the join as a kink, one mid-chord reads a corner as straight, and finer
resampling makes it worse. Fixed by computing the speed cap at the source
vertices and interpolating it onto the step alongside the position. Worth about
half a second a lap on Monte Carlo and a tenth on Ardennes.

**Cost, since it runs on every mouse move.** 2.64 ms for measure-plus-estimate on
La Sarthe, of which 1.63 ms is the walk the editor was doing anyway. Against a
16.7 ms frame.

### Checking it against a driven lap

The estimate needed a real lap to be worth anything, and none had ever been
driven. So a throwaway `_diag_drive.gd` drove one: pure pursuit for steering, a
look-ahead speed target for the pedals, pressing the same actions a pad does
through `Input.action_press` — so the whole of `car_controller` and the real
physics are in the loop and the lap time is produced by the car rather than by a
model of it. It used 80% of measured grip, because a pursuit controller with
steering lag cannot sit on the limit without eventually losing the back end.

Four laps each, best of the three after a warm-up lap:

| Circuit | Driver | Estimate | Driver vs estimate | Centreline | Driven | Max stray |
|---|---|---|---|---|---|---|
| Ardennes | 50.48 s | 49.14 s | **+2.7%** | 1473 m | 1380 m (−6.3%) | 7.3 m |
| Monte Carlo | 38.07 s | 40.04 s | **−4.9%** | 1054 m | 973 m (−7.7%) | 7.3 m |
| La Sarthe | 60.33 s | 61.12 s | **−1.3%** | 1768 m | 1650 m (−6.6%) | 7.3 m |

**The model is good to about ±5%, which is the answer M10 wanted.** Lap times
were repeatable to within half a second across four laps, so the spread is the
model's, not noise.

**But the driver beat the "perfect" lap on two circuits, and that is the real
finding.** Not because the physics constants are wrong — they are measured and
the cornering half is checked independently — but because of the **path**. The
model integrates along the centreline. A car drives the racing line, which came
out **6–8% shorter** on every circuit.

The 7.3 m maximum stray is exactly half the 14 m road width, on all three. The
driver is not cutting off the circuit or exploiting grass gripping like tarmac;
it is using the full width of the road, outside to apex to outside, as anyone
would. This is an ordinary racing line, not an exploit.

Which means **the error is circuit-dependent, not a constant offset**: the
tighter the circuit, the more the racing line has to gain, so Monte Carlo's
fourteen tight corners give up 4.9% while La Sarthe's long straights give up
1.3%. No single slack constant can absorb that, which is exactly what
`HUMAN_SLACK` was going to be asked to do.

### The racing line, modelled

The fix M10 asked for. Rather than widen corners with a closed-form arc — which
assumes a corner alone with unlimited straight either side, and gives a 21 m
corner an effective radius near 50 m — the line is found by **relaxation**:
repeatedly pull each point towards the midpoint of its neighbours, clamped to
6 m either side of the centreline. That converges on the minimum-curvature line
inside the ribbon, and gets the competition between neighbouring corners for the
same road for free.

| Circuit | Centreline | Racing line | Estimate before | after | Driven | Error |
|---|---|---|---|---|---|---|
| Ardennes | 1473 m | 1447 m | 49.14 s | 47.75 s | 50.48 s | −5.4% |
| Monte Carlo | 1054 m | 1037 m | 40.04 s | 38.15 s | 38.07 s | +0.2% |
| La Sarthe | 1768 m | 1738 m | 61.12 s | 59.02 s | 60.33 s | −2.2% |

**The qualitative change matters more than the numbers.** Before, the model was
slower than the driver on one circuit and faster on two — it was not a bound on
anything. Now it is faster on all three, by 0.2% to 5.4%, which is what an
*ideal* lap should be against a conservative driver using 80% of grip.

**The line is only 1.8% shorter, and the lap is 3% quicker.** Most of the gain is
not distance but curvature: straightening a corner raises the speed through it,
which is worth more than the metres saved. That is also why the closed-form
approach would have been so wrong — it models only the radius and ignores what
the next corner is doing.

**Cost, since it runs on every mouse move.** 4.4 ms on La Sarthe against 2.6 ms
for the walk alone. Written over flat `PackedFloat32Array`s with the inner loop
inlined: as arrays of `Vector3` with a two-line helper it was 10.8 ms, nearly all
of it function-call overhead. Eight passes at a half step land within 0.2% of
twenty at a quarter and cost a third less.

### Still open, from M10

- ~~**Model the racing line, do not tune the constant.**~~ **Done, above.**
- **`HUMAN_SLACK` is still unmeasured**, and still measuring the wrong thing on
  its own. The model is now a consistent bound, which is the prerequisite for
  calibrating it, but the spread across three circuits is 0.2% to 5.4% — so a
  single constant still carries several percent of circuit-dependent error.
  Narrowing that needs laps driven by people rather than by a pursuit controller.
- **The old note, kept because the reasoning still holds:** The honest fix for the
  above is a wider effective corner radius — a 90-degree corner of radius R on a
  road of half-width w can be taken on an arc meaningfully larger than R — which
  would both raise corner speeds and shorten the path, the two effects actually
  observed. Adding a fudge factor to `HUMAN_SLACK` instead would hide a
  systematic error inside a number that is supposed to mean something else.
- **`HUMAN_SLACK` is still unmeasured**, and now known to be measuring the wrong
  thing on its own. Medals (M15) rest on it, so M15 should not be started until
  the path question above is settled. Nothing user-facing uses it today; the
  editor shows `ideal_lap`.
- **The scripted driver is not a human.** It is a competent, conservative
  reference at 80% grip, useful for validating the model and useless for knowing
  what a person on a pad will do. A gold medal set at the driver's pace is a
  guess about people, however well measured it is about cars.
- The acceleration model is optimistic below about 60 km/h. It matters most on
  circuits with many slow corners, which is exactly where a par time is hardest
  to get right.
- Braking is treated as constant-g from any speed. Real braking from 165 km/h has
  aerodynamic drag helping at the start, so the model is slightly pessimistic
  into the fastest corners.

## M14 — a second car, measured

A garage needs cars that feel different, so the second one had to be measured
rather than assumed. Same rig as M1 and M2: the flat plane, real `car_controller`
driven through `Input.action_press`, teleported back up the plane so the run is
not cut short by the edge.

| Car | 0–60 | 0–100 | Top | 100–0 | Lateral |
|---|---|---|---|---|---|
| Racer | 2.14 s | 3.38 s | 164.9 km/h | 1.85 s / 24.3 m | 3.52 g |
| Prototype | 2.05 s | 3.07 s | 186.2 km/h | 1.81 s / 23.9 m | 3.90 g |

**The Racer reproduces M1 and M2 exactly** — 0–100 in 3.38 s against 3.37, top
speed 164.9 against 164.9 — which is what says the rig is measuring the same
thing the old one did. The lateral figure reads 3.52 against M3b's 3.65 because
the *method* differs: this takes the peak of `v * yaw_rate` in a steady-state
skidpad, M3b measured it another way. Both are internally consistent, so the
Prototype's grip is carried across as a **ratio** of the two rather than used
raw: 3.90/3.52 applied to 3.65 gives 4.04.

The Prototype is 13% faster at the top end, 9% quicker to 100 and 11% grippier.
That is a different car rather than a reskin, which is the whole point of a
garage.

### The consequence: par is per car

`ParTime` hard-coded the Racer's grip and top speed, because for as long as there
was one car they were *the* grip and top speed. A second, quicker car makes a par
computed from them simply wrong for it — and medals were always specified per car,
so a shared par would hand the Prototype an easy gold on every circuit.

So the measured outcomes moved onto `CarSpec` and `ParTime` takes one. Par is now
per circuit *and* per car:

| Circuit | Racer | Prototype |
|---|---|---|
| Ardennes | 47.75 s | 45.25 s |
| Monte Carlo | 38.15 s | 36.35 s |
| La Sarthe | 59.01 s | 56.09 s |
| Suzuka | 34.43 s | 32.78 s |

Note what is on the spec and what is not: `tuning` says how much engine force and
grip the car is *given*, and these say what that *produced*. Par needs the
outcomes, and deriving them from the tuning would mean reimplementing the physics
in the estimator.

### The limit checks, and one that did not work

M2's slalom re-run for both cars, at 95% of each car's own top speed rather than
a shared one, so each is tested where it actually lives:

| Car | Slalom at | 2+ wheels off | Peak roll rate |
|---|---|---|---|
| Racer | 156.7 km/h | 0 / 2522 | 0.03 rad/s |
| Prototype | 176.9 km/h | 0 / 2522 | 0.04 rad/s |

Both flat, over four times the frames M2's 0/600 was declared on. The anti-roll
bar holds the second car as well as the first.

**The oversteer probe did not work, and saying so is the finding.** Full lock held
at speed produced a peak slip angle of 3.8 and 4.2 degrees — a car turning, not a
car sliding. The cause is the speed-based steering falloff: at 177 km/h against a
215 km/h reference, `speed_factor` clamps to its 0.25 floor, so "full lock" is a
quarter of the steering the test believed it was applying. **Neither car has been
provoked at the limit**, and the flat slip numbers are evidence about the probe
rather than about the cars. Provoking one needs a lower speed, a lift, or the
handbrake.

That mattered immediately: the Prototype's blurb claimed "less forgiving", which
nothing had measured. An attempt to *make* it true — rear grip nearer the front,
softer anti-roll — moved none of the numbers, because the probe could not see it
either. Worse, it changed the grip the M14 sweep had just been run against, which
would have left the spec describing a car that no longer existed. Reverted, and
the blurb now says what was measured: faster everywhere, same balance.

### Provoking a slide, properly

The probe rewritten to work at **90 km/h** rather than at top speed, where the
steering falloff still leaves 55% of the lock instead of clamping to its 0.25
floor. Three provocations, peak slip angle in degrees:

| Car | Power | Handbrake | Lift |
|---|---|---|---|
| Racer | 1.3 | 179.1 | 14.7 |
| Prototype | 1.8 | 178.8 | 15.8 |

**The rig can see a slide now**: the handbrake spins both cars fully round — 179
degrees of slip and 8.06 rad/s of yaw — where the old probe reported 4 degrees
for everything.

Three findings:

- **There is no power oversteer at all.** Full throttle and full lock produce
  under 2 degrees of slip on either car. At 3.65 g and 4.04 g the tyres simply do
  not care, so the throttle cannot break the back end loose. That is M2's "slides
  only when provoked" holding exactly, with the handbrake as the only thing that
  provokes.
- **The handbrake may provoke too much.** 179 degrees is not a slide, it is a
  complete spin, from one press at 90 km/h. Recorded rather than changed:
  `handbrake_rear_friction` is the lever, it was last set in M3b to keep its ratio
  under the raised grip, and changing it is a feel decision that wants driving
  rather than measuring.
- **The two cars have the same balance.** Every figure is within a degree or two
  across all three probes. The Prototype is faster, not different in character —
  which is what its blurb now says, and it is worth knowing before a third car is
  added that "faster" is the only axis the garage currently varies.

### Still open, from M14

- Whether a full-spin handbrake is what the game wants. Measured, not judged.
- A car that differs in *balance* rather than in pace, which is what would make
  the garage a choice rather than a ladder.
- The two cars are within 12% of the same size, which is why the road-versus-car
  scale question is still deferred rather than answered.

## M17 — conditions

Surfaces arrived as a **race-time choice** rather than a property of the circuit.
`docs/ideas.md` proposed a winter Ardennes; racing one is the same thing from the
other side — the circuit does not change, the conditions do — and a lap record has
been keyed on `track|car|surface` since M8 precisely so the two could never be
compared.

`grip` multiplies the tyre friction the car's tuning asks for, so it composes:
the Prototype is still grippier than the Racer on snow. Dry 1.0, dirt 0.72, snow
0.5.

**What this model does and does not change, and it is the wrong way round.** M2b
measured that braking here is *brake-limited* rather than traction-limited —
stopping distance was byte-identical at grip 1.4, 2.5 and 4.0, because
`brake_force` sits below its saturation point. So lowering grip changes cornering
and **leaves braking alone**. On real snow braking is the first thing to go. The
honest fix is for a surface to scale `brake_force` as well as friction, and it is
not done: brake force interacts with the saturation ceiling that M2b spent a
milestone finding, and changing it wants its own sweep rather than a guess
alongside this one.

Par follows grip, so a snow lap is judged against a snow target:

| Circuit | Dry | Dirt | Snow |
|---|---|---|---|
| Ardennes | 47.75 s | 52.76 s | 59.73 s |
| Monte Carlo | 38.15 s | 42.40 s | 48.14 s |
| La Sarthe | 59.01 s | 65.12 s | 73.41 s |
| Suzuka | 34.43 s | 37.36 s | 41.38 s |

(Dirt and snow rose again once braking became surface-aware; see below.)

### Braking now degrades with the surface — measured

The open item above is closed, and closing it needed a **deliberate model rather
than a tuning change**, because the physics will not produce this on its own.

`VehicleBody3D` applies `brake` as a force at the wheel instead of putting it
through the friction model, so `wheel_friction_slip` never limits it. Measured
from 100 km/h on the bare plane, full brake, before any change:

| Surface | Grip | Stopping distance |
|---|---|---|
| Tarmac | 1.00 | 24.17 m |
| Dirt | 0.72 | 24.24 m |
| Snow | 0.50 | 24.15 m |

A 0.4% spread across a surface that halves your cornering — which is noise, and
the wrong way round for anything loose. `car_controller` now scales `brake`, the
handbrake and reverse by exactly the same grip figure the tyres get:

| Surface | Grip | Stopping distance | vs dry |
|---|---|---|---|
| Tarmac | 1.00 | 24.17 m | — |
| Dirt | 0.72 | 31.25 m | x 1.29 |
| Snow | 0.50 | 40.44 m | x 1.67 |

Less than the 1/grip the model implies, because aerodynamic drag also slows the
car and drag does not care what the road is made of. That is the correct
behaviour, not a shortfall.

**Exactly grip, with no second table**, on purpose: a surface scales what a tyre
can do, and it should not be able to do that differently in one direction than
another. `ParTime` scales `braking_g` the same way — par has to model the car
being driven, or every braking zone on snow is estimated at nearly twice the
deceleration available. Baked par on dirt and snow moved up accordingly (tarmac
is unchanged, since its multiplier is 1.0), and the suite's par-vs-model check is
what caught all sixteen values.

**Acceleration was measured at the same time and deliberately left alone.** Time
to 100 km/h was 406, 409 and 414 frames on tarmac, dirt and snow — a 2% spread,
so drive is very nearly as surface-blind as braking was. The rear wheels *are*
traction-limited enough to spin, but engine force dominates. Changing it would
move every par time and the whole feel of the car, so it wants its own measured
pass rather than being folded into a braking fix.

### Every surface has now had a sweep of its own

The grip multipliers were *stated* and never measured. Two rigs, both on the bare
plane.

**Steady-state skidpad** — full throttle, full lock, settled for 15 s, then
lateral acceleration read off the car as speed x yaw rate:

| Surface | Grip | Speed | Radius | Measured | `LATERAL_G` x grip | Error |
|---|---|---|---|---|---|---|
| Tarmac | 1.00 | 105.5 km/h | 23.7 m | 3.69 g | 3.65 g | +1% |
| Dirt | 0.72 | 122.6 km/h | 44.0 m | 2.69 g | 2.63 g | +2% |
| Snow | 0.50 | 118.1 km/h | 58.4 m | 1.88 g | 1.82 g | +3% |

**The par model is fair on every surface**, which is the result that mattered:
`ParTime` assumes the car can pull `LATERAL_G x grip`, and it can, to within 3%.
A medal on snow is worth the same as a medal on tarmac.

**Slide recovery** — provoked with the handbrake and full lock for a fixed time,
then everything released except throttle. Peak slip angle is heading against
velocity; recovery is time to come back inside 12 degrees with yaw settled:

| Pull | Tarmac | Dirt | Snow |
|---|---|---|---|
| 0.20 s | 1.0 deg, 0.23 s, 97 km/h | 0.9 deg, 0.23 s, 98 km/h | 0.7 deg, 0.23 s, 98 km/h |
| 0.33 s | 15.4 deg, 1.28 s, 72 km/h | 11.8 deg, 1.38 s, 78 km/h | 8.3 deg, 1.35 s, 82 km/h |
| 0.50 s | 48.2 deg, 1.57 s, 22 km/h | 37.8 deg, 2.05 s, 35 km/h | 27.1 deg, 2.17 s, 52 km/h |
| 0.75 s | 180 deg, 1.58 s, 7 km/h | 180 deg, 1.88 s, 7 km/h | 130 deg, 2.43 s, 3 km/h |

**The car slides *less* on snow than on tarmac, and that is correct rather than
broken.** It reads backwards at first. The reason is that a handbrake spin is
generated by an *imbalance* between the ends of the car, and scaling both ends by
the same number preserves the balance while reducing the total yaw moment
available — so the same provocation buys less rotation on a slippier road. The
handbrake is simply a poorer weapon on snow.

What snow does deliver is the two things that actually make a surface treacherous,
and both are measured above: it takes **longer to recover** (2.17 s against 1.57 s
at the 0.5 s pull), and it corners at **half the lateral g**, so a corner entered
at the speed that worked on tarmac runs wide. That is what a player will feel, and
it is the honest consequence of uniform grip scaling.

Recovery never failed at 0.5 grip. That was the open question and the answer is
no, the car does not become uncatchable.

### M14 revisited — the garage, measured

The prototype's figures were written down rather than measured, which the roadmap
called "a guess wearing measured clothes". The M1/M2 sweeps were run against both
cars on the flat plane.

| | Top speed | Lateral | Braking | 0-100 | Stop from 100 |
|---|---|---|---|---|---|
| `race` measured | 164.9 km/h | 3.69 g | 1.62 g | 6.65 s | 24.2 m |
| `race` spec | 164.9 | 3.65 | 1.62 | — | — |
| `race_future` measured | 186.2 km/h | 4.08 g | 1.66 g | 6.02 s | 23.7 m |
| `race_future` spec | 186.2 | 4.04 | 1.65 | — | — |

**The prototype's stated figures were right.** Top speed to the decimal, lateral
and braking within 1%. The baseline reproducing its own spec exactly is what makes
that believable rather than lucky — it validates the rig before the rig is used to
judge anything.

**`launch_accel` was wrong on both cars, by about a factor of two, and it had been
wrong since M10.**

`ParTime` integrates `a = launch * (1 - (v/v_max)^2)` forward between corners, so
the value that belongs there is the one making *that model* reproduce the car's
real acceleration. Fitted against the measured 0-100 it is **4.84** for `race` and
**5.16** for the prototype. They carried 9.56 and 10.11, which predict a 3.4 s
0-100 against a measured 6.65 s.

So par accelerated roughly twice as hard as the car can out of every corner, and
**every medal in the game was that much too hard to win**. Par is now 10% slower
across the board: Ardennes dry goes 47.75 s to 52.23 s, La Sarthe 59.01 s to
65.05 s.

Measured *directly* off the line the car pulls 6.73 m/s^2, between the fitted
value and the old one — the car accelerates harder early and falls off faster than
a single constant can describe. A one-parameter model cannot follow a curve the
car does not follow, so the constant is chosen for what it is **used** for, and
`CarSpec` now says so where the number is.

> **The bare plane stopped being a valid measurement surface and nothing said so.**
> `track_01.tscn` is kept precisely for physics measurements, and off-road grip
> (M17) means anything not on the drivable ribbon runs at 0.55 of the car's grip —
> which the plane, having no ribbon, now is. The first run of this sweep returned
> 2.14 g lateral and 38.0 m braking for a car whose journal figures are 3.65 g and
> 24.2 m, and the numbers looked plausible enough to write down. The rig now lays
> a road-layer slab under the plane. **Any future measurement on `track_01` must
> do the same.**

### Drive degrades with the surface too — measured

The last open item from M17. Drive was left alone when braking was fixed, on the
reasoning that it already degraded: the rear wheels are traction-limited under
power, so they spin instead. Measured, that is worth almost nothing.

| Surface | Grip | 0-100 before | 0-100 after |
|---|---|---|---|
| Tarmac | 1.00 | 6.62 s | 6.85 s |
| Dirt | 0.72 | 6.65 s | 9.95 s |
| Snow | 0.50 | 6.77 s | 19.55 s |

**A 2% spread across a surface with half the grip**, before. `wheel_friction_slip`
limits how much of `engine_force` reaches the road far less than it looks — the
same way it never limited `brake` at all. So `engine_force` is scaled by grip like
everything else, and there is still no second table: the surface scales what a
tyre can do and it cannot do that differently in one direction than another.

`ParTime` scales `launch_accel` to match, and par on the loose surfaces moved a
long way — La Sarthe on snow goes 80.10 s to 89.21 s, Ardennes 64.33 s to 71.01 s.
Tarmac is untouched, since its multiplier is 1.0.

> **Snow is now three times slower to 100 km/h, and that is the number to watch.**
> Braking on snow came out at 1.67x dry; drive comes out at 2.9x, because drag is
> quadratic and a halved tractive force loses to it much sooner. It is consistent
> with how braking and cornering are modelled and it may still be more penalty
> than the game wants. It is one multiply in `car_controller` if so, and par
> follows it automatically.

### Par is bounded by arithmetic, not by a driver

Par is a perfect lap and every medal is judged against it, so an error in par is
an error in every medal — and two changes moved it a long way in one session:
`launch_accel` corrected by a factor of two, and drive made surface-aware. Neither
had anything checking the result was still a *lower* bound.

The strong check is a scripted driver trying to beat it. **That has now been
attempted twice and abandoned twice**, and what came out of it is one measurement
and one honest gap.

The measurement: `car_controller` carried a comment saying its steering sign was
"a guess at `VehicleBody3D`'s convention". It is not a guess any more — held at
full lock with `steer_right` pressed, the car yaws at **-2.54 rad/s**, clockwise
seen from above, which is right. The sign in the controller is correct, and the
first scripted driver had it inverted, which is why it steered into the barrier at
the first corner of every circuit.

The gap: corrected, and following `ParTime`'s own racing line rather than the
centreline, it still did not complete a lap on any circuit inside 150 seconds. A
driver that cannot get round proves nothing about par either way, so nothing is
claimed from it. What it wants next is instrumentation — where the car actually
ends up, and whether it is stalling, spinning or simply never triggering a gate —
rather than another guess at the control law.

What is cheap and still definite is the arithmetic bound: **a lap cannot be driven
faster than its own length at the car's top speed.** No cornering, no braking, no
acceleration — distance over speed. Par below that is impossible; par far above it
means the model has stopped describing a car. Both ends are now checked for every
circuit, car and surface: 96 combinations, all inside the band.

### Still open, from M17
- ~~Grass still grips like tarmac~~ — fixed. Off the ribbon the car keeps 0.55 of
  whatever the surface gives it, and the barriers became solid in the same change,
  because a penalty for leaving the road with nothing to stop you leaving it is a
  car sliding into four square kilometres of empty field.

### Still open

- The hills are still the hardest part of the circuit to drive: 0.84 s airborne
  over a crest at 150 km/h in a straight line, and the car keeps whatever
  rotation it took off with. Open deliberately, not overlooked — the fix above
  worked on paper and was rejected on feel, so the next attempt wants a different
  approach rather than a retune of that one.
- Steering is still linear with a speed-based falloff; no countersteer assist.
- ~~Grass has the same friction as tarmac~~ and ~~guardrails are off~~ — both
  fixed together; see the M17 entry.
- Suspension squat/roll under load is not yet visible enough to read as weight
  transfer.
- Rear wheels sit at skid 0.66 under full throttle at 100 km/h — the car is
  power-sliding slightly in a straight line. Not obviously wrong for an arcade
  racer, but it has not been deliberately tuned.
- The grid shader aliases badly toward the horizon; wants a distance fade.
- Chicanes are two of the smallest corners back to back, which is as tight as the
  kit gets. `roadCurved` — the piece that would make a proper offset kink — always
  offsets the same way relative to travel, so mirroring it needs a negative scale
  rather than a Y rotation, and nothing emits it.
- Walls approximate `roadCurved` as a straight line between its endpoints.
- `track_01.tscn` (bare flat plane) is kept deliberately — physics measurements
  want a surface with no walls to run into.
