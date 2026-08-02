class_name TyreMarks
extends MultiMeshInstance3D

## What the tyres leave on the road, and how it stays there.
##
## ## Why a MultiMesh and not a growing mesh
##
## Marks are laid continuously while driving, so the obvious shape — append to a
## mesh — means rebuilding a vertex array many times a second, in GDScript, on the
## physics thread. A `MultiMesh` is built once with a fixed number of instances
## and each new mark **writes one transform**, which is a single upload.
##
## ## Why they never fade
##
## They used to be a ring buffer: `CHUNK` marks on the road at once and the oldest
## overwritten. That is the cheap answer, and it is the wrong one — a trail that
## erases itself from behind means the line you took two corners ago is gone
## before you have finished the lap, and on dirt or snow the whole appeal is
## coming back round to a circuit that remembers you. Marks now persist for the
## whole session.
##
## Permanence is affordable because of `_cells`, not in spite of it. A mark is
## claimed against a **quantised patch of ground**, so driving the same line again
## does not stack a second mark on the first — it *deepens the one already there*.
## Growth is therefore bounded by how much distinct ground the car has touched
## rather than by how long the session has run, and a hundredth lap of the same
## line costs nothing at all. It is also what a rut really does: repeated passes
## wear the same groove, they do not pile ruts on top of each other.
##
## New ground goes into a fresh chunk once the current one is full. Chunks matter
## because `MultiMesh.buffer` can only be assigned **whole** — with one growing
## buffer, every mark laid late in a session would re-upload every mark laid
## earlier in it. A chunk is a fixed 40 KB however many chunks exist, so the cost
## of laying a mark does not depend on how many are already down.
##
## ## Why the depth is displaced material, not a carved hole
##
## On a loose surface a mark is a trough with a **raised shoulder either side** —
## the shape a tyre actually leaves where it pushes material aside rather than
## removing it. That is not only physical honesty: the road is Kenney tiles, and a
## rut displaced *downwards* would be hidden behind the tile it lies on. You cannot
## dig into geometry you do not own.
##
## Carving properly means the drivable surface becoming a dense generated ribbon
## that can be displaced in a vertex shader — `docs/roadmap.md` M17 step three, and
## a much larger change. The ribbon's coordinate system already exists
## (`_build_road_overlay`); the road being made of it does not.
##
## ## Rubber and ruts are not the same thing
##
## Tarmac gets neither the depth nor the rolling mark. A tyre on tarmac deposits a
## film of rubber and displaces nothing, so its mark is **flat** and only appears
## when the tyre is *sliding* — which is what makes laying rubber mean something.
## Both differences live in `RoadSurface`, as `mark_depth` and `mark_always`.

## Marks per chunk. One chunk is one draw call and one 40 KB buffer, and 640 at
## `SPACING` is roughly 90 m of trail per wheel.
const CHUNK := 640

## The ceiling, as a safety valve rather than as the design. Past it the car stops
## marking new ground, and — deliberately — nothing already laid disappears; a
## trail that vanishes in chunks of 640 would be worse than one that stops
## growing. 96 chunks is 61,440 distinct patches, about 9,800 m² of ground, which
## a car following anything like a racing line will not reach in a session.
const MAX_CHUNKS := 96

## Twelve floats of transform then four of colour, which is the layout
## `MultiMesh.buffer` uses once `use_colors` is on.
const FLOATS_PER_MARK := 16

## How far a wheel travels between marks. Close enough to read as continuous, far
## enough that a lap is not spent marking one straight.
const SPACING := 0.55

## The patch of ground one mark claims. Smaller than a mark, so a trail still
## overlaps into a continuous groove, and large enough that a second lap on the
## same line lands in the same patches instead of beside them.
const CELL := 0.4

## How much stronger a mark has to be before it is worth rewriting the one already
## in that patch. Without it a wheel wobbling either side of a slip threshold
## would rewrite the same patch every time it passed.
const DEEPEN := 0.06

