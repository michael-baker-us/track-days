class_name TitleScreen
extends Control

## Track selection. Buttons are built from GameState.all_tracks() rather than
## placed in the scene, so a shipped circuit appears by being added to that list
## and a player-made one simply by existing on disk.
##
## A row is one `Button` with labels laid over it, not a container of widgets:
## the whole row has to be a single focusable, pressable thing for the keyboard
## and a gamepad, and Godot's Button draws its own text rather than hosting a
## child label. So the circuit's name is the button's text — pushed to the top
## left by the lopsided content margins on the `CardButton` style — and the blurb
## and lap time are `Label`s anchored into the space that leaves. They are all
## mouse-transparent, so the press still belongs to the button underneath.

const RACE_SCENE := "res://scenes/race.tscn"
const EDITOR_SCENE := "res://scenes/editor/track_editor.tscn"
const TITLE_SCENE := "res://scenes/title.tscn"

## Width reserved for the Edit button, matched by a spacer on the circuits that do
## not have one so every row ends at the same place.
const EDIT_W := 74.0

## Width reserved for Delete. Fixed rather than sized to its text, because the
## button relabels itself to "Sure?" when armed and a row that resized under the
## pointer would move the second press somewhere else.
const DELETE_W := 84.0

## Gap between the card and the buttons beside it. Named because the spacer that
## keeps the shipped rows the same width has to reserve exactly what the custom
## ones spend, including the gaps.
const ROW_SEP := 8

## Row geometry. The card style reserves the bottom 40px of the row for the blurb
## (see `UiTheme.V_CARD`), so the height here has to leave room for it.
const CARD_H := 88.0
const CARD_MIN_W := 300.0
const PAD := 20.0

## Width of the right-hand column: caption over value, right-aligned.
const META_W := 150.0

## Vertical gap between rows, shared with tools/build_title.gd so the scene and
## the height cap below cannot disagree about how tall three rows are.
const ROW_GAP := 10

## Tallest the track list is allowed to get before it scrolls: three whole rows.
## The rest of the menu is fixed height, and at the design height of 720 this
## leaves the wordmark, "Build a track" and the hint all comfortably on screen.
## Whole rows rather than a round number, so the list never ends on a half-drawn
## card pretending to be a full one.
const TRACK_LIST_MAX_H := CARD_H * 3.0 + ROW_GAP * 2.0

@onready var _scroll: ScrollContainer = $Centre/Rows/TrackScroll
@onready var _tracks: VBoxContainer = $Centre/Rows/TrackScroll/Tracks
@onready var _count: Label = $Centre/Rows/ListHeader/Count
@onready var _car_button: Button = $Centre/Rows/ChoiceRow/CarButton
@onready var _surface_button: Button = $Centre/Rows/ChoiceRow/SurfaceButton
@onready var _editor_button: Button = $Centre/Rows/EditorButton

var _entries: Array[Dictionary] = []

## The one Delete button currently asking "Sure?", if any. At most one: arming a
## second disarms the first, so the list never shows two circuits both a single
## press from being gone.
var _armed: Button = null

## Held so a rebuild can kill the fade still running over rows it is about to
## free, rather than leaving a half-faded row behind.
var _reveal_tween: Tween = null

func _ready() -> void:
	ViewportScaling.attach(get_window())
	# Whatever the editor last set it to, Esc from a race started here comes back
	# here.
	GameState.return_scene = TITLE_SCENE
	_populate()
	_car_button.pressed.connect(_on_car_pressed)
	_surface_button.pressed.connect(_on_surface_pressed)
	_editor_button.pressed.connect(_on_editor_pressed)
	# So the keyboard works without touching the mouse first.
	_focus_row(0)

