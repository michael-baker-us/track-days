extends VehicleBody3D

@export_group("Drivetrain")
@export var engine_force_value: float = 8000.0
@export var reverse_force_value: float = 3000.0
@export var brake_force: float = 3000.0
## Aerodynamic drag. Force grows with speed squared, so this sets the top
## speed (engine force balances drag) and makes acceleration taper off
## naturally instead of climbing linearly forever.
@export var drag_coefficient: float = 1.6

@export_group("Grip")
## Rear grip sits slightly above front so the car washes out into mild,
## predictable understeer at the limit rather than snapping into oversteer.
@export var friction_front: float = 10.5
@export var friction_rear: float = 11.5
## Handbrake cuts rear grip to break the back loose on demand - slides are
## something you provoke, not something that happens to you.
@export var handbrake_rear_friction: float = 2.0
@export var handbrake_force: float = 4000.0

@export_group("Steering")
@export var max_steer_angle: float = 0.6
@export var steer_speed: float = 4.0
@export var steer_falloff_reference_kmh: float = 200.0

@export_group("Stability")
## Virtual anti-roll bar. VehicleBody3D has no roll stiffness of its own, so
## quick steering reversals unload the inside wheels and put the car on two
## wheels. This resists body roll without reducing grip.
@export var antiroll_stiffness: float = 15.0
@export var antiroll_damping: float = 4.0

var _front_wheels: Array[VehicleWheel3D] = []
var _rear_wheels: Array[VehicleWheel3D] = []

func _ready() -> void:
	add_to_group("player_car")

	for child in get_children():
		if child is VehicleWheel3D:
			if child.use_as_steering:
				_front_wheels.append(child)
			else:
				_rear_wheels.append(child)

	for wheel in _front_wheels:
		wheel.wheel_friction_slip = friction_front
	for wheel in _rear_wheels:
		wheel.wheel_friction_slip = friction_rear

func _physics_process(delta: float) -> void:
	var steer_input := Input.get_axis("steer_left", "steer_right")
	var accelerate_pressed := Input.is_action_pressed("accelerate")
	var brake_pressed := Input.is_action_pressed("brake")
	var handbrake_pressed := Input.is_action_pressed("handbrake")

	var speed_kmh := linear_velocity.length() * 3.6
	var speed_factor: float = clamp(1.0 - speed_kmh / steer_falloff_reference_kmh, 0.25, 1.0)
	# Sign is a guess at VehicleBody3D's steering convention; flip if turning is inverted.
	var steer_target: float = -steer_input * max_steer_angle * speed_factor
	steering = move_toward(steering, steer_target, steer_speed * delta)

	# This car model's front faces local +Z, so that's "forward" for braking-vs-reverse.
	var forward_speed := linear_velocity.dot(global_transform.basis.z)

	if handbrake_pressed:
		engine_force = 0.0
		brake = handbrake_force
	elif accelerate_pressed:
		engine_force = engine_force_value
		brake = 0.0
	elif brake_pressed:
		if forward_speed > 0.5:
			engine_force = 0.0
			brake = brake_force
		else:
			engine_force = -reverse_force_value
			brake = 0.0
	else:
		engine_force = 0.0
		brake = 0.0

	var rear_friction := handbrake_rear_friction if handbrake_pressed else friction_rear
	for wheel in _rear_wheels:
		wheel.wheel_friction_slip = rear_friction

	_apply_drag()
	_apply_antiroll()

	if Input.is_action_just_pressed("reset_car"):
		_reset()

func _apply_drag() -> void:
	apply_central_force(-linear_velocity * linear_velocity.length() * drag_coefficient)

func _apply_antiroll() -> void:
	var basis := global_transform.basis
	# basis.x . basis.y is always 0 for an orthonormal basis; the car's right
	# vector against world up is the actual signed roll (sin of the roll angle).
	var tilt := basis.x.dot(Vector3.UP)
	var roll_rate := angular_velocity.dot(basis.z)
	apply_torque(-basis.z * (tilt * antiroll_stiffness + roll_rate * antiroll_damping) * mass)

func _reset() -> void:
	global_transform.basis = Basis()
	global_transform.origin += Vector3.UP * 1.0
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
