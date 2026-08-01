# Architecture

How the project is put together and, more usefully, *why*. Handling numbers and
the measurements behind them live in [`tuning-journal.md`](tuning-journal.md).

## Shape of the project

```
scenes/     title.tscn selects a track, race.tscn runs one, editor/ builds one
scripts/    behaviour, mirroring scenes/ (car, camera, track, ui)
resources/  CarTuning + its presets
tools/      headless generators that write scenes/ (not used at runtime)
tests/      headless test suite, gates CI
assets/     Kenney CC0 art, one shader
user://     tracks/*.json - circuits the player built
```

## Four decisions that shape everything else

### 1. Feel lives in a resource, not in nodes

Every handling parameter is on `CarTuning` (`resources/tuning/car_tuning.gd`) —
drivetrain, grip, steering, suspension, stability, and camera framing.
`car.tscn` holds only *geometry*: wheel positions, radius, which wheels steer or
drive. The controller applies the resource to the wheels in `_ready()`.

Camera parameters live there too, deliberately: chase distance and FOV kick are
a large part of perceived speed, so swapping a feel preset should swap how the
car is framed.

Godot only serialises properties that differ from a script's defaults, so the
**defaults are the grippy baseline**, `grippy.tres` is intentionally empty, and
every other preset stores only its deltas. `drifty.tres` is four lines, and
those four lines are exactly what makes it drifty.

### 2. Collision is generated, never taken from the art

The road surface is a ribbon of quads built along the circuit centreline and
used as one `ConcavePolygonShape3D`. It is not derived from the Kenney tile
meshes.

Tiles snapped end to end have micro-seams, and `VehicleBody3D` uses raycast
wheels that catch on them. A generated ribbon is seamless by construction, and
once the track gained elevation it was the only option anyway — the flat ground
plane underneath is just grass now.

> `ConcavePolygonShape3D` is one-sided by default. With the wrong triangle
> winding the car silently falls through raised sections, so the shape sets
> `backface_collision = true`. `tests/run_tests.gd` raycasts down at every
> checkpoint to keep that fixed.

### Trackside scenery, and why it is not laid out of kit pieces

Everything beside the road — the barriers, the lighting columns, the trees, the
paddock — is placed by `TrackBuilder` from the centreline it has just walked, and
none of it has collision. That last part is not an oversight: `car_controller`
casts a ray straight down to find the road's normal, and anything solid the car
could end up over would eventually be read as a piece of very steep banking.

Three things were learned building it.

**Props must be checked against the whole loop, not the leg they came from.**
A fixed offset from the current leg is not enough. The circuits are laid on a
grid and double back on themselves — two legs of Ardennes run a couple of tiles
apart — so a grandstand set beside the pit straight lands squarely on the back
straight, and trees grow out of the tarmac. Each candidate is tested against a
bucketed copy of the centreline, at a clearance just inside the gap its prop is
placed at, so a prop is only ever rejected by a *different* piece of road than
its own. A prop that does not fit is skipped rather than moved, on the same
principle the elevation system follows: reduce the request, do not refuse it.

**The barrier is swept, not repeated.** Kenney's `rail` is a straight one-unit
plank; repeated round a corner it chords across the arc, kinking and gapping at
every join so it reads as a line of fence panels. It is generated instead, as a
continuous strip along the centreline offset — the same technique as the
collision ribbon, and for the same reason. The centreline carries a point every
2.8 m for the sake of bank and ramp profiles, which is far more than a wall
needs, so the strip keeps only the points where the road turns, climbs, or has
run straight for long enough.

**The kit's scale and the car's scale disagree, and the car wins near the road.**
Kenney draws to its own proportions: a road tile is one unit and its cars about
0.55 of one. This project stretches the tile to 14 m for a realistic road width
while the car stays at its model's own 2.56 m, which leaves anything placed at
tile scale roughly four times too big beside it. The kit rail came out 2.24 m
tall next to a car 0.63 m high — not a barrier, a wall. So props the car passes
close to are sized against the *car*, and distant scenery keeps tile scale,
because a grandstand is meant to tower and shrinking it would make the circuit a
model village.

> **A `MultiMesh` built under `--headless` silently loses its instances.**
> `set_instance_transform` writes through the RenderingServer and reads back out
> of it, and under `--headless` that server is a stub which stores nothing. The
> shipped circuits baked with the right instance *count* and an empty buffer, so
> all two hundred barrier segments sat at the origin and the tracks looked
> exactly as bare as before the scenery existed — with no error anywhere.
> `_instance_buffer` packs the transforms by hand and assigns `buffer` directly,
> which is ordinary resource state and survives. `custom_aabb` is set the same
> way and for the same reason: bounds computed by that server come back empty,
> and empty bounds mean everything is frustum-culled.

> **A surface override on an instanced tile does not survive `pack`.** The road
> is re-surfaced as tarmac by material override, and when that was done inside
> `build` it baked onto only the handful of tiles `_reshape_tiles` had already
> rebuilt into ordinary nodes — a road that changed colour at every banked
> corner. `TrackBuilder.surface_road` is therefore static and called by `race.gd`
> on whatever track it is about to show, which sidesteps serialisation and treats
> a shipped circuit and a player's identically.

### 3. One builder serves the tool and the game

`TrackBuilder` (`scripts/track/track_builder.gd`) is the only code that turns a
layout into a circuit. `tools/build_track.gd` calls it to bake the three shipped
tracks into committed `.tscn` files; `race.gd` calls it at runtime to build a
player-made track, which has no scene file at all.

So a custom circuit is not a lesser thing than Ardennes — same collision ribbon,
same sixteen ordered gates, same spawn rule — and there is only one
implementation to test.

`build(..., with_geometry = false)`, exposed as `measure()`, walks a layout doing
the arithmetic but instancing no tiles. The editor recompiles on every mouse
move and the menu measures every custom track it lists; neither could afford to
instance a few hundred GLBs to find out how long a lap is.

### 4. Scenes are generated by committed tools

Both circuits, `scenes/ui/hud.tscn`, `scenes/title.tscn` and `scenes/race.tscn`
are produced by scripts in `tools/`. The generated `.tscn` files are committed,
so the game never depends on the tools at runtime — but a circuit is *described*
by a layout spec rather than hand-placed, and rebuilding is one command.

`race.tscn` in particular must be regenerated rather than hand-edited: instance
overrides in a scene silently beat values in the sub-scene it instances, which
once left a corrected `center_of_mass` inactive in the running game while every
diagnostic (which loaded `car.tscn` directly) reported it fixed.

> A second `PackedScene` trap, found the same way: set `owner` on nodes you
> created and on instanced sub-scene *roots*, but never on an instance's
> internal nodes. Those then serialise on top of the instance and everything
> appears twice — it shipped a car with eight wheels and two of every road tile,
> and inflated each track file threefold. Only a node count reveals it.

## Flow

`title.tscn` lists `GameState.all_tracks()` and records the choice in a static
var, which survives the scene change. Custom circuits get an **Edit** button
beside them, which sets `GameState.editing_id` and opens the editor on that
track. It stays live even when the circuit is too broken to drive — that row's
main button is disabled, so Edit is the only way back in and must not be gated on
the same condition. `race.tscn` holds everything a race needs
*except* the track; `race.gd` instances the selected circuit, drops the car on
its `SpawnPoint`, and tells the lap tracker which record to use. One race scene
therefore serves every circuit, and adding a track means adding a layout and a
list entry.

Lap records are keyed per track, so a quick time on one circuit cannot look like
a record on another. `GameState.records_path` is overridable so the test suite
writes somewhere disposable instead of into the player's saves.

## The car

`VehicleBody3D` with four `VehicleWheel3D`. Fronts steer, rears drive.
`car.tscn` is generated by `tools/build_car.gd` from `race.glb` and committed,
like every other scene here.

> **The whole car rendered flat white for most of this project's life,** and it
> was an asset-vendoring mistake rather than a material one. Kenney's car kit
> paints every model from one shared 512x512 palette atlas, which the `.glb`
> files reference as an *external* file — and only the `.glb` files were copied
> into `assets/`. With the texture missing, the material fell back to untextured
> white: bodywork, glass and tyres all the same shade. `Textures/colormap.png` is
> now vendored alongside the models. Note that it is not enough to drop the file
> in — Godot keys reimport off a content hash, not a timestamp, so the `.glb`
> import cache has to be cleared before the material picks the texture up.
>
> The scene could not simply be pointed at the texture either. It had been built
> by hand with the meshes baked in, and the bake had dropped the UVs from all
> four wheel meshes, so they would have sampled one corner of the atlas whatever
> the material said. That is why there is now a builder for it.

Two things it does that the node does not do for you:

- **Aerodynamic drag**, applied as a central force scaling with speed squared.
  This sets top speed (where engine force balances it) and makes acceleration
  taper instead of climbing linearly forever.
- **A virtual anti-roll bar**, a restoring torque about the car's forward axis
  from signed roll angle and roll rate. `VehicleBody3D` has no roll stiffness,
  so without it quick steering reversals put the car on two wheels.

Braking is deliberately kept *below* the point where `VehicleBody3D.brake`
saturates (~150). Above that, stopping is limited by tyre grip rather than brake
force, which reads as an instant jolt — and it means grip can be tuned purely
for cornering without touching how braking feels.

## Input, and two traps in the input map

`ui_accept` and `ui_cancel` are **overridden here purely to add a gamepad
button** (A and B). Godot's defaults for those two are keyboard-only — unlike
`ui_up`/`ui_down`/`ui_left`/`ui_right`, which do ship with D-pad and left-stick
bindings. That asymmetry is the whole reason a controller could move the
track-select highlight but never actually choose a track, which in turn made the
pad look completely dead when it was not. Overriding an action replaces the
default outright, so both overrides also restate the keys (Enter/Kp Enter/Space,
Escape); dropping one of those from the list is how you silently lose a keyboard
binding.

