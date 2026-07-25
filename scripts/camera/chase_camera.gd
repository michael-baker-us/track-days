extends Camera3D

@export var follow_offset: Vector3 = Vector3(0.0, 2.5, -7.0)
@export var look_offset: Vector3 = Vector3(0.0, 0.8, 0.0)
@export var position_lag: float = 4.0
@export var rotation_lag: float = 5.0
@export var base_fov: float = 70.0
@export var max_fov_kick: float = 12.0
@export var fov_speed_reference_kmh: float = 180.0

var _car: VehicleBody3D

func _physics_process(delta: float) -> void:
	if _car == null:
		_car = get_tree().get_first_node_in_group("player_car")
		if _car == null:
			return
		global_transform.origin = _car.global_transform * follow_offset

	var desired_pos: Vector3 = _car.global_transform * follow_offset
	var desired_look: Vector3 = _car.global_transform.origin + look_offset

	global_transform.origin = global_transform.origin.lerp(desired_pos, 1.0 - exp(-position_lag * delta))

	var desired_basis := Transform3D(Basis(), Vector3.ZERO).looking_at(desired_look - global_transform.origin, Vector3.UP).basis
	global_transform.basis = global_transform.basis.slerp(desired_basis, 1.0 - exp(-rotation_lag * delta))

	var speed_kmh: float = _car.linear_velocity.length() * 3.6
	var kick_t: float = clamp(speed_kmh / fov_speed_reference_kmh, 0.0, 1.0)
	fov = base_fov + max_fov_kick * kick_t
