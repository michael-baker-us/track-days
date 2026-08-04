# Handoff — M18, step by step

Scratch file for picking up M18 in a fresh session. Delete it when M18 closes.

## Resume prompt

Paste this into a fresh session:

> Read `docs/handoff.md`, then continue M18 from the next action. Keep the same
> stop-point discipline: one item at a time, suite green before moving on, and
> update the handoff before you finish.

Swap the next action for a specific step if you want a different one — e.g.
"…continue M18, but do the particles step (5) rather than speed feedback."

Read `docs/roadmap.md` M18 for the *why*; this is only the state of play and the
next action. Everything below assumes:

```bash
GODOT=/Users/michael.baker/Downloads/Godot.app/Contents/MacOS/Godot
```

---

## Where things stand

**Steps 1 to 5 are done. The suite is green — 2064 checks. The tyre spray is the
working diff; everything before it is committed.**

Step 1 (the grading system) shipped as `39e465b`, step 2 (all six looks authored)
as `bd3d09f`, step 3 (wind) as `5c15be2`, step 4's camera shake as `999d288` and
its speed lines as `40542ce`.

| File | What it is |
| --- | --- |
| `scripts/car/tyre_spray.gd` | New. The plume. Read the header before changing it — three things it got wrong first are written down there, and two of them are invisible in a still frame. |
| `tools/build_car.gd` | An empty `TyreSpray` node beside `TyreMarks`, filled in when it enters the tree. |
| `scenes/car/*.tscn` | Rebaked. Both cars, 23 nodes each. |
| `tests/run_tests.gd` | One new test, 32 checks. |

### The rebake rule for this one

`tools/build_car.gd` after **any** change to what nodes a car carries — but not
for the spray's own behaviour, since the script is referenced by path and the
emitters are built at runtime. `build_audio.gd` comes first if the streams have
changed, which they have not. (For contrast: a **wind** change needs
`tools/build_track.gd`, because `WIND_*` is baked into the circuits as
`ShaderMaterial` parameters. A **grade** change needs nothing.)

### Verified this pass

- **The spray was driven, not posed.** A throwaway `_diag_spray.gd` ran the car
  full throttle off the grid and then handbraked it into a slide, on each of the
  three surfaces, with the camera re-posed beside the car for every shot. Both of
  the bugs it found — emitters orbiting their axles, and a billboard mode that
  rendered nothing — are invisible in a screenshot of a parked car.
- **Every mutation the tests claim to catch was made and caught** — `mark_always`
  forced false, the two rates summed instead of maximised, the emitters parented
  back onto the wheels, `local_coords` turned on, the contact-patch offset
  removed, and tarmac reading `grit` again.
- **Earlier in this milestone**, the same discipline caught the camera shake being
  a translation, and one test that **passed when it should not have**: the streak
  check compared `nearest` against `lines.INNER`, the constant under test, so it
  agreed with itself. It now compares against a number written out in the test.
  Worth repeating on any check whose threshold is a constant the code owns.

### Two things seen but not chased, still open from step 3

- **Nobody has run it in an actual browser.** The web export builds clean, but the
  Chrome here reports `WebGL2 - Check web browser configuration and hardware
  support` before Godot starts. That is the browser, not the build. Worth five
  minutes on a machine with a working WebGL2 context:

  ```bash
  "$GODOT" --headless --path . --export-release "Web" build/web/index.html
  cd build/web && python3 -m http.server 8777    # then open localhost:8777
  ```

- **Compatibility renders the tree canopies much paler than Forward+.** Not the
  wind — a no-wind render under the same renderer is identical, so this predates
  the shader. It is the same ambient/tonemap gap the grading pass measured (whites
  ~10 points brighter under Compatibility), just far more visible on a light mint
  canopy already near the top of the range. It is a **web-build look difference**
  and belongs to whoever next touches lighting, not to wind.

### And three from steps 4 and 5

- **There is now a motion-settings shaped hole.** The shake and the streaks are
  both the sort of effect that usually gets an accessibility toggle, and
  `GameState` already keeps `analogue_input` and `audio_enabled` in exactly the
  shape a third would take. Left out of the change that added them on purpose —
  and now there is genuinely a *set* to offer rather than one thing, which was the
  stated condition for adding it. One switch could reasonably turn both down.
- **Roadside density needed nothing and is now counted rather than claimed** —
  6.0 to 8.7 markers a second at 165 km/h, 7.9 to 13 pieces of roadside furniture,
  12 to 17 with the trees. The builder's comment claimed twenty and had never been
  true. If the circuit ever needs to feel faster, argue with those numbers.
