extends Node3D

## Loads whichever track was chosen on the title screen, drops the car on its
## start line, and points the lap tracker at that track's record.
##
## The track is instanced here rather than baked into race.tscn so one race
## scene serves every circuit.

const TITLE_SCENE := "res://scenes/title.tscn"

@onready var _car: VehicleBody3D = $Car
@onready var _tracker: Node = $LapTracker

func _ready() -> void:
	var track_info: Dictionary = GameState.selected()
	_tracker.track_id = track_info["id"]

	var track: Node3D = load(track_info["scene"]).instantiate()
	track.name = "Track"
	# Ahead of the car so the car keeps rendering order and group lookups work.
	add_child(track)
	move_child(track, 0)

	var spawn: Marker3D = track.get_node("SpawnPoint")
	_place_car(spawn.position, spawn.rotation.y)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_tree().change_scene_to_file(TITLE_SCENE)

func _place_car(pos: Vector3, yaw: float) -> void:
	_car.global_transform = Transform3D(Basis(Vector3.UP, yaw), pos)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
