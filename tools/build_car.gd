extends SceneTree

# Builds scenes/car/car.tscn: the VehicleBody3D, its collision box, four
# VehicleWheel3D and the visual meshes lifted out of race.glb.
#
# This used to be a hand-made scene with the meshes baked in, and the bake lost
# the material's link to the kit's shared palette atlas — every surface sampled
# nothing and the whole car, tyres and glass included, rendered flat white. The
# wheel meshes came out of that bake with no UVs at all, so the scene could not
# be repaired by pointing the material at the texture; it had to be rebuilt from
# the source mesh. Hence this script.
#
# Geometry here is *load-bearing*: the wheel positions, radii and rest length
# are what docs/tuning-journal.md measured the handling against, and the
# collision box and centre of mass were both arrived at by fixing specific bugs
# (see the journal on wheel hop and body roll). Changing a number in this file
# changes how the car drives. The visuals are the only part meant to be edited
# freely.

## How far the body sits above the wheel line, and how much suspension travel the
## wheels are given. Both measured in M1 and unchanged since; unlike the rest of
## the geometry they are *decisions* rather than facts about the art, so they stay
## here rather than being read out of a `.glb`.
const BODY_LIFT := 0.1
const WHEEL_REST_LENGTH := 0.1

## Kenney paints every model from one 512x512 palette atlas, referenced by the
## GLBs as an external file. Only the .glb files were vendored originally, so the
## texture was missing and the material fell back to untextured white.
const COLORMAP := "res://assets/kenney/car_kit/Textures/colormap.png"
const BODY_SHADER := "res://assets/shaders/car_body.gdshader"

## Every car the garage offers. The geometry is *not* here: it is measured out of
## each spec's own model, which reproduces the constants this file used to
## hard-code exactly. See `CarSpec`.
const SPECS := [
	"res://resources/cars/race.tres",
	"res://resources/cars/race_future.tres",
]

func _initialize() -> void:
	var failed := false
	for path in SPECS:
		if not _bake(load(path)):
			failed = true
	quit(1 if failed else 0)

func _bake(spec: CarSpec) -> bool:
	var source: Node3D = load(spec.source).instantiate()
	var mat := _material()

	var car := VehicleBody3D.new()
	car.name = "Car"
	car.mass = spec.mass
	# Custom rather than computed: the computed centre sat high enough that the
	# inside wheels hopped in a turn. The custom value is the (0, 0, 0) default,
	# which is body centre — deliberately, not by omission.
	car.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	car.set_script(load("res://scripts/car/car_controller.gd"))
	car.tuning = spec.tuning

	var body_mesh := _find_mesh(source, "body")
	if body_mesh == null:
		push_error("%s has no 'body' mesh" % spec.source)
		source.free()
		car.free()
		return false
	var body_size := body_mesh.mesh.get_aabb().size

	var body := _mesh_copy(source, "body", mat)
	body.name = "body"
	body.position = Vector3(0.0, BODY_LIFT, 0.0)
	car.add_child(body)

	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = body_size
	col.shape = box
	col.position = Vector3(0.0, BODY_LIFT + body_size.y * 0.5, 0.0)
	car.add_child(col)

	# Wheels, front pair first and left before right, because the GLBs list them
	# in whatever order they were authored in and two builds of the same car have
	# to produce the same scene. This particular order is not arbitrary: it is the
	# one the hand-written constants used, so regenerating `race` reproduces the
	# committed scene exactly rather than merely equivalently.
	var wheels := []
	for child in source.get_children():
		if child is MeshInstance3D and String(child.name).begins_with("wheel"):
			wheels.append(child)
	wheels.sort_custom(func(a, b): return _wheel_order(a) < _wheel_order(b))
	if wheels.size() != 4:
		push_error("%s has %d wheels, expected 4" % [spec.source, wheels.size()])
		source.free()
		car.free()
		return false

	for mesh_node: MeshInstance3D in wheels:
		var mesh_name := String(mesh_node.name)
		# "wheel-front-left" -> "WheelFrontLeft", so the built scene reads the way
		# it always has and the front/back split comes from the art's own naming.
		var node_name := ""
		for part in mesh_name.split("-"):
			node_name += String(part).capitalize()
		var steers := mesh_name.contains("front")

		var wheel := VehicleWheel3D.new()
		wheel.name = node_name
		wheel.position = mesh_node.position
		wheel.use_as_steering = steers
		wheel.use_as_traction = not steers
		# A wheel is a disc in the XZ-facing plane, so its radius is half its
		# larger cross-section — read off the art rather than assumed, which is
		# what lets a car with different wheels arrive without an edit here.
		var wheel_box := mesh_node.mesh.get_aabb().size
		wheel.wheel_radius = maxf(wheel_box.y, wheel_box.z) * 0.5
		wheel.wheel_rest_length = WHEEL_REST_LENGTH
		car.add_child(wheel)

		# Parented to the wheel, not the body, so it turns with the steering and
		# rises with the suspension travel.
		var mi := _mesh_copy(source, mesh_name, mat)
		mi.name = mesh_name
		wheel.add_child(mi)

	car.add_child(_audio())
	car.add_child(_shadow())
	# What the tyres leave behind. A plain node like the others; it configures
	# itself from the surface being raced on when it enters the tree.
	var marks := MultiMeshInstance3D.new()
	marks.name = "TyreMarks"
	marks.set_script(load("res://scripts/car/tyre_marks.gd"))
	car.add_child(marks)

	TrackBuilder.set_owner_recursive(car, car)

	var packed := PackedScene.new()
	packed.pack(car)
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://scenes/car")
	)
	var err := ResourceSaver.save(packed, spec.scene_path())
	print("%s: %s (%d nodes, body %.3f x %.3f x %.3f)" % [
		spec.scene_path().get_file(), "ok" if err == OK else "FAILED %s" % err,
		_count(car), body_size.x, body_size.y, body_size.z,
	])
	source.free()
	car.free()
	return err == OK

