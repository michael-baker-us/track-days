# Roadmap

`docs/ideas.md` is the working document: what could be built, what it would cost,
and which invariants each thing threatens. This file is the commitment — what is
being built, in what order, and what "done" means for each step.

**Numbering continues from `docs/plan.md`**, which took the project from M0 to M6
and whose M6 was "decide the direction, deliberately unplanned". This is that
decision. `docs/tuning-journal.md` carried the sequence to M7, so the first
milestone here is M8 — one sequence across all three documents, because two
overlapping sets of milestone numbers in one `docs/` folder would be worse than
an awkward starting number.

The ordering is inherited from the end of `ideas.md` and regrouped into
milestones. Two rules shaped the grouping:

- **Every milestone ships something playable.** No milestone exists only to make
  the next one possible.
- **Decisions are made before the format that depends on them is written**, not
  after. The record key is the worked example; see below.

---

## Decisions locked

These were open questions in `ideas.md`. They are answered here, and `ideas.md`
keeps the reasoning for why they were hard.

### Analogue throttle and brake, behind a toggle

Throttle, brake and handbrake move to `Input.get_action_strength`, scaling
`engine_force` and `brake`. A player setting chooses analogue or binary, because
the brief genuinely pulls both ways — Horizon Chase is arcade and binary, the
time attack half of the brief is Forza and analogue.

**Lap records are not keyed on the setting, and that is defensible rather than
lazy.** Analogue is a strict superset of binary: full press is `1.0`, so anything
achievable in binary mode is achievable in analogue mode. A record set in binary
stays a legitimate target. The reverse is not guaranteed, so a player in binary
mode may face a time they cannot match — that is a real cost of the toggle and it
is accepted knowingly, not overlooked.

**The tuning journal has to be measured twice** from here on: every corner-exit
figure is a binary-throttle figure today. That is the price of the toggle, and it
is the reason this is the first milestone rather than a later one — the debt gets
worse the more numbers exist.

### The record key is composite from day one

A record is keyed on track, car **and** surface, with `car` fixed at `default` and
`surface` fixed at `tarmac` until a garage (M14) and surfaces (M17) exist.
Existing records migrate once, on load.

The point is that **sector splits and ghosts key off the same function** from the
moment they are written. Doing this later means migrating three save formats
instead of one, across data that by then a player cares about losing.

**The track is the config section, not part of one flat key.** A flat
`best_<track>_<car>` cannot be taken apart again: ids are drawn from `[a-z0-9_]`
(`TrackStore.new_id`), so `best_ardennes_kart` reads equally well as the kart on
Ardennes and as the default car on a circuit called "ardennes kart". A section per
track also makes deletion a single `erase_section`, which is exactly the sweep
`GameState.delete_track` needs — every time set on a circuit has to go with it, or
the next circuit to reuse the id inherits them.

### Still open, and when they must be answered

| Question | Needed by |
|---|---|
| Does the car kit scale up to the road, or the road down to the car? | M14, and it gets harder with every car added |
| Self-crossing at the same level, or only at different levels? | M13 |
| ~~Do shared circuits carry the author's ghost by default?~~ | **Answered in M11: no.** A circuit is 372 characters; a two-minute ghost makes the code 128,000. Not a preference — a size fact. Attaching one is possible and opt-in, for a transport that is not a chat message. |
| Per-circuit LUT or one global grade? | M16 (M8 does the global push, which is the cheap half) |
| Surface per circuit or per segment? | M17 |
| Do the barriers finally need collision? | M17, when grass stops gripping |

---

## M8 — Feel, and colour

*The cheapest big win of each kind. Both change every screenshot or every lap,
and neither needs a decision that has not been made.*

1. **Analogue throttle, brake and handbrake**, behind `GameState.analogue_input`.
   Keyboard and touch are unaffected — a full press is `1.0` either way.
2. **A steering response curve.** The stick maps linearly today and is then
   smoothed by `steer_speed`, which fights an analogue input. Curve near centre,
   full lock still reachable.
3. **The composite record key**, with migration.
4. **Colour grade.** `adjustment_saturation`, `adjustment_contrast` and
   `adjustment_brightness` on the `Environment` that `_build_lighting` already
   builds programmatically. Push the existing `ProceduralSkyMaterial` harder at
   the same time — a more saturated top colour, a bigger sun disc.

**Done when:** a gamepad trigger produces partial throttle, the toggle survives a
restart, an existing `best_<track>` record still shows on the title screen after
migration, the suite passes, and the tuning journal has a new section measuring
the analogue figures against the binary ones.

**Risk:** the re-measure is the real work. The code change is small.

