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

## Straight off race.glb's own AABB — the box is the body's bounding volume, and
## it sits at half its own height so it rests on the ground rather than sinking.
const BODY_SIZE := Vector3(1.2, 0.6325443, 2.5597725)
const BODY_LIFT := 0.1

## Kenney's kit paints every model from one 512x512 palette atlas, referenced by
## the GLBs as an external file. Only the .glb files were vendored originally, so
## the texture was missing and the material fell back to untextured white.
const COLORMAP := "res://assets/kenney/car_kit/Textures/colormap.png"

const SOURCE := "res://assets/kenney/car_kit/race.glb"
const OUTPUT := "res://scenes/car/car.tscn"

## Front wheels steer, rear wheels drive. Positions are the source model's own
## wheel origins, so the visuals line up with the suspension that carries them.
const WHEELS := [
	{"name": "WheelFrontLeft", "mesh": "wheel-front-left", "pos": Vector3(0.35, 0.3, 0.6398862), "steer": true},
	{"name": "WheelFrontRight", "mesh": "wheel-front-right", "pos": Vector3(-0.35, 0.3, 0.6398862), "steer": true},
	{"name": "WheelBackLeft", "mesh": "wheel-back-left", "pos": Vector3(0.35, 0.3, -0.8801137), "steer": false},
	{"name": "WheelBackRight", "mesh": "wheel-back-right", "pos": Vector3(-0.35, 0.3, -0.8801137), "steer": false},
]

const WHEEL_RADIUS := 0.3
const WHEEL_REST_LENGTH := 0.1

func _initialize() -> void:
	var source: Node3D = load(SOURCE).instantiate()
	var mat := _material()

	var car := VehicleBody3D.new()
	car.name = "Car"
	# The default of 1.0 kg is unusable; see docs/tuning-journal.md.
	car.mass = 1200.0
	# Custom rather than computed: the computed centre sat high enough that the
	# inside wheels hopped in a turn. The custom value is the (0, 0, 0) default,
	# which is body centre — deliberately, not by omission.
	car.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	car.set_script(load("res://scripts/car/car_controller.gd"))
	car.tuning = load("res://resources/tuning/grippy.tres")

	var body := _mesh_copy(source, "body", mat)
	body.name = "body"
	body.position = Vector3(0.0, BODY_LIFT, 0.0)
	car.add_child(body)

	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = BODY_SIZE
	col.shape = box
	col.position = Vector3(0.0, BODY_LIFT + BODY_SIZE.y * 0.5, 0.0)
	car.add_child(col)

	for spec in WHEELS:
		var wheel := VehicleWheel3D.new()
		wheel.name = spec["name"]
		wheel.position = spec["pos"]
		wheel.use_as_steering = spec["steer"]
		wheel.use_as_traction = not spec["steer"]
		wheel.wheel_radius = WHEEL_RADIUS
		wheel.wheel_rest_length = WHEEL_REST_LENGTH
		car.add_child(wheel)

		# Parented to the wheel, not the body, so it turns with the steering and
		# rises with the suspension travel.
		var mi := _mesh_copy(source, spec["mesh"], mat)
		mi.name = spec["mesh"]
		wheel.add_child(mi)

	car.add_child(_audio())

	TrackBuilder.set_owner_recursive(car, car)

	var packed := PackedScene.new()
	packed.pack(car)
	var err := ResourceSaver.save(packed, OUTPUT)
	print("car.tscn: %s (%d nodes)" % ["ok" if err == OK else "FAILED %s" % err, _count(car)])
	source.free()
	car.free()
	quit(0 if err == OK else 1)

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
## vary. Nearest filtering because neighbouring swatches are unrelated colours
## and linear sampling blends them into seams along every UV island edge.
func _material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = "colormap"
	mat.albedo_texture = load(COLORMAP)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	# The source model is authored double-sided; the windscreen is single-sided
	# geometry and disappears from one side without this.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.metallic = 0.0
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
