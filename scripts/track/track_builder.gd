class_name TrackBuilder
extends RefCounted

## Turns a layout spec into a complete, drivable circuit node.
##
## This is the single implementation of track construction, used from two
## places: `tools/build_track.gd` bakes the shipped circuits into committed
## `.tscn` files with it, and `race.gd` calls it at runtime to build a
## player-authored track that has no scene file. Custom tracks are therefore
## made of exactly the same geometry as the shipped ones, and the test suite
## only has one builder to cover.
##
## Axis convention: -Z North, +Z South, -X West, +X East. Kenney road tiles are
## authored on a 1-unit grid with off-centre origins; every piece is normalised
## so its cell min corner sits at the origin, then placed by matching its entry
## connection point and edge normal to the walker's current position/heading.
##
## Height: each connection carries a y (in tile units). A piece's rise is
## conn_y[exit] - conn_y[entry], so the same ramp mesh climbs or descends purely
## by which way it is entered, and the walker carries the running height.
##
## Collision does NOT come from the road meshes. A ribbon of quads is generated
## along the centreline and used as a ConcavePolygonShape3D: smooth, seamless
## for the raycast wheels, and it follows elevation. The flat ground plane
## underneath is only the grass.
##
## Banking: the centreline carries a roll angle per point as well as a position,
## and the ribbon's lateral offsets are rolled about the track tangent by it, so
## corners lean into the turn. The tile meshes are deformed to match — see
## `_reshape_tiles`. Bank rolls about the centreline, so the racing line's *height*
## is untouched and elevation still closes exactly.

# 1 tile unit -> this many metres. Sets road width, corner radii and lap length
# together, since Kenney has no wider road tiles. The car does not scale, so
# raising this widens the track relative to the car and opens up the corners.
const SCALE := 14.0
# Vertical scale, applied on top of SCALE. Kenney's ramp is 0.5 units over 2,
# a 25% grade - very steep for a circuit, and with no barriers a fall off an
# elevated section hurts. Halving it gives ~12% and a 3.5 m high plateau.
const VERT := 0.5
const ROAD_HALF := 0.5 * SCALE
# Collision ribbon reaches slightly past the painted road edge, so the very edge
# of the tarmac is still drivable rather than a cliff.
const RIBBON_HALF := 0.6 * SCALE

const BARRIERS_ENABLED := false
const BARRIER_PIECE := "railDouble"
const BARRIER_LENGTH_AXIS := "z"
const BARRIER_SCALE := 10.0
const BARRIER_STEP := 1.0 * BARRIER_SCALE
const WALL_GAP := 0.7 * SCALE
const WALL_H := 2.8
const WALL_T := 0.6
const ARC_STEPS := 8

## How finely straights are sampled into the centreline, in tile units.
##
## Used to be one point per tile — 14 m, or 28 m for the long tile. That is
## plenty for a flat straight, where two points describe it exactly, but bank
## transitions and the eased ramp profile are *curves* laid along the straight,
## and a curve sampled every 14 m is a set of facets the wheels can feel. At
## 0.2 units the ribbon carries a sample every 2.8 m, which keeps the roll change
## from one sample to the next under 2.5 degrees.
const TRACE_STEP := 0.2

## Extra samples across a ramp tile, on top of `TRACE_STEP`. The eased profile
## does most of its climbing in the middle third, so it wants resolving finer
## than a flat straight does: at 16 the gradient never changes by more than about
## 4% between samples, against the 25% cliff the flat wedge had at each end.
const RAMP_STEPS := 16

## Bank angle by level, in degrees. Level 0 is a flat corner, and is always
## available — banking is a choice per corner, not something every bend gets.
##
## The ceiling is set by what happens when you run wide, not by taste.
##
## A banked corner is an embankment, so the outside of the road stands above the
## grass around it by twice `BANK_FULL_HALF * tan(angle)` — and all of that has to
## be shed again over the 2.1 m of verge between the tarmac and the edge of the
## tile. At 6 degrees that is a metre of road edge and a 26 degree apron: a car
## drifting a hand's width wide drops off it, which measured as the car being
## thrown and is exactly what banking should not do. At 4 it is 0.69 m and 18
## degrees, which the suspension can follow.
##
## Measured, not guessed: launched along the road at 30 m/s from points all round
## the lap, banked corners average 0.7 airborne frames against 23 for the hills
## and 13 for plain flat road. On the road, banking is the most planted part of
## the circuit; it was only ever the edge that threw anything.
##
## NASCAR's 24 to 33 is out of reach without wider tiles to land the apron on.
const BANK_DEGREES: Array[float] = [0.0, 1.5, 2.5, 4.0]
const MAX_BANK_LEVEL := 3
const MAX_BANK_DEG := 4.0

## The level a corner gets when nothing has asked for anything.
##
## Flat. A corner banks because someone said so and for no other reason — there
## is no radius-derived default anywhere, in the editor or in a hand-written
## layout. Banking changes how a circuit drives, and inheriting it silently is
## not something a track author should have to notice and undo.
##
## Suggested angles, when someone does ask, run *up* with radius: a sweeper is the
## corner taken fastest, so it is where leaning the road actually buys grip, and
## it is the only one with enough road either side to ease the roll in and out of.
## A hairpin banked hard is a skate bowl — the tilt arrives in a car length and
## reads as a glitch rather than as a corner.
const DEFAULT_BANK_LEVEL := 0

## Road spent easing bank in and out at each end of a corner, in tile units.
##
## 1.5 units is 21 m, about three quarters of a second at racing speed, which
## puts the peak roll rate near 25 degrees a second — quick enough to feel like
## the road is taking the car, slow enough that the chase camera never snaps.
## Shorter reads as a flick; much longer and a short straight between two bends
## never gets back to flat.
const BANK_TRANSITION := 1.5

## Below this the roll is not worth deforming a mesh for, in radians. Roughly a
## tenth of a degree.
const BANK_EPSILON := 0.002

## The same threshold for the ramp-chain correction, in metres. A centimetre is
## well under what a wheel can find, and keeping it non-zero means the tiles of a
## single-tile level change — where the chain profile and the mesh's own are the
## same curve — go on sharing one imported mesh instead of each baking a copy.
const LIFT_EPSILON := 0.01

## How far the bank is carried across the road before it grades back to ground
## level, in metres either side of the centreline.
##
## The world outside the road is one flat plane 4 km across, and it cannot be
## banked to meet a banked corner. Tilting a whole tile bodily therefore puts its
## outer edge into the air as a grass cliff and its inner edge *under* the ground
## plane, where the grass clips straight through the road.
##
## So the corner is built the way a real banked one is: as an embankment. The
## inside edge stays at ground level, the road climbs across its width, and the
## outside grades back down to ground by the edge of the tile. Nothing ever sits
## below the grass, so nothing can clip through it, whatever the angle.
##
## `BANK_FULL_HALF` must cover the whole painted road, and that is not a
## preference — it is the difference between banking and a bump.
##
## It was 0.25 units (3.5 m) first, chosen to leave a long, gentle verge to shed
## the height on. But the tarmac reaches 0.345 units (4.83 m), so the two places
## where the cross-section changes gradient — the apex of the climb on one side,
## the start of the flat apron on the other — both landed *on the driving
## surface*. The result was a ridge running along the road at 3.5 m out and a kink
## at 3.5 m in, and the car hopped every time a wheel crossed one. It measured as
## a perfect 10 degree bank the whole time, because along the racing line it was.
##
## At 0.35 units the banked strip is one unbroken plane across the entire road and
## every gradient change is on grass. The price is a steeper apron, since the same
## height is shed over less verge, which is what caps the angle below.
const BANK_FULL_HALF := 0.35 * SCALE
const BANK_FADE_HALF := 0.5 * SCALE

