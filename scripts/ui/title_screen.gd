extends Control

## Track selection. Buttons are built from GameState.all_tracks() rather than
## placed in the scene, so a shipped circuit appears by being added to that list
## and a player-made one simply by existing on disk.

const RACE_SCENE := "res://scenes/race.tscn"
const EDITOR_SCENE := "res://scenes/editor/track_editor.tscn"
const TITLE_SCENE := "res://scenes/title.tscn"

## Tallest the track list is allowed to get before it scrolls. The rest of the
## menu is fixed height, and at the design height of 720 this leaves the heading,
## "Build a track" and the hint all comfortably on screen.
const TRACK_LIST_MAX_H := 340.0

## Width reserved for the Edit button, matched by a spacer on the circuits that do
## not have one so every row ends at the same place.
const EDIT_W := 74.0

@onready var _scroll: ScrollContainer = $Centre/Rows/TrackScroll
@onready var _tracks: VBoxContainer = $Centre/Rows/TrackScroll/Tracks
@onready var _editor_button: Button = $Centre/Rows/EditorButton

var _entries: Array[Dictionary] = []

func _ready() -> void:
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
	_editor_button.pressed.connect(_on_editor_pressed)
	# So the keyboard works without touching the mouse first.
	if _tracks.get_child_count() > 0:
		_tracks.get_child(0).get_child(0).grab_focus()

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
		edit.custom_minimum_size = Vector2(EDIT_W, 74.0)
		edit.add_theme_font_size_override("font_size", 17)
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
	var best: float = GameState.best_lap_for(info["id"])
	var best_text: String = (
		"best %s" % _format(best) if best > 0.0 else "no time set"
	)

	var button := Button.new()
	button.custom_minimum_size = Vector2(300.0, 74.0)
	button.text = "%s\n%s   ·   %s" % [info["name"], info["blurb"], best_text]
	button.add_theme_font_size_override("font_size", 19)
	# An unfinished custom track has no drivable geometry. Offering it anyway
	# would drop the player onto a broken circuit instead of telling them why —
	# but the Edit button beside it stays live, which is where they need to go.
	if info.get("custom", false) and not (info["layout"] as TrackLayout).compile().ok:
		button.disabled = true
		button.tooltip_text = "This circuit does not close yet — edit it to finish it."
	else:
		button.pressed.connect(_on_track_pressed.bind(index))
	return button

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
