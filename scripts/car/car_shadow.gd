class_name CarShadow
extends MeshInstance3D

## A soft patch of dark that follows the car onto whatever it is standing on.
##
## ## Why the car needs one when it already casts a shadow
##
## It casts onto the *road*, and onto nothing else. `ground_grid.gdshader` is
## `unshaded` — deliberately, because flat and bright grass is the look and a lit
## ground plane would sink it into shading gradients this style does not want (see
## `docs/architecture.md`). Unshaded means it receives no shadow, so the moment
## the car runs wide its shadow vanishes and it appears to float.
##
## `docs/ideas.md` reaches the same conclusion from the other direction: what is
## missing is not global shading but *one reliable shadow*, and the fix is a blob
## that works regardless of what is underneath.
##
## ## Why it is `top_level`
##
## It is a child of the car so it travels with it and is built once per car, but
## it must not inherit the car's transform: the body rolls, pitches and leaves the
## ground, and a shadow that did any of those would be a dark rectangle waving
## about under the car. `top_level` detaches it from the parent transform and it
## is placed in world space every physics frame instead.
##
## ## Why it is placed by raycast rather than dropped to y = 0
##
## The circuits climb, bank and — on Suzuka — cross over themselves. Dropping the
## shadow to the ground plane would leave it under the road on an elevated
## section and buried in the embankment on a banked corner. The ray finds the
## surface actually beneath the car, which is the same question
## `car_controller._surface_up` asks and answers the same way.

## How far below the car to look. Beyond this the car is airborne as far as this
## is concerned, which is roughly where the shadow should have faded out anyway.
const PROBE := 4.0

## Clear of the surface, so it does not fight the road for the depth buffer. The
## shader also never writes depth, which is what actually settles it; this is
## belt and braces for surfaces at a steep angle.
const LIFT := 0.03

## Footprint, in metres. Wider than the car so the falloff has room to happen
## inside the quad rather than being clipped by its edge.
const SIZE := Vector2(2.0, 3.6)

## Height at which the shadow has faded out entirely.
const FADE_OVER := 2.5

var _material: ShaderMaterial
var _car: Node3D

func _ready() -> void:
	_car = get_parent() as Node3D
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material = material_override as ShaderMaterial
	visible = false

func _physics_process(_delta: float) -> void:
	if _car == null or _material == null:
		return
	var space := get_world_3d().direct_space_state
	var from: Vector3 = _car.global_transform.origin
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * PROBE)
	# The car itself, or the ray starts inside its own collision box and hits it.
	query.exclude = [(_car as PhysicsBody3D).get_rid()] if _car is PhysicsBody3D else []
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		visible = false
		return

	var point: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	# The collision ribbon is two-sided, so a hit from underneath reports an
	# inverted normal — the same correction `car_controller._surface_up` makes.
	if normal.dot(Vector3.UP) < 0.0:
		normal = -normal

	# Flattened onto the surface: the car's heading projected into the surface
	# plane, so the shadow points where the car does without tipping with it.
	var forward := _car.global_transform.basis.z
	forward = (forward - normal * forward.dot(normal))
	if forward.length() < 0.001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var right := normal.cross(forward).normalized()

	global_transform = Transform3D(
		Basis(right, normal, forward), point + normal * LIFT
	)
	visible = true
	# Fainter and no larger as the car lifts: a shadow that grew would read as the
	# car sinking rather than rising.
	var height: float = from.distance_to(point)
	_material.set_shader_parameter(
		"fade", clampf(1.0 - height / FADE_OVER, 0.0, 1.0)
	)