## How far either side of each break in the cross-section the corner is rounded
## off, in metres.
##
## Without this the road meets its apron at a sharp convex crest, and a sharp
## convex crest throws the car *however slowly it is crossed*: the vertical
## acceleration a surface demands is its curvature times the square of the speed
## across it, and at a corner the curvature is infinite. Drifting a wheel a
## hand's width off the tarmac was enough to launch the car, which is not what
## banking is supposed to do to anyone.
##
## Rounded over 0.7 m either side, the crest has a radius of a couple of metres.
## What crosses it is the car's *lateral* drift, not its speed down the road, so
## a couple of metres is enough: at 3 m/s sideways it asks for well under a g and
## the wheels stay down.
const BANK_FILLET := 0.05 * SCALE

# Lap checkpoints. Index 0 sits on the start line; a lap only counts if all of
# them are crossed in order.
const CHECKPOINT_COUNT := 16
const CHECKPOINT_W := 4.0 * SCALE
const CHECKPOINT_H := 12.0  # tall enough to still catch the car on a slope
const CHECKPOINT_T := 4.0

## Where the pole slot sits, in tile units: how far along `roadStartPositions`,
## and how far to the driver's right of the centreline.
##
## Read off the art. The tile paints four slots alternating sides, at 0.077..0.423,
## 0.577..0.923, 1.077..1.423 and 1.577..1.923 along it, across a cell whose road
## runs 0.155..0.845. Driven as `PIECES` lays it — in through S — the slots march
## towards the exit, the last of them spanning x 0.224..0.431. So pole is 1.75
## along and 0.1725 to the driver's right of the middle of the road.
##
## Which is also what says the grid tile belongs before the line rather than
## after it: the slots lead up to the tile's exit, and the exit is where
## `roadStart` joins.
const GRID_POLE_ALONG := 1.75
const GRID_POLE_ACROSS := 0.1725

## Where the start/finish line sits along the layout, in tile units.
##
## Not zero, which is the trap, and no longer under 1 either.
##
## The walker starts at the *leading edge* of the first tile of the start run,
## and that tile is `roadStartPositions`, 2 units of grid slots. The line itself
## is on the `roadStart` tile behind it, which is another 2 units long and carries
## the line across the middle of itself: the painted stripe spans z 0.905..0.954
## of that tile and the gantry straddles it at 0.905..1.095. Timing from arc 0
## therefore started and stopped the clock most of 40 m before the car reached
## anything the player can see.
##
## The fractional part is the midpoint of that whole assembly, so the trigger is
## within half a metre of both the stripe and the middle of the arch rather than
## exact on one and a metre out on the other.
const START_LINE_ALONG := 2.0 + 0.96
const START_LINE_ARC := START_LINE_ALONG * SCALE

const DIRS := {
	"N": Vector2(0, -1), "S": Vector2(0, 1),
	"E": Vector2(1, 0), "W": Vector2(-1, 0),
}

## Deck height of the bridge corner pieces, in tile units, measured from the art:
## their road surface tops out at local y 0.117 and every Kenney glb carries its
## mesh 0.01 low, so the deck sits 0.107 above the piece origin.
##
## Not 0.5 like `roadStraightBridge`, which is a full bridge with supports down to
## the ground; the bridge corners are deck-only sections meant to be carried at
## height. Getting this wrong does not fail loudly — the corner simply sits a few
## metres proud of the straights it joins.
const BRIDGE_CORNER_DECK := 0.107

# name -> cell size, origin shift, connection points in normalised cell coords,
# connection heights in tile units, and for corners the arc centre. An `entry`
# names the connection the piece must be driven in through, for art that is not
# symmetric end to end.
const PIECES := {
	"roadStart": {
		"cell": Vector2(1.26, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.63, 0.0), "S": Vector2(0.63, 2.0)},
	},
	## Laid backwards on purpose — driven in through S and out through N, which
	## is a 180-degree turn of the art within the same two cells.
	##
	## Each slot is painted as a U: a bar closing one end and a strip down either
	## side, open at the other end. The car noses in through the open end and
	## stops at the bar, so the bar has to be the *forward* edge. As the tile is
	## authored the bar is at the low-z end and the opening faces high z, which is
	## the way the walker drives it — every box open behind the car and barred
	## across its nose, a grid you reverse into.
	##
	## The tile survives being turned round because everything else on it is
	## symmetric about the cell centre: the road, both kerbs and both verges map
	## onto themselves, and the four slots map onto each other's places (they
	## alternate sides, so mirroring across and along together lands each one
	## where another was). Only the U's opening changes hand, which is the point.
	"roadStartPositions": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
		"entry": "S",
	},
	"roadStraightLong": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
	},
	"roadStraight": {
		"cell": Vector2(1.0, 1.0), "shift": Vector2(0.35, 1.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 1.0)},
	},
	# Climbs 0.5 units over its 2 units of length, as a flat wedge: 8 vertices,
	# so the grade arrives and leaves at a hard crease. Kept because it is a
	# valid piece, but nothing emits it any more — see `roadRampLongCurved`.
	"roadRampLong": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
		"conn_y": {"N": 0.5, "S": 0.0},
	},
	# Same rise, same footprint, same connections — but the surface eases into
	# the grade and out of it instead of breaking into it, so a crest is a crest
	# rather than a ridge. `RAMP_PROFILE` reproduces its shape for collision.
	"roadRampLongCurved": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
		"conn_y": {"N": 0.5, "S": 0.0},
		"eased": true,
	},
	# Flat, but sits at ramp-top height.
	"roadStraightBridge": {
		"cell": Vector2(1.0, 1.0), "shift": Vector2(0.35, 1.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 1.0)},
		"conn_y": {"N": 0.5, "S": 0.5},
	},
	# The arc centre is the *outer* corner of the block, not the point where the
	# two centre lines cross. Both give a quarter circle through the same two
	# connection points — they are mirror images across the chord — but only this
	# one leaves the arc tangent to the straights it joins. Centred on the
	# crossing point instead, the road turns the wrong way out of each end and
	# the centreline cuts across the inside of the bend.
	"roadCornerSmall": {
		"cell": Vector2(1.0, 1.0), "shift": Vector2(0.35, 1.65),
		"conns": {"E": Vector2(1.0, 0.5), "S": Vector2(0.5, 1.0)},
		"arc": Vector2(1.0, 1.0),
	},
	"roadCornerLarge": {
		"cell": Vector2(2.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"E": Vector2(2.0, 0.5), "S": Vector2(0.5, 2.0)},
		"arc": Vector2(2.0, 2.0),
	},
	"roadCornerLarger": {
		"cell": Vector2(3.0, 3.0), "shift": Vector2(0.35, 3.65),
		"conns": {"E": Vector2(3.0, 0.5), "S": Vector2(0.5, 3.0)},
		"arc": Vector2(3.0, 3.0),
	},
	# Corners that hold their height, so an elevated section can carry on round a
	# bend instead of having to come back down for it. Same footprint and arc as
	# the flat corners; only the deck height differs.
	"roadCornerBridgeSmall": {
		"cell": Vector2(1.0, 1.0), "shift": Vector2(0.35, 1.65),
		"conns": {"E": Vector2(1.0, 0.5), "S": Vector2(0.5, 1.0)},
		"conn_y": {"E": BRIDGE_CORNER_DECK, "S": BRIDGE_CORNER_DECK},
		"arc": Vector2(1.0, 1.0),
	},
	"roadCornerBridgeLarge": {
		"cell": Vector2(2.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"E": Vector2(2.0, 0.5), "S": Vector2(0.5, 2.0)},
		"conn_y": {"E": BRIDGE_CORNER_DECK, "S": BRIDGE_CORNER_DECK},
		"arc": Vector2(2.0, 2.0),
	},
	"roadCornerBridgeLarger": {
		"cell": Vector2(3.0, 3.0), "shift": Vector2(0.35, 3.65),
		"conns": {"E": Vector2(3.0, 0.5), "S": Vector2(0.5, 3.0)},
		"conn_y": {"E": BRIDGE_CORNER_DECK, "S": BRIDGE_CORNER_DECK},
		"arc": Vector2(3.0, 3.0),
	},
}

