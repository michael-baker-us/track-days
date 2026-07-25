extends SceneTree

# Builds scenes/track/track_02.tscn from a layout spec.
#
# Axis convention: -Z North, +Z South, -X West, +X East. Kenney road tiles are
# authored on a 1-unit grid with off-centre origins; every piece is normalised
# so its cell min corner sits at the origin, then placed by matching its entry
# connection point and edge normal to the walker's current position/heading.
#
# Collision deliberately does NOT come from the road meshes. Every tile is flat
# at y=0, so the existing flat ground plane already *is* a perfectly smooth
# driving surface with no seams for the raycast wheels to catch on. The road
# meshes are visual only; walls constrain the car to the circuit.

# 1 tile unit -> this many metres. Sets road width, corner radii and lap length
# together, since Kenney has no wider road tiles. The car does not scale, so
# raising this widens the track relative to the car and opens up the corners.
const SCALE := 14.0
const ROAD_HALF := 0.5 * SCALE
# Distance from centreline to wall. Must stay below the smallest corner's
# centreline radius or the inner offset polyline inverts and the walls cross
# themselves. Smallest corner in use is roadCornerLarge at 1.5 units (15 m).
# Kept close to the 5 m road edge so the barrier reads as the track boundary
# and nudges you back on rather than letting you wander into open grass.
const WALL_GAP := 0.7 * SCALE
# railDouble is a 0.28-unit guardrail (2.8 m once scaled) - tall enough to read
# as the track edge from the chase camera, unlike the 1.3 m barrierWall which
# looked like a road marking. Its length runs along local +Z, not +X.
# Guardrails and their wall collision, off by default.
#
# They are disabled because the offset polyline they follow is wrong at corners:
# `_offset_line` offsets each vertex by the *preceding* segment's normal only,
# with no mitring, so at every direction change the offset lags a segment and
# kinks - which puts inner rails across the racing line and cuts off parts of
# the track. Offsetting a polyline properly needs the averaged normal of the two
# adjacent segments at each vertex (and outer-corner arcs). Not worth doing yet;
# the circuit drives fine without them since the ground is one flat plane.
#
# Set true to build them anyway - everything below still works, it just clips.
const BARRIERS_ENABLED := false
const BARRIER_PIECE := "railDouble"
const BARRIER_LENGTH_AXIS := "z"
# Deliberately independent of SCALE: the car never scales, so a guardrail sized
# off the track scale would tower over it. 10 gives a ~2.8 m rail in 10 m spans.
const BARRIER_SCALE := 10.0
const BARRIER_STEP := 1.0 * BARRIER_SCALE
const WALL_H := 2.8  # matches the guardrail height so you cannot see over it
const WALL_T := 0.6
const ARC_STEPS := 8

const DIRS := {
	"N": Vector2(0, -1), "S": Vector2(0, 1),
	"E": Vector2(1, 0), "W": Vector2(-1, 0),
}

# name -> cell size, origin shift, connection points (normalised cell coords),
# and for corners the arc centre so walls can follow the curve.
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
	"roadCornerSmall": {
		"cell": Vector2(1.0, 1.0), "shift": Vector2(0.35, 1.65),
		"conns": {"E": Vector2(1.0, 0.5), "S": Vector2(0.5, 1.0)},
		"arc": Vector2(0.5, 0.5),
	},
	"roadCornerLarge": {
		"cell": Vector2(2.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"E": Vector2(2.0, 0.5), "S": Vector2(0.5, 2.0)},
		"arc": Vector2(0.5, 0.5),
	},
	"roadCornerLarger": {
		"cell": Vector2(3.0, 3.0), "shift": Vector2(0.35, 3.65),
		"conns": {"E": Vector2(3.0, 0.5), "S": Vector2(0.5, 3.0)},
		"arc": Vector2(0.5, 0.5),
	},
}

# ["S", piece, repeat] straight | ["C", piece, "left"|"right"] corner
const LAYOUT := [
	["S", "roadStart", 1],
	["S", "roadStartPositions", 1],
	["S", "roadStraightLong", 6],
	["C", "roadCornerLarger", "right"],
	["S", "roadStraightLong", 4],
	["C", "roadCornerLarge", "right"],
	["S", "roadStraightLong", 3],
	["C", "roadCornerLarge", "left"],
	["S", "roadStraightLong", 2],
	["C", "roadCornerLarge", "right"],
	["S", "roadStraightLong", 8],
	["C", "roadCornerLarger", "right"],
	["S", "roadStraightLong", 7],
	["S", "roadStraight", 1],
	["C", "roadCornerLarge", "right"],
	["S", "roadStraightLong", 4],
	["S", "roadStraight", 1],
]