## Builds the list from disk. Called again after a deletion rather than reloading
## the scene, so the menu keeps its scroll position and the row that replaces the
## deleted one can take focus — a scene change would drop the player back at the
## top of the list with focus on the first circuit.
func _populate() -> void:
	_armed = null
	if _reveal_tween != null and _reveal_tween.is_valid():
		_reveal_tween.kill()
	# `remove_child` as well as `queue_free`: a freed child is still a child until
	# the end of the frame, and the height measured below counts children.
	for row in _tracks.get_children():
		_tracks.remove_child(row)
		row.queue_free()

	_entries = GameState.all_tracks()
	for i in _entries.size():
		_tracks.add_child(_track_row(i))
	# Size the list to its contents, up to the cap, so a short list has no
	# scrollbar and a long one does not push the rest of the menu off screen.
	_scroll.custom_minimum_size.y = minf(
		_tracks.get_combined_minimum_size().y, TRACK_LIST_MAX_H
	)
	_count.text = _count_text()
	_refresh_car()
	_refresh_surface()
	_reveal()

## How many circuits, and how many of them are the player's. Two shipped tracks
## look like the whole game until the menu admits the rest of the list is yours.
func _count_text() -> String:
	var mine := 0
	for info in _entries:
		if info.get("custom", false):
			mine += 1
	if mine == 0:
		return "%d SHIPPED" % _entries.size()
	return "%d SHIPPED  ·  %d YOURS" % [_entries.size() - mine, mine]

## Fades the rows in, briefly and in order. Opacity only, never position: the
## rows are laid out by a container, so anything that moved them would be fought
## by the next layout pass — and the suite measures where they land.
func _reveal() -> void:
	_reveal_tween = create_tween()
	_reveal_tween.set_parallel(true)
	for i in _tracks.get_child_count():
		var row: Control = _tracks.get_child(i)
		row.modulate.a = 0.0
		_reveal_tween.tween_property(row, "modulate:a", 1.0, 0.18).set_delay(i * 0.035)

## Puts the keyboard and the gamepad on a row, used on entry and again after a
## deletion so the list is still navigable without reaching for the mouse. Takes
## the first control on the row that will actually accept focus: an unfinished
## circuit's card is disabled, so on those rows it is Edit that takes it — which
## is where that circuit needs the player anyway.
func _focus_row(index: int) -> void:
	var count := _tracks.get_child_count()
	if count > 0:
		for child in _tracks.get_child(clampi(index, 0, count - 1)).get_children():
			var button := child as Button
			if button != null and not button.disabled:
				button.grab_focus()
				return
	_editor_button.grab_focus()

## One row per circuit: the track itself, plus an Edit button for the ones the
## player built. Without that, getting back to a saved circuit meant opening the
## editor — which starts a *new* track — and then finding yours in the dropdown.
func _track_row(index: int) -> HBoxContainer:
	var info: Dictionary = _entries[index]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", ROW_SEP)

	var button := _track_button(index)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(button)

	if info.get("custom", false):
		var edit := Button.new()
		edit.text = "Edit"
		edit.custom_minimum_size = Vector2(EDIT_W, CARD_H)
		edit.tooltip_text = "Open %s in the track editor" % info["name"]
		edit.pressed.connect(_on_edit_pressed.bind(String(info["id"])))
		row.add_child(edit)
		row.add_child(_delete_button(info))
	else:
		# The shipped circuits have nothing to edit and cannot be deleted, but they
		# still need the width reserving or their rows run wider than the custom
		# ones and the right-hand edge of the menu comes out ragged.
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(EDIT_W + ROW_SEP + DELETE_W, 0.0)
		row.add_child(gap)
	return row

## Removes a circuit the player built. It sits one row-width from "drive this
## circuit" and there is no undo — the file is gone — so it arms rather than
## fires: the first press relabels it "Sure?" and only the second deletes.
##
## A modal would be the obvious alternative, and was the first thing tried. It
## costs more than it looks: this menu is deliberately one flat list of focusable
## rows so a gamepad can walk it, and a `ConfirmationDialog` is a `Window` that
## takes focus away from that list, hands it back somewhere else on close, and
## arrives wearing stock Godot chrome, because the project theme styles Controls
## and says nothing about windows. Arming keeps the whole interaction on the
## control the player is already pointing at.
func _delete_button(info: Dictionary) -> Button:
	var button := Button.new()
	button.theme_type_variation = UiTheme.V_DANGER
	button.text = "Delete"
	button.custom_minimum_size = Vector2(DELETE_W, CARD_H)
	button.tooltip_text = "Delete %s — this cannot be undone" % info["name"]
	button.pressed.connect(_on_delete_pressed.bind(button, info))
	# Walking away disarms it. Without this a row left armed stays a single press
	# from deletion however long the player spends elsewhere in the menu.
	button.focus_exited.connect(_disarm.bind(button))
	button.mouse_exited.connect(_disarm.bind(button))
	return button

