extends SceneTree

# Builds scenes/ui/hud.tscn. Node names must match the @onready paths in
# scripts/ui/hud.gd.

func _initialize() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	layer.set_script(load("res://scripts/ui/hud.gd"))

	var root_ctrl := Control.new()
	root_ctrl.name = "Root"
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root_ctrl)

	# Lap timing, top right.
	var lap_panel := PanelContainer.new()
	lap_panel.name = "LapPanel"
	lap_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	lap_panel.position = Vector2(-230.0, 16.0)
	lap_panel.custom_minimum_size = Vector2(214.0, 0.0)
	root_ctrl.add_child(lap_panel)

	var lap_margin := _margin("LapMargin")
	lap_panel.add_child(lap_margin)

	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.add_theme_constant_override("separation", 2)
	lap_margin.add_child(rows)

	# Right-aligned and fixed width: the panel hugs the screen edge, so anything
	# that grows it pushes content off-screen.
	for spec in [["Lap", "OUT LAP", 20], ["Current", "--:--.---", 30],
			["Last", "last   --:--.---", 15], ["Best", "best   --:--.---", 15]]:
		var l := _label(spec[0], spec[1], spec[2])
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		l.clip_text = true
		rows.add_child(l)

	# Speed, bottom right.
	var speed_panel := PanelContainer.new()
	speed_panel.name = "SpeedPanel"
	speed_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	speed_panel.position = Vector2(-190.0, -84.0)
	root_ctrl.add_child(speed_panel)

	var speed_margin := _margin("SpeedMargin")
	speed_panel.add_child(speed_margin)
	speed_margin.add_child(_label("Speed", "  0 km/h", 34))

	# Lap-completed banner, centred near the top.
	var banner := _label("Banner", "", 40)
	banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	banner.position = Vector2(-260.0, 90.0)
	banner.custom_minimum_size = Vector2(520.0, 0.0)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root_ctrl.add_child(banner)

	root_ctrl.add_child(_touch_controls())

	_set_owner(layer, layer)
	var packed := PackedScene.new()
	packed.pack(layer)
	var err := ResourceSaver.save(packed, "res://scenes/ui/hud.tscn")
	print("hud.tscn: %s" % ("ok" if err == OK else "FAILED %s" % err))
	layer.free()
	quit(0)

## On-screen driving pads, hidden unless the device has a touchscreen. Node names
## must match `REGION_ACTIONS` in scripts/ui/touch_controls.gd.
##
## Every pad is anchored to a *bottom* corner and sized in canvas units, so the
## same layout lands correctly in both orientations: portrait keeps the width and
## grows the canvas downwards, which moves the bottom edge away from the HUD but
## leaves the pads under the thumbs either way. Nothing here is anchored to the
## top, which is where a portrait canvas gains its extra room.
const PAD := 120.0
const PEDAL_W := 148.0
const PEDAL_H := 104.0
const EDGE := 28.0

func _touch_controls() -> Control:
	var root := Control.new()
	root.name = "TouchControls"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# The pads hit-test themselves from raw touch events, so the container must
	# never swallow a press on its way to anything underneath.
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_script(load("res://scripts/ui/touch_controls.gd"))

	# Steering, bottom left, thumb-width apart.
	root.add_child(_pad("SteerLeft", "<", Control.PRESET_BOTTOM_LEFT,
		Vector2(EDGE, -(PAD + EDGE)), Vector2(PAD, PAD)))
	root.add_child(_pad("SteerRight", ">", Control.PRESET_BOTTOM_LEFT,
		Vector2(EDGE + PAD + 16.0, -(PAD + EDGE)), Vector2(PAD, PAD)))

	# Pedals, bottom right, gas below brake so the resting thumb is on the gas.
	root.add_child(_pad("Gas", "GAS", Control.PRESET_BOTTOM_RIGHT,
		Vector2(-(PEDAL_W + EDGE), -(PEDAL_H + EDGE)), Vector2(PEDAL_W, PEDAL_H)))
	root.add_child(_pad("Brake", "BRAKE", Control.PRESET_BOTTOM_RIGHT,
		Vector2(-(PEDAL_W + EDGE), -(PEDAL_H * 2.0 + EDGE + 12.0)),
		Vector2(PEDAL_W, PEDAL_H)))
	return root

func _pad(node_name: String, text: String, preset: int, pos: Vector2,
		size: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = node_name
	panel.set_anchors_preset(preset)
	panel.position = pos
	panel.size = size
	panel.custom_minimum_size = size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var label := _label("Label", text, 30)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(label)
	return panel

func _margin(node_name: String) -> MarginContainer:
	var m := MarginContainer.new()
	m.name = node_name
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 14)
	for side in ["top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 8)
	return m

func _label(node_name: String, text: String, size: int) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l

func _set_owner(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		if c != owner_node:
			c.owner = owner_node
		_set_owner(c, owner_node)
