# First Godot Game — 3D Third-Person Arcade Racer

## Context

`~/repos/racing` is an empty git repo with no commits. Godot **4.7 stable** is installed at
`~/Downloads/Godot.app`, and a throwaway starter project sits at `~/godot-test` (default
scaffold, untouched since 2026-06-18).

The goal is a **targeted tech demo, reached early**: drive a car around a track and get the
*feel* right. Feel is the deliverable — not content, not features. Everything below is
sequenced so that we're driving something within the first milestone and spending the bulk
of the effort on tuning, with the engineering hygiene (tests, CI, docs, export) arriving
once there's something worth protecting.

Once the feel is dialled in, we branch — time trials, opponents, drift scoring, whatever
the demo suggests. That decision is deliberately deferred.

### Decisions locked in

| Decision | Choice |
|---|---|
| Relationship to roadmap | **New project**, separate from pseudo-3D OutRun Racer |
| Language | **GDScript** |
| Vehicle physics | **Built-in `VehicleBody3D`** |
| Art | **Kenney CC0 asset packs** (Car Kit + Racing Kit) |
| Layout | **Godot project at repo root** |
| Target feel | **Arcade / drifty** — Ridge Racer, OutRun, Horizon Chase |

---

## Architecture

### Directory layout (repo root = Godot project root)

```
racing/
  project.godot
  .gitignore .gitattributes README.md
  assets/kenney/{car_kit,racing_kit}/     # CC0 GLB source art
  scenes/
    main.tscn                             # entry scene, wires level + car + camera
    car/car.tscn                          # VehicleBody3D + 4 VehicleWheel3D + visuals
    camera/chase_camera.tscn
    track/track_01.tscn
    ui/{hud.tscn,debug_overlay.tscn}
  scripts/
    car/car_controller.gd
    camera/chase_camera.gd
    ui/{hud.gd,debug_overlay.gd}
    track/{lap_tracker.gd,checkpoint.gd}
  resources/tuning/
    car_tuning.gd                         # class_name CarTuning extends Resource
    drifty.tres  grippy.tres              # swappable presets
  docs/{architecture.md,tuning-journal.md}
  tests/                                  # GUT, from M5
```

### Three design decisions worth understanding

**1. Tuning lives in a `Resource`, not in exported vars on the car node.**
`CarTuning` (`resources/tuning/car_tuning.gd`) holds every feel parameter — engine force,
steer rate, front/rear friction slip, suspension, camera lag, FOV kick. `.tres` files are
plain text, so presets diff cleanly in git and can be hot-swapped at runtime to A/B two
feels back to back. This is the single highest-leverage structural choice for a project
whose whole purpose is tuning.

**2. Collision geometry is separate from visual geometry.**
Kenney's modular road pieces snapped end-to-end produce micro-seams. `VehicleBody3D` uses
raycast wheels, which will catch on those seams and jolt the car. So the pretty Kenney
meshes are visual-only (`StaticBody3D`-free), and the car drives on a separate, deliberately
smooth collision surface — a low-poly road ribbon plus box walls — hidden at runtime. This
is standard practice in shipped racers and it removes an entire class of "why does my car
randomly hop" debugging.

**3. The camera is a sibling of the car, not a child.**
A `SpringArm3D` parented to the car inherits its roll and pitch, which reads as nausea when
the car is sliding. Instead `chase_camera.gd` follows a `Marker3D` target, lerping position
and slerping rotation on its own timescale — the lag between car and camera *is* the sense
of speed. Speed-proportional FOV on top.

---

## Milestones

### M0 — Skeleton (short)
- `project.godot` at repo root, Godot 4.7, Forward+ renderer.
- `.gitignore` (`.godot/`, `export/`, `*.translation`), `.gitattributes` (Godot's standard
  text/eol rules so `.tscn`/`.tres` diff properly).
- `README.md`, initial commit on `main`.
- Define InputMap actions up front — `steer_left`, `steer_right`, `accelerate`, `brake`,
  `handbrake`, `reset_car`, `toggle_debug` — bound to **both** keyboard and gamepad. Costs
  nothing now; means controller support is already done.
- Set `physics/common/physics_ticks_per_second = 120`. `VehicleBody3D` is materially more
  stable above 60Hz, and 60Hz vehicle jitter is a trap that wastes days.

### M1 — Drivable car on a flat plane ← *the tech demo core*
- Download Kenney **Car Kit** and **Racing Kit** (CC0, kenney.nl) into `assets/kenney/`;
  verify GLB import.