Every joypad event is bound to **device `-1`** (all devices) rather than a
concrete index. `InputMap` matches an event only when the binding's device is
`-1` or an exact match, so `device 0` covers just the *first* pad the OS
enumerates. This was hardening, not a bug fix — a Bluetooth pad measured on macOS
did enumerate at index 0 and its `device 0` bindings matched correctly. But a pad
that sleeps and reconnects can come back on a different index, and there is no
reason a one-player game should care which index it got.

Neither fact can be recorded in `project.godot` itself — Godot rewrites that file
on its own schedule and deletes `;` comments. Both are asserted by the suite
instead: `test_joypad_bindings_take_any_device` walks the whole `InputMap`, so an
action added later cannot quietly reintroduce a concrete device index.

### Analogue pedals, and why they are a setting

Throttle and brake read `Input.get_action_strength`, so a gamepad trigger's
travel reaches `engine_force` and `brake`. It previously went through
`is_action_pressed` and was **discarded entirely** — every device in the game had
exactly two throttle positions.

It is a **player setting** (`GameState.analogue_input`, on the pause menu)
because the brief genuinely pulls both ways: the look is Horizon Chase, which is
arcade and binary, while the mode is Forza's time attack, where lifting a
fraction out of a hairpin is the skill being measured. Rather than guess which
half wins, both are offered.

Three things follow, and each is a decision rather than an oversight:

- **The handbrake stays binary in both modes.** It is bound to a face button, so
  there is no analogue source to read. Routing it through `get_action_strength`
  would return 1.0 dressed up as a measurement.
- **Keyboard and touch are unaffected by the setting.** Both report full strength
  when held, so they take the same path either way. That is what makes the change
  safe: every figure in the tuning journal was measured through one of those two,
  at full lock, and none of them moved.
- **Records are not keyed on the setting**, although they are keyed on car and
  surface. Analogue is a strict superset of binary — a full press is 1.0, so
  anything driveable in binary is driveable in analogue — which means a
  binary-mode record stays an honest target. The converse does not hold, and a
  binary-mode player may meet a time they cannot match. That is a real cost of
  offering the choice, accepted rather than missed.

The steering curve added alongside it (`CarTuning.steer_response_curve`) is an
**odd power**, so it fixes -1, 0 and 1. A keyboard and a touch pad ask for
nothing but those three, so the curve reaches sticks only. That is both its
purpose and the reason it invalidated no existing measurement.

### Leaving a race

`ui_cancel` used to change scene the instant it was pressed. That is fine on a
keyboard, where Escape is a deliberate reach; it is wrong on a pad, where B sits
under the thumb, and it did not exist at all on a phone, which had **no way out
of a race** short of reloading the page. One mis-press threw away the lap being
driven.