- **The spray does not ask whether it is on the road.** `TyreMarks` raycasts for
  that, so a set of ruts never wanders across a field; the plume skips the check
  because it costs a ray per wheel per frame and nothing about a dust cloud is
  wrong on grass. It does mean a tarmac car sliding on the verge makes tyre smoke
  rather than a divot of turf. Cheap to fix if it ever reads badly —
  `tyre_marks.on_road()` is already public.

---

## Next action

**Step 6: weather that does something.** `storm` is currently an hour with a grey
grade; it becomes rain. Three parts, and the third is the one with the real
payoff:

- **A screen droplet layer.** Nearest thing already built is `speed_lines.gd` — a
  `Control` on the HUD layer drawing into the frame with no screen texture. The
  droplets want the same shape.
- **Spray from the wheels.** `TyreSpray` is now the thing to point at it: a wet
  road is a surface with something loose on it, which is exactly the `mark_always`
  branch that already exists.
- **A wet road, which is a roughness change and not a new shader.** `RoadSurface`
  already carries `roughness` per surface, and `sparkle` already proved that
  punching roughness holes and letting the real sun answer beats drawing the
  highlight. A low-roughness road reflecting a bright sky is a dramatic image
  rather than a faithful one, which is the one place realism pays here.

**The open question is whether rain is a surface or an hour.** `storm` is a
`SkyPreset`, chosen per circuit at build time; `tarmac`/`dirt`/`snow` are a
`RoadSurface`, chosen per race and keyed into the lap record. Wet tarmac is
plainly a *condition* — it changes grip, so it must not share a record with dry —
which argues it belongs beside the other three rather than in the sky. Worth
settling before writing any of it.

---

## How to look at a visual change without a person in the room

Both steps were done this way and it is worth keeping. A throwaway `_diag_*.gd`
`SceneTree` script — the same pattern the handling measurements used — that:

1. builds **one** layout under each look, so the look is the only variable;
2. frames it from fixed poses. Two are worth having in the spawn's frame (the
   chase camera's own offsets, and a high wide shot); the third has to come from
   the **centreline metadata**, because guessing a pose in the spawn's frame put
   the camera in an empty field twice — a third of the way round the lap, looking
   along the road, is where the treeline is;
