extends SceneTree

# Regenerates main.tscn. Built programmatically rather than hand-edited so it
# carries no stale instance overrides - the previous one pinned
# center_of_mass to (0, -0.3, 0), which silently beat the corrected value in
# car.tscn because instance overrides win over the source scene.

func _initialize() -> void:
	var root_node := Node3D.new()
	root_node.name = "Main"

	var track: Node3D = load("res://scenes/track/track_02.tscn").instantiate()
	root_node.add_child(track)
	track.owner = root_node

	var spawn: Marker3D = track.get_node("SpawnPoint")

	var car: VehicleBody3D = load("res://scenes/car/car.tscn").instantiate()
	car.position = spawn.position
	car.rotation = spawn.rotation
	root_node.add_child(car)
	car.owner = root_node

	var cam: Camera3D = load("res://scenes/camera/chase_camera.tscn").instantiate()
	root_node.add_child(cam)
	cam.owner = root_node

	var overlay: CanvasLayer = load("res://scenes/ui/debug_overlay.tscn").instantiate()
	root_node.add_child(overlay)
	overlay.owner = root_node

	var packed := PackedScene.new()
	packed.pack(root_node)
	var err := ResourceSaver.save(packed, "res://scenes/main.tscn")
	print("main.tscn: %s | car spawn %s rot_y %.2f" % [
		"ok" if err == OK else "FAILED %s" % err, car.position, car.rotation.y
	])
	root_node.free()
	quit(0)
