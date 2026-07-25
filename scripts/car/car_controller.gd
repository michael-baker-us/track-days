extends VehicleBody3D

@export var engine_force_value: float = 800.0
@export var max_steer_angle: float = 0.6
@export var steer_speed: float = 4.0
@export var handbrake_force: float = 60.0
@export var steer_falloff_reference_kmh: float = 200.0

func _ready() -> void:
	add_to_group("player_car")

func _physics_process(delta: float) -> void:
	var steer_input := Input.get_axis("steer_left", "steer_right")
	var throttle_input := Input.get_axis("brake", "accelerate")

	var speed_kmh := linear_velocity.length() * 3.6
	var speed_factor: float = clamp(1.0 - speed_kmh / steer_falloff_reference_kmh, 0.25, 1.0)
	# Sign is a guess at VehicleBody3D's steering convention; flip if turning is inverted.
	var steer_target: float = -steer_input * max_steer_angle * speed_factor
	steering = move_toward(steering, steer_target, steer_speed * delta)

	if Input.is_action_pressed("handbrake"):
		engine_force = 0.0
		brake = handbrake_force
	else:
		engine_force = throttle_input * engine_force_value
		brake = 0.0

	if Input.is_action_just_pressed("reset_car"):
		_reset()

func _reset() -> void:
	global_transform.basis = Basis()
	global_transform.origin += Vector3.UP * 1.0
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