func _track_button(index: int) -> Button:
	var info: Dictionary = _entries[index]
	var button := Button.new()
	button.theme_type_variation = UiTheme.V_CARD
	button.custom_minimum_size = Vector2(CARD_MIN_W, CARD_H)
	# The name is the button's own text, so the row still identifies itself to
	# anything reading the control rather than the labels drawn over it.
	button.text = String(info["name"])
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.clip_text = true

	# An unfinished custom track has no drivable geometry. Offering it anyway
	# would drop the player onto a broken circuit instead of telling them why —
	# but the Edit button beside it stays live, which is where they need to go.
	var broken: bool = (
		info.get("custom", false)
		and not (info["layout"] as TrackLayout).compile().ok
	)
	if broken:
		button.disabled = true
		button.tooltip_text = "This circuit does not close yet — edit it to finish it."
	else:
		button.pressed.connect(_on_track_pressed.bind(index))

	_blurb(button, String(info["blurb"]))
	if broken:
		_meta(button, "STATUS", "unfinished", UiTheme.DANGER)
	else:
		var best: float = GameState.best_lap_for(info["id"])
		var par := GameState.par_for(info)
		if best > 0.0:
			# The medal is the caption rather than a separate line: the column is
			# a caption over a value, and "which medal" is what that time *is*.
			var medal := GameState.medal_for(best, par)
			var caption := (
				"BEST LAP" if medal == GameState.Medal.NONE
				else "%s LAP" % GameState.medal_name(medal)
			)
			_meta(button, caption, _format(best), _medal_colour(medal))
		elif par > 0.0:
			# Never driven: show what gold is worth instead of a dash, so a
			# circuit says what it is asking for before it is attempted.
			_meta(button, "GOLD AT", _format(par * GameState.MEDAL_GOLD),
				UiTheme.MUTED)
		else:
			_meta(button, "BEST LAP", "—", UiTheme.MUTED)
	return button

## Medal colours, from the theme rather than invented here, so they mean the same
## thing as everywhere else: accent is the good result the screen is built around,
## text is ordinary, muted is the least of the three. There is no brown in the
## palette and adding one for bronze alone would be a colour with a single user.
func _medal_colour(medal: GameState.Medal) -> Color:
	match medal:
		GameState.Medal.GOLD:
			return UiTheme.ACCENT
		GameState.Medal.SILVER:
			return UiTheme.TEXT
		GameState.Medal.BRONZE:
			return UiTheme.MUTED
		_:
			return UiTheme.ACCENT

## The circuit's description, along the bottom of the card, stopping short of the
## lap time column so a long blurb truncates instead of colliding with it.
func _blurb(card: Button, text: String) -> void:
	var label := _overlay(card, text, UiTheme.V_MUTED, HORIZONTAL_ALIGNMENT_LEFT)
	label.anchor_top = 1.0
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	label.offset_left = PAD
	label.offset_right = -(META_W + PAD)
	label.offset_top = -34.0
	label.offset_bottom = -12.0
	label.clip_text = true

## The right-hand column: a small caption over the value it labels. The colour is
## set per row because it carries meaning — a real lap time is accent, an unset
## one is muted, an unfinished circuit is danger.
func _meta(card: Button, caption: String, value: String, colour: Color) -> void:
	var cap := _overlay(card, caption, UiTheme.V_SECTION, HORIZONTAL_ALIGNMENT_RIGHT)
	_pin_right(cap, 20.0, 38.0)

	var val := _overlay(card, value, UiTheme.V_CARD_META, HORIZONTAL_ALIGNMENT_RIGHT)
	_pin_right(val, 38.0, 70.0)
	val.add_theme_color_override("font_color", colour)

