extends Control

## Rain in front of the camera, drawn into the frame.
##
## The third thing `storm` does, after the road going dark and glossy and the
## tyres throwing water. Same shape as `speed_lines.gd` and for the same reasons:
## a `Control` on the HUD layer drawing short strokes, no screen texture, no
## shader, nothing a single-threaded WebGL 2 build cannot do.
##
## ## Falling streaks, not droplets on glass
##
## The obvious version is beads clinging to the lens and sliding down it, and it
## is wrong here for a reason the camera settles: **there is no glass.** The
## chase camera is a third-person view floating behind the car, not a driver's
## eye behind a windscreen, so anything stuck to the front of it is a smudge on a
## lens the game has never claimed to have. Rain falling *through* the space
## between the camera and the car is the honest reading of the same effect, and
## it is also the one that moves.
##
## ## The slant is the speed
##
## Rain falls straight down and a car driving into it does not see it that way:
## the faster you go, the more it comes at the screen from ahead. So the streaks
## lean with `camera_fov_reference_kmh` — the same number the FOV kick, the
## camera shake and the speed lines are scaled against — and the whole set tilts
## as the car accelerates. It costs one term and it is the difference between
## weather happening near the car and weather the car is driving through.

## How many streaks are in the air at full rain. Rain reads as *many and thin*;
## a dozen fat ones is a leak rather than a downpour.
const COUNT := 110
## Length as a fraction of the frame's height, and how much longer a streak gets
## at the reference speed. A stroke that does not lengthen with speed reads as
## snow.
const SHORT := 0.045
const LONG := 0.11
const WIDTH := 1.6

## Falls per second: how many times a streak crosses the frame top to bottom.
const FALL := 1.35
## How far a streak leans, as a fraction of its own length, stopped and at the
## reference speed. Negative because the car drives *into* it, so the top of a
## stroke is ahead of the bottom.
const LEAN_AT_REST := -0.15
const LEAN_AT_SPEED := -0.85

## Opacity at full rain. Deliberately low: this sits over the whole frame,
## including the car, and rain you have to look through is rain you cannot drive
## through.
const OPACITY := 0.30

## Fixed, so the pattern is the same every race and in every screenshot.
const SEED := 6109

var _car: VehicleBody3D
var _tuning: CarTuning
var _rain := 0.0
## Where each streak sits across the frame, where it starts down it, and how
## fast it falls relative to the rest. Fixed at `_ready`.
var _across := PackedFloat32Array()
var _phase := PackedFloat32Array()
var _rate := PackedFloat32Array()
var _weight := PackedFloat32Array()
var _fallen := 0.0
## Standing-still values rather than zero, so the first frame after the lights go
## out draws rain rather than a set of zero-length streaks.
var _lean := LEAN_AT_REST
var _length := SHORT

## Handed over by `race.gd`, the way the hour is handed to the headlights and the
## rain to the tyre spray. The weather belongs to the circuit, and nothing on the
## HUD layer has any business searching the scene for it.
func set_rain(amount: float) -> void:
	_rain = clampf(amount, 0.0, 1.0)
	visible = _rain > 0.0
	set_process(_rain > 0.0)

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in COUNT:
		_across.append(rng.randf())
		_phase.append(rng.randf())
		# Nearer streaks fall faster and are longer, which is the only depth cue
		# a flat overlay has.
		_rate.append(rng.randf_range(0.7, 1.45))
		_weight.append(rng.randf_range(0.35, 1.0))
	set_process(false)
	visible = false

func _process(delta: float) -> void:
	if _rain <= 0.0:
		return
	if _car == null:
		_car = get_tree().get_first_node_in_group("player_car")
		if _car == null:
			return
		_tuning = _car.tuning

	var t: float = clampf(
		_car.linear_velocity.length() * 3.6 / _tuning.camera_fov_reference_kmh,
		0.0, 1.0)
	_lean = lerpf(LEAN_AT_REST, LEAN_AT_SPEED, t)
	_length = lerpf(SHORT, LONG, t)
	_fallen += delta * FALL
	queue_redraw()

## Every streak to draw right now, as `[from, to, alpha]`.
##
## Separate from `_draw` so the suite can assert on it: that a dry circuit draws
## nothing at all, and that the strokes lean further at speed, are both
## statements about these numbers rather than about pixels.
func segments() -> Array:
	var out := []
	if _rain <= 0.0:
		return out
	var length := _length * size.y
	for i in COUNT:
		# Each streak falls from above the frame to below it and starts again, so
		# none of them is seen to appear or to stop.
		var fall: float = fposmod(_phase[i] + _fallen * _rate[i], 1.0)
		var top := Vector2(
			_across[i] * size.x + length * _lean,
			fall * (size.y + length * 2.0) - length)
		out.append([
			top,
			top + Vector2(-length * _lean, length),
			_rain * OPACITY * _weight[i],
		])
	return out

func _draw() -> void:
	for streak in segments():
		var colour: Color = UiTheme.TEXT
		colour.a = streak[2]
		draw_line(streak[0], streak[1], colour, WIDTH, true)
