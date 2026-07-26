extends Node3D

## Loads whichever track was chosen on the title screen, drops the car on its
## start line, and points the lap tracker at that track's record.
##
## The track is instanced here rather than baked into race.tscn so one race
## scene serves every circuit — including the ones the player built, which have
## no scene file at all and are constructed on the spot from their layout.

const TITLE_SCENE := "res://scenes/title.tscn"

@onready var _car: VehicleBody3D = $Car
@onready var _tracker: Node = $LapTracker

func _ready() -> void:
	ViewportScaling.attach(get_window())

	var track_info: Dictionary = GameState.selected()
	_tracker.track_id = track_info["id"]

	var track: Node3D = _make_track(track_info)
	track.name = "Track"
	# Ahead of the car so the car keeps rendering order and group lookups work.
	add_child(track)
	move_child(track, 0)

	var spawn: Marker3D = track.get_node("SpawnPoint")
	_place_car(spawn.position, spawn.rotation.y)

## A shipped circuit is a packed scene; a custom one is built here from its grid
## layout by the same builder that baked the shipped ones, so the two are made
## of identical geometry and everything downstream — lap gates, collision ribbon,
## spawn point — is unaware of the difference.
func _make_track(track_info: Dictionary) -> Node3D:
	if track_info.has("scene"):
		return load(track_info["scene"]).instantiate()
	var layout: TrackLayout = track_info["layout"]
	var compiled := layout.compile()
	return TrackBuilder.new().build(layout.id, compiled.segments).root

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		var back: String = GameState.return_scene
		get_tree().change_scene_to_file(back if not back.is_empty() else TITLE_SCENE)

func _place_car(pos: Vector3, yaw: float) -> void:
	_car.global_transform = Transform3D(Basis(Vector3.UP, yaw), pos)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