**Status: built, and half measured.** Four trigger positions swept and recorded
in the journal; full throttle reproduces M1's figures exactly, so nothing already
measured was invalidated. What is *not* done is in the journal under "Still open,
from M8": no corner has been driven at partial throttle, braking was never swept,
and the steering exponent is a starting point rather than a measurement. All
three need a physical pad.

---

## M9 — The time attack loop

*The point at which this stops being a lap timer.*

1. **Sector splits.** Sixteen ordered gates already exist and `lap_tracker`
   already enforces their order; recording the time at each turns them into
   sixteen sector times for nearly nothing.
2. **Live delta on the HUD.** The `+0.42 / -0.18` readout against the stored best,
   which is the single most addictive thing a time attack game has.
3. **Ghost cars.** Record the car's transform every physics tick, save it beside
   the record, replay it as a translucent car.

**Note on ghost size, correcting `ideas.md`:** physics runs at **120 Hz**
(`common/physics_ticks_per_second=120`), not 60. A two-minute lap is ~14,400
samples, not 7,200 — roughly 460 KB as position plus quaternion, uncompressed.
Store every other tick and interpolate, or delta-encode, or both. This matters
because the `.pck` has to download in a browser.

**Done when:** a second lap shows a live delta against the first, a ghost of the
best lap replays over a fresh attempt, and a headless run reproduces both.

**Status: built.** Sampled at 60 Hz and deflated, stored under `user://ghosts/`
keyed the same way the lap record is. Not yet driven by a human — the ghost is
asserted to record, save, reload, interpolate and carry no collision, but
whether it *reads* well at speed has not been seen. See `docs/architecture.md`
for the eight decisions inside it.

---

## M10 — The editor as a design tool

*A panel, not an architecture.*

Surface what `measure()` already returns while drawing: length, longest straight,
tightest corner, total elevation change, and an estimated lap time from the same
par function the medals will use in M15. Plus a nudge when a circuit is
pathological — fourteen hairpins and no straight, or gates metres apart.

Then ordinary comfort: undo/redo (the shape is a value, so snapshot it),
duplicating a shipped circuit as a starting point, mirror and rotate, rename.

**Done when:** the readout updates live on every mouse move without the editor
dropping frames, and the estimated time is within a sensible margin of a real lap
on all three shipped circuits.

**Status: the readout is done and the estimate is validated.** The live readout
costs ~1 ms on top of the walk the editor already did. A scripted driver was then
run round all three circuits to supply the real laps the second half of the
"done when" required: the estimate lands within **±5%**, repeatable to half a
second across four laps.

**It also turned up something that changes M15.** The driver *beat* the perfect
lap on two circuits, because the model integrates along the centreline while a
car drives the racing line — measured 6–8% shorter, using the full road width
without ever leaving it. The error is therefore circuit-dependent (4.9% on tight
Monte Carlo, 1.3% on open La Sarthe), so no single slack constant can absorb it.
**M15 should not start until the racing line is modelled**, or medals will be
built on a number quietly doing two jobs. See the tuning journal, M10.

Editor comfort — undo is already in the editor; duplicating a shipped circuit,
mirror and rotate are **not started**.

---

## M11 — Reach

*Custom tracks were stored as JSON deliberately, for sharing, and sharing was
never built.*

A **share code**: layout JSON, deflate-compressed, base64'd, to the clipboard and
back. Works identically on desktop and web, which nothing filesystem-based would.
Then the same code **with a ghost attached**, so whoever opens a circuit is racing
a time from their first lap.

**Done when:** a code round-trips through the clipboard into an identical circuit,
and a malformed or hand-edited code **fails politely** rather than silently —
`TrackLayout.compile` calls `walk`, so an invalid one cannot build, but the player
has to be told why.

**Status: built.** `TD1-<base64>|<size>` — 372 characters for a real circuit,
carrying every per-corner choice, not just the painted outline. Copy is a button
in the editor; paste is an entry in the circuit picker, because the picker is the
control that answers "which circuit am I working on" and a pasted code is one way
to answer it. Every failure path is tested and each returns a sentence a player
can read.

**Ghosts are opt-in, and the measurement is why.** See the decisions table above.
Attaching a real lap makes the code 128,000 characters, so "share your ghost"
needs a transport that is not a message — a file or a paste-bin — which is not
built.

---

## M12 — Audio

*The single biggest gap in the project: there is none at all.*

Engine pitch from wheel RPM, tyre squeal from the skid values every wheel already
reports, and music that matches the palette. Nothing else makes the existing
driving feel this much better per line of code.

---

## M13 — Crossings and bridges

