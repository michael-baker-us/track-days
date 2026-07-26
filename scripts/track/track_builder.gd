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

# Lap checkpoints. Index 0 sits on the start line; a lap only counts if all of
# them are crossed in order.
const CHECKPOINT_COUNT := 16
const CHECKPOINT_W := 4.0 * SCALE
const CHECKPOINT_H := 12.0  # tall enough to still catch the car on a slope
const CHECKPOINT_T := 4.0

## How far behind the start line the car is placed. Far enough to get rolling,
## close enough that the lap timer starts within a couple of seconds.
const SPAWN_BEHIND_LINE := 22.0

## Where the start/finish line sits along the layout, in tile units.
##
## Not zero, which is the trap. The walker starts at the *leading edge* of the
## `roadStart` tile, but that tile is 2 units long and carries the line across
## the middle of itself: the painted stripe spans z 0.905..0.954 and the gantry
## straddles it at 0.905..1.085. Timing from arc 0 therefore started and stopped
## the clock 13 m before the car reached anything the player can see.
##
## The value is the midpoint of that whole assembly, so the trigger is within
## half a metre of both the stripe and the middle of the arch rather than exact
## on one and a metre out on the other.
const START_LINE_ALONG := 0.96
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
# connection heights in tile units, and for corners the arc centre.
const PIECES := {
	"roadStart": {
		"cell": Vector2(1.26, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.63, 0.0), "S": Vector2(0.63, 2.0)},
	},
	"roadStartPositions": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
	},
	"roadStraightLong": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
	},
	"roadStraight": {
		"cell": Vector2(1.0, 1.0), "shift": Vector2(0.35, 1.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 1.0)},
	},
	# Climbs 0.5 units over its 2 units of length.
	"roadRampLong": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
		"conn_y": {"N": 0.5, "S": 0.0},
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

var _triangles := 0
var _gate_spacing := 0.0

## Layout grammar:
##   ["S", piece, repeat]              straight run
##   ["S", piece, repeat, rise_sign]   ramp; +1 climbs, -1 descends, same mesh
##   ["C", piece, "left"|"right"]      corner
##
## A layout only makes a circuit if it closes: gap (0, 0), net turns +/-4, and
## height back to 0. Callers must check `BuildResult.closed` — the builder still
## returns geometry for a broken layout so the editor can draw it.
##
## With `with_geometry` false nothing is instanced and `result.root` is null;
## see `measure()`.
func build(track_name: String, layout: Array, with_geometry := true) -> BuildResult:
	centreline = []
	_triangles = 0
	_gate_spacing = 0.0

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
			for i in int(seg[2]):
				var r := _place(roads, piece, pos, heading, heading, height, rise_sign)
				_trace_straight(r[2], height, r[0], r[5])
				pos = r[0]
				height = r[5]
				peak = maxf(peak, height)
		else:
			var turn: String = seg[2]
			var new_heading := _rotate(heading, 90.0 if turn == "left" else -90.0)
			turn_total += (1 if turn == "left" else -1)
			var r := _place(roads, piece, pos, heading, new_heading, height, 0)
			_trace_arc(piece, r[3], r[4], r[2], r[0], height)
			pos = r[0]
			height = r[5]
			heading = new_heading

	var total := 0.0
	for i in centreline.size() - 1:
		total += centreline[i].distance_to(centreline[i + 1])

	if with_geometry:
		if BARRIERS_ENABLED:
			_build_walls(root_node)
		_build_road_collision(root_node)
		_build_checkpoints(root_node)
		_build_ground(root_node)
		_build_lighting(root_node)

		# Start just *behind* the line rather than just past it, so the timer
		# starts a second or two in instead of after a full out lap. Measured
		# back from the line itself, so moving the line moves the grid with it.
		var grid := _point_at_arc(START_LINE_ARC - SPAWN_BEHIND_LINE)
		var spawn := Marker3D.new()
		spawn.name = "SpawnPoint"
		spawn.position = (grid[0] as Vector3) + Vector3(0.0, 1.0, 0.0)
		# The car model faces local +Z, so align +Z with the track tangent.
		var tan: Vector2 = grid[1]
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

# Returns [exit_pos, exit_heading, entry_pos, origin, theta, exit_height]
func _place(
	parent: Node3D, piece: String, pos: Vector2, heading: Vector2,
	want_heading: Vector2, height: float, rise_sign: int
) -> Array:
	var desc: Dictionary = PIECES[piece]
	var conns: Dictionary = desc["conns"]
	var conn_y: Dictionary = desc.get("conn_y", {})
	var keys: Array = conns.keys()

	for theta in [0.0, 90.0, 180.0, 270.0]:
		for a in keys:
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
				if parent != null:
					var holder := Node3D.new()
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

				return [exit_pos, want_heading, pos, origin, theta, height + rise]

	push_error("no placement for %s heading %s -> %s rise_sign %d" % [
		piece, heading, want_heading, rise_sign
	])
	return [pos, heading, pos, Vector2.ZERO, 0.0, height]

func _rotate(v: Vector2, deg: float) -> Vector2:
	var a := deg_to_rad(deg)
	var c := cos(a)
	var s := sin(a)
	# Matches Godot's Y-rotation acting on (x, z).
	return Vector2(v.x * c + v.y * s, -v.x * s + v.y * c)

func _world(p: Vector2, h: float) -> Vector3:
	return Vector3(p.x * SCALE, h * SCALE * VERT, p.y * SCALE)

func _trace_straight(from: Vector2, from_h: float, to: Vector2, to_h: float) -> void:
	if centreline.is_empty():
		centreline.append(_world(from, from_h))
	centreline.append(_world(to, to_h))

func _trace_arc(
	piece: String, origin: Vector2, theta: float, from: Vector2, to: Vector2, h: float
) -> void:
	var desc: Dictionary = PIECES[piece]
	if not desc.has("arc"):
		_trace_straight(from, h, to, h)
		return
	if centreline.is_empty():
		centreline.append(_world(from, h))

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

## The driving surface: a ribbon of quads along the centreline, as one concave
## shape. Seamless for the raycast wheels, and it follows the elevation changes
## that the flat ground plane cannot.
func _build_road_collision(root_node: Node3D) -> void:
	var body := StaticBody3D.new()
	body.name = "RoadSurface"
	root_node.add_child(body)

	var faces := PackedVector3Array()
	for i in centreline.size() - 1:
		var a := centreline[i]
		var b := centreline[i + 1]
		var dir := b - a
		var flat := Vector2(dir.x, dir.z)
		if flat.length() < 0.001:
			continue
		var n := Vector2(-flat.y, flat.x).normalized() * RIBBON_HALF
		var offset := Vector3(n.x, 0.0, n.y)
		var a_l := a + offset
		var a_r := a - offset
		var b_l := b + offset
		var b_r := b - offset
		faces.append_array([a_l, b_l, b_r])
		faces.append_array([a_l, b_r, a_r])

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
