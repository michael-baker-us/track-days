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

**Steps 1, 2 and 3 are done and the suite is green — 1998 checks.**

Step 1 (the grading system) shipped as `39e465b`, step 2 (all six looks authored)
as `bd3d09f`. **Step 3 is the working diff.**

| File | What it is |
| --- | --- |
| `assets/shaders/wind.gdshader` | New. The vertex displacement; read its header before changing it. |
| `scripts/track/track_builder.gd` | `WIND_*` constants, `_windy()`, and a `wind` argument on `_multimesh`. |
| `scenes/track/*.tscn` | Rebaked — **wind is baked, unlike the grade.** |
| `tests/run_tests.gd` | Three new tests. |
| `scripts/track/colour_grade.gd` | Step 2, already committed. `GRADES` holds **all six** looks, in `CircuitLook.ORDER` so it reads as a day; `from_bcs` kept as the fallback for a future look. |

### The rebake rule, which differs between the two steps

- **A grade change needs no rebake.** Grades are data, the LUT is built at load,
  and the `.tscn` files carry only the look's *name*. Edit `GRADES`, run, look.
- **A wind change does.** `WIND_TREE` / `WIND_FLAG` / `WIND_DIRECTION` are baked
  into the circuits as `ShaderMaterial` parameters, so
  `"$GODOT" --headless --path . --script tools/build_track.gd` after touching
  them.

### Verified this pass

- **All six looks looked at**, chase and wide framing, against both the ungraded
  frame and the derived grade each look used to have.
- **Grading survives the Compatibility renderer** — within 1–2 of 255 of Forward+.
- **Wind survives it too**: no shader errors, and the trees measurably move.
- **The wind material swap is lossless.** With the sway pinned at zero, a wind
  frame and a pre-wind frame differ on ~0.06% of pixels by a mean of ~2/255 —
  anti-aliasing on thin silhouettes, because `world_vertex_coords` does the model
  transform in the shader and the last bits differ.

### Two things seen but not chased

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

---

## Next action

**Step 4: speed you can feel.** Camera shake that rises with speed and with
surface, and roadside density that streams. `chase_camera.gd` already has the FOV
kick and reads its numbers from `CarTuning`, so shake belongs beside
`camera_base_fov` and friends for the same reason the framing does: it is part of
how a car feels, not a property of the scene.

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

Delete the scripts when the step closes — they are throwaway, and they get packed
into the web export if left in the project root.

---

## Stop points for the rest of M18

1. ~~Colour grade — the LUT system + two authored looks.~~ **Done.**
2. ~~Grade tuning — the other four authored, all six checked, Compatibility
   verified.~~ **Done.**
3. ~~Wind — trees and roadside marker flags.~~ **Done.** Banner towers and
   roadside grass deliberately not; see below.
4. **Speed feedback** — camera shake in `CarTuning` beside the framing that is
   already there (`chase_camera.gd` has FOV kick; this is the rest of the set).
5. **Particles** — `CPUParticles3D`, not GPU: GPU particles throw WebGL errors
   under Compatibility with a View Depth draw order. Read `RoadSurface.mark` and
   `mark_always`, which already answer "does this tyre displace material".
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
