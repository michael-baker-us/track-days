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

Importing goes through a **text field**, not a clipboard read. In a browser,
`clipboard_get` only returns what was last pasted into the canvas — reading the
system clipboard needs a permissions API Godot's web platform does not expose —
so a button that read it would come back empty. A focused `LineEdit` gets the
browser's paste event directly and behaves the same on both targets. The field is
pre-filled from the clipboard where that works, so desktop stays one click.

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

**Status: rebuilt after being judged not good enough. Still off by default,
because nobody has heard the new one.**

The first person to listen to it called it annoying, which is the only listening
test that counts and the one no amount of headless assertion substitutes for.
What is there is a buzz and a hiss keyed to speed — structurally correct, tuned
against measured handling numbers, and not a car. **Sound is now opt-in** via a
switch on the pause menu, because shipping something irritating as the default is
worse than shipping silence.

### The pass that item asked for, done — except the listening

Three of the four things named above now exist.

1. **The engine is modelled with load and overrun.** The old one summed sixteen
   harmonics of 50 Hz: structurally what an engine *spectrum* looks like, and an
   organ to listen to, because what makes an engine an engine is that the sound
   arrives as a **train of pressure pulses** — one per firing, each ringing and
   dying before the next. Steady sines contain no pulses at all. A voice is now
   sixteen decaying resonant impulses placed in time, with uneven per-cylinder
   amplitudes for a once-per-cycle wobble.

   There are **two** of them, crossfaded by the throttle: bright and ringing on
   under power, dull and dying between firings on a closed throttle. A car that
   only changes pitch reads as a siren — the ear hears effort as timbre.

   > The decay rate is the load-bearing number. Firings are 10 ms apart, so 190
   > leaves 15% of a pulse sounding when the next arrives, which is the body of
   > the sound. The first attempt used 26 — **77%** — which is the harmonic stack
   > again with extra steps, and it measured as one. The suite now pins the shape
   > directly rather than the spectrum: split the buffer into sixteen windows and
   > every window's loudest sample must land near the start of it.

2. **Tyre scrub varies with surface.** Squeal is a *tarmac* phenomenon — tread
   stuttering against something hard, and tonal. Dirt throws material, broadband
   and much lower; snow packs it, quieter and duller than either. One buffer each,
   chosen when the car enters the tree. A squeal on snow was the loudest wrong
   note in the old mix.

3. **Collisions.** The barriers went solid in M17, and until now running out of
   road was a silent event that simply stopped the car, which reads as the game
   freezing. Triggered by a step change in velocity rather than a contact signal —
   `contact_monitor` reports *touching*, and 3 m/s inside one physics frame cannot
   be produced by driving, since the measured 1.62 g stop is 0.27 m/s per frame.

Six streams, 100 KB, about 1% of the web `.pck`.

4. **The countdown has a voice.** Two one-shot tones a fifth apart — one on each
   number, a longer and higher one on GO. A silent wait is indistinguishable from
   a game that has not started, and the interval is what makes GO read as a
   different event rather than as a fourth number. Non-positional, because a start
   signal does not come from a place in the world.

5. **The menus answer.** Two very short blips, a fifth apart like the countdown so
   they read as the same family — but quieter and shorter, because a menu tick is
   an acknowledgement and a start signal is an instruction, and a UI that answers
   as loudly as the race does is the kind of thing that gets the sound switched
   off. Wired to `gui_focus_changed` rather than per button: the circuit list is
   rebuilt whenever one is added or deleted, and a signal connected per row is a
   signal missed on the row added next.

6. **Kerbs rattle.** A train of sharp clicks rather than a tone, because a kerb is
   a *rhythm* — ribs going under a tyre — and the runtime shifts its rate with
   speed, which is the whole information a kerb carries.

   It needed something nothing else in the game had: **how far across the road the
   car is**. The collision world answers everything else — on the tarmac at all is
   a masked raycast, how steep it is comes off the contact normal — but not that.
   The circuit carries its centreline as metadata, `race.gd` hands it over, and
   `KerbFeel` walks a rolling index outward from the last answer rather than
   scanning a couple of thousand points every physics frame.

   **Deliberately only a sound.** A real kerb unsettles the car, and the collision
   ribbon is smooth across its whole width — there is no bump to hit, so shaking
   the car by hand would be inventing a physical event with no physics behind it.
   Ribs on the ribbon is the honest version and a different piece of work.

**M12 is now done bar the listening.** And the default is
**still off**, which is the honest position — every claim above is a measurement,
and the thing that condemned the last version was a person listening to it. The
constant is `GameState.audio_enabled`; flipping it is one line, and it should be
flipped by whoever hears this and thinks it is right.

One correction to the item above: pitch is **not** taken from wheel RPM. Wheel
speed rises monotonically, so that gives one twenty-second slide rather than an
engine; the speed range is divided into bands and the note sweeps each. See
`docs/architecture.md`.

**Music is deliberately not attempted.** A synthesised buzz is a sound effect and
a chiptune is composition — a different kind of work, and one where generating it
procedurally would produce something worse than silence. It wants either an
authored track or a real decision to build a sequencer.

**Unheard.** Every assertion here is about sample data, pulse shape and pitch
arithmetic. Nobody has listened to the current sounds at all.

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

### Status: step 1 of 4 done — topology