var centreline: Array[Vector2] = []

func _initialize() -> void:
	var root_node := Node3D.new()
	root_node.name = "Track02"

	var roads := Node3D.new()
	roads.name = "RoadVisuals"
	roads.scale = Vector3(SCALE, SCALE, SCALE)
	root_node.add_child(roads)

	var pos := Vector2.ZERO
	var heading := DIRS["S"]
	var turn_total := 0

	for seg in LAYOUT:
		var kind: String = seg[0]
		var piece: String = seg[1]
		if kind == "S":
			for i in int(seg[2]):
				var r := _place(roads, piece, pos, heading, heading)
				pos = r[0]
				_trace_straight(r[2], r[0])
		else:
			var turn: String = seg[2]
			var new_heading := _rotate(heading, 90.0 if turn == "left" else -90.0)
			turn_total += (1 if turn == "left" else -1)
			var r := _place(roads, piece, pos, heading, new_heading)
			_trace_arc(piece, r[3], r[4], r[2], r[0])
			pos = r[0]
			heading = new_heading

	var gap := pos - Vector2.ZERO
	print("closure gap = (%.2f, %.2f) units | heading %s | net turns %d (need -4 or +4)" % [
		gap.x, gap.y, heading, turn_total
	])

	if BARRIERS_ENABLED:
		_build_walls(root_node)
	_build_ground(root_node)
	_build_lighting(root_node)

	var spawn := Marker3D.new()
	spawn.name = "SpawnPoint"
	# On the centreline, a little past the start line, facing down the straight.
	var start_dir := DIRS["S"]
	var start_pt: Vector2 = centreline[1] if centreline.size() > 1 else Vector2.ZERO
	spawn.position = Vector3(start_pt.x, 1.0, start_pt.y)
	# The car model faces local +Z, so align +Z with the opening heading.
	spawn.rotation.y = atan2(start_dir.x, start_dir.y)
	root_node.add_child(spawn)

	_set_owner(root_node, root_node)
	var packed := PackedScene.new()
	packed.pack(root_node)
	var err := ResourceSaver.save(packed, "res://scenes/track/track_02.tscn")
	var length := 0.0
	for i in centreline.size() - 1:
		length += centreline[i].distance_to(centreline[i + 1])
	print("saved track_02.tscn: %s | centreline pts %d | lap length %.0f m" % [
		"ok" if err == OK else "FAILED %s" % err, centreline.size(), length
	])
	root_node.free()
	quit(0)

# Returns [exit_pos, exit_heading, entry_pos, placement_transform_origin, rotation]
func _place(
	parent: Node3D, piece: String, pos: Vector2, heading: Vector2, want_heading: Vector2
) -> Array:
	var desc: Dictionary = PIECES[piece]
	var conns: Dictionary = desc["conns"]
	var keys: Array = conns.keys()

	for theta in [0.0, 90.0, 180.0, 270.0]:
		for a in keys:
			for b in keys:
				if a == b:
					continue
				# Entry edge must face against travel; exit must give the wanted heading.
				if not _rotate(DIRS[a], theta).is_equal_approx(-heading):
					continue
				if not _rotate(DIRS[b], theta).is_equal_approx(want_heading):
					continue

				var entry_local: Vector2 = conns[a]
				var exit_local: Vector2 = conns[b]
				var origin := pos - _rotate(entry_local, theta)
				var exit_pos := origin + _rotate(exit_local, theta)

				var holder := Node3D.new()
				holder.position = Vector3(origin.x, 0.0, origin.y)
				holder.rotation.y = deg_to_rad(theta)
				parent.add_child(holder)

				var inst: Node3D = load(
					"res://assets/kenney/racing_kit/%s.glb" % piece
				).instantiate()
				var shift: Vector2 = desc["shift"]
				inst.position = Vector3(shift.x, 0.0, shift.y)
				holder.add_child(inst)

				return [exit_pos, want_heading, pos, origin, theta]

	push_error("no placement for %s heading %s -> %s" % [piece, heading, want_heading])
	return [pos, heading, pos, Vector2.ZERO, 0.0]

func _rotate(v: Vector2, deg: float) -> Vector2:
	var a := deg_to_rad(deg)
	var c := cos(a)
	var s := sin(a)
	# Matches Godot's Y-rotation acting on (x, z).
	return Vector2(v.x * c + v.y * s, -v.x * s + v.y * c)

func _trace_straight(from: Vector2, to: Vector2) -> void:
	if centreline.is_empty():
		centreline.append(from * SCALE)
	centreline.append(to * SCALE)

