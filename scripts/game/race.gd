extends Node3D

## Loads whichever track was chosen on the title screen, drops the car on its
## start line, and points the lap tracker at that track's record.
##
## The track is instanced here rather than baked into race.tscn so one race
## scene serves every circuit — including the ones the player built, which have
## no scene file at all and are constructed on the spot from their layout.

@onready var _tracker: Node = $LapTracker

## Instanced at runtime rather than baked into race.tscn, for the same reason the
## track is: which car this is depends on what the title screen chose, and one
## race scene serves every combination.
var _car: VehicleBody3D

func _ready() -> void:
	ViewportScaling.attach(get_window())

	var track_info: Dictionary = GameState.selected()
	_tracker.track_id = track_info["id"]

	var track: Node3D = _make_track(track_info)
	track.name = "Track"
	# Done here rather than in the builder because a surface override set on an
	# instanced tile does not survive being packed into a .tscn — see
	# TrackBuilder.surface_road. Applying it on load treats a shipped circuit and
	# a player's the same way.
	TrackBuilder.surface_road(track, GameState.selected_surface)
	# Ahead of the car so the car keeps rendering order and group lookups work.
	add_child(track)
	move_child(track, 0)

	_car = load(GameState.selected_car_spec().scene_path()).instantiate()
	_car.name = "Car"
	_tint_car_rim(_car, String(track_info["id"]))
	# The hour, handed over rather than worked out. See car_lights.gd: scene
	# brightness cannot order the hours, because dusk carries a *higher* ambient
	# than noon on purpose.
	var beams := _car.get_node_or_null("Headlights") as CarLights
	if beams != null:
		beams.set_hour(float(track.get_meta("headlights", 0.0)))
	add_child(_car)

	var spawn: Marker3D = track.get_node("SpawnPoint")
	_place_car(spawn.position, spawn.rotation.y)

	_add_ghost()

## Points the car's rim light at the hour this circuit is raced at.
##
## Set here rather than baked into the car, because one car scene is driven on
## every circuit and the rim is meant to pick up the *sky* — a car edged in noon
## blue on Monte Carlo's sunset would read as belonging to a different scene.
##
## Converted to linear on the way in, for the same reason the sky's colours are:
## a shader uniform is used as radiance and `set_shader_parameter` converts
## nothing, while the `Color` properties it replaced converted internally. See
## `docs/architecture.md`.
func _tint_car_rim(car: Node, track_id: String) -> void:
	var rim: Color = SkyPreset.for_track(track_id)["horizon"]
	for node in car.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (node as MeshInstance3D).mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i) as ShaderMaterial
			if mat != null:
				mat.set_shader_parameter("rim_color", rim.srgb_to_linear())

## The recorded best lap, if there is one, as a translucent car to chase.
##
## Added here rather than baked into race.tscn because whether there is a ghost
## at all depends on which circuit was picked and whether it has ever been
## driven — and because the tracker has to have loaded one first. It is created
## even when empty so that a best lap set *during* this session has something to
## play back on the next lap without the scene being rebuilt.
func _add_ghost() -> void:
	var ghost_car := GhostCar.new()
	ghost_car.name = "GhostCar"
	add_child(ghost_car)
	ghost_car.setup(_tracker)

## A shipped circuit is a packed scene; a custom one is built here from its grid
## layout by the same builder that baked the shipped ones, so the two are made
## of identical geometry and everything downstream — lap gates, collision ribbon,
## spawn point — is unaware of the difference.
func _make_track(track_info: Dictionary) -> Node3D:
	if track_info.has("scene"):
		return load(track_info["scene"]).instantiate()
	var layout: TrackLayout = track_info["layout"]
	var compiled := layout.compile()
	return TrackBuilder.new().build(
		layout.id, compiled.segments, true, layout.look
	).root

## Leaving a race is `scripts/ui/pause_menu.gd`'s job, not this scene's. It used
## to happen here, the instant Escape was pressed — fine on a keyboard, wrong on
## a pad where B sits under the thumb, and impossible on a phone, which had no
## way out at all. One mis-press threw away the lap being driven.

func _place_car(pos: Vector3, yaw: float) -> void:
	_car.global_transform = Transform3D(Basis(Vector3.UP, yaw), pos)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