## The size of the patch a tyre leaves, and the shape of it.
##
## `RIDGE` is what makes a loose-surface mark read as three-dimensional: the tyre
## **pushes material aside**, so the mark is a shallow trough with a shoulder
## either side and what you see is the light catching those shoulders.
const WIDTH := 0.36
const LENGTH := 0.8
## How high displaced material stands, and how far the trough sinks below the
## road. The floor sits fractionally proud so it never fights the tarmac for the
## depth buffer.
const RIDGE := 0.045
const FLOOR := 0.004
## How far a flat mark floats above the road. Enough to clear z-fighting on a
## banked or ramped tile, small enough to be invisible edge-on.
const LIFT := 0.008

## Below this there is no mark worth drawing. `get_skidinfo` is 1.0 with full grip
## and falls as the tyre slides, so this is measured on `1 - skidinfo`.
const SLIP_FLOOR := 0.12

## How far either side of a contact point to look for the road.
const ROAD_PROBE := 0.4

var _wheels: Array[VehicleWheel3D] = []
var _last: Array[Vector3] = []
var _always := false
var _mesh: Mesh
var _material: StandardMaterial3D
## Chunk zero is this node itself; the rest are children created on demand.
var _chunks: Array[MultiMeshInstance3D] = []
## Each chunk's buffer, kept because assigning one means having all of it.
var _buffers: Array[PackedFloat32Array] = []
## Slots taken in the newest chunk.
var _used := 0
## Ground patch -> `[chunk, slot, strength]` of the mark that owns it.
var _cells := {}
var _exclude: Array[RID] = []

func _ready() -> void:
	# World space: the marks stay on the road the car has left behind, which is
	# the one thing they must not do if they inherit its transform.
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var car := get_parent()
	for child in car.get_children():
		if child is VehicleWheel3D:
			_wheels.append(child)
			_last.append(Vector3.INF)
	if car is CollisionObject3D:
		_exclude = [(car as CollisionObject3D).get_rid()]

	var surface := RoadSurface.named(GameState.selected_surface)
	_always = bool(surface["mark_always"])
	var relief := bool(surface.get("mark_depth", true))
	_mesh = mark_mesh(relief)
	_material = mark_material(surface["mark"], relief)
	material_override = _material
	_add_chunk()

## One more chunk of instances, all degenerate. The first is this node, so a
## session that never leaves the pit lane allocates nothing extra.
func _add_chunk() -> void:
	var node: MultiMeshInstance3D = self
	if not _chunks.is_empty():
		node = MultiMeshInstance3D.new()
		node.name = "Chunk%d" % _chunks.size()
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.material_override = _material
		# Not `top_level`: this node already is, and sits at the origin, so a
		# child inherits world space from it.
		add_child(node)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# Per-instance colour is how a mark carries its own strength, so a light
	# scuff and a locked wheel are the same geometry at different depths.
	mm.use_colors = true
	mm.mesh = _mesh
	mm.instance_count = CHUNK
	node.multimesh = mm

	# Written through `buffer`, not `set_instance_transform`.
	#
	# The per-instance setters do not survive a headless run — this project has
	# the scar already, from barriers built as a MultiMesh whose transforms all
	# collapsed to identity (`docs/tuning-journal.md`, M3b). Confirmed again here:
	# under `--headless` a colour set to alpha 0 reads back as opaque black and a
	# zero-scaled basis reads back as identity, while the buffer round-trips
	# exactly. The buffer is also the only form the suite can *check*, which is
	# the more important half.
	#
	# All zeros: a zero basis is a degenerate instance and draws nothing, so a
	# fresh chunk is invisible until something is written into it.
	var buf := PackedFloat32Array()
	buf.resize(CHUNK * FLOATS_PER_MARK)
	mm.buffer = buf

	_chunks.append(node)
	_buffers.append(buf)
	_used = 0

