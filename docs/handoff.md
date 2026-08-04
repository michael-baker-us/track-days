# Handoff — M18, step by step

Scratch file for picking up M18 in a fresh session. Delete it when M18 closes.

## Resume prompt

Paste this into a fresh session:

> Read `docs/handoff.md`, then continue M18 from the next action. Keep the same
> stop-point discipline: one item at a time, suite green before moving on, and
> update the handoff before you finish.

Swap the next action for a specific step if you want a different one — e.g.
"…continue M18, but do the wind step (3) rather than grade tuning."

Read `docs/roadmap.md` M18 for the *why*; this is only the state of play and the
next action. Everything below assumes:

```bash
GODOT=/Users/michael.baker/Downloads/Godot.app/Contents/MacOS/Godot
```

---

## Where things stand

**Step 1 (colour grade) is done and the suite is green — 1900 checks.**

| File | What it is |
| --- | --- |
| `scripts/track/colour_grade.gd` | New. ASC CDL grades, the LUT builder, the cache. Start here. |
| `scripts/track/circuit_look.gd` | Gained `name_of()` — the look's *key*, which `resolve()` cannot give back. |
| `scripts/track/track_builder.gd` | BCS scalars pinned neutral; `set_meta("look", ...)`; new static `grade_scene()` beside `surface_road`. |
| `scripts/game/race.gd` | Calls `TrackBuilder.grade_scene(track)` on load. |
| `tests/run_tests.gd` | Four new tests; `test_shipped_circuits_carry_their_own_hour` updated for neutral scalars. |
| `scenes/track/*.tscn` | Rebaked — the environment is baked in, so a builder change needs `tools/build_track.gd`. |

### The one thing not yet verified

**Nobody has looked at it.** The suite proves the LUT is correct and reaches the
scene; it cannot prove the grade looks good, and it cannot prove the
Compatibility renderer samples a `Texture3D` LUT the way Forward+ does. Both need
eyes:

```bash
"$GODOT" --path .                      # desktop, Forward+
"$GODOT" --headless --path . --export-release "Web" build/web/index.html
cd build/web && python3 -m http.server 8777    # then compare in a browser
```

Ardennes is `bright`, La Sarthe is `night` — the two authored looks. Monte Carlo,
Suzuka and the other two are derived and should look **exactly** as they did
before; if any of them shifted, the migration is wrong and that is a bug, not a
taste question.

If the web build renders ungraded, the fallback is a 1D `GradientTexture1D` or
folding the grade back into the three scalars for web only. Do not discover this
late — it decides how much of M18 depends on grading.

---

## Next action

**Tune `bright` and `night` by eye, then author the remaining four.**

Grades are data in `ColourGrade.GRADES`. Editing them needs no rebake — the LUT
is built at load — so the loop is: edit, run the game, look.

- `slope` colours the **highlights** (multiply, leaves black alone).
- `offset` colours the **shadows** (add, washes out toward white).
- `power` moves the **midtones** only. Currently `Vector3.ONE` everywhere; note
  that leaving it at ONE is what keeps derived grades bit-exact, so only authored
  grades should touch it.
- `saturation` last, about a flat channel mean.

Moving a look out of "derived" and into `GRADES` is what removes it from
`test_the_grade_migration_is_exact`. That is fine and expected — but the test
asserts at least one derived look remains, so if all six get authored, retire the
test rather than leave it passing vacuously.

Then continue down M18: **wind** (step 2) is the next item and is the cheapest
large win in the milestone.

---

## Stop points for the rest of M18

Each is independently shippable, suite-green, and a clean place to clear context.

1. ~~Colour grade — the LUT system + two authored looks.~~ **Done.**
2. **Grade tuning** — the other four looks authored, all six checked on web.
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

Palette consolidation (a look owning the colours `SceneryTheme`, `SkyPreset` and
`RoadSurface` each pick separately) is unscheduled and belongs before the looks
multiply.

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