## Everything the caller could want to know about a build: the node itself, and
## whether the loop actually joined up.
##
## The tool turns `closed` into a non-zero exit code so a broken circuit cannot
## be committed; the editor turns the same numbers into a live readout so the
## player can see *how far* off closing they are while painting.
class BuildResult extends RefCounted:
	var root: Node3D
	var closed: bool
	var gap: Vector2          # tile units still between the end and the start
	var height_gap: float     # tile units of unreturned elevation
	var turn_total: int       # net quarter-turns; +/-4 for a single clean loop
	var length: float         # lap distance in metres
	var peak: float           # highest point in metres
	var triangles: int        # collision ribbon size
	var gate_spacing: float   # metres between checkpoints

	func summary() -> String:
		return "gap = (%.2f, %.2f) height %.2f | net turns %d | %s" % [
			gap.x, gap.y, height_gap, turn_total,
			"CLOSED" if closed else "*** DOES NOT CLOSE ***"
		]

var centreline: Array[Vector3] = []
## Roll angle at each centreline point, in radians, positive where the road
## leans into a left-hand turn. Always the same length as `centreline`.
var bank := PackedFloat32Array()

var _triangles := 0
var _gate_spacing := 0.0
## One entry per placed tile: its node, and the centreline index range it spans.
## Filled during the walk and consumed by `_reshape_tiles`, which cannot run until
## the whole loop is known — a corner's bank reaches back into the straight
## before it, which has already been placed by the time the corner is reached.
var _placed: Array = []
## Centreline index ranges that sit inside a corner arc, with the bank that
## corner asks for. Turned into a continuous profile by `_build_bank_profile`.
var _corner_spans: Array = []
## The road's lateral direction at each centreline point; see `_side_vectors`.
var _sides: Array[Vector3] = []
## How far, in world units, the centreline at each point sits above the surface
## the tile mesh under it actually has. Zero everywhere except inside a ramp
## chain of more than one tile, where the profile spans the whole chain but each
## mesh still carries its own — see `_trace_straight`. Always the same length as
## `centreline`; `_frame_at` hands it to the tile reshaper so the visible road
## and the collision ribbon stay the same surface.
var _ramp_lift := PackedFloat32Array()

## Layout grammar:
##   ["S", piece, repeat]              straight run
##   ["S", piece, repeat, rise_sign]   ramp; +1 climbs, -1 descends, same mesh
##   ["C", piece, "left"|"right"]      corner, banked to suit its radius
##   ["C", piece, turn, bank_degrees]  corner banked by an explicit amount; 0 is
##                                     flat, and is not the same as saying nothing
##
## A layout only makes a circuit if it closes: gap (0, 0), net turns +/-4, and
## height back to 0. Callers must check `BuildResult.closed` — the builder still
## returns geometry for a broken layout so the editor can draw it.
##
## With `with_geometry` false nothing is instanced and `result.root` is null;
## see `measure()`.
func build(track_name: String, layout: Array, with_geometry := true) -> BuildResult:
	centreline = []
	bank = PackedFloat32Array()
	_triangles = 0
	_gate_spacing = 0.0
	_placed = []
	_corner_spans = []
	_sides = []
	_ramp_lift = PackedFloat32Array()

	var root_node: Node3D = null
	var roads: Node3D = null
	if with_geometry:
		root_node = Node3D.new()
		root_node.name = "Track_%s" % track_name
		roads = Node3D.new()
		roads.name = "RoadVisuals"
		roads.scale = Vector3(SCALE, SCALE * VERT, SCALE)
		root_node.add_child(roads)

	var pos := Vector2.ZERO
	var heading := DIRS["S"]
	var height := 0.0
	var turn_total := 0
	var peak := 0.0

	for seg in layout:
		var kind: String = seg[0]
		var piece: String = seg[1]
		if kind == "S":
			var rise_sign: int = seg[3] if seg.size() > 3 else 0
			var count := int(seg[2])
			# A level change of N is N ramp tiles in a row, and each mesh eases in
			# *and* out of its own two cells. Traced one at a time that is N humps,
			# not one hill: the gradient returns to zero at every tile seam, so a
			# 0-to-3 climb pitches the car three times on the way up. The chain is
			# therefore given a single profile spanning all N tiles. Peak gradient
			# is unchanged — an eased ramp's steepest point is a fixed multiple of
			# its average, and stretching rise and length together leaves that
			# alone — so this only removes the undulation.
			var chain := {}
			if rise_sign != 0 and count > 1:
				chain = {
					"base": height,
					"rise": _tile_rise(piece) * rise_sign * count,
					"count": count,
				}
			for i in count:
				var r := _place(roads, piece, pos, heading, heading, height, rise_sign)
				var from_idx := _mark()
				if not chain.is_empty():
					chain["index"] = i
				_trace_straight(piece, r[2], height, r[0], r[5], chain)
				_record(r[6], from_idx)
				pos = r[0]
				height = r[5]
				peak = maxf(peak, height)
		else:
			var turn: String = seg[2]
			var new_heading := _rotate(heading, 90.0 if turn == "left" else -90.0)
			turn_total += (1 if turn == "left" else -1)
			var r := _place(roads, piece, pos, heading, new_heading, height, 0)
			var from_idx := _mark()
			_trace_arc(piece, r[3], r[4], r[2], r[0], height)
			_record(r[6], from_idx)
			# A fourth element is a bank in degrees. Without one the corner is
			# flat, so "said nothing" and "said zero" now mean the same thing,
			# and neither can quietly bank a circuit nobody asked to bank.
			_note_corner(piece, turn, from_idx,
				float(seg[3]) if seg.size() > 3 else 0.0)
			pos = r[0]
			height = r[5]
			heading = new_heading

	_build_bank_profile()

	var total := 0.0
	for i in centreline.size() - 1:
		total += centreline[i].distance_to(centreline[i + 1])

	if with_geometry:
		# After the whole loop, because a corner's bank reaches back into the
		# straight before it and forward into the one after.
		_reshape_tiles()
		if BARRIERS_ENABLED:
			_build_walls(root_node)
		_build_road_collision(root_node)
		_build_checkpoints(root_node)
		_build_ground(root_node)
		_build_lighting(root_node)

		# In the pole slot, which is behind the line rather than past it: the
		# timer starts a second or two in instead of after a full out lap, and
		# the car starts on the one painted box that is drawn for it. Measured
		# from arc zero — the leading edge of the grid tile — rather than back
		# from the line, so it stays in the box the art puts there.
		var grid := _point_at_arc(GRID_POLE_ALONG * SCALE)
		var spawn := Marker3D.new()
		spawn.name = "SpawnPoint"
		# The car model faces local +Z, so align +Z with the track tangent.
		var tan: Vector2 = grid[1]
		# Driver's right for a Y-up right-handed basis is cross(forward, up),
		# which for a tangent (x, z) is (-z, x).
		var across := Vector3(-tan.y, 0.0, tan.x) * (GRID_POLE_ACROSS * SCALE)
		spawn.position = (grid[0] as Vector3) + across + Vector3(0.0, 1.0, 0.0)
		spawn.rotation.y = atan2(tan.x, tan.y)
		root_node.add_child(spawn)

	var result := BuildResult.new()
	result.root = root_node
	result.gap = pos
	result.height_gap = height
	result.turn_total = turn_total
	result.length = total
	result.peak = peak * SCALE * VERT
	result.triangles = _triangles
	result.gate_spacing = _gate_spacing
	result.closed = (
		is_zero_approx(pos.x) and is_zero_approx(pos.y) and is_zero_approx(height)
		and absi(turn_total) == 4
	)
	return result