`TrackShape.walk` takes an `allow_crossings` flag. **It is off by default and
every existing caller leaves it off**, so the editor and the compiler behave
exactly as before. A shape the editor accepted but the builder could not build
would be worse than one it refuses, so the switch is thrown last, not first.

What the relaxation permits is exactly one thing: a cell with **four** neighbours,
which the road passes **straight through** twice. Three neighbours is a T
junction — a branch — and stays refused however the heights work out.

Pinned by tests: a figure of eight walks to a lap one longer than its cell count
with the crossing visited twice and no bend at it; T junctions, spurs, broken
rings, separate loops and road folded against itself are all still refused *with
the flag on*; and ordinary circuits walk to a byte-identical lap either way, so
throwing the switch later cannot quietly change an existing circuit.

**One encouraging find while surveying:** a different-level crossing may need **no
new tile**. `roadStraightBridge` is already in service, so the raised leg is a
bridge and the lower leg is ordinary road. `roadCrossing.glb` is only needed for
same-level crossings, which this milestone excludes.

### And a shipped circuit that already crosses: Suzuka

Shipped circuits are **authored segment lists**, not painted cells, so they reach
`TrackBuilder` without going through `TrackShape` at all. That means a crossover
circuit was reachable before any of the painted-crossing work is finished, and
one now ships: a rectilinear figure of eight, 991 m, six corners, where the back
half bridges over the front half 7 m up. Driving it opens by going *under* the
road the lap will later cross *over*.

It forced one real change: `BuildResult.closed` demanded `absi(turn_total) == 4`,
which conflates "it joins up" with "it never crosses itself". A figure of eight
cancels to **zero** net turns and joins up perfectly. Closure is now position,
height and heading; the stronger claim survives as `simple`, which is still what
every painted circuit must satisfy.

A scripted driver laps it in ~33 s between −0.04 m and 7.80 m, so it is drivable
rather than only geometrically valid.

### Step 2 done — the compiler, and the gate that makes it safe

`TrackLayout.allow_crossings` (off by default, persisted, round-trips through
JSON and share codes) makes the compiler crossing-aware: four-neighbour cells
stop being junctions, and the walk is asked to allow them.

**The gate is two levels of separation, and that is a measurement rather than a
taste.** `roadStraightBridge` carries 0.5 tile units of structure below its deck —
exactly one level. One level of separation would put the upper road's supports
in the lower road; two puts the deck 7 m up with 3.5 m of clear air beneath,
which is what Suzuka is built on.

A crossing that does not clear is **refused with a sentence**, not silently
flattened. Elevation requests that do not fit are reduced rather than refused —
a shortened climb is still a circuit — but two roads in the same place is not a
circuit at all, and quietly levelling it would leave the player looking at a
problem they cannot see.

### Step 3 done — and it needed no builder changes at all

A painted crossing builds with real clearance, and `TrackBuilder` was not
touched. It simply walks the segments and the road passes over itself, exactly as
Suzuka does; `_emit_run` already emits `roadStraightBridge` for a held section
above ground, so the raised leg is carried on a bridge without anything asking
for one. Pinned by a test measuring the built centreline: two parts of the lap a
sixth of a lap apart, meeting in plan, with 7 m between them.

Suzuka is what made this cheap. Shipping a crossover circuit as an authored
segment list proved the builder handled overlapping geometry *before* any of the
painted path existed, which turned step 3 from the risky one into a test.

### Step 4 done — the editor. M13 is complete.

A **Cross** toggle sits in the tool row beside Draw, Erase and Fit, and sets
`TrackLayout.allow_crossings` for that circuit — saved with it, and carried in
its share code.

**Per circuit and off by default, because it gives something up.** With it off,
no drag can produce a shape that will not build: that is the editor's strongest
guarantee. With it on, a drag can lay one leg across another and leave a circuit
that needs a bridge before it compiles. A fair trade to opt into and a poor one
to be handed.

Turning it back *off* is refused while a crossing is drawn, rather than silently
making the circuit unbuildable — the switch would appear to work and the reason
would surface as an error somewhere else entirely.

Three smaller things it needed:

- **`cells_from_corners` now returns a set.** Its output is written straight back
  to `TrackLayout.cells`, and a cell listed twice there is not a circuit with a
  crossing, it is a corrupt circuit. Deduplicating does not weaken
  `corners_valid`: `walk` does that work properly, since road doubling back along
  its own line leaves cells with one or three neighbours and only a clean
  transverse crossing leaves four.
- **`edge_at` returns -1 at a crossing**, the way it already does at a corner.
  Two straights run through it and there is no telling which one a drag meant.
  Both legs stay grabbable everywhere else.
- The opt-in threads through every edit, so `TrackShape` stays conservative by
  default and the policy lives in one place.

Pinned by tests: diagonals, degenerate edges and too-few-corners are all still
refused **with the opt-in on**; a figure of eight's outline is refused without it
and accepted with it; and the cells it traces contain no duplicates.

**Explicitly not doing:** diagonals. `roadStraightSkew` exists and is a trap — the
rectilinear model is why closure is arithmetic rather than trial and error.

---

## M14 — The garage

1. **A `CarSpec` resource** — display name, source `.glb`, wheel positions, wheel
   radius, collision extents, and a `CarTuning` to pair with it. The natural
   extension of the decision that already put feel in a resource.

