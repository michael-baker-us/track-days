# Track Days

A 3D third-person arcade racer, built in Godot 4.7 (GDScript). Pick a circuit,
chase a lap time — or build your own circuit and chase a time on that.

Separate from any pseudo-3D OutRun-style racer on the broader project roadmap — this one
uses real 3D and Godot's built-in `VehicleBody3D` physics.

See [`docs/architecture.md`](docs/architecture.md) for how it fits together,
[`docs/tuning-journal.md`](docs/tuning-journal.md) for how the handling numbers
were arrived at, and [`docs/plan.md`](docs/plan.md) for the milestone plan.

## Web build

```bash
/path/to/Godot.app/Contents/MacOS/Godot --headless --path . \
  --export-release "Web" build/web/index.html

# Must be served over HTTP - opening index.html from disk will not work.
cd build/web && python3 -m http.server 8777
```

Deployed to GitHub Pages by `.github/workflows/pages.yml` on every push to
`main`. Enable Pages with **Settings → Pages → Source: GitHub Actions** first.

Two constraints shape this build, both checked in CI:

- **Single-threaded.** Threaded web builds need `SharedArrayBuffer`, which needs
  COOP/COEP headers that Pages cannot send. `variant/thread_support=false` keeps
  those checks switched off entirely.
- **Compatibility renderer.** Web only supports WebGL 2; Forward+ and Mobile are
  not available. `rendering_method.web` overrides it for web alone, so desktop
  still runs Forward+.

## Testing

```bash
# Headless suite; exits non-zero on failure, so CI gates on it.
/path/to/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/run_tests.gd
```

Covers tuning invariants, lap-ordering rules, checkpoint integrity, that the road
collision surface follows the track's elevation and never kinks away from the
road at a corner, that a painted grid loop compiles to a circuit the builder
agrees closes, and that no shape edit can produce a loop that does not. Handling *feel* is not unit-tested — see
[`docs/tuning-journal.md`](docs/tuning-journal.md) for how that is measured
instead.

## Running

```bash
# Open in the editor
/path/to/Godot.app/Contents/MacOS/Godot --path .

# Headless import/parse check (CI-friendly)
/path/to/Godot.app/Contents/MacOS/Godot --headless --path . --quit
```

## Controls

| Action | Keyboard | Gamepad |
|---|---|---|
| Steer | A/D or Left/Right | Left stick |
| Accelerate | W or Up | Right trigger |
| Brake / reverse | S or Down | Left trigger |
| Handbrake | Space | A |
| Reset car | R | Y |
| Toggle debug overlay | F3 | — |
| Back to track select | Esc | — |

### Track editor

Two ways to build, switched with the **Draw road** toggle (or `D`).

**Draw on** — lay road freehand. Handles hide so a stroke is never mistaken for a
drag. Left off a closed loop? **Join the ends up** routes the last stretch for you.

| Action | Control |
|---|---|
| Lay road / erase | Drag / right-drag |

**Draw off** — drag the loop around by its shape. An edit that would break the
circuit is refused, so loose ends and crossings cannot be made this way.

| Action | Control |
|---|---|
| Move a corner | Drag a green dot |
| Slide a straight | Drag the road |
| Add a bend | Double-click a straight, then drag it in or out |
| Remove a corner | Right-click a green dot |
| Corner radius | Click the numbered badge outside the loop |
| Raise a straight or corner | Click the badge inside the loop |
| Move the start line | Drag the flag |
| Lay road without leaving shaping | Shift-drag / shift-right-drag |

Always available: **Ctrl+Z** undo · **Ctrl+S** save · wheel zooms · middle-drag
pans · **F** refits.

## Status

M3 — two circuits, both 14 m wide and built from Kenney Racing Kit tiles by a
layout spec: **Highland** (1278 m, long straights and two climbs) and **The
Flats** (1287 m, flat and technical). A title screen selects between them and
shows the best lap for each.
Guardrails exist behind a flag but are off by default; they clipped the racing
line at corners. Handling is tuned to a grippy-arcade target: 165 km/h top speed,
0–100 in 3.4 s, 100–0 in 24 m (1.6 g), and corners held at 98–127 km/h. All feel
parameters live in a swappable `CarTuning` resource.

M4 — lap timing over 16 ordered checkpoints, with a HUD showing speed, current
lap, last lap and best lap. Best laps are per circuit and persist between
sessions. Laps only count if every gate is crossed in sequence, so corners
cannot be cut. The car starts just behind the line, so timing begins about two
seconds in rather than after an out lap.

M5 — a track editor. Draw a circuit freehand, or take the driveable rectangle a
new track opens with and drag its corners and straights into shape. Either way
the game compiles the result into a real track — Kenney tiles, a seamless collision ribbon, and sixteen ordered
gates, identical in kind to the shipped ones. Closure, which the shipped layouts
had to be hand-solved into, comes free, and because every drag is refused unless
it leaves a valid loop, a broken circuit cannot be built in the first place.

Corner radius stays a choice: all three Kenney corners join the same two centre
lines, so the widest that fits is picked automatically and can be cycled down,
trading straight for a faster corner.

Elevation is per segment, straights *and* corners. Raise a straight on its own
and you get a crest that climbs and falls inside it; raise the corner after it
too and the height carries on round the bend, so an elevated section runs from
wherever you start it to wherever you stop it. Height closes for the same
structural reason position does — the corner before the start line is pinned to
the ground, so the running height always returns to where it began. Circuits are saved as JSON under `user://tracks/` and appear on the title
screen with their own lap records and an **Edit** button, so a saved track can
always be reopened — including one left too unfinished to drive.

See [`docs/tuning-journal.md`](docs/tuning-journal.md) for how the handling
numbers were arrived at and what is still open.

## Scenes

| Scene | Purpose |
|---|---|
| `scenes/title.tscn` | Entry point — track selection, and Edit for custom tracks |
| `scenes/editor/track_editor.tscn` | Drag a circuit into shape and drive it |
| `scenes/race.tscn` | A race. The track is instanced at runtime from the selection |
| `scenes/track/track_*.tscn` | The circuits. Generated; edit the layout spec and rebuild |
| `scenes/track/track_01.tscn` | Bare flat plane, kept for physics measurement |
| `scenes/car/car.tscn` | Car geometry only; feel comes from `resources/tuning/` |
| `scenes/ui/hud.tscn` | Lap/speed HUD. Generated by `tools/build_ui.gd` |