## Walks a layout without building anything, filling `centreline` and returning
## the same closure and length figures as a real build. The editor recompiles on
## every mouse move and the menu measures every custom track it lists, so both
## need the numbers without paying for the tiles.
func measure(layout: Array) -> BuildResult:
	return build("measure", layout, false)

# Returns [exit_pos, exit_heading, entry_pos, origin, theta, exit_height, holder]
func _place(
	parent: Node3D, piece: String, pos: Vector2, heading: Vector2,
	want_heading: Vector2, height: float, rise_sign: int
) -> Array:
	var desc: Dictionary = PIECES[piece]
	var conns: Dictionary = desc["conns"]
	var conn_y: Dictionary = desc.get("conn_y", {})
	var keys: Array = conns.keys()
	# A piece whose art is not symmetric end to end says which way it is driven.
	# Without one, the first rotation that fits wins, and for a straight piece
	# that is always the untuned one — the search would never turn a tile round
	# on its own however wrong the result looked.
	var entry: String = desc.get("entry", "")

	for theta in [0.0, 90.0, 180.0, 270.0]:
		for a in keys:
			if entry != "" and a != entry:
				continue
			for b in keys:
				if a == b:
					continue
				if not _rotate(DIRS[a], theta).is_equal_approx(-heading):
					continue
				if not _rotate(DIRS[b], theta).is_equal_approx(want_heading):
					continue

				var y_in: float = conn_y.get(a, 0.0)
				var y_out: float = conn_y.get(b, 0.0)
				var rise := y_out - y_in
				# A ramp mesh climbs or descends depending only on which end is
				# entered, so the caller says which it wanted.
				if rise_sign > 0 and rise <= 0.0:
					continue
				if rise_sign < 0 and rise >= 0.0:
					continue

				var entry_local: Vector2 = conns[a]
				var exit_local: Vector2 = conns[b]
				var origin := pos - _rotate(entry_local, theta)
				var exit_pos := origin + _rotate(exit_local, theta)

				# No parent means a measuring walk: the arithmetic is all that is
				# wanted, and instancing a few hundred GLB tiles is by far the
				# most expensive thing the builder does.
				var holder: Node3D = null
				if parent != null:
					holder = Node3D.new()
					# Lift the piece so its entry connection meets the running height.
					holder.position = Vector3(origin.x, height - y_in, origin.y)
					holder.rotation.y = deg_to_rad(theta)
					parent.add_child(holder)

					var inst: Node3D = load(
						"res://assets/kenney/racing_kit/%s.glb" % piece
					).instantiate()
					var shift: Vector2 = desc["shift"]
					inst.position = Vector3(shift.x, 0.0, shift.y)
					holder.add_child(inst)

				return [exit_pos, want_heading, pos, origin, theta, height + rise, holder]

	push_error("no placement for %s heading %s -> %s rise_sign %d" % [
		piece, heading, want_heading, rise_sign
	])
	return [pos, heading, pos, Vector2.ZERO, 0.0, height, null]

func _rotate(v: Vector2, deg: float) -> Vector2:
	var a := deg_to_rad(deg)
	var c := cos(a)
	var s := sin(a)
	# Matches Godot's Y-rotation acting on (x, z).
	return Vector2(v.x * c + v.y * s, -v.x * s + v.y * c)

func _world(p: Vector2, h: float) -> Vector3:
	return Vector3(p.x * SCALE, h * SCALE * VERT, p.y * SCALE)

## The index the next traced point will extend from, so a tile can be given the
## span it occupies. Zero on the first piece, whose entry point does not exist
## yet — the tracer appends it.
func _mark() -> int:
	return maxi(centreline.size() - 1, 0)

func _record(holder: Node3D, from_idx: int) -> void:
	if holder == null:
		return
	_placed.append({"holder": holder, "from": from_idx, "to": centreline.size() - 1})

## Height of the eased ramp's surface a fraction `t` of the way along it, as a
## fraction of its total rise.
##
## This is `roadRampLongCurved`'s own profile, recovered from the mesh: it is
## smootherstep, matching the art to under a centimetre at every one of its 25
## rows of vertices. It is reproduced here rather than sampled from the GLB
## because `measure()` traces the centreline without loading a single mesh, and
## the editor measures on every mouse move.
##
## The point of it is that the derivative is zero at both ends, so the ramp
## meets the flat road it joins at a matched gradient. The plain `roadRampLong`
## wedge meets it at 25%, and that step in gradient is a bump the wheels find
## even though nothing about the road looks raised.
static func _ease(t: float) -> float:
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)

## The height one tile of `piece` gains, read from its own connection heights so
## the chain arithmetic in `build` cannot drift from the art.
func _tile_rise(piece: String) -> float:
	var conn_y: Dictionary = PIECES.get(piece, {}).get("conn_y", {})
	var lo := INF
	var hi := -INF
	for key in conn_y:
		lo = minf(lo, conn_y[key])
		hi = maxf(hi, conn_y[key])
	return 0.0 if lo > hi else hi - lo

## Samples a straight into the centreline. Flat straights only need their two
## ends, but bank transitions and ramp profiles are curves drawn along the
## straight, so it is subdivided finely enough to carry them.
##
## `chain` is set for a tile that is one of several ramps making a single level
## change. It carries the chain's `base` height, total `rise`, tile `count` and
## this tile's `index`, and makes the profile here a slice of one ease across the
## whole chain rather than a complete ease across this tile. `from_h` and `to_h`
## still describe the mesh, which keeps its own shape and its own placement; the
## difference between the two profiles is recorded in `_ramp_lift` and applied to
## the tile's vertices later, so the road the player sees is the road the ribbon
## is built from.
func _trace_straight(
	piece: String, from: Vector2, from_h: float, to: Vector2, to_h: float,
	chain: Dictionary = {}
) -> void:
	if centreline.is_empty():
		centreline.append(_world(from, from_h))
		_ramp_lift.append(0.0)

	var eased: bool = PIECES.get(piece, {}).get("eased", false)
	var steps := maxi(1, int(ceil(from.distance_to(to) / TRACE_STEP)))
	if eased:
		steps = maxi(steps, RAMP_STEPS)
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var tile_h := lerpf(from_h, to_h, _ease(t) if eased else t)
		var h := tile_h
		if not chain.is_empty():
			var u := (float(chain["index"]) + t) / float(chain["count"])
			h = float(chain["base"]) + float(chain["rise"]) * _ease(u)
		centreline.append(_world(from.lerp(to, t), h))
		# In world units, because that is where the vertices it corrects live.
		_ramp_lift.append((h - tile_h) * SCALE * VERT)