> **Correction, from building it: the geometry does not belong in the spec.**
> `build_car.gd` hard-coded the body size, wheel positions and wheel radius with
> a warning that they were load-bearing. Measuring the same numbers off
> `race.glb` reproduces **every one exactly** — they were a copy of the art, not
> a decision about it. So a spec names a `.glb` and the builder reads the
> geometry out of it, and the regenerated `race` scene is byte-identical to the
> hand-specified one once Godot's generated resource ids are normalised.
>
> A spec is therefore an id, a name, a model and a tuning preset. Feel is the
> only thing that cannot be derived, and it is the only thing left to author.
2. **`tools/build_car.gd` generalised** to bake one scene per spec.
3. **A second car**, chosen from the title screen at first, and tuned properly.
   A kart and a truck sharing `grippy.tres` feel like one car in two costumes.
4. **The pit lane as the selector**, approach (a) — generated from the finished
   centreline like the paddock is, parallel to the pit straight, with its own
   collision ribbon and an `Area3D`. The main loop stays one simple ring and
   `TrackShape` never learns about it.

The scale question has to be answered here: the road is 14 m wide and the car is
2.56 m long. A truck and a kart on the same road make that stop being subtle.

**Status: garage built, pit lane not.** Two cars — `race` (the measured baseline)
and `race-future` (a prototype: more grip, more top end). Chosen from a button on
the title screen, which re-reads every row's lap time because **records were
already keyed per car**, so a second car arrived with no save migration at all.
That is the composite-key decision from M8 paying for itself.

**The scale question is deferred, not answered.** Every car shipped is within 12%
of the same size and all four candidate models use a 0.3 m wheel, so nothing
forces it yet. A kart or a truck would, and that is when it has to be settled.

**The prototype is measured now, and its figures were right** — top speed to the
decimal, lateral and braking within 1%. The baseline reproducing its own spec
exactly in the same run is what makes that believable rather than lucky.

**But the sweep found `launch_accel` wrong on both cars by about 2x**, and it had
been since M10. `ParTime` integrates `a = launch * (1 - (v/v_max)^2)` between
corners, so the value belonging there is the one that makes *that model* reproduce
the real car: 4.84 and 5.16, against the 9.56 and 10.11 they carried — which
predict a 3.4 s 0-100 against a measured 6.65 s. Par accelerated twice as hard as
the car can out of every corner, so **every medal was that much too hard to win**.
Par is now 10% slower across the board. Written up in the tuning journal, along
with the trap that nearly buried it: off-road grip quietly made the bare
measurement plane an invalid surface.

**Not done:** the pit lane is untouched.

---

## M15 — Medals

> **Unblocked, and built.** The racing line is modelled (tuning journal, M10),
> so par is no longer 6–8% pessimistic and is now a consistent bound rather than
> something the reference driver beat on two circuits out of three.

Gold / silver / bronze per circuit per car, with par times **derived** from
`measure()` rather than authored — so player-drawn circuits get medals for free,
which is a much better story than progression existing only on three tracks.

`par = length / effective_average_speed(corners, peak, car)`, calibrated against
the three shipped circuits whose real times are known. Gold at par, silver at
par x 1.06, bronze at par x 1.15, all to be measured.

**Medals unlock variety, never capability.** No performance upgrades — they make
old lap times incomparable, which is the one thing a time attack game cannot
afford.

**Status: built.** Gold at par x 1.06, silver x 1.15, bronze x 1.30, where par is
`ParTime.ideal_lap` — a perfect lap on the racing line.

**A medal is derived, never stored.** It is the best lap read against par, so
there is no new save format, no migration, and no way for a stored medal to
disagree with the time that earned it. Changing a threshold re-evaluates every
medal in the game on the spot.

Shipped circuits carry their par as a constant in `GameState.TRACKS`, because the
layouts live in `tools/` and the game does not depend on `tools/` at runtime —
the same arrangement as the generated theme, and guarded the same way: the suite
recomputes each one from its layout and fails if it has drifted. **Player-drawn
circuits compute their own**, which is the point of deriving par rather than
authoring it: a circuit has a gold time the moment it is drawn.

Shown as the caption on the title screen's lap column ("GOLD LAP"), coloured from
the theme, and announced on the HUD banner alongside the time that earned it. A
circuit never driven shows what gold is worth instead of a dash.

**The weakness, stated:** gold is set at roughly the pace of M10's scripted
driver, which is the only reference for what a perfect lap is worth in practice.
That reference is itself 0.2% to 5.4% off par depending on the circuit, so gold
is harder on some than others. Narrowing it needs laps driven by people — the
same gap that leaves `ParTime.HUMAN_SLACK` unmeasured.

---

## M16 — The look

*The point at which it stops looking like a Kenney demo.*

A custom sky shader — gradient bands, a huge sun, flat stylised cloud bands. Then
time-of-day presets attached to the circuit rather than hidden behind a menu, with
**night built for specifically**, which is the reason to finish the lighting
columns already being placed trackside. Then horizon silhouettes, denser roadside
objects, a lower and closer camera pass, a rim light on the car, a blob shadow
under it, scenery themes, and weather as a colour treatment.

**Status: sky, hours, a real lighting rig, and a start to the race.**

Two things light a circuit: a shadow-casting **key light**, which is what makes
floodlighting *even* the way a real circuit is; and **floodlight masts** — actual
fixtures at the verge on alternating sides, 21 m tall with lit headframes, each
throwing its cone about 50 m down the track so the pools land as long ellipses
that overlap end to end. A small emission floor on the road stops pure black
between them, the car's headlights sit below the key light, and ambient comes
*down*, because every unit of ambient is contrast the lights do not get to make.