- `car.tscn`: `VehicleBody3D`, mass ~**1200 kg** (the default of 1.0 is unusable and is the
  #1 cause of "my Godot car is uncontrollable"), custom center of mass lowered toward the
  floor pan to resist rollover. Four `VehicleWheel3D` — fronts `use_as_steering`, rears
  `use_as_traction`. Kenney wheel meshes parented under each wheel node.
- `car_controller.gd`: reads input via `Input.get_axis()`, applies `engine_force`, `brake`,
  `steering`. Steering is **lerped** toward its target, not snapped — keyboard input is
  binary and unsmoothed steering feels awful. Steering authority scales down with speed.
- `chase_camera.gd` per the design above.
- `debug_overlay.gd` (F3): speed km/h, engine force, steer angle, per-wheel ground contact
  and slip. Tuning without telemetry is guesswork; this pays for itself immediately.
- `reset_car` (R) respawns upright — you will flip the car constantly.

**Done when:** you can drive a Kenney car around a flat plane and it feels controllable.
Nothing past this point matters until that's true.

### M2 — Feel pass (expect to spend real time here)
- Introduce `CarTuning`; migrate every magic number out of `car_controller.gd`.
- Dial in **drifty**: rear `wheel_friction_slip` meaningfully below front (the default 10.5
  is glued to the road), handbrake cuts rear grip and applies rear-only brake force, enough
  engine force to break traction out of a corner.
- Suspension stiffness / travel / damping so the car squats and rolls visibly under load —
  weight transfer you can *see* is most of what sells arcade handling.
- Camera lag and FOV kick tuned against the new grip model.
- `docs/tuning-journal.md`: what we changed, what it felt like, what we kept. This is the
  artifact that makes the milestone reusable knowledge instead of fiddling.

### M3 — A real track
- Assemble a **mixed-corner circuit** from Racing Kit pieces — hairpin, sweeper, chicane,
  straight. An oval tells you nothing about handling; you need corners that punish
  different mistakes.
- Author the separate smooth collision ribbon + boundary walls.
- Lighting, sky, and a horizon so speed reads visually.

### M4 — Laps
- `checkpoint.gd` on `Area3D` triggers; `lap_tracker.gd` enforces ordered checkpoints so the
  track can't be short-cut.
- HUD: speed, current lap, last lap, best lap. Best lap persisted to `user://`.
- A stopwatch is what converts "this feels nice" into "this feels nice *and I keep replaying
  it*" — it's also the first honest test of the handling model.

### M5 — Hygiene and a release
- **GUT** unit tests over the pure logic — lap validation, checkpoint ordering, tuning curve
  math. Physics feel isn't unit-testable; don't pretend otherwise.
- Engine audio pitch-shifted by wheel RPM, skid particles on slip.
- GitHub Actions: headless import + script parse check on every push.
- macOS export, tag `v0.1.0`.
- `docs/architecture.md`.

### M6 — Decide the direction
Time trial / ghosts, AI opponents, drift scoring, or something the demo itself suggests.
Deliberately unplanned.

---

## Verification

**What I can check myself:**
```bash
# import + open project headlessly; surfaces import and parse errors
/Users/michael.baker/Downloads/Godot.app/Contents/MacOS/Godot --headless --path . --quit

# GDScript parse check
/Users/michael.baker/Downloads/Godot.app/Contents/MacOS/Godot --headless --check-only --script scripts/car/car_controller.gd

# GUT suite, from M5
/Users/michael.baker/Downloads/Godot.app/Contents/MacOS/Godot --headless --path . -s addons/gut/gut_cmdln.gd
```
I can also launch the game and confirm it runs without errors on stdout.

**What only you can check:** whether it *feels* right. I can't evaluate handling from a
screenshot, and I won't claim a feel milestone is done — M1 and M2 close when you drive it
and say so. Concretely, at the end of M1 I'll hand you the build and a short list of things
to pay attention to (turn-in response, does it fight you at speed, does the camera keep up).

**Suggested housekeeping:** move `Godot.app` from `~/Downloads` to `/Applications` and add a
`godot` alias, so tooling and CI paths don't break when Downloads gets cleared. Your call —
I'll use the full path until then.

---

## Notable risks

- **`VehicleBody3D` is a raycast vehicle and it is twitchy out of the box.** Mass, center of
  mass, and physics tick rate are addressed in M0/M1 specifically because they're the usual
  culprits. If it still fights us after a genuine M2 tuning pass, the fallback is a custom
  `RigidBody3D` controller — more work, total control, and honestly where most arcade racers
  end up. We'd take that decision at the end of M2 with real evidence, not now.
- **Kenney car meshes need their wheels split from the body.** If a given model ships as one
  fused mesh, we pick a different car from the kit rather than doing mesh surgery.
