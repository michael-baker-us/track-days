extends VehicleBody3D

const DEFAULT_TUNING := "res://resources/tuning/grippy.tres"

## All feel parameters live in this resource so presets can be swapped whole.
## Falls back to the default preset if unset, so the car is never un-drivable.
@export var tuning: CarTuning

var _front_wheels: Array[VehicleWheel3D] = []
var _rear_wheels: Array[VehicleWheel3D] = []
var _wheels: Array[VehicleWheel3D] = []

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

	_wheels = _front_wheels + _rear_wheels
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

	var grounded := _wheels_on_ground()
	_apply_drag()
	_apply_downforce()
	_apply_antiroll(grounded)
	if grounded == 0:
		_stabilise_airborne()

	if Input.is_action_just_pressed("reset_car"):
		_reset()

func _wheels_on_ground() -> int:
	var count := 0
	for wheel in _wheels:
		if wheel.is_in_contact():
			count += 1
	return count

func _apply_drag() -> void:
	apply_central_force(-linear_velocity * linear_velocity.length() * tuning.drag_coefficient)

## Straight down in world space, not along the chassis.
##
## Aligning it to the chassis would press more squarely into the road on a slope,
## which is tempting — but it points wherever the car does, and a car that is
## pitched steeply or inverted would then have the force pushing it *upward* in
## world terms, adding to a launch at the exact moment it least helps. World down
## is unconditionally safe: it can only ever press towards the ground.
func _apply_downforce() -> void:
	var speed := linear_velocity.length()
	apply_central_force(Vector3.DOWN * speed * speed * tuning.downforce_coefficient)

## The anti-roll bar needs grip to react against. Airborne it just rotates the
## body, so it is faded out with the number of wheels still down and the airborne
## stabiliser takes over.
func _apply_antiroll(grounded: int) -> void:
	if grounded == 0:
		return
	var basis := global_transform.basis
	# basis.x . basis.y is always 0 for an orthonormal basis; the car's right
	# vector against world up is the actual signed roll (sin of the roll angle).
	var tilt := basis.x.dot(Vector3.UP)
	var roll_rate := angular_velocity.dot(basis.z)
	var authority := float(grounded) / float(maxi(1, _wheels.size()))
	apply_torque(
		-basis.z * (tilt * tuning.antiroll_stiffness + roll_rate * tuning.antiroll_damping)
		* mass * authority
	)

## Keeps the car flat and pointing where it was while it has nothing to push
## against, so a crest does not decide the landing for it.
func _stabilise_airborne() -> void:
	apply_torque(airborne_torque(global_transform.basis, angular_velocity) * mass)

## Split out from the applying so the maths can be tested without launching a car
## off a hill: given an attitude and a rotation, the torque that levels it.
func airborne_torque(basis: Basis, ang_vel: Vector3) -> Vector3:
	# Roll and pitch both measured against world up, then corrected about the
	# axis each one turns around.
	var roll := basis.x.dot(Vector3.UP)
	var pitch := basis.z.dot(Vector3.UP)
	var levelling := (-basis.z * roll + basis.x * pitch) * tuning.air_level_torque
	# Bleed off whatever rotation it took off with, yaw included, so it does not
	# arrive sideways.
	return levelling - ang_vel * tuning.air_angular_damping

func _reset() -> void:
	global_transform.basis = Basis()
	global_transform.origin += Vector3.UP * 1.0
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