Measured the way the renderer computes it — inside-the-cone, distance falloff
times angular falloff — **no point of the road is unlit and no point depends on a
single cone**, on every hour, on a circuit built from scratch.

> **The painted light pools are gone.** Flat additive discs on the tarmac,
> defended here for a long time as the graphic statement. What they looked like,
> said three times by the person playing it, was *yellow glow spots*. A disc of
> colour added to the road is not light: it does not move with the eye, it does
> not fall on the car, and its edge is a circle from every angle.

Seven ways this was wrong before, all written up in `docs/architecture.md`: lamps
anchored where their cones could not reach the road; spacing inherited from
scenery, leaving gaps no energy can fill; `spot_angle` read as a full angle when
it is the half-angle; `light_energy` compared between lights at different
distances; energies set with nothing to measure against, landing at 33x the
moonlight of the hour; and `surface_road` matching Kenney's shared `"road"`
material name across the whole scene, which re-surfaced buildings and made them
glow. Plus one that hid in a *measurement* rather than the code:
`look_at_from_position` silently does nothing outside the tree, and a circuit is
built detached. And one that showed up on the *car* rather than the circuit: the
sun and the key light both cast shadows, so every lit hour double-shadowed the
car and its wheels banded differently on every track.

**The race also has a start:** 3 - 2 - 1 - GO, a number in the middle of the
screen, with three gantry lamps lighting one at a time and turning green together.

The first attempt was a real Formula 1 sequence — five columns of two,
extinguishing together — and it was rejected on sight. It is the correct grammar
for a motor race and the wrong one here, because it asks you to *interpret*
lights: the signal is the moment they go out, which you only read if you already
know the rule. The number is the instruction; the lamps count *up* as it counts
down, so three lit means "about to go" without looking at the number at all.

The lights own the sequence, so a circuit without a gantry races immediately
rather than waiting on a node that is not there.

The car is **held on its brakes, not `freeze`d**. `freeze` takes a body out of the
simulation, so its suspension never compresses and unfreezing drops the whole car
onto its springs: every race start visibly dropped the car onto the track. Held
through the controller, the physics runs the whole time and the release moves
nothing.

**And HUD text is outlined.** The panels are translucent so as not to punch a hole
in the road, which means a near-white horizon came straight through them and the
lap time was unreadable at the moment it appeared.

---

## M17 — Surfaces, and tyre tracks

1. **A lateral coordinate on the ribbon** (`UV2` or vertex colour). Small, and the
   prerequisite for both racing-line rubber and the deformation texture. Worth
   doing on its own, first.

> **Done — but not on the tiles, and that is a correction worth keeping.** The
> road is Kenney tiles: shared cached meshes, one resource serving every instance
> of a piece, and `_reshape_tiles` only rebuilds the handful that are banked or
> lifted. Giving *those* a lateral coordinate would mean inlining every road mesh
> into every circuit, throwing away the sharing.
>
> So the coordinate lives on a **separate overlay ribbon** generated from the
> centreline, which has "how far along" and "how far across" by construction —
> and which is the dense visual ribbon step 3 was going to need anyway.
>
> **Racing-line rubber came with it**, baked into vertex colour from
> `ParTime.racing_line` — so the dark band on the tarmac is literally the line the
> lap estimate is computed on. One draw call, no texture, no per-frame work.
>
> One measurement while pinning it: the line departs the centreline by **at most
> about 2 m of the 6 it is allowed**. Relaxation converges on the
> *minimum-curvature* line and a point is held back by its neighbours staying put,
> so it is smoother than a truly optimal line and uses less of the road. A known
> limit of the model, not a bug — and the reason the racing line only shortened
> the lap by 1.8%.
2. **Surfaces per circuit** — snow and dirt as shader variants through the
   `surface_road` hook that already exists, each with its own grip sweep.

> **Built, as a race-time choice rather than a circuit property.** Racing a winter
> Ardennes is the same thing seen from the other side: the circuit does not
> change, the conditions do — and the record key has carried `surface` since M8
> for exactly this. Chosen beside the car on the title screen, so the same circuit
> in the same car on snow keeps its own record, ghost, splits, par and medal.
>
> The grip multiplier composes with the car rather than replacing it. Par follows
> it, so a snow lap is judged against a snow target.
>
> **Not done: the grip sweep.** The multipliers are stated, not measured — the
> same debt the Prototype carried. And braking does *not* degrade with the
> surface, because M2b established braking here is brake-limited rather than
> traction-limited; fixing that means scaling `brake_force` against a saturation
> ceiling that wants its own sweep. Both are in the tuning journal under M17.
3. **Tyre tracks**, in three steps: trail geometry, then a track-space deformation
   texture accumulating across laps, then real vertex displacement.

