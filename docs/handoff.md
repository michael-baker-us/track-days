# Handoff — M18, step by step

Scratch file for picking up M18 in a fresh session. Delete it when M18 closes.

## Resume prompt

Paste this into a fresh session:

> Read `docs/handoff.md`, then continue M18 from the next action. Keep the same
> stop-point discipline: one item at a time, suite green before moving on, and
> update the handoff before you finish.

Swap the next action for a specific step if you want a different one — e.g.
"…continue M18, but do the particles step (5) rather than wind."

Read `docs/roadmap.md` M18 for the *why*; this is only the state of play and the
next action. Everything below assumes:

```bash
GODOT=/Users/michael.baker/Downloads/Godot.app/Contents/MacOS/Godot
```

---

## Where things stand

**Steps 1 and 2 (the grade) are done and the suite is green — 1919 checks.**

Step 1 shipped as `39e465b`. Step 2 is the working diff: `scripts/track/colour_grade.gd`
and `tests/run_tests.gd`, plus the two docs.

| File | What changed in step 2 |
| --- | --- |
| `scripts/track/colour_grade.gd` | `GRADES` now holds **all six** looks, in `CircuitLook.ORDER` so it reads as a day. `from_bcs` is kept as the fallback for a *future* look. |
| `tests/run_tests.gd` | `test_the_grade_migration_is_exact` → `test_the_bcs_conversion_is_exact` (checks the conversion directly, since there is no unauthored look left to check through). Split test extended to the four sunlit hours. New `test_the_sunless_hours_are_authored_flat`. |

**No rebake was needed and none is needed for a grade change.** Grades are data,
the LUT is built at load, and the `.tscn` files carry only the look's *name*. The
loop is: edit `GRADES`, run, look.

### Verified this pass

- **All six looked at**, chase framing and a high wide shot, against both the
  ungraded frame and the derived grade each look used to have.
- **The Compatibility renderer samples the table.** Same frames under
  `--rendering-method gl_compatibility` land within 1–2 of 255 of the Forward+
  versions, in the same direction. The renderers do differ — the white kit is
  ~10 points brighter under Compatibility — but that gap is in the *ungraded*
  frame too, so it is ambient and tonemapping, not the grade. **This closes step
  1's open risk:** grading survives the platform, so the rest of M18 can lean on
  it.

### The one thing still not checked

**Nobody has seen it in an actual browser.** The web export builds clean, but the
Chrome available in this environment reports `WebGL2 - Check web browser
configuration and hardware support` before Godot starts, so the page never ran.
That is the browser, not the build.

```bash
"$GODOT" --headless --path . --export-release "Web" build/web/index.html
cd build/web && python3 -m http.server 8777    # then open localhost:8777
```

Worth five minutes next time someone is at a machine with a working WebGL2
context. The residual risk is small — Compatibility is the same Godot renderer
the web build uses, and the only web-specific unknown left is WebGL2's `sampler3D`
— but it is not zero.

---

## Next action

**Step 3: wind.** One vertex shader on trees, flags, banners and roadside grass,
phase driven by world position so nothing moves in lockstep. It survives the trees
being `MultiMesh` because the displacement is per-vertex in world space and never
touches the instance transform.

The cheapest large win left in the milestone, and the one that changes what the
game *is* rather than what it looks like: a static tree reads as a prop, a moving
one reads as a place.

---

## How to look at a visual change without a person in the room

Grading was tuned this way and it worked well enough to write down. A throwaway
`_diag_*.gd` `SceneTree` script — the same pattern the handling measurements used
— that:

1. builds **one** layout under each look, so the look is the only variable;
2. frames it from two fixed poses (the chase camera's own offsets, and a high wide
   shot where sky and ground read against each other);
3. renders each frame in several variants — graded, the previous grade, ungraded —
   so the change is visible rather than merely present;
4. saves a PNG per combination, which can then be read directly.

Two things it needs. **Run it windowed** — no `--headless`, there is no rendering
server to read back from — and `await RenderingServer.frame_post_draw` before
`root.get_texture().get_image()`, after ~8 frames for shadows and sky to settle.
Passing the output directory as a `-- <dir>` user arg is what lets the same script
be re-run under `--rendering-method gl_compatibility` and the two compared.

A second tiny script that prints region means from those PNGs is worth the ten
lines: "the whites went from 220/198/194 to 221/190/167" is a decision, "it looks
warmer" is not.

Delete both when the step closes — they are throwaway, and they get packed into
the web export if they are still sitting in the project root when it runs.

---

## Stop points for the rest of M18

Each is independently shippable, suite-green, and a clean place to clear context.

1. ~~Colour grade — the LUT system + two authored looks.~~ **Done.**
2. ~~Grade tuning — the other four authored, all six checked, Compatibility
   verified.~~ **Done.**
3. **Wind** — one vertex shader on trees, flags, banners, roadside grass.
   Phase from world position so nothing moves in lockstep. Survives `MultiMesh`
   because displacement is per-vertex and never touches the instance transform.
4. **Speed feedback** — camera shake in `CarTuning` beside the framing that is
   already there (`chase_camera.gd` has FOV kick; this is the rest of the set).
5. **Particles** — `CPUParticles3D`, not GPU: GPU particles throw WebGL errors
   under Compatibility with a View Depth draw order. Read `RoadSurface.mark` and
   `mark_always`, which already answer "does this tyre displace material".
6. **Rain** — screen droplets, wheel spray, and a roughness drop on the road.
7. **Crowd** — billboard spectators in the stands that are currently empty.
8. **Marker boards** — braking and apex markers placed from `Compiled.corners`.

**Palette consolidation** — a look owning the colours `SceneryTheme`, `SkyPreset`
and `RoadSurface` each pick separately — is still unscheduled, and grading the six
made the case for it stronger. `evening` is the clearest: the ground stays a flat
olive under a sunset sky because `SceneryTheme` chose it without knowing the hour,
and no grade can fix one object's albedo without moving the whole frame. It
belongs before the looks multiply.

---

## Traps that bit during step 1

- **A new `class_name` is invisible until the registry is regenerated.** Adding
  `ColourGrade` broke `tools/build_track.gd` with a bare "Compile Error" until
  `"$GODOT" --headless --editor --quit --path .` had run. Do that first after
  adding any new `class_name`, and check `git diff project.godot` is empty
  afterwards.
- **`ImageTexture3D.get_data()` returns an empty array under `--headless`** —
  there is no rendering server holding it. Tests go through
  `ColourGrade.slices()` instead, which is the data on the way in.
- **Godot clamps nothing between contrast and saturation.** Clamping there costs
  about 0.03 in the shadows and breaks the exact migration. Found by the suite,
  written up in `docs/architecture.md`.

## What tuning by eye taught, in step 2

- **Global saturation above about 1.3 starts colouring the white kit**, which is
  what the rest of the palette is read against. `evening` sat at 1.45 and had pink
  grandstands and lavender guardrails; 1.26 with a wider per-channel split is
  warmer *and* keeps the whites.
- **To warm an hour whose sky is already at the top of the range, drop blue rather
  than lift red.** Sunset's red channel is near 1.0 across the whole sky, so a red
  slope only flattens the gradient the sky is made of.
- **A negative offset cannot be undone by anything downstream.** Several looks
  crush the tarmac to pure black, and `overcast`'s positive offset only lifts it
  to about 8/255 because the road's albedo is genuinely near zero. If the road
  needs to hold detail in the dark hours that is a material change, not a grade
  change — which is M19's road detail pass, not this one.
