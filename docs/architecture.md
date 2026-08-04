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

### Straightening a bend is a drag, not a mode

Pushing a bend out of a straight is a double-click; putting it back used to be
Erase plus a tap — a mode switch to undo a drag, in an editor whose premise is
that you drag the road. **Dragging a straight back level with the road either
side of it now straightens it.**

**However the bend got there.** A section becomes a bump by being dragged into
one at least as often as by being pushed out with a double-click, and the player
did not label which is which — so both routes straighten the same way. There are
two ways a drag can arrive at straight, and both are handled:

- an **edge** pulled level with the road either side of it, and
- **any** drag whose result simply comes back with fewer corners, which is
  `prune` finding the road no longer turns there. That is how a **corner**
  dragged back into line reads, and it used to be refused outright with "the
  circuit would cross itself" — neither true nor the problem.

Three things make that work, and it took three attempts to get there — each one
correct in code and wrong in the hand:

- **Flat is measured against the corners either side**, not against how far the
  drag has travelled. `_step_past_flat` reads the direction of travel, which
  answers "which way is the player going" rather than "have they arrived". The
  first attempt used it and so stepped past every time.
- **It applies across a band, not on a single cell.** A bend shallower than
  `MIN_EDGE` cannot be represented, so the cells either side of the line are ones
  `move_edge` refuses — and `_step_past_flat` then throws the bend to the far
  side. That left the straighten position a knife-edge with a flip on either side
  of it, so dragging a bump back **flapped between the two sides and never went
  flat**. Those cells were dead space; making the whole band mean "straighten"
  turns a knife-edge into a target.
- **It is applied live, not on release.** Holding the bend in place and
  straightening only when the button came up meant the canvas disagreed with the
  outcome: the player had to *know* the rule rather than see it. The road is now
  drawn straight the moment the drag enters the band, and the bend is kept aside
  in `_flatten_saved` so dragging back out puts it straight back. Passing through
  on the way to the far side therefore costs nothing, which is what
  `_drag_floor` was protecting in the first place — the protection just moved
  from "refuse to prune" to "remember what was pruned".

The last one is the general lesson: **what is drawn during a drag has to be what
letting go will give you.** A gesture that commits something other than what it
is showing cannot be learned by using it.

`straighten_at` still exists for the Erase tap, and it now tries pairs one step
further out. A popped section adds **four** corners and its outer pair is only
adjacent to itself, so tapping either inner corner previously found no workable
pair and refused — two of the four dots worked and two did not, with an error
message about needing four corners that was not the reason.

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

The target is **Horizon Chase**: vivid flat-shaded colour blocking, no textures
on the geometry, big graphic skies, bright and readable, never grimy. The Kenney
kit is already untextured flat-shaded geometry, which is the expensive half of
that look done, and it survives the compatibility renderer the web build is stuck
with.

### The colour grade

Every circuit is seen through a **lookup table**, one per `CircuitLook`, built by
`scripts/track/colour_grade.gd`. It is the first thing in the frame that is
authored rather than derived, and it is where the game's visual identity is
supposed to live.

The model is **ASC CDL** — per-channel slope, offset and power, then saturation.
Not invented here: it is the colour decision list the film industry standardised
on, it is four parameters, and it is exactly enough. Slope multiplies, so it
moves highlights and leaves black alone; offset adds, so it moves shadows and
washes out toward white. **Cool shadows against warm highlights — the operation
most responsible for a game looking like itself — is therefore just an offset
that crushes red and a slope that lifts it.** An earlier draft carried
`shadow_tint` and `highlight_tint` next to CDL before anyone noticed they were
the same two dials under different names.

> **Why this replaced three `Environment` dials rather than joining them.**
> `adjustment_saturation`, `adjustment_contrast` and `adjustment_brightness` were
> the whole grade until M18, one `Vector3` per hour in `SkyPreset`. They work, but
> they are three *global scalars*: they can only move the whole image at once, and
> no combination of them puts warm light in the highlights while leaving the
> shadows cool.
>
> Godot applies all three **before** colour correction, so leaving them set would
> grade the image twice. They are pinned to 1.0 and `ColourGrade.from_bcs` carries
> their meaning into the table instead. `adjustment_enabled` still has to be
> **true** — it gates the whole block, colour correction included.

**The migration is exact, and that is asserted rather than claimed.** Godot's
brightness-then-contrast arithmetic is `colour * brightness`, then
`mix(0.5, colour, contrast)`, which expands to a slope of `brightness * contrast`
and an offset of `0.5 * (1 - contrast)`. So a look nobody has art-directed yet
renders pixel-identical to how it rendered before the file existed.

That fallback is what let the six looks be graded **one at a time**: the grading
system landed in one commit with `bright` and `night` authored and the other four
provably untouched, and the remaining four followed in the next. All six are
authored now, so the conversion is checked directly against Godot's own
arithmetic rather than through an unauthored look. It stays because it is still
the right answer for a *seventh* hour — a new look renders as its scalars say
until someone sits down with it.

> **The six are not all split the same way, and two are not split at all.**
> `bright`, `evening`, `dusk` and `night` are the hours with a sun in them and all
> carry cool shadows against warm highlights, at increasing strength. `storm` is
> cool at *both* ends on purpose — a storm has no warm light source in it — and
> leans on `power` above 1 to sink the midtones while black and white stay pinned.
>
> `overcast` is the one that could not have been expressed by the three scalars at
> all: its offset is **positive**. Flat light casts nothing, so the shadows are
> lifted rather than crushed, and a low contrast is not the same move — it drags
> the highlights down with the shadows up, which is a fog rather than an overcast
> day. The suite pins the sign, because it is the whole look.
>
> Two things learned tuning these by eye. **Global saturation above about 1.3
> starts colouring the white kit**, which is the kit the whole palette is read
> against — the hour it used to sit at 1.45 had pink grandstands and lavender
> guardrails, and pulling it down to 1.26 while widening the per-channel split
> gave a warmer picture with the whites intact. And **warming an hour whose sky is
> already at the top of the range is done by dropping blue, not lifting red**:
> sunset's red channel is near 1.0 across the whole sky, so a red slope only
> flattens the gradient the sky is made of.

> **Two traps, both found by the suite.**
>
> **Do not clamp between the offset and the saturation.** Godot's chain clamps
> nothing until the framebuffer write, so a dark pixel that an offset takes below
> zero *stays* below zero and drags the channel mean down with it. Clamping there
> is a plausible-looking mistake worth about 0.03 in the shadows — small, and
> right in the range the migration has to be exact in.
>
> **Saturation is a flat channel mean, not luminance.** Because Godot's tonemap
> desaturates toward `dot(vec3(1.0), colour) * 0.33333` and every grade was
> authored against that. A luminance-weighted mean is more correct and would
> silently re-grade six looks the day it arrived.