> **Marks are in, with real depth on the surfaces that should have it — and the
> depth is displaced material, not a carved hole.** That is forced rather than
> chosen: the road is Kenney tiles, so a rut pushed *downwards* is hidden behind
> the tile it lies on. **You cannot dig into geometry you do not own.**
>
> A tyre on something loose does not remove material, it pushes it aside — so on
> dirt and snow a mark is a shallow trough with a raised shoulder either side,
> built as real geometry with real normals and **lit**, so the sun catches one
> side of each ridge and not the other. Tarmac gets a flat, unshaded mark and only
> when the tyre *slides*: rubber is a film and displaces nothing, and a rubber
> mark standing proud of the road would be visibly wrong every time the light got
> low.
>
> **Marks last the whole session**, and that is affordable because a mark is
> claimed against a quantised patch of ground: a second pass deepens the mark
> already there rather than laying another beside it. Growth is bounded by
> distinct ground touched, not by session length — which is also what a rut really
> does. Chunked into 640-instance `MultiMesh`es because `buffer` can only be
> assigned whole, so the cost of a mark never depends on how many are already
> down.
>
> **They stop at the verge**, asked of the collision world — the drivable ribbon
> is a body in a known group — rather than of the centreline. Grass grips exactly
> like tarmac here, so nothing in the physics distinguishes on from off, and ruts
> across a field would advertise that marks are drawn by a rule rather than by a
> surface.
>
> **Carving properly is still ahead**, and it needs the drivable surface to *be*
> a dense generated ribbon that can be displaced in a vertex shader. The ribbon's
> coordinate system already exists from step 1; the road being made of it does
> not. That is the remaining half of step 3, and it is a milestone-sized change:
> the tiles' `road` surface would be hidden and replaced, with the painted lines
> and kerbs left on their own surface.

4. **Surfaces that look made of something.** Dirt and snow shipped as recolours of
   the tarmac shader and read as coloured card — they are surfaces *made of
   relief* and had none. The road shader now bends its normal with the same
   procedural height field it tints with, so the sun lights the near side of every
   clod and drift. `relief` is zero on tarmac deliberately: all three run one
   shader, and tarmac asking for no shape is what makes the other two feel like
   different materials. Snow adds `sparkle` — holes of low roughness rather than
   emitted light, so the glints are the real sun and vanish at night — and dirt
   adds loose stones. The condition also leaves the road: the outfield blends
   toward it, because a white circuit through a green summer field read as a
   painted road rather than as weather.

5. **The surface is switchable from the editor**, beside Test drive, because
   building a circuit and immediately driving it in the conditions you had in mind
   is the whole point. It sets the same global the title screen sets rather than
   becoming a property of the layout — the surface is a *condition*, which is why
   a lap record is keyed `track|car|surface`.

6. **Braking degrades on loose surfaces**, which it did not before and would
   never have started doing on its own. `VehicleBody3D` applies `brake` outside
   the friction model, so a surface that halved cornering left stopping distance
   *byte-identical*: 24.2 m from 100 km/h on tarmac, dirt and snow alike. The
   controller now scales the brakes, the handbrake and reverse by exactly the same
   grip figure the tyres get — 24.2 / 31.3 / 40.4 m — and `ParTime` scales
   `braking_g` to match, because par has to model the car actually being driven.
   Measured both ways round in the tuning journal.

   Acceleration was left alone at the time and has since been done the same way.
   It measured a **2% spread across a surface with half the grip** — 6.62 s to
   100 km/h on tarmac against 6.77 s on snow — because `wheel_friction_slip`
   limits how much of `engine_force` reaches the road far less than it looks, in
   exactly the way it never limited `brake`. Scaled by grip it is 6.85 / 9.95 /
   19.55 s, `ParTime` scales `launch_accel` to match, and par on the loose
   surfaces moved a long way. Snow being 2.9x slower to 100 is the figure to watch
   if it plays as too much penalty; it is one multiply.

The ribbon parameterisation is what makes step 3 tractable: a 4096 x 128 texture
covers a 1500 m lap. The world-space equivalent is unallocatable.

7. **Every surface has been swept**, which was the last piece of M17 that was
   asserted rather than measured. A steady-state skidpad puts real lateral g
   within 1–3 % of the `LATERAL_G x grip` the par model assumes on all three
   surfaces, so **a medal on snow is worth the same as a medal on tarmac** — that
   was the result that mattered. A provocation sweep answers the other open
   question: the car does *not* become uncatchable at 0.5 grip.

   It also produced one finding that reads backwards until you work it through:
   the car slides **less** on snow than on tarmac for the same handbrake pull
   (27° against 48°). A spin is generated by an imbalance between the ends of the
   car, and scaling both ends equally preserves the balance while shrinking the
   total yaw moment — the handbrake is a poorer weapon on a slippery road. What
   snow does deliver is slower recovery and half the cornering force, which is
   what a player actually feels. Figures in the tuning journal.

8. **Grass stops gripping like tarmac, and the barriers become solid.** These are
   one change, not two. Off the ribbon the car keeps `OFF_ROAD_GRIP` (0.55) of
   whatever the surface gives it — dry grass is 0.55 of dry tarmac, grass under
   snow is 0.55 of snow — and a penalty for leaving the road with nothing to stop
   you leaving it would just be a car sliding into four square kilometres of empty
   field. The barriers were switched off for exactly as long as leaving the road
   was free.

   The walls are **collision only** (the rails you see are already a `MultiMesh`
   of scenery) and are built on the **ribbon's own edge** from the same
   `_ribbon_point` the road collision uses. The old constant-offset version folded
   through itself on any corner tighter than its 9.8 m gap — a size-1 corner has a
   7 m radius — and put the inside wall on the tarmac.

   The road body now carries a collision layer of its own, and both the car and
   the tyre marks ask about it with a **masked ray**. Inspecting what an unmasked
   ray hit cannot work: the ribbon and the ground slab are both at exactly y = 0,
   and walking down through the hits reported road as field on 40 % of Suzuka
   because the same `Ground` body came back three times running.

