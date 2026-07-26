extends SceneTree

# Builds scenes/editor/track_editor.tscn. Node names must match the @onready
# paths in scripts/ui/track_editor.gd.
#
# The side panel scrolls and the action buttons sit outside it. Laid out as one
# tall column instead, the panel's own minimum height pushed the whole HBox
# past the bottom of the window - which made the *canvas* taller than the
# screen, so "fit the circuit to the view" fitted it to a view partly off-screen
# and the bottom of the track was cut off. Anything with a hard minimum height
# next to the canvas has to be able to scroll.

const PANEL_W := 330.0
const PAD := 12.0

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

	var side := VBoxContainer.new()
	side.name = "Side"
	side.custom_minimum_size = Vector2(PANEL_W, 0.0)
	side.add_theme_constant_override("separation", 6)
	split.add_child(side)

	# Everything explanatory scrolls; the buttons below never do.
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(scroll)

	var panel := VBoxContainer.new()
	panel.name = "Panel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.custom_minimum_size = Vector2(PANEL_W - PAD * 2.0, 0.0)
	panel.add_theme_constant_override("separation", 7)
	scroll.add_child(panel)

	panel.add_child(_label("Heading", "TRACK EDITOR", 25))

	var name_edit := LineEdit.new()
	name_edit.name = "NameEdit"
	name_edit.placeholder_text = "Circuit name"
	panel.add_child(name_edit)

	var picker := OptionButton.new()
	picker.name = "Picker"
	panel.add_child(picker)

	# What to do next. Deliberately the most prominent thing after the heading -
	# it is the only answer to "the editor is open, now what".
	var guide := _wrapped("Guide", 15)
	guide.custom_minimum_size = Vector2(PANEL_W - PAD * 2.0, 54.0)
	panel.add_child(guide)

	panel.add_child(_rule())

	# A legend, not a toolbar: nothing here is clickable, because every action is
	# performed on the canvas by hitting the thing it applies to. It exists so the
	# handles are recognisable the first time they are seen.
	var legend := VBoxContainer.new()
	legend.name = "Legend"
	legend.add_theme_constant_override("separation", 3)
	panel.add_child(legend)
	for row in [
		"drag a green dot — move that corner",
		"drag the road — slide that straight",
		"double-click the road — add a bend",
		"right-click a green dot — remove that corner",
		"click a numbered badge — corner radius",
		"click a badge inside the loop — climb",
		"drag the flag — move the start line",
	]:
		legend.add_child(_label("LegendRow", row, 13))

	panel.add_child(_rule())

	var readout := _wrapped("Readout", 15)
	readout.custom_minimum_size = Vector2(PANEL_W - PAD * 2.0, 96.0)
	panel.add_child(readout)

	var status := _wrapped("Status", 13)
	status.custom_minimum_size = Vector2(PANEL_W - PAD * 2.0, 32.0)
	panel.add_child(status)

	var actions := VBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", 5)
	side.add_child(actions)
	actions.add_child(_button("UndoButton", "Undo  (ctrl+Z)"))
	actions.add_child(_button("SaveButton", "Save  (ctrl+S)"))
	actions.add_child(_button("TestButton", "Test drive"))
	actions.add_child(_button("DeleteButton", "Delete"))
	actions.add_child(_button("BackButton", "Back to menu  (esc)"))

	var keys := _wrapped("Keys", 12)
	keys.text = "wheel zooms · middle-drag pans · F refits · shift-drag paints freehand"
	side.add_child(keys)

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

func _wrapped(node_name: String, size: int) -> Label:
	var l := _label(node_name, "", size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l

func _button(node_name: String, text: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.custom_minimum_size = Vector2(0.0, 30.0)
	return b

func _rule() -> Control:
	var line := ColorRect.new()
	line.name = "Rule"
	line.color = Color(1.0, 1.0, 1.0, 0.10)
	line.custom_minimum_size = Vector2(0.0, 1.0)
	return line

func _set_owner(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		if c != owner_node:
			c.owner = owner_node
		_set_owner(c, owner_node)
