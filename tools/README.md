# tools/

One-off generators, run headlessly. They write scenes into `scenes/`, so the
generated `.tscn` files are committed and the game does not depend on these at
runtime.

> **Use `--editor --quit`, not `--import`, to register new `class_name`s.**
> Both regenerate `.godot/`, but `--import` also rewrites `project.godot` and
> drops the whole `[rendering]` section — taking
> `renderer/rendering_method.web="gl_compatibility"` with it, which the web build
> depends on. `--editor --quit` leaves the file alone, which is why the workflows
> use it. If you do run `--import`, check `git diff project.godot`.

> A `--script` run that hits an error never reaches `quit()`, so the process
> idles forever and a pipe to `tail` never flushes. Redirect to a file and use a
> timeout when running these unattended, or a broken script looks like a hang.

```bash
GODOT=/path/to/Godot.app/Contents/MacOS/Godot

# Rebuild the project theme after editing scripts/ui/ui_theme.gd. Nothing picks
# up a palette change until this is re-run; the suite compares the committed
# resource against a freshly built one so a stale theme fails CI.
"$GODOT" --headless --path . --script tools/build_theme.gd

# Rebuild every circuit after editing a layout in build_track.gd.
# Prints a closure gap per track: it must be (0, 0) with net turns +/-4 and
# height back to 0, or the loop does not join up. Adjust straight counts until
# it closes; the script exits non-zero if any track fails to close.
"$GODOT" --headless --path . --script tools/build_track.gd

# Rebuild the HUD after editing build_ui.gd. Node names there must match the
# @onready paths in scripts/ui/hud.gd.
"$GODOT" --headless --path . --script tools/build_ui.gd

# Rebuild the title screen (track list comes from GameState at runtime).
"$GODOT" --headless --path . --script tools/build_title.gd

# Rebuild the track editor. Node names here must match the @onready paths in
# scripts/ui/track_editor.gd; the mode buttons are generated at runtime.
"$GODOT" --headless --path . --script tools/build_editor.gd

# Regenerate race.tscn (car + camera + HUD + tracker; the track is instanced at
# runtime from whatever the title screen selected).
# Always regenerate rather than hand-editing: instance overrides in a scene
# silently beat values in the sub-scene it instances, which has bitten this
# project once already.
"$GODOT" --headless --path . --script tools/build_race.gd
```

Run `build_track.gd` and `build_ui.gd` before `build_race.gd`, which instances
`hud.tscn`. `build_theme.gd` is independent of the rest.

**No styling in these files.** They place nodes and name theme type variations
(`UiTheme.V_PRIMARY` and friends); colours, borders and font sizes live in
`scripts/ui/ui_theme.gd`. A mistyped variation name fails silently — the control
renders as the plain base type — which is why they are constants.

**Owner rule.** When packing a scene, set `owner` on nodes you created and on
instanced sub-scene *roots*, but never on an instance's internal nodes — those
then serialise on top of the instance and everything appears twice. This shipped
a car with eight wheels and two of every road tile; `tests/run_tests.gd` now
counts both.