All three routes now arrive at the same pause menu and leaving is the second
press. The way *in* differs per device because the devices differ — `pause`
(Escape, and the pad's Start), plus an on-screen button shown on the same rule as
the driving pads, since the other two routes are physical — but nothing after
that does.

`pause` and `ui_cancel` are both read in `pause_menu.gd`, in one handler, in that
order. Escape fires **both actions from a single event**, so splitting them
across two handlers toggles twice and leaves the menu exactly as it was found.

The whole tree pauses rather than just the car: `lap_tracker` accumulates in
`_physics_process`, so a menu that did not pause would quietly add the time spent
reading it to the lap. That makes two things load-bearing — the menu is
`PROCESS_MODE_ALWAYS`, because a paused menu cannot unpause itself, and leaving
unpauses first, because `paused` belongs to the tree rather than the scene and
would otherwise carry the freeze into the title screen. Pausing also releases the
touch pads: a synthesised press is held until something sends the matching
release, and the pads stop getting events the moment the tree stops.

### Tunnels are covered, not buried

Monte Carlo is roofed out of Portier, which is where Monaco's tunnel actually is.
The kit has **no tunnel art of any kind**, so the shell is generated and swept
along the centreline the way the barrier is — a wall down each side and a roof
across the top.

It is expressed as a **road piece** (`roadStraightTunnel`,
`roadStraightLongTunnel`) rather than as a separate list of arc ranges, because
that is how everything else about a circuit is written: a layout says what road
goes where, and a tunnel is a kind of road. It also means the shell cannot drift
out of step with the tiles beneath it, which a hand-written range of metres
would. Those pieces carry a `model` key pointing at the plain straight's `.glb`,
since there is no tunnel tile to point at.

**No collision**, like all scenery. `car_controller` finds which way is up by
casting a ray downwards and treating whatever it hits as the road it is standing
on, so a solid roof would be read as a surface the car was resting against. The
roof does cast a *shadow*, which is most of what sells it — the tarmac goes dark
on the way in and comes back on the way out with nothing lit or unlit specially.

> **Genuinely underground road is out of reach, and it is worth writing down
> why so nobody re-derives it.** Three separate blockers, each independent:
>
> - **No art.** There is no tunnel, arch, underpass or portal piece in the kit.
> - **The ground is solid.** `_build_ground` lays a 4000 x 1 x 4000 collision box
>   whose *top face is y = 0*. Anything below ground is inside it, so the car
>   would rest on the field rather than on the road.
> - **Elevation cannot go negative.** Levels are clamped to `[0, MAX_LEVEL]`
>   throughout `TrackLayout`, so "below the ground plane" is not expressible.
>
> A real tunnel therefore needs a hole in both the ground mesh and its collider,
> a signed elevation level, and geometry — a milestone, not a feature.

### Drawing a crossing, and the trap in it

The **Cross** toggle in the editor's tool row sets `TrackLayout.allow_crossings`
per circuit. Off by default because it gives up the editor's strongest guarantee:
with it off no drag can produce a shape that will not build.

The compiler then refuses a crossing with less than
`CROSSING_CLEARANCE_LEVELS` (two) between the legs — a measurement, since
`roadStraightBridge` carries exactly one level of structure below its deck.

> **The start straight reports no headroom, and that was a bug worth recording.**
> `_resolve_elevation` pins run zero to the ground so the lap's height closes,
> but `_measure_headroom` probed without accounting for it and advertised two or
> three levels the run would never be given. The editor believed the number:
> clicking the elevation badge on the start straight flashed "held at +2", the
> resolver put it straight back to zero, and nothing changed.
>
> Harmless on an ordinary circuit — nobody misses a climb they did not plan — and
> the reason a crossing could not be made to validate. **Half the time, the leg
> you are told to raise is the one that silently refuses to rise**, and the
> editor gave no sign which half you were in.

> **And the fix was hidden behind the problem.** The canvas drew and hit-tested
> its badges only when `compiled.ok`, and `compile` returned early on a crossing
> error before filling `segments`, `cycle` and `to_grid`. So a circuit refused
> for a crossing showed "raise one side" beside a canvas with **nothing on it to
> press** — the one failure a player fixes by clicking the circuit was the one
> where clicking was switched off.
>
> Two changes. `compile` no longer bails on a crossing error: it finishes, fills
> the geometry and leaves `ok` false, which is enough for the title screen and
> Test drive to keep refusing it. And the canvas gates on
> `Compiled.has_structure()` — corners and segments exist — rather than on `ok`.
> Failures earlier than that (loose ends, junctions, a shape that is not a ring)
> return before any structure is built, so they still get a bare canvas, which is
> right: there is nothing meaningful to decorate yet.

Three things follow from that, and all three are about the failure being
*actionable* rather than merely correct:

- The readout says what is wrong; the **guide card says which control fixes it**
  — click the faint dot in the middle of the straight that should go over, twice,
  and not the one carrying the start line. A correct diagnosis with nowhere to
  click is why this was first reported as unintuitive rather than as broken.
- Clicking to `+1` on a crossing leg says **"one more to clear the crossing"**.
  Reporting only "held at +1" reads as success while the circuit is still
  refused, and doing as you were told and being told no again is where people
  stop.
- Clicking the start straight now explains that it stays down so the lap's
  height closes, rather than reusing the "too short for a climb" message, which
  was not true and suggested the wrong remedy.

### Closed is not the same as simple

`BuildResult.closed` used to mean "the walk returned to its start **and**
`absi(turn_total) == 4`". Those are two different claims bolted together: the
first is "it joins up", the second is "it joins up without ever crossing itself".

A figure of eight fails the second and satisfies the first perfectly — one half
turns right, the other turns left, and the quarter-turns cancel to **zero**. So
`closed` now checks position, height and heading (heading returns exactly when
the turn total is a multiple of four), and the stronger claim lives on as
`simple`.

`simple` is still what every *painted* circuit must satisfy: `TrackShape` only
permits a crossing when it is asked to, and nothing asks it to yet.

**Suzuka** (`tools/build_track.gd`) is the shipped circuit that exercises this —
a rectilinear figure of eight, 991 m, where the back half bridges over the front
half. It is authored as a segment list, so it reaches the builder without going
through `TrackShape` at all, which is why it exists before the painted-crossing
work is finished.

Two things about it are measurements rather than choices:

- **The bridge is at level two, not one.** `roadStraightBridge` carries 0.5 tile
  units of structure below its deck, which is exactly one level. At level one it
  stands on the ground — fine for a crest, useless here, because the ground is
  where the other half of the lap is. At level two the deck sits 7 m up with
  3.5 m of clear air beneath. The supports stop short of the ground rather than
  punching through the road below, which is the honest limit of a tile set never
  drawn for this.
- **The elevated section is three cells, not the whole straight.** Every elevated
  cell is a cell of bridge with nothing under it, so short reads as a bridge and
  long would read as a viaduct on stilts that stop early.

A scripted driver completes laps of it in ~33 s, moving between −0.04 m and
7.80 m — under the bridge on the way out, over it on the way back.

## The track builder

`tools/build_track.gd` walks a layout spec, carrying a position, a heading and a
height.

Kenney tiles sit on a 1-unit grid with off-centre origins. Each piece is
described by its cell size, origin shift, connection points, connection heights
and (for corners) its arc centre. Placement searches the four yaw angles and
both travel directions for the orientation whose entry edge faces against travel
and whose exit gives the wanted heading.

Height falls out of the same mechanism: a piece's rise is
`conn_y[exit] - conn_y[entry]`, so one ramp mesh climbs or descends depending
only on which end is entered.

The builder reports a **closure gap** per track, which must be `(0, 0)` with net
±4 turns and height back to 0. `build_track.gd` exits non-zero if any track
fails, so a layout that does not close cannot be shipped silently.

Adding a shipped circuit is a layout constant plus an entry in
`GameState.TRACKS`. Three things about writing that constant are not visible
from the grammar:

- **Solve the outline, not the straight counts.** A leg of the rectilinear
  outline spans `straight_cells + N_in + N_out - 1` tile units, where N is the
  size of the corner at either end. Choose the outline in whole units and the
  straight counts fall out of it, with closure as two sums — one per axis —
  rather than as trial and error.
- **Closure does not mean the road misses itself.** A layout can close perfectly
  with one straight driven over another; nothing in the builder objects, and it
  is not visible in the closure line. Check the outline for legs that cross or
  run within a tile width of each other. Some corner *orders* have no
  non-crossing solution at any leg length — five same-handed corners in a row
  make a peninsula the next straight has to cross back over, which is what
  reordered Monte Carlo into a pair of staircases.
- **Climb one level and come back down inside the same straight.**
  `roadStraightBridge` carries 0.5 tile units of structure below its deck, so at
  level 1 it stands on the ground and at level 2 it floats 3.5 m above it. The
  bridge *corners* are deck-only pieces with no structure at all. Sustained
  elevated sections through corners are an editor feature; the shipped circuits
  keep their corners on the ground.

### Banked corners

The centreline carries a **roll angle per point** as well as a position, and
everything about banking follows from that one array.

Bank is a **per-corner choice, and corners are flat until someone makes one
otherwise** — in the editor and in a hand-written layout alike. A layout ends a
corner with an angle in degrees, `["C", piece, turn, 4.0]`; without one the corner
is flat, so "said nothing" and "said zero" mean the same thing.

Nothing infers banking from anything. There was a radius-derived default at first
and it was wrong in the way silent defaults usually are: banking changes how a
circuit drives, so a track that leaned everywhere the moment it was painted was
one its author had to notice and undo. The angles *suggested* when someone does
ask still run up with radius — a sweeper is the corner taken fastest and the only
one with enough road either side to ease the roll in and out of, while a hairpin
banked hard is a skate bowl whose tilt arrives in a car length — but they are a
suggestion in the editor's cycle order, not a value anything applies on its own.

The shipped circuits show both answers, and all three say so out loud:
**Ardennes** and **La Sarthe** write 2.5° on their medium corners and 4° on their
sweepers, **Monte Carlo** writes `0.0` on every one of its fourteen and does not
lean anywhere. That is the honest answer for a street circuit, which is why it is
the one that carries it.

The profile is built by giving each corner its full angle across its own arc and
easing to nothing over `BANK_TRANSITION` (1.5 units, 21 m) at each end, then
**summing** the contributions. Summing is what makes an S-bend work: a left
followed immediately by a right has overlapping transitions of opposite sign, so
the road rolls through flat exactly where the car changes hands. The distance
measure wraps, or the corner before the start line would snap flat at the line.

Two things then consume the profile, and they must not disagree:

- **The collision ribbon**, whose lateral offsets are lifted by the bank's
  cross-section. The ribbon is now cut into six strips across its width rather
  than one quad edge to edge — a single quad would interpolate straight across
  the cross-section and give the car a flat road under a banked one.
- **The tile meshes.** There is no banked corner in the Kenney kit and no rigid
  rotation that would make one — a corner held at constant bank is a slice of a
  cone — so each affected tile's mesh is rebuilt vertex by vertex against the
  same cross-section function. The art is kept exactly: same surfaces, same
  materials, same kerbs and markings. Tiles on flat road keep sharing one
  imported mesh; only corners and the road either side pay for a unique one
  (18 of 60 holders on Ardennes, and none at all on Monte Carlo).

> **The banked tile replaces the glb instance rather than overriding the mesh
> inside it.** Writing a property onto a node *inside* an instanced sub-scene is
> the same mechanism that once shipped a car with eight wheels, and it would
> leave the committed `.tscn` files depending on override behaviour for something
> as load-bearing as the shape of the road. The replacement is a plain
> `MeshInstance3D` this builder owns, at identity, with its vertices baked into
> holder space — which also keeps the holder's "one mesh per piece" invariant and
> leaves `_gantry_position` in the suite walking the same path it always did.
> Cost: the shipped scenes grow from 38 KB to about 190 KB.

#### A banked corner is an embankment, not a tilted tile

The world outside the road is one flat plane 4 km across and cannot be banked to
meet a banked corner. Rolling a whole tile bodily therefore puts its outer edge
into the air as a grass cliff and its inner edge *under* the ground plane, where
the grass clips straight through the road — which is exactly what the first
version did, and it looked broken.

So the cross-section is built the way a real banked corner is. The inside edge
stays at ground level, the road climbs across its whole width, and the outside
grades back down to ground by the edge of the tile. Nothing ever sits below the
grass, so nothing can clip through it at any angle. The grades are **straight,
not eased** — an eased one peaks at nearly twice its average slope, and it is the
peak that decides whether a car running wide is turned back or thrown — but every
join between them is **rounded** over `BANK_FILLET`, because a sharp convex crest
throws the car however slowly it is crossed: the vertical acceleration a surface
demands is its curvature times the square of the speed across it, and at a corner
the curvature is infinite.

Three consequences worth knowing:

- **`BANK_FULL_HALF` must cover the whole painted road.** It was set inside the
  tarmac at first, to leave a longer, gentler verge — which put both of the
  cross-section's gradient changes *on the driving surface*, as a ridge 3.5 m out
  and a kink 3.5 m in. The car hopped whenever a wheel crossed one, while
  measuring as a perfect 10° bank the whole time, because along the racing line
  it was.
- **The bank ceiling is set by the road edge, not by taste.** The outside of the
  road stands above the surrounding grass by twice `BANK_FULL_HALF × tan(angle)`,
  and all of that is shed again over 2.1 m of verge. At 6° that is a metre of
  edge and a 26° apron, and drifting a hand's width wide drops the car off it. 4°
  is 0.69 m and 18°, which the suspension follows. NASCAR's 24–33° is out of
  reach without wider tiles to land the apron on.
- Because the road climbs from its inside edge, its middle ends up above the
  ground it is built on. `_build_bank_profile` adds that lift to the centreline
  itself, so "the centreline is the middle of the road" stays true for the things
  that rely on it — where the grid sits, where the timing gates hang. Height
  still closes: bank is zero at the start line, and the walker's own running
  height, which is what closure is measured from, is never touched.

Straights are sampled into the centreline every 0.2 units (2.8 m) rather than
once per tile, because bank transitions and ramp profiles are curves laid along a
straight and a curve sampled every 14 m is a set of facets the wheels can feel.
That holds the roll change under 2.5° between samples, about 0.9°/m — roughly 25°
a second at racing speed.

> **The anti-roll bar had to learn about this.** `car_controller` measured body
> roll against *world* up, which is the same thing as the road's up on a flat
> circuit and quietly wrong on a banked one: it saw a permanently rolled car and
> spent the whole corner trying to level it against the road, so the car fought
> the banking instead of settling into it. It now takes the road's normal from a
> single downward ray, falling back to world up when airborne or over something
> too steep to be road — which is the right answer there too, since a car in the
> air should level out.

> **Corner arcs are filleted, not centred on the corner.** A corner tile's arc
> centre is the *outer* corner of its NxN block, not the point where the two
> centre lines cross. Both give a quarter circle through the same two
> connections — they are mirror images across the chord — but only the fillet
> leaves the arc tangent to the straights it joins. Centred on the crossing
> point instead, the road turns the wrong way out of each end and the collision
> ribbon cuts clean across the inside of every bend, leaving the outer half of
> each corner with nothing under it but grass.
>
> This shipped for a long time unnoticed, because grass grips like tarmac so
> falling off the ribbon mid-corner costs nothing you can feel. It was almost
> certainly also what made the guardrails clip the racing line. The suite now
> asserts the centreline never turns by more than one arc step between
> consecutive points.

## The track editor

`scenes/editor/track_editor.tscn` lets the player build a circuit by dragging
it into shape on a grid.
`TrackLayout` (`scripts/track/track_layout.gd`) holds the painted cells and
compiles them into the segment list the builder walks.

### Why a grid rather than a segment list

The builder's native input is an ordered list of straights and corners, and it
only makes a circuit if it happens to close. The shipped layouts were solved by
hand, adjusting straight counts until the walker returned to the origin. That is
a puzzle, and a bad one to hand to a player.

A painted grid inverts the problem. One cell is one tile unit, the player paints
a closed loop, and closure is guaranteed by construction — a loop drawn on a grid
necessarily returns to where it started. The compiler's job is then merely to
express that loop in pieces.

### How corner radius survives the translation

The obvious objection is that a painted bend is a single cell, so every corner
would have to be the smallest tile, losing the sweepers that make the shipped
circuits worth driving.

The tile set does not work that way. All three Kenney corners join the *same two
centre lines*; a bigger one simply starts turning earlier and finishes later. A
corner of size N occupies an NxN block: the bend cell, plus N-1 cells taken from
the straight leading in and N-1 from the straight leading out.

So the painted route fixes where the road runs, and radius stays a free
per-corner choice, bounded only by how much straight there is to spend. The
compiler defaults every corner to the widest tile that fits and lets the editor
cycle it down — which is the interesting decision to give a player anyway: tight
hairpin or long sweeper, paid for in straight.

A corner also may not pave over road it does not own, so an oversized sweeper is
rejected where the circuit doubles back close to itself.

### Banking is the one per-corner choice that cannot fail

Radius and height are both negotiations with the circuit: a corner can be too
wide for the straights either side, a straight too short for the ramps it needs,
and the compiler has to shave requests until they fit. Banking is not like that.
It spends no cells and cannot stop the loop closing, so every corner can have any
of the four levels and the editor never has to refuse the click.

That is why cycling **wraps back round through flat** rather than stopping at the
top. Banking is a choice, and "no banking" has to be as easy to ask for as any
other setting — the badge shows a dot for a flat corner precisely so that
*deliberately flat* is a state you can see rather than infer.

**A corner that has never been told anything is flat**, which is also what a
track saved before banking existed gets, since it has no `corner_banks` at all.
Nothing is inherited, so a circuit only ever leans where its author said it
should, and reopening an old track cannot silently change how it drives.

### Elevation, and sustaining it

Every segment — each straight and each corner — carries an absolute *level*, and
the compiler works out where the ramps have to go. Raise a straight, the corner
after it, and the straight after that, and the result is one sustained elevated
section beginning and ending exactly where the player said.

The tile set is what makes that possible: `roadCornerBridge{Small,Large,Larger}`
hold their height, so a raised stretch can carry on round a bend instead of
dropping back down for it. Their decks sit `BRIDGE_CORNER_DECK` = 0.107 tile
units above the piece origin — *not* the 0.5 of `roadStraightBridge`, which is a
full bridge with supports to the ground where the corners are deck-only sections
meant to be carried at height. Getting that number wrong does not fail loudly;
the corner simply sits a few metres proud of the straights it joins.

Height can only *change* inside a straight, because a corner tile has the same
deck height at both ends. So a run reconciles three numbers — the level of the
corner before it, its own, and the level of the corner after — ramping from the
first to its own, holding, then ramping to the third. One `roadRampLongCurved`
per level of difference, two cells each.

That piece, not the plain `roadRampLong`, and the difference is the whole point.
`roadRampLong` is a wedge of eight vertices: the surface goes from level to a 25%
grade at a single edge and back again at the far end. Nothing about it reads as a
hill, and the car finds both creases. `roadRampLongCurved` has 377 vertices and
eases in and out — and its profile, recovered from the mesh, is **smootherstep**
(`6t⁵ − 15t⁴ + 10t³`) to within a centimetre at all 25 of its vertex rows. The
builder reproduces that curve analytically in the collision ribbon rather than
sampling the GLB, because `measure()` traces a centreline without loading a
single mesh and the editor measures on every mouse move. Worst gradient change
between collision samples went from a 25% cliff to about 4%.

**A chain of ramps shares one profile.** Easing in and out is exactly right for a
single tile and exactly wrong repeated: a change of three levels is three tiles
in a row, and tracing each one's own ease put the gradient back at zero at both
seams. Measured along a 0→3 climb, the grade ran 0 → 0.23 → 0 three times, and
the car pitched at each. The chain is now given a single ease spanning all of it,
which leaves the peak gradient alone — an eased ramp's steepest point is a fixed
multiple of its average, so stretching rise and length together cancels out
(measured: 0.232 before, 0.234 after) — and removes the undulation.

That correction lives in the centreline, so the collision ribbon gets it for
free, but the *tiles* still carry their own baked ease. They would otherwise
visibly undulate over a road the car drives smoothly, so each centreline point
records how far it sits above the mesh beneath it (`_ramp_lift`) and the tile's
vertices are lifted by it. This is the same per-vertex vertical correction
banking already used, and it reuses the same reshaping path — which is why that
path is now called `_reshape_tiles` rather than `_bank_tiles`, and why it no
longer returns early on a circuit with no banked corners. Left off, the tarmac
sits 2 m from the ribbon at a chain seam; the suite checks both halves, because
every other elevation test reads the ribbon and would not notice.

Two rules make it safe:

- **The start run is flat and the corner immediately before it is pinned to
  ground level.** The start line and its grid belong on the ground, and that pin
  is what makes the running height return to where it began — closure for
  elevation, the same trick the grid pulls for position.
- **Requests that do not fit are reduced, not refused.** A run that cannot afford
  its ramps has the highest of the three levels shaved until it can, preferring
  the run's own so a sustained section survives a short straight rather than
  being broken in half by it. The badge then shows what was actually built, and
  the headroom offered for cycling is probed against the resolved circuit, so
  every level the editor offers is one the compiler will really build.

The old behaviour — a plateau inside one straight — is now just the case where
both neighbouring corners are at zero.

> Levels and geometry are tracked separately: levels are absolute per segment,
> while the builder only ever moves height via ramps. They can therefore diverge
> silently, leaving the resolver describing a circuit that was never built. The
> suite pins them together by asserting the built peak equals the highest
> resolved level times the per-level rise.

### Drawing and shaping are peers

There are two ways to build a circuit and neither is the poor relation.
**Drawing** (the `Draw road` toggle, or `D`) gives the canvas over to laying road
freehand; the handles hide so a stroke cannot be mistaken for a drag. **Shaping**
drags the loop around by its corners. Shift is a temporary drawing override, for
a quick fix without leaving shaping.

An earlier version demoted drawing to a Shift-only escape hatch, which was the
wrong call: drawing is how you get a shape that is not a rectangle in the first
place.

Freehand drawing almost always ends with the two ends near each other but not
touching, and closing that last stretch by hand is the fiddliest part of the
whole job. `TrackShape.close_gap` routes a right-angled path between the two
loose ends, and the editor offers it as **Join the ends up** — but only when there
are exactly two ends and a route that lands on no existing road, so the button
never appears unless it will work.

> Filling between mouse samples has to step **one axis at a time**. Interpolating
> straight towards the cursor lays a diagonal staircase, and two cells meeting
> only at their corners are not neighbours here — so every diagonal step is a
> break in the road. One sloppy stroke produced six loose ends that way.
> `TrackShape.orthogonal_path` is the fix and the suite pins it.

### Editing is direct manipulation, not tool modes

The first version had four modes — paint, start line, corners, elevation — and a
click on a cell meant whichever the toolbar last said. The player had to keep the
current mode in their head, and the canvas gave no clue what a click would do.

Now every action has its own thing on screen to hit: a corner handle, a radius
badge, a bank badge, a climb badge, the start flag, the body of a straight. What
a click does is decided by what is under it, which is visible. Badges are drawn
*off* the road — corner badges outside the loop, climb badges inside — because a
badge sitting on the road steals clicks meant for the road beneath it.

The bank badge sits directly beyond the radius badge on the same ray out of the
corner. Radius and bank are both answers to "what shape is this bend", so they
read as a pair; putting the second further out rather than beside it keeps them
apart where two corners are close together. It is tinted differently from the
climb badge so leaning and climbing can be told apart without reading either
number.

Freehand painting survives on Shift, for anything the handles cannot express.

### The loop is edited as a shape, and invalid states are unreachable

`TrackShape` (`scripts/track/track_shape.gd`) views the painted cells as a
rectilinear polygon. Dragging a corner carries its two neighbours along one axis
each so the straights stay axis-aligned; dragging a straight slides it whole;
double-clicking one pushes a bend out of it; right-clicking a corner straightens
the jog it belongs to.

Every one of those goes through `_accept`, which prunes redundant vertices and
then refuses the edit outright unless the resulting cells still walk as one
simple ring.

A drag never changes *how many* corners there are — corners are added by
double-clicking and removed by right-clicking, and only there. That keeps the
dragged handle's index stable for the whole gesture, which is what lets a new
bend be dragged from outside the loop, through flat, and out the other side into
the interior. Letting the prune dissolve it mid-drag stranded the gesture at
exactly the point the player was trying to cross, so a circuit could only ever
grow outward. A bend crossing its own straight is stepped over the flat position
rather than stopping on it, and the crossing stalls quietly instead of colouring
the road red, because nothing is actually wrong. So the failure modes that made painting miserable — loose ends,
junctions, a loop folded onto itself — are not reachable by dragging at all. A
refused drag says so rather than silently doing nothing.

`TrackShape.walk` is the *single* definition of "a valid painted loop", and
`TrackLayout.compile` calls it too, so the shape editor and the compiler can
never disagree about what counts as a circuit.

Cells remain the source of truth; corners are derived from them on every change.
That keeps persistence, the compiler and the tests unchanged, and lets handle
edits and freehand painting mix freely.

> Painting had a plain bug worth remembering: the stroke was applied only to the
> cell under each motion event, with no interpolation. A drag across thirteen
> cells painted four of them. Every normal-speed stroke laid a dotted line, the
> validator then correctly reported loose ends, and the tool read as broken
> because it was. Any grid painter needs to fill in between samples — and to do
> it orthogonally, per the note above.

### The canvas draws the compiled circuit, not the cells

A painted bend is a right angle; the tile that takes it is an arc that starts
turning up to two cells early and bulges across the inside of the bend. Drawing
only the cells would misrepresent the track by around 25 m at the widest corner.

So the editor overlays the real centreline, coloured by height, on the painted
cells. `Compiled.to_grid` is the rigid transform that makes this possible: the
builder always walks from its own origin heading south, so what it returns is the
painted route rotated and translated, and recovering that transform puts the two
back on top of each other.

### Custom tracks are JSON

`TrackStore` writes one JSON file per circuit into `user://tracks/`. Not `.tres`:
Godot resource files can name a script to attach, so loading one is closer to
running code than to reading data. That is fine for the tuning presets that ship
inside the game and wrong for files players swap with each other. A layout is a
list of cells and a few integers; a corrupt or hostile one can do nothing worse
than fail to parse.

`GameState.all_tracks()` lists the shipped circuits followed by whatever is on
disk. Built-ins come first so their indices never move when a custom track is
added or deleted, and custom ids are namespaced `user_` so nobody can name a
circuit "ardennes" and inherit its lap record.

## The interface

Every widget in the game is styled by one generated resource,
`resources/ui_theme.tres`, named by `gui/theme/custom` in `project.godot`. A
Control therefore arrives styled without opting in, and a new screen inherits the
look by existing.

The theme is *described* in `scripts/ui/ui_theme.gd` and *baked* by
`tools/build_theme.gd` — the same bargain as the generated scenes: the reasoning
lives in code, the artefact is committed, and the game never depends on `tools/`
at runtime. Edit the script and nothing changes until the tool is re-run, which
is invisible (the colours are simply the old ones), so the suite compares the
committed resource against a freshly built one.

Three rules keep it from rotting:

- **No colours in the builders.** `tools/build_title.gd` and
  `tools/build_editor.gd` place nodes and name **type variations**
  (`UiTheme.V_PRIMARY`, `V_CARD`, `V_SECTION`, ...); a hex value in either of
  those files belongs in `ui_theme.gd` instead. Variation names are constants for
  a reason — a mistyped variation fails *silently*, rendering as the base type
  with nothing to say why.
- **One palette, including the parts that are painted.** `track_grid.gd` draws
  the editor canvas by hand and cannot pick up a theme, so it takes its colours
  from the same constants. The meanings carry across: green is the valid racing
  line, amber is height *and* the primary action, red is a circuit that will not
  compile *and* Delete.
- **No font is shipped.** Godot's built-in face is used at every size, so there
  is no licensed binary in the repo and nothing extra in the web build. The
  wordmark is letterspaced by putting spaces between its letters, because glyph
  spacing in Godot needs a `FontVariation` wrapping a font resource.

> A project-wide theme reaches screens nobody was thinking about. Giving
> `PanelContainer` sensible padding restyled the HUD too, and the speed readout —
> anchored to the bottom right and sized by its contents — grew straight off the
> edge of the screen. The `HudPanel` variation therefore carries a translucent
> background and *no* padding, because the HUD spaces itself with margin
> containers. Anything anchored to a screen edge is worth re-checking after a
> change to a base style.

### A menu row is one button, not a row of widgets

A track row has to be a single focusable, pressable thing — a gamepad and the
keyboard both move between *controls*, not between decorated boxes. But a
`Button` draws its own text and hosts no children, so the circuit's name is the
button's text and the blurb and lap time are mouse-transparent `Label`s anchored
over it. The `CardButton` style has deliberately lopsided content margins: a deep
bottom margin lifts the button's own text into the top left and frees the space
underneath for the overlaid lines.

> `tests/run_tests.gd` asserts the first child of every row is that button, and
> that the second is an Edit button on custom circuits and a spacer on shipped
> ones. Both halves of the layout are load-bearing: the spacer is what keeps the
> menu's right edge straight.

A player's own circuit carries a third control, **Delete**, which the shipped
ones reserve width for and do not get. It **arms rather than fires**: the first
press relabels it "Sure?" and only the second removes anything. There is no undo
— the JSON file is gone — and it sits one row-width from "drive this circuit".

A `ConfirmationDialog` was the obvious alternative and costs more than it looks.
It is a `Window`: it takes focus off the flat list of rows this menu is
deliberately built as, hands focus back somewhere else on close, and arrives
wearing stock Godot chrome, because the project theme styles Controls and says
nothing about windows. Arming keeps the whole interaction on the control the
player is already pointing at, and walking away — losing focus, or moving the
pointer off — disarms it.

Deleting goes through `GameState.delete_track`, not `TrackStore.delete`, because
**the lap record has to go with the file**. Ids are derived from the display name
and handed straight back out by `TrackStore.new_id` once the file is gone, so a
record left behind is inherited by the next circuit the player happens to name
the same thing — the exact thing `ID_PREFIX` exists to prevent across the shipped
tracks. That cannot live in `TrackStore` itself without the two classes
referencing each other.

### The editor panel has a fixed height budget

Content scaling pins the canvas to **720 units tall on every landscape window**
(see *Display scaling*), so the editor's side panel has the same room on a 4K
monitor as on a laptop — a bigger screen makes it larger, never taller. Anything
that does not fit has to go somewhere else, not wait for a bigger display.

The column is ordered by what an edit needs answered: what circuit this is, what
to do next, what the circuit currently *is*, then the actions. Those all stay
put. The legend — labelled **TIPS**, because naming the canvas handles in the
switch explained nothing to anyone who had not already found them — is reference
the player stops needing, so it is the one section that folds away. It opens as a
**flyout over the canvas** rather than inside the column, because the column has
no spare 200 units to give it on any window, and it starts **closed**: eleven
lines over a corner of the canvas is not what the editor should open on, and the
guide card already answers "now what".

> An earlier arrangement put the whole panel in a scroll region. That pushed the
> readout — the live verdict, wanted on every single edit — under the fold. The
> current rule is the opposite: feedback is fixed, reference scrolls.

**Width has the same problem, in the circuit picker.** An `OptionButton` takes
its minimum width from its **longest item**, and the items are names the player
typed with nothing limiting them. One long name dragged the panel out from 364
units to around a thousand and swallowed the canvas it is supposed to sit beside.
`clip_text` on the picker makes the panel width authoritative rather than the
contents.

Three controls, one rule: **anything displaying text the player supplied, or the
compiler generated, needs a cap.** The track name button and its blurb on the
title screen already had `clip_text` for exactly this reason; the editor's picker
and cards did not.

**The cards need a ceiling, not just a floor.** `custom_minimum_size` sets the
floor; the guide and readout wrap, and what goes in them comes from the compiler
— a list of errors, a nudge, a crossing that needs bridging. With no cap they
grew, and pushed Save, Test drive and Back under the bottom of the column. There
was no way to save the circuit being described.

`max_lines_visible` on every wrapping label makes that **structural** rather than
a matter of keeping the wording short: however long the text gets, nothing below
it can move. Trimmed with an ellipsis so a clipped message looks clipped rather
than finished. The suite now drives the layout with the worst content the editor
can produce — a refused crossing, which carries an error per problem cell — and
asserts the buttons are still on screen, because the default circuit it used to
test with is exactly the case that never overflowed.

The budget is enforced by the suite, and it bites. Adding the longest straight
and the lap estimate as two new readout lines overran the portrait column by
18 units, and nothing but `test_more_panel_holds_the_rest` noticed. Both facts
were folded into lines that already existed instead, and the pathology nudge
**replaces** the least important line rather than adding one — so the readout has
the same height whether or not it is warning about something. A panel that
changed height when it had something to say would reflow the column underneath it
at exactly the moment the player was reading it.

### The estimated lap time

`ParTime` is deliberately shared between the editor readout and the medals that
will derive from it (`docs/roadmap.md`, M15): an editor advertising a target the
medals disagreed with would be worse than no readout at all.

It runs the standard quasi-static lap simulation over the centreline `measure()`
already fills — cap speed by cornering grip everywhere, then sweep forwards under
acceleration and backwards under braking — rather than the fitted
`length / average_speed` constant `ideas.md` sketched. A fitted constant needs
re-fitting whenever the handling changes and cannot tell one long straight from
the same metres in short bursts.

Every constant in it is measured (see the tuning journal, M10), and the cornering
half is checked against figures measured in M3b: 98.7 km/h predicted on a 21 m
radius against 98 measured, 127.4 against 127.

Three things about it are load-bearing:

- **Curvature is measured at the source vertices, not after resampling.** The
  centreline is a polyline whose vertices sit on the real geometry and whose
  segments cut inside it, so sampling it finely reads its own chord junctions as
  kinks. This is the one genuine bug the model had.
- **Curvature is measured flat; distance is measured in 3D.** A crest is
  curvature too, and counting it would brake for a gentle brow. The car is
  limited by grip through bends, not by the shape of the hill.
- **The editor shows the *ideal* lap, not the par.** `HUMAN_SLACK` — how much
  slower a person is than a perfect simulation — is the only unmeasured number in
  the model, and printing something derived from it would launder a placeholder
  into a figure that looks authored. For the same reason the readout prints whole
  seconds: milliseconds on an estimate claim an accuracy it does not have.

It costs about 1 ms on top of the walk the editor was already doing, on the
longest shipped circuit, against a 16.7 ms frame. The suite asserts that, because
the editor recompiles on every mouse move and dragging is how it is used.

## The look

The target is **Horizon Chase**: vivid flat-shaded colour blocking, no textures,
big graphic skies, bright and readable, never grimy. The Kenney kit is already
untextured flat-shaded geometry, which is the expensive half of that look done,
and it survives the compatibility renderer the web build is stuck with.

What was missing was saturation, not detail. Kenney's palette is **pastel** —
mint grass, near-white kerbs, a soft orange car — and saturation is a property of
the `Environment` rather than of any asset, so the whole first step is three
properties on an object `_build_lighting` already constructs in code:
`adjustment_saturation`, `adjustment_contrast`, `adjustment_brightness`. No new
art, no new shader.

Two things about it are load-bearing:

- **`tonemap_white` had to rise with the contrast.** ACES was chosen because the
  kerbs and grid markings clipped to featureless white under linear tonemapping.
  Pushing contrast lifts the top of the range and reintroduces exactly that, so
  the white point moved from 1.8 to 2.1 in the same change. Raising one without
  the other undoes the reason the tonemapper was picked.
- **The fog colour and the sky's horizon colour are one constant**
  (`TrackBuilder.SKY_HORIZON`), not two that happen to match. Fog here is
  structural rather than weather: the ground is a 4 km plane and fog exists to
  land its edge into the sky, which it can only do while it *is* the colour the
  sky is at that edge. Letting them drift apart puts a visible seam at the
  horizon.

The grade is **baked into each shipped circuit** by `_build_lighting`, so
changing the palette does nothing until `tools/build_track.gd` is re-run — the
same trap as the theme resource, and asserted the same way, by comparing the
committed scenes against the constants.

These are constants rather than a resource on purpose. A per-circuit
time-of-day preset is the right home for them and is scheduled (`docs/roadmap.md`,
M16); building that structure now, with one circuit's worth of values and nothing
to vary, would be fitting a socket before there is a bulb.

## Audio

> **Off by default, and that is a verdict rather than a setting.** The synthesised
> sounds below were listened to once and called annoying. They are structurally
> right — seamless loops, pitch keyed to measured speeds — and they are a buzz
> and a hiss rather than a car. `GameState.audio_enabled` defaults to false, with
> a switch on the pause menu, until a proper audio pass replaces them. Flipping
> the default is a one-line change when that happens.
>
> Everything below describes what is there and why it is shaped that way. None of
> it argues that it sounds good.

There was none at all, and there is no audio in the Kenney kits — they are art.
So it is **synthesised** by `SoundBank` and baked into two looping
`AudioStreamWAV` resources by `tools/build_audio.gd`. That keeps the game
buildable from what is committed, the same reason the theme, the circuits and the
car are baked by scripts, and it means the sounds can be tuned against handling
numbers that are measured rather than against whatever a downloaded loop was.

Saved as `.tres`, not `.wav`: a `.wav` in the project is an *import*, cached
under `.godot/`, which is neither committed nor stable. A resource carries its
samples inline, so what is committed is exactly what the game loads. Together
they are 32 KB, or 0.5% of the web `.pck`.

**The rule that makes a generated loop seamless:** every partial's frequency must
be an integer multiple of the buffer's own fundamental (mix rate ÷ frame count).
A component that does not complete whole cycles inside the buffer arrives at the
loop point mid-swing and clicks — once per loop, forever, and quietly enough in
isolation to ship. It is also why the tyre "noise" is 240 summed partials rather
than a random number generator: random samples cannot be made to meet their own
start.

The suite checks this by comparing the wrap against the buffer's own largest
sample-to-sample step, not against a fixed threshold. An absolute limit cannot
serve both sounds — the engine is a low buzz whose neighbouring samples barely
differ, while the tyre runs to 3.3 kHz where a full swing between adjacent
samples is normal. What makes a click is the wrap being an *outlier for that
waveform*, not being large.

### The gearbox is a lie, and deliberately

Engine pitch could come from `VehicleWheel3D.get_rpm()`, and it would be wrong:
wheel speed rises monotonically from a standstill to top speed, so the note would
climb one long slide over twenty seconds and never do the thing an engine does.
The speed range is divided into five bands and the note sweeps each one, so
acceleration is sold by repetition.

There is no gearbox in the physics — `engine_force` is applied directly, with no
clutch or torque curve — so this is honestly a sound effect keyed to speed. The
band is found by dividing the speed range rather than by tracking a current gear,
which means it cannot get stuck in one: braking drops the note the way
accelerating raises it, with no state to unwind.

Two smaller decisions:

- **Tyre noise reports the worst-behaved wheel, not the average.** One wheel
  breaking away is the moment worth hearing, and averaging hides it behind the
  three still gripping. It is also gated above a threshold and a minimum speed —
  squealing through every corner would carry no information.
- **The audio node runs `PROCESS_MODE_ALWAYS`.** Audio does not stop when
  `get_tree().paused` is set, so something has to keep running in order to
  silence it, and a node that paused with everything else could not. Same
  reasoning as the pause menu, which runs always so it can dismiss itself.

Playback does not start under `--headless`, where the audio driver is a stub that
never mixes. The playback objects it creates are still held by the audio server
at shutdown, which ended every suite run with "2 resources still in use". None of
the *logic* is skipped — pitch and gain are still computed and applied every
frame, so the suite asserts on exactly what the game does.

## Lap timing

16 `Area3D` gates along the centreline, index 0 on the start line. They never
block the car; ordering is enforced in `lap_tracker.gd`, and an out-of-order
gate is ignored so a skipped gate has to be gone back for.

The car spawns just *behind* the line rather than past it, so the timer starts
about two seconds in instead of after a full out lap. Specifically it spawns in
the pole slot painted on the `roadStartPositions` tile.

> **The grid tile goes down before the start tile, and turned round.** Two
> separate ways of getting the start backwards, neither of which breaks anything:
>
> - `roadStartPositions` paints four slots that alternate sides and march
>   towards its own exit end, so laid ahead of `roadStart` they lead up to the
>   line with pole nearest it. Emitted the other way round — which is how the
>   shipped circuits and the compiler both had it — the whole grid sits *past*
>   the line running away from it.
> - Each slot is a **U**: a bar closing one end, a strip down either side, open
>   at the other. The car noses in through the opening and stops at the bar, so
>   the bar belongs at the front. As Kenney authored it the bar is at the end the
>   walker drives in through, so the tile has to be driven backwards — hence
>   `"entry": "S"` in `PIECES`, which forces `_place` to pick the 180-degree
>   rotation instead of the first one that fits. Everything else on the tile is
>   symmetric about the cell centre, so nothing else moves.
>
> The loop still closes either way and the lap is still timed at the line; the
> only symptom is a grid you would have to reverse into. `GRID_POLE_ALONG` and
> `GRID_POLE_ACROSS` are read off the art, and are also where the car is put —
> the suite locates the paint in the built scene and samples the middle of the
> pole slot at each end, which is the difference between a bar and an opening.

> **The gates hang off the start line, not off arc zero — and it is their leading
> face that counts.** Two separate mistakes once put the clock 13.85 m ahead of
> the line the player can see, so a lap both started and finished before the car
> reached the gantry:
>
> - Arc zero is the *leading edge* of the first tile of the start run. That is
>   the grid tile, two units of it, and the `roadStart` tile behind it is another
>   two units carrying its painted stripe and gantry across the middle of itself.
>   `START_LINE_ALONG` is the midpoint of that assembly, and everything — gates
>   and grid slot alike — is measured from there.
> - `Area3D.body_entered` fires when the car first touches the box's *leading
>   face*, not its centre. The gates are deliberately 4 m deep so nothing tunnels
>   through at speed, and every metre of that depth was a metre timed early, so
>   each box is pushed forward by half its own depth to put that face on the line.
>
> Neither was visible from behind the wheel: the HUD has no reference to disagree
> with, and the car is 17 m back on the grid so the clock starting "about when you
> set off" looked right. The suite now locates the gantry from its own mesh
> vertices in the built scene and asserts the trigger plane is within 2 m of it —
> deliberately reading the art rather than the constant, so a wrong constant
> cannot make the test agree with itself.

This matters because nothing physically prevents cutting: collision is one
surface, grass grips like tarmac, and the guardrails are off. Ordered gates are
what make a lap time mean anything.

Lap time accumulates in `_physics_process`, so times track the simulation rather
than the render framerate — headless runs therefore produce the same times as
the game.

### Sector splits, for free

The sixteen gates were already ordered, so recording the clock at each one turns
them into sixteen sector times without a single new node. `splits[i]` is the
elapsed time when gate `i` was taken; comparing against the stored best lap's
splits gives the live delta on the HUD.

Two details that look arbitrary and are not:

- **Index 0 holds the time the lap was *closed* at**, not a zero at the
  beginning. Crossing the line is what ends a lap, so that entry is the lap time
  itself — which is what makes it comparable with a stored one.
- **A slot is 0.0 until its gate is taken**, so a lap in progress is a partially
  filled array rather than a short one. Index therefore always means gate number,
  which is what lets two laps be compared slot for slot without either carrying a
  length.

The delta is **NAN, not 0.0, when there is nothing to compare against**. Dead
level with the record is a real and interesting reading, and it must not look
like an absent one. It resets to NAN at the line, because carrying the last
gate's delta into a new lap shows a comparison against a gate the car has not
reached yet.

`_delta_at` refuses to compare when the stored splits are a different length from
the current gate count. That is the case where a circuit was edited after its
record was set: without the check it would read out a confident delta between two
different places on the track.

### Ghosts

Recording the car every physics tick was cheap *because of a decision already
made*: lap timing accumulates in `_physics_process` so headless runs reproduce
real times, and sampling on that same fixed step is what makes a recording
reproducible rather than dependent on framerate.

- **60 Hz, not the 120 Hz the physics runs at.** A two-minute lap is ~14,400
  ticks; at 60 Hz and seven floats a sample that is ~230 KB, and at 165 km/h a
  sample every 76 cm. Playback interpolates, and a ghost is a translucent shape
  at a distance rather than something being collided with.
- **Samples are aligned to the lap, not to an accumulator.** Sample *n* is always
  the pose at *n*/HZ seconds in, because the recorder compares `lap_time` against
  the count it already has. A self-resetting accumulator would drift by up to a
  physics step per sample, and two recordings of the same circuit would stop
  being comparable frame for frame.
- **Recording stops at `MAX_SAMPLES`.** The cap exists on the reading side to
  stop a corrupt count sizing a huge allocation, so it has to be obeyed on the
  writing side too — otherwise a long enough lap writes a file the same code
  refuses to read.
- **The replay is meshes and nothing else.** No collision body, for two separate
  reasons that would each be enough: `car_controller` finds "up" by raycasting
  down and would read a solid ghost as banking, exactly as it would a trackside
  prop; and the gates fire on `body_entered`, so a second body wearing the car's
  shape would trip all sixteen and time a lap nobody drove.
- **It follows the lap clock, not its own.** Pausing stops both together, and a
  lap restarted at the line restarts the ghost with it.
- **It reads the recording from the tracker every frame** rather than being
  handed one. The tracker loads the stored ghost on its first *physics* frame,
  not in `_ready`, because the checkpoints it binds to are instanced at runtime —
  and a new best lap replaces it mid-session.

Stored as bytes under `user://ghosts/`, not in `records.cfg`: a ghost is a few
hundred kilobytes of binary and `ConfigFile` is a text format read whole on every
lookup, including by the title screen. The *name* still comes from `GameState`,
so a ghost is keyed on exactly what its lap time is keyed on. `from_bytes`
returns null for anything it does not fully understand rather than a
half-populated lap, which would read as a driving mistake rather than a broken
file — and the compressed body's length is in the header purely so a truncated
file is caught by arithmetic instead of by handing bad data to `decompress`,
which logs an engine error on its way to failing.

### Share codes

Custom tracks were stored as JSON so they could be swapped, and then swapping was
never built. The obvious form — hand someone the file — fails on the target that
matters: the web export has no filesystem, `user://` there is browser storage, and
a download-and-upload flow needs UI on both sides. A code works identically on
desktop and in a browser and needs nothing but the clipboard.

`TD1-<base64>|<uncompressed size>`. The prefix sits outside the base64 so a code
is recognisable on sight, the version can be read before anything is decoded, and
a paste that was never a code is rejected cheaply rather than deep inside a
decompressor. The size sits after a `|` because `decompress` needs it up front —
and it is bounded before it is believed, since the whole purpose of a size field
is to size an allocation.

Four things it deliberately does:

- **The sender's id does not travel.** Ids are local: `TrackStore` hands them out
  and lap records are keyed on them, so importing under the sender's id would let
  the circuit inherit whatever the receiving player had recorded against that
  name. The importer allocates a fresh one, and an imported circuit arrives
  unsaved.
- **Whitespace is stripped before anything else.** Chat windows and email wrap
  lines, and a code that failed because of what the transport did to it would be
  indistinguishable from one that was never valid.
- **The base64 alphabet is checked before `Marshalls` sees it.** Marshalls logs an
  engine error on its way to returning nothing, and a mistyped code is the most
  ordinary failure this has — it should not look like a fault in the game. Same
  reasoning as the length field in `Ghost`.
- **Validity is the last check, and it is the compiler's.** `TrackLayout.compile`
  calls the same `TrackShape.walk` the editor does, so a decodable non-circuit
  can never be built — but it fails with a sentence saying so rather than a
  button that appears not to work.

**Ghosts do not ride along by default, and that was settled by measuring rather
than by taste.** A circuit is 372 characters. The same code carrying a two-minute
lap is 128,000 — 343 times larger, and past what anyone pastes into a message.
The capability exists and is opt-in, for a transport that can carry it.

Importing lives in the circuit **picker** rather than behind a button, partly
because it belongs there — the picker answers "which circuit am I working on" and
a pasted code is one way to answer it, like "New circuit" beside it — and partly
because the panel has no room. A share row of its own measured 35 units against a
column that had none to spare.

#### Why importing goes through a text field, not the clipboard

The picker opens a small flyout with a `LineEdit` in it, and **that field is what
gets decoded** — not `DisplayServer.clipboard_get()`. This is a web-build
constraint, and it is the same constraint that made a code the right format in
the first place:

- On desktop, `clipboard_get` is reliable.
- **In a browser it is not.** Reading the system clipboard needs an async
  permissions API that Godot's web platform does not expose, so what
  `clipboard_get` returns there is whatever was last pasted *into the canvas*. A
  button that read it would come back empty until the player had already pressed
  ctrl+V somewhere, which is a rule nobody could guess.
- A focused `LineEdit` receives the browser's own paste event directly. It is the
  one route that behaves identically on both targets.

The field is still **pre-filled from the clipboard when that works**, so the
desktop flow stays a single click — and only when the clipboard already holds
something starting with the prefix, so the box never opens with somebody's
unrelated copied text in it.

Both directions check `DisplayServer.has_feature(FEATURE_CLIPBOARD)` first.
Asking a display server that has no clipboard logs an engine error, which the
suite would then carry in its log for as long as it existed. Copy falls back to
putting the code *in the same box* to be selected by hand, rather than reporting
a success that did not happen.

### How a record is keyed, and why the track is a section

A time is only comparable to another set **in the same car on the same surface**,
so a record is keyed on all three. Both extra dimensions are fixed today — there
is one car and every circuit is tarmac — and they are in the key anyway, because
sector splits and ghosts are next and would otherwise have to be migrated
alongside the records once a garage exists. One migration now beats three later,
across data a player by then minds losing.

The **track is the `ConfigFile` section** and the car and surface are the key
(`record:<track>` / `<car>|<surface>`). Two reasons, and the first is the one
that forced it:

- Ids are drawn from `[a-z0-9_]` (`TrackStore.new_id`), so a flat
  `best_<track>_<car>` cannot be taken apart again. `best_ardennes_kart` reads
  equally well as the kart on Ardennes and as the default car on a circuit called
  "ardennes kart". A separator outside the id alphabet is needed, and a section
  boundary is the cleanest one available.
- Deleting a circuit has to take **every** time set on it, whatever car they were
  set in, and `erase_section` is exactly that sweep. Ids are handed straight back
  out once a file is gone, so a record left behind is inherited by the next
  circuit named the same thing — the same hazard `GameState.delete_track` already
  exists to close.

The old flat format (`[records] best_<track>`) is version 1 and migrates once, on
load, stamped with `[meta] version`. That migration is only unambiguous *because*
version 1 predates any composite key: every key it can encounter is a
default-car tarmac lap, since there was nothing else to drive. `_open` is the
single door onto the file, so there is exactly one place that can meet an old
one.

## Testing

`tests/run_tests.gd` runs headless and exits non-zero on failure, so CI gates on
it. It covers what is cheap and stable to assert: tuning invariants, lap
ordering rules, checkpoint integrity, and the road surface actually being where
the road is.

It is a small hand-rolled runner rather than GUT — the suite is entirely scene-
and physics-dependent and needs no fixtures or mocking, so an addon would add
weight without removing any. Worth swapping if it outgrows a single staged
script.

Handling *feel* is not unit-testable and is not pretended to be. It is measured
with throwaway `_diag_*.gd` scripts whose findings are recorded in the tuning
journal, then deleted.

## Web build

The game exports to WebAssembly and is hosted on GitHub Pages. Two platform
constraints drive the configuration:

**Single-threaded.** Since Godot 4.3 this is the default, and it matters here:
threaded web builds require `SharedArrayBuffer`, which requires the COOP/COEP
cross-origin isolation headers, and GitHub Pages cannot send custom headers.
With `variant/thread_support=false` the loader skips those checks altogether —
the generated page carries `GODOT_THREADS_ENABLED = false`, which CI asserts so
a threaded build cannot be published by accident.

**Compatibility renderer.** Web targets WebGL 2 only; Forward+ and Mobile are
unavailable. Rather than downgrade the whole project, `rendering_method.web`
overrides the renderer for web alone. Rendering under Compatibility was checked
before committing to it: the grid shader, gantry, shadows and HUD all survive,
with slightly brighter tonemapping.

> **Godot rewrites `project.godot` on its own schedule** — an `--import`, an
> editor open, even a web export — and when it does it drops whole sections and
> every `;` comment in the file. The `rendering_method.web` override has been lost
> that way twice, and nothing warns: the export still succeeds and the page simply
> renders wrong. So the reasoning lives here rather than in comments there, and
> `tests/run_tests.gd` asserts both renderer settings are present.

**No system fonts.** Godot's built-in font covers Latin and little else, and
`allow_system_fallback` quietly fills the gaps from the OS — on desktop. The web
export has no OS font provider, so any character the built-in font lacks renders
as a **tofu box with its own codepoint printed inside it**, and only in the
browser. The editor canvas labelled its bank badges with `∠`, the angle
sign, which looked right on macOS for as long as it was only ever run there and
reached GitHub Pages as a box reading "2220". `track_grid.gd` now draws the mark
with two lines instead of typing it — that canvas draws everything else by hand
anyway, and two lines are cheaper than shipping a font for one glyph.

> `tests/run_tests.gd` reads the scripts that draw and label the interface and
> asks the font about every character in them, `\uXXXX` escapes decoded — that
> being the form this one was written in, where a scan for raw non-ASCII would
> have walked straight past it. Comments are covered too, so the rule is simply
> "do not type a glyph the built-in font does not have, anywhere". Em dashes and
> middle dots are fine; the suite confirms it rather than assuming it.

`export_presets.cfg` is committed (not gitignored as Godot suggests by default)
because CI needs it. That is safe while web is the only target — it holds no
signing keys — and should be revisited if a platform that needs credentials is
added.

> Godot's exporter can print a configuration error and still **exit 0**. The
> workflow therefore checks the artifacts exist rather than trusting the exit
> code.

## Display scaling

The UI is laid out in pixels, so with no stretch mode it kept its pixel size and
shrank as a fraction of the screen the denser the display got — the title menu
measured 47% of screen width at 1152x648 and 21% at 2560x1440, which is why it
looked tiny on a Retina laptop panel and correct on an external monitor.

`window/stretch/mode = "canvas_items"` scales the whole UI with the window against
a 1280x720 design size; 3D rendering is unaffected. The aspect is `keep_height`,
not the two obvious alternatives: `expand` deliberately holds the scale at 1:1 and
only reveals more canvas, which is the bug being fixed, and `keep` letterboxes,
which is unwanted with a 3D view behind the UI. With `keep_height` a wider window
simply shows more to the sides — measured at 16:9, 16:10 and ultrawide, the
background reaches every corner with no bars.

> Measuring this is easy to get wrong. `root.size` is the *window* size while
> Controls are laid out in canvas units, so comparing the two makes a correctly
> scaled UI look broken. `root.get_visible_rect().size` is the canvas, and
> `root.get_final_transform()` carries the scale.

`keep_height` is right for every *landscape* shape and wrong for portrait: it
pins the canvas to 720 units tall, so a 9:16 phone gets 720 x 9/16 = 405 units of
width and the 300-unit track buttons run off both sides. `ViewportScaling`
(`scripts/ui/viewport_scaling.gd`) therefore swaps the rule at runtime — portrait
keeps the *width* against a 720x1280 design, landscape keeps the height against
1280x720 — and every scene root calls `attach()` in `_ready`.

The **project setting stays `keep_height`**, deliberately. It is what a fresh
window and the headless suite get before any scene has run, and the suite asserts
it. Only the live window is retargeted.

> The short edge is 720 in both design sizes, so a control sized in canvas units
> covers the same fraction of the short edge either way. That is what lets one
> set of touch-pad sizes serve both orientations.

### `size_changed` is not enough on a phone

A browser fires its resize on rotation **before** it has finished reshaping the
canvas, so a handler reading `window.size` at signal time gets the size the
window is about to stop being. Every orientation decision in the game is made
from that one read — the canvas rule, the camera's aspect, the HUD's layout, the
editor's — and **none of them is ever revisited**, so a single stale read latches:
landscape gets drawn to the portrait rule, turning back applies the landscape
rule to a portrait screen, and it stays one rotation behind forever because there
is no event left to correct it. First load is always right, which is what makes
it look like rotation specifically is broken.

`ViewportScaling.SizeWatch` is a `Node` parented to the **window**, not to a
scene, so it outlives every scene change the way the signal connection does. It
compares `window.size` each frame and re-emits `size_changed` when it differs
from what it last saw. Polling works because the size is only wrong for a moment;
whatever the browser said at signal time, `window.size` is right a frame or two
later. The same tick also covers a resize that reports no signal at all.

It **re-emits the signal** rather than calling `apply` itself, deliberately: the
signal is the one wire every listener is already on, and what the watch observed
is exactly what the signal means. Any other route would leave the camera and the
editor still holding the stale value while only the canvas recovered.

> Not a canvas-policy problem, which is the other thing that produces these
> symptoms: `export_presets.cfg` has `html/canvas_resize_policy=2` (adjust to
> whole window), so the canvas does follow the browser.

> Testing this needs the *state* a phone ends up in, not a desktop resize — a
> correctly-sized window carrying the previous orientation's rule, with nothing
> further coming. Only the aspect can be staged wrong: writing
> `content_scale_size` re-fires `size_changed` on the spot and the handler puts it
> straight back. And the assertion has to **poll** rather than pick a frame, because
> physics runs at 120 Hz while the watch runs on idle frames, so consecutive
> frames in `run_tests.gd` can share one idle frame or none.

### What content scaling does *not* fix

Swapping the canvas rule is only half of a rotation. Three things sit outside it,
and all three shipped broken on a phone; each now has a test that rotates a real
window rather than checking the rule as a pure function, which is how they were
missed.

**The camera.** Content scaling does not touch the 3D projection, and `Camera3D`
defaults to `KEEP_HEIGHT` — it holds the *vertical* FOV and lets the horizontal
one shrink with the viewport. A 9:16 phone therefore keeps the full height and
throws most of the width away: the car filled the screen, the road ahead was
gone, and the game was unplayable held upright. `ViewportScaling.camera_aspect`
mirrors the canvas rule (portrait keeps the width) and `chase_camera.gd`
subscribes to `size_changed` itself, so the connection dies with the camera
rather than outliving it on the window.

**Anything two controls wide.** Screen-edge anchoring survives a rotation on its
own, but only where the things anchored do not meet. The lap panel wants 214
units and the banner about 470; across 1280 they share a line, across 720 they
are drawn on top of each other. `hud.gd` drops the banner below the panel in
portrait, and lifts the speed readout clear of the gas pedal wherever the touch
pads exist.

**Anything holding coordinates of its own.** The editor canvas keeps a pan and a
zoom that mean nothing except against a given canvas size, so a rotation left the
circuit off screen — with no F key on a phone to refit it. `TrackGrid` handles
`resized`: an orientation flip refits, and any other resize keeps whatever was in
the middle in the middle, because a dragged window edge should not throw away a
deliberate zoom.

## Touch controls

`TouchControls` lives inside `hud.tscn` and is hidden unless
`DisplayServer.is_touchscreen_available()`. It does **not** drive the car. It
synthesises `InputEventAction`s and pushes them through
`Input.parse_input_event`, so `car_controller` keeps reading exactly the actions
the keyboard and gamepad feed and never learns touch exists — adding a pad cannot
change how the car drives, only what presses the same buttons.

**`Button` cannot be used for this, and that is the whole design.** Button presses
arrive via the emulated mouse (`emulate_mouse_from_touch`, on by default), and the
emulated mouse is a *single* pointer owned by the first finger down — so a layout
built from `Button`s physically cannot hold the gas and steer at the same time,
which is most of driving. Raw `InputEventScreenTouch`/`InputEventScreenDrag` carry
a per-finger `index`, so the pads hit-test themselves against those.

That hand-rolled bookkeeping is where the bugs live, and each has a test:

- Actions are **reference counted per finger**. Two fingers on the gas and the
  first one lifting must not release it.
- A finger that **drags off** a pad releases it, or a thumb slip leaves the
  throttle stuck on.
- `release_all()` runs on `_exit_tree` and on being hidden. Leaving the race
  mid-press would otherwise strand that action down forever — `Input` holds a
  synthesised press until something sends the matching release, and the node that
  would have sent it is gone.

> `Input.parse_input_event` **buffers**. The action does not reach
> `Input.is_action_pressed` until the next flush, which is a frame of latency
> nobody can feel in the game but which makes a test read the state from before
> the touch. The suite calls `Input.flush_buffered_events()` after each synthetic
> event rather than spreading one gesture across frames.

Touch positions arrive in viewport space while `get_global_rect()` is in the
CanvasLayer's space. They coincide only while that layer's transform is identity,
so the hit test converts through `get_canvas_transform().affine_inverse()` rather
than relying on it.

The menus need none of this: `emulate_mouse_from_touch` already turns a tap into
a click, which is exactly what a `Button` wants.

## The editor on a phone

The editor needed all three of the things emulation cannot give it. It is worth
being precise about which, because each was a different kind of gap.

**Two fingers.** Emulation collapses every finger onto one pointer, so pan and
pinch simply do not exist on the mouse path — and `InputEventMagnifyGesture` and
`InputEventPanGesture`, which the canvas already handled, are macOS *trackpad*
events that a touchscreen never sends. `TrackGrid._input` therefore reads raw
`InputEventScreenTouch`/`Drag`, the same route `TouchControls` uses and for the
same reason. **One finger is deliberately not handled there**: emulation already
turns it into exactly the left-button drag the canvas has always understood, so
drawing, dragging a corner and tapping a badge work on a phone without the script
knowing. Only the part emulation cannot express is taken over.

Two things then stand between a pinch and an accidental edit, and both have a
test that fails without them:

- The gesture *starts* wherever the fingers land, and the emulated mouse has
  already reported the first of them as a press — so a pinch centred on a corner
  arrives as a grab of that corner. `_end_drag` closes it off, and it now records
  an undo entry only when the drag actually **changed** something (`_drag_moved`),
  or a pinch left an entry on the stack that undoes nothing.
- *During* the gesture the emulated mouse keeps following a finger, and a finger
  lifted and put back down mid-pinch — how anyone adjusts their grip — arrives as
  a fresh press on whatever is underneath. `_gui_input` drops mouse events while
  two fingers are down.

**A second button.** Erasing a stroke and removing a corner were right-button
only, which on glass means unreachable — and they are the only two destructive
edits, so a circuit could be built but nothing taken back out. `erase_mode` is
the mode this canvas otherwise refuses to have, and it earns the exception by
being destructive: a mode you can see you are in is the cheap way to stop a stray
thumb rubbing out a circuit. The road tints toward `DANGER` while it is on, and a
corner dot still wins the hit test, so the dot that *moves* a corner with erase
off is the dot that *removes* it with erase on.

> Hit targets widen on touch but only to one cell. A fingertip wants roughly 80
> canvas units on a phone; the radius and bank badges sit 1.2 cells apart, so past
> about a cell a wider circle stops being a bigger target and starts being a coin
> toss between two neighbours. Getting closer than that is what pinching is for.

**Room.** The sidebar is 364 units against a 720-unit portrait canvas, so the
circuit was being edited in less space than the controls editing it. Portrait
reflows to a bar above the canvas (Draw, Erase, Fit, Undo, MORE), a bar below it
(the guide, the status line, Test drive / Save / Back) and the sidebar **floated
over the canvas behind MORE**, holding the name, the picker, the stats, the tips
and Delete — what you go looking for rather than what you reach for while
drawing.

The controls **move** between the two arrangements rather than being built twice.
Two of each button would mean two `disabled` flags, two signal connections and
two chances to disagree about which is lit, and Undo and Test drive both spend
most of their life disabled, so a stale twin would show immediately.
`track_editor.gd` records each moving control's parent and index once, before
anything has moved, and restores by that index in ascending order — restoring in
any other order puts them back in the wrong places. The round trip is tested
against a snapshot of the whole control tree, because the way this breaks is that
a trip through portrait and back leaves the sidebar subtly rearranged and nothing
notices until someone opens the editor on a desktop afterwards.

> The floated panel stops short of **both** bars. Covering the top one buries
> MORE under the panel MORE opened, leaving no way to shut it; covering the
> bottom one takes Test drive away at the moment you have finished with the
> settings you opened it for.

Icons were not an option for the bars — see the built-in font constraint under
*Web build constraints*. The toolbar is short words.

## Known gaps

- No audio, and no skid particles.
- Guardrails exist behind a flag. They clipped the racing line at corners, which
  was blamed on polyline offsetting needing proper mitring — but the corner arc
  bug above is the more likely cause, and they are worth retrying now it is
  fixed.
- Grass has the same friction as tarmac, so leaving the circuit costs only time.
  This is also what hid the corner arc bug for so long.
- The editor cannot express a crossover or a pit lane: the compiler requires
  every painted cell to have exactly two neighbours, which is what makes the loop
  unambiguous. A figure-eight would need a bridge piece and a real graph walk.
- Custom circuits get no name validation beyond being non-empty, and there is no
  confirmation on Delete.
- Undo is a stack of whole-layout snapshots and there is no redo. Fine at this
  size; a diff-based command stack would be the move if layouts grow.
- Dragging a corner cannot move it *past* an adjacent one — the edit is refused
  rather than reordering the ring — so some reshapes need two drags.
- A bend cannot be shallower than two cells, so dragging one across its own
  straight is refused for a cell either side of flat. Structural, not a bug, but
  it does mean the crossing has a little resistance in it.
- The interface has no motion beyond the menu rows fading in, no sound, and no
  transition between screens; a scene change is a hard cut.
- Nothing persists whether the editor's tips flyout was left open, so it is
  closed again on every visit.
- Rotating the window refits the editor canvas, which throws away a deliberate
  zoom. It is the right call the first time and irritating the second; remembering
  the framing per orientation would be better.
- The phone bars are keyed off orientation alone. A tablet held upright has ample
  room for the sidebar and gets the bars anyway; a width threshold would be the
  more honest test.
- Nothing on a phone reaches double-tap-to-add-a-bend reliably, and there is no
  touch route to the shift-drag override. Both are still mouse-first.
- No tagged release build yet; web deploys straight from `main`.
- Physics runs at 120 Hz, which is the main CPU cost in a single-threaded web
  build. Unmeasured on real hardware in a browser.