The table is 16 cubed — the low end of what film LUTs use, and about 12 KB against
98 KB at 32. It is attached **on load** by `TrackBuilder.grade_scene`, not baked,
because an `ImageTexture3D` is built at runtime and does not survive
`PackedScene.pack` — the same serialisation limit that keeps `surface_road` out of
the builder. A circuit carries the *name* of its look as metadata and the table is
fetched through it. Grading is also, notably, **one of the few large visual levers
the Compatibility renderer still has**: `Adjustments` are supported there, while
volumetric fog, SSIL, SDFGI and depth of field are not.

> An ungraded frame is a **plausible** frame — merely flatter than it should be —
> so nothing catches this failing by looking at it. `tests/run_tests.gd` asserts
> the LUT reaches the scene the player actually gets.

**The Compatibility renderer samples the table, and that was checked rather than
assumed.** Running the game under `--rendering-method gl_compatibility` and
comparing region means against the Forward+ render puts every graded region within
one or two of 255, in the same direction and by the same amount. The renderers do
differ — the white kit sits about ten points brighter under Compatibility — but
that difference is present in the *ungraded* frame too, so it is ambient and
tonemapping, not the grade. This mattered enough to check first: if grading had
not survived the platform, most of M18 would have needed rethinking.

> A throwaway `SceneTree` script that builds one layout under each look, frames it
> from the chase camera and a high wide shot, and saves a PNG per look per
> renderer — the same `_diag_*.gd` pattern the handling measurements used. Grades
> are data and the LUT is built at load, so the loop is edit, run, look, with no
> rebake in it. Deleted once the looks were settled.

### Wind, and the two things it has to survive

The circuit had exactly one moving thing in it: the car. Everything else was
nailed down, and a forest that does not move reads as a backdrop rather than a
place. `assets/shaders/wind.gdshader` is a vertex displacement on the scenery
that ought to be moving — no CPU cost, no per-frame script, no new nodes, and it
works under the Compatibility renderer, which rules out most of the alternatives.

**It has to survive `MultiMesh`, and that decides where the phase comes from.**
The trees are a `MultiMesh` precisely so a forest costs one draw call, which means
there is no node per tree to hang a phase on. `MODEL_MATRIX[3].xyz` — where the
instance stands — is the only per-instance identity a vertex has, and it is what
the phase is built from. The two failures either side of that are both worth
naming: taking the phase from `VERTEX` gives every vertex of one tree a different
phase and the tree *shears*, and taking it from nothing at all puts a whole forest
in lockstep, which reads as the camera moving rather than the trees.

**It has to survive the props being placed at arbitrary yaw**, which is why the
shader declares `world_vertex_coords`. `VERTEX` then arrives already through the
model matrix, so the lean is a *world* direction and every prop leans the same
way. Without it the same `direction` blows a different way for every prop, and
wind that changes direction per tree is not wind. It also removes the alternative
— carrying a world offset back through the instance basis, which is either an
`inverse()` per vertex or an assumption that the scale is uniform.

Height is measured as `VERTEX.y - MODEL_MATRIX[3].y`, not world Y: scenery beside
a raised section stands on ground of its own, and measuring from zero would bend
it as though it were buried. The displacement is a power of that height, above 1,
so the base is still whatever material is on it — which is also why **every**
surface of a prop goes into the wind and not just the leafy one. A tree is a
`grass` canopy and a `bark` trunk, and moving one without the other detaches them.

> **The colour trap, which is the opposite of the sky's.** `_windy` hands
> `albedo_color` to the shader **untouched**, while `_build_environment` converts
> to linear on the way into `sky.gdshader`. Both uniforms are declared
> `source_color`; the difference is the shader type. A `spatial` shader's
> `source_color` uniform is converted for you — `ground_grid` and `tarmac` also
> pass their colours raw — while a `sky` shader's output is used directly as
> radiance and is not. Converting first here renders the forest at about *half*
> its authored brightness, canopy green (0.64, 0.87, 0.76) arriving as
> (0.15, 0.65, 0.43). It is a plausible forest, so only a comparison finds it.

> **The chequered flag is the surface that nearly got left out.** Almost all of
> the Kenney kit is untextured flat colour, so an early version skipped any
> surface carrying a texture — and the one prop that has one is
> `flagCheckersSmall`, which is the marker the **default** theme uses and
> therefore the marker on every circuit a player draws. The shader takes an
> optional albedo texture with no companion `bool` and no branch, because Godot
> binds opaque white to a `sampler2D` nobody assigned: an untextured prop
> multiplies its colour by 1 and is unaffected.

Wind settings are baked into the circuit rather than applied on load, unlike the
colour grade — a `ShaderMaterial` on a duplicated mesh serialises fine, where an
`ImageTexture3D` does not. A change to `WIND_TREE` or `WIND_FLAG` therefore needs
`tools/build_track.gd` re-run.

> **Tuned by driving it wrong on purpose.** A subtle wrong bend and a subtle right
> one are the same picture; an exaggerated one is not. The tree sway was pushed to
> 0.22 — a gale — to check that trunks stayed planted, that the canopy carried the
> movement, and that neighbouring trees were visibly out of phase, then brought
> back to 0.07, which is about four degrees.

### Camera shake, which is a rotation and was a translation first

The camera already carried one thing that says *speed* — the FOV kick, scaled
against `camera_fov_reference_kmh` per preset — and shake is the rest of that
set. It lives in `CarTuning` beside the framing for the same reason the framing
does: it is part of how a car feels, not a property of the scene.

**Shaking the camera's position does not shake the camera.** This was built and
measured that way before it was built the right way, and the reason it fails is
geometric rather than a matter of taste: a translation of `d` moves an object at
distance `z` across the screen by `d/z`, so it moves whatever is nearest and
almost nothing else. The car is 4.2 m away and the circuit is tens to hundreds of
metres away, so a 0.05 m shake slid the car eight pixels and left the road, the
trees and the horizon within a tenth of a pixel of where they were. That is a car
with a loose wheel — the opposite of the thing being asked for. A rotation moves
the whole frame by `focal x angle` at every depth. The measurements are in
`docs/tuning-journal.md` under M18.

**Yaw and pitch, never roll.** The horizon is the one line in frame that is
reliably level; rolling it is both the shake that disorients and the shake that
reads as the car spinning. The suite asserts it twice — once that the waveform's
third axis is unused, and once off the basis that actually gets applied, because
a roll term costs one character to introduce where the two are combined.

**The smoothed aim is held separately from the transform.** `_aim` is what the
rotation lag smooths toward; the shake is applied on top of it, and the result is
what goes into `global_transform`. Reading the shaken basis back into the next
frame's `slerp` — which is what happens if there is only one of them — puts the
buzz through a low-pass filter whose cutoff is the camera lag, so it lags its own
amplitude and never returns to centre. It looks like a camera slowly swimming
rather than like a bug, which is why the suite runs the same eight frames with
the shake off and on and compares the aim.

> **The waveform has a frame rate to live inside, and this is the trap.** The
> camera is driven at 120 Hz in `_physics_process` and *seen* at 60, or at
> whatever a browser gives it, so the display is what samples the shake. The first
> version summed harmonics at 2.37x and 3.11x an 11 Hz base — 26 and 34 Hz, both
> past a 60 Hz Nyquist limit — and anything above half the display rate aliases
> into a slow wobble that reads as a bug in the smoothing. The rates now live in
> `SHAKE_X` / `SHAKE_Y` as a table rather than as four sines written out,
> precisely so the fastest one can be asserted against the base frequency.