func _wheel_order(node: Node) -> String:
	var mesh_name := String(node.name)
	return ("0" if mesh_name.contains("front") else "1") + mesh_name

func _find_mesh(source: Node3D, mesh_name: String) -> MeshInstance3D:
	for child in source.get_children():
		if child is MeshInstance3D and String(child.name) == mesh_name:
			return child
	return null

const SHADOW_SHADER := "res://assets/shaders/car_shadow.gdshader"

## The patch of dark under the car. Built here rather than at runtime so it is in
## the committed scene like everything else, and as a plain node rather than an
## instanced sub-scene — setting `owner` on an instance's internals is the trap
## that once shipped this car with eight wheels.
##
## A `PlaneMesh` rather than a `QuadMesh`: a quad faces +Z and would need
## rotating flat, and `car_shadow.gd` builds the basis itself from the surface
## normal. A plane is already in the XZ plane, which is the orientation that
## basis produces.
func _shadow() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Shadow"
	mi.set_script(load("res://scripts/car/car_shadow.gd"))
	var plane := PlaneMesh.new()
	plane.size = CarShadow.SIZE
	mi.mesh = plane
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADOW_SHADER)
	mi.material_override = mat
	return mi

const ENGINE_STREAM := "res://resources/audio/engine.tres"
const TYRE_STREAM := "res://resources/audio/tyre.tres"

## The engine note and the tyre scrub, as children of the car so they travel with
## it and are positioned in 3D by being where the car is.
##
## `PROCESS_MODE_ALWAYS` is load-bearing rather than incidental: audio does not
## stop when `get_tree().paused` is set, so something has to keep running in
## order to silence it, and a node that paused with everything else could not.
## Same reasoning as the pause menu, which runs always so it can dismiss itself.
##
## Plain nodes, not an instanced sub-scene. Setting `owner` on the internals of
## an instance makes them serialise on top of it and everything appears twice —
## the trap that once shipped this car with eight wheels.
func _audio() -> Node3D:
	var holder := Node3D.new()
	holder.name = "Audio"
	holder.process_mode = Node.PROCESS_MODE_ALWAYS
	holder.set_script(load("res://scripts/car/car_audio.gd"))

	# Node names must match the @onready paths in scripts/car/car_audio.gd.
	holder.add_child(_player("Engine", ENGINE_STREAM, 34.0))
	holder.add_child(_player("Tyre", TYRE_STREAM, 26.0))
	return holder

## `unit_size` is how far the sound carries. The engine is set well beyond the
## chase camera's ~4 m so the car does not fade as the camera lags behind it in a
## corner; the tyres are nearer, because scrub is a thing happening at the
## contact patches rather than a thing filling the scene.
func _player(node_name: String, stream_path: String, unit_size: float) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = node_name
	player.stream = load(stream_path)
	player.unit_size = unit_size
	# Started muted by `car_audio.gd`'s first update; without this the first
	# frame is a full-volume blip before anything has been worked out.
	player.volume_db = -80.0
	return player

## One material shared by every surface, mirroring how the kit is authored: the
## mesh UVs pick a flat swatch out of the atlas, so there is nothing per-part to
## vary.
##
## A `ShaderMaterial` rather than a `StandardMaterial3D`, for one addition: a
## fresnel rim tinted towards the sky, which is what gives a flat-coloured car a
## silhouette against a flat-coloured road at speed. Everything else the standard
## material was doing — the atlas, nearest filtering, double-sided, flat paint —
## the shader does identically. See assets/shaders/car_body.gdshader.
##
## The rim *colour* is not set here. It belongs to the hour the circuit is raced
## at, and one car scene is driven on all of them, so `race.gd` sets it when it
## instances the car.
func _material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.resource_name = "colormap"
	mat.shader = load(BODY_SHADER)
	mat.set_shader_parameter("albedo_texture", load(COLORMAP))
	return mat

## Copies a mesh out of the imported GLB and detaches it from it. `duplicate`
## clears `resource_path`, which is what makes PackedScene write the mesh into
## car.tscn instead of referencing the file under .godot/imported — a cache
## directory that is neither committed nor stable.
func _mesh_copy(source: Node3D, mesh_name: String, mat: Material) -> MeshInstance3D:
	var src: MeshInstance3D = source.get_node(mesh_name)
	var mesh: ArrayMesh = src.mesh.duplicate()
	for i in mesh.get_surface_count():
		mesh.surface_set_material(i, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi

func _count(n: Node) -> int:
	var total := 1
	for c in n.get_children():
		total += _count(c)
	return total