func _trace_arc(
	piece: String, origin: Vector2, theta: float, from: Vector2, to: Vector2, h: float
) -> void:
	var desc: Dictionary = PIECES[piece]
	if not desc.has("arc"):
		_trace_straight(piece, from, h, to, h)
		return
	if centreline.is_empty():
		centreline.append(_world(from, h))
		_ramp_lift.append(0.0)

	var centre := origin + _rotate(desc["arc"], theta)
	var v0 := from - centre
	var v1 := to - centre
	var a0 := atan2(v0.y, v0.x)
	var a1 := atan2(v1.y, v1.x)
	var radius := v0.length()
	# Take the short way round; a tile corner is always a quarter turn.
	var delta := wrapf(a1 - a0, -PI, PI)
	for i in range(1, ARC_STEPS + 1):
		var a: float = a0 + delta * (float(i) / ARC_STEPS)
		centreline.append(_world(centre + Vector2(cos(a), sin(a)) * radius, h))
		# Corner tiles are flat end to end, so they are never part of a chain.
		_ramp_lift.append(0.0)

# --- banking ---

## Records that the arc just traced wants banking, and how much.
##
## `degrees` comes from the layout when it says, and from the corner's own radius
## when it does not: a size-N corner is an NxN block, so `arc` is (N, N) and N
## picks the default level. That also means the bridge corners default the same
## way as the flat ones, which is what you want — an elevated sweeper is exactly
## where you least want the road to go level.
func _note_corner(piece: String, turn: String, from_idx: int, degrees: float) -> void:
	if is_zero_approx(degrees):
		return
	# Positive rolls the outside of a left-hander up; a right-hander is its
	# mirror, so it simply carries the opposite sign all the way through.
	var sign := 1.0 if turn == "left" else -1.0
	_corner_spans.append({
		"from": from_idx,
		"to": centreline.size() - 1,
		"bank": deg_to_rad(clampf(degrees, -MAX_BANK_DEG, MAX_BANK_DEG)) * sign,
	})

## Turns the per-corner requests into a roll angle for every centreline point.
##
## Each corner holds its full bank across its own arc and eases to nothing over
## `BANK_TRANSITION` of road at each end, and the contributions are *summed*.
## Summing is what makes an S-bend work: a left immediately followed by a right
## has overlapping transitions of opposite sign, which cancel through the middle,
## so the road rolls from one way to the other through flat exactly where the car
## changes hands. Taking the strongest instead would hold one corner's bank right
## up to the other's and put a step between them.
##
## Two corners the same way round that close together do reinforce, which is why
## the total is clamped.
func _build_bank_profile() -> void:
	bank.resize(centreline.size())
	bank.fill(0.0)
	_sides = _side_vectors()
	if _corner_spans.is_empty() or centreline.size() < 2:
		return

	# Arc length at each point, and the loop's total, so transitions can be
	# measured in metres of road rather than in points — the sampling is not
	# uniform, and an arc step is a third of a straight's step.
	var arc := PackedFloat32Array()
	arc.resize(centreline.size())
	arc[0] = 0.0
	for i in range(1, centreline.size()):
		arc[i] = arc[i - 1] + centreline[i - 1].distance_to(centreline[i])
	var total: float = arc[arc.size() - 1]
	if total <= 0.0:
		return

	var transition := BANK_TRANSITION * SCALE
	var limit := deg_to_rad(MAX_BANK_DEG)
	for span in _corner_spans:
		var a: float = arc[span["from"]]
		var b: float = arc[span["to"]]
		var amount: float = span["bank"]
		for i in centreline.size():
			var d := _arc_distance_outside(arc[i], a, b, total)
			if d >= transition:
				continue
			bank[i] += amount * _ease(1.0 - d / transition)
	for i in bank.size():
		bank[i] = clampf(bank[i], -limit, limit)

	# Ride the centreline up onto the embankment, so it goes on describing the
	# middle of the road. Height still closes: bank is zero at the start line, so
	# the lift is zero there too, and the walker's own running height — which is
	# what closure is measured from — is not touched at all.
	for i in centreline.size():
		centreline[i].y += _bank_lift(bank[i])

## How far a point is from the span [a, b], measured the short way round the
## loop; zero inside it.
##
## Wrapping matters: the corner before the start line has its exit transition
## running off the end of the centreline and onto the beginning, and without the
## wrap that corner alone would snap flat at the start/finish line.
static func _arc_distance_outside(s: float, a: float, b: float, total: float) -> float:
	var from_a := fposmod(s - a, total)
	var span := fposmod(b - a, total)
	if from_a <= span:
		return 0.0
	return minf(from_a - span, total - from_a)

## The centreline's lateral direction at each point — the car's right — averaged
## across the two segments meeting there.
##
## Averaging is the point. Taking each quad's own perpendicular leaves the two
## quads at a shared point disagreeing by the turn between them, which on an arc
## step is over a metre of overlap at the ribbon's edge. Flat, that is invisible;
## banked, the two quads also disagree about which way is up, and the seam
## becomes a step the wheels drop off.
func _side_vectors() -> Array[Vector3]:
	var sides: Array[Vector3] = []
	sides.resize(centreline.size())
	var dirs: Array[Vector2] = []
	for i in centreline.size() - 1:
		var d := centreline[i + 1] - centreline[i]
		var flat := Vector2(d.x, d.z)
		dirs.append(flat.normalized() if flat.length() > 0.001 else Vector2.ZERO)
	for i in centreline.size():
		var before: Vector2 = dirs[i - 1] if i > 0 else dirs[dirs.size() - 1]
		var after: Vector2 = dirs[i] if i < dirs.size() else dirs[dirs.size() - 1]
		var avg := before + after
		if avg.length() < 0.001:
			avg = after if after != Vector2.ZERO else before
		avg = avg.normalized()
		sides[i] = Vector3(-avg.y, 0.0, avg.x)
	return sides

## How far the middle of a banked road stands above the ground it is built on.
##
## The embankment rises from its inside edge, so the centre of the road ends up
## half the total climb above ground level. `_build_bank_profile` adds this to the
## centreline itself, which keeps "the centreline is the middle of the road" true
## for the things that rely on it — where the grid sits, where the timing gates
## hang — through a banked corner as much as through a flat one.
static func _bank_lift(roll: float) -> float:
	return absf(tan(roll)) * BANK_FULL_HALF