func _pin_right(label: Label, top: float, bottom: float) -> void:
	label.anchor_left = 1.0
	label.anchor_right = 1.0
	label.offset_left = -(META_W + PAD)
	label.offset_right = -PAD
	label.offset_top = top
	label.offset_bottom = bottom

func _overlay(card: Button, text: String, variation: StringName,
		align: int) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	label.horizontal_alignment = align
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Never eat the press: the row is the button, and these only draw on it.
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Godot dims a disabled Button's own text, but knows nothing about labels
	# laid over it, so a broken circuit would keep a bright blurb.
	if card.disabled:
		label.modulate.a = 0.5
	card.add_child(label)
	return label

func _on_delete_pressed(button: Button, info: Dictionary) -> void:
	if _armed != button:
		_arm(button, info)
		return
	# Read the index off the live list rather than closing over the one this row
	# was built with: the list is rebuilt on every deletion, so a captured index
	# would be stale the second time round.
	var track_id := String(info["id"])
	var index := _index_of(track_id)
	GameState.delete_track(track_id)
	_populate()
	# The row that slid up into this one's place, so a second deletion needs no
	# fresh navigation and the focus never lands on nothing.
	_focus_row(index)

func _arm(button: Button, info: Dictionary) -> void:
	_disarm(_armed)
	_armed = button
	button.text = "Sure?"
	button.tooltip_text = "Press again to delete %s" % info["name"]

func _disarm(button: Button) -> void:
	# Guarded, because both signals that call this fire on rows that were never
	# armed, and `focus_exited` also fires on the armed button as the list is
	# rebuilt out from under it.
	if button == null or not is_instance_valid(button) or button != _armed:
		return
	_armed = null
	button.text = "Delete"

func _index_of(track_id: String) -> int:
	for i in _entries.size():
		if String(_entries[i]["id"]) == track_id:
			return i
	return 0

func _on_edit_pressed(track_id: String) -> void:
	GameState.editing_id = track_id
	get_tree().change_scene_to_file(EDITOR_SCENE)

func _on_track_pressed(index: int) -> void:
	GameState.selected_index = index
	get_tree().change_scene_to_file(RACE_SCENE)

## Cycles the garage.
##
## The lap times on the rows are per car — the record key has always included one
## — so changing the car re-reads every row. That is the point of showing it here
## rather than in the race: which car you are in changes what your best lap on
## each circuit *is*, and the menu should say so before you set off.
func _on_car_pressed() -> void:
	var specs := GameState.cars()
	var at := 0
	for i in specs.size():
		if specs[i].id == GameState.selected_car:
			at = i
	GameState.selected_car = specs[(at + 1) % specs.size()].id
	_populate()
	_car_button.grab_focus()

## Cycles the conditions the next lap is driven in.
##
## Beside the car for the same reason: both are chosen before a lap rather than
## being part of the circuit, and a lap record is keyed on `track|car|surface`.
## Changing either re-reads every row, because the times on them are that
## combination's times — a dry record is not a snow record and never was.
func _on_surface_pressed() -> void:
	GameState.selected_surface = RoadSurface.after(GameState.selected_surface)
	_populate()
	_surface_button.grab_focus()

func _refresh_surface() -> void:
	_surface_button.text = RoadSurface.label_of(GameState.selected_surface)
	_surface_button.tooltip_text = (
		"Conditions. Less grip, a slower target, and records of its own."
	)

func _refresh_car() -> void:
	var spec := GameState.selected_car_spec()
	var blurb := spec.blurb
	_car_button.text = (
		"Car:  %s" % spec.display_name if blurb.is_empty()
		else "Car:  %s  -  %s" % [spec.display_name, blurb]
	)
	_car_button.tooltip_text = "Change car. Lap records are kept per car."

func _on_editor_pressed() -> void:
	GameState.editing_id = ""
	get_tree().change_scene_to_file(EDITOR_SCENE)

func _format(seconds: float) -> String:
	var minutes := int(seconds / 60.0)
	return "%d:%06.3f" % [minutes, seconds - minutes * 60.0]
