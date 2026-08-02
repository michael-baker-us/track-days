extends SceneTree

# Builds scenes/title.tscn. Node names must match the @onready paths in
# scripts/ui/title_screen.gd — and `Centre/Rows/TrackScroll/Tracks` plus
# `Centre/Rows/EditorButton` are asserted on by tests/run_tests.gd, which is what
# keeps "the menu still fits however many circuits are saved" honest.
#
# Widget styling is not here. Everything visual comes from the project theme
# (resources/ui_theme.tres, built by tools/build_theme.gd); this file places
# things and names type variations. If a colour or a corner radius appears in
# this file, it belongs in scripts/ui/ui_theme.gd instead.
#
# The track rows are not built here — the script generates them from
# GameState.all_tracks() at runtime.

## Nominal menu width. Wide enough for a circuit name, its blurb and a lap time
## on one row without the blurb truncating, and comfortably inside the 720 units
## a portrait canvas gets (see ViewportScaling).
const MENU_W := 600.0

func _initialize() -> void:
	var root_ctrl := Control.new()
	root_ctrl.name = "Title"
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.set_script(load("res://scripts/ui/title_screen.gd"))

	var bg := ColorRect.new()
	bg.name = "Background"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = UiTheme.BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ctrl.add_child(bg)

	# A single wide pool of light behind the menu, so the flat fill reads as a
	# lit room rather than a blank buffer. Cheap enough for the compatibility
	# renderer the web build uses: one scaled 256px texture, no shader.
	var glow := TextureRect.new()
	glow.name = "Glow"
	glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	glow.texture = _radial(UiTheme.ACCENT, 0.12)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ctrl.add_child(glow)

	# A CenterContainer rather than PRESET_CENTER with hardcoded offsets. The old
	# position of (-230, -190) was half of an assumed 460x380 menu, so the block
	# was never actually centred once the heading made it wider — and it drifted
	# further off-centre and off the bottom of the screen with every track added.
	# A CenterContainer re-centres whatever the content grows to.
	var centre := CenterContainer.new()
	centre.name = "Centre"
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.add_child(centre)

	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.custom_minimum_size = Vector2(MENU_W, 0.0)
	rows.add_theme_constant_override("separation", 12)
	centre.add_child(rows)

	rows.add_child(_masthead())
	rows.add_child(_spacer(10))
	rows.add_child(_list_header())

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
	tracks.add_theme_constant_override("separation", TitleScreen.ROW_GAP)
	scroll.add_child(tracks)

	rows.add_child(_spacer(6))

	# The garage. One button that cycles rather than a list: there are two cars,
	# the choice belongs next to the circuits it applies to, and the menu has a
	# fixed height that a second scrolling list would eat. It sits *below* the
	# track list because a circuit is what you pick first and a car is what you
	# pick it in.
	#
	# The label is written by title_screen.gd from the selected spec.
	# Car and conditions on one row. Both are things you choose *before* a lap
	# rather than parts of the circuit, and a lap record is keyed on the pair —
	# so they belong together and beneath the list they apply to.
	var car_button := Button.new()
	car_button.name = "CarButton"
	car_button.text = "Car"
	var surface_button := Button.new()
	surface_button.name = "SurfaceButton"
	surface_button.text = "Dry"
	surface_button.custom_minimum_size = Vector2(150.0, 40.0)
	rows.add_child(_row("ChoiceRow", [car_button, surface_button]))

	rows.add_child(_spacer(4))

	var editor_button := Button.new()
	editor_button.name = "EditorButton"
	editor_button.text = "+   Build a track"
	editor_button.custom_minimum_size = Vector2(MENU_W, 48.0)
	rows.add_child(editor_button)

	rows.add_child(_spacer(4))
	var hint := _label("Hint", "arrows select  ·  enter drives  ·  esc returns here from a race")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.theme_type_variation = UiTheme.V_MUTED
	rows.add_child(hint)

	root_ctrl.add_child(_badge())

	_set_owner(root_ctrl, root_ctrl)
	var packed := PackedScene.new()
	packed.pack(root_ctrl)
	var err := ResourceSaver.save(packed, "res://scenes/title.tscn")
	print("title.tscn: %s" % ("ok" if err == OK else "FAILED %s" % err))
	root_ctrl.free()
	quit(0 if err == OK else 1)

