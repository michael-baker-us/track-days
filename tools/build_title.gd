extends SceneTree

# Builds scenes/title.tscn. Node names must match the @onready paths in
# scripts/ui/title_screen.gd. The track buttons are not built here - the script
# generates them from GameState.TRACKS at runtime.

func _initialize() -> void:
	var root_ctrl := Control.new()
	root_ctrl.name = "Title"
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.set_script(load("res://scripts/ui/title_screen.gd"))

	var bg := ColorRect.new()
	bg.name = "Background"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.11, 0.13, 0.15)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ctrl.add_child(bg)

	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.set_anchors_preset(Control.PRESET_CENTER)
	rows.position = Vector2(-230.0, -190.0)
	rows.custom_minimum_size = Vector2(460.0, 0.0)
	rows.add_theme_constant_override("separation", 10)
	root_ctrl.add_child(rows)

	rows.add_child(_label("Heading", "TRACK DAYS", 60))
	rows.add_child(_label("Sub", "select a circuit", 20))
	rows.add_child(_spacer(18))

	var tracks := VBoxContainer.new()
	tracks.name = "Tracks"
	tracks.add_theme_constant_override("separation", 10)
	rows.add_child(tracks)

	rows.add_child(_spacer(18))
	rows.add_child(_label("Hint", "esc returns here from a race", 15))

	_set_owner(root_ctrl, root_ctrl)
	var packed := PackedScene.new()
	packed.pack(root_ctrl)
	var err := ResourceSaver.save(packed, "res://scenes/title.tscn")
	print("title.tscn: %s" % ("ok" if err == OK else "FAILED %s" % err))
	root_ctrl.free()
	quit(0)

func _label(node_name: String, text: String, size: int) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	return l

func _spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0.0, height)
	return c

func _set_owner(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		if c != owner_node:
			c.owner = owner_node
		_set_owner(c, owner_node)
