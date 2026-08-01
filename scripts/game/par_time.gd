class_name ParTime
extends RefCounted

## How long a lap of a given circuit ought to take.
##
## Used live in the editor, so a designer can see what they have drawn before
## driving it, and it is the same function the medals will be derived from
## (`docs/roadmap.md`, M15). That is the reason it is a class of its own rather
## than a helper inside the editor: a par time the editor showed and the medals
## disagreed with would be worse than no readout at all.
##
## ## Why this is a simulation rather than a fitted constant
##
## `docs/ideas.md` sketched `length / effective_average_speed(corners, peak)`
## with the constant calibrated against the shipped circuits. That works, but it
## has to be re-calibrated whenever the handling changes, and it cannot tell a
## circuit with one long straight from one with the same length in short bursts.
##
## This instead runs the standard quasi-static lap simulation over the
## centreline the builder has already produced: cap the speed at every point by
## how hard the car can corner there, then make the result reachable by sweeping
## forwards under acceleration and backwards under braking. It is the textbook
## method, it is O(n), and every constant in it is a *measurement* rather than a
## fit.
##
## ## The constants, and where they were measured
##
## All from `docs/tuning-journal.md`, none invented here:
##
## - **3.65 g lateral** — the measured grip at the shipped 4.0/4.5 friction.
##   The journal also records what that produced on real corners: 98 km/h on a
##   21 m radius and 127 km/h on 35 m. `sqrt(3.65 * 9.81 * 21)` is 98.7 km/h and
##   `sqrt(3.65 * 9.81 * 35)` is 127.4, so the cornering half of this model is
##   directly checked against measurement rather than assumed.
##
##   Note those are the *middle* and *largest* Kenney corners. The radius is
##   `(size - 0.5)` tile units, so the three are **7 m, 21 m and 35 m**, and the
##   smallest is a genuine 57 km/h hairpin rather than a rounding error. All
##   three shipped circuits contain one, which is why they all report the same
##   slowest corner.
## - **1.62 g braking** — measured at 100->0 in 1.75 s / 24.1 m, and identically
##   at every grip level tested, because braking here is brake-limited rather
##   than traction-limited.
## - **164.9 km/h top speed** and **0-100 km/h in 3.37 s**, both re-measured in
##   M8 and unchanged since M1.
##
## Acceleration is modelled as `A * (1 - (v/v_max)^2)` — full thrust at rest,
## nothing left at top speed — which is the shape drag actually produces. `A` is
## not free: integrating that form to 100 km/h in 3.37 s fixes it at 9.56 m/s².
## It predicts 0-60 in 1.83 s against a measured 2.13, so it is optimistic low
## down, where the real car is traction-limited off the line. That is the right
## direction for a *par* time and the wrong direction to use this for anything
## claiming to be a real lap.

const G := 9.81

## Measured. See the class comment for where each came from.
const LATERAL_G := 3.65
const BRAKING_G := 1.62
const TOP_SPEED := 45.8      ## m/s, 164.9 km/h
const LAUNCH_ACCEL := 9.56   ## m/s^2 at a standstill

## The centreline is sampled unevenly — eight steps around a corner arc, one per
## tile down a straight — so it is resampled to a fixed step before anything is
## integrated over it. Fine enough that a corner is many samples, coarse enough
## that a 2 km lap is a few hundred of them.
const STEP := 5.0

## Passes needed for a closed loop. One forward and one backward sweep is enough
## for a circuit with a start and an end; a loop has neither, so the limit
## arriving at the line has to be carried back round to affect the corner before
## it. Two laps of each sweep converges; a third changes nothing.
const SWEEPS := 2

## How much slower a good human lap is than a perfect one.
##
## **This is the one number here that is not measured**, and it is the only one
## a real lap time would settle. The simulation drives every corner at exactly
## the limit and every straight flat out, which nobody does. Until M15 calibrates
## it against driven laps it is a stated placeholder, not a finding — which is
## why the editor shows the ideal lap rather than this.
const HUMAN_SLACK := 1.08

## Seconds for a perfect lap of `centreline`, or 0.0 if there is not enough of a
## circuit to say.
##
## `centreline` is the builder's, which `measure()` fills without instancing a
## single tile — so this costs the editor nothing beyond the walk it was already
## doing on every mouse move.
static func ideal_lap(centreline: Array[Vector3]) -> float:
	var walk := resample(centreline)
	var points: Array[Vector3] = walk[0]
	var limit: PackedFloat32Array = walk[1]
	if points.size() < 8:
		return 0.0

	var n := points.size()
	var speed := limit.duplicate()
	for _sweep in SWEEPS:
		# Forwards under power, then backwards under braking. The backward pass
		# is what puts the braking zone *before* the corner rather than letting
		# the car arrive too fast and slow down inside it.
		for i in n:
			var j := (i + 1) % n
			speed[j] = minf(speed[j], _after_accelerating(speed[i]))
		for i in range(n - 1, -1, -1):
			var j := (i + n - 1) % n
			speed[j] = minf(speed[j], _before_braking(speed[i]))

	var total := 0.0
	for i in n:
		var j := (i + 1) % n
		# Trapezoidal: over one step the speed goes from one to the other, so the
		# time it takes is the step divided by the average of the two.
		total += 2.0 * STEP / maxf(speed[i] + speed[j], 0.001)
	return total

