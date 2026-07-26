extends Control

## Track selection. Buttons are built from GameState.all_tracks() rather than
## placed in the scene, so a shipped circuit appears by being added to that list
## and a player-made one simply by existing on disk.

const RACE_SCENE := "res://scenes/race.tscn"
const EDITOR_SCENE := "res://scenes/editor/track_editor.tscn"
const TITLE_SCENE := "res://scenes/title.tscn"

@onready var _tracks: VBoxContainer = $Rows/Tracks
@onready var _editor_button: Button = $Rows/EditorButton

var _entries: Array[Dictionary] = []

func _ready() -> void:
	# Whatever the editor last set it to, Esc from a race started here comes back
	# here.
	GameState.return_scene = TITLE_SCENE
	_entries = GameState.all_tracks()
	for i in _entries.size():
		_tracks.add_child(_track_button(i))
	_editor_button.pressed.connect(_on_editor_pressed)
	# So the keyboard works without touching the mouse first.
	if _tracks.get_child_count() > 0:
		_tracks.get_child(0).grab_focus()

func _track_button(index: int) -> Button:
	var info: Dictionary = _entries[index]
	var best: float = GameState.best_lap_for(info["id"])
	var best_text: String = (
		"best %s" % _format(best) if best > 0.0 else "no time set"
	)

	var button := Button.new()
	button.custom_minimum_size = Vector2(460.0, 74.0)
	button.text = "%s\n%s   ·   %s" % [info["name"], info["blurb"], best_text]
	button.add_theme_font_size_override("font_size", 19)
	# An unfinished custom track has no drivable geometry. Offering it anyway
	# would drop the player onto a broken circuit instead of telling them why.
	if info.get("custom", false) and not (info["layout"] as TrackLayout).compile().ok:
		button.disabled = true
		button.tooltip_text = "This circuit does not close yet — open the editor."
	else:
		button.pressed.connect(_on_track_pressed.bind(index))
	return button

func _on_track_pressed(index: int) -> void:
	GameState.selected_index = index
	get_tree().change_scene_to_file(RACE_SCENE)

func _on_editor_pressed() -> void:
	GameState.editing_id = ""
	get_tree().change_scene_to_file(EDITOR_SCENE)

func _format(seconds: float) -> String:
	var minutes := int(seconds / 60.0)
	return "%d:%06.3f" % [minutes, seconds - minutes * 60.0]
