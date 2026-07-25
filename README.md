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

M1 — drivable `VehicleBody3D` car (Kenney Car Kit, RWD) on a flat plane, chase camera,
debug overlay. Feel is untuned; that's M2.
