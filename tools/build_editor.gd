extends SceneTree

# Builds scenes/editor/track_editor.tscn. Node names must match the @onready
# paths in scripts/ui/track_editor.gd; the mode buttons are not built here,
# because the script generates them from its own MODES list.

const PANEL_W := 320.0

func _initialize() -> void:
	var root_ctrl := Control.new()
	root_ctrl.name = "TrackEditor"
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.set_script(load("res://scripts/ui/track_editor.gd"))

	var bg := ColorRect.new()
	bg.name = "Background"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.11, 0.13, 0.15)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ctrl.add_child(bg)

	var split := HBoxContainer.new()
	split.name = "Split"
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	split.add_theme_constant_override("separation", 0)
	root_ctrl.add_child(split)

	var grid := Control.new()
	grid.name = "Grid"
	grid.set_script(load("res://scripts/ui/track_grid.gd"))
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(grid)

	var panel := VBoxContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(PANEL_W, 0.0)
	panel.add_theme_constant_override("separation", 8)
	split.add_child(panel)

	panel.add_child(_label("Heading", "TRACK EDITOR", 26))

	var name_edit := LineEdit.new()
	name_edit.name = "NameEdit"
	name_edit.placeholder_text = "Circuit name"
	panel.add_child(name_edit)

	var picker := OptionButton.new()
	picker.name = "Picker"
	panel.add_child(picker)

	panel.add_child(_spacer(6))

	var modes := VBoxContainer.new()
	modes.name = "Modes"
	modes.add_theme_constant_override("separation", 4)
	panel.add_child(modes)

	var hint := _label("Hint", "", 14)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(PANEL_W - 24.0, 52.0)
	hint.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	panel.add_child(hint)

	panel.add_child(_spacer(6))

	var readout := _label("Readout", "", 15)
	readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	readout.custom_minimum_size = Vector2(PANEL_W - 24.0, 120.0)
	readout.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	panel.add_child(readout)

	# Pushes the buttons to the bottom of the panel.
	var filler := Control.new()
	filler.name = "Filler"
	filler.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(filler)

	var actions := VBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", 6)
	panel.add_child(actions)
	actions.add_child(_button("SaveButton", "Save  (ctrl+S)"))
	actions.add_child(_button("TestButton", "Test drive"))
	actions.add_child(_button("DeleteButton", "Delete"))
	actions.add_child(_button("BackButton", "Back to menu  (esc)"))

	panel.add_child(_label(
		"Keys", "wheel zooms · middle-drag pans · F refits", 13
	))

	_set_owner(root_ctrl, root_ctrl)
	var packed := PackedScene.new()
	packed.pack(root_ctrl)
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://scenes/editor")
	)
	var err := ResourceSaver.save(packed, "res://scenes/editor/track_editor.tscn")
	print("track_editor.tscn: %s" % ("ok" if err == OK else "FAILED %s" % err))
	root_ctrl.free()
	quit(0 if err == OK else 1)

func _label(node_name: String, text: String, size: int) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l

func _button(node_name: String, text: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.custom_minimum_size = Vector2(0.0, 34.0)
	return b

func _spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0.0, height)
	return c

func _set_owner(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		if c != owner_node:
			c.owner = owner_node
		_set_owner(c, owner_node)
