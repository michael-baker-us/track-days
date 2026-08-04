class_name KerbFeel
extends AudioStreamPlayer3D

## The rattle of running over a kerb, and the road coordinate that finds it.
##
## ## Why this needs the centreline and nothing else does
##
## Everything else about the car's relationship to the road is answered by the
## collision world: whether it is on the tarmac at all is a masked raycast, and
## how steep the surface is comes off the contact normal. Neither of them can say
## **how far across** the road the car is, and that is the only thing a kerb is —
## the last metre or so before the edge.
##
## So the circuit carries its centreline as metadata (`TrackBuilder`) and `race.gd`
## hands it over. A painted circuit and a baked one carry it the same way.
##
## ## Why the search is a rolling index rather than a scan
##
## A lap is a couple of thousand points and this is asked every physics frame, so
## a nearest-point scan is a million distance checks a second for one number. The
## car cannot move more than a few metres per frame, so the answer is always
## within a short window of the last one. The window is walked outward from where
## the car was, and only a car that has been teleported — a reset, a respawn —
## falls back to the full scan.
##
## ## Why it is only a sound
##
## A real kerb also *unsettles* the car, and that is deliberately not modelled
## here: the collision ribbon is smooth across its whole width, so there is no
## bump to hit, and shaking the car by hand would be inventing a physical event
## with no physics behind it. Adding ribs to the ribbon is the honest version of
## that and it is a different piece of work.

## The band, measured out from the centreline, that counts as kerb: from just
## inside the painted edge of the road out to the edge itself.
const KERB_FROM := 5.6
const KERB_TO := 7.4
## Below this there is no rattle however far out the car is — a kerb is a rhythm,
## and at walking pace there is no rhythm to hear.
const MIN_KMH := 25.0

## How far either side of the last answer to look before giving up and scanning.
const WINDOW := 24

## How much the rattle speeds up with the car. A kerb's whole information is how
## fast the ribs are going under the tyre.
const PITCH_AT_MIN := 0.55
const PITCH_AT_TOP := 1.7
const TOP_KMH := 160.0

const GAIN_LERP := 14.0

var _line := PackedVector3Array()
var _at := 0
var _car: VehicleBody3D
var _gain := 0.0

func _ready() -> void:
	_car = get_parent() as VehicleBody3D

## Handed the road by `race.gd`, once, when the car is dropped on the grid.
func set_road(line: PackedVector3Array) -> void:
	_line = line
	_at = 0

## How far the point is from the centreline, and where along it that was — the
## two numbers a road coordinate is made of. `-1` back means there is no road.
func nearest(point: Vector3) -> Vector2:
	if _line.is_empty():
		return Vector2(-1.0, -1.0)
	var total := _line.size()
	var best := INF
	var found := -1
	# Outward from the last answer first. A hit inside the window is the common
	# case and costs a few dozen checks instead of a few thousand.
	for step in WINDOW:
		for dir in [step, -step] if step > 0 else [0]:
			var i: int = ((_at + dir) % total + total) % total
			var d := Vector2(_line[i].x - point.x, _line[i].z - point.z).length_squared()
			if d < best:
				best = d
				found = i
	# **Fall back when the winner sits at the edge of the window**, which means
	# the real nearest point is probably outside it.
	#
	# The first version compared the best squared *distance* against `WINDOW *
	# WINDOW` — a count of indices — and the two are only comparable because the
	# centreline happens to be sampled about a metre apart. It answered 17 m
	# across for a point dead on the centreline, because the window ran out
	# before it reached the right index and 17 squared was under the threshold.
	var reach: int = mini(WINDOW - 1, total / 2)
	var apart: int = absi(found - _at)
	if mini(apart, total - apart) >= reach:
		for i in total:
			var d := Vector2(_line[i].x - point.x, _line[i].z - point.z).length_squared()
			if d < best:
				best = d
				found = i
	if found < 0:
		return Vector2(-1.0, -1.0)
	_at = found
	return Vector2(sqrt(best), float(found))

## Whether a point is out on the kerb: near the road's painted edge, on either
## side, and not beyond it.
func on_kerb(point: Vector3) -> bool:
	var across := nearest(point).x
	return across >= KERB_FROM and across <= KERB_TO

func _physics_process(delta: float) -> void:
	if _car == null or _line.is_empty():
		return
	var speed_kmh := _car.linear_velocity.length() * 3.6
	var want := 1.0 if (speed_kmh >= MIN_KMH
		and on_kerb(_car.global_position)) else 0.0
	_gain = lerpf(_gain, want, minf(1.0, GAIN_LERP * delta))

	if not playing and _gain > 0.01 and GameState.audio_enabled() and _audible():
		play()
	elif playing and _gain <= 0.01:
		stop()
	pitch_scale = lerpf(PITCH_AT_MIN, PITCH_AT_TOP,
		clampf(speed_kmh / TOP_KMH, 0.0, 1.0))
	volume_db = -80.0 if _gain <= 0.01 else linear_to_db(_gain)

## Under `--headless` the audio driver is a stub that never mixes, and a playback
## it holds is still held at shutdown. The coordinate and the gain are computed
## either way, so the suite asserts on exactly what the game would do.
func _audible() -> bool:
	return DisplayServer.get_name() != "headless"
