extends Control

## Streaks at the edge of the frame, flying outward, that arrive with speed.
##
## The third and last thing the game does to say *fast* — the FOV kick and the
## camera shake are the other two, and all three read the same
## `camera_fov_reference_kmh` off the car's tuning so a preset that is quicker is
## quicker in all of them.
##
## ## Why this and not a radial blur
##
## A blur is the obvious screen-space speed effect and it was rejected on both
## halves of the standard this milestone was reordered under. It is a full-screen
## pass sampling the screen texture on a build that is single-threaded WebGL 2,
## and — the part that actually decides it — **it smears the flat silhouettes
## that are the identity.** This game's whole look is untextured colour with hard
## edges; blurring it buys a frame that could have come from any engine. Drawn
## streaks are a graphic device rather than a photographic one, they cost a few
## dozen `draw_line` calls, and they need no screen texture, no shader and no
## second viewport.
##
## ## Why they move outward rather than sitting there
##
## A static set of streaks is a vignette, and a vignette says nothing about
## speed. Each line runs its own loop from the middle of the frame out past the
## edge and fades in and out across it, so what the eye reads is *arrival rate*.
## That is the same claim `_scenery_markers` makes about roadside props, one
## layer closer to the viewer.
##
## ## Geometry
##
## Everything is a fraction of the frame rather than a pixel count, and the
## radius is an **ellipse matched to the viewport** rather than a circle: on a
## 16:9 canvas a circle of streaks reaches the left and right edges long before
## the top and bottom, so the effect would be a pair of side curtains rather than
## a border. The ellipse keeps every direction the same distance from its edge,
## in landscape and in portrait.

## Fractions of the way from the centre of the frame to its edge. Lines are born
## outside the middle - the road ahead and the car are in there and neither wants
## a streak across it - and die past the edge, so nothing is seen to stop.
##
## `INNER` was 0.46 and that was too near the middle: streaks arrived under the
## car, on the one part of the frame the driver is actually reading. The suite
## asserts a floor of 0.35 against a number written out there rather than against
## this constant, which is the version of the check that means something.
const INNER := 0.62
const OUTER := 1.35
## Length of a streak, as the same fraction, at the start and end of its run. It
## grows as it goes: near the edge the frame is moving fastest.
const SHORT := 0.16
const LONG := 0.44
const WIDTH := 3.5

## How many lines are alive at once. Enough to read as a border, few enough that
## the gaps between them are what carries the motion.
const COUNT := 44
## Runs from centre to edge per second at the reference speed.
const RATE := 1.35
## The rate never drops to nothing, or the lines would crawl at exactly the speed
## the eye can follow one and start reading as objects.
const RATE_AT_REST := 0.35

## Fixed, so the pattern is the same every race and in every screenshot. A seed
## chosen at runtime would be a bug report nobody can reproduce.
const SEED := 8184

var _car: VehicleBody3D
var _tuning: CarTuning
## Where each line starts in its own loop, how fast it runs relative to the rest,
## and how bright it is. Fixed at `_ready`.
var _phase := PackedFloat32Array()
var _rate := PackedFloat32Array()
var _weight := PackedFloat32Array()
var _angle := PackedFloat32Array()
## How far the whole set has travelled, in runs.
var _travel := 0.0
var _intensity := 0.0

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in COUNT:
		# Evenly spaced and then jittered, rather than random: COUNT random angles
		# clump, and a clump reads as one thick streak with a hole beside it.
		_angle.append(TAU * (float(i) + rng.randf_range(-0.4, 0.4)) / float(COUNT))
		_phase.append(rng.randf())
		_rate.append(rng.randf_range(0.75, 1.35))
		_weight.append(rng.randf_range(0.45, 1.0))

