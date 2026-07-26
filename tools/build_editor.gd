extends SceneTree

# Builds scenes/editor/track_editor.tscn. Node names must match the @onready
# paths in scripts/ui/track_editor.gd.
#
# The legend scrolls and everything else in the panel does not. Something in the
# column has to be able to give: laid out as one tall stack of fixed heights, the
# panel's own minimum height pushed the whole HBox past the bottom of the window
# - which made the *canvas* taller than the screen, so "fit the circuit to the
# view" fitted it to a view partly off-screen and the bottom of the track was cut
# off. The legend is the right thing to sacrifice, because it is reference the
# player stops needing; the readout is not, because it is the answer to "what did
# that edit just do".
#
# Widget styling is not here. Colours, borders and font sizes come from the
# project theme (resources/ui_theme.tres, built by tools/build_theme.gd); this
# file places things and names type variations.

## Panel width, and the width its contents can count on: the panel style spends
## 18px either side, and the scrollbar takes a little more when the column is
## long enough to scroll.
const PANEL_W := 364.0
const INNER_W := PANEL_W - 18.0 * 2.0 - 12.0

func _initialize() -> void:
	var root_ctrl := Control.new()
	root_ctrl.name = "TrackEditor"
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.set_script(load("res://scripts/ui/track_editor.gd"))

	var bg := ColorRect.new()
	bg.name = "Background"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = UiTheme.BG
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

	# The panel is a surface in its own right, not a strip of controls floating
	# on the canvas: one border down its left edge separates the thing being
	# edited from the tools that edit it.
	var side := PanelContainer.new()
	side.name = "Side"
	side.theme_type_variation = UiTheme.V_SIDEBAR
	side.custom_minimum_size = Vector2(PANEL_W, 0.0)
	split.add_child(side)

	# Only the legend scrolls, and it is last in the column, so it absorbs
	# whatever height is left over. Everything above it is feedback or a control
	# and stays on screen at the design height of 720: putting the readout inside
	# a scroll region is what pushed the live verdict under the fold, and it is
	# wanted on every single edit.
	var rows := VBoxContainer.new()
	rows.name = "Rows"
	rows.add_theme_constant_override("separation", 6)
	side.add_child(rows)

	rows.add_child(_header())

	var name_edit := LineEdit.new()
	name_edit.name = "NameEdit"
	name_edit.placeholder_text = "Circuit name"
	rows.add_child(name_edit)

	var picker := OptionButton.new()
	picker.name = "Picker"
	rows.add_child(picker)

	# Drawing and shaping are peers, so the switch between them is a visible
	# toggle rather than a modifier key nobody discovers.
	var draw_button := _button("DrawButton", "Draw road  (D)")
	draw_button.toggle_mode = true
	rows.add_child(draw_button)

	# What to do next. Deliberately the most prominent thing after the heading -
	# it is the only answer to "the editor is open, now what". In its own framed
	# card so it reads as advice rather than as another line of status.
	rows.add_child(_card("GuideCard", "DO THIS NEXT", _wrapped("Guide", 56.0)))

	# The live verdict: what the circuit *is*, updated on every edit.
	rows.add_child(_card("ReadoutCard", "THIS CIRCUIT", _wrapped("Readout", 84.0)))

	var status := _wrapped("Status", 30.0)
	status.theme_type_variation = UiTheme.V_FINE
	rows.add_child(status)

	# The legend's caption doubles as its switch. It opens over the canvas rather
	# than inside the column: content scaling pins the canvas to 720 units tall
	# whatever the window, so there is no such thing as a window with room to
	# spare here, and eleven lines of reference will never fit alongside the
	# controls and the feedback.
	var legend_toggle := _button("LegendToggle", "HANDLES ON THE CANVAS")
	legend_toggle.theme_type_variation = UiTheme.V_DISCLOSURE
	legend_toggle.toggle_mode = true
	# Open to begin with: the handles have to be recognisable the first time the
	# canvas is seen, and the switch beside it is how they are put away.
	legend_toggle.button_pressed = true
	legend_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	legend_toggle.custom_minimum_size = Vector2(0.0, 22.0)
	rows.add_child(legend_toggle)

	rows.add_child(_actions())

	var keys := _wrapped("Keys", 28.0)
	keys.theme_type_variation = UiTheme.V_FINE
	keys.text = (
		"wheel or pinch zooms \u00b7 middle-drag, two-finger drag or cmd-drag pans"
		+ " \u00b7 F refits \u00b7 shift-drag draws"
	)
	rows.add_child(keys)

	# Added after the split, so it draws over the canvas rather than under it.
	root_ctrl.add_child(_legend())

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