**What this breaks, and it is real:** grass currently grips like tarmac, which is
what makes corner-cutting only *discouraged* by the ordered gates. Low-grip
surfaces change that, and that is when the barriers need collision.

---

## M18 — Identity, and a world in motion

*The point at which the game becomes recognisable at a glance, and stops being
still.*

M16 gave the circuit a sky, an hour and a real lighting rig; M17 gave the road a
material that varies. What neither gave it is **a signature** — something that
makes a screenshot identifiably this game and not any other Godot racer — or
**motion**, of which the circuit currently has exactly one source: the car.
Everything else in frame is nailed down. The trees do not move, the flags do not
move, the grandstands are empty, and the storm is a colour.

Both gaps are cheaper to close than anything in M19, and closing them is worth
more. That ordering was arrived at the wrong way round and is corrected below.

> **This milestone was originally "Made of something" — a Poly Haven PBR
> conversion — and was demoted to M19 before any of it was built.** The reasoning
> it was written under does not survive the standard the project is actually held
> to: largest visual improvement for the least complexity, and every decision
> reinforcing one coherent style.
>
> A PBR texture pass fails both. **It is the most generic move available**:
> photoreal asphalt and triplanar concrete are what every asset-store racer is
> made of, and adopting them spends the one thing this game has — a committed
> flat-shaded look — to buy something anyone can buy. And its heaviest step,
> texturing the kit and lighting the ground plane, invalidates the floodlight rig
> that took three wrong versions to get right, in exchange for barriers that are
> beige instead of white.
>
> Meanwhile a wind shader is fifteen lines and makes an entire forest move. **The
> cheap work and the identity-forming work turned out to be the same work.**
> Realism is not the axis this game gets better along.

**Status: steps 1–4 done — the grading system, all six looks authored, the
scenery moving, and the car feeling fast.**

1. **A colour grade per look, as a real LUT.** `CircuitLook` already pairs an hour
   with a place; it gains a third thing, and that thing is the signature.

> **Done, as ASC CDL.** Per-channel slope, offset and power, then saturation —
> the film industry's colour decision list rather than anything invented here, and
> four parameters is exactly enough. Cool shadows against warm highlights turns
> out to need no dedicated parameters at all: it *is* an offset that crushes red
> and a slope that lifts it.
>
> **The migration is exact and the suite proves it.** Godot's
> brightness-then-contrast arithmetic rearranges into a slope and an offset, so a
> look nobody has art-directed renders pixel-identical to how it did when the
> grade was three `Environment` scalars. That is what allowed the grading system
> and the art direction to change in one commit — and then the remaining four
> looks to be graded in the next, against a baseline that had provably not moved.
>
> **All six are authored.** The full write-up, including the two traps the suite
> caught and what tuning them by eye taught, is in `docs/architecture.md` under
> "The colour grade".
>
> **Not done: the palette consolidation.** Ground colour still lives in
> `SceneryTheme`, sky and fog in `SkyPreset`, road in `RoadSurface`, and none of
> the three consults the others. Deliberately left out of this step — it is a
> refactor with no visual output, and mixing it into the change that carried a
> provable migration would have made both harder to review. It is now the thing
> most visibly holding the looks back: `evening`'s ground stays a flat olive under
> a sunset sky because `SceneryTheme` picked it without knowing what hour it is.

2. **The remaining four looks, art-directed.** `evening`, `dusk`, `storm` and
   `overcast` off the derived fallback and into `GRADES`.

> **Done, and the six do not all take the same shape.** Four hours have a sun in
> them and split their tones; `storm` is cold at both ends because a storm has no
> warm light in it; `overcast` **lifts its shadows with a positive offset**, which
> is the one grade here the three scalars could not have expressed at all.
>
> **Grading survives the Compatibility renderer, and that is now checked rather
> than assumed** — the same frames rendered under `--rendering-method
> gl_compatibility` land within one or two of 255 of the Forward+ versions. This
> was the open risk of step 1: if the table had not been sampled on the web
> renderer, most of this milestone would have needed rethinking.

> `ideas.md` left this open — "a global saturation push, or a hand-authored LUT
> per circuit? The second is much stronger and is also the point at which someone
> has to art-direct three separate looks." It is answered here: **the LUT**, and
> the art direction is the deliverable rather than the obstacle.
>
> Grading is what makes *art of rally*, *Hotshot Racing* and *Horizon Chase* each
> recognisable in one frame, and none of them is doing it with fidelity. It is
> also nearly free: `Environment.adjustment_color_correction` takes a `Texture3D`,
> the environment is already built per circuit in `_build_environment`, and the
> three `adjustment_*` scalars in use today are the weak version of the same idea.
>
> **It works on the web build**, which is the fact that makes it the first step
> rather than a desktop luxury. `Adjustments` are supported under Compatibility.
>
> The palette question comes with it. Ground colour lives in `SceneryTheme`, sky
> and fog in `SkyPreset`, road in `RoadSurface` — three files that each pick
> colours without reference to the other two, which is why a circuit reads as
> assembled rather than authored. A look should **own a palette** those three draw
> from.

3. **Wind.** One vertex shader, applied to trees, flags, banners and the roadside
   grass, phase driven by world position so nothing moves in lockstep.