func _process(delta: float) -> void:
	if _car == null:
		_car = get_tree().get_first_node_in_group("player_car")
		if _car == null:
			return
		_tuning = _car.tuning

	var speed_kmh: float = _car.linear_velocity.length() * 3.6
	var was := _intensity
	_intensity = intensity(speed_kmh)
	_travel += delta * RATE * lerpf(RATE_AT_REST, 1.0,
		clampf(speed_kmh / _tuning.camera_fov_reference_kmh, 0.0, 1.0))
	# A parked car costs one comparison a frame and no redraw. The frame after it
	# stops still redraws, so the last streaks are cleared rather than left on
	# screen.
	if _intensity > 0.0 or was > 0.0:
		queue_redraw()

## How strongly the lines are drawn at this speed, 0 to 1.
##
## **Quadratic in speed, and against the same reference the camera uses.** The
## FOV kick is linear because it is a framing change that should track speed
## honestly; these and the shake are decoration on top of it, and decoration that
## starts at a third of top speed is decoration that is always on.
func intensity(speed_kmh: float) -> float:
	if _tuning == null:
		return 0.0
	var t: float = clampf(speed_kmh / _tuning.camera_fov_reference_kmh, 0.0, 1.0)
	return t * t * _tuning.speed_lines_opacity

## Every streak to draw right now, as `[from, to, alpha]`.
##
## Separate from `_draw` so the suite can assert on the geometry: that nothing is
## drawn at a standstill, and that nothing crosses the middle of the frame, are
## both statements about these numbers rather than about pixels.
func segments() -> Array:
	var out := []
	if _intensity <= 0.0:
		return out
	var centre := size * 0.5
	for i in COUNT:
		# Each line runs its own loop out from the middle and fades in and out
		# across it, so none of them is seen to appear or to stop.
		var run: float = fposmod(_phase[i] + _travel * _rate[i], 1.0)
		var fade: float = sin(PI * run)
		var alpha: float = _intensity * _weight[i] * fade
		if alpha <= 0.0:
			continue
		# The ellipse, not a circle: `size * 0.5` in each direction is exactly the
		# edge of the frame, whatever its shape.
		var out_dir := Vector2(cos(_angle[i]), sin(_angle[i])) * centre
		var from: float = lerpf(INNER, OUTER, run)
		out.append([
			centre + out_dir * from,
			centre + out_dir * (from + lerpf(SHORT, LONG, run)),
			alpha,
		])
	return out

## Light streaks on a dark road, dark ones on a bright road.
##
## **Found by rendering it on snow, where a white streak is invisible.** At full
## opacity on a snow circuit — a white road under a white outfield under a pale
## sky — the effect simply was not there, and no amount of raising the opacity
## would have found that from a tarmac screenshot. One colour cannot sit over a
## frame that is nearly black on one condition and nearly white on another.
##
## The surface decides it, because the surface is what the lower half of the
## frame is made of and it is chosen per race. `base` is the road's own colour,
## already in the table: tarmac 0.21 and dirt about 0.31 are dark, snow 0.87 is
## not. The two colours are the theme's page and text, so this borrows the
## contrast pair the whole interface is already built on rather than inventing a
## second one.
##
## > **What this deliberately does not read is the hour.** A dark hour darkens
## > everything, including snow, so a night snow circuit gets dark streaks over a
## > dimmed white road and they are weaker than they could be. Adding `SkyPreset`
## > to the decision is a second term for a case that is one of eighteen; the
## > ordering by surface holds in every hour, which is the part that matters.
func streak_colour() -> Color:
	var base: Color = RoadSurface.named(GameState.selected_surface)["base"]
	return UiTheme.BG if base.get_luminance() > 0.5 else UiTheme.TEXT

func _draw() -> void:
	for line in segments():
		var colour: Color = streak_colour()
		colour.a = line[2]
		# Antialiased: these are thin near-diagonal lines over a moving image, and
		# the staircase on an aliased one is more visible than the line itself.
		draw_line(line[0], line[1], colour, WIDTH, true)