## The shape of one mark: a trough with a shoulder of displaced material either
## side on a loose surface, and a flat patch on tarmac.
##
## Six spans across the tyre rather than a flat quad, because the normals are what
## sell it. Built once and instanced, so the cost of the shape is paid a single
## time however many marks are on the road.
##
## Static so the suite can build both without racing on both.
static func mark_mesh(relief: bool) -> ArrayMesh:
	var half := WIDTH * 0.5
	# Across the mark: how far out, and how high. Ground, up onto the shoulder,
	# down into the trough, and back out symmetrically. Rubber has no section at
	# all — it is a film, so it is one flat span floating clear of the road.
	var section := (
		[
			[-half, 0.0], [-half * 0.72, RIDGE], [-half * 0.34, -FLOOR],
			[half * 0.34, -FLOOR], [half * 0.72, RIDGE], [half, 0.0],
		] if relief
		else [[-half, LIFT], [half, LIFT]]
	)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var back := -LENGTH * 0.5
	var front := LENGTH * 0.5
	for i in section.size() - 1:
		var a: Array = section[i]
		var b: Array = section[i + 1]
		var a0 := Vector3(a[0], a[1], back)
		var a1 := Vector3(a[0], a[1], front)
		var b0 := Vector3(b[0], b[1], back)
		var b1 := Vector3(b[0], b[1], front)
		var normal := (b0 - a0).cross(a1 - a0).normalized()
		if normal.y < 0.0:
			normal = -normal
		for v in [a0, b0, b1, a0, b1, a1]:
			st.set_normal(normal)
			st.add_vertex(v)
	return st.commit()