Surface comes from `RoadSurface.shake_of`, which is derived from `relief` rather
than being a fourth number per surface. `relief` already *is* how much shape a
surface has — the amplitude the road shader bends its normals by — so a surface
that looks broken up is one that feels broken up, with no way for the two to
drift apart. It is normalised against the table's own maximum, so adding a
rougher surface rescales the others instead of pushing the camera past what the
tuning was set against.

> **Not yet offered as a setting.** Camera shake is a common accessibility
> toggle and there is a natural home for one — `GameState` already keeps
> `analogue_input` and `audio_enabled` this way, and the pause menu already
> carries rows. It is deliberately not done in the same change as the effect
> itself: the amplitude here is a few pixels of a level frame rather than a
> lurch, and a setting is worth adding once there is a set of motion options to
> add rather than one.

### Speed lines, and why they are not a blur

The third thing the game does to say *fast*, after the FOV kick and the shake,
and the three read the same `camera_fov_reference_kmh` so a quicker preset is
quicker in all of them. `scripts/ui/speed_lines.gd` is a `Control` at the bottom
of the HUD layer that draws a few dozen streaks radiating from the middle of the
frame, each running its own loop from the middle outward and fading in and out
across it.

**A radial blur was the obvious version and it was rejected before any of it was
written.** It is a full-screen pass sampling the screen texture on a build that
is single-threaded WebGL 2 — and, the part that actually decides it, *it smears
the flat silhouettes that are the identity*. This game is untextured colour with
hard edges; blurring it buys a frame that could have come from any engine, which
is the same argument that moved the PBR pass out of this milestone. Drawn
streaks are a graphic device rather than a photographic one, and they cost a few
dozen `draw_line` calls, no shader, no screen texture and no second viewport.

**They move outward rather than sitting there**, because a static set of streaks
is a vignette and a vignette says nothing about speed. What the eye reads is
arrival rate — the same claim `_scenery_markers` makes about roadside props, one
layer closer to the viewer.

The radius is an **ellipse matched to the viewport**, not a circle: on a 16:9
canvas a circle of streaks reaches the left and right edges long before the top
and bottom, so the effect would be a pair of side curtains. The ellipse holds in
portrait too, which is the orientation a phone actually plays in.

> **The colour has to come from the surface, and only a render found that.** The
> first version drew white. On a snow circuit — a white road under a white
> outfield under a pale sky — the effect was *not there*, at any opacity, and no
> tarmac screenshot could ever have shown it. `streak_colour()` takes the road's
> own `base` colour out of `RoadSurface` and picks the theme's text colour under
> about half luminance and the theme's page colour over it, so the pair is the
> contrast the rest of the interface already uses. The hour is deliberately not
> read: a dark hour dims everything including snow, and the ordering by surface
> holds in all of them.

Two things it must not do, both asserted rather than looked at. It must never
draw across the middle of the frame — the car and the road ahead are in there,
and a streak over either is a scratch on the picture — and being a full-frame
`Control` over the driving pads, it must never swallow a touch. The second is
the shape of a bug already fixed once on the countdown label.

### Tyre marks: what shape, where, and for how long

Three separate rules, each of which has been wrong at some point.

**Shape.** On dirt and snow a mark is a shallow trough with a **raised shoulder
either side** — displaced material, not a carved hole — built as real geometry
with real normals and *lit*, so the sun catches one ridge and not the other.
That shape is forced: the road is Kenney tiles, and a rut displaced *downwards*
would be hidden behind the tile it lies on. **You cannot dig into geometry you do
not own.** It is also what a tyre on something loose really does — pushes material
aside rather than removing it — so the constraint and the physics agree.

Tarmac gets none of it. Rubber is a film; it displaces nothing, so a rubber mark
standing proud of the road would be a lie visible from any angle the light is low
at. Tarmac's mark is flat and **unshaded**, which is also what the baked
racing-line rubber in `road_overlay.gdshader` already is — the same material laid
down by the same thing should not be two materials. `RoadSurface.mark_depth`
carries the distinction, alongside `mark_always`: on tarmac a tyre marks only when
it is *sliding*, which is what makes laying rubber mean something; on loose
surfaces it marks by rolling and sliding only deepens it.

**Where.** Marks stop at the verge, tested against the collision world rather than
against the centreline: `TrackBuilder` puts the drivable ribbon's body in the
group `road_surface`, and `TyreMarks.on_road` raycasts for it. Grass grips
*exactly* like tarmac here, so nothing in the physics distinguishes on from off,
and a set of ruts wandering across a field is the clearest possible sign that
marks are drawn by a rule rather than by a surface. The ribbon already knows about
crossings and bridge decks; a distance-from-centreline test would be a second
approximation to maintain, and would mark the deck and the road beneath it at
once. The cost is one ray per *mark*, not per frame.

> Two traps live in that one raycast.
>
> **`add_to_group` is not persistent by default.** Without `add_to_group(name,
> true)` the group lives only on the node in memory and `PackedScene.pack` drops
> it — so runtime-built circuits would have known where their road was and every
> shipped one would not.
>
> **The probe walks down through what it hits.** The flat sections of the ribbon
> and the top face of the ground slab are both at y = 0 — exactly, not nearly — so
> which one a ray returns first is arbitrary. It returned `Ground` from a point
> the car was standing on, which would have suppressed marks on every flat part of
> every circuit.

**How long.** For the whole session. They were a ring buffer, which is the cheap
answer and the wrong one: a trail that erases itself from behind means the line
you took two corners ago is gone before the lap is finished, and coming round to
a circuit that remembers you is the entire appeal on dirt.

Permanence is affordable **because of** the quantisation, not in spite of it. A
mark is claimed against a patch of ground, so a second pass over the same line
deepens the mark already there instead of laying another beside it — which is what
a rut really does, and which bounds growth by *distinct ground touched* rather
than by session length. New ground goes into a fresh 640-instance chunk;
`MultiMesh.buffer` can only be assigned whole, so a single growing buffer would
re-upload the whole session's marks every time a wheel turned. A chunk is a fixed
40 KB however many chunks exist. Past a 96-chunk ceiling the car stops marking
new ground and, deliberately, nothing already laid disappears.

> **Written through `MultiMesh.buffer`, never `set_instance_transform`.** The
> per-instance setters do not survive a headless run — this project already has
> the scar, from barriers whose transforms all collapsed to identity (tuning
> journal, M3b). Confirmed again here: headless, a colour set to alpha 0 reads
> back opaque and a zero-scaled basis reads back as identity, while the buffer
> round-trips exactly. It is also the only form the suite can check, which is the
> more important half — the first version of this test passed 640 marks off as
> "none on the road" because it was reading through the broken getter.

Carving real depth still needs the drivable surface to *be* a dense generated
ribbon that can be displaced in a vertex shader. The ribbon's coordinate system
exists; the road being made of it does not.