## The road's cross-section: how far the surface sits above the centreline at a
## lateral offset of `lateral` metres, under a roll of `roll` radians.
##
## Purely vertical — the point does not move sideways. A rigid roll would also
## pull it inwards by cos(roll), which at 10 degrees is 1.5% of the road's width
## for no visible gain, and it would leave the deformation unable to reproduce a
## point exactly where the bank is zero. Vertical-only is exact there, which is
## what lets a tile that is banked at one end and flat at the other stay welded to
## the tiles either side of it.
##
## Shape, from the inside of the corner outwards: flat apron at ground level, a
## straight climb across the whole width of the road, then a straight grade back
## down to ground by the edge of the tile — with every join between those rounded
## off over `BANK_FILLET`.
##
## The straights are straight rather than eased because an eased grade peaks at
## nearly twice its average slope, and it is the peak that decides whether a car
## running wide is turned back or thrown. The rounding is what stops the joins
## between them doing the throwing instead.
static func _bank_rise(lateral: float, roll: float) -> float:
	if is_zero_approx(roll):
		return 0.0
	var climb := absf(tan(roll))
	var lift := climb * BANK_FULL_HALF
	# Measured towards the high side, so one set of cases covers both hands.
	var out := lateral * signf(roll)

	var ground := -lift
	var road := climb * out
	var apron := (
		climb * 2.0 * BANK_FULL_HALF
		* (BANK_FADE_HALF - out) / (BANK_FADE_HALF - BANK_FULL_HALF)
		- lift
	)

	if out < -BANK_FULL_HALF - BANK_FILLET:
		return ground
	if out < -BANK_FULL_HALF + BANK_FILLET:
		return lerpf(ground, road, _bank_blend(out, -BANK_FULL_HALF))
	if out < BANK_FULL_HALF - BANK_FILLET:
		return road
	if out < BANK_FULL_HALF + BANK_FILLET:
		return lerpf(road, apron, _bank_blend(out, BANK_FULL_HALF))
	if out < BANK_FADE_HALF - BANK_FILLET:
		return apron
	if out < BANK_FADE_HALF + BANK_FILLET:
		return lerpf(apron, ground, _bank_blend(out, BANK_FADE_HALF))
	return ground

## Rounds one join. Zero slope at both ends of the window, so the blended curve
## leaves each straight at exactly the straight's own gradient and the profile has
## no corner left in it anywhere.
static func _bank_blend(out: float, at: float) -> float:
	return smoothstep(-1.0, 1.0, (out - at) / BANK_FILLET)

## The same cross-section's gradient, for turning normals with the surface.
##
## Differentiated numerically rather than by hand. The rounded profile has six
## cases and the normals have to agree with the shape exactly — a hand-derived
## twin would be one more thing to keep in step, for a saving of nothing that
## matters at build time.
static func _bank_slope(lateral: float, roll: float) -> float:
	const STEP := 0.05
	return (
		_bank_rise(lateral + STEP, roll) - _bank_rise(lateral - STEP, roll)
	) / (2.0 * STEP)

## A point on the driving surface: `lateral` metres to the side of a centreline
## point, lifted by the bank's cross-section there.
static func _ribbon_point(
	at: Vector3, side: Vector3, roll: float, lateral: float
) -> Vector3:
	return at + side * lateral + Vector3.UP * _bank_rise(lateral, roll)

## Lateral offsets at which the collision ribbon is sampled across its width.
##
## The straight parts of the cross-section need a cut only at each end, because a
## strip reproduces a straight exactly. The rounded joins have to be sampled
## *through*, and the join between the road and its apron gets the most: it is
## the convex one, so it is the only place where the corners left between samples
## can still throw the car. Sampling it coarsely would just replace one sharp
## crest with a handful of smaller ones.
##
## A single quad edge to edge, which is what this used to be, would interpolate
## straight across the whole cross-section and give the car a flat road under a
## banked one.
static func _ribbon_cuts() -> Array[float]:
	var cuts: Array[float] = [-RIBBON_HALF, 0.0, RIBBON_HALF]
	for side in [-1.0, 1.0]:
		# Three samples through each rounded join is enough to keep the shape
		# without the ribbon getting expensive: it is a static shape, but it is
		# also serialised into the committed scene files, and finer sampling was
		# measured to buy nothing at all — nine samples across the crest left the
		# car exactly as planted as three.
		for k in range(-1, 2):
			cuts.append(side * (BANK_FULL_HALF + BANK_FILLET * k))
			cuts.append(side * (BANK_FADE_HALF + BANK_FILLET * k))
	cuts.sort()

	var out: Array[float] = []
	for c in cuts:
		if c < -RIBBON_HALF or c > RIBBON_HALF:
			continue
		if out.is_empty() or c - out[out.size() - 1] > 0.001:
			out.append(c)
	return out

## Rebuilds the tiles that sit on banked road so the art agrees with what the
## wheels are driving on.
##
## There is no banked corner in the Kenney kit, and there is no rigid rotation
## that would make one: a corner held at a constant bank is a slice of a cone,
## so the roll has to be applied per vertex, about the arc, not to the tile as a
## whole. Rolling the tile bodily instead leaves its two ends tilted across the
## straights they join, which shows up as a step at every corner entry.
##
## So each affected tile's mesh is rebuilt vertex by vertex. The Kenney art is
## kept exactly — same surfaces, same materials, same kerbs and markings — and
## only the shape changes. Everything on the tile rolls, the verge included,
## which is what makes the road read as banked rather than as a flat road with a
## tilted stripe on it.
##
## Tiles on flat road are left alone, so they keep sharing one imported mesh;
## only corners and the road either side of them pay for a unique one.
## Two things send a tile through the reshaper, and they use the same machinery:
## a corner that is banked, and a ramp inside a chain whose grade is the chain's
## rather than its own. Both are a per-vertex vertical correction against the
## centreline; see `_roll_point`.
func _reshape_tiles() -> void:
	for entry in _placed:
		# A segment of margin at each end, so a vertex on the seam between two
		# tiles projects onto the same centreline segment whichever tile it
		# belongs to, and the two stay welded instead of tearing open.
		var lo: int = maxi(int(entry["from"]) - 1, 0)
		var hi: int = mini(int(entry["to"]) + 1, centreline.size() - 1)
		if not _span_is_banked(lo, hi) and not _span_is_lifted(lo, hi):
			continue
		_reshape_tile(entry["holder"], lo, hi)

func _span_is_banked(lo: int, hi: int) -> bool:
	for i in range(lo, hi + 1):
		if absf(bank[i]) > BANK_EPSILON:
			return true
	return false

func _span_is_lifted(lo: int, hi: int) -> bool:
	for i in range(lo, hi + 1):
		if absf(_ramp_lift[i]) > LIFT_EPSILON:
			return true
	return false

## Swaps a tile's imported scene for a single `MeshInstance3D` carrying a baked,
## banked copy of its geometry.
##
## Replacing the instance rather than overriding the mesh inside it is
## deliberate. A property written onto a node *inside* an instanced sub-scene is
## the same mechanism that has already shipped a car with eight wheels here, and
## it would leave the shipped `.tscn` files depending on override behaviour for
## something as load-bearing as the shape of the road. A node this builder owns
## outright packs and reloads with no such subtlety.
##
## The replacement keeps the holder's "one mesh per piece" shape and sits at
## identity, with its vertices baked into holder space.
func _reshape_tile(holder: Node3D, lo: int, hi: int) -> void:
	var holder_to_track := (holder.get_parent() as Node3D).transform * holder.transform
	var track_to_holder := holder_to_track.affine_inverse()

	var sources: Array = []
	for mi in _mesh_instances(holder):
		if mi.mesh != null:
			sources.append([mi.mesh, holder_to_track * _relative_transform(mi, holder)])
	if sources.is_empty():
		return

	for child in holder.get_children():
		holder.remove_child(child)
		child.free()

	for src in sources:
		var mi := MeshInstance3D.new()
		mi.mesh = _reshaped_mesh(
			src[0], src[1], holder_to_track, track_to_holder, lo, hi
		)
		holder.add_child(mi)