## A legend, not a toolbar: nothing here is clickable, because every action is
## performed on the canvas by hitting the thing it applies to. It exists so the
## handles are recognisable the first time they are seen, which is why it is the
## one thing allowed to fold away — the player stops needing it.
func _legend() -> PanelContainer:
	var flyout := PanelContainer.new()
	flyout.name = "LegendFlyout"
	flyout.visible = true
	# Pinned to the bottom right of the canvas, just clear of the panel, and
	# grown up and to the left from there: anchored this way it sizes itself to
	# its contents instead of needing a height guessed here and corrected every
	# time a line is added.
	flyout.anchor_left = 1.0
	flyout.anchor_top = 1.0
	flyout.anchor_right = 1.0
	flyout.anchor_bottom = 1.0
	flyout.offset_left = -(PANEL_W + 12.0)
	flyout.offset_right = -(PANEL_W + 12.0)
	flyout.offset_top = -16.0
	flyout.offset_bottom = -16.0
	flyout.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	flyout.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var panel := VBoxContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(INNER_W, 0.0)
	panel.add_theme_constant_override("separation", 4)
	flyout.add_child(panel)

	var legend := VBoxContainer.new()
	legend.name = "Legend"
	legend.add_theme_constant_override("separation", 3)
	panel.add_child(legend)
	# Each mode's own rows are indented under it, so the two halves cannot be
	# read as one list.
	for row: Array in [
		["mode", "DRAW ON"],
		["item", "drag lays road \u00b7 right-drag erases"],
		["gap", ""],
		["mode", "DRAW OFF"],
		["item", "drag a green dot \u2014 move a corner"],
		["item", "drag the road \u2014 slide a straight"],
		["item", "double-click it \u2014 add a bend, then drag that bend in or out"],
		["item", "right-click a dot \u2014 remove a corner"],
		["item", "numbered badge \u2014 corner radius"],
		["item", "badge inside the loop \u2014 raise it; raise a corner too to hold"
			+ " the height right through it"],
		["item", "drag the flag \u2014 move the start"],
	]:
		legend.add_child(_legend_row(row[0], row[1]))
	return flyout

## Six actions in three rows rather than six stacked buttons: stacked, they ate
## enough of a 720-unit column that the readout above them had to scroll, and the
## pairs here are natural — undo/save, delete/leave.
func _actions() -> VBoxContainer:
	var actions := VBoxContainer.new()
	actions.name = "Actions"
	actions.add_theme_constant_override("separation", 6)

	# Shown only when the drawn road actually has two ends to join. Accented
	# while it is visible: an unclosed circuit has exactly one useful next move.
	var close_button := _button("CloseButton", "Join the ends up")
	close_button.theme_type_variation = UiTheme.V_PRIMARY
	close_button.visible = false
	actions.add_child(close_button)

	actions.add_child(_pair("UndoRow",
		_button("UndoButton", "Undo  (ctrl+Z)"),
		_button("SaveButton", "Save  (ctrl+S)")
	))

	# The payoff. Everything else in the panel exists to make this button work.
	var test_button := _button("TestButton", "Test drive")
	test_button.theme_type_variation = UiTheme.V_PRIMARY
	test_button.custom_minimum_size = Vector2(0.0, 38.0)
	actions.add_child(test_button)

	var delete_button := _button("DeleteButton", "Delete")
	delete_button.theme_type_variation = UiTheme.V_DANGER
	actions.add_child(_pair("ExitRow", delete_button,
		_button("BackButton", "Back  (esc)")))
	return actions

## Two buttons sharing a row. Named, because two containers called the same thing
## under one parent get silently renumbered by Godot and the @onready paths in
## track_editor.gd would then point at whichever one it renamed.
func _pair(node_name: String, left: Button, right: Button) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = node_name
	row.add_theme_constant_override("separation", 6)
	for b in [left, right]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	return row


## Names the screen and says what it is for in one line, which is the whole
## orientation a first-time visitor gets before the panel starts talking about
## corners.
func _header() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "Header"
	box.add_theme_constant_override("separation", 2)
	var heading := _label("Heading", "TRACK EDITOR")
	heading.theme_type_variation = UiTheme.V_HEADING
	box.add_child(heading)
	var sub := _label("Sub", "draw a circuit, then drive it")
	sub.theme_type_variation = UiTheme.V_MUTED
	box.add_child(sub)
	return box

## A framed block with its own small caption. Groups the panel's two paragraphs
## so neither reads as a stray sentence.
func _card(node_name: String, caption: String, body: Label) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = node_name
	card.theme_type_variation = UiTheme.V_CARD_PANEL
	var box := VBoxContainer.new()
	box.name = "Rows"
	box.add_theme_constant_override("separation", 4)
	box.add_child(_section("Caption", caption))
	body.theme_type_variation = UiTheme.V_BODY
	box.add_child(body)
	card.add_child(box)
	return card

func _section(node_name: String, text: String) -> Label:
	var l := _label(node_name, text)
	l.theme_type_variation = UiTheme.V_SECTION
	return l

func _legend_row(kind: String, text: String) -> Control:
	if kind == "gap":
		return _spacer(6)
	var l := _label("LegendRow", text)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if kind == "mode":
		l.theme_type_variation = UiTheme.V_SECTION
	else:
		l.theme_type_variation = UiTheme.V_MUTED
		# Indented under the mode it belongs to, with the indent as layout rather
		# than as leading spaces, so a wrapped second line lines up too.
		var indent := MarginContainer.new()
		indent.name = "LegendIndent"
		indent.add_theme_constant_override("margin_left", 10)
		indent.add_child(l)
		return indent
	return l

func _label(node_name: String, text: String) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	return l

func _wrapped(node_name: String, min_height: float) -> Label:
	var l := _label(node_name, "")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size = Vector2(0.0, min_height)
	return l

func _button(node_name: String, text: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.custom_minimum_size = Vector2(0.0, 32.0)
	return b

func _spacer(height: int) -> Control:
	var c := Control.new()
	c.name = "Spacer"
	c.custom_minimum_size = Vector2(0.0, height)
	return c

func _set_owner(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		if c != owner_node:
			c.owner = owner_node
		_set_owner(c, owner_node)
