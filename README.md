# Racing

A 3D third-person arcade racer, built in Godot 4.7 (GDScript), starting as a tech demo:
drive a car around a track and get the feel right before deciding where the game goes next.

Separate from any pseudo-3D OutRun-style racer on the broader project roadmap — this one
uses real 3D and Godot's built-in `VehicleBody3D` physics.

See [`docs/plan.md`](docs/plan.md) for the full milestone plan and architecture notes.

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

## Status

M3 — a 913 m closed circuit built from Kenney Racing Kit tiles, with walls and a
start line. Handling is tuned to a grippy-arcade target (top speed 165 km/h,
0–100 in 3.5 s, 100–0 in 24 m); all feel parameters live in a swappable
`CarTuning` resource. Next: lap timing and checkpoints.

See [`docs/tuning-journal.md`](docs/tuning-journal.md) for how the handling
numbers were arrived at and what is still open.

## Scenes

| Scene | Purpose |
|---|---|
| `scenes/main.tscn` | Entry point — circuit, car, chase camera, debug overlay |
| `scenes/track/track_02.tscn` | The circuit. Generated; edit the layout spec and rebuild |
| `scenes/track/track_01.tscn` | Bare flat plane, kept for physics measurement |
| `scenes/car/car.tscn` | Car geometry only; feel comes from `resources/tuning/` |
