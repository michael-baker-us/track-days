class_name GhostCar
extends Node3D

## Replays the best lap recorded on this circuit, alongside the one being driven.
##
## ## It is meshes and nothing else
##
## Built by stripping `car.tscn` down to its `MeshInstance3D`s, so what is added
## to the scene has **no collision body, no wheels and no script**. That is not
## just economy:
##
## - `car_controller` decides which way is up by casting a ray downwards, and
##   treats whatever it hits as the road it is standing on. A solid ghost would
##   be read as banking, exactly as the trackside props would be, which is why
##   those carry no collision either.
## - `lap_tracker` finds the car by the `player_car` group and the gates fire on
##   `body_entered`. A second physics body wearing the same shape would trip
##   sixteen checkpoints on its way round and time a lap nobody drove.
##
## ## It follows the lap clock, not its own
##
## Position comes from `tracker.lap_time`, so the ghost is wherever it was at the
## same point in *its* lap that the driver is at in theirs. Pausing stops both
## together, and a lap restarted at the line restarts the ghost with it. A ghost
## running on its own accumulator would drift apart from the thing it exists to
## be compared against, which is the one thing it must not do.

const COLOUR := Color(0.35, 0.75, 1.0, 0.35)

var _tracker: Node

func _ready() -> void:
	visible = false

func setup(tracker: Node) -> void:
	_tracker = tracker
	add_child(_build_visual())

## The recording is read from the tracker every frame rather than handed over
## once. Two reasons, and both are about *when* a ghost appears:
##
## - The tracker loads the stored one on its first physics frame, not in
##   `_ready`, because the checkpoints it binds to are instanced at runtime. A
##   ghost captured at setup time would always be null.
## - Setting a new best lap replaces it mid-session, and the next lap should
##   immediately be run against the new one.
func _physics_process(_delta: float) -> void:
	var ghost: Ghost = _tracker.ghost if _tracker != null else null
	# Hidden between laps as well as when there is nothing to show: a ghost that
	# finished its lap holds the finish line, and parking a translucent car on
	# the line while the driver sets off again reads as a bug.
	if ghost == null or ghost.is_empty() or not _tracker.timing:
		visible = false
		return
	visible = true
	transform = ghost.pose_at(_tracker.lap_time)

## The car's meshes, flattened onto one node at their world-relative transforms.
##
## Flattened rather than kept in their original hierarchy because that hierarchy
## is made of `VehicleWheel3D`s, which are physics nodes that would need a
## `VehicleBody3D` parent to sit under. The wheels therefore do not steer or
## spin. At the distance and opacity a ghost is seen at that is not worth a
## physics body to fix.
static func build_visual_from(car: Node) -> Node3D:
	var holder := Node3D.new()
	holder.name = "GhostBody"
	var material := StandardMaterial3D.new()
	material.albedo_color = COLOUR
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Unshaded to match the flat-shaded direction, and because a ghost reading as
	# a solid lit object is the opposite of what it is trying to say.
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_collect(car, Transform3D(), holder, material)
	return holder

func _build_visual() -> Node3D:
	var source: Node = load("res://scenes/car/car.tscn").instantiate()
	var visual := build_visual_from(source)
	source.free()
	return visual

## Walks with an explicit accumulated transform rather than reading
## `global_transform`. The car is instanced but never added to the tree -- it
## exists only to be copied from -- and `global_transform` is only meaningful for
## a node that is in one.
static func _collect(
	node: Node, so_far: Transform3D, holder: Node3D, material: Material
) -> void:
	for child in node.get_children():
		var here := so_far
		if child is Node3D:
			here = so_far * (child as Node3D).transform
		if child is MeshInstance3D:
			var copy := MeshInstance3D.new()
			copy.mesh = (child as MeshInstance3D).mesh
			copy.transform = here
			copy.material_override = material
			copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			holder.add_child(copy)
		_collect(child, here, holder, material)
