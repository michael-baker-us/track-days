extends SceneTree

# Builds scenes/title.tscn. Node names must match the @onready paths in
# scripts/ui/title_screen.gd. The track rows are not built here - the script
# generates them from GameState.all_tracks() at runtime.

## Nominal menu width. The heading is wider than this at 60pt, so the container
## ends up sized by that; this just stops the buttons being narrower than the
## title above them.
const MENU_W := 460.0

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

	# A CenterContainer rather than PRESET_CENTER with hardcoded offsets. The old
	# position of (-230, -190) was half of an assumed 460x380 menu, so the block
	# was never actually centred once the heading made it 539 wide - and it drifted
	# further off-centre and off the bottom of the screen with every track added.
	# A CenterContainer re-centres whatever the content grows to.
	var centre := CenterContainer.new()
	centre.name = "Centre"
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.add_child(centre)

	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.custom_minimum_size = Vector2(MENU_W, 0.0)
	rows.add_theme_constant_override("separation", 10)
	centre.add_child(rows)

	rows.add_child(_label("Heading", "TRACK DAYS", 60))
	rows.add_child(_label("Sub", "select a circuit", 20))
	rows.add_child(_spacer(18))

	# The track list scrolls. Everything else in the menu has a fixed height, so
	# without a cap here a long list pushed "Build a track" and the hint off the
	# bottom of the screen and the last circuits with them. title_screen.gd sizes
	# this to the content up to TRACK_LIST_MAX_H.
	var scroll := ScrollContainer.new()
	scroll.name = "TrackScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(MENU_W, 0.0)
	rows.add_child(scroll)

	var tracks := VBoxContainer.new()
	tracks.name = "Tracks"
	tracks.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tracks.add_theme_constant_override("separation", 10)
	scroll.add_child(tracks)

	rows.add_child(_spacer(18))

	var editor_button := Button.new()
	editor_button.name = "EditorButton"
	editor_button.text = "Build a track"
	editor_button.custom_minimum_size = Vector2(MENU_W, 44.0)
	editor_button.add_theme_font_size_override("font_size", 18)
	rows.add_child(editor_button)

	rows.add_child(_spacer(10))
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