## What the same lap is worth as a target for a person rather than for the
## simulation. Separate from `ideal_lap` so the unmeasured constant is applied
## in exactly one visible place.
static func par_lap(centreline: Array[Vector3]) -> float:
	return ideal_lap(centreline) * HUMAN_SLACK

## Fastest the car can hold the bend at `i`, from the radius of the circle
## through its neighbours.
##
## Measured **flat**, on the horizontal projection, while distance is measured in
## 3D. A crest is curvature too, and taking it into account here would read a
## gentle brow as a corner and brake for it — the car is limited by grip through
## bends, not by the shape of the hill it is going over.
##
## Neighbours are found by walking outwards past any that sit on top of this
## one, because the centreline **closes by repeating its first point**. Without
## the search that wrap-around triangle has a zero-length side, and the
## collinearity test below would quietly call the start line dead straight —
## which is nearly true here and would not be on a circuit whose start sits in a
## bend. Defensive rather than a fix for an observed wrong number, and it also
## covers coincident vertices anywhere else a piece happens to produce them.
static func _corner_speed(points: Array[Vector3], i: int) -> float:
	var a := _neighbour(points, i, -1)
	var c := _neighbour(points, i, 1)
	if a < 0 or c < 0:
		return TOP_SPEED
	var radius := _circumradius(
		_flat(points[a]), _flat(points[i]), _flat(points[c])
	)
	if radius <= 0.0:
		return TOP_SPEED
	return sqrt(LATERAL_G * G * radius)

## Shortest chord worth measuring a turn across. Below this the three points are
## effectively one and the circle through them means nothing.
const MIN_CHORD := 0.25

## Index of the nearest point in `direction` that is genuinely somewhere else,
## or -1 if the whole loop is degenerate.
static func _neighbour(points: Array[Vector3], i: int, direction: int) -> int:
	var n := points.size()
	var at := i
	for _step in n:
		at = posmod(at + direction, n)
		if at == i:
			break
		if points[at].distance_to(points[i]) >= MIN_CHORD:
			return at
	return -1

static func _flat(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)

## Radius of the circle through three points; INF where they are collinear,
## which is what a straight is.
static func _circumradius(a: Vector2, b: Vector2, c: Vector2) -> float:
	var ab := a.distance_to(b)
	var bc := b.distance_to(c)
	var ca := c.distance_to(a)
	# Twice the signed area, via the cross product of two edges.
	var twice_area: float = absf((b - a).cross(c - a))
	if twice_area < 0.0001:
		return INF
	return (ab * bc * ca) / (2.0 * twice_area)

## Speed after one step at full throttle from `v`.
##
## Acceleration falls off as the square of speed, so it is evaluated at the
## start of the step rather than held constant across the lap. At STEP = 5 m the
## difference within one step is small enough to ignore.
static func _after_accelerating(v: float) -> float:
	var accel: float = LAUNCH_ACCEL * maxf(0.0, 1.0 - pow(v / TOP_SPEED, 2.0))
	return sqrt(v * v + 2.0 * accel * STEP)

## Speed one step *earlier* that still allows `v` to be reached under braking.
static func _before_braking(v: float) -> float:
	return sqrt(v * v + 2.0 * BRAKING_G * G * STEP)

## The centreline at a constant step, walked as the closed loop it is, plus the
## cornering speed limit at each of those steps. Returns `[points, limits]`.
##
## Distance is 3D, so a climb costs the time it really takes rather than being
## measured as if the lap were flat.
##
## ## Why the limit is computed before resampling, not after
##
## The centreline is a *polyline*: eight straight chords around a corner arc.
## Its vertices lie on the real geometry, but the segments between them cut
## inside it, so the shape has sharp corners at every vertex and is dead straight
## in between.
##
## Measuring curvature after resampling therefore measures the polygon rather
## than the road: a sample landing near a chord junction reads the join as a
## kink, and one landing mid-chord reads a corner as dead straight. The finer the
## resampling the worse it gets, which is the opposite of what more samples
## should do.
##
## So the limit is worked out at the source vertices, where the geometry is
## exact, and interpolated onto the fixed step along with the position. Worth
## about half a second a lap on Monte Carlo, which has the most corners to get
## wrong, and a tenth on Ardennes.
static func resample(centreline: Array[Vector3]) -> Array:
	var points: Array[Vector3] = []
	var limits := PackedFloat32Array()
	var n := centreline.size()
	if n < 3:
		return [points, limits]

	var caps := PackedFloat32Array()
	caps.resize(n)
	for i in n:
		caps[i] = minf(TOP_SPEED, _corner_speed(centreline, i))

	var carried := 0.0
	for i in n:
		var from := centreline[i]
		var to := centreline[(i + 1) % n]
		var span := from.distance_to(to)
		if span < 0.0001:
			continue
		var at := carried
		while at < span:
			var t := at / span
			points.append(from.lerp(to, t))
			limits.append(lerpf(caps[i], caps[(i + 1) % n], t))
			at += STEP
		carried = at - span
	return [points, limits]