## A copy of `src` with every vertex rolled about the centreline, expressed in
## the holder's own space.
func _reshaped_mesh(
	src: Mesh, local_to_track: Transform3D, holder_to_track: Transform3D,
	track_to_holder: Transform3D, lo: int, hi: int
) -> ArrayMesh:
	# Normals do not transform like positions under a non-uniform scale, and
	# `RoadVisuals` carries one — VERT squashes y to half. The inverse transpose
	# is what keeps them perpendicular to the surface through that squash.
	var normals_to_track := local_to_track.basis.inverse().transposed()
	var normals_from_track := holder_to_track.basis.transposed()

	var out := ArrayMesh.new()
	for s in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var has_normals := normals != null and normals.size() == verts.size()

		var new_verts := PackedVector3Array()
		new_verts.resize(verts.size())
		var new_normals := PackedVector3Array()
		if has_normals:
			new_normals.resize(verts.size())

		for i in verts.size():
			var at := local_to_track * verts[i]
			var frame := _frame_at(at, lo, hi)
			if frame.is_empty():
				new_verts[i] = track_to_holder * at
				if has_normals:
					new_normals[i] = normals[i]
				continue
			new_verts[i] = track_to_holder * _roll_point(at, frame)
			if has_normals:
				new_normals[i] = (
					normals_from_track * _roll_direction(
						(normals_to_track * normals[i]).normalized(), frame
					)
				).normalized()

		arrays[Mesh.ARRAY_VERTEX] = new_verts
		if has_normals:
			arrays[Mesh.ARRAY_NORMAL] = new_normals
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(s, src.surface_get_material(s))
	return out

## Where a point sits relative to the road: the centreline point directly below
## it, the roll there, and its own offset from it split into lateral,
## along-track and vertical parts.
##
## The search is horizontal, and restricted to the tile's own stretch of
## centreline. Both matter. Projecting in 3D would fold the road's gradient into
## the lateral offset, so a vertex on a ramp would slide along the road as well
## as across it; and searching the whole loop would be a few hundred segments per
## vertex, on tiles with hundreds of vertices, at runtime.
func _frame_at(w: Vector3, lo: int, hi: int) -> Dictionary:
	var p := Vector2(w.x, w.z)
	var best := INF
	var out := {}
	for i in range(lo, hi):
		var a := centreline[i]
		var b := centreline[i + 1]
		var base := Vector2(a.x, a.z)
		var seg := Vector2(b.x - a.x, b.z - a.z)
		var len2 := seg.length_squared()
		if len2 < 0.000001:
			continue
		var t := clampf((p - base).dot(seg) / len2, 0.0, 1.0)
		var foot := base + seg * t
		var d := foot.distance_squared_to(p)
		if d >= best:
			continue
		best = d
		var tangent := seg / sqrt(len2)
		var side: Vector3 = _sides[i].lerp(_sides[i + 1], t)
		side = side.normalized() if side.length() > 0.001 else _sides[i]
		out = {
			"side": side,
			"tangent": Vector3(tangent.x, 0.0, tangent.y),
			"roll": lerpf(bank[i], bank[i + 1], t),
			"lift": lerpf(_ramp_lift[i], _ramp_lift[i + 1], t),
			"lateral": (p - foot).dot(Vector2(side.x, side.z)),
		}
	return out

## Lifts a point onto the banked cross-section. Purely vertical, and exactly the
## same function the collision ribbon is built from, which is what makes the road
## the car drives on the road the player can see.
##
## The bank lift is added back here because a tile is placed at the height the
## walker reached, which is the ground the embankment is built on, while the
## ribbon is measured from a centreline that has already been raised onto it.
## `frame["lift"]` is the other correction of the same kind: inside a multi-tile
## ramp the centreline follows one grade across the whole chain while the mesh
## still carries its own per-tile ease, and this is the gap between them.
static func _roll_point(w: Vector3, frame: Dictionary) -> Vector3:
	var roll: float = frame["roll"]
	return w + Vector3.UP * (
		_bank_rise(frame["lateral"], roll) + _bank_lift(roll) + frame["lift"]
	)

## The matching rotation for a normal: the surface has been tilted by its own
## local gradient, which is the full bank across the tarmac and the opposite way
## across the verge that grades back down.
static func _roll_direction(v: Vector3, frame: Dictionary) -> Vector3:
	var angle := atan(_bank_slope(frame["lateral"], frame["roll"]))
	var side: Vector3 = frame["side"]
	var tangent: Vector3 = frame["tangent"]
	var cs := cos(angle)
	var sn := sin(angle)
	var lateral := v.dot(side)
	return (
		side * (lateral * cs - v.y * sn)
		+ Vector3.UP * (lateral * sn + v.y * cs)
		+ tangent * v.dot(tangent)
	).normalized()

