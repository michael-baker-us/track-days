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

	var grip := _surface_grip()
	for wheel in _front_wheels:
		wheel.wheel_friction_slip = tuning.friction_front * grip
	for wheel in _rear_wheels:
		wheel.wheel_friction_slip = tuning.friction_rear * grip

## How much of the car's own grip the road allows, 1.0 on dry tarmac.
##
## A multiplier rather than a replacement, so it composes: a grippier car is
## still grippier on snow. Read once per frame rather than cached, because the
## surface is chosen on the title screen and a race can be restarted into a
## different one without this node being rebuilt.
##
## ## It has to be applied to the brakes by hand
##
## Setting `wheel_friction_slip` is enough for cornering and not for stopping.
## `VehicleBody3D` applies `brake` as a force at the wheel rather than through the
## friction model, so the tyre never limits it: M2b measured stopping distance as
## byte-identical at friction 1.4, 2.5 and 4.0, and M17 measured 24.2 m from
## 100 km/h on dry tarmac, dirt *and* snow — a 0.4% spread, which is noise. Snow
## that halves your cornering and leaves your braking untouched is exactly the
## wrong way round.
##
## So the brakes, the handbrake, reverse **and drive** are scaled by the same
## number the tyres are. There is deliberately no second table for it: the surface
## scales what a tyre can do, and it should not be able to do that differently in
## one direction than another.
##
## Drive was left alone at first, on the reasoning that it already degraded — the
## rear wheels are traction-limited under power, so they spin instead. Measured,
## that is worth almost nothing: 0-100 took 6.62 s on tarmac and 6.77 s on snow,
## a 2% spread on a surface with half the grip. `wheel_friction_slip` limits how
## much of `engine_force` reaches the road far less than it looks, in the same way
## it never limited `brake` at all.
func _surface_grip() -> float:
	var road := RoadSurface.grip_of(GameState.selected_surface)
	return road if _on_road else road * OFF_ROAD_GRIP

## What is left of the tyres once the car is off the tarmac.
##
## Grass gripped exactly like the road for the whole of the project's life, which
## made leaving the circuit cost nothing but distance — and once surfaces arrived
## it became actively backwards, because running wide on snow put the car on the
## one part of the world with *full* grip. Cutting a corner was only ever
## discouraged by the ordered gates.
##
## It composes rather than replacing, like every other grip term here: dry grass
## is 0.55 of dry tarmac, and grass under snow is 0.55 of snow. There is no
## separate table of off-road surfaces, and no attempt to model a verge as
## distinct from a field — the world outside the ribbon is one flat plane, so
## claiming to know more about it than "not road" would be inventing detail the
## geometry does not have.
const OFF_ROAD_GRIP := 0.55

## Held on the grid until the start lights go out.
##
## **Not `freeze`.** A frozen `RigidBody3D` is removed from the simulation
## entirely, so its suspension never compresses and its wheels never find the
## road — and the moment it is unfrozen the whole car falls onto its springs. The
## car was visibly dropped onto the track at every race start. Held this way the
## physics runs normally the whole time: the car settles on its suspension while
## the lights are counting, exactly as it would if someone were sitting on the
## brakes, and at the release nothing moves that was not already moving.
var held := false

func _physics_process(delta: float) -> void:
	# One probe a frame, read by both the anti-roll bar and the tyres. It has to
	# come first: everything below it asks how much grip there is.
	_probe_surface()

	if held:
		# Everything below still runs: the suspension settles, the anti-roll bar
		# levels the car on its banking, and drag does nothing at a standstill.
		engine_force = 0.0
		brake = tuning.handbrake_force
		steering = 0.0
		for wheel in _rear_wheels:
			wheel.wheel_friction_slip = tuning.handbrake_rear_friction * _surface_grip()
		_apply_drag()
		_apply_antiroll()
		return

	var steer_input := _curve(Input.get_axis("steer_left", "steer_right"))
	var throttle := _pedal(&"accelerate")
	var braking := _pedal(&"brake")
	# The handbrake stays binary whatever the setting: it is bound to a face
	# button, so there is no analogue source to read. Pretending otherwise would
	# be a strength of 1.0 dressed up as a measurement.
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

	var grip := _surface_grip()
	if handbrake_pressed:
		engine_force = 0.0
		brake = tuning.handbrake_force * grip
	elif throttle > 0.0:
		engine_force = tuning.engine_force * throttle * grip
		brake = 0.0
	elif braking > 0.0:
		if forward_speed > 0.5:
			engine_force = 0.0
			brake = tuning.brake_force * braking * grip
		else:
			engine_force = -tuning.reverse_force * braking * grip
			brake = 0.0
	else:
		engine_force = 0.0
		brake = 0.0

	var rear_friction: float = (
		tuning.handbrake_rear_friction if handbrake_pressed else tuning.friction_rear
	) * grip
	for wheel in _rear_wheels:
		wheel.wheel_friction_slip = rear_friction

	_apply_drag()
	_apply_antiroll()

	if Input.is_action_just_pressed("reset_car"):
		_reset()

