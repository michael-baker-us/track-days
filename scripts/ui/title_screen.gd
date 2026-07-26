extends Control

## Track selection. Buttons are built from GameState.TRACKS rather than placed
## in the scene, so adding a track to that list is all it takes to appear here.

const RACE_SCENE := "res://scenes/race.tscn"

@onready var _tracks: VBoxContainer = $Rows/Tracks

func _ready() -> void:
	for i in GameState.TRACKS.size():
		_tracks.add_child(_track_button(i))
	# So the keyboard works without touching the mouse first.
	if _tracks.get_child_count() > 0:
		_tracks.get_child(0).grab_focus()

func _track_button(index: int) -> Button:
	var info: Dictionary = GameState.TRACKS[index]
	var best: float = GameState.best_lap_for(info["id"])
	var best_text: String = (
		"best %s" % _format(best) if best > 0.0 else "no time set"
	)

	var button := Button.new()
	button.custom_minimum_size = Vector2(460.0, 74.0)
	button.text = "%s\n%s   ·   %s" % [info["name"], info["blurb"], best_text]
	button.add_theme_font_size_override("font_size", 19)
	button.pressed.connect(_on_track_pressed.bind(index))
	return button

func _on_track_pressed(index: int) -> void:
	GameState.selected_index = index
	get_tree().change_scene_to_file(RACE_SCENE)

func _format(seconds: float) -> String:
	var minutes := int(seconds / 60.0)
	return "%d:%06.3f" % [minutes, seconds - minutes * 60.0]