### Off the road, and the wall that had to come with it

Grass gripped exactly like tarmac for the whole of the project's life. That was
convenient — the ordered gates were the only thing discouraging a cut — and once
surfaces arrived it became actively backwards, because running wide on snow put
the car on the one part of the world with *full* grip.

`OFF_ROAD_GRIP` is 0.55, composing with the surface exactly as everything else
does: dry grass is 0.55 of dry tarmac, grass under snow is 0.55 of snow. There is
no table of off-road surfaces and no verge-versus-field distinction, because the
world outside the ribbon is one flat plane and claiming to know more about it than
"not road" would be inventing detail the geometry does not have.

**The walls came on in the same change, and that pairing is not optional.** A
penalty for leaving the road with nothing to stop you leaving it means a car that
slides off into four square kilometres of empty field with no grip to turn around
on. They were switched off for exactly as long as leaving the road was free.

Two things about how they are built:

- **Collision only.** The rails you see are scenery, one `MultiMesh` built by
  `_scenery_barrier`. An earlier version of `_build_walls` instanced a
  `MeshInstance3D` per rail — several hundred draw calls a lap on a
  single-threaded compatibility-renderer web build, every one of them inside a
  rail that was already there.
- **Built on the ribbon's own edge**, from the same `_ribbon_point` the road
  collision uses, rather than by offsetting the centreline by a constant.
  `_offset_line` pushes each segment out perpendicular in plan by a fixed 9.8 m,
  and a size-1 corner has a 7 m centreline radius — so the inside line folded
  through the centre and put the wall **on the tarmac**, 6.6 m from the
  centreline. It also ignored roll and elevation. Standing the wall on the ribbon
  edge makes it the boundary of the drivable surface by construction, and it
  inherits banking and height for free.

> **Ask the collision world with a masked ray, never by inspecting what came
> back.** The flat parts of the ribbon and the top face of the ground slab are at
> exactly y = 0 — not nearly — so which one an unmasked ray returns is arbitrary.
> Walking down through the hits and excluding each collider in turn does not
> rescue it: measured across the shipped circuits, the same `Ground` body came
> back **three times running** from a single point, which exhausted the walk and
> reported road as field on 40% of Suzuka. That is half the grip vanishing at
> random over a third of a lap with nothing on screen to explain it.
>
> So the road body adds `TrackBuilder.ROAD_LAYER` to its collision layer, and a
> ray masked to it can hit nothing else — one cast, one answer. The group is how
> you *find* the road; the layer is how you *ask about* it. `car_controller` and
> `TyreMarks` both use it, so the tyres and the marks they leave can never
> disagree about where the circuit is.

### The road has two edges, and a bridge only has one

`_edge_half` is where the road's usable edge is at a point, and it is not the same
number everywhere.

On the ground it is `RIBBON_HALF` — the collision ribbon runs 1.4 m past the
visible tile, out over the verge, which is deliberate: it catches a car that has
run wide instead of dropping it off an invisible kerb. **On a raised section there
is no verge.** The tile *is* the deck and it stops at `ROAD_HALF`, so anything
placed beyond that is standing in mid-air.

That is exactly how the trackside railing looked on every bridge on every circuit:
its outer face sat at 8.9 m against a deck edge at 7. The rail follows the deck
edge now, and **so do the collision walls**, so the thing you can see and the thing
that stops you still coincide.

> **Measure the railing by triangle, never by vertex.** `_barrier_vertices` keeps
> only the points where the road turns, climbs, or has run straight for a tile —
> so a straight is drawn as *one long quad with no vertices in the middle of it*.
> A check that marks a stretch "railed" wherever a vertex lands reports that quad
> as a hole, and two separate investigations chased 50 m and 16 m "gaps" that were
> nothing of the kind. Walking the triangles and marking the arc each one actually
> spans is what finally answered it: the worst genuine hole is 7 m at the lap seam
> on three circuits, and 32 m at Suzuka's crossing, where rail cannot stand on the
> other leg's tarmac and the break is correct.

> **A curve offset inward by more than its own radius folds back through
> itself.** That is the classic parallel-curve failure, and it is what tied the
> railing in a bow at every tight corner: a size-1 corner has a 7 m centreline
> radius and the rail sat 8.4 m in, so the offset inverted and the quads between
> consecutive stations came out crossed.
>
> The fold is detected **where it shows** rather than predicted: if the step from
> the last station to this one points *against* the road, this offset is
> impossible here and a tighter one is tried. The alternative — computing the
> local radius and clamping against it — needs two sign conventions (which way the
> road turns, and which side of it this rail is on) and gets one of them wrong.
> Measured after: no rail vertex on any circuit comes closer than 7.00 m to the
> centreline, which is exactly the tarmac edge.

> **The clearance rule culled both rails and left neither.** A railing point that
> lands on another leg's tarmac has to go, and the old rule dropped it on the
> reasoning that "the barrier already standing between them serves both". Where
> two legs run one tile apart, *both* sides are rejected by that rule — each
> assuming the other exists — and neither is built. It now steps the rail inward
> and only gives up if nothing fits.
>
> Tucking the rail to the deck edge then broke it a second way: at 7 m from its
> own centreline it failed a 7.7 m clearance **against the very road it was
> lining**, so the railing vanished from every raised section. `_clear_of_road`
> takes an optional stretch of the lap to exempt, and the railing is the one
> caller that is *supposed* to be close to the road. Posts, trees and markers ask
> the plain question.

### The circuit carries its own centreline

`TrackBuilder` writes the centreline onto the built root as metadata. A shipped
circuit is a packed scene and the layout that produced it lives in `tools/`, which
the game never loads — so until now the only things that knew the shape of a baked
circuit were its collision ribbon and its sixteen gates. That is enough to drive on
and not enough to reason about: a scripted lap, a minimap, an off-the-racing-line
cue and a kerb all want the same two numbers, how far along and how far across.
About 20 KB on the longest circuit, a fifth of what the audio costs.

### The start of a race

**3 — 2 — 1 — GO**, as a number in the middle of the screen, with three lamps on
the gantry lighting one at a time and turning green together.

> **The first attempt was a real Formula 1 start** — five columns of two, a second
> apart, extinguishing together — and it is the correct grammar for a motor race
> and the wrong one for this game. A Formula 1 start asks you to *interpret*
> lights: the signal is the moment they go **out**, which you only read if you
> already know that is the rule. An arcade racer wants the opposite. The number is
> the instruction and the lamps are decoration, which is why the lamps count *up*
> as the number counts down — three lit means "about to go" at a glance, without
> looking at the thing you were told to look at.

Three decisions behind it:

- **The lights own the sequence, not `race.gd`.** The race needs one fact — am I
  held — and the rest is presentation. A circuit with no gantry asks the question,
  gets "no", and races immediately rather than waiting on a node that is not
  there.
- **Not a coroutine.** An `await` chain runs on the scene tree's own timing and
  keeps counting while the game is paused, so pausing on the grid would start the
  race behind the pause menu. Counting in `_process` stops when the tree stops.