> **Done, on the trees and the roadside marker flags.** The highest ratio of
> *alive* to *complexity* in the project, as expected: no CPU cost, no per-frame
> script, no new nodes, and verified working under Compatibility. It survives the
> trees being `MultiMesh` because the phase comes from `MODEL_MATRIX[3]` — where
> the instance stands — which is the only per-instance identity a `MultiMesh`
> vertex has.
>
> A static tree reads as a prop. A tree that moves reads as a place.
>
> **Not done: banner towers and roadside grass.** The banner towers are the two
> props at the start line, and they go in through `_place_prop`, which instances
> the GLB scene directly — so putting them in the wind means either mutating a
> shared imported resource or a property override on an instanced sub-scene's
> internal node, and the second is the exact shape of a trap already recorded
> here. It wants a per-instance mesh duplication of its own and is a separate
> change. **Roadside grass does not exist**: the kit's entire vegetation list is
> `treeLarge` and `treeSmall`, so there is no grass prop to move. The roadmap line
> above was written without checking, and it is left as written with this note
> rather than quietly narrowed.
>
> The full write-up — the `MultiMesh` phase, `world_vertex_coords`, and the two
> traps this hit — is in `docs/architecture.md` under "Wind, and the two things it
> has to survive".

4. **Speed you can feel.** Camera shake that rises with speed and with surface,
   a screen-space speed effect at the frame edges, and roadside density that
   streams.

> **Shake is done, and it is a rotation.** It lives in `CarTuning` beside the FOV
> kick that was already there, for the same reason the framing does: it is part of
> how a car feels, not a property of the scene. Quadratic in speed where the kick
> is linear, multiplied by how loose the surface is, and yaw and pitch only — the
> horizon is never rolled.
>
> It was built as a *translation* first and that is the finding worth keeping: a
> translation of `d` moves an object at distance `z` by `d/z`, so shaking the
> camera's position shakes only what is nearest it. Measured, a 0.05 m shake slid
> the car eight pixels and moved the horizon by a tenth of one. That is a loose
> wheel, not a fast camera. The measurements, and the frame-rate ceiling the
> waveform has to live inside, are in `docs/tuning-journal.md` under M18.
>
> **Roadside density needed nothing.** "Density is speed" was already built —
> `_scenery_markers` places a flag every 10.5 to 15.4 m down both verges, by
> theme, and the lighting columns and floodlight masts are on top of that. Counted
> at 165 km/h: 6.0 to 8.7 markers a second, 7.9 to 13 pieces of roadside furniture
> a second, 12 to 17 with the trees. The builder's own comment claimed "about
> twenty a second" and had never been true; it now carries the measured figures,
> which is what a later argument about pace should start from.
>
> **The frame edges streak, and they are not a blur.** A radial blur is the
> obvious reading and it fails both halves of the standard this milestone was
> reordered under: a full-screen pass sampling the screen texture on a
> single-threaded WebGL 2 build, and it smears the crisp flat silhouettes that
> are the whole identity. It buys a frame that could have come from any engine —
> the same argument that moved the PBR pass to M19. What shipped is drawn
> streaks: a few dozen `draw_line` calls at the edge of the frame, flying
> outward, no shader and no screen texture.
>
> The one thing no amount of reasoning would have found is that **the colour has
> to come from the surface**. White streaks on a snow circuit — a white road
> under a white outfield under a pale sky — are not there at all, at any opacity.
> Rendering it on snow is what found it.
>
> **Step 4 is done.** All three of what the game does to say *fast* now scale
> against the same `camera_fov_reference_kmh`, so a quicker car is quicker in the
> framing, in the shake and at the edges of the frame at once.

5. **Particles, from data the game already has.** Tyre spray, dust and grass
   clippings off the wheels; colour and behaviour taken from `RoadSurface`.

> `RoadSurface` already answers this question for a different consumer:
> `mark_always` says whether a tyre displaces material by rolling, `mark` says
> what colour that material is. A dust plume on dirt, a snow rooster tail, and
> nothing on dry tarmac until the tyre slides — that is the existing table, read
> by something new.
>
> **`CPUParticles3D` on web.** `GPUParticles3D` under Compatibility throws WebGL
> errors with a *View Depth* draw order, and particle trails and SDF collision are
> unsupported there anyway. This is a case where the constrained path is also the
> simple one.

6. **Weather that does something.** `storm` is currently an hour with a grey
   grade. It becomes rain: a screen-space droplet layer, spray thrown from the
   wheels, and a wet road — which is a **roughness change**, not a new shader.

> Wet tarmac is the one place realism pays here, because a low-roughness road
> reflecting a bright sky is a dramatic image rather than a faithful one. It also
> composes with what exists: `RoadSurface` already carries `roughness` per
> surface, and `sparkle` already proved that punching roughness holes and letting
> the real sun answer beats drawing the highlight.

7. **The grandstands are empty, and that reads as abandoned.** Billboard
   spectators with a shimmer, and marshal posts with flags.

> Environmental storytelling, and the cheapest kind: an impostor crowd is a
> textured quad per spectator with two frames of animation, a technique older than
> the renderer it runs on. The grandstands are already placed and already lit. A
> full stand is the difference between a race and a test session.

8. **Boards that make the circuit readable.** Braking markers, apex markers and
   corner numbering, placed from the centreline the way everything trackside
   already is.

> Real circuits carry these because they *work* — a driver reads distance-to-apex
> off them — so they are the rare piece of set dressing that improves play and
> authenticity with one asset. Placement is a function of `Compiled.corners`,
> which the builder already has.

