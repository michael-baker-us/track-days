extends Camera3D

## Camera framing comes from the car's CarTuning resource so that swapping a
## feel preset also swaps how the car is framed - chase distance, FOV kick and
## shake are a large part of perceived speed.
##
## ## Shake is a rotation, and it was written as a translation first
##
## Offsetting the camera's *position* is the obvious way to shake it, and it was
## built and measured that way before this comment existed. It does not work,
## for a reason that is obvious once seen and not before: a translation of `d`
## moves an object at distance `z` across the screen by `d/z`, so it moves
## whatever is nearest and almost nothing else. The car sits 4.2 m away and the
## rest of the circuit is tens to hundreds of metres off, so a 0.05 m shake slid
## the car about six pixels and left the road, the trees and the horizon exactly
## where they were. That is not a shaking camera. That is a car with a loose
## wheel — the *opposite* of the thing being asked for, and it was measured with
## `_diag_shake.gd` rather than argued about.
##
## A rotation moves the whole image by `focal * angle` regardless of depth: at
## 720p and a 70 degree vertical FOV that is 514 px per radian, so 0.45 degrees
## is four pixels of the entire frame. Yaw and pitch only, never roll — the
## horizon is the one thing in frame that is reliably level, and rolling it is
## both the disorienting shake and the one that reads as the car spinning.
##
## ## The waveform has a frame rate to live inside
##
## The camera is driven at 120 Hz and *seen* at 60, or at whatever a browser
## gives it. Anything above half the display rate aliases: an early version
## summed harmonics at 26 and 34 Hz, which on a 60 Hz screen is a slow wobble
## that looks like a bug in the smoothing rather than a shake. Every component
## here stays under 15 Hz so it survives a 30 fps frame as well.

var _car: VehicleBody3D
var _tuning: CarTuning

## Where the camera would be looking with no shake, and how far through the
## shake waveform it is, in cycles.
##
## The smoothed basis is held here rather than read back off
## `global_transform.basis`, because the shake is applied to that basis *after*
## the smoothing. Feeding a shaken basis into the next frame's slerp would put
## the buzz through a low-pass filter whose cutoff is the camera lag, so the
## shake would lag its own amplitude and never quite return to centre.
var _aim := Basis()
var _shake_phase := 0.0

## What the phase advances at when the car is stopped, as a fraction of
## `camera_shake_hz`. A kerb's rattle already pitches up with speed for the
## reason this does (`kerb_feel.gd`): the rate at which the road arrives *is* the
## information. It matters much less than it sounds, because amplitude is
## quadratic in speed and there is almost nothing to hear down here.
const SHAKE_RATE_AT_REST := 0.6

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
		_aim = global_transform.basis

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
	_aim = _aim.slerp(
		desired_basis, 1.0 - exp(-_tuning.camera_rotation_lag * delta)
	)

	var speed_kmh: float = _car.linear_velocity.length() * 3.6
	var kick_t: float = clamp(speed_kmh / _tuning.camera_fov_reference_kmh, 0.0, 1.0)
	fov = _tuning.camera_base_fov + _tuning.camera_max_fov_kick * kick_t

	_shake_phase += delta * _tuning.camera_shake_hz * lerpf(SHAKE_RATE_AT_REST, 1.0, kick_t)
	var shake: Vector3 = shake_shape(_shake_phase) * shake_degrees(speed_kmh)
	# Yaw then pitch, in the camera's own frame. `from_euler` takes them as
	# (pitch, yaw, roll), and the third stays zero for as long as this exists.
	global_transform.basis = _aim * Basis.from_euler(
		Vector3(deg_to_rad(shake.y), deg_to_rad(shake.x), 0.0)
	)

## How hard the camera is being shaken right now, in degrees of peak rotation
## per axis. About 514 pixels of 720p per radian, so a degree is nine pixels of
## the whole frame moving at once.
##
## **Quadratic in speed, where the FOV kick is linear.** 55 km/h is a third of
## the reference and about the speed a slow corner is exited at; linear would put
## a third of the shake there - 1.8 px of the frame moving - where squaring puts
## a ninth, which is 0.6 and below what anyone can see. Squaring keeps the effect
## in the top half of the range, where the only thing left to do about speed is
## feel it.
##
## Surface is a multiplier on top rather than a term beside it, so a car
## crawling across dirt still does not shake: loose ground is not a source of
## motion, it is an amplifier of the motion speed already causes.
func shake_degrees(speed_kmh: float) -> float:
	var t: float = clamp(speed_kmh / _tuning.camera_fov_reference_kmh, 0.0, 1.0)
	return (
		_tuning.camera_shake_degrees
		* t * t
		* lerpf(1.0, _tuning.camera_shake_surface_gain,
			RoadSurface.shake_of(GameState.selected_surface))
	)

## What the shake is summed from, per axis: rate against `camera_shake_hz`,
## weight, and a phase offset so the two axes never start together.
##
## Two sines per axis at a rate no fraction of a second brings back into phase,
## which is what stops a shake reading as a bounce - one sine is a pendulum and
## the eye finds it immediately. Deliberately not `FastNoiseLite`: this is four
## sines against a resource plus a seed, and a seed is a bug report nobody can
## reproduce.
##
## A table rather than four sines written out, because the **fastest rate in it
## is load-bearing** and has to be checkable: at the 8 Hz base, 1.79 is 14.3 Hz,
## which still survives a 30 fps frame. The first version was 2.37 and 3.11
## against an 11 Hz base, putting two of the four above a 60 Hz Nyquist limit.
##
## The weights sum to 1.0 per axis, so the amplitude they are multiplied by is in
## degrees and means what it says.
const SHAKE_X := [[1.00, 0.6, 0.0], [1.61, 0.4, 1.7]]
const SHAKE_Y := [[1.27, 0.6, 0.9], [1.79, 0.4, 2.4]]

## The unit shake: yaw in x, pitch in y, and z unused because roll is the one
## rotation that must not happen here.
static func shake_shape(phase: float) -> Vector3:
	var t: float = phase * TAU
	var at := Vector3.ZERO
	for part in SHAKE_X:
		at.x += sin(t * float(part[0]) + float(part[2])) * float(part[1])
	for part in SHAKE_Y:
		at.y += sin(t * float(part[0]) + float(part[2])) * float(part[1])
	return at
