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

## Status

M0 — project skeleton (input map, physics tick rate, directory layout).
