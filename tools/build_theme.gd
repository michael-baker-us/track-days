extends SceneTree

# Builds resources/ui_theme.tres from scripts/ui/ui_theme.gd.
#
# The saved resource is what `project.godot`'s `gui/theme/custom` points at, so
# editing the palette in the script changes nothing until this is re-run. Same
# bargain as the generated scenes: the description lives in code, the artefact is
# committed, and the game never depends on tools/ at runtime.
#
# Deliberately a plain Theme with no font. Godot's built-in font is used at every
# size, so there is no licensed binary in the repo and the web export stays small.

const OUT := "res://resources/ui_theme.tres"

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://resources")
	)
	var theme := UiTheme.build()
	var err := ResourceSaver.save(theme, OUT)
	print("ui_theme.tres: %s" % ("ok" if err == OK else "FAILED %s" % err))

	# The theme is only project-wide if project.godot says so, and Godot has
	# dropped whole sections of that file before now. Say so loudly here rather
	# than leaving a correctly built theme that nothing loads.
	var configured: String = ProjectSettings.get_setting("gui/theme/custom", "")
	if configured != OUT:
		printerr("project.godot gui/theme/custom is %s, expected %s" % [
			configured if not configured.is_empty() else "<unset>", OUT
		])
		quit(1)
		return
	quit(0 if err == OK else 1)