## How a mark takes the light, which is not the same question on the two surfaces.
##
## A rut is **lit**, unlike everything else laid on this road, and that is the
## whole point: a trough with raised shoulders only reads as a trough because the
## sun catches one side of each ridge and not the other. Unshaded, it would be a
## sticker of a rut.
##
## Rubber is unshaded, for the mirror-image reason. It is flat, so there is no
## relief for light to find, and lighting it would only make a film of rubber pick
## up a specular the road under it does not have. It also matches the racing-line
## rubber already baked into `road_overlay.gdshader`, which is the same material
## laid down by the same thing.
static func mark_material(tint: Color, relief: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = 1.0
	mat.metallic = 0.0
	# Per-instance colour carries how strong the mark is, so a light scuff and a
	# locked wheel are the same geometry at different opacities.
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if relief:
		# Sorted against the road rather than writing depth into it: the ridges
		# are millimetres proud and would otherwise flicker against the tarmac.
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	else:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# Laid over the tarmac without fighting it, exactly as the light pools
		# and the car's shadow are.
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return mat

func _physics_process(_delta: float) -> void:
	for i in _wheels.size():
		var wheel := _wheels[i]
		if not wheel.is_in_contact():
			# Forgotten rather than kept: a wheel that lands after a jump should
			# start a fresh mark, not draw one across the gap it flew over.
			_last[i] = Vector3.INF
			continue

		var point := wheel.get_contact_point()
		if _last[i] == Vector3.INF:
			_last[i] = point
			continue
		if point.distance_to(_last[i]) < SPACING:
			continue

		var heading := point - _last[i]
		# Advanced before any of the reasons to skip, so a lap of grass leaves
		# `_last` beside the car rather than back at the point it left the road —
		# otherwise rejoining would lay one mark stretched across the excursion.
		_last[i] = point
		if heading.length() < 0.001:
			continue

		var slip: float = clampf(1.0 - wheel.get_skidinfo(), 0.0, 1.0)
		var strength := (
			clampf(0.35 + slip, 0.0, 1.0) if _always
			else (slip if slip > SLIP_FLOOR else 0.0)
		)
		if strength <= 0.01:
			continue
		# Last, because it is the only test that costs a raycast.
		if not on_road(point):
			continue
		_place(point, wheel.get_contact_normal(), heading.normalized(), strength)

## Whether this contact is on the drivable ribbon rather than on the field beside
## it.
##
## Grass grips exactly like tarmac here, so nothing in the physics distinguishes
## on from off — but a set of ruts wandering across a field is the clearest
## possible signal that marks are being drawn by a rule rather than by a surface.
## Only the road is made of anything a tyre could mark.
##
## Asked by raycast rather than by distance from the centreline. The ribbon is one
## `StaticBody3D` on a collision layer of its own, so the collision world already
## holds the answer exactly, including on the sections carried over a crossing —
## while "within half a road width of the centreline" would be an approximation
## that has to be maintained alongside the real one, and would put marks on the
## bridge deck and on the road beneath it at once.
##
## **Masked to the road, so a hit *is* the answer.** Asking an unmasked ray what
## it hit does not work: the flat ribbon and the top of the ground slab are both
## at exactly y = 0, so which comes back is arbitrary. Nor does walking down
## through the hits — the same `Ground` body was measured coming back three times
## in a row from one point, which exhausted the walk and reported road as field
## across 40% of Suzuka.
##
## One ray per *mark*, not per frame: it is asked only once a wheel has covered
## `SPACING`.
func on_road(point: Vector3) -> bool:
	var world := get_world_3d()
	if world == null:
		return false
	var space := world.direct_space_state
	if space == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(
		point + Vector3.UP * ROAD_PROBE, point + Vector3.DOWN * ROAD_PROBE,
		TrackBuilder.ROAD_LAYER
	)
	query.exclude = _exclude
	return not space.intersect_ray(query).is_empty()

## Lays a mark on the patch of ground under `point`, or deepens the one already
## there.
func _place(
	point: Vector3, normal: Vector3, heading: Vector3, strength: float
) -> void:
	var up := normal if normal.dot(Vector3.UP) > 0.0 else -normal
	# Flattened onto the surface, so a mark on a banked corner lies on the
	# banking rather than cutting into it.
	var forward := heading - up * heading.dot(up)
	if forward.length() < 0.001:
		return
	forward = forward.normalized()
	var right := up.cross(forward).normalized()

	var key := Vector3i(
		floori(point.x / CELL), floori(point.y / CELL), floori(point.z / CELL)
	)
	var owner_of: Array = _cells.get(key, [])
	if owner_of.is_empty():
		if _used >= CHUNK:
			if _chunks.size() >= MAX_CHUNKS:
				return
			_add_chunk()
		owner_of = [_chunks.size() - 1, _used, 0.0]
		_cells[key] = owner_of
		_used += 1
	elif strength <= float(owner_of[2]) + DEEPEN:
		# Already marked at least this hard. The second lap through a corner
		# costs nothing, which is what makes never forgetting affordable.
		return
	owner_of[2] = strength

	var chunk := int(owner_of[0])
	var buf: PackedFloat32Array = _buffers[chunk]
	var b := int(owner_of[1]) * FLOATS_PER_MARK
	# Three rows of four: each row is the three basis axes' component on that
	# axis, then the origin's.
	buf[b + 0] = right.x
	buf[b + 1] = up.x
	buf[b + 2] = forward.x
	buf[b + 3] = point.x
	buf[b + 4] = right.y
	buf[b + 5] = up.y
	buf[b + 6] = forward.y
	buf[b + 7] = point.y
	buf[b + 8] = right.z
	buf[b + 9] = up.z
	buf[b + 10] = forward.z
	buf[b + 11] = point.z
	buf[b + 12] = 1.0
	buf[b + 13] = 1.0
	buf[b + 14] = 1.0
	buf[b + 15] = strength

	# Reassigned whole, which is the only way the buffer can be written — and the
	# reason marks are chunked. One chunk is 40 KB however many are down, and this
	# runs when a wheel has covered half a metre, so about ninety times a second
	# flat out rather than every frame.
	_chunks[chunk].multimesh.buffer = buf

## How many marks are on the road. For the suite and for diagnostics.
func mark_count() -> int:
	return _cells.size()
