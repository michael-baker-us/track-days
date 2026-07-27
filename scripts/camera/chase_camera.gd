extends Camera3D

## Camera framing comes from the car's CarTuning resource so that swapping a
## feel preset also swaps how the car is framed - chase distance and FOV kick
## are a large part of perceived speed.

var _car: VehicleBody3D
var _tuning: CarTuning

## The camera has to be told about orientation separately from the UI. Content
## scaling reshapes the canvas; it does nothing to the 3D projection, and
## `Camera3D` defaults to holding the *vertical* FOV — so a portrait phone loses
## most of its horizontal view and the road ahead disappears behind the car. See
## `ViewportScaling.camera_aspect`.
##
## The connection is made from here rather than from `ViewportScaling.attach`, so
## it dies with the camera: the window outlives every scene, and a bound callable
## pointing at a freed camera would otherwise have to be unwired by hand.
func _ready() -> void:
	_apply_aspect()
	get_window().size_changed.connect(_apply_aspect)

func _apply_aspect() -> void:
	if not is_inside_tree():
		return
	keep_aspect = ViewportScaling.camera_aspect(get_window().size)

func _physics_process(delta: float) -> void:
	if _car == null:
		_car = get_tree().get_first_node_in_group("player_car")
		if _car == null:
			return
		_tuning = _car.tuning
		global_transform.origin = _car.global_transform * _tuning.camera_follow_offset

	# Exponential smoothing trails a moving target by roughly velocity/lag, which
	# at 29 m/s and lag 4 is ~7 m - enough that the follow offset stopped meaning
	# anything and the car shrank to a speck at speed. Feeding the velocity
	# forward cancels that steady-state error, so the offset is honest at any
	# speed while smoothing still absorbs acceleration and bumps.
	var desired_pos: Vector3 = (
		_car.global_transform * _tuning.camera_follow_offset
		+ _car.linear_velocity / _tuning.camera_position_lag
	)
	var desired_look: Vector3 = _car.global_transform.origin + _tuning.camera_look_offset

	global_transform.origin = global_transform.origin.lerp(
		desired_pos, 1.0 - exp(-_tuning.camera_position_lag * delta)
	)

	var desired_basis := Transform3D(Basis(), Vector3.ZERO).looking_at(
		desired_look - global_transform.origin, Vector3.UP
	).basis
	global_transform.basis = global_transform.basis.slerp(
		desired_basis, 1.0 - exp(-_tuning.camera_rotation_lag * delta)
	)

	var speed_kmh: float = _car.linear_velocity.length() * 3.6
	var kick_t: float = clamp(speed_kmh / _tuning.camera_fov_reference_kmh, 0.0, 1.0)
	fov = _tuning.camera_base_fov + _tuning.camera_max_fov_kick * kick_t
