extends SceneTree

# Builds scenes/race.tscn: everything a race needs except the track, which
# race.gd instances at runtime from whatever the title screen selected. One
# race scene therefore serves every circuit.
#
# Built programmatically rather than hand-edited so it carries no stale instance
# overrides - an earlier hand-made main.tscn pinned center_of_mass to
# (0, -0.3, 0), which silently beat the corrected value in the car scene because
# instance overrides win over the source scene.
#
# The **car is no longer baked in either**, for the same reason the track is not:
# which car this is depends on what the title screen chose, so `race.gd`
# instances it at runtime from the selected `CarSpec`.

func _initialize() -> void:
	var root_node := Node3D.new()
	root_node.name = "Race"
	root_node.set_script(load("res://scripts/game/race.gd"))

	var cam: Camera3D = load("res://scenes/camera/chase_camera.tscn").instantiate()
	root_node.add_child(cam)

	# Tracker before the HUD so the HUD can find it; both look each other up by
	# group at runtime, so order only affects the first frame.
	var tracker := Node.new()
	tracker.name = "LapTracker"
	tracker.set_script(load("res://scripts/track/lap_tracker.gd"))
	root_node.add_child(tracker)

	var hud: CanvasLayer = load("res://scenes/ui/hud.tscn").instantiate()
	root_node.add_child(hud)

	var overlay: CanvasLayer = load("res://scenes/ui/debug_overlay.tscn").instantiate()
	root_node.add_child(overlay)

	# Owner is set only on the direct children, never recursively. These are
	# instanced sub-scenes; giving their *internal* nodes an owner makes
	# PackedScene write them out as explicit nodes on top of the instance, which
	# silently duplicates them - the car came back with eight wheels.
	for child in root_node.get_children():
		child.owner = root_node

	var packed := PackedScene.new()
	packed.pack(root_node)
	var err := ResourceSaver.save(packed, "res://scenes/race.tscn")
	print("race.tscn: %s" % ("ok" if err == OK else "FAILED %s" % err))
	root_node.free()
	quit(0)