- **One node per lamp.** They light in sequence, and a single shared material can
  only be all on or all off — which is a set of traffic lights rather than a
  countdown.

> **The lamps are hung from the gantry, not placed at a guessed height.** They sat
> at a constant 7.4 m while the `roadStart` arch tops out below 5.65 — a metre and
> a half of clear air between the lights and the structure they are supposed to be
> bolted to. A constant cannot know how tall a Kenney tile is, so the arch is
> measured out of the scene that was just built and the bar hangs a fixed drop
> below it. A circuit whose start tile cannot be measured falls back to the old
> constant rather than putting the lights on the road.

> **The car is held on the brakes, never `freeze`d.** `freeze` takes a
> `RigidBody3D` out of the simulation entirely: its suspension never compresses,
> its wheels never find the road, and the moment it is unfrozen the whole car
> falls onto its springs. Every race start visibly **dropped the car onto the
> track**. Held through the controller instead — engine force zero, brakes on,
> steering centred — the physics runs the whole time, the car settles on its
> springs while the count runs, and at the release nothing moves that was not
> already moving. `LEAD_IN` is long enough that the settle finishes before "3".

> **The ghost must not copy the car's shadow.** `car_shadow.gdshader` draws a soft
> contact patch, and all of that softness is in the shader — the mesh under it is
> a plain 2 x 3.6 m rectangle. `GhostCar` copies every mesh off the car and
> repaints it in translucent green, so it copied that one too, and what slid along
> the road under the ghost was a **glowing rectangle**. It is skipped rather than
> kept with its own material: a ghost is a replay of a lap, not a second car, and
> a contact shadow under it would claim it is really there.

> **The wheels get their own material, with a rim of their own.** The bodywork's
> rim is a fresnel edge tinted to the *sky of the circuit being raced*, which is
> what makes the car read as belonging to the scene it is in. On bodywork that is
> a line along the silhouette. On a wheel it is the entire wheel — fresnel covers
> almost all of a small round object seen from outside, and a tyre is black, so
> the rim emission is the only colour on it. The tyres came out **red at Monte
> Carlo and blue at Ardennes**: they were reporting the horizon.
>
> Removing the rim outright was the obvious fix and the wrong one — a black tyre
> on dark tarmac disappears into the road, and the car's own shadow decal
> underneath takes what contrast was left. What a tyre wants is an edge that does
> not move: a fixed cool grey, tighter to the silhouette than the bodywork's
> (`rim_power` 5 against 3.5) so it draws a line rather than washing the wheel.
> The figures live on `CarSpec`, because three places have to agree — the builder
> that makes the material, `race.gd`, which must leave this one material alone
> when it tints the rest, and the suite that checks they have not drifted.

> **Exactly one directional light may cast shadows.** Both the sun and the
> floodlight key cast until this was found, and two directional shadow maps over
> the same geometry is what made the car's **wheels** look wrong — and look wrong
> *differently on every circuit*, because only the lit hours carried a second
> light, and its angle and strength changed with the hour. A small curved object
> shadowed twice from two directions is all banding. The **brighter** light casts,
> rather than the key always: at sunset the sun is still the light and the masts
> are only just switching on. A moon at 0.28 casting shadows at night was wrong on
> its own terms as well.

> **A lit lens has to survive the grade.** The lens colours were multiplied by
> 3.2, on the reasoning that a lamp should be pushed above 1 so it reads as a lamp
> rather than as paint. It does the opposite. The scene is tonemapped with ACES at
> a white point of 2.1, and **an unshaded albedo is not exempt from that** — it is
> a whole-frame post-process. Everything past the white point compresses toward
> white, so the red came out pale orange and the green came out near-white: the
> lamps were described, accurately, as "yellow and white". At x3.2 the green lens
> keeps barely half its saturation; at x1.35 it keeps three quarters. What makes a
> lens read as lit is **contrast with a dark housing**, not magnitude — blowing
> past the white point only trades the colour away for brightness the tonemapper
> then takes back. The suite models the same curve, because the alternative is
> looking at it, and looking at it is exactly what did not happen.

> A node added to `root` **before the tree's first frame has not run `_ready`**.
> The suite released the car in `_initialize`, found nothing to release because
> the track did not exist yet, and the first driving test then read an engine
> force of zero from a car still sitting on its brakes. It releases on frame 1.

### HUD text over a bright sky

Every `Label` carries a dark outline, set as the **default** for the type rather
than as a variation something has to opt into.

The HUD panels are translucent on purpose — a solid block would punch a hole in
the road — so whatever is behind them comes through, and what is behind them at
the top of the screen is a big graphic sky that runs to near-white at the horizon.
Pale text on a pale sky is unreadable at exactly the moment a lap time appears. An
outline costs one draw pass, works over any background including ones added later,
and leaves the panels the weight they were designed with. Menus sit over dark
surfaces, where it is invisible.

### Lighting the track

Two things light a circuit here, and a third stops it going black.

**A key light.** One `DirectionalLight3D`, warm, steeply down, `shadow_enabled`.
It lights the road, the barriers and the buildings uniformly and gives the car a
shadow that swings as it turns. The field around the circuit stays dark for free,
because the ground plane is `unshaded` and receives nothing — the contrast a
floodlit circuit is made of falls out of the existing architecture.

**Floodlight masts.** Real fixtures, standing at the verge on alternating sides,
21 m tall with a lit headframe, one every 26 m. Each throws a cone at the road
about 50 m *ahead of itself*, so the pool lands as a long ellipse along the track
and consecutive pools overlap end to end.

**A `road_glow` floor**, a small emission term on the road material whose only job
is to stop pure black between fixtures.

> **Why the masts aim down the track rather than at their own feet.** A spot goes
> to **zero at its cone edge**, whatever `spot_angle_attenuation` is. A cone aimed
> straight down stamps a circle, and circles tile badly: a row of them is a row of
> discs with dark rims. Struck at a shallow angle the same cone lays a long
> ellipse, and ellipses along a line overlap properly.
>
> Aimed along the **centreline**, by stepping forward through the resampled
> points, not by extrapolating the tangent — a straight line 50 m from a corner
> leaves the circuit, and half the masts on La Sarthe were measured aiming into
> the field with only the width of the cone keeping the road lit.
>
> The headframe runs **parallel with the track** (local Z, which `_yaw_along` lays
> down the circuit). Built along local X it reached 4.5 m either side of the pole:
> out over the tarmac on one side and into the field on the other, at whatever
> angle each corner happened to take.

Measured on the drivable surface, computing what the renderer computes: **no point
of the road is unlit, and no point depends on a single cone** — a lone cone means
its edge is nearby, and an edge is zero. Brightness under the masts varies about
two and a half to one, which on top of the key light reads as pools rather than as
spots.

> **The painted light pools are gone.** They were flat additive discs laid on the
> tarmac under each column — a stand-in for lighting from before there was any,
> and defended here for a long time as the graphic statement, a hard-edged pool
> being more in keeping than a smooth falloff. That stopped being true the moment
> real fixtures existed. What they actually looked like, said three separate times
> by the person playing it, was **yellow glow spots**. A disc of colour added to
> the road is not light and no tuning makes it behave like light: it does not move
> with the eye, it does not fall on the car, and its edge is a circle from every
> angle.