static func _mesh_instances(root_node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root_node is MeshInstance3D:
		out.append(root_node)
	for c in root_node.get_children():
		out.append_array(_mesh_instances(c))
	return out

static func _relative_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	var out := Transform3D()
	var at := node
	while at != null and at != ancestor:
		out = at.transform * out
		at = at.get_parent() as Node3D
	return out

## The driving surface: a ribbon of quads along the centreline, as one concave
## shape. Seamless for the raycast wheels, and it follows the elevation changes
## that the flat ground plane cannot.
func _build_road_collision(root_node: Node3D) -> void:
	var body := StaticBody3D.new()
	body.name = "RoadSurface"
	root_node.add_child(body)

	var cuts := _ribbon_cuts()
	var faces := PackedVector3Array()
	for i in centreline.size() - 1:
		var a := centreline[i]
		var b := centreline[i + 1]
		if Vector2(b.x - a.x, b.z - a.z).length() < 0.001:
			continue
		# Each end carries its own roll, so a strip inside a bank transition is
		# twisted rather than flat, and consecutive strips share their edges
		# exactly.
		for k in cuts.size() - 1:
			var a_in := _ribbon_point(a, _sides[i], bank[i], cuts[k])
			var a_out := _ribbon_point(a, _sides[i], bank[i], cuts[k + 1])
			var b_in := _ribbon_point(b, _sides[i + 1], bank[i + 1], cuts[k])
			var b_out := _ribbon_point(b, _sides[i + 1], bank[i + 1], cuts[k + 1])
			faces.append_array([a_in, b_in, b_out])
			faces.append_array([a_in, b_out, a_out])

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# Concave shapes are one-sided by default, so whether the ribbon collides at
	# all depends on triangle winding - and getting that wrong means the car
	# silently falls through the elevated sections. Collide from both sides.
	shape.backface_collision = true
	var col := CollisionShape3D.new()
	col.name = "RoadCollision"
	col.shape = shape
	body.add_child(col)
	_triangles = faces.size() / 3

func _build_checkpoints(root_node: Node3D) -> void:
	var holder := Node3D.new()
	holder.name = "Checkpoints"
	root_node.add_child(holder)

	var total := _total_length()
	var step := total / float(CHECKPOINT_COUNT)
	_gate_spacing = step

	var script: Script = load("res://scripts/track/checkpoint.gd")
	# Gate 0 goes on the painted line and the rest follow it round, rather than
	# all of them hanging off arc zero. Otherwise the lap both starts and ends
	# before the car reaches the line it is being timed to.
	#
	# The box is then pushed forward by half its own depth, because `body_entered`
	# fires when the car first touches the *leading face* — so it is that face,
	# not the centre, that is the trigger plane and belongs on the line. The gate
	# is deliberately thick so nothing tunnels through it at speed, and every
	# metre of that thickness was a metre of the lap timed early.
	for i in CHECKPOINT_COUNT:
		var sample := _point_at_arc(
			START_LINE_ARC + CHECKPOINT_T * 0.5 + step * float(i)
		)
		var pt: Vector3 = sample[0]
		var tan: Vector2 = sample[1]

		var area := Area3D.new()
		area.name = "Checkpoint%02d" % i
		area.set_script(script)
		area.set("index", i)
		area.position = pt + Vector3(0.0, CHECKPOINT_H * 0.5, 0.0)
		area.rotation.y = atan2(tan.x, tan.y)
		holder.add_child(area)

		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(CHECKPOINT_W, CHECKPOINT_H, CHECKPOINT_T)
		col.shape = box
		area.add_child(col)

func _build_walls(root_node: Node3D) -> void:
	var walls := StaticBody3D.new()
	walls.name = "Walls"
	root_node.add_child(walls)

	var barrier_src: Node3D = load(
		"res://assets/kenney/racing_kit/%s.glb" % BARRIER_PIECE
	).instantiate()
	var barrier_mesh: Mesh = _first_mesh(barrier_src).mesh
	var barrier_aabb := barrier_mesh.get_aabb()
	var barrier_centre := barrier_aabb.position + barrier_aabb.size * 0.5
	barrier_centre.y = barrier_aabb.position.y

	var barrier_root := Node3D.new()
	barrier_root.name = "Barriers"
	root_node.add_child(barrier_root)

	var barrier_xforms: Array[Transform3D] = []
	for side in [-1.0, 1.0]:
		for p in _resample(_offset_line(side), BARRIER_STEP):
			var pt: Vector3 = p[0]
			var tan: Vector2 = p[1]
			var yaw := (
				atan2(tan.x, tan.y) if BARRIER_LENGTH_AXIS == "z"
				else atan2(-tan.y, tan.x)
			)
			var basis := Basis(Vector3.UP, yaw).scaled(
				Vector3(BARRIER_SCALE, BARRIER_SCALE, BARRIER_SCALE)
			)
			barrier_xforms.append(Transform3D(basis, pt - basis * barrier_centre))

	for i in barrier_xforms.size():
		var mi := MeshInstance3D.new()
		mi.name = "Barrier%03d" % i
		mi.mesh = barrier_mesh
		mi.transform = barrier_xforms[i]
		barrier_root.add_child(mi)
	barrier_src.free()

	for side in [-1.0, 1.0]:
		var line := _offset_line(side)
		for i in line.size() - 1:
			var a: Vector3 = line[i]
			var b: Vector3 = line[i + 1]
			var d := Vector2(b.x - a.x, b.z - a.z)
			var seg_len := d.length()
			if seg_len < 0.01:
				continue
			var mid := (a + b) * 0.5
			var angle := atan2(-d.y, d.x)

			var col_xform := Transform3D()
			col_xform = col_xform.rotated(Vector3.UP, angle - PI * 0.5)
			col_xform.origin = mid + Vector3(0.0, WALL_H * 0.5, 0.0)

			var col := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3(WALL_T, WALL_H, seg_len)
			col.shape = shape
			col.transform = col_xform
			walls.add_child(col)

func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var m := _first_mesh(c)
		if m != null:
			return m
	return null

func _offset_line(side: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in centreline.size() - 1:
		var a := centreline[i]
		var b := centreline[i + 1]
		var d := Vector2(b.x - a.x, b.z - a.z)
		if d.length() < 0.01:
			continue
		var n := Vector2(-d.y, d.x).normalized() * WALL_GAP * side
		var off := Vector3(n.x, 0.0, n.y)
		if out.is_empty():
			out.append(a + off)
		out.append(b + off)
	return out

func _total_length() -> float:
	var total := 0.0
	for i in centreline.size() - 1:
		total += centreline[i].distance_to(centreline[i + 1])
	return total

## Position and horizontal tangent at a given arc length along the centreline.
##
## The arc wraps, because everything is now placed relative to the start line:
## the grid slot sits at a negative arc and the last gates run past the end.
func _point_at_arc(target: float) -> Array:
	if centreline.is_empty():
		return [Vector3.ZERO, Vector2(0, 1)]
	var total := _total_length()
	if total <= 0.0:
		return [centreline[0], Vector2(0, 1)]
	target = fposmod(target, total)
	var travelled := 0.0
	for i in centreline.size() - 1:
		var a := centreline[i]
		var b := centreline[i + 1]
		var seg := b - a
		var seg_len := seg.length()
		if seg_len < 0.001:
			continue
		if travelled + seg_len >= target:
			var dir := seg / seg_len
			return [a + dir * (target - travelled), Vector2(dir.x, dir.z).normalized()]
		travelled += seg_len
	var last := centreline[centreline.size() - 1]
	return [last, Vector2(0, 1)]

## Walks a 3D polyline at fixed arc-length intervals, returning
## [point, horizontal tangent].
func _resample(line: Array[Vector3], step: float) -> Array:
	var out := []
	# A zero step would advance the walk by nothing and spin forever. The tool
	# could never reach that, but a player's half-painted loop can compile to a
	# degenerate centreline, and the editor recompiles on every mouse move.
	if line.size() < 2 or step <= 0.0:
		return out
	var carry := 0.0
	for i in line.size() - 1:
		var a := line[i]
		var b := line[i + 1]
		var seg := b - a
		var seg_len := seg.length()
		if seg_len < 0.001:
			continue
		var dir := seg / seg_len
		var flat := Vector2(dir.x, dir.z).normalized()
		var t := carry
		while t < seg_len:
			out.append([a + dir * t, flat])
			t += step
		carry = t - seg_len
	return out

func _build_ground(root_node: Node3D) -> void:
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	root_node.add_child(ground)

	var mi := MeshInstance3D.new()
	mi.name = "GroundMesh"
	var plane := PlaneMesh.new()
	plane.size = Vector2(4000.0, 4000.0)
	var shader_mat := ShaderMaterial.new()
	shader_mat.shader = load("res://assets/shaders/ground_grid.gdshader")
	shader_mat.set_shader_parameter("grid_size", 10.0)
	shader_mat.set_shader_parameter("line_width", 0.08)
	shader_mat.set_shader_parameter("base_color", Color(0.24, 0.30, 0.24))
	shader_mat.set_shader_parameter("line_color", Color(0.30, 0.36, 0.30))
	plane.material = shader_mat
	mi.mesh = plane
	mi.position.y = -0.02
	ground.add_child(mi)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 1.0, 4000.0)
	col.shape = box
	col.position.y = -0.5
	ground.add_child(col)

func _build_lighting(root_node: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	sun.shadow_enabled = true
	root_node.add_child(sun)

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	we.environment = env
	root_node.add_child(we)

## Set `owner` on nodes you created and on instanced sub-scene *roots*, but
## never on an instance's internal nodes — those then serialise on top of the
## instance and everything appears twice. Only needed when packing to a file.
static func set_owner_recursive(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		if c.scene_file_path.is_empty():
			set_owner_recursive(c, owner_node)