## How far a pedal is down, 0 to 1.
##
## In analogue mode this is how far a gamepad trigger is pulled, so partial
## throttle out of a hairpin becomes possible for the first time — the triggers
## were previously read through `is_action_pressed` and their travel thrown away
## entirely. A keyboard key and a touch pad both report full strength when held,
## so neither is affected by the setting, and every figure in the tuning journal
## was measured at full lock through one of those two.
##
## Deadzone comes from the InputMap rather than a constant here, so steering and
## the pedals cut in at the same place. Godot zeroes below the deadzone without
## rescaling what is left, which means the pedal engages with a small step rather
## than from nothing. Whether that step wants smoothing out is a feel question
## and belongs in the journal, measured, rather than guessed at here.
func _pedal(action: StringName) -> float:
	if not GameState.analogue_input():
		return 1.0 if Input.is_action_pressed(action) else 0.0
	return Input.get_action_strength(action)

## Shapes stick travel so small movements near centre stay small, while full lock
## is still full lock.
##
## The stick maps linearly today and is then smoothed by `steer_speed`, and the
## two fight each other: the lerp is what gives a keyboard its ramp from nothing
## to full lock, and it blunts an analogue input that already has a position.
##
## Note what this deliberately cannot touch. The curve is an odd power, so it
## fixes -1, 0 and 1 — and a keyboard or a touch pad only ever asks for those
## three. Sticks are the only input it reaches, which is the point, and it is
## also why adding it invalidates nothing already measured.
func _curve(x: float) -> float:
	return signf(x) * pow(absf(x), tuning.steer_response_curve)

func _apply_drag() -> void:
	apply_central_force(-linear_velocity * linear_velocity.length() * tuning.drag_coefficient)

## How far below the car to look for the road when deciding which way is up, and
## how far the surface may lean before the reading is rejected as a wall.
const GROUND_PROBE := 3.0
const GROUND_MAX_LEAN := 0.5

## Filled by `_probe_surface` once a frame.
var _road_up := Vector3.UP
var _on_road := true

func _apply_antiroll() -> void:
	var basis := global_transform.basis
	var up := _road_up
	# basis.x . up is always 0 for an orthonormal basis measured against its own
	# y; against the road's up it is the actual signed roll (sin of the angle)
	# of the car relative to the surface it is standing on.
	var tilt := basis.x.dot(up)
	var roll_rate := angular_velocity.dot(basis.z)
	apply_torque(
		-basis.z * (tilt * tuning.antiroll_stiffness + roll_rate * tuning.antiroll_damping) * mass
	)

## Which way is up as far as the suspension is concerned, and whether the car is
## on the road at all.
##
## **Up** used to be world up, which is the same thing on a flat circuit and
## quietly wrong on a banked one. The anti-roll bar reads the angle between the
## car and "up" as body roll to be resisted, so on a 10 degree banking it saw a
## permanently rolled car and spent the whole corner trying to level it against
## the road — the car fought the banking instead of settling into it, which is
## exactly the opposite of what banking is for. Airborne, or over something too
## steep to be road, it falls back to world up; that is the right answer there
## too, since levelling out is what a car in the air should do.
##
## **On the road** is a second ray, masked to `TrackBuilder.ROAD_LAYER`, so a hit
## is the answer and there is nothing to interpret. It cannot be folded into the
## first: that one has to hit whatever is actually under the car, including the
## field, to know which way up it is.
##
## > Asking one unmasked ray both questions was tried and does not work. The flat
## > parts of the ribbon and the top of the ground slab sit at exactly y = 0, so
## > which one comes back is arbitrary, and walking down through the hits while
## > excluding each collider does not rescue it — the same `Ground` body was
## > measured coming back three times running from a single point, which reported
## > road as field across 40% of Suzuka. Half the grip, disappearing at random on
## > a third of the lap, and nothing on screen to explain it.
func _probe_surface() -> void:
	_road_up = Vector3.UP
	_on_road = false
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var from := global_transform.origin
	var to := from + Vector3.DOWN * GROUND_PROBE
	var mine := [get_rid()]

	var up_query := PhysicsRayQueryParameters3D.create(from, to)
	up_query.exclude = mine
	var hit := space.intersect_ray(up_query)
	if not hit.is_empty():
		var normal: Vector3 = hit["normal"]
		# The collision ribbon is two-sided, so a hit from underneath reports an
		# inverted normal; and a near-vertical one is a wall, not road.
		if normal.dot(Vector3.UP) < 0.0:
			normal = -normal
		if normal.dot(Vector3.UP) >= GROUND_MAX_LEAN:
			_road_up = normal

	var road_query := PhysicsRayQueryParameters3D.create(
		from, to, TrackBuilder.ROAD_LAYER
	)
	road_query.exclude = mine
	_on_road = not space.intersect_ray(road_query).is_empty()

func _reset() -> void:
	global_transform.basis = Basis()
	global_transform.origin += Vector3.UP * 1.0
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