func _trace_arc(piece: String, origin: Vector2, theta: float, from: Vector2, to: Vector2) -> void:
	var desc: Dictionary = PIECES[piece]
	if not desc.has("arc"):
		_trace_straight(from, to)
		return
	if centreline.is_empty():
		centreline.append(from * SCALE)

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
		centreline.append((centre + Vector2(cos(a), sin(a)) * radius) * SCALE)

func _build_walls(root_node: Node3D) -> void:
	var walls := StaticBody3D.new()
	walls.name = "Walls"
	root_node.add_child(walls)

	# Visual barriers are Kenney meshes laid along the same offset polyline the
	# collision boxes follow, so what you see is where you actually get stopped.
	var barrier_src: Node3D = load(
		"res://assets/kenney/racing_kit/%s.glb" % BARRIER_PIECE
	).instantiate()
	var barrier_mesh: Mesh = _first_mesh(barrier_src).mesh
	var barrier_aabb := barrier_mesh.get_aabb()
	var barrier_centre := barrier_aabb.position + barrier_aabb.size * 0.5
	# Sit it on the ground rather than centred vertically on the path point.
	barrier_centre.y = barrier_aabb.position.y

	# Deliberately plain MeshInstance3D nodes rather than a MultiMesh: a
	# MultiMesh's instance transforms live in its `buffer` property, which is
	# NOT serialised by ResourceSaver into a packed scene. The instance count
	# survives but every transform collapses to identity, so all the barriers
	# end up stacked invisibly at the origin.
	var barrier_root := Node3D.new()
	barrier_root.name = "Barriers"
	root_node.add_child(barrier_root)

	var barrier_xforms: Array[Transform3D] = []
	for side in [-1.0, 1.0]:
		var line := _offset_line(side)
		for p in _resample(line, BARRIER_STEP):
			var pt: Vector2 = p[0]
			var tan: Vector2 = p[1]
			# Align the mesh's length axis with the path tangent.
			var yaw := (
				atan2(tan.x, tan.y) if BARRIER_LENGTH_AXIS == "z"
				else atan2(-tan.y, tan.x)
			)
			var basis := Basis(Vector3.UP, yaw).scaled(
				Vector3(BARRIER_SCALE, BARRIER_SCALE, BARRIER_SCALE)
			)
			var origin := Vector3(pt.x, 0.0, pt.y) - basis * barrier_centre
			barrier_xforms.append(Transform3D(basis, origin))

	for i in barrier_xforms.size():
		var mi := MeshInstance3D.new()
		mi.name = "Barrier%03d" % i
		mi.mesh = barrier_mesh
		mi.transform = barrier_xforms[i]
		barrier_root.add_child(mi)
	print("barriers: %d nodes | first origin=%s" % [
		barrier_xforms.size(),
		barrier_xforms[0].origin if barrier_xforms.size() > 0 else Vector3.ZERO
	])
	barrier_src.free()

	for side in [-1.0, 1.0]:
		for i in centreline.size() - 1:
			var a := centreline[i]
			var b := centreline[i + 1]
			var dir := (b - a)
			if dir.length() < 0.01:
				continue
			var n: Vector2 = Vector2(-dir.y, dir.x).normalized() * WALL_GAP * side
			var wa: Vector2 = a + n
			var wb: Vector2 = b + n
			var mid: Vector2 = (wa + wb) * 0.5
			var seg_len: float = (wb - wa).length()
			var angle := atan2(-(wb - wa).y, (wb - wa).x)

			# The collision box carries the length in its own size, so its
			# transform must NOT also be scaled - doing both makes each wall
			# seg_len^2 long and buries the whole circuit in invisible geometry.
			var col_xform := Transform3D()
			col_xform = col_xform.rotated(Vector3.UP, angle - PI * 0.5)
			col_xform.origin = Vector3(mid.x, WALL_H * 0.5, mid.y)

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

func _offset_line(side: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in centreline.size() - 1:
		var a := centreline[i]
		var b := centreline[i + 1]
		var d := b - a
		if d.length() < 0.01:
			continue
		var n := Vector2(-d.y, d.x).normalized() * WALL_GAP * side
		if out.is_empty():
			out.append(a + n)
		out.append(b + n)
	return out

# Walks a polyline at fixed arc-length intervals, returning [point, tangent].
func _resample(line: Array[Vector2], step: float) -> Array:
	var out := []
	if line.size() < 2:
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
		var t := carry
		while t < seg_len:
			out.append([a + dir * t, dir])
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
	# Just under the road tiles so the road reads as raised tarmac on grass.
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

func _set_owner(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		if c != owner_node:
			c.owner = owner_node
		_set_owner(c, owner_node)