3. renders variants that isolate one question at a time. For the grade: graded,
   previously-graded, ungraded. For the wind: `still` (sway pinned at zero, so a
   before/after differs only by the material swap) and `nowind` (the
   `StandardMaterial3D` put back, which is what separates "my shader lights this
   differently" from "this renderer lights everything differently");
4. renders **each pose twice, a beat apart**. A still world and a windy one are
   the same single frame; the only proof the wind runs is that the same frame a
   moment later is not the same frame;
5. saves a PNG per combination, which can then be read directly.

Two mechanical things it needs. **Run it windowed** — no `--headless`, there is no
rendering server to read back from — and `await RenderingServer.frame_post_draw`
before `root.get_texture().get_image()`, after ~8 frames for shadows and sky to
settle. Passing the output directory and flags as `-- <dir> <flags>` user args is
what lets the same script be re-run under `--rendering-method gl_compatibility`
and the two compared.

A second script that diffs two PNGs — differing-pixel count, worst pixel, and the
**mean shift over differing pixels** — earns its ten lines several times over. The
mean shift is the useful number: near zero means things moved, consistently
negative means something got darker, and that is what caught the colour bug in
step 3. "The whites went from 220/198/194 to 221/190/167" is a decision; "it looks
warmer" is not.

And **tune by driving it wrong on purpose.** A subtle wrong bend and a subtle
right one are the same picture. Pushing the tree sway to 0.22 made it obvious that
trunks stayed planted and neighbours were out of phase; coming back to 0.07 was
then just a number.

**Step 4 added one more, and it is the cheapest of the lot: some visual questions
do not need a render at all.** `camera.unproject_position(point)` says exactly
where a world point lands on screen, so "how far does this move the picture" is a
subtraction rather than a diff of two PNGs — no frames to settle, no wind or
suspension moving underneath the measurement, and an answer in pixels. Projecting
one point at each of five depths is what showed that shaking the camera's position
moves the car and nothing else, which no amount of looking at a still frame could
have. Render the PNGs as well, but render them to *confirm* a number rather than
to find one.

Delete the scripts when the step closes — they are throwaway, and they get packed
into the web export if left in the project root.

---

## Stop points for the rest of M18

1. ~~Colour grade — the LUT system + two authored looks.~~ **Done.**
2. ~~Grade tuning — the other four authored, all six checked, Compatibility
   verified.~~ **Done.**
3. ~~Wind — trees and roadside marker flags.~~ **Done.** Banner towers and
   roadside grass deliberately not; see below.
4. ~~Speed feedback — camera shake, roadside density, and the frame edges.~~
   **Done.** All three scale against one `camera_fov_reference_kmh`.
5. ~~Particles — tyre spray off the wheels, from `RoadSurface`.~~ **Done.**
   `mark_always` decides rolling versus sliding, exactly as it does for the marks.
6. **Rain** — screen droplets, wheel spray, and a roughness drop on the road.
7. **Crowd** — billboard spectators in the stands that are currently empty.
8. **Marker boards** — braking and apex markers placed from `Compiled.corners`.

### Left out of step 3, on purpose

- **Banner towers.** The two props at the start line, placed by `_place_prop`,
  which instances the GLB scene directly. Putting them in the wind means either
  mutating a shared imported resource — `instantiate()` shares rather than copies,
  so it would leak to every other user of that mesh — or a property override on an
  instanced sub-scene's internal node, which is the exact shape of a trap already
  recorded in `docs/architecture.md`. It needs a per-instance mesh duplication of
  its own. Half a session, and visible at every race start, so it is worth doing.
- **Roadside grass.** Does not exist. The kit's entire vegetation list is
  `treeLarge` and `treeSmall`. The roadmap line was written without checking.
- **Wind that varies by hour.** `WIND_DIRECTION` and the strengths are global
  constants, and a storm blowing exactly as hard as a bright noon is a missed
  opportunity — but weather doing something is step 6, and that is where it
  belongs rather than bolted onto this one.

**Palette consolidation** — a look owning the colours `SceneryTheme`, `SkyPreset`
and `RoadSurface` each pick separately — is still unscheduled, and grading the six
made the case stronger. `evening` is the clearest: the ground stays a flat olive
under a sunset sky because `SceneryTheme` chose it without knowing the hour, and
no grade can fix one object's albedo without moving the whole frame.

---

## Traps hit, in order

**Step 1.**

- **A new `class_name` is invisible until the registry is regenerated.** Adding
  `ColourGrade` broke `tools/build_track.gd` with a bare "Compile Error" until
  `"$GODOT" --headless --editor --quit --path .` had run. Do that first after
  adding any new `class_name`, and check `git diff project.godot` is empty
  afterwards.
- **`ImageTexture3D.get_data()` returns an empty array under `--headless`.** Tests
  go through `ColourGrade.slices()`, which is the data on the way in.
- **Godot clamps nothing between contrast and saturation.** Clamping there costs
  about 0.03 in the shadows and breaks the exact migration.

**Step 2 — what tuning by eye taught.**

- **Global saturation above about 1.3 starts colouring the white kit**, which is
  what the rest of the palette is read against. `evening` sat at 1.45 and had pink
  grandstands and lavender guardrails; 1.26 with a wider per-channel split is
  warmer *and* keeps the whites.
- **To warm an hour whose sky is already at the top of the range, drop blue rather
  than lift red.** Sunset's red is near 1.0 across the whole sky, so a red slope
  only flattens the gradient the sky is made of.
- **A negative offset cannot be undone downstream.** Several looks crush the
  tarmac to pure black, and `overcast`'s positive offset only lifts it to about
  8/255 because the road's albedo is genuinely near zero. If the road needs to
  hold detail in the dark hours that is a material change — M19's road detail
  pass, not a grade.

**Step 3.**

- **`source_color` behaves differently in a `spatial` shader and a `sky` shader.**
  A spatial shader's uniform is converted for you; converting first as well —
  which is what `sky.gdshader` genuinely needs — rendered the whole forest at about
  half its authored brightness. A *plausible* forest, so only a diff found it.
- **The one textured prop in the kit is the one on the default theme.**
  `flagCheckersSmall` is the meadow marker, and meadow is what every player-drawn
  circuit uses. An early `_windy` skipped textured surfaces and left exactly those
  flags dead; the suite caught it on Suzuka.
- **A `MultiMesh` vertex has no per-instance identity except `MODEL_MATRIX[3]`.**
  Phase from `VERTEX` shears the tree; phase from nothing puts the forest in
  lockstep.