**Ambient comes down** at the dark hours, and that is a consequence of the
lighting working rather than a separate decision. Ambient is a flat fill: every
unit of it is contrast the lights do not get to create, and a night lit mostly by
ambient is an overcast afternoon with the brightness pulled down.

> **Five separate ways this was wrong before**, each kept because each is a
> different mistake.
>
> **Aim.** The lamps were anchored on the column line 13.3 m from the centreline,
> with a `+ Vector3(0, 0, 0)` where the offset back to the road should have been,
> and aimed straight down. A lamp 9.5 m up with a 28 degree half-cone lights a
> ring from 8.25 m to 18.35 m out; the road ends at 7. **No lamp could touch the
> tarmac at any energy.**
>
> **Spacing.** They then inherited the columns' 70 m spacing, so the only
> continuously lit thing was whatever the headlights pointed at — a circuit that
> reads as a torch being carried round it. No amount of energy fixes a gap.
>
> **Units, twice.** `spot_angle` is the **half**-angle, measured from the axis to
> the edge, which is why it caps at 89.9 rather than 180; treating it as a full
> angle and halving it made cones four times wider than intended, so a "80 degree"
> cone reached 125 m from a 22 m mast. And `light_energy` figures are not
> comparable between lights at different distances from what they light: a mast is
> 22 m away and a headlight about 8, so beams that measured as a safe margin were
> delivering **3.4 against a mast's 1.4**. Compare *delivered*, never raw.
>
> **Energy.** Chosen from geometry with nothing to compare against, the masts hit
> 11.0 — delivering 9.3 to a circuit whose moon is 0.28, **33x the light of the
> hour being lit**. They are set against the noon sun's 1.15 now.
>
> **Scope.** `surface_road` matched Kenney's shared `"road"` material name across
> the whole scene, so twelve scenery surfaces per circuit — building aprons, pit
> garage floors — were re-surfaced as tarmac. Invisible while tarmac was only a
> colour; **glowing buildings** the moment the road gained an emission floor. It
> matches by branch now: `RoadVisuals` and nothing else.
>
> **And one that hid in a measurement rather than in the code:**
> `look_at_from_position` works through `global_transform` and quietly does
> nothing on a node outside the tree. The whole circuit is built detached and then
> packed, so it could never work — every mast was left pointing along its default
> -Z, horizontally. The aim is built as a `Basis` now.

> **The headlights are handed their hour, not given a rule to derive it from.**
> The first version read the scene's sun and ambient and turned on in proportion
> to the darkness. It was a nicer shape and it broke, because sun and ambient are
> dials for how a scene *looks* — they get rebalanced whenever the look changes,
> and they have been twice since. The circuit carries the figure as metadata, the
> same way it carries `road_glow`, and `race.gd` hands it over.
>
> It arrives **before the car is in the tree** — `race.gd` instances the car,
> tints its rim, sets its hour and only then adds it — so a `set_hour` that wrote
> only to lights collected in `_ready` did nothing whatever in the game while
> passing every test, because the suite's car was already in the tree.

Checked for **every hour**, on a circuit built from scratch, not only on the
shipped circuits that happen to be dark. Checking less than that is how three
rigs in a row survived a green suite.

### Surfaces have to be made of something

Grip is what makes snow *be* snow, but colour alone is not what makes it *look*
like snow. Dirt and snow first shipped as recolours of the tarmac shader and read
as coloured card, because they are surfaces **made of relief** and had none.

So `tarmac.gdshader` bends the surface normal with the same procedural height
field it already tints with: two extra taps give a gradient, the gradient
perturbs the world normal, and the scene's own sun lights the near side of every
clod and drift. Bump mapping with no texture and no UVs the road does not have —
which matters, because the road's UVs come from tiles of three different lengths
and any sampled texture seams at every join.

`relief` is **zero on tarmac**, and that is the point: all three run the same
shader, and tarmac asking for no relief is what makes the other two feel like
different materials rather than different tints. Tarmac genuinely is flat, so
colour noise alone describes it honestly.

Two surface-specific terms sit on top. `stones` scatters lighter, rougher
specks on dirt, thresholded hard so they read as objects lying on it rather than
as more noise in it. `sparkle` is snow's alone, and it is **not drawn as light**:
it punches holes of low roughness through the surface so the real sun makes real
specular highlights that come and go as the camera moves. Drawn as emission they
would sit on the snow like confetti and be just as bright at midnight.

The condition also leaves the road. `field`/`field_amount` blend the ground plane
toward the surface — a white circuit through a green summer field read as a
painted road, not as weather. *Blended*, not replaced, so the circuit's theme and
its hour still come through and a snowy dusk stays dusk.

> `surface_road` runs on load, so it must be safe to run repeatedly. The field's
> material lives inside a packed scene and `instantiate()` **shares** resources
> rather than copying them, so tinting it in place would compound with every race
> started. It reads the untouched mesh material and writes a fresh surface
> override, which makes the call idempotent — and clears the override on tarmac,
> so drying out actually dries the field out.

### The road's own coordinate system

Rubber down the racing line, and later tyre tracks, both need the road to carry
two numbers at every point: how far **along** the lap, and how far **across** the
road. The tarmac cannot carry them. It is Kenney tiles — shared cached meshes,
one resource serving every instance of a piece — and `_reshape_tiles` only
rebuilds the handful that are banked or lifted. Giving the rest a per-vertex
coordinate would mean inlining every road mesh into every circuit.

So a **separate overlay ribbon** is generated from the centreline, laid 2 cm over
the tarmac. Built across the road, it has both coordinates by construction, and
it is the dense visual ribbon the deformation texture will want in any case.

The rubber is **baked into vertex colour** from `ParTime.racing_line` — the same
line the lap estimate is computed on, so what is dark on the tarmac is literally
the line the game thinks is quickest. One draw call, no texture, nothing
per-frame.

> **Scenery is excluded from `_road_vertices` in the suite, and this is why.**
> Several elevation tests take the highest vertex within a few metres of a point
> and compare it against the centreline, which only means "the tarmac follows the
> ribbon" while the geometry sampled *is* tarmac. The overlay has a vertex at
> every centreline sample, so on a 1-in-11 ramp it supplies a point five metres
> uphill and half a metre higher — a true fact about a slope, and nothing to do
> with the tiles. It failed the moment the overlay landed.

### The car's rim light

A car in flat colour against a road in flat colour has no silhouette at speed.
The fix this look actually uses is a **fresnel edge tinted towards the sky** — not
reflections and not clearcoat, both of which `ideas.md` reverses an earlier
instinct about because they pull towards realism.

So the car's material is a `ShaderMaterial` now
(`assets/shaders/car_body.gdshader`). Everything the `StandardMaterial3D` was
doing it does identically — the shared palette atlas, nearest filtering because
neighbouring swatches are unrelated colours, double-sided for the single-sided
windscreen, flat paint at roughness one. The rim is the only addition.

Two decisions inside it:

- **It is `EMISSION`, not a light contribution.** It has to show on the *shaded*
  side of the car, which is exactly where the silhouette is hardest to read. A
  rim that needed the sun would vanish where it is most wanted.
- **The colour is set by `race.gd`, not baked into the car.** One car scene is
  driven on every circuit, and the rim is meant to pick up the sky — a car edged
  in noon blue on Monte Carlo's sunset would read as belonging to a different
  scene. Converted with `srgb_to_linear()` on the way in, for the same reason the
  sky's colours are.

> The atlas link is the thing to guard when touching this. An earlier hand-made
> car scene sampled nothing and rendered flat white, tyres and glass included,
> which is why the scene is generated at all — and swapping the material is
> exactly the change that could drop it again. The suite checks every painted
> surface still has the texture.

### The car's own shadow

The sun's shadow lands on the **road and nothing else**. `ground_grid.gdshader`
is `unshaded` — deliberately, because flat bright grass is the look and a lit
ground plane would sink it into gradients this style does not want — and unshaded
means it receives no shadow. So the moment the car ran wide its shadow vanished
and it appeared to float.

`ideas.md` reaches the same conclusion from the other side: what is missing is not
global shading but **one reliable shadow**, and the fix is a blob that works
whatever is underneath.

Three things about it are load-bearing:

- **`top_level`.** It is a child of the car so it travels with it and is baked
  into the car scene, but it must not inherit the car's transform: the body
  rolls, pitches and leaves the ground, and a shadow doing any of those is a dark
  rectangle waving about underneath. It is placed in world space each physics
  frame instead.
- **Placed by raycast, not dropped to y = 0.** The circuits climb, bank, and on
  Suzuka cross over themselves. Dropping to the ground plane would leave the
  shadow *under the road* on an elevated section and buried in the embankment on
  a banked corner. The ray asks the same question `car_controller._surface_up`
  asks, and corrects the inverted normal from the two-sided collision ribbon the
  same way.
- **`depth_draw_never` in the shader.** It sits 3 cm above the road and would
  otherwise fight the tarmac for the depth buffer at distance.

It fades with height rather than growing, because a shadow that grew as the car
rose would read as the car *sinking*.

### Weather is an hour, not a physics change

`storm` is a `SkyPreset` like any other: heavy cloud, the closest fog, and a
grade that **desaturates** — the one place in the game the look goes down in
saturation rather than up. Horizon Chase does rain and snow as tinted overlays
with a matching sky rather than as wet surfaces and spray, which is cheaper and
more in keeping.

> **It deliberately does not touch grip**, although that is what would make it a
> gameplay variant rather than a filter. Grip belongs to the *surface*, and a lap
> record is keyed on `track|car|surface`. Lowering grip for weather without
> engaging that key would leave every lap on the circuit quietly incomparable
> with every other — the precise failure the composite key was introduced to
> prevent. M17 owns surfaces and has the key to do it with.
>
> The suite pins this: par for every circuit must equal what the model gives from
> the circuit and the car alone, so weather cannot start affecting pace without
> someone deliberately deleting that test.

### One choice sets both

`SkyPreset` says *when* and `SceneryTheme` says *where*, kept apart because they
compose. But a player picking them one at a time is being asked a question about
lighting rigs rather than about circuits, so `CircuitLook` pairs them and is the
only thing anyone selects — one button in the editor, beside the name.

Three things fall out of it:

- **A drawn circuit can be raced at any hour.** Every visual feature in M16
  applied to the four shipped circuits only; a player's track was always noon in
  a meadow, which is exactly the "same field twice" `ideas.md` warns about. The
  look is saved with the layout and travels in its share code.
- **`overcast` and `dusk` are reachable again.** Both were written as hours for
  shipped circuits and then displaced — La Sarthe went to `night` once the
  columns could light it, Suzuka to `storm` — and without a pairing to name them
  they were data nothing could select.
- **One place answers what a circuit looks like.** The hour and the place used to
  be listed separately, by track name, in two files that could disagree about
  which circuits existed.

The builder holds the chosen look as state for the duration of a build rather
than threading it through every scenery function, because by now that is eight
call sites deep.

### Where a circuit is, as distinct from when

`SceneryTheme` says what the land is made of — its colour and how much grows on
it — and is kept **separate from `SkyPreset`** because they answer different
questions and the pairs are not fixed. A forest can be raced at noon or at
midnight; Monaco is a harbour at any hour. Four hours and four places make
sixteen looks rather than four.

The racing kit has exactly two pieces of vegetation, so a theme varies **colour
and density** rather than a prop table. That is most of the effect anyway: a
dense dark treeline and a sparse pale one read as different countries without
either needing a model the kit does not have.

> **The ground plane needed the hour, and night is what exposed it.**
> `ground_grid.gdshader` is `unshaded` — deliberately, because flat bright grass
> is the look — which means it receives no light. Adding a night preset therefore
> left La Sarthe with **noon-bright green grass under a midnight sky**. So the
> hour carries a `ground_tint` the theme's colour is multiplied by: the lighting
> cannot darken an unshaded surface, so something has to.
>
> Worth noting as a shape rather than a one-off. Every unshaded surface in the
> game is outside the lighting model and needs its own answer for the hour — the
> ground, the horizon ring, the light pools and the car's rim have each needed
> one separately.

### A time of day per circuit

Four hours, one per shipped circuit: Ardennes at **noon**, Monte Carlo at
**sunset**, La Sarthe at **dusk**, Suzuka **overcast**. In Horizon Chase every
race has its own hour and that is most of why the circuits feel like different
places; three circuits sharing one lighting rig look like three parts of one
afternoon.

`SkyPreset` keeps them as **one struct each**, not four independent settings,
because they are not independent. A sunset with a noon fog colour leaves a
visible seam where the ground plane ends — fog exists to land that edge into the
sky and can only do it while it *is* the colour the sky is there. A dark sky with
noon ambient reads as a mistake rather than an evening. They change together or
not at all.

The sky itself is now a **shader** (`assets/shaders/sky.gdshader`) rather than
`ProceduralSkyMaterial`: flat colour bands, an oversized sun and stylised cloud
stripes are the look, and a procedural sky can only give a smooth gradient and a
small disc. Every term is arithmetic on `EYEDIR` — no loops, no noise textures,
no derivatives — because the web build runs Compatibility.

> **A shader uniform is linear; a `Color` property is not.** This cost a
> "everything looks white" report. `ProceduralSkyMaterial` takes a `Color` and
> converts sRGB to linear internally; `set_shader_parameter` converts nothing and
> the value is used as radiance. Handing the same numbers to the replacement
> therefore rendered the sky at roughly **twice** its intended brightness — sRGB
> 0.62 is linear 0.34 — so a horizon authored as a pale blue came out very nearly
> white, and with the fog and the grade on top of it the whole distance washed
> out.
>
> The presets stay authored in sRGB, because that is how anyone picking a colour
> thinks, and `srgb_to_linear()` is applied once at the boundary in
> `_build_lighting`. The suite compares the baked material against the *linear*
> form, so the conversion cannot be dropped silently.