*The biggest expressive unlock still inside the grid.*

Teach `TrackShape.walk` that a self-touch is permitted **when the two visits sit
at different elevation levels**, and have the compiler emit a crossing or a bridge
there. `roadCrossing.glb` is vendored and unused; the bridge pieces are already in
service for elevated sections.

**This is the milestone that most needs its own tests.** `_accept` refusing
invalid shapes is what makes the editor safe, and this deliberately relaxes it.
Every existing rejection test must still reject.

**Explicitly not doing:** diagonals. `roadStraightSkew` exists and is a trap — the
rectilinear model is why closure is arithmetic rather than trial and error.

---

## M14 — The garage

1. **A `CarSpec` resource** — display name, source `.glb`, wheel positions, wheel
   radius, collision extents, and a `CarTuning` to pair with it. The natural
   extension of the decision that already put feel in a resource.
2. **`tools/build_car.gd` generalised** to bake one scene per spec.
3. **A second car**, chosen from the title screen at first, and tuned properly.
   A kart and a truck sharing `grippy.tres` feel like one car in two costumes.
4. **The pit lane as the selector**, approach (a) — generated from the finished
   centreline like the paddock is, parallel to the pit straight, with its own
   collision ribbon and an `Area3D`. The main loop stays one simple ring and
   `TrackShape` never learns about it.

The scale question has to be answered here: the road is 14 m wide and the car is
2.56 m long. A truck and a kart on the same road make that stop being subtle.

---

## M15 — Medals

> **Blocked, by a measurement rather than by an opinion.** M10 found the par
> model is 6–8% pessimistic because it walks the centreline and a car drives the
> racing line, and that the gap varies with how tight the circuit is. Medals rest
> directly on par, so calibrating `HUMAN_SLACK` first would bake a path error
> into a constant that is supposed to mean "how much slower people are". Model
> the racing line first.

Gold / silver / bronze per circuit per car, with par times **derived** from
`measure()` rather than authored — so player-drawn circuits get medals for free,
which is a much better story than progression existing only on three tracks.

`par = length / effective_average_speed(corners, peak, car)`, calibrated against
the three shipped circuits whose real times are known. Gold at par, silver at
par x 1.06, bronze at par x 1.15, all to be measured.

**Medals unlock variety, never capability.** No performance upgrades — they make
old lap times incomparable, which is the one thing a time attack game cannot
afford.

---

## M16 — The look

*The point at which it stops looking like a Kenney demo.*

A custom sky shader — gradient bands, a huge sun, flat stylised cloud bands. Then
time-of-day presets attached to the circuit rather than hidden behind a menu, with
**night built for specifically**, which is the reason to finish the lighting
columns already being placed trackside. Then horizon silhouettes, denser roadside
objects, a lower and closer camera pass, a rim light on the car, a blob shadow
under it, scenery themes, and weather as a colour treatment.

**Not doing, and the reversal is deliberate:** clearcoat paint, sky reflections,
road wear, a fully lit ground plane, SSAO. Those are realism tools and this is not
a realism target. `ground_grid.gdshader` stays `unshaded`.

---

## M17 — Surfaces, and tyre tracks

1. **A lateral coordinate on the ribbon** (`UV2` or vertex colour). Small, and the
   prerequisite for both racing-line rubber and the deformation texture. Worth
   doing on its own, first.
2. **Surfaces per circuit** — snow and dirt as shader variants through the
   `surface_road` hook that already exists, each with its own grip sweep.
3. **Tyre tracks**, in three steps: trail geometry, then a track-space deformation
   texture accumulating across laps, then real vertex displacement.

The ribbon parameterisation is what makes step 3 tractable: a 4096 x 128 texture
covers a 1500 m lap. The world-space equivalent is unallocatable.

**What this breaks, and it is real:** grass currently grips like tarmac, which is
what makes corner-cutting only *discouraged* by the ordered gates. Low-grip
surfaces change that, and that is when the barriers need collision.

---

## Cross-cutting, every milestone

Non-negotiable per `CLAUDE.md` and the repository philosophy:

- **Tests.** `tests/run_tests.gd` gates CI. New behaviour arrives with new
  assertions in it.
- **The tuning journal** records how numbers were measured, not what they are.
- **`docs/architecture.md`** records the *why* behind structural decisions and the
  traps already hit. Anything non-obvious goes there, not in a code comment alone.
- **The web build constrains all of it**: single-threaded, compatibility renderer,
  no system fonts. New UI text stays inside the built-in font or it ships as a
  tofu box.
- **Generated scenes stay generated.** Never hand-edit a `.tscn` that `tools/`
  bakes.
