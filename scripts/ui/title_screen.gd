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
@onready var _editor_button: Button = $Centre/Rows/EditorButton

var _entries: Array[Dictionary] = []

func _ready() -> void:
	ViewportScaling.attach(get_window())
	# Whatever the editor last set it to, Esc from a race started here comes back
	# here.
	GameState.return_scene = TITLE_SCENE
	_entries = GameState.all_tracks()
	for i in _entries.size():
		_tracks.add_child(_track_row(i))
	# Size the list to its contents, up to the cap, so a short list has no
	# scrollbar and a long one does not push the rest of the menu off screen.
	_scroll.custom_minimum_size.y = minf(
		_tracks.get_combined_minimum_size().y, TRACK_LIST_MAX_H
	)
	_count.text = _count_text()
	_editor_button.pressed.connect(_on_editor_pressed)
	# So the keyboard works without touching the mouse first.
	if _tracks.get_child_count() > 0:
		_tracks.get_child(0).get_child(0).grab_focus()
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
	var tween := create_tween()
	tween.set_parallel(true)
	for i in _tracks.get_child_count():
		var row: Control = _tracks.get_child(i)
		row.modulate.a = 0.0
		tween.tween_property(row, "modulate:a", 1.0, 0.18).set_delay(i * 0.035)

## One row per circuit: the track itself, plus an Edit button for the ones the
## player built. Without that, getting back to a saved circuit meant opening the
## editor — which starts a *new* track — and then finding yours in the dropdown.
func _track_row(index: int) -> HBoxContainer:
	var info: Dictionary = _entries[index]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

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
	else:
		# The shipped circuits have nothing to edit, but they still need the width
		# reserving or their rows run wider than the custom ones and the right-hand
		# edge of the menu comes out ragged.
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(EDIT_W, 0.0)
		row.add_child(gap)
	return row

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
		if best > 0.0:
			_meta(button, "BEST LAP", _format(best), UiTheme.ACCENT)
		else:
			_meta(button, "BEST LAP", "—", UiTheme.MUTED)
	return button

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

func _on_edit_pressed(track_id: String) -> void:
	GameState.editing_id = track_id
	get_tree().change_scene_to_file(EDITOR_SCENE)

func _on_track_pressed(index: int) -> void:
	GameState.selected_index = index
	get_tree().change_scene_to_file(RACE_SCENE)

func _on_editor_pressed() -> void:
	GameState.editing_id = ""
	get_tree().change_scene_to_file(EDITOR_SCENE)

func _format(seconds: float) -> String:
	var minutes := int(seconds / 60.0)
	return "%d:%06.3f" % [minutes, seconds - minutes * 60.0]