**Night, and the thing it was waiting for.** The trackside columns had been
placed since M3 and had never emitted anything, so a genuinely dark circuit was
unplayable rather than atmospheric. `night` therefore carries a `lit` flag, and
La Sarthe — a 24-hour race — runs under it.

The columns light the road with **flat additive discs**, not `OmniLight3D`s. Two
reasons, and both matter: a circuit carries twenty-odd columns, and twenty-odd
point lights is a great deal to ask of the Compatibility renderer the web build
is stuck with; and a real light produces exactly the smooth falloff gradient this
look avoids everywhere else — the ground plane is unshaded, the sky is banded, the
car is flat paint. The pools are 24 m across against a 70 m column spacing, so
there is dark between them, which is the point. A continuous wash would be
daylight.

`dusk` stays as a preset in its own right rather than as the stepping stone it
started as.

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

> **Still off by default, and that is a verdict rather than a setting.** The
> sounds have been rebuilt (below) but **nobody has listened to the new ones**.
> The old ones were listened to once and called annoying, which is the only
> listening test that counts, and no amount of headless assertion substitutes for
> it. `GameState.audio_enabled` stays false, with a switch on the pause menu, and
> flipping it is a one-line change the moment someone has heard this.

There was none at all, and there is no audio in the Kenney kits — they are art.
So it is **synthesised** by `SoundBank` and baked into `AudioStreamWAV` resources
by `tools/build_audio.gd`. That keeps the game buildable from what is committed,
the same reason the theme, the circuits and the car are baked by scripts, and it
means the sounds can be tuned against handling numbers that are measured rather
than against whatever a downloaded loop was.

Saved as `.tres`, not `.wav`: a `.wav` in the project is an *import*, cached
under `.godot/`, which is neither committed nor stable. A resource carries its
samples inline, so what is committed is exactly what the game loads. Six streams
come to 100 KB, about 1% of the web `.pck`.

### An engine is a series of explosions, not a chord

The first engine summed sixteen harmonics of 50 Hz with a sub-harmonic underneath.
That is structurally what an engine's *spectrum* looks like, and it sounded like
an organ — because what makes an engine an engine is not its spectrum. It is that
the sound arrives as a **train of sharp pressure pulses**, one per firing, each
ringing through the exhaust and dying before the next. Steady sine partials
contain no pulses at all. That is the version that got switched off.

A voice is now built by placing firings *in time*: sixteen impulses across the
buffer, each a decaying resonance. Overlapping tails give the body, the impulse
edges give the lumpiness, and per-cylinder amplitudes are deliberately uneven so
there is a once-per-cycle wobble.

> **The decay rate is the load-bearing number and it is easy to get an order of
> magnitude wrong.** Firings are 10 ms apart, so a decay of 190 leaves 15% of a
> pulse sounding when the next arrives — overlap, which is the body. The first
> attempt used 26, which leaves **77%**: that is not a pulse train, it is the
> harmonic stack again with extra steps. It measured as one, which is why the
> suite pins the *shape* rather than the spectrum — split the buffer into sixteen
> windows and every window's loudest sample must land near the start of it. That
> is true of decaying impulses and false of anything continuous, and unlike a
> spectral check it cannot be satisfied by a chord that happens to be loud in the
> right places.

**Two voices, crossfaded by the throttle.** A car that only changes pitch reads as
a siren: an ear hears effort as *timbre*. `engine_load` is bright and rings on,
`engine_overrun` is dull and dies between firings, and both play at one pitch —
letting them drift apart would be two engines. Both are normalised, so the suite
tells them apart by how much of each window's energy survives into its second
half, not by loudness.

### The scrub knows what it is scrubbing on

Squeal is a **tarmac** phenomenon — tread stuttering against a hard surface, and
tonal. Dirt throws material, which is broadband and much lower; snow packs it,
quieter and duller than either. One buffer per surface, chosen by `car_audio.gd`
when the car enters the tree rather than baked into the car scene, because one car
scene serves every condition. A squeal on snow was the loudest wrong note in the
old mix once surfaces existed.

### The menus answer, more quietly

Two very short blips, a fifth apart like the countdown so they read as the same
family, but shorter and quieter and with far less harmonic edge. A menu tick is an
acknowledgement; a start signal is an instruction. A UI that answers as loudly as
the race does is the kind of thing that gets the sound switched off.

Connected to the viewport's `gui_focus_changed` rather than to each button. The
circuit list is rebuilt whenever a circuit is added or deleted, so a signal wired
per row is a signal missed on the row added next.

### The countdown has a voice

Two one-shot tones, a fifth apart: one on each number, a longer and higher one on
GO. A silent wait is indistinguishable from a game that has not started — the
number on screen says *what* is happening and the tone says it is happening
**now**, which is the part a driver takes their eyes off the HUD for. The interval
is what makes GO read as a different event rather than as a fourth number.

Plain `AudioStreamPlayer`s on the HUD rather than the 3D kind: a start signal is
not coming from a place in the world, and a positional one would fade as the chase
camera drifted back.

> **They start from silence.** A tone at full amplitude on sample zero is a step,
> and a step is a click — audible as a tick in front of the note, which on a
> countdown reads as a fault rather than as percussion. Four milliseconds of
> attack is enough, and the suite checks the first sample against the loudest one
> in the opening.

These are the only streams in the game that must **not** loop, alongside the
impact, and none of the looping rules elsewhere in this section apply to them: a
tone that ends in silence has nothing to meet at its own start.

### Impacts, now that there is something to hit

The barriers became solid in the same pass that took grip off the grass, and
running out of road was until then a silent event that simply stopped the car —
which reads as the game freezing rather than as a crash. The sound is three things
at once, because an impact is: the thud of mass arriving, the broadband crack of
the collision, and the rail ringing after. The ring is deliberately inharmonic; a
barrier is not tuned, and two partials a musical interval apart would chime.

> **Triggered by a step change in velocity, not by a contact signal.**
> `contact_monitor` costs a broadphase report every frame for something that
> happens seconds apart, and it reports *touching* — a car resting against a rail
> touches continuously. A velocity change of 3 m/s inside one physics frame cannot
> be produced by driving: the measured 1.62 g stop is 0.27 m/s per frame. It also
> catches landings from a crest for free. Repeats inside 0.25 s are swallowed, or
> scraping a barrier machine-guns.

**The rule that makes a generated loop seamless:** every partial's frequency must
be an integer multiple of the buffer's own fundamental (mix rate ÷ frame count).
A component that does not complete whole cycles inside the buffer arrives at the
loop point mid-swing and clicks — once per loop, forever, and quietly enough in
isolation to ship. It is why the tyre band is 240 summed partials rather than a
random number generator.

The engine voices satisfy it a different way: every sample is a function of
`fposmod(t - t0, duration)`, so sample *i* and sample *i + frames* are identical
by construction whatever the resonant frequency. A noise *table* of exactly the
buffer's length is periodic for the same reason and is safe to index modulo —
the restriction only bites when noise is generated per sample under a continuous
envelope. The impact stream is the one that must **not** loop.

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
