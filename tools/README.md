# tools/

One-off generators, run headlessly. They write scenes into `scenes/`, so the
generated `.tscn` files are committed and the game does not depend on these at
runtime.

```bash
GODOT=/path/to/Godot.app/Contents/MacOS/Godot

# Rebuild the circuit after editing LAYOUT in build_track.gd.
# Prints the closure gap: it must be (0, 0) with net turns +/-4, or the loop
# does not join up. Adjust straight counts until it closes.
"$GODOT" --headless --path . --script tools/build_track.gd

# Rebuild the HUD after editing build_ui.gd. Node names there must match the
# @onready paths in scripts/ui/hud.gd.
"$GODOT" --headless --path . --script tools/build_ui.gd

# Regenerate main.tscn (wires circuit + car + camera + overlay together).
# Always regenerate rather than hand-editing: instance overrides in main.tscn
# silently beat values in car.tscn, which has bitten this project once already.
"$GODOT" --headless --path . --script tools/build_main.gd
```

Run `build_track.gd` and `build_ui.gd` before `build_main.gd` — the last one
reads the circuit's `SpawnPoint` to place the car and instances `hud.tscn`.