## The game's name, its one accent rule, and what this screen is for. Grouped in
## its own box so the whole lockup moves as a unit if the menu is re-ordered.
func _masthead() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "Masthead"
	box.add_theme_constant_override("separation", 0)

	# Letterspaced by inserting spaces. Godot only offers glyph spacing through a
	# FontVariation, which would mean shipping a font resource wrapping the
	# built-in font purely to move nine letters apart.
	var word := HBoxContainer.new()
	word.name = "Wordmark"
	word.alignment = BoxContainer.ALIGNMENT_CENTER
	word.add_theme_constant_override("separation", 20)
	word.add_child(_wordmark_part("Track", "TRACK", UiTheme.TEXT))
	word.add_child(_wordmark_part("Days", "DAYS", UiTheme.ACCENT))
	box.add_child(word)

	box.add_child(_spacer(14))

	# A short accent bar, centred, standing in for the underline the wordmark
	# would otherwise need. Its own CenterContainer so it stays 84 wide instead
	# of stretching to the menu.
	var rule_centre := CenterContainer.new()
	rule_centre.name = "RuleCentre"
	var rule := ColorRect.new()
	rule.name = "Rule"
	rule.color = UiTheme.ACCENT
	rule.custom_minimum_size = Vector2(84.0, 3.0)
	rule_centre.add_child(rule)
	box.add_child(rule_centre)

	box.add_child(_spacer(12))

	var sub := _label("Sub", "arcade circuit racing")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.theme_type_variation = UiTheme.V_MUTED
	box.add_child(sub)
	return box

func _wordmark_part(node_name: String, text: String, colour: Color) -> Label:
	var l := _label(node_name, _tracked(text))
	l.theme_type_variation = UiTheme.V_WORDMARK
	l.add_theme_color_override("font_color", colour)
	return l

## The one label above the list, and a count the script fills in — a menu that
## says how many circuits there are reads as a list rather than as everything
## there could ever be.
func _list_header() -> HBoxContainer:
	var header := HBoxContainer.new()
	header.name = "ListHeader"

	var section := _label("Section", "CIRCUITS")
	section.theme_type_variation = UiTheme.V_SECTION
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(section)

	var count := _label("Count", "")
	count.theme_type_variation = UiTheme.V_SECTION
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(count)
	return header

## Says out loud what this build is, in the corner, so the menu can look finished
## without claiming the game is.
func _badge() -> Label:
	var badge := _label("Badge", "TECH DEMO")
	badge.theme_type_variation = UiTheme.V_SECTION
	badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.position = Vector2(-140.0, 18.0)
	badge.custom_minimum_size = Vector2(120.0, 0.0)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return badge

## A soft radial wash, transparent at the edges. Built here rather than shipped
## as an image so there is no binary asset to keep in step with the palette.
func _radial(colour: Color, alpha: float) -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(colour.r, colour.g, colour.b, alpha))
	gradient.set_color(1, Color(colour.r, colour.g, colour.b, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.42)
	tex.fill_to = Vector2(1.0, 1.0)
	tex.width = 256
	tex.height = 256
	return tex

## Puts a space between every letter. Applied to the wordmark only: at 54pt a
## tight default advance makes a ten-letter title look like body text set large.
func _tracked(text: String) -> String:
	var out := PackedStringArray()
	for i in text.length():
		out.append(text[i])
	return " ".join(out)

func _label(node_name: String, text: String) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	return l

## A row of controls sharing the width, the wider one first.
func _row(node_name: String, controls: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = node_name
	row.add_theme_constant_override("separation", 8)
	for i in controls.size():
		var c: Control = controls[i]
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if i == 0:
			c.size_flags_stretch_ratio = 2.6
		row.add_child(c)
	return row

func _spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0.0, height)
	return c

func _set_owner(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		if c != owner_node:
			c.owner = owner_node
		_set_owner(c, owner_node)