**Deliberately not here: live time-of-day transition.** It was asked for and it
does not fit yet. `SkyPreset` is discrete presets resolved at *build* time, with
`road_glow` and `headlights` baked onto the packed scene as metadata; a
transition means interpolating whole presets at runtime and re-driving the light
rig every frame, including which of two directional lights casts the shadow. That
is a milestone, not a step, and it wants the presets to be interpolatable first.
The cheap version — a race that starts at dusk and finishes at night — is
reachable once step 1 makes a look own its palette.

---

## M19 — Made of something

*Materials, scoped to what a stylised game can actually use.*

Everything M18 does is achieved without a texture. This is where the textures
come in, and the scope is deliberately much smaller than the version that was
first written: **the two steps with a clear payoff, and not the two without one.**

Assets are **Poly Haven** — CC0, roughly 980 HDRIs and 780 texture sets, no
attribution required.

> **Poly Haven has no racing geometry, and never will.** The model library is
> Props, Furniture, Decorative, Industrial, Appliances, Nature, Electronics,
> Tools, Lighting — about 520 assets, none of them a grandstand, a barrier, a
> kerb, a gantry, a tyre stack or a car. So "use Poly Haven throughout" cannot
> mean replacing the Kenney kit; there is nothing to replace it with short of
> modelling it, which is a different project in a different discipline.
>
> The kit keeps its silhouettes. What Poly Haven supplies is **light and
> surface detail** — and, in Nature and Industrial, the props that make a scenery
> theme more than a tint.

1. **The asset pipeline, before any asset.** A committed manifest of Poly Haven
   ids and resolutions, plus `tools/fetch_assets.gd` against their public API,
   downloading into a gitignored directory. Only the **downsized derivatives the
   game actually ships** are committed.

> The same split the project makes everywhere else: `tools/` generates, the
> generated artifact is committed, and the game never depends on `tools/` at
> runtime. The 4 K source is a builder's input and does not belong in the history
> any more than a `.blend` would.
>
> **The budget is enforced by the suite, not by discipline.** 2 K desktop, 1 K
> web, ORM-packed, VRAM-compressed. Godot will not downscale per platform on its
> own, and a budget that lives only in a document erodes exactly the way the
> `[rendering]` section of `project.godot` has twice.

2. **Image-based lighting.** The HDRI becomes the radiance and reflection source;
   `SkyPreset` keeps its hours but rebalances ambient against real irradiance.

> `track_builder.gd:2127-2131` sets `ambient_light_source` to a flat colour and
> `reflected_light_source` to `DISABLED`, with stated reasons: sky irradiance
> turned the almost entirely white kit **frankly blue**, and sky reflections on
> roughness-1 materials cost a lot and changed nothing. Both are artefacts of
> there being no materials and no varying roughness — and M18's wet road supplies
> the second.
>
> **The sky shader stays as the visible background.** The banded gradient and the
> oversized sun are the graphic statement and they were tuned; the HDRI is wanted
> for its *light*, not its picture. Whether the two agree at every hour is the
> open question of this step, and if they cannot, authoring HDRIs *from* the sky
> shader is the fallback — cheaper, and it keeps the identity.

3. **A detail pass on the road, on the ribbon rather than the tiles.** A normal
   and roughness map on the overlay ribbon, at low contrast. **Detail, not
   realism**: enough to break up forty per cent of the frame being dead flat, not
   enough to turn the road photographic while the barrier beside it is a flat
   white box.

> **The UV problem is already solved and it was solved for something else.**
> `tarmac.gdshader` generates its grain from world position precisely because road
> UVs are inherited from tiles of three different lengths, so a sampled texture
> seams at every join. That stays true of the tiles.
>
> The overlay ribbon from M17 has "how far along" and "how far across" **by
> construction**. It is the only surface on the circuit with a UV set worth
> sampling, so it is where this goes.

4. **Scenery themes with a real prop table.** `SceneryTheme` says a theme is "a
   colour palette plus a prop table" and admits the table is thin — two pieces of
   vegetation, so a theme varies colour and density and nothing else. Nature and
   Industrial are the one place Poly Haven's *models* are usable here.

**Cut, and here is why.** *Triplanar PBR across the whole kit* and *a lit ground
plane* were steps 4 and 5 of the original M18. They are the most expensive work in
the milestone, they invalidate every measurement behind the floodlight rig — the
field going dark at night is a *consequence* of the ground plane being `unshaded`
— and what they buy is a kit that looks like everyone else's. If the flat kit ever
becomes the thing holding a frame back, it comes back as its own milestone with
that case made properly. It is not the thing holding the frame back today.

> **And one correction that changes the tiering.** The original step 5 proposed
> SSAO as a desktop-only luxury. **SSAO is supported under Compatibility** — it is
> volumetric fog, SSIL, SDFGI and depth of field that are not. So contact shadows
> are available to the web build, which is where they matter most: a flat-shaded
> kit has very little to ground its objects to the floor, and ambient occlusion is
> exactly the cue it is missing. Verified against the Godot renderer support
> matrix rather than assumed.

**What this breaks, and it is real:** the download. Every texture lands in the
same `.pck` that has to arrive in a browser, single-threaded, from GitHub Pages.
This is the first milestone whose primary cost is bytes rather than frames, and
the budget in step 1 is what decides whether it ships.

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
