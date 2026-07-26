extends VehicleBody3D

const DEFAULT_TUNING := "res://resources/tuning/grippy.tres"

## All feel parameters live in this resource so presets can be swapped whole.
## Falls back to the default preset if unset, so the car is never un-drivable.
@export var tuning: CarTuning

var _front_wheels: Array[VehicleWheel3D] = []
var _rear_wheels: Array[VehicleWheel3D] = []

func _ready() -> void:
	add_to_group("player_car")

	if tuning == null:
		tuning = load(DEFAULT_TUNING)

	for child in get_children():
		if child is VehicleWheel3D:
			if child.use_as_steering:
				_front_wheels.append(child)
			else:
				_rear_wheels.append(child)

	_apply_tuning_to_wheels()

func _apply_tuning_to_wheels() -> void:
	for wheel in _front_wheels + _rear_wheels:
		wheel.suspension_stiffness = tuning.suspension_stiffness
		wheel.suspension_max_force = tuning.suspension_max_force
		wheel.suspension_travel = tuning.suspension_travel
		wheel.damping_compression = tuning.damping_compression
		wheel.damping_relaxation = tuning.damping_relaxation

	for wheel in _front_wheels:
		wheel.wheel_friction_slip = tuning.friction_front
	for wheel in _rear_wheels:
		wheel.wheel_friction_slip = tuning.friction_rear

func _physics_process(delta: float) -> void:
	var steer_input := Input.get_axis("steer_left", "steer_right")
	var accelerate_pressed := Input.is_action_pressed("accelerate")
	var brake_pressed := Input.is_action_pressed("brake")
	var handbrake_pressed := Input.is_action_pressed("handbrake")

	var speed_kmh := linear_velocity.length() * 3.6
	var speed_factor: float = clamp(
		1.0 - speed_kmh / tuning.steer_falloff_reference_kmh, 0.25, 1.0
	)
	# Sign is a guess at VehicleBody3D's steering convention; flip if turning is inverted.
	var steer_target: float = -steer_input * tuning.max_steer_angle * speed_factor
	steering = move_toward(steering, steer_target, tuning.steer_speed * delta)

	# This car model's front faces local +Z, so that's "forward" for braking-vs-reverse.
	var forward_speed := linear_velocity.dot(global_transform.basis.z)

	if handbrake_pressed:
		engine_force = 0.0
		brake = tuning.handbrake_force
	elif accelerate_pressed:
		engine_force = tuning.engine_force
		brake = 0.0
	elif brake_pressed:
		if forward_speed > 0.5:
			engine_force = 0.0
			brake = tuning.brake_force
		else:
			engine_force = -tuning.reverse_force
			brake = 0.0
	else:
		engine_force = 0.0
		brake = 0.0

	var rear_friction: float = (
		tuning.handbrake_rear_friction if handbrake_pressed else tuning.friction_rear
	)
	for wheel in _rear_wheels:
		wheel.wheel_friction_slip = rear_friction

	_apply_drag()
	_apply_antiroll()

	if Input.is_action_just_pressed("reset_car"):
		_reset()

func _apply_drag() -> void:
	apply_central_force(-linear_velocity * linear_velocity.length() * tuning.drag_coefficient)

## How far below the car to look for the road when deciding which way is up, and
## how far the surface may lean before the reading is rejected as a wall.
const GROUND_PROBE := 3.0
const GROUND_MAX_LEAN := 0.5

func _apply_antiroll() -> void:
	var basis := global_transform.basis
	var up := _surface_up()
	# basis.x . up is always 0 for an orthonormal basis measured against its own
	# y; against the road's up it is the actual signed roll (sin of the angle)
	# of the car relative to the surface it is standing on.
	var tilt := basis.x.dot(up)
	var roll_rate := angular_velocity.dot(basis.z)
	apply_torque(
		-basis.z * (tilt * tuning.antiroll_stiffness + roll_rate * tuning.antiroll_damping) * mass
	)

## Which way is up as far as the suspension is concerned: the road's normal.
##
## This used to be world up, which is the same thing on a flat circuit and
## quietly wrong on a banked one. The anti-roll bar reads the angle between the
## car and "up" as body roll to be resisted, so on a 10 degree banking it saw a
## permanently rolled car and spent the whole corner trying to level it against
## the road — the car fought the banking instead of settling into it, which is
## exactly the opposite of what banking is for.
##
## Airborne, or over something too steep to be road, it falls back to world up.
## That is the right answer there too: with no surface to align to, levelling out
## is what a car in the air should do.
func _surface_up() -> Vector3:
	var space := get_world_3d().direct_space_state
	var from := global_transform.origin
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * GROUND_PROBE)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return Vector3.UP
	var normal: Vector3 = hit["normal"]
	# The collision ribbon is two-sided, so a hit from underneath reports an
	# inverted normal; and a near-vertical one is scenery, not road.
	if normal.dot(Vector3.UP) < 0.0:
		normal = -normal
	if normal.dot(Vector3.UP) < GROUND_MAX_LEAN:
		return Vector3.UP
	return normal

func _reset() -> void:
	global_transform.basis = Basis()
	global_transform.origin += Vector3.UP * 1.0
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
