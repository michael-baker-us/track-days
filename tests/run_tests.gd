extends SceneTree

## Headless test suite. Run with:
##   godot --headless --path . --script tests/run_tests.gd
## Exits non-zero on failure, so CI can gate on it.
##
## Deliberately a small hand-rolled runner rather than GUT: the whole suite is
## scene- and physics-dependent, it needs no fixtures or mocking, and this keeps
## the project free of a vendored addon. Worth swapping to GUT if the suite
## grows past what a single staged script can express.

var failures: Array[String] = []
var checks := 0

var tracker: Node
var gates: Array = []
var laps: Array = []
var frame := 0
var step := 0

var custom_track: Node3D
var sustained_track: Node3D
## Staged a few frames ahead of its assertions: containers only lay out
## some frames after a scene is added, so sizes are not final immediately.
var staged_title: Control
var staged_track_ids: Array[String] = []
var staged_editor: Control
## Editor canvas framing recorded before a resize, to compare with after it.
var view_centre_before := Vector2.ZERO
var view_zoom_before := Vector2.ZERO
## Every editor control and its place in its row, taken while the editor is still
## in its landscape arrangement.
var editor_layout_before := {}
## Frames the stale-rotation recovery was staged on and noticed on.
var stale_staged_at := 0
var stale_fixed_at := 0
## Lap clock reading taken just before pausing.
var paused_lap_time := 0.0

func _initialize() -> void:
	# race.tscn instances whichever track GameState has selected, so the suite
	# exercises the same path the title screen uses.
	GameState.selected_index = 0
	# Never write to the player's real records; the suite completes laps, which
	# would otherwise leave a bogus best time on the title screen.
	GameState.records_path = "user://test_records.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.records_path))
	# Likewise never write into the player's saved circuits, or over the ghosts of
	# their best laps -- the suite completes laps, so it records both.
	TrackStore.dir = "user://test_tracks"
	_clear_dir(TrackStore.dir)
	GhostStore.dir = "user://test_ghosts"
	_clear_dir(GhostStore.dir)
	root.add_child(load("res://scenes/race.tscn").instantiate())

func _clear_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(f)))

## A hand-written painted loop with an inward kink, so it exercises more than a
## rectangle: eight corners, both handednesses, and runs of differing length.
func sample_layout() -> TrackLayout:
	var layout := TrackLayout.new()
	var cells: Array[Vector2i] = []
	var p := Vector2i(0, 0)
	for move in [
		[Vector2i(1, 0), 14], [Vector2i(0, 1), 5], [Vector2i(1, 0), 6],
		[Vector2i(0, 1), 7], [Vector2i(-1, 0), 9], [Vector2i(0, -1), 4],
		[Vector2i(-1, 0), 11], [Vector2i(0, -1), 8],
	]:
		for i in int(move[1]):
			cells.append(p)
			p += move[0] as Vector2i
	layout.cells = cells
	layout.start_cell = Vector2i(6, 0)
	layout.display_name = "Test Circuit"

	# Banked on purpose, and stated rather than inherited — corners are flat by
	# default now. This is the circuit that gets built into the physics world, so
	# banking it here is what puts a banked collision surface under a real car for
	# `test_banked_collision_leans_into_the_corner` to raycast.
	for corner in layout.compile().corners:
		layout.corner_banks[corner.cell] = TrackBuilder.MAX_BANK_LEVEL
	return layout

# --- assertions ---

func check(label: String, got, want) -> void:
	checks += 1
	if got != want:
		failures.append("%s: got %s, want %s" % [label, got, want])

func check_true(label: String, got: bool) -> void:
	check(label, got, true)

func check_near(label: String, got: float, want: float, tol: float) -> void:
	checks += 1
	if absf(got - want) > tol:
		failures.append("%s: got %.3f, want %.3f (+/-%.3f)" % [label, got, want, tol])

# --- tests that need no physics ---

func test_time_formatting() -> void:
	var t: Node = tracker
	check("format zero", t.format_time(0.0), "--:--.---")
	check("format negative", t.format_time(-1.0), "--:--.---")
	check("format 65.5s", t.format_time(65.5), "1:05.500")
	check("format 9.25s", t.format_time(9.25), "0:09.250")

## Every preset in the project, not a list of the ones that existed when this was
## written.
##
## It named `grippy` and `drifty` explicitly, so the Prototype's preset arrived
## with the garage and was checked by nothing — including the handbrake rule,
## which has silently turned the handbrake into a *grip aid* once already. A
## garage means presets get added, so the test has to find them.
func test_tuning_invariants() -> void:
	var paths := []
	var dir := DirAccess.open("res://resources/tuning")
	if dir != null:
		for file in dir.get_files():
			if file.ends_with(".tres"):
				paths.append("res://resources/tuning/%s" % file)
	check_true("presets were found to check (%d)" % paths.size(), paths.size() >= 3)
	# And every car's preset is among them, so a spec pointing somewhere else
	# cannot slip past.
	for spec in GameState.cars():
		check_true("%s's preset is checked" % spec.id,
			paths.has(spec.tuning.resource_path))

	for path in paths:
		var tuning: CarTuning = load(path)
		var name: String = String(path).get_file()
		# The handbrake works by *cutting* rear grip. Setting it above rear grip
		# silently turns the handbrake into a grip aid; this has happened once.
		check_true("%s handbrake below rear grip" % name,
			tuning.handbrake_rear_friction < tuning.friction_rear)
		# Braking saturates around 150; above that it is traction-limited and
		# stopping becomes an instant, unmodulated jolt.
		check_true("%s brake below saturation" % name, tuning.brake_force < 150.0)
		check_true("%s rear grip >= front" % name,
			tuning.friction_rear >= tuning.friction_front or name == "drifty.tres")
		check_true("%s has drag" % name, tuning.drag_coefficient > 0.0)

func test_car_wired_to_tuning() -> void:
	var car: Node = get_first_node_in_group("player_car")
	check_true("car exists", car != null)
	check_true("car has tuning", car != null and car.tuning != null)
	# Suspension must actually be applied from the resource, not left at Godot's
	# defaults, which are far too soft for a 1200 kg body.
	for wheel in car.get_children():
		if wheel is VehicleWheel3D:
			check_near("wheel stiffness from tuning",
				wheel.suspension_stiffness, car.tuning.suspension_stiffness, 0.01)
			break

## Records written by an older build have to survive the move to a composite key.
##
## Version 1 kept one flat `best_<track>` per circuit in a `[records]` section.
## Those times are the only thing the game saves, so dropping them here would be
## dropping everything a player has to show for playing it.
func test_old_records_migrate_to_the_composite_key() -> void:
	var path := "user://test_migration.cfg"
	var old := ConfigFile.new()
	old.set_value("records", "best_ardennes", 91.5)
	old.set_value("records", "best_user_my_track", 42.25)
	old.save(path)

	var real_path := GameState.records_path
	GameState.records_path = path
	check_near("old record survives", GameState.best_lap_for("ardennes"), 91.5, 0.001)
	check_near("and a custom circuit's too",
		GameState.best_lap_for("user_my_track"), 42.25, 0.001)

	# Rewritten on disk, not merely read through. A migration that only ever
	# happened in memory would run on every launch, and would leave the old
	# section behind to shadow whatever the new one later said.
	var after := ConfigFile.new()
	after.load(path)
	check("old section gone", after.has_section("records"), false)
	check("version stamped", int(after.get_value("meta", "version", 1)),
		GameState.RECORDS_VERSION)
	check_true("moved to the new key", after.has_section_key(
		GameState.record_section("ardennes"),
		GameState.record_key(GameState.DEFAULT_CAR, GameState.DEFAULT_SURFACE)))

	GameState.records_path = real_path
	GameState.forget_cached_settings()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

## Two cars on one circuit are two records, and deleting the circuit takes both.
func test_records_are_kept_per_car_and_surface() -> void:
	var track := "test_keying"
	GameState.save_best_lap(track, 60.0, PackedFloat32Array(), "hatchback", "tarmac")
	GameState.save_best_lap(track, 48.0, PackedFloat32Array(), "kart", "tarmac")
	check_near("one car's time", GameState.best_lap_for(track, "hatchback", "tarmac"),
		60.0, 0.001)
	check_near("the other's, separately",
		GameState.best_lap_for(track, "kart", "tarmac"), 48.0, 0.001)
	check_near("a surface never driven has no time",
		GameState.best_lap_for(track, "kart", "snow"), 0.0, 0.001)

	# Why the track is a section rather than part of one flat key: ids are drawn
	# from [a-z0-9_], so `best_test_keying_kart` reads equally well as the kart on
	# "test keying" and as the default car on "test keying kart". This is that
	# collision, and it must not be one.
	GameState.save_best_lap("test_keying_kart", 12.0, PackedFloat32Array(), "default", "tarmac")
	check_near("a circuit named after a car keeps its own record",
		GameState.best_lap_for("test_keying_kart", "default", "tarmac"), 12.0, 0.001)
	check_near("and did not stand on the kart's time",
		GameState.best_lap_for(track, "kart", "tarmac"), 48.0, 0.001)

	# Ids are handed straight back out once a file is gone, so a time left behind
	# is inherited by the next circuit named the same thing.
	GameState.clear_best_lap(track)
	check_near("every car's time goes with the circuit",
		GameState.best_lap_for(track, "hatchback", "tarmac"), 0.0, 0.001)
	check_near("including the second car's",
		GameState.best_lap_for(track, "kart", "tarmac"), 0.0, 0.001)
	check_near("and the circuit next to it is untouched",
		GameState.best_lap_for("test_keying_kart", "default", "tarmac"), 12.0, 0.001)

## The stored default is analogue, so only the *false* case proves anything came
## back off disk rather than out of an uninitialised variable. That is the one
## worth asserting.
func test_the_throttle_setting_survives_a_restart() -> void:
	GameState.set_analogue_input(false)
	# What a relaunch does: drop the cache, so the answer has to be read again.
	GameState.forget_cached_settings()
	check("binary persisted", GameState.analogue_input(), false)
	GameState.set_analogue_input(true)
	GameState.forget_cached_settings()
	check("analogue persisted", GameState.analogue_input(), true)

## How far the trigger is pulled has to reach engine force -- the travel was
## previously read through `is_action_pressed` and thrown away.
##
## Driven with `Input.action_press`, which sets the action's strength there and
## then, and stepped by calling `_physics_process` directly. Both so the
## assertion sits one call after the press, and so nothing is left held for the
## scripted lap sequence later in this suite to drive into.
func test_partial_throttle_reaches_the_engine() -> void:
	var car: Node = get_first_node_in_group("player_car")
	var full: float = car.tuning.engine_force
	var step_delta := 1.0 / 120.0

	GameState.set_analogue_input(true)
	Input.action_press("accelerate", 0.5)
	car._physics_process(step_delta)
	check_near("half a trigger is half the force", car.engine_force, full * 0.5,
		full * 0.02)

	# The whole point of offering the setting: the same half-pull commits to
	# everything the engine has.
	GameState.set_analogue_input(false)
	car._physics_process(step_delta)
	check_near("binary does not care how far", car.engine_force, full, 0.01)

	Input.action_release("accelerate")
	GameState.set_analogue_input(true)
	# Back to a standing start, or the car drives itself away from the grid while
	# the rest of the suite is measuring where it sits.
	car._physics_process(step_delta)
	check_near("nothing left held", car.engine_force, 0.0, 0.01)

## The steering curve is an odd power, so it fixes -1, 0 and 1 -- and a keyboard
## or a touch pad only ever asks for those three. That is what lets it be added
## without invalidating a tuning journal measured entirely at full lock, so it is
## worth asserting rather than reasoning about.
func test_the_steering_curve_leaves_full_lock_alone() -> void:
	var car: Node = get_first_node_in_group("player_car")
	check_true("the curve is doing something", car.tuning.steer_response_curve > 1.0)
	check_near("full right is still full right", car._curve(1.0), 1.0, 0.0001)
	check_near("full left is still full left", car._curve(-1.0), -1.0, 0.0001)
	check_near("centre is still centre", car._curve(0.0), 0.0, 0.0001)
	check_true("half a stick asks for less than half lock", car._curve(0.5) < 0.5)
	check_true("and asks in the same direction", car._curve(-0.5) < 0.0)

## The grade is baked into each shipped circuit by `_build_lighting`, so a
## palette change that was not followed by re-running `tools/build_track.gd`
## would ship three circuits wearing the old look. Same reasoning as the check
## that the committed theme still matches its source.
func test_shipped_circuits_carry_the_colour_grade() -> void:
	for entry in GameState.TRACKS:
		var id: String = entry["id"]
		var circuit: Node3D = load(entry["scene"]).instantiate()
		var env: Environment = (circuit.get_node("WorldEnvironment") as WorldEnvironment).environment
		check_true("%s is graded" % id, env.adjustment_enabled)
		check_near("%s saturation" % id, env.adjustment_saturation,
			TrackBuilder.GRADE_SATURATION, 0.001)
		check_near("%s contrast" % id, env.adjustment_contrast,
			TrackBuilder.GRADE_CONTRAST, 0.001)
		# Fog exists to land the 4 km ground plane into the sky, which it can only
		# do while it is the colour the sky is at that edge. They are one horizon
		# seen twice, so they are read from one constant.
		check_true("%s fog is the sky's horizon" % id,
			env.fog_light_color.is_equal_approx(TrackBuilder.SKY_HORIZON))
		circuit.free()

func _sample_ghost() -> Ghost:
	var ghost := Ghost.new()
	for i in 5:
		ghost.add(Transform3D(
			Basis(Vector3.UP, float(i) * 0.25), Vector3(float(i), 1.0, float(i) * 2.0)
		))
	return ghost

## A ghost is written as bytes, so the write and the read have to agree exactly.
## A lap that came back subtly wrong would look like a driving mistake rather
## than a broken file, which is the reason to pin this rather than trust it.
func test_a_ghost_round_trips_through_bytes() -> void:
	var original := _sample_ghost()
	var restored := Ghost.from_bytes(original.to_bytes())
	check_true("a ghost survives the trip", restored != null)
	if restored == null:
		return
	check("same number of samples", restored.count(), original.count())
	check_near("same duration", restored.duration(), original.duration(), 0.0001)
	for i in original.count():
		var want := original.pose_at(float(i) / Ghost.HZ)
		var got := restored.pose_at(float(i) / Ghost.HZ)
		check_true("sample %d position" % i,
			got.origin.is_equal_approx(want.origin))
		check_true("sample %d rotation" % i, absf(
			got.basis.get_rotation_quaternion().dot(
				want.basis.get_rotation_quaternion())
		) > 0.9999)

## Ghosts are files, and `docs/roadmap.md` M11 puts them inside share codes, so
## they will eventually arrive from other people. Every way one can be wrong has
## to end at null rather than at a half-loaded lap.
func test_a_damaged_ghost_is_refused() -> void:
	var good := _sample_ghost().to_bytes()

	check("empty", Ghost.from_bytes(PackedByteArray()), null)
	check("too short to hold a header", Ghost.from_bytes(good.slice(0, 8)), null)
	check("truncated body", Ghost.from_bytes(good.slice(0, good.size() - 4)), null)
	var padded := good.duplicate()
	padded.append(0)
	check("padded body", Ghost.from_bytes(padded), null)

	var wrong_magic := good.duplicate()
	wrong_magic.encode_u32(0, 0x4B4F4F4C)
	check("not one of ours", Ghost.from_bytes(wrong_magic), null)

	var future := good.duplicate()
	future.encode_u32(4, Ghost.VERSION + 1)
	check("from a later version", Ghost.from_bytes(future), null)

	# A count the body cannot possibly match. Checked because it is the field an
	# allocation is sized from, so believing it is the expensive mistake.
	var absurd := good.duplicate()
	absurd.encode_u32(8, Ghost.MAX_SAMPLES + 1)
	check("an impossible sample count", Ghost.from_bytes(absurd), null)

## Playback interpolates, so 60 Hz samples do not have to be dense enough to be
## seen individually, and clamps at both ends rather than wrapping.
func test_a_ghost_interpolates_and_then_holds() -> void:
	var ghost := _sample_ghost()
	# Samples sit at whole multiples of 1/HZ along x, so halfway between the
	# first two is x = 0.5 exactly.
	var midway := ghost.pose_at(0.5 / Ghost.HZ)
	check_near("interpolated between samples", midway.origin.x, 0.5, 0.001)

	check_near("before the start it sits on the first sample",
		ghost.pose_at(-5.0).origin.x, 0.0, 0.001)
	# Holding rather than vanishing or looping: a ghost that finished its lap
	# says so by staying where it finished.
	check_near("past the end it holds the last",
		ghost.pose_at(999.0).origin.x, float(ghost.count() - 1), 0.001)

## Deleting a circuit takes its recordings too. An inherited lap record is a
## number that is too good; an inherited ghost is a translucent car driving
## through the scenery of a circuit it has never seen.
func test_ghosts_go_with_a_deleted_circuit() -> void:
	var layout := TrackLayout.new()
	layout.cells = sample_layout().cells
	layout.start_cell = sample_layout().start_cell
	layout.display_name = "Ghosted"
	TrackStore.save(layout)

	check("a ghost is stored",
		GhostStore.save(layout.id, _sample_ghost()), OK)
	check_true("and reads back",
		GhostStore.load_ghost(layout.id) != null)

	# A circuit whose id merely starts the same must not be swept with it -- the
	# same class of ambiguity the record key had to avoid.
	var neighbour := layout.id + "_2"
	check("a neighbour's ghost is stored",
		GhostStore.save(neighbour, _sample_ghost()), OK)

	GameState.delete_track(layout.id)
	check("the ghost went with the circuit",
		GhostStore.load_ghost(layout.id), null)
	check_true("the neighbour kept its own",
		GhostStore.load_ghost(neighbour) != null)

## The replay is meshes and nothing else. A second physics body wearing the car's
## shape would trip all sixteen gates on its way round and time a lap nobody
## drove, and `car_controller` finds "up" by raycasting down -- it would read a
## solid ghost as banking, exactly as it would a trackside prop.
func test_the_ghost_car_is_not_a_physics_body() -> void:
	var ghost_car := _find_first("GhostCar", "Node3D")
	check_true("the race scene has a ghost car", ghost_car != null)
	if ghost_car == null:
		return
	check("it is not a second player car",
		ghost_car.is_in_group("player_car"), false)
	var bodies := ghost_car.find_children("*", "CollisionObject3D", true, false)
	check("and carries no collision at all", bodies.size(), 0)
	check_true("but does carry meshes",
		ghost_car.find_children("*", "MeshInstance3D", true, false).size() > 0)

## The cornering half of the par model, against the figures the tuning journal
## measured. Those two radii are the middle and largest Kenney corners, and they
## are the only independent check this model has -- everything else in it is a
## straight-line number.
func test_par_time_reproduces_measured_corner_speeds() -> void:
	for pair in [[21.0, 98.0], [35.0, 127.0]]:
		var radius: float = pair[0]
		var kmh: float = sqrt(ParTime.LATERAL_G * ParTime.G * radius) * 3.6
		check_near("a %.0f m corner goes at the measured speed" % radius,
			kmh, float(pair[1]), 1.0)

## The estimate has to be the right shape even without a driven lap to check it
## against: longer circuits take longer, nothing exceeds the car's measured top
## speed, and a tight circuit averages less than an open one.
func test_par_time_is_plausible_on_the_shipped_circuits() -> void:
	var source: GDScript = load("res://tools/build_track.gd")
	var times := {}
	var lengths := {}
	for entry in [["ardennes", source.ARDENNES], ["monte_carlo", source.MONTE_CARLO],
			["la_sarthe", source.LA_SARTHE]]:
		var builder := TrackBuilder.new()
		var result := builder.measure(entry[1])
		var ideal := ParTime.ideal_lap(builder.centreline)
		times[entry[0]] = ideal
		lengths[entry[0]] = result.length
		check_true("%s has an estimate at all" % entry[0], ideal > 0.0)
		# A lap cannot average more than the car's measured top speed, and a
		# circuit made of corners cannot average anywhere near it.
		var average_kmh: float = result.length / maxf(ideal, 0.001) * 3.6
		check_true("%s averages below top speed (%.1f)" % [entry[0], average_kmh],
			average_kmh < ParTime.TOP_SPEED * 3.6)
		check_true("%s averages something sane (%.1f)" % [entry[0], average_kmh],
			average_kmh > 40.0)

	check_true("the longest circuit takes the longest",
		times["la_sarthe"] > times["ardennes"]
		and times["ardennes"] > times["monte_carlo"])
	# Monte Carlo is "fourteen tight corners, not one banked" and Ardennes is
	# "fast sweepers" -- so the shorter circuit must also be the slower one per
	# metre, or the model is measuring length and calling it difficulty.
	check_true("and the tight circuit is slower per metre",
		lengths["monte_carlo"] / times["monte_carlo"]
		< lengths["ardennes"] / times["ardennes"])

## Nothing to walk, nothing to say. The editor calls this on a circuit that is
## mid-edit and may be anything at all.
func test_par_time_refuses_a_degenerate_circuit() -> void:
	var empty: Array[Vector3] = []
	check_near("no centreline", ParTime.ideal_lap(empty), 0.0, 0.0001)
	var two: Array[Vector3] = [Vector3.ZERO, Vector3(1.0, 0.0, 0.0)]
	check_near("not enough of one", ParTime.ideal_lap(two), 0.0, 0.0001)
	# All one point: every chord degenerate, so there is no turn to measure
	# anywhere. Must come back with nothing rather than dividing by zero.
	var stack: Array[Vector3] = []
	for _i in 20:
		stack.append(Vector3.ZERO)
	check_near("a circuit with no extent", ParTime.ideal_lap(stack), 0.0, 0.0001)

## The editor recompiles on every mouse move, and the readout now runs the lap
## estimate on top of that walk. Both together have to fit inside a frame or
## dragging a corner would stutter -- which is the one thing the editor cannot
## afford, since dragging is how it is used.
func test_the_editor_readout_is_affordable_per_mouse_move() -> void:
	var source: GDScript = load("res://tools/build_track.gd")
	var runs := 20
	var started := Time.get_ticks_usec()
	for _i in runs:
		var builder := TrackBuilder.new()
		builder.measure(source.LA_SARTHE)
		ParTime.ideal_lap(builder.centreline)
	var each_ms := float(Time.get_ticks_usec() - started) / float(runs) / 1000.0
	# Against a 16.7 ms frame at 60 Hz, on the longest shipped circuit. Generous
	# on purpose: this is a regression guard against the estimate becoming
	# quadratic, not a benchmark.
	check_true("measure plus estimate fits in a frame (%.2f ms)" % each_ms,
		each_ms < 9.0)

## A circuit has to survive being turned into a string and back, including every
## per-corner choice -- radius, banking and elevation are the interesting half of
## a layout, and a code that carried only the painted cells would lose the design
## and keep the outline.
func test_a_circuit_round_trips_through_a_share_code() -> void:
	var layout := sample_layout()
	layout.display_name = "Shared Circuit"
	layout.id = "user_the_senders_id"
	var corners := layout.compile().corners
	check_true("the sample circuit has corners to decorate", corners.size() > 2)
	layout.corner_sizes[corners[0].cell] = 1
	layout.elevation[layout.compile().runs[1].key] = 2

	var code := ShareCode.encode(layout)
	check_true("a code is recognisable on sight", code.begins_with(ShareCode.PREFIX))
	# Small enough to paste into a message, which is the entire point of the
	# format. Measured at 372 characters for this circuit; the bound is loose
	# because it is guarding the order of magnitude, not the exact number.
	check_true("and is short enough to paste (%d chars)" % code.length(),
		code.length() < 2000)

	var result := ShareCode.decode(code)
	check_true("it decodes: %s" % result.error, result.ok)
	if not result.ok:
		return
	check("same name", result.layout.display_name, "Shared Circuit")
	check("same cells", result.layout.cells.size(), layout.cells.size())
	check("corner radius survives",
		result.layout.corner_sizes.get(corners[0].cell, -1), 1)
	check("banking survives",
		result.layout.corner_banks.size(), layout.corner_banks.size())
	check("elevation survives", result.layout.elevation.size(), 1)
	check_true("and it still compiles", result.layout.compile().ok)

	# Ids are local: they key lap records, and `TrackStore` hands them out. An
	# imported circuit arriving under the sender's id would inherit whatever this
	# player had already recorded against that name.
	check("the sender's id does not travel", result.layout.id, "")

## Pasting goes through chat windows and email, which wrap lines and add spaces.
## A code that failed because of what the transport did to it would be
## indistinguishable from one that was never valid.
func test_a_share_code_survives_being_pasted_badly() -> void:
	var code := ShareCode.encode(sample_layout())
	var mangled := "  " + code.substr(0, 20) + "\n" + code.substr(20, 20) \
		+ "\r\n " + code.substr(40) + "  \n"
	var result := ShareCode.decode(mangled)
	check_true("line breaks and spaces are ignored: %s" % result.error, result.ok)
	if result.ok:
		check("and it is the same circuit",
			result.layout.cells.size(), sample_layout().cells.size())

## Codes come from other people, so every field is a claim rather than a fact.
## Each of these has to fail *politely* -- with something a player can read --
## rather than silently, or by taking the editor down with it.
func test_a_bad_share_code_fails_politely() -> void:
	var good := ShareCode.encode(sample_layout())
	for bad in [
		"", "hello", "TD1-", "TD1-not-base64-at-all|99",
		good.substr(0, good.length() / 2),
		good.replace("|", ""),
	]:
		var result := ShareCode.decode(bad)
		check("%s is refused" % (bad.substr(0, 12) if not bad.is_empty() else "an empty paste"),
			result.ok, false)
		check_true("and says why", not result.error.is_empty())

	# A size field is what an allocation gets sized from, so an absurd one has to
	# be refused before it is believed rather than after.
	var huge := good.substr(0, good.rfind("|")) + "|999999999"
	check("an impossible size is refused", ShareCode.decode(huge).ok, false)

	# The one that matters most: a code that decodes cleanly but is not a
	# circuit. `TrackLayout.compile` calls the same `TrackShape.walk` the editor
	# does, so this can never become a track -- but the player has to be told.
	var broken := TrackLayout.new()
	broken.cells = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(5, 5)]
	broken.display_name = "Not A Loop"
	var result := ShareCode.decode(ShareCode.encode(broken))
	check("a decodable non-circuit is refused", result.ok, false)
	check_true("and is refused for being a bad circuit, not a bad code",
		result.error.contains("not a valid circuit"))

## Ghosts can ride along, and measurement is why they do not by default: a
## two-minute lap makes the code about 128,000 characters against the circuit's
## 372, which is past what anyone pastes into a message.
func test_a_share_code_can_carry_a_ghost_but_does_not_by_default() -> void:
	var layout := sample_layout()
	var plain := ShareCode.encode(layout)
	check("a plain code carries no lap", ShareCode.decode(plain).ghost, null)

	var ghost := Ghost.new()
	for i in 200:
		ghost.add(Transform3D(
			Basis(Vector3.UP, float(i) * 0.07),
			Vector3(float(i) * 1.7, 1.0 + sin(float(i) * 0.3), cos(float(i) * 0.2) * 40.0)
		))
	var with_ghost := ShareCode.encode(layout, ghost)
	# Only "bigger" is asserted, not by how much: this ghost is 200 synthetic
	# samples and deflate is very good at those. The figure that decided the
	# design is a *real* lap -- 128,000 characters against a circuit's 372, which
	# is why a shared circuit does not carry one by default. That measurement is
	# in the tuning journal, not pinned here, because pinning it would be pinning
	# how well a compressor happens to do on made-up data.
	check_true("attaching one makes the code bigger",
		with_ghost.length() > plain.length())

	var result := ShareCode.decode(with_ghost)
	check_true("and it comes back: %s" % result.error, result.ok)
	if result.ok and result.ghost != null:
		check("with every sample", result.ghost.count(), ghost.count())
		check_near("and the right shape",
			result.ghost.pose_at(100.0 / Ghost.HZ).origin.x, 100.0 * 1.7, 0.01)

## The committed sound must match what `tools/build_audio.gd` produces now, the
## same rule the generated theme and circuits follow: editing the synthesis and
## forgetting to re-run the tool would leave the game playing the old sound with
## no sign anything was wrong.
func test_audio_resources_match_their_source() -> void:
	# `SoundBank`, not `tools/build_audio.gd`: the tool extends SceneTree, so
	# `new()`-ing it here allocates a second viewport and scenario and leaks them
	# at exit. The synthesis lives in the class for exactly this reason.
	for pair in [["engine", SoundBank.engine()], ["tyre", SoundBank.tyre()]]:
		var committed: AudioStreamWAV = load(
			"res://resources/audio/%s.tres" % pair[0]
		)
		var fresh: AudioStreamWAV = pair[1]
		check_true("%s.tres exists" % pair[0], committed != null)
		if committed == null:
			continue
		check("%s is the committed length" % pair[0],
			committed.data.size(), fresh.data.size())
		check("%s is byte-for-byte the built one" % pair[0],
			committed.data, fresh.data)
		check("%s loops" % pair[0],
			committed.loop_mode, AudioStreamWAV.LOOP_FORWARD)
		# The loop must cover the whole buffer. A loop end short of the data is
		# the classic way a generated tone develops a tick.
		check("%s loops over all of itself" % pair[0],
			committed.loop_end, committed.data.size() / 2)

## Every partial in a generated loop has to complete whole cycles inside the
## buffer, or the waveform arrives at its own start mid-swing and clicks once per
## loop -- forever, and inaudibly enough in isolation to ship.
##
## The wrap is compared against the buffer's *own* biggest sample-to-sample step
## rather than against a fixed threshold. An absolute limit does not work across
## both sounds: the engine is a low buzz whose neighbouring samples barely
## differ, while the tyre is a band of noise up to 3.3 kHz, where a full swing
## between adjacent samples is completely normal. What makes a click is the wrap
## being an *outlier* for that particular waveform, not being large.
func test_generated_loops_meet_their_own_start() -> void:
	for name in ["engine", "tyre"]:
		var wav: AudioStreamWAV = load("res://resources/audio/%s.tres" % name)
		if wav == null:
			continue
		var frames := wav.data.size() / 2
		var biggest_step := 0
		for i in range(1, frames):
			biggest_step = maxi(biggest_step, absi(
				wav.data.decode_s16(i * 2) - wav.data.decode_s16((i - 1) * 2)
			))
		var wrap := absi(
			wav.data.decode_s16(0) - wav.data.decode_s16((frames - 1) * 2)
		)
		check_true(
			"%s wraps no harder than it moves anywhere else (%d vs %d)"
				% [name, wrap, biggest_step],
			wrap <= biggest_step
		)

## Sound is off unless it has been asked for, and the choice survives a restart.
##
## The default is off because the sounds are synthesised and, on the only
## listening anyone has done, annoying. That is a placeholder for a proper audio
## pass rather than a considered preference — but while it stands, it is worth
## pinning, because "silent by default" is the sort of thing that gets flipped
## back accidentally.
func test_sound_is_off_until_asked_for() -> void:
	GameState.forget_cached_settings()
	check("silent unless asked", GameState.audio_enabled(), false)

	GameState.set_audio_enabled(true)
	GameState.forget_cached_settings()
	check("turning it on persists", GameState.audio_enabled(), true)
	GameState.set_audio_enabled(false)
	GameState.forget_cached_settings()
	check("and turning it off again persists", GameState.audio_enabled(), false)

## With sound off, nothing plays -- stopped rather than muted, because a silent
## loop still costs a mix on every frame and the point of the switch is that
## someone did not want it running.
func test_the_car_is_silent_when_sound_is_off() -> void:
	var car: Node = get_first_node_in_group("player_car")
	var audio: Node = car.get_node_or_null("Audio") if car != null else null
	if audio == null:
		return
	GameState.set_audio_enabled(false)
	audio._physics_process(1.0 / 120.0)
	check("engine stopped", audio._engine.playing, false)
	check("tyres stopped", audio._tyre.playing, false)

## The car carries its own sound, and it must not be a second physics body or a
## second anything -- the owner rule that once shipped this car with eight wheels
## applies to whatever gets added to it.
func test_the_car_carries_its_audio() -> void:
	var car: Node = get_first_node_in_group("player_car")
	check_true("there is a car", car != null)
	if car == null:
		return
	var audio: Node = car.get_node_or_null("Audio")
	check_true("with an audio node", audio != null)
	if audio == null:
		return
	# Runs while the tree is paused, which is the only way it can silence itself
	# when the game stops. A menu over a droning engine is the bug this prevents.
	check("that keeps running while paused",
		audio.process_mode, Node.PROCESS_MODE_ALWAYS)
	for node_name in ["Engine", "Tyre"]:
		var player: AudioStreamPlayer3D = audio.get_node_or_null(node_name)
		check_true("%s player exists" % node_name, player != null)
		check_true("%s has a stream" % node_name,
			player != null and player.stream != null)

## Pitch follows speed, and it does so by sweeping a band repeatedly rather than
## climbing once. Straight wheel RPM would rise monotonically from a standstill
## to top speed -- one long slide over twenty seconds, which is the thing an
## engine most obviously does not do.
func test_engine_pitch_sweeps_rather_than_climbing_once() -> void:
	var car: Node = get_first_node_in_group("player_car")
	var audio: Node = car.get_node_or_null("Audio") if car != null else null
	if audio == null:
		return

	var pitches: Array[float] = []
	for kmh in [0.0, 20.0, 40.0, 60.0, 80.0, 100.0, 120.0, 140.0, 165.0]:
		pitches.append(audio._target_pitch(kmh))

	var drops := 0
	for i in range(1, pitches.size()):
		if pitches[i] < pitches[i - 1]:
			drops += 1
	check_true("the note falls back at least once, as a shift (%s)"
		% ", ".join(pitches.map(func(p): return "%.2f" % p)), drops > 0)

	# And it stays inside the range the loop was baked for, at both extremes.
	for p in pitches:
		check_true("pitch %.2f is usable" % p,
			p >= CarAudio.PITCH_IDLE - 0.01 and p <= CarAudio.PITCH_REDLINE + 0.01)
	check_true("standing still idles",
		is_equal_approx(audio._target_pitch(0.0), CarAudio.PITCH_IDLE))
	# Past the top of the range is still the top of it, not beyond: a car pushed
	# downhill over its measured top speed must not shriek.
	check_near("and beyond top speed it holds",
		audio._target_pitch(400.0), CarAudio.PITCH_REDLINE, 0.001)

## Tyre noise means a tyre losing the fight, not a tyre working. Squealing
## through every corner would make the sound carry no information at all.
func test_tyres_only_squeal_when_they_are_sliding() -> void:
	var car: Node = get_first_node_in_group("player_car")
	var audio: Node = car.get_node_or_null("Audio") if car != null else null
	if audio == null:
		return
	# Stationary, whatever the wheels are doing.
	check_near("parked is silent", audio._squeal(0.0), 0.0, 0.001)
	# The wheels in the suite's car are gripping, so at speed it is still silent.
	check_near("gripping at speed is silent", audio._squeal(80.0), 0.0, 0.001)
	check_true("and the threshold is below full grip",
		CarAudio.SQUEAL_FROM < 1.0)

## A rectangle of cells, as the outline only.
func _ring(w: int, h: int, at := Vector2i.ZERO) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for x in w:
		out.append(at + Vector2i(x, 0))
		out.append(at + Vector2i(x, h - 1))
	for y in range(1, h - 1):
		out.append(at + Vector2i(0, y))
		out.append(at + Vector2i(w - 1, y))
	return out

## A figure of eight: two rings meeting at a single shared cell, which the road
## passes straight through twice. The smallest interesting crossing.
func _figure_of_eight() -> Array[Vector2i]:
	# Two 5x5 rings sharing exactly the corner cell (4, 4) / (0, 0).
	var out: Array[Vector2i] = _ring(5, 5)
	for c in _ring(5, 5, Vector2i(4, 4)):
		if not out.has(c):
			out.append(c)
	return out

## A painted figure of eight: two square rings sharing one cell. Big enough that
## the runs have room for the start line and for a two-level climb.
func _eight_layout(size: int) -> TrackLayout:
	var layout := TrackLayout.new()
	var cells: Array[Vector2i] = _ring(size, size)
	for c in _ring(size, size, Vector2i(size - 1, size - 1)):
		if not cells.has(c):
			cells.append(c)
	layout.cells = cells
	layout.start_cell = cells[0]
	layout.display_name = "Crossover"
	layout.allow_crossings = true
	return layout

## Raises whichever run passes through `cell` and is not the start run, as high
## as it is allowed to go. Returns the level it managed.
func _raise_over(layout: TrackLayout, cell: Vector2i, want: int) -> int:
	var compiled := layout.compile()
	for run in compiled.runs:
		if run.is_start or not run.cells.has(cell):
			continue
		layout.elevation[run.key] = want
		break
	var after := layout.compile()
	for run in after.runs:
		if run.cells.has(cell) and not run.is_start:
			return run.level
	return 0

## The compiler refuses a crossing where the two roads would meet, and says so in
## a sentence rather than by producing a circuit with two roads in one place.
##
## This is the whole safety argument for allowing crossings: the shape is
## drawable, and only *buildable* if one leg clears the other. `TrackShape` knows
## the first; only the compiler knows heights, so only the compiler can know the
## second.
func test_a_crossing_needs_headroom_to_compile() -> void:
	var flat := _eight_layout(14)
	var crossing: Vector2i = TrackShape.crossings_in(flat.cells)[0]

	var level := flat.compile()
	check("a flat crossing is refused", level.ok, false)
	check_true("and the cell is pointed at",
		level.problem_cells.has(crossing))
	var said_headroom := false
	for e in level.errors:
		if e.contains("crosses itself"):
			said_headroom = true
	check_true("with a sentence about the crossing (%s)"
		% ", ".join(level.errors), said_headroom)

	# Raised properly, it compiles. Two levels because the bridge tile carries
	# one level of structure below its deck -- one level of separation would put
	# the upper road's supports in the lower road.
	var raised := _eight_layout(14)
	var got := _raise_over(raised, crossing, TrackLayout.CROSSING_CLEARANCE_LEVELS)
	check("the leg went up two levels", got,
		TrackLayout.CROSSING_CLEARANCE_LEVELS)
	var ok := raised.compile()
	check_true("and then it compiles (%s)" % ", ".join(ok.errors), ok.ok)
	check_true("with a lap to drive", ok.segments.size() > 0)

## A painted crossing has to build, not just compile -- and the builder needs no
## special case for it. Suzuka reaches the builder as a hand-authored segment
## list; this is the same geometry arriving from painted cells, which is the
## route a player's circuit takes.
##
## The raised leg becomes `roadStraightBridge` because `_emit_run` already emits
## that for a held section above ground. Nothing was added to the builder for
## crossings; it simply walks the segments and the road passes over itself.
func test_a_painted_crossing_builds_with_real_clearance() -> void:
	var layout := _eight_layout(14)
	var crossing: Vector2i = TrackShape.crossings_in(layout.cells)[0]
	_raise_over(layout, crossing, TrackLayout.CROSSING_CLEARANCE_LEVELS)
	var compiled := layout.compile()
	check_true("it compiles (%s)" % ", ".join(compiled.errors), compiled.ok)
	if not compiled.ok:
		return

	var builder := TrackBuilder.new()
	var result := builder.measure(compiled.segments)
	check_true("and closes", result.closed)
	check("as a circuit that crosses itself", result.simple, false)

	# The same measurement Suzuka gets: two parts of the lap far apart along the
	# road, on top of each other in plan, with real height between them.
	var line := builder.centreline
	var n := line.size()
	var apart := n / 6
	var best_flat := INF
	var rise := 0.0
	for i in n:
		for j in range(i + apart, n - apart):
			var flat := Vector2(line[i].x, line[i].z).distance_to(
				Vector2(line[j].x, line[j].z)
			)
			if flat < best_flat:
				best_flat = flat
				rise = absf(line[i].y - line[j].y)
	check_true("the lap meets itself in plan (%.1f m)" % best_flat,
		best_flat < 2.0)
	check_true("with two levels of air between (%.1f m)" % rise, rise > 6.0)

	# And the raised leg is carried on the bridge tile, which is what holds a
	# deck up rather than a plain straight hanging in space.
	var bridges := 0
	for seg in compiled.segments:
		if seg[0] == "S" and String(seg[1]) == "roadStraightBridge":
			bridges += 1
	check_true("carried on bridge tiles", bridges > 0)

## One level is not enough, and the refusal has to say so specifically rather
## than repeating the flat message.
func test_one_level_of_crossing_clearance_is_refused() -> void:
	var layout := _eight_layout(14)
	var crossing: Vector2i = TrackShape.crossings_in(layout.cells)[0]
	var got := _raise_over(layout, crossing, 1)
	check("the leg went up one level", got, 1)
	var result := layout.compile()
	check("one level is still refused", result.ok, false)
	var said_one := false
	for e in result.errors:
		if e.contains("only one level"):
			said_one = true
	check_true("and says one level is not enough (%s)"
		% ", ".join(result.errors), said_one)

## The compiler is only crossing-aware when the layout asks. Without the flag a
## four-neighbour cell is still a junction, which is what every circuit saved so
## far will keep getting.
func test_the_compiler_refuses_crossings_by_default() -> void:
	var layout := _eight_layout(14)
	layout.allow_crossings = false
	var result := layout.compile()
	check("refused without the flag", result.ok, false)
	var said_junction := false
	for e in result.errors:
		if e.contains("junction"):
			said_junction = true
	check_true("as a junction (%s)" % ", ".join(result.errors), said_junction)

	# And the flag survives being saved, or a shared or reloaded circuit would
	# come back as an invalid one.
	var raised := _eight_layout(14)
	var round_tripped := TrackLayout.from_dict(raised.to_dict())
	check("the flag round-trips", round_tripped.allow_crossings, true)

## The editor's strongest guarantee is that no drag can leave a shape which will
## not build. Crossings give that up deliberately, so the opt-in has to reach all
## the way down: with it off a handle edit that would cross is still refused.
func test_handle_edits_only_cross_when_asked() -> void:
	var corners: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(12, 0), Vector2i(12, 8), Vector2i(0, 8),
	]
	check_true("the rectangle is valid to begin with",
		TrackShape.corners_valid(corners))

	# Everything `corners_valid` guarded before still has to be refused with the
	# opt-in on: allowing a crossing must not become a licence for a diagonal, a
	# degenerate edge, or a ring too small to be a circuit.
	var diagonal: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(12, 4), Vector2i(12, 8), Vector2i(0, 8),
	]
	check("a diagonal edge is refused",
		TrackShape.corners_valid(diagonal, true), false)
	var stubby: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 8), Vector2i(0, 8),
	]
	check("an edge below the minimum is refused",
		TrackShape.corners_valid(stubby, true), false)
	check("too few corners is refused",
		TrackShape.corners_valid(corners.slice(0, 3), true), false)

	# The real thing: an outline that genuinely crosses itself is accepted only
	# with the opt-in.
	var eight := _eight_layout(14)
	var eight_corners := TrackShape.corners_of(eight.cells, true)
	check_true("a figure of eight has corners to read", eight_corners.size() >= 4)
	check("its outline is refused by default",
		TrackShape.corners_valid(eight_corners), false)
	check_true("and accepted when asked",
		TrackShape.corners_valid(eight_corners, true))

	# And the cells it traces are a *set*: a crossing cell appears once, or the
	# layout it is written back into would be corrupt rather than crossed.
	var traced := TrackShape.cells_from_corners(eight_corners)
	var seen := {}
	var doubled := 0
	for c in traced:
		if seen.has(c):
			doubled += 1
		seen[c] = true
	check("no cell is traced twice", doubled, 0)
	check_true("and the traced cells still walk as a crossing circuit",
		not TrackShape.walk(traced, true).is_empty())

## A crossing belongs to no straight, the way a corner does not: two straights
## run through it and there is no telling which one a drag meant to grab.
func test_a_crossing_cannot_be_grabbed_as_a_straight() -> void:
	var eight := _eight_layout(14)
	var corners := TrackShape.corners_of(eight.cells, true)
	var crossing: Vector2i = TrackShape.crossings_in(eight.cells)[0]
	check("the crossing is not grabbable",
		TrackShape.edge_at(corners, crossing), -1)

	# Ordinary road on the same circuit still is, or the whole circuit would
	# become undraggable rather than just the one cell.
	var grabbable := 0
	for c in eight.cells:
		if TrackShape.edge_at(corners, c) >= 0:
			grabbable += 1
	check_true("but the rest of the road still is (%d cells)" % grabbable,
		grabbable > 20)

## The start straight is pinned to the ground so the lap's height closes, so it
## must report **no** headroom.
##
## It used to report two or three levels of it, because the probe ran before the
## pinning was accounted for. The editor believed the number: clicking the badge
## on the start straight flashed "held at +2", the resolver put it straight back
## to zero, and nothing changed. Harmless on an ordinary circuit and the reason a
## crossing could not be made to validate — half the time the leg you are told to
## raise is the one that silently refuses to rise.
func test_the_start_straight_offers_no_headroom() -> void:
	var plain := sample_layout().compile()
	check_true("the sample circuit compiles", plain.ok)
	for run in plain.runs:
		if run.is_start:
			check("the start straight offers no climb", run.max_level, 0)
	# And something else on the circuit still does, or the check above would pass
	# by the whole circuit being unraisable.
	var raisable := 0
	for run in plain.runs:
		if not run.is_start and run.max_level > 0:
			raisable += 1
	check_true("but other straights still can be raised (%d)" % raisable,
		raisable > 0)

	# The same on a crossing circuit, which is where it bites.
	var eight := _eight_layout(14)
	var crossing: Vector2i = TrackShape.crossings_in(eight.cells)[0]
	var compiled := eight.compile()
	var over := 0
	for run in compiled.runs:
		if not run.cells.has(crossing):
			continue
		if run.is_start:
			check("the crossing's start leg cannot rise", run.max_level, 0)
		elif run.max_level >= TrackLayout.CROSSING_CLEARANCE_LEVELS:
			over += 1
	check_true("and the other leg can rise far enough to bridge", over > 0)

## The panel's controls must survive whatever the compiler has to say.
##
## The guide and readout cards wrap, and with a floor on their height but no
## ceiling they simply grew: a circuit with a list of errors on it pushed Save,
## Test drive and Back under the bottom of a column that is 720 units tall on
## every window, so there was no way to save the thing being described. The cards
## are capped with `max_lines_visible` now, which makes that structural rather
## than a matter of keeping the wording short.
##
## Driven with the worst content the editor can produce — a refused crossing,
## which carries an error per problem cell — rather than the default circuit the
## other layout test uses, because the default is exactly the case that never
## overflowed.
func test_the_panel_keeps_its_buttons_whatever_the_readout_says() -> void:
	var editor: Control = staged_editor
	if editor == null:
		return
	var side: Control = editor.get_node_or_null("Split/Side")
	if side == null:
		return

	var worst := _eight_layout(14)
	editor._layout = worst
	editor._grid.layout = worst
	editor._recompile()
	# Also load the status line up, which is the other label that takes a
	# sentence from the code rather than a fixed string.
	editor._flash(
		"The start straight stays on the ground so the lap's height closes. "
		+ "Raise the other side instead."
	)
	editor._update_panel()
	check("the worst case is actually a refused circuit", editor._compiled.ok, false)

	var rows: Control = side.get_node("Rows")
	check_true("the panel still fits its column (%.0f in %.0f)"
		% [rows.get_combined_minimum_size().y, side.size.y],
		rows.get_combined_minimum_size().y <= side.size.y)

	# Width, for the same reason and a different control. The circuit picker is
	# an OptionButton and takes its minimum width from its longest item -- which
	# is a name the player typed, with nothing limiting it. One long name used to
	# drag the panel out past nine hundred units and swallow the canvas beside
	# it. `stage_title_menu` saves exactly such a circuit, so the picker here is
	# listing one.
	# Saved and refreshed here rather than relying on what other tests left in the
	# store, so the picker is definitely listing one.
	var long_named := sample_layout()
	long_named.display_name = (
		"A Circuit With An Extremely Long Name That Nobody Sensible Would Type "
		+ "But Which The Field Happily Accepts Anyway"
	)
	long_named.id = ""
	TrackStore.save(long_named)
	staged_track_ids.append(long_named.id)
	editor._refresh_picker()

	var picker: OptionButton = editor.get_node("Split/Side/Rows/Picker")
	var longest := 0
	for i in picker.item_count:
		longest = maxi(longest, picker.get_item_text(i).length())
	check_true("the picker is listing a very long name (%d chars)" % longest,
		longest > 60)
	check_true("and the panel keeps its width (%.0f, budget %.0f)"
		% [side.size.x, editor.SIDEBAR_W],
		side.size.x <= editor.SIDEBAR_W + 2.0)

	# And the buttons that matter are still on screen, which is the thing the
	# player actually lost.
	for path in [
		"Split/Side/Rows/Actions/UndoRow/SaveButton",
		"Split/Side/Rows/Actions/TestButton",
		"Split/Side/Rows/Actions/ExitRow/BackButton",
	]:
		var button: Control = editor.get_node_or_null(path)
		check_true("%s exists" % path.get_file(), button != null)
		if button == null:
			continue
		var bottom := button.get_global_rect().end.y
		check_true("%s is on screen (bottom %.0f of %.0f)"
			% [button.name, bottom, side.get_global_rect().end.y],
			bottom <= side.get_global_rect().end.y + 1.0)

## The fix for a crossing has to be reachable *while the circuit is refused*,
## because being refused is the only state it is ever offered from.
##
## The canvas used to draw and hit-test its badges only when `ok`, so a crossing
## with no headroom hid the elevation badge that was the entire remedy: the
## editor said "raise one side" next to a canvas with nothing on it to press.
## This drives the real control on the real canvas rather than setting elevation
## through the compiler, which is the gap that let the feature ship broken.
func test_a_refused_crossing_can_still_be_raised_on_the_canvas() -> void:
	var editor: Control = staged_editor
	if editor == null:
		return
	var eight := _eight_layout(14)
	editor._layout = eight
	editor._grid.layout = eight
	editor._recompile()

	check("the crossing circuit is refused", editor._compiled.ok, false)
	check_true("but it still has structure to decorate",
		editor._compiled.has_structure())

	# The leg that can actually rise: not the start straight, which is pinned to
	# the ground so the lap's height closes.
	var crossing: Vector2i = TrackShape.crossings_in(eight.cells)[0]
	var target := Vector2i.ZERO
	var found := false
	for run in editor._compiled.runs:
		if run.is_start or not run.cells.has(crossing):
			continue
		target = run.key
		found = true
		break
	check_true("there is a raisable leg over the crossing", found)
	if not found:
		return

	# Two presses of the badge, which is what the guide card tells the player to
	# do. Nothing here reaches into the compiler.
	editor._cycle_elevation(target)
	check("one press is not enough", editor._compiled.ok, false)
	editor._cycle_elevation(target)
	check_true("two presses clears it (%s)"
		% ", ".join(editor._compiled.errors), editor._compiled.ok)
	check_true("and it has a lap to drive",
		editor._compiled.segments.size() > 0)

## The readout says what is wrong; the guide card has to say which control puts
## it right. A correct diagnosis with nowhere to click is why this was reported
## as unusable rather than as broken.
func test_the_editor_says_how_to_fix_a_crossing() -> void:
	var editor: Control = staged_editor
	if editor == null:
		return
	var eight := _eight_layout(14)
	editor._layout = eight
	editor._grid.layout = eight
	editor._recompile()

	check("a flat crossing does not compile", editor._compiled.ok, false)
	var guide: String = editor._guide.text
	check_true("the guide names the control to press (%s)" % guide,
		guide.contains("dot") and guide.contains("bridge"))
	check_true("and warns which straight will not rise",
		guide.contains("start line"))

## The relaxation is opt-in, and with it off nothing whatsoever changes. This is
## the guard that matters most in M13: `TrackShape.walk` refusing bad shapes is
## what makes the editor safe, and the editor has not been switched over yet.
func test_crossings_are_refused_unless_asked_for() -> void:
	var eight := _figure_of_eight()
	check_true("a figure of eight has a cell with four neighbours",
		TrackShape.crossings_in(eight).size() == 1)
	check_true("and is refused by default",
		TrackShape.walk(eight).is_empty())
	check_true("and refused explicitly",
		TrackShape.walk(eight, false).is_empty())

	# The compiler and every handle edit still go through the default, so a
	# crossing cannot reach the builder by any route that exists today.
	var layout := TrackLayout.new()
	layout.cells = eight
	layout.start_cell = eight[0]
	check("the compiler still refuses one", layout.compile().ok, false)

## With crossings allowed, the ring is walked through itself: the crossing cell
## appears twice and the lap covers every cell.
func test_a_crossing_is_walked_straight_through() -> void:
	var eight := _figure_of_eight()
	var cycle := TrackShape.walk(eight, true)
	check_true("a figure of eight walks", not cycle.is_empty())
	if cycle.is_empty():
		return

	var crossing: Vector2i = TrackShape.crossings_in(eight)[0]
	check("the ring is one longer than the cell count",
		cycle.size(), eight.size() + 1)
	var visits := 0
	for c in cycle:
		if c == crossing:
			visits += 1
	check("the crossing is on the lap twice", visits, 2)

	# Every other cell exactly once, or the walk has doubled back somewhere.
	var seen := {}
	for c in cycle:
		seen[c] = int(seen.get(c, 0)) + 1
	var wrong := 0
	for c in eight:
		if int(seen.get(c, 0)) != (2 if c == crossing else 1):
			wrong += 1
	check("every other cell exactly once", wrong, 0)

	# The road goes over itself rather than turning onto the leg it crosses, so
	# the crossing is not a bend and does not become a corner.
	for i in cycle.size():
		if cycle[i] != crossing:
			continue
		var n := cycle.size()
		var into: Vector2i = cycle[i] - cycle[(i - 1 + n) % n]
		var away: Vector2i = cycle[(i + 1) % n] - cycle[i]
		check("the road goes straight through the crossing", into, away)

## Allowing crossings must not allow anything else. Every one of these was
## refused before and has to stay refused with the relaxation switched on --
## this is the test that says the invariant was widened by exactly one case.
func test_allowing_crossings_still_refuses_everything_else() -> void:
	var cases := {}

	# A T junction: three neighbours. A branch, not a crossing, and no
	# arrangement of heights makes it drivable as one loop.
	var tee: Array[Vector2i] = _ring(6, 6)
	tee.append(Vector2i(3, 6))
	tee.append(Vector2i(3, 7))
	cases["a T junction"] = tee

	# Two separate rings that never touch.
	var apart: Array[Vector2i] = _ring(5, 5)
	apart.append_array(_ring(5, 5, Vector2i(20, 20)))
	cases["two separate loops"] = apart

	# A loose end.
	var tail: Array[Vector2i] = _ring(6, 6)
	tail.append(Vector2i(7, 3))
	cases["a spur off the side"] = tail

	# A gap: not closed at all.
	var broken: Array[Vector2i] = _ring(6, 6)
	broken.remove_at(0)
	cases["a broken ring"] = broken

	# Road running alongside itself: cells with three neighbours, no crossing.
	var doubled: Array[Vector2i] = _ring(6, 6)
	for x in range(1, 5):
		doubled.append(Vector2i(x, 1))
	cases["road folded against itself"] = doubled

	for label in cases:
		check_true("%s is refused with crossings off" % label,
			TrackShape.walk(cases[label], false).is_empty())
		check_true("%s is refused with crossings on" % label,
			TrackShape.walk(cases[label], true).is_empty())

## An ordinary circuit must walk to exactly the same lap whether or not crossings
## are permitted. If the two disagree anywhere, switching the editor over later
## would silently change every existing circuit.
func test_ordinary_circuits_walk_identically_either_way() -> void:
	var shapes := {
		"a rectangle": _ring(8, 6),
		"a long thin ring": _ring(14, 4),
		"the suite's sample circuit": sample_layout().cells,
	}
	for label in shapes:
		var strict := TrackShape.walk(shapes[label], false)
		var relaxed := TrackShape.walk(shapes[label], true)
		check_true("%s walks" % label, not strict.is_empty())
		check("%s walks the same lap either way" % label, relaxed, strict)

	# The shipped circuits are deliberately absent from this: they are authored
	# segment lists rather than painted cells and never go through `walk` at all,
	# so nothing about crossings can reach them.

## Suzuka is the one shipped circuit that crosses over itself, and the whole
## point of it is a thing no other track can be checked for: two pieces of road
## in the same place at different heights.
##
## Measured off the built centreline rather than trusted from the layout. The
## layout says what was asked for; this says what came out.
func test_the_crossover_circuit_actually_crosses() -> void:
	var source: GDScript = load("res://tools/build_track.gd")
	var builder := TrackBuilder.new()
	var result := builder.measure(source.SUZUKA)

	check_true("it closes", result.closed)
	# The distinction the closure gate had to learn: a figure of eight comes back
	# to the same pose with its turns cancelling to zero, rather than to the +/-4
	# a loop that never crosses itself makes.
	check("and does so without being a simple loop", result.simple, false)
	check("its turns cancel", result.turn_total, 0)

	# Find the closest approach between two points that are far apart *along* the
	# lap. Neighbouring points are always close together; a crossing is two parts
	# of the road nowhere near each other in lap distance sitting on top of each
	# other in plan.
	var line := builder.centreline
	var n := line.size()
	var apart := n / 6  # a sixth of a lap is well beyond any corner's own span
	var best_flat := INF
	var rise_there := 0.0
	for i in n:
		for j in range(i + apart, n - apart):
			var flat := Vector2(line[i].x, line[i].z).distance_to(
				Vector2(line[j].x, line[j].z)
			)
			if flat < best_flat:
				best_flat = flat
				rise_there = absf(line[i].y - line[j].y)

	check_true("two distant parts of the lap meet in plan (%.1f m apart)"
		% best_flat, best_flat < 2.0)
	# 3.5 m per level and the bridge is at level two, so the decks are 7 m apart.
	# The bridge carries 0.5 tile units -- one level, 3.5 m -- of structure below
	# its deck, so anything less than that and the supports would be sitting in
	# the road underneath rather than clear above it.
	check_true("and one is well above the other (%.1f m)" % rise_there,
		rise_there > 6.0)
	check_near("at the height two levels buys", result.peak, 7.0, 0.1)

## Monte Carlo is roofed out of Portier, where Monaco's tunnel is. The kit has no
## tunnel art, so the shell is generated -- which means it has to be checked for
## rather than assumed to have come out of a .glb.
func test_the_tunnel_is_built_and_does_not_collide() -> void:
	var circuit: Node3D = load(
		"res://scenes/track/track_monte_carlo.tscn"
	).instantiate()
	var found := circuit.find_children("Tunnel", "MeshInstance3D", true, false)
	check_true("monte carlo has a tunnel shell", not found.is_empty())
	if found.is_empty():
		circuit.free()
		return

	var tunnel: MeshInstance3D = found[0]
	var box := tunnel.mesh.get_aabb()
	# Tall enough for the roof to clear the car and the chase camera behind it,
	# which rides 1.4 m up.
	check_near("the roof is where it was asked to be",
		box.size.y, TrackBuilder.TUNNEL_HEIGHT, 0.2)
	# Eight cells of roofed road at 14 m a cell, so the shell runs about 112 m
	# along whichever axis the straight happens to lie on.
	check_true("and it runs the length of the roofed straight (%.0f x %.0f m)"
		% [box.size.x, box.size.z],
		maxf(box.size.x, box.size.z) > 90.0)

	# Scenery never collides: `car_controller` finds "up" by casting a ray down
	# and treats whatever it hits as road, so a solid roof would be read as a
	# surface the car was resting against.
	var scenery: Node = circuit.get_node_or_null("Scenery")
	check_true("scenery exists", scenery != null)
	if scenery != null:
		check("and nothing in it collides",
			scenery.find_children("*", "CollisionObject3D", true, false).size(), 0)
	circuit.free()

	# The other circuits are not roofed, so a tunnel appearing on one would mean
	# the spans are leaking between builds.
	for id in ["ardennes", "la_sarthe", "suzuka"]:
		var other: Node3D = load(
			"res://scenes/track/track_%s.tscn" % id
		).instantiate()
		check("%s has no tunnel" % id,
			other.find_children("Tunnel", "MeshInstance3D", true, false).size(), 0)
		other.free()

## Dragging a bend back onto the straight it came from makes the road straight
## again, which is the gesture the editor is built around — "drag the road" — and
## was the one thing it would not do.
##
## Pushing a bend *through* to the far side must keep working, because that is
## why the drag refuses to prune mid-gesture in the first place. Both are driven
## through `TrackGrid` rather than through `TrackShape`, because the rule that
## broke this lives in the drag handler and not in the shape maths.
func test_dragging_a_bend_flat_straightens_the_road() -> void:
	var editor: Control = staged_editor
	if editor == null:
		return
	var grid: TrackGrid = editor._grid

	var layout := TrackLayout.new()
	layout.cells = TrackShape.cells_from_corners([
		Vector2i(0, 0), Vector2i(20, 0), Vector2i(20, 12), Vector2i(0, 12),
	])
	layout.start_cell = Vector2i(2, 0)
	layout.display_name = "Bend Test"
	grid.layout = layout
	grid.refresh(layout.compile())
	var plain := grid._corners.size()

	# Push a bend out of the top straight, the way a double-click does.
	var popped := TrackShape.insert_bump(grid._corners, 0, Vector2i(10, 0), -4)
	check("a bend was pushed out", popped.size(), plain + 4)
	grid._corners = popped
	layout.cells = TrackShape.cells_from_corners(popped)

	# Now drag its outer edge back onto y = 0, which is the line it left.
	grid._drag = TrackGrid.Hit.EDGE
	grid._drag_floor = popped.size()
	grid._drag_moved = false
	for i in popped.size():
		var a: Vector2i = popped[i]
		var b: Vector2i = popped[(i + 1) % popped.size()]
		if a.y == -4 and b.y == -4:
			grid._drag_index = i
			break
	# The straighten is armed across the whole band no bend can occupy, not on the
	# single cell exactly on the line: those cells are ones `move_edge` refuses,
	# so they used to do nothing but throw the bump to the far side, leaving the
	# flat position a knife-edge between two flips.
	for approach in [-1, 0, 1]:
		grid._corners = popped.duplicate()
		layout.cells = TrackShape.cells_from_corners(grid._corners)
		grid._drag = TrackGrid.Hit.EDGE
		grid._drag_floor = popped.size()
		grid._drag_moved = false
		grid._flatten_saved = []
		for i in popped.size():
			if popped[i].y == -4 and popped[(i + 1) % popped.size()].y == -4:
				grid._drag_index = i
				break

		grid._apply_drag(Vector2i(10, approach))
		# Straight *now*, not on release: the canvas has to show what letting go
		# will give, or the player has to know the rule instead of seeing it.
		check("at y=%d the road is drawn straight" % approach,
			grid._corners.size(), plain)
		check("and the cells match what is drawn" % [],
			grid.layout.cells.size(),
			TrackShape.cells_from_corners(grid._corners).size())
		check_true("with the bend kept in case the drag continues",
			not grid._flatten_saved.is_empty())
		grid._end_drag()
		check("letting go at y=%d keeps it straight" % approach,
			grid._corners.size(), plain)
		check_true("leaving a valid road", TrackShape.corners_valid(grid._corners))

	# The other half of the gesture, and why the drag refuses to prune while it is
	# running: a bend must still be pushable through its own straight and out the
	# far side. Past the band, the flip is exactly as it was.
	grid._corners = popped.duplicate()
	layout.cells = TrackShape.cells_from_corners(grid._corners)
	grid._drag = TrackGrid.Hit.EDGE
	grid._drag_floor = popped.size()
	grid._drag_moved = false
	grid._flatten_saved = []
	for i in popped.size():
		if popped[i].y == -4 and popped[(i + 1) % popped.size()].y == -4:
			grid._drag_index = i
			break
	grid._apply_drag(Vector2i(10, 4))
	check("pushing it through keeps the bend", grid._corners.size(), popped.size())
	grid._end_drag()
	check("still there after letting go", grid._corners.size(), popped.size())

	# And the round trip: through the flat band and out the far side in one
	# gesture. Passing over straight must not cost the bend, or crossing to the
	# other side would be impossible without a second drag.
	grid._corners = popped.duplicate()
	layout.cells = TrackShape.cells_from_corners(grid._corners)
	grid._drag = TrackGrid.Hit.EDGE
	grid._drag_floor = popped.size()
	grid._drag_moved = false
	grid._flatten_saved = []
	for i in popped.size():
		if popped[i].y == -4 and popped[(i + 1) % popped.size()].y == -4:
			grid._drag_index = i
			break
	grid._apply_drag(Vector2i(10, -1))
	check("passing over flat shows it straight", grid._corners.size(), plain)
	grid._apply_drag(Vector2i(10, 4))
	check("carrying on restores the bend on the far side",
		grid._corners.size(), popped.size())
	check("and nothing is left held", grid._flatten_saved.size(), 0)
	grid._end_drag()
	check("which is what letting go keeps", grid._corners.size(), popped.size())

## A bend arrived at by dragging a **corner** straightens the same way as one
## pushed out with a double-click. A section becomes a bump by being dragged into
## one at least as often as by being popped, and the two cannot behave
## differently — the player did not label which is which.
##
## This route used to be refused outright, with "the circuit would cross itself",
## which was neither true nor the problem: `prune` had found the road no longer
## turns there, and the drag handler read fewer corners as danger.
func test_dragging_a_corner_into_line_straightens_it() -> void:
	var editor: Control = staged_editor
	if editor == null:
		return
	var grid: TrackGrid = editor._grid

	var layout := TrackLayout.new()
	# A rectangle with a step in its top edge, made of two corners. Nothing was
	# "popped" here; this is just a shape with a jog in it.
	var jogged: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(8, 0), Vector2i(8, -4), Vector2i(20, -4),
		Vector2i(20, 12), Vector2i(0, 12),
	]
	layout.cells = TrackShape.cells_from_corners(jogged)
	layout.start_cell = Vector2i(2, 12)
	layout.display_name = "Jog Test"
	grid.layout = layout
	grid.refresh(layout.compile())
	check("the jogged shape is valid", grid._corners.size(), jogged.size())

	# Drag the corner at (8, -4) down onto y = 0, which puts it in line with the
	# road either side and leaves no turn there.
	grid._drag = TrackGrid.Hit.CORNER
	grid._drag_floor = jogged.size()
	grid._drag_moved = false
	grid._flatten_saved = []
	grid._drag_index = jogged.find(Vector2i(8, -4))
	check_true("the corner was found", grid._drag_index >= 0)

	grid._apply_drag(Vector2i(8, 0))
	check_true("the road is drawn straight while dragging",
		grid._corners.size() < jogged.size())
	check_true("with the jog kept in case the drag continues",
		not grid._flatten_saved.is_empty())

	# Carry on past and the jog comes back, so nothing is lost by crossing over.
	grid._apply_drag(Vector2i(8, 4))
	check("dragging on restores the jog", grid._corners.size(), jogged.size())
	check("and nothing is left held", grid._flatten_saved.size(), 0)

	# Back into line, and let go.
	grid._apply_drag(Vector2i(8, 0))
	grid._end_drag()
	check_true("letting go in line keeps it straight",
		grid._corners.size() < jogged.size())
	check_true("leaving a valid road", TrackShape.corners_valid(grid._corners))

## A section popped out of a straight has to go back in, from **any** of the four
## corners it added.
##
## It used to work from two of them and refuse from the other two. `straighten_at`
## only tried the tapped corner with an immediate neighbour, and a bump's outer
## pair is only adjacent to itself — so tapping either inner corner found no
## workable pair and refused, with a message about needing four corners that was
## not the reason. The player is pointing at a shape, not at an index.
func test_a_popped_section_can_be_flattened_from_any_of_its_corners() -> void:
	var rect: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(20, 0), Vector2i(20, 12), Vector2i(0, 12),
	]
	var plain := TrackShape.cells_from_corners(rect)
	var popped := TrackShape.insert_bump(rect, 0, Vector2i(10, 0), -4)
	check("a bump adds four corners", popped.size(), rect.size() + 4)

	var tried := 0
	for i in popped.size():
		if rect.has(popped[i]):
			continue  # one of the original corners, not part of the bump
		tried += 1
		var out := TrackShape.straighten_at(popped, i)
		check_true("tapping the bump corner at %s flattens it" % popped[i],
			not out.is_empty())
		if out.is_empty():
			continue
		check("and leaves the rectangle it started as", out.size(), rect.size())
		check("with the same road",
			TrackShape.cells_from_corners(out).size(), plain.size())
	check("all four of the bump's corners were tried", tried, 4)

## The estimate is driven on the racing line, not the centreline.
##
## M10 measured the centreline model against a scripted driver and found it beat
## the "perfect" lap on two circuits of three — a path error, not a physics one.
## The line has to be shorter than the centreline, and it has to stay on the road.
func test_the_estimate_uses_a_racing_line() -> void:
	var source: GDScript = load("res://tools/build_track.gd")
	for entry in [["ardennes", source.ARDENNES], ["monte_carlo", source.MONTE_CARLO],
			["la_sarthe", source.LA_SARTHE]]:
		var builder := TrackBuilder.new()
		builder.measure(entry[1])
		var line := ParTime.racing_line(builder.centreline)
		check("%s keeps a point per centreline sample" % entry[0],
			line.size(), builder.centreline.size())

		var centre := _lap_length(builder.centreline)
		var driven := _lap_length(line)
		check_true("%s cuts the corners (%.0f m vs %.0f m)"
			% [entry[0], driven, centre], driven < centre)

		# Never off the road. The line is a lateral offset and the clamp is what
		# keeps it inside the ribbon; without it the relaxation would happily
		# shortcut across the grass.
		var worst := 0.0
		for i in line.size():
			worst = maxf(worst, Vector2(line[i].x, line[i].z).distance_to(
				Vector2(builder.centreline[i].x, builder.centreline[i].z)))
		check_true("%s stays on the road (%.1f m from centre, limit %.1f)"
			% [entry[0], worst, ParTime.LINE_HALF_WIDTH],
			worst <= ParTime.LINE_HALF_WIDTH + 0.01)
		# Height is carried through untouched: the line moves across the road,
		# never up or down it.
		check_near("%s keeps its elevation" % entry[0],
			line[10].y, builder.centreline[10].y, 0.0001)

func _lap_length(line: Array[Vector3]) -> float:
	var total := 0.0
	for i in line.size():
		total += line[i].distance_to(line[(i + 1) % line.size()])
	return total

## The par times written into `GameState.TRACKS` have to match what `ParTime`
## produces now.
##
## They are constants because the game does not depend on `tools/` at runtime and
## the shipped layouts live there — the same arrangement the generated theme has,
## and the same hazard: change the handling constants or the racing-line model and
## every shipped par silently becomes a different number from the one the medals
## are handed out against.
func test_shipped_par_times_match_the_model() -> void:
	var source: GDScript = load("res://tools/build_track.gd")
	var layouts := {
		"ardennes": source.ARDENNES, "monte_carlo": source.MONTE_CARLO,
		"la_sarthe": source.LA_SARTHE, "suzuka": source.SUZUKA,
	}
	# Every circuit, for every car: par is per car because the cars are not
	# equally quick, and a par computed for one hands the other an easy gold.
	for entry in GameState.TRACKS:
		var id: String = entry["id"]
		if not layouts.has(id):
			continue
		var builder := TrackBuilder.new()
		builder.measure(layouts[id])
		for spec in GameState.cars():
			var recorded := GameState.par_for(entry, spec.id)
			check_true("%s records a par for %s" % [id, spec.id], recorded > 0.0)
			check_near("%s par for %s is still what the model says" % [id, spec.id],
				recorded, ParTime.ideal_lap(builder.centreline, spec), 0.05)

	# And the quicker car has the quicker par everywhere, or the medals are
	# measuring the circuit rather than the drive.
	for entry in GameState.TRACKS:
		check_true("%s is quicker in the Prototype" % entry["id"],
			GameState.par_for(entry, "race_future")
			< GameState.par_for(entry, "race"))

## Medals are read off the lap time and the par, never stored. That is what makes
## it impossible for a saved medal to disagree with the time that earned it, and
## it means changing a threshold re-evaluates every medal in the game.
func test_medals_are_derived_from_the_lap_time() -> void:
	var par := 100.0
	check("dead on par is gold",
		GameState.medal_for(100.0, par), GameState.Medal.GOLD)
	check("and so is anything inside the gold margin",
		GameState.medal_for(par * GameState.MEDAL_GOLD, par),
		GameState.Medal.GOLD)
	check("just past it is silver",
		GameState.medal_for(par * GameState.MEDAL_GOLD + 0.01, par),
		GameState.Medal.SILVER)
	check("then bronze",
		GameState.medal_for(par * GameState.MEDAL_SILVER + 0.01, par),
		GameState.Medal.BRONZE)
	check("and then nothing",
		GameState.medal_for(par * GameState.MEDAL_BRONZE + 0.01, par),
		GameState.Medal.NONE)

	# The two ways there is nothing to judge.
	check("no lap, no medal", GameState.medal_for(0.0, par), GameState.Medal.NONE)
	check("no par, no medal", GameState.medal_for(50.0, 0.0), GameState.Medal.NONE)

	# The thresholds have to stay in order, or a faster lap could win a lesser
	# medal — the sort of thing a stray edit does silently.
	check_true("the thresholds are ordered",
		GameState.MEDAL_GOLD < GameState.MEDAL_SILVER
		and GameState.MEDAL_SILVER < GameState.MEDAL_BRONZE)

	# Medal names stay inside the built-in font, like everything else drawn.
	for medal in [GameState.Medal.GOLD, GameState.Medal.SILVER,
			GameState.Medal.BRONZE]:
		check_true("%s has a name" % medal,
			not GameState.medal_name(medal).is_empty())
	check("and no medal has no name",
		GameState.medal_name(GameState.Medal.NONE), "")

## A player's own circuit gets medals too, from its own geometry — which is the
## whole reason par is derived rather than authored. A circuit nobody has ever
## seen has a gold time the moment it is drawn.
func test_custom_circuits_get_a_par_of_their_own() -> void:
	var layout := sample_layout()
	layout.display_name = "Par Test"
	layout.id = ""
	TrackStore.save(layout)
	staged_track_ids.append(layout.id)

	var found := {}
	for info in GameState.all_tracks():
		if info["id"] == layout.id:
			found = info
	check_true("the circuit is listed", not found.is_empty())
	if found.is_empty():
		return
	var par := GameState.par_for(found)
	check_true("with a par of its own (%.1f s)" % par, par > 5.0)

	# And it agrees with computing it directly, so the menu is not showing a
	# different target from the one a lap will be judged against.
	var builder := TrackBuilder.new()
	builder.measure(layout.compile().segments)
	check_near("that matches the model",
		par, ParTime.ideal_lap(builder.centreline), 0.05)

## Every car in the garage has to be buildable and driveable, and its geometry
## has to come out of its own model.
##
## `tools/build_car.gd` used to hard-code the body size, wheel positions and
## wheel radius, with a warning that they were load-bearing. Measuring the same
## numbers off `race.glb` reproduces every one exactly — the constants were a copy
## of the art, not a decision about it — which is what makes a garage a spec and
## a tuning preset rather than a transcription job.
func test_every_car_is_built_from_its_own_model() -> void:
	var specs := GameState.cars()
	check_true("there is more than one car", specs.size() > 1)

	var seen_ids := {}
	var seen_tuning := {}
	for spec in specs:
		check_true("%s has an id" % spec.display_name, not spec.id.is_empty())
		check("%s's id is unique" % spec.id, seen_ids.has(spec.id), false)
		seen_ids[spec.id] = true

		# Two cars sharing a preset feel like one car in two costumes, which is
		# the whole failure mode a garage has to avoid.
		check_true("%s has tuning of its own" % spec.id, spec.tuning != null)
		if spec.tuning != null:
			check("%s's tuning is not shared" % spec.id,
				seen_tuning.has(spec.tuning.resource_path), false)
			seen_tuning[spec.tuning.resource_path] = true

		var scene: PackedScene = load(spec.scene_path())
		check_true("%s is baked" % spec.id, scene != null)
		if scene == null:
			continue
		var car: VehicleBody3D = scene.instantiate()
		check_near("%s carries its mass" % spec.id, car.mass, spec.mass, 0.01)

		# Geometry, against the model it was built from.
		var source: Node3D = load(spec.source).instantiate()
		var wheels := 0
		var steering := 0
		for child in car.get_children():
			if not (child is VehicleWheel3D):
				continue
			wheels += 1
			if child.use_as_steering:
				steering += 1
			var art: MeshInstance3D = source.get_node_or_null(
				NodePath(String(child.get_child(0).name))
			)
			check_true("%s's %s matches the art" % [spec.id, child.name],
				art != null and child.position.is_equal_approx(art.position))
		check("%s has four wheels" % spec.id, wheels, 4)
		# The trap that once shipped this car with eight of them.
		check("%s has exactly two that steer" % spec.id, steering, 2)

		var body: MeshInstance3D = source.get_node_or_null("body")
		var shape: CollisionShape3D = car.get_node_or_null("CollisionShape3D")
		check_true("%s has a collision box" % spec.id, shape != null)
		if shape != null and body != null:
			check_true("%s's box is the body's own size" % spec.id,
				(shape.shape as BoxShape3D).size.is_equal_approx(
					body.mesh.get_aabb().size))
		source.free()
		car.free()

## Records are per car, which is what the composite key was built for. A second
## car arriving must not disturb what the first one recorded.
func test_lap_records_are_kept_per_car() -> void:
	var was := GameState.selected_car
	var specs := GameState.cars()
	if specs.size() < 2:
		return

	GameState.selected_car = specs[0].id
	GameState.save_best_lap("test_garage", 60.0, PackedFloat32Array())
	GameState.selected_car = specs[1].id
	GameState.save_best_lap("test_garage", 55.0, PackedFloat32Array())

	GameState.selected_car = specs[0].id
	check_near("the first car keeps its own time",
		GameState.best_lap_for("test_garage"), 60.0, 0.001)
	GameState.selected_car = specs[1].id
	check_near("and the second keeps its own",
		GameState.best_lap_for("test_garage"), 55.0, 0.001)

	# And the medal is read against the same par, so a quicker car earns a better
	# medal on the same circuit rather than a different target.
	# Par 55 puts gold at 58.3, so the two times fall either side of it.
	var par := 55.0
	check("the slower car misses gold",
		GameState.medal_for(60.0, par), GameState.Medal.SILVER)
	check("the quicker one takes it",
		GameState.medal_for(55.0, par), GameState.Medal.GOLD)

	GameState.clear_best_lap("test_garage")
	GameState.selected_car = was

## Every entry the title screen offers must actually load and be a usable
## circuit. A broken entry here is a dead button on the menu.
func test_all_tracks_usable() -> void:
	check_true("track list not empty", GameState.TRACKS.size() > 0)
	var ids := {}
	for info in GameState.TRACKS:
		var id: String = info["id"]
		check_true("track %s has unique id" % id, not ids.has(id))
		ids[id] = true
		check_true("track %s has a name" % id, not String(info["name"]).is_empty())

		var packed: PackedScene = load(info["scene"])
		check_true("track %s scene loads" % id, packed != null)
		if packed == null:
			continue
		var inst: Node3D = packed.instantiate()
		check_true("track %s has a spawn point" % id, inst.has_node("SpawnPoint"))
		check_true("track %s has a road surface" % id, inst.has_node("RoadSurface"))
		var gate_count := 0
		for cp in inst.get_node("Checkpoints").get_children():
			gate_count += 1
		check("track %s gate count" % id, gate_count, 16)
		inst.free()

## Guards against a PackedScene trap: giving the *internal* nodes of an
## instanced sub-scene an owner makes them serialise on top of the instance, so
## everything appears twice. It shipped a car with eight wheels and two of every
## road tile, and is invisible unless counted.
func test_no_duplicated_instances() -> void:
	var car: Node = get_first_node_in_group("player_car")
	var wheels := 0
	for child in car.get_children():
		if child is VehicleWheel3D:
			wheels += 1
	check("car wheel count", wheels, 4)

	for info in GameState.TRACKS:
		var inst: Node3D = load(info["scene"]).instantiate()
		var visuals: Node = inst.get_node("RoadVisuals")
		# One road piece per holder, one mesh per piece.
		var holders := visuals.get_child_count()
		check("track %s one mesh per piece" % info["id"],
			_count_class(visuals, "MeshInstance3D"), holders)
		inst.free()

## Regression test for the corner arc centre.
##
## Every corner tile joins two straights, and the arc between them has to leave
## each end pointing the way the straight points. Centred on the wrong point it
## still passes through both connections — the two candidate circles are mirror
## images across the chord — but it turns the wrong way out of each end, and the
## whole collision ribbon cuts across the inside of the bend instead of following
## the road. The car keeps driving, because grass grips like tarmac, so nothing
## about it is obvious from behind the wheel.
##
## A kink shows up as a large heading change between consecutive centreline
## segments. Correct geometry never exceeds one arc step.
func test_centreline_has_no_kinks() -> void:
	var step_deg := 90.0 / float(TrackBuilder.ARC_STEPS)
	var tool_script := load("res://tools/build_track.gd")
	var layouts := {
		"ardennes": tool_script.ARDENNES,
		"monte_carlo": tool_script.MONTE_CARLO,
		"la_sarthe": tool_script.LA_SARTHE,
		"custom": sample_layout().compile().segments,
	}
	for name in layouts:
		var builder := TrackBuilder.new()
		builder.measure(layouts[name])
		var line := builder.centreline
		var worst := 0.0
		for i in range(1, line.size() - 1):
			var a := line[i] - line[i - 1]
			var b := line[i + 1] - line[i]
			var da := Vector2(a.x, a.z)
			var db := Vector2(b.x, b.z)
			if da.length() < 0.001 or db.length() < 0.001:
				continue
			worst = maxf(worst, rad_to_deg(absf(da.angle_to(db))))
		check_true("%s centreline turns smoothly (worst %.1f deg)" % [name, worst],
			worst <= step_deg + 0.5)

## Which way round the driver actually goes.
##
## All three shipped circuits are taken from real ones that run clockwise, and a
## lap that runs the other way is a mirror image of the circuit it is named after
## — every corner on the wrong hand, the hairpin turning out of the pit straight
## instead of into it. It closes, it drives, and nothing else in the suite
## notices. The first draft of all three was mirrored exactly this way.
##
## Measured off the built centreline rather than counted off the layout, because
## the layout is the thing that was wrong. The car's forward is local +Z — see
## `car_controller`, which reads `linear_velocity.dot(basis.z)` — and for a Y-up
## right-handed basis the driver's right is `cross(forward, up)`, which in the XZ
## plane is `(-z, x)`. Facing south, that is west, and `TrackBuilder._rotate`
## takes south to west for a "right". The labels mean what they say; deriving it
## from `Vector2.rotated`, which rotates the other way, says they do not.
func test_shipped_circuits_run_clockwise() -> void:
	var tool_script := load("res://tools/build_track.gd")
	for entry in [
		["ardennes", tool_script.ARDENNES],
		["monte_carlo", tool_script.MONTE_CARLO],
		["la_sarthe", tool_script.LA_SARTHE],
	]:
		var builder := TrackBuilder.new()
		builder.measure(entry[1])
		var line := builder.centreline
		var turned := 0.0
		var first := 0.0
		for i in range(1, line.size() - 1):
			var d := Vector2(line[i].x - line[i - 1].x, line[i].z - line[i - 1].z)
			var e := Vector2(line[i + 1].x - line[i].x, line[i + 1].z - line[i].z)
			if d.length() < 0.001 or e.length() < 0.001:
				continue
			var turn := e.normalized().dot(Vector2(-d.y, d.x).normalized())
			turned += turn
			if is_zero_approx(first) and absf(turn) > 0.05:
				first = turn
		check_true("%s runs clockwise (net %+.1f)" % [entry[0], turned], turned > 0.0)
		# La Source, Sainte Devote and the Dunlop chicane are all right-handers,
		# and all three are the first corner off the line.
		check_true("%s turns right off the pit straight" % entry[0], first > 0.0)

	# Suzuka is **deliberately absent** from the list above, and it is worth
	# saying so out loud rather than leaving it to be noticed: a figure of eight
	# has no handedness at all. One half turns each way and they cancel, which is
	# exactly what makes it a crossover. Adding it to the loop above would fail,
	# and the fix would be to remove it again.
	var eight := TrackBuilder.new()
	eight.measure(load("res://tools/build_track.gd").SUZUKA)
	var net := 0.0
	var line := eight.centreline
	for i in range(1, line.size() - 1):
		var d := Vector2(line[i].x - line[i - 1].x, line[i].z - line[i - 1].z)
		var e := Vector2(line[i + 1].x - line[i].x, line[i + 1].z - line[i].z)
		if d.length() < 0.001 or e.length() < 0.001:
			continue
		net += e.normalized().dot(Vector2(-d.y, d.x).normalized())
	check_true("suzuka has no handedness (net %+.1f)" % net, absf(net) < 1.0)

## The grid editor's whole premise: a painted loop closes by construction, so the
## builder should never disagree. If this fails the compiler and the walker have
## drifted apart.
func test_painted_loops_close() -> void:
	var compiled := sample_layout().compile()
	check_true("sample layout compiles", compiled.ok)
	check_true("no errors", compiled.errors.is_empty())
	var result := TrackBuilder.new().measure(compiled.segments)
	check_true("builder agrees it closes", result.closed)
	check("net quarter turns", absi(result.turn_total), 4)
	check_near("no leftover height", result.height_gap, 0.0, 0.001)
	check_true("has real length", result.length > 100.0)
	# Eight painted bends must produce eight corners, two of them left-handers.
	check("corner count", compiled.corners.size(), 8)
	var lefts := 0
	for corner in compiled.corners:
		lefts += 1 if corner.turn == "left" else 0
	check("left-handers", lefts, 2)

## A player can paint anything. Each of these has to be refused with the offending
## cells named, rather than compiling into a circuit that cannot be driven.
func test_bad_loops_are_rejected() -> void:
	var stub := sample_layout()

	var loose := TrackLayout.new()
	loose.cells.assign(stub.cells.slice(0, stub.cells.size() - 3))
	var a := loose.compile()
	check_true("gap in the loop is rejected", not a.ok)
	check_true("and points at the loose ends", a.problem_cells.size() >= 2)

	var branched := stub.duplicate_layout()
	# A spur off the side gives one cell three neighbours.
	branched.cells.append(branched.cells[4] + Vector2i(0, -1))
	var b := branched.compile()
	check_true("branch is rejected", not b.ok)
	check_true("and points at the junction", b.problem_cells.size() >= 1)

	var two_loops := stub.duplicate_layout()
	for x in 6:
		two_loops.cells.append(Vector2i(500 + x, 500))
		two_loops.cells.append(Vector2i(500 + x, 503))
	for y in range(501, 503):
		two_loops.cells.append(Vector2i(500, y))
		two_loops.cells.append(Vector2i(505, y))
	var c := two_loops.compile()
	check_true("a second separate loop is rejected", not c.ok)

	var tiny := TrackLayout.new()
	tiny.cells = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1)]
	check_true("too small is rejected", not tiny.compile().ok)

## Corner radius is the one real choice the editor offers, so the rules around it
## have to hold: widest that fits by default, an explicit choice honoured, and
## never a size the straights cannot pay for.
func test_corner_sizing() -> void:
	var layout := sample_layout()
	var compiled := layout.compile()
	for corner in compiled.corners:
		check_true("default is the widest that fits", corner.size == corner.max_size)
		check_true("size is a real tile", TrackLayout.CORNER_PIECES.has(corner.size))

	var bend: Vector2i = compiled.corners[0].cell
	layout.corner_sizes[bend] = 1
	var tightened := layout.compile()
	check("explicit corner size honoured", tightened.corners[0].size, 1)
	check_true("still closes when tightened",
		TrackBuilder.new().measure(tightened.segments).closed)

	# Asking for more than the tile set has must clamp, not crash or overrun.
	layout.corner_sizes[bend] = 99
	var clamped := layout.compile()
	check_true("oversize request clamped",
		clamped.corners[0].size <= TrackLayout.MAX_CORNER)
	check_true("clamped corner still fits",
		clamped.corners[0].size <= clamped.corners[0].max_size)

	# Every straight must be able to pay for the corners at both its ends.
	for i in clamped.runs.size():
		check_true("run %d not oversubscribed" % i, clamped.runs[i].free >= 0)

## Elevation lives inside one straight and returns to zero before the next
## corner, which is what keeps a painted loop's height closing for free.
func test_elevation() -> void:
	var layout := sample_layout()
	var compiled := layout.compile()

	var target: TrackLayout.Run = null
	for run in compiled.runs:
		if run.max_level > 0 and not run.is_start:
			target = run
			break
	check_true("some straight can take a climb", target != null)
	if target == null:
		return

	layout.elevation[target.cells[target.cells.size() / 2]] = target.max_level
	var raised := layout.compile()
	check_true("raised layout still compiles", raised.ok)

	var result := TrackBuilder.new().measure(raised.segments)
	check_true("still closes with a hill", result.closed)
	check_near("height returns to zero", result.height_gap, 0.0, 0.001)
	check_true("and actually climbs (%.1f m)" % result.peak, result.peak > 1.0)

	# A level beyond what the straight can pay for must be refused, not built.
	layout.elevation[target.cells[target.cells.size() / 2]] = TrackLayout.MAX_LEVEL + 5
	var over := layout.compile()
	for run in over.runs:
		check_true("level never exceeds what fits", run.level <= run.max_level)
	check_true("over-raised layout still closes",
		TrackBuilder.new().measure(over.segments).closed)


## The promise the handle editing makes: an edit either produces a valid loop or
## is refused outright. If this slips, dragging silently starts making circuits
## the compiler will reject, and the editor is back to fighting the player.
func test_shape_edits_stay_valid() -> void:
	var layout := sample_layout()
	var corners := TrackShape.corners_of(layout.cells)
	check("corners found", corners.size(), 8)
	check("cells round-trip through corners",
		TrackShape.cells_from_corners(corners).size(), layout.cells.size())

	# Every corner, dragged a long way in each direction. Whatever comes back is
	# either empty or a circuit the compiler accepts — never anything between.
	var accepted := 0
	var refused := 0
	for i in corners.size():
		for delta in [
			Vector2i(6, 0), Vector2i(-6, 0), Vector2i(0, 6), Vector2i(0, -6),
			Vector2i(20, 20), Vector2i(-20, -20), Vector2i(3, -4),
		]:
			var moved := TrackShape.move_corner(corners, i, corners[i] + delta)
			if moved.is_empty():
				refused += 1
				continue
			accepted += 1
			var probe := TrackLayout.new()
			probe.cells = TrackShape.cells_from_corners(moved)
			probe.start_cell = probe.cells[0]
			var compiled := probe.compile()
			check_true("drag %d by %s leaves a loop" % [i, delta],
				not TrackShape.walk(probe.cells).is_empty())
			# It must also be a circuit, not merely a ring.
			check_true("drag %d by %s compiles" % [i, delta], compiled.ok)
			check_true("drag %d by %s closes" % [i, delta],
				TrackBuilder.new().measure(compiled.segments).closed)
	check_true("some drags were accepted", accepted > 0)
	# A drag right across the circuit has to be refused, or the loop could fold
	# onto itself and the road would run through its own surface.
	check_true("some drags were refused", refused > 0)

## Sliding a whole straight, and the two operations that change how many corners
## there are.
func test_shape_add_and_remove() -> void:
	var layout := sample_layout()
	var corners := TrackShape.corners_of(layout.cells)

	var slid := TrackShape.move_edge(corners, 0, corners[0] + Vector2i(0, -3))
	check_true("a straight can be slid", not slid.is_empty())
	check("sliding does not change the corner count", slid.size(), corners.size())

	var bumped := TrackShape.insert_bump(corners, 0, corners[0], -6)
	check_true("a bend can be added", not bumped.is_empty())
	check("adding a bend adds four corners", bumped.size(), corners.size() + 4)
	check_true("the bigger loop is still valid", TrackShape.corners_valid(bumped))

	var straightened := TrackShape.straighten_at(bumped, 2)
	check_true("the bend can be taken out again", not straightened.is_empty())
	check_true("and that leaves fewer corners", straightened.size() < bumped.size())

	# The floor holds: a plain rectangle cannot be reduced below four corners.
	var square: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(12, 0), Vector2i(12, 8), Vector2i(0, 8),
	]
	check_true("cannot straighten below four corners",
		TrackShape.straighten_at(square, 1).is_empty())

## Redundant vertices have to go, or the loop accumulates handles that are not
## bends — they would show a grab dot that does nothing and inflate the corner
## count the player is shown.
func test_shape_prunes_non_corners() -> void:
	var with_flat: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(6, 0), Vector2i(12, 0),  # middle is not a bend
		Vector2i(12, 8), Vector2i(0, 8),
	]
	var pruned := TrackShape.prune(with_flat)
	check("collinear vertex dropped", pruned.size(), 4)
	check_true("the loop survives pruning", TrackShape.corners_valid(pruned))

## Anything that is not one simple ring must be rejected by the same test the
## editor uses to police drags, so the two can never disagree.
func test_shape_rejects_bad_rings() -> void:
	var good := sample_layout().cells
	check_true("a real loop walks", not TrackShape.walk(good).is_empty())

	var gapped: Array[Vector2i] = []
	gapped.assign(good.slice(0, good.size() - 2))
	check_true("a gapped loop does not walk", TrackShape.walk(gapped).is_empty())

	var spurred: Array[Vector2i] = good.duplicate()
	spurred.append(good[4] + Vector2i(0, -1))
	check_true("a spur does not walk", TrackShape.walk(spurred).is_empty())

	var doubled: Array[Vector2i] = good.duplicate()
	doubled.append(good[0])
	check_true("a repeated cell does not walk", TrackShape.walk(doubled).is_empty())

	var two: Array[Vector2i] = good.duplicate()
	for x in 6:
		two.append(Vector2i(400 + x, 400))
		two.append(Vector2i(400 + x, 403))
	for y in range(401, 403):
		two.append(Vector2i(400, y))
		two.append(Vector2i(405, y))
	check_true("two separate rings do not walk", TrackShape.walk(two).is_empty())

## A bend has to be draggable clean through its own straight and out the other
## side. It could once only be pushed back as far as flat, where it collapsed and
## the drag died — so a circuit could grow outward but never inward.
func test_bend_can_cross_its_straight() -> void:
	var square: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(18, 0), Vector2i(18, 12), Vector2i(0, 12),
	]
	# Outward on the top straight is negative y; inward is positive.
	var outward := TrackShape.insert_bump(square, 0, Vector2i(9, 0), -TrackShape.MIN_EDGE)
	check_true("a bend can be added outward", not outward.is_empty())
	var inward := TrackShape.insert_bump(square, 0, Vector2i(9, 0), TrackShape.MIN_EDGE)
	check_true("a bend can be added inward", not inward.is_empty())

	# From an outward bend, the outer edge must reach positions on the far side.
	var reached_inward := 0
	for target in [3, 5, 8]:
		var moved := TrackShape.move_edge(outward, 2, Vector2i(9, target))
		if moved.is_empty():
			continue
		var depth := 0
		for c in moved:
			depth = maxi(depth, c.y if c.y < 12 else 0)
		if depth > 0:
			reached_inward += 1
		check_true("bend dragged to y=%d stays a loop" % target,
			not TrackShape.walk(TrackShape.cells_from_corners(moved)).is_empty())
	check_true("an outward bend can be dragged inward", reached_inward > 0)

	# And the resulting inward circuit is drivable, not merely well-formed.
	var probe := TrackLayout.new()
	probe.cells = TrackShape.cells_from_corners(
		TrackShape.move_edge(outward, 2, Vector2i(9, 8))
	)
	probe.start_cell = probe.cells[0]
	var compiled := probe.compile()
	check_true("an inward bend compiles", compiled.ok)
	check_true("an inward bend closes",
		TrackBuilder.new().measure(compiled.segments).closed)

## Joining up a half-drawn loop. Drawing freehand nearly always ends with two
## ends close but not touching, and closing that by hand is the fiddliest part of
## the job.
func test_close_gap() -> void:
	var full := sample_layout().cells
	check("a complete loop needs nothing added",
		TrackShape.close_gap(full).size(), 0)

	for cut in [1, 3, 7]:
		var partial: Array[Vector2i] = []
		partial.assign(full.slice(0, full.size() - cut))
		var added := TrackShape.close_gap(partial)
		check_true("gap of %d can be joined" % cut, not added.is_empty())
		var joined: Array[Vector2i] = partial.duplicate()
		joined.append_array(added)
		check_true("gap of %d closes into a ring" % cut,
			not TrackShape.walk(joined).is_empty())
		var probe := TrackLayout.new()
		probe.cells = joined
		probe.start_cell = joined[0]
		check_true("gap of %d yields a drivable circuit" % cut, probe.compile().ok)

	# A hole in the middle of a straight, rather than a missing tail.
	var holed: Array[Vector2i] = []
	for c in full:
		if c.y == 0 and c.x >= 4 and c.x <= 8:
			continue
		holed.append(c)
	var patch := TrackShape.close_gap(holed)
	check_true("a hole mid-straight can be joined", not patch.is_empty())
	var repaired: Array[Vector2i] = holed.duplicate()
	repaired.append_array(patch)
	check_true("and closes into a ring",
		not TrackShape.walk(repaired).is_empty())

	# Nothing sensible to do with a branch, so it must decline rather than guess.
	var spurred: Array[Vector2i] = full.duplicate()
	spurred.append(full[4] + Vector2i(0, -1))
	check("a branched loop is declined", TrackShape.close_gap(spurred).size(), 0)

## The fill between two mouse samples. Painting only the sampled cells left a
## dotted line; filling diagonally left cells touching at their corners only,
## which are not neighbours, so the road was still broken at every step.
func test_stroke_fill_is_orthogonal() -> void:
	for pair in [
		[Vector2i(0, 0), Vector2i(12, 0)],
		[Vector2i(0, 0), Vector2i(0, 9)],
		[Vector2i(4, 10), Vector2i(0, 7)],
		[Vector2i(0, 0), Vector2i(7, 7)],
		[Vector2i(5, 5), Vector2i(-6, -3)],
		[Vector2i(3, 3), Vector2i(3, 3)],
	]:
		var from: Vector2i = pair[0]
		var to: Vector2i = pair[1]
		var path := TrackShape.orthogonal_path(from, to)
		var label := "%s to %s" % [from, to]
		if from == to:
			check("%s needs no fill" % label, path.size(), 0)
			continue
		check("%s ends at the target" % label, path[path.size() - 1], to)
		# Every step exactly one cell, along exactly one axis.
		var at := from
		var orthogonal := true
		for cell in path:
			var d := cell - at
			if absi(d.x) + absi(d.y) != 1:
				orthogonal = false
			at = cell
		check_true("%s steps orthogonally" % label, orthogonal)
		# No gaps: the whole stroke has to be one connected run of cells.
		var cells: Array[Vector2i] = [from]
		cells.append_array(path)
		var occupied := {}
		for c in cells:
			occupied[c] = true
		var connected := true
		for c in cells:
			if c != from and c != to and TrackShape.neighbour_count(occupied, c) < 2:
				connected = false
		check_true("%s leaves no break" % label, connected)

## Where the timer actually fires, measured against the geometry the player can
## see rather than against the constant that positions it.
##
## Two separate mistakes put the clock ahead of the line, and both were invisible
## from behind the wheel because the HUD has no reference to disagree with:
##
##  - Gate 0 sat at arc zero, which is the *leading edge* of the `roadStart`
##    tile. That tile is 2 units long and carries the stripe and gantry across
##    its middle, so the lap started and ended 13 m early.
##  - `body_entered` fires when the car touches the gate's leading *face*, not
##    its centre, so the gate's 4 m depth cost another 2 m.
func test_timing_gate_sits_on_the_start_line() -> void:
	var tool_script := load("res://tools/build_track.gd")
	for entry in [
		["ardennes", tool_script.ARDENNES],
		["monte_carlo", tool_script.MONTE_CARLO],
		["la_sarthe", tool_script.LA_SARTHE],
	]:
		var name: String = entry[0]
		var result := TrackBuilder.new().build(name, entry[1])
		var gantry := _gantry_position(result.root)
		check_true("%s has a gantry to measure against" % name, gantry != Vector3.INF)
		if gantry == Vector3.INF:
			result.root.free()
			continue

		var gate0: Area3D = result.root.get_node("Checkpoints/Checkpoint00")
		var box: BoxShape3D = gate0.get_child(0).shape
		# The face the car reaches first is half the box's depth back along the
		# direction of travel; that plane, not the centre, is the trigger.
		var forward := Basis(Vector3.UP, gate0.rotation.y) * Vector3(0, 0, 1)
		var trigger: Vector3 = gate0.position - forward * (box.size.z * 0.5)

		var gap := Vector2(trigger.x - gantry.x, trigger.z - gantry.z).length()
		check_true("%s times the lap at the line (%.2f m out)" % [name, gap], gap < 2.0)

		# And the grid slot is still a sensible run-up behind that line.
		var spawn: Marker3D = result.root.get_node("SpawnPoint")
		var run_up := Vector2(trigger.x - spawn.position.x, trigger.z - spawn.position.z).length()
		check_true("%s run-up is %.1f m" % [name, run_up], run_up > 8.0 and run_up < 40.0)
		result.root.free()

## Which side of the line the starting grid is on, and which way round it is.
##
## Two separate ways of getting it backwards, and neither breaks anything:
##
##  - `roadStartPositions` paints four slots marching towards the tile's *exit*
##    end, so it belongs before `roadStart`. Emitted after the line — which is
##    how all three circuits and the compiler first had it — the whole grid sits
##    past the line running away from it, and the car is parked in what should
##    be the back row.
##  - Each slot is a U, barred at one end and open at the other, and the car
##    noses in through the opening and stops at the bar. As authored the bar is
##    at the end the walker drives *in* through, so the boxes have to be turned
##    round with them: `PIECES` enters this one at S. Left alone, the grid is one
##    the car reverses into.
##
## The loop still closes either way, the lap is still timed at the line, and the
## only symptom is that the start looks wrong.
##
## Measured off the painted markings rather than off the tile order, because the
## tile order is the thing that was wrong. The slots are the grey geometry inside
## the road's own width; the kerbs are the grey geometry outside it.
func test_starting_grid_leads_up_to_the_line() -> void:
	var tool_script := load("res://tools/build_track.gd")
	for entry in [
		["ardennes", tool_script.ARDENNES],
		["monte_carlo", tool_script.MONTE_CARLO],
		["la_sarthe", tool_script.LA_SARTHE],
	]:
		var name: String = entry[0]
		var result := TrackBuilder.new().build(name, entry[1])
		var gantry := _gantry_position(result.root)
		var holder := _tile_holder(result.root, "roadStartPositions")
		check_true("%s has a grid tile to measure" % name,
			holder != null and gantry != Vector3.INF)
		if holder == null or gantry == Vector3.INF:
			result.root.free()
			continue

		# The start straight is straight, so the heading at the line is also the
		# heading across the grid.
		var gate0: Area3D = result.root.get_node("Checkpoints/Checkpoint00")
		var forward := Basis(Vector3.UP, gate0.rotation.y) * Vector3(0, 0, 1)
		var right := forward.cross(Vector3.UP)

		var visuals: Node3D = result.root.get_node("RoadVisuals")
		var inst: Node3D = holder.get_child(0)
		var mi := _first_mesh_in(inst)
		var to_world := (
			visuals.transform * holder.transform * inst.transform * mi.transform
		)
		# The painted markings as triangles in (along, across) metres relative to
		# the gantry, so the shape of a slot can be read and not just its extent.
		# Negative along is behind the line.
		var paint := []
		var along := []
		for si in mi.mesh.get_surface_count():
			var mat: Material = mi.mesh.surface_get_material(si)
			if mat == null or mat.resource_name != "grey":
				continue
			var arrays := mi.mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for t in idx.size() / 3:
				var tri := []
				# Inside the road, so the kerbs down either side are left out.
				var inside := true
				for c in 3:
					var v: Vector3 = verts[idx[t * 3 + c]]
					if v.x < 0.2 or v.x > 0.8:
						inside = false
						break
					var offset: Vector3 = (to_world * v) - gantry
					tri.append(Vector2(offset.dot(forward), offset.dot(right)))
				if not inside:
					continue
				paint.append(tri)
				for p: Vector2 in tri:
					along.append(p.x)
		check_true("%s paints slots on the grid tile" % name, paint.size() >= 8)
		if paint.is_empty():
			result.root.free()
			continue

		var front: float = along.max()
		check_true("%s starts the grid behind the line (front slot %.1f m)"
			% [name, front], front < 0.0)
		# Two tile units of grid plus the gap to the line: any further back and
		# something has been emitted between them.
		check_true("%s runs the grid up to the line (back slot %.1f m)"
			% [name, along.min()], along.min() > -45.0)

		# The pole slot is the frontmost one. Its neighbour ends 7 m further
		# back, and a slot is under 5 m long, so 5 m of the front separates them.
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for tri in paint:
			for p: Vector2 in tri:
				if p.x < front - 5.0:
					continue
				lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
				hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		var mid := (lo.y + hi.y) * 0.5
		var pole := gantry + forward * ((lo.x + hi.x) * 0.5) + right * mid

		# Which way the U faces, sampled half a metre in from either end of the
		# slot, down its middle. The bar spans the full width and the sides do
		# not reach the middle, so exactly one of these two points is painted —
		# and it has to be the one the car's nose ends up against.
		check_true("%s bars the front of the pole slot" % name,
			_paint_covers(paint, Vector2(hi.x - 0.5, mid)))
		check_true("%s leaves the back of the pole slot open to drive into" % name,
			not _paint_covers(paint, Vector2(lo.x + 0.5, mid)))

		# And the car is parked in it, rather than straddling the paint.
		var spawn: Marker3D = result.root.get_node("SpawnPoint")
		var off := Vector2(spawn.position.x - pole.x, spawn.position.z - pole.z).length()
		check_true("%s parks the car in the pole slot (%.2f m off centre)"
			% [name, off], off < 1.0)
		result.root.free()

## Whether any of the painted triangles covers a point, both in (along, across).
func _paint_covers(paint: Array, at: Vector2) -> bool:
	for tri in paint:
		var a: Vector2 = tri[0]
		var b: Vector2 = tri[1]
		var c: Vector2 = tri[2]
		# Inside means on the same side of all three edges; the winding of one
		# triangle in isolation is not worth assuming either way.
		var d1 := (at - a).cross(b - a)
		var d2 := (at - b).cross(c - b)
		var d3 := (at - c).cross(a - c)
		var any_neg := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
		var any_pos := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
		if not (any_neg and any_pos):
			return true
	return false

## Gates must stay evenly spaced around the lap after being offset onto the line,
## or a mis-wrapped arc would bunch them without breaking anything visibly.
func test_gates_stay_evenly_spaced() -> void:
	var result := TrackBuilder.new().build(
		"spacing", load("res://tools/build_track.gd").ARDENNES)
	var gates: Array = result.root.get_node("Checkpoints").get_children()
	check("gate count", gates.size(), TrackBuilder.CHECKPOINT_COUNT)
	var lo := 1e9
	var hi := -1e9
	for i in gates.size():
		var a: Vector3 = gates[i].position
		var b: Vector3 = gates[(i + 1) % gates.size()].position
		var d: float = Vector2(b.x - a.x, b.z - a.z).length()
		lo = minf(lo, d)
		hi = maxf(hi, d)
	# Straight-line gaps run shorter than the arc through corners, so this is a
	# generous band - it is catching bunching, not measuring precisely.
	check_true("no gate pair is bunched (%.0f..%.0f m)" % [lo, hi], lo > 30.0)
	check_true("no gate pair is stretched", hi < result.length * 0.5)
	result.root.free()

## Centre of the gantry over the start line, from the tall grey geometry of the
## `roadStart` tile. Deliberately reads the art rather than the builder's own
## constant, so a wrong constant cannot make the test agree with itself.
##
## Found by name rather than taken as the first tile: `roadStartPositions` goes
## down ahead of it, so the first tile of the lap is the grid, not the line.
func _gantry_position(root_node: Node3D) -> Vector3:
	var holder := _tile_holder(root_node, "roadStart")
	if holder == null:
		return Vector3.INF
	var inst: Node3D = holder.get_child(0)
	var mi := _first_mesh_in(inst)
	if mi == null:
		return Vector3.INF
	var sum := Vector3.ZERO
	var count := 0
	for si in mi.mesh.get_surface_count():
		var mat := mi.mesh.surface_get_material(si)
		if mat == null or mat.resource_name != "grey":
			continue
		for v in mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
			if v.y > 0.15:
				sum += v
				count += 1
	if count == 0:
		return Vector3.INF
	var local: Vector3 = sum / float(count)
	var visuals: Node3D = root_node.get_node("RoadVisuals")
	return visuals.transform * (
		holder.transform * (inst.transform * (mi.transform * local))
	)

## The holder wrapping the first tile of the given piece. Every holder is an
## unnamed `Node3D` carrying one instanced glb, and the instance keeps the
## piece's own name, so that is what identifies it.
func _tile_holder(root_node: Node3D, piece: String) -> Node3D:
	for holder in root_node.get_node("RoadVisuals").get_children():
		if holder.get_child_count() > 0 and holder.get_child(0).name == piece:
			return holder
	return null

func _first_mesh_in(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var m := _first_mesh_in(c)
		if m != null:
			return m
	return null

## A saved circuit has to be reachable from the menu for editing, including one
## too broken to drive — otherwise an unfinished track is a dead row that cannot
## be fixed without hunting through the editor's own dropdown.
func test_title_offers_editing_of_custom_tracks() -> void:
	var good := sample_layout()
	good.display_name = "Menu Test"
	TrackStore.save(good)

	var broken := TrackLayout.new()
	broken.display_name = "Menu Test Broken"
	broken.cells.assign(good.cells.slice(0, good.cells.size() - 4))
	TrackStore.save(broken)

	var title: Control = load("res://scenes/title.tscn").instantiate()
	root.add_child(title)

	var rows: VBoxContainer = title.get_node("Centre/Rows/TrackScroll/Tracks")
	check("a row per circuit", rows.get_child_count(), GameState.all_tracks().size())

	var built_in_with_edit := 0
	var custom_without_edit := 0
	var broken_row_drivable := false
	var broken_row_editable := false
	for i in rows.get_child_count():
		var row: Node = rows.get_child(i)
		var main: Button = row.get_child(0)
		# Every row has a second child: an Edit button on the custom circuits, and
		# on the shipped ones a plain spacer reserving the same width so the menu's
		# right edge stays straight. Only the button counts as an Edit affordance.
		var has_edit: bool = row.get_child_count() > 1 and row.get_child(1) is Button
		var custom: bool = GameState.all_tracks()[i].get("custom", false)
		if not custom and has_edit:
			built_in_with_edit += 1
		if custom and not has_edit:
			custom_without_edit += 1
		if main.text.begins_with(broken.display_name):
			broken_row_drivable = not main.disabled
			broken_row_editable = has_edit
	# Shipped circuits are baked scenes with no layout, so there is nothing to
	# open; offering Edit on them would be a dead button.
	check("no Edit on the shipped circuits", built_in_with_edit, 0)
	check("every custom circuit offers Edit", custom_without_edit, 0)
	check_true("a broken circuit is not drivable", not broken_row_drivable)
	check_true("but is still editable", broken_row_editable)

	title.free()
	TrackStore.delete(good.id)
	TrackStore.delete(broken.id)

## Deleting from the menu, which is the only place a finished circuit can be
## thrown away without opening the editor first. The button arms rather than
## fires, so what is really under test is that one press changes nothing: it sits
## a row-width from "drive this circuit" and there is no undo.
func test_title_deletes_a_custom_track() -> void:
	var doomed := sample_layout()
	doomed.display_name = "Delete Me"
	doomed.id = ""
	TrackStore.save(doomed)
	# A record to leave behind. Ids are derived from the name and handed back out
	# as soon as the file is gone, so this must not outlive the circuit it
	# belongs to or the next "Delete Me" inherits a lap it never drove.
	GameState.save_best_lap(doomed.id, 42.0, PackedFloat32Array())

	var title: Control = load("res://scenes/title.tscn").instantiate()
	root.add_child(title)
	var rows: VBoxContainer = title.get_node("Centre/Rows/TrackScroll/Tracks")
	var before := rows.get_child_count()

	var shipped_with_delete := 0
	var row: Node = null
	for i in rows.get_child_count():
		var candidate: Node = rows.get_child(i)
		if not GameState.all_tracks()[i].get("custom", false):
			# Card plus one spacer. A third child would mean a shipped circuit is
			# offering to delete a baked scene that is not the player's to remove.
			if candidate.get_child_count() > 2:
				shipped_with_delete += 1
		if (candidate.get_child(0) as Button).text == doomed.display_name:
			row = candidate
	check("no Delete on the shipped circuits", shipped_with_delete, 0)
	check_true("the doomed circuit has a row", row != null)
	if row == null:
		title.free()
		return

	check("a custom row is card, Edit and Delete", row.get_child_count(), 3)
	var delete: Button = row.get_child(2)
	check("Delete starts unarmed", delete.text, "Delete")

	delete.pressed.emit()
	check("one press only arms it", delete.text, "Sure?")
	check("and removes no row", rows.get_child_count(), before)
	check_true("leaving the circuit on disk", TrackStore.load_layout(doomed.id) != null)

	delete.pressed.emit()
	check("the second press takes the row", rows.get_child_count(), before - 1)
	check_true("and the file with it", TrackStore.load_layout(doomed.id) == null)
	check("and the lap record with that", GameState.best_lap_for(doomed.id), 0.0)

	title.free()

## Sustained elevation: height held across a corner rather than rising and falling
## inside one straight. This is what the bridge corner tiles are for, and the
## thing that makes an elevated *section* possible rather than just a crest.
func test_sustained_elevation_across_corners() -> void:
	var layout := _roomy_rectangle()
	var first := layout.compile()
	check_true("the test circuit compiles flat", first.ok)

	# Raise a straight, the corner after it, and the straight after that.
	layout.elevation[first.runs[1].cells[0]] = 2
	layout.elevation[first.corners[1].cell] = 2
	layout.elevation[first.runs[2].cells[0]] = 2
	var raised := layout.compile()
	check_true("the raised circuit compiles", raised.ok)

	check("the straight is held up", raised.runs[1].level, 2)
	check("the corner is held up", raised.corners[1].level, 2)
	check("the next straight is held up", raised.runs[2].level, 2)

	# A corner that holds height must use the tile that can, and the run between
	# two raised corners must need no ramps at all.
	var bridge_corners := 0
	var ramps := 0
	for seg in raised.segments:
		if String(seg[1]).begins_with("roadCornerBridge"):
			bridge_corners += 1
		if seg[1] == "roadRampLongCurved":
			ramps += int(seg[2])
	check("one bridge corner is used", bridge_corners, 1)
	# Two ramps of two levels: up once at the start, down once at the end. A
	# section that dropped for the corner would need four.
	check("the height is gained and lost once", ramps, 4)

	var result := TrackBuilder.new().measure(raised.segments)
	check_true("a sustained section still closes", result.closed)
	check_near("and returns to ground level", result.height_gap, 0.0, 0.001)
	check_true("and actually climbs (%.1f m)" % result.peak, result.peak > 5.0)

	# The invariant the whole model rests on: the levels the resolver settled on
	# are the heights the builder actually walked. They are tracked separately —
	# levels are absolute per segment, while the builder only ever moves height
	# via ramps — so they can silently diverge, and then the resolver's arithmetic
	# would be describing a circuit that was never built.
	check_near("the built height matches the resolved level",
		result.peak, _metres_per_level() * _highest_level(raised), 0.05)

## One level of climb, in metres: half a tile unit of rise, scaled.
func _metres_per_level() -> float:
	return 0.5 * TrackBuilder.SCALE * TrackBuilder.VERT

func _highest_level(compiled: TrackLayout.Compiled) -> int:
	var highest := 0
	for run in compiled.runs:
		highest = maxi(highest, run.level)
	for corner in compiled.corners:
		highest = maxi(highest, corner.level)
	return highest

## A change of several levels has to read as one hill, not as a set of steps.
##
## A level change of N is N ramp tiles in a row, and `roadRampLongCurved` eases in
## *and* out of its own two cells — its gradient is zero at both ends. Traced a
## tile at a time, a 0-to-3 climb therefore went up in three humps: the gradient
## reached full grade and came back to nothing three times, and the car pitched at
## every seam. The chain now carries a single profile across all of it.
func test_a_multi_level_climb_is_one_hill() -> void:
	var layout := _roomy_rectangle()
	var first := layout.compile()
	layout.elevation[first.runs[1].cells[0]] = 3
	var raised := layout.compile()
	check("the straight really does climb three levels", raised.runs[1].level, 3)

	var built := TrackBuilder.new()
	built.measure(raised.segments)
	var span := _climb_span(built.centreline)
	check_true("a climbing stretch was found", span[1] > span[0] + 4)
	if span[1] <= span[0] + 4:
		return

	var grades := _grades(built.centreline, span[0], span[1])
	var peak_at := 0
	for i in grades.size():
		if grades[i] > grades[peak_at]:
			peak_at = i
	# Steepening all the way to one peak and easing off all the way down from it.
	# Any dip on the way up is a seam between two tiles that each eased to flat.
	var reversals := 0
	for i in grades.size() - 1:
		var rising: bool = grades[i + 1] > grades[i] + 0.0005
		var falling: bool = grades[i + 1] < grades[i] - 0.0005
		if (i < peak_at and falling) or (i >= peak_at and rising):
			reversals += 1
	check("the gradient never reverses on the way up or down", reversals, 0)

	# Spreading the same ease over three tiles instead of one is not allowed to
	# make the hill steeper: an eased ramp's steepest point is a fixed multiple of
	# its average grade, so stretching rise and length together leaves the peak
	# where it was. A single-level ramp is the yardstick.
	var one_level := _roomy_rectangle()
	one_level.elevation[one_level.compile().runs[1].cells[0]] = 1
	var shallow := TrackBuilder.new()
	shallow.measure(one_level.compile().segments)
	var single := _climb_span(shallow.centreline)
	var reference: float = _grades(shallow.centreline, single[0], single[1]).max()
	check_true("and is no steeper than a single-level ramp (%.3f vs %.3f)"
		% [grades[peak_at], reference], grades[peak_at] <= reference + 0.005)

## The visible road has to be the road the car drives on.
##
## Collision is a ribbon generated along the centreline, while the tarmac the
## player sees is the Kenney tile mesh — and inside a ramp chain those two now
## want different shapes, because the chain's profile is not the profile baked
## into any one tile. The builder closes the gap by lifting the tile's vertices
## onto the centreline. If it ever stops doing that the car drives on a smooth
## grade through a road that still visibly undulates, which no other test would
## notice: every elevation check in this suite reads the ribbon.
func test_ramp_tiles_follow_the_climb_they_are_on() -> void:
	var layout := _roomy_rectangle()
	layout.elevation[layout.compile().runs[1].cells[0]] = 3

	var built := TrackBuilder.new()
	var result := built.build("ramp_mesh_test", layout.compile().segments)
	var line := built.centreline
	var span := _climb_span(line)

	var verts: Array[Vector3] = []
	_road_vertices(result.root, Transform3D(), result.root, verts)
	check_true("the built track has geometry", verts.size() > 100)

	# The tile is sampled where its own vertices are, so the comparison is against
	# real mesh rows rather than an interpolation of them. A tolerance under a
	# metre is enough: left uncorrected, the seams of a three-level chain sit more
	# than 1.3 m off the grade the ribbon takes.
	var worst := 0.0
	var sampled := 0
	for step in 12:
		var idx: int = span[0] + int((span[1] - span[0]) * float(step) / 11.0)
		var c: Vector3 = line[idx]
		var top := -INF
		for v in verts:
			if Vector2(v.x - c.x, v.z - c.z).length() < 5.0:
				top = maxf(top, v.y)
		if top == -INF:
			continue
		sampled += 1
		worst = maxf(worst, absf(top - c.y))
	check_true("the climb was sampled against the meshes", sampled >= 6)
	check_true("the tarmac sits on the ribbon all the way up (worst %.2f m)" % worst,
		worst < 0.8)
	result.root.free()

## The stretch of centreline that is climbing: the longest run of strictly rising
## points. Returns [first, last] indices.
func _climb_span(line: Array[Vector3]) -> Array[int]:
	var best := [0, 0]
	var start := -1
	for i in line.size() - 1:
		if line[i + 1].y > line[i].y + 0.0001:
			if start < 0:
				start = i
		elif start >= 0:
			if i - start > best[1] - best[0]:
				best = [start, i]
			start = -1
	if start >= 0 and line.size() - 1 - start > best[1] - best[0]:
		best = [start, line.size() - 1]
	return [best[0], best[1]]

## Gradient — rise over horizontal run — between consecutive centreline points.
func _grades(line: Array[Vector3], lo: int, hi: int) -> Array[float]:
	var out: Array[float] = []
	for i in range(lo, hi):
		var flat := Vector2(line[i + 1].x - line[i].x, line[i + 1].z - line[i].z)
		if flat.length() > 0.001:
			out.append((line[i + 1].y - line[i].y) / flat.length())
	return out

## Every mesh vertex in the track, in the track root's own space. The tiles are
## not in the scene tree, so the transform has to be accumulated by hand rather
## than read off `global_transform`.
func _road_vertices(n: Node, so_far: Transform3D, root_node: Node,
		out: Array[Vector3]) -> void:
	var here := so_far if n == root_node else so_far * (n as Node3D).transform
	var mi := n as MeshInstance3D
	if mi != null and mi.mesh != null:
		for s in mi.mesh.get_surface_count():
			var arrays: Array = mi.mesh.surface_get_arrays(s)
			for v in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array):
				out.append(here * v)
	for c in n.get_children():
		if c is Node3D:
			_road_vertices(c, here, root_node, out)

func test_a_corner_can_be_raised_on_its_own() -> void:
	var layout := _roomy_rectangle()
	var first := layout.compile()
	layout.elevation[first.corners[1].cell] = 1
	var raised := layout.compile()
	check_true("a lone raised corner compiles", raised.ok)
	check("the corner is raised", raised.corners[1].level, 1)
	var result := TrackBuilder.new().measure(raised.segments)
	check_true("and closes", result.closed)
	check_true("and climbs", result.peak > 1.0)
	# The straights either side have to do the climbing for it.
	check_true("the straight before ramps up to it", raised.runs[1].exit_level == 1)
	check_true("the straight after ramps back down", raised.runs[2].entry_level == 1)

## Height closes because the corner immediately before the start line is pinned to
## the ground. Without that pin the running height would not return to where it
## began and the circuit would not join up vertically.
func test_start_line_stays_on_the_ground() -> void:
	var layout := _roomy_rectangle()
	var first := layout.compile()
	var last := first.corners.size() - 1
	layout.elevation[first.corners[last].cell] = 3
	layout.elevation[first.runs[0].cells[0]] = 3
	var raised := layout.compile()
	check_true("still compiles", raised.ok)
	check("the corner before the line stays down", raised.corners[last].level, 0)
	check("the start run stays flat", raised.runs[0].level, 0)
	check_true("so the circuit still closes",
		TrackBuilder.new().measure(raised.segments).closed)

## Every level the editor offers has to be one the compiler will actually build,
## and any level it will not build has to be reduced rather than emitted broken.
func test_elevation_requests_are_reduced_not_broken() -> void:
	var layout := _roomy_rectangle()
	var first := layout.compile()

	# Ask for far too much, everywhere at once.
	for run in first.runs:
		if not run.cells.is_empty():
			layout.elevation[run.cells[0]] = TrackLayout.MAX_LEVEL + 4
	for corner in first.corners:
		layout.elevation[corner.cell] = TrackLayout.MAX_LEVEL + 4
	var greedy := layout.compile()
	check_true("an impossible request still compiles", greedy.ok)
	for i in greedy.runs.size():
		check_true("run %d is within its own limit" % i,
			greedy.runs[i].level <= greedy.runs[i].max_level)
		check_true("run %d can pay for its ramps" % i,
			greedy.runs[i].ramp_cells() <= greedy.runs[i].free)
		check_true("corner %d is within its limit" % i,
			greedy.corners[i].level <= greedy.corners[i].max_level)
	var greedy_result := TrackBuilder.new().measure(greedy.segments)
	check_true("and it still closes", greedy_result.closed)
	check_near("the reduced levels are what got built",
		greedy_result.peak, _metres_per_level() * _highest_level(greedy), 0.05)

	# The advertised headroom must be honest: raising each segment to the max it
	# reports has to keep the circuit buildable.
	var honest := _roomy_rectangle()
	var probe := honest.compile()
	for i in probe.runs.size():
		if not probe.runs[i].cells.is_empty():
			honest.elevation[probe.runs[i].cells[0]] = probe.runs[i].max_level
	var at_max := honest.compile()
	check_true("a circuit at its advertised maximum compiles", at_max.ok)
	check_true("and closes", TrackBuilder.new().measure(at_max.segments).closed)

## The old behaviour is now just the case where both neighbouring corners are on
## the ground, and it has to still work.
func test_plateau_inside_one_straight_still_works() -> void:
	var layout := _roomy_rectangle()
	var first := layout.compile()
	layout.elevation[first.runs[2].cells[0]] = 1
	var raised := layout.compile()
	check("only that straight is raised", raised.runs[2].level, 1)
	check("its corners stay down", raised.corners[1].level + raised.corners[2].level, 0)
	var bridge_corners := 0
	for seg in raised.segments:
		if String(seg[1]).begins_with("roadCornerBridge"):
			bridge_corners += 1
	check("no bridge corner is needed", bridge_corners, 0)
	var result := TrackBuilder.new().measure(raised.segments)
	check_true("a plateau closes", result.closed)
	check_true("and climbs", result.peak > 1.0)

## The road surface has to follow a sustained section, including over the corner —
## the same one-sided-collision trap the shipped circuits have a test for, but on
## geometry only the editor can produce.
##
# --- banking ---

## The bank profile the builder hands the rest of the game.
##
## Checks the shape of it rather than exact numbers: full bank in the corners,
## flat down the straights, the right sign for the direction of turn, and no step
## anywhere. The step is the one that matters — a discontinuity in roll is a
## surface the wheels drop off, and it would not be visible in a screenshot.
func test_corners_are_banked() -> void:
	var builder := TrackBuilder.new()
	builder.measure(load("res://tools/build_track.gd").ARDENNES)
	check("a bank angle per centreline point",
		builder.bank.size(), builder.centreline.size())

	var peak := 0.0
	var flat := 0
	for b in builder.bank:
		peak = maxf(peak, absf(b))
		if absf(b) <= TrackBuilder.BANK_EPSILON:
			flat += 1
	# Ardennes' biggest corners are size 3, so they set the peak.
	check_near("the widest corners reach their full bank",
		rad_to_deg(peak), TrackBuilder.BANK_DEGREES[3], 0.01)
	check_true("and nothing exceeds the ceiling",
		rad_to_deg(peak) <= TrackBuilder.MAX_BANK_DEG + 0.001)
	# Banking the whole lap would mean the transitions never resolve, which is
	# how a too-long transition or a broken wrap would show up.
	check_true("the straights come back to flat (%d of %d points)"
		% [flat, builder.bank.size()], flat > builder.bank.size() / 3)

	# Which way each point is turning, read off the centreline itself rather than
	# taken from the layout, so the test cannot inherit a sign error from the
	# thing it is checking. Ardennes turns both ways, so this covers both.
	var wrong_way := 0
	var tested := 0
	for i in range(1, builder.centreline.size() - 1):
		if absf(builder.bank[i]) < deg_to_rad(2.0):
			continue
		var back: Vector3 = builder.centreline[i] - builder.centreline[i - 1]
		var on: Vector3 = builder.centreline[i + 1] - builder.centreline[i]
		var a := Vector2(back.x, back.z).normalized()
		var b := Vector2(on.x, on.z).normalized()
		var turn := a.x * b.y - a.y * b.x
		if absf(turn) < 0.01:
			continue  # a transition running along a straight, with nothing to turn
		tested += 1
		# A left turn is negative here, and the road banks positive for it: the
		# outside edge, on the right, is the one that lifts.
		if signf(builder.bank[i]) == signf(turn):
			wrong_way += 1
	check_true("there are banked corners to check (%d points)" % tested, tested > 20)
	check("every corner banks the way it turns", wrong_way, 0)

	# No step. The profile wraps, so the join at the start line is checked too —
	# that is where a corner's exit transition runs off the end of the array.
	var worst := 0.0
	for i in builder.bank.size():
		var next: int = (i + 1) % builder.bank.size()
		var span: float = builder.centreline[i].distance_to(
			builder.centreline[next if next > 0 else i]
		)
		if span < 0.01:
			continue
		worst = maxf(worst, absf(builder.bank[next] - builder.bank[i]) / span)
	check_true("the roll never steps (worst %.2f deg/m)" % rad_to_deg(worst),
		rad_to_deg(worst) < 1.5)

## The collision the car actually drives on has to lean by the angle the builder
## says, and lean *into* the corner.
##
## This is the test that ties the two halves together. Banking is applied twice
## over — once to the ribbon and once to the tile meshes — from one profile, and
## nothing about a wrong sign or a missed roll on the collision side is visible
## from behind the wheel, because the car would simply grip a road that looks
## banked and is not.
func test_banked_collision_leans_into_the_corner() -> void:
	if custom_track == null:
		return
	var builder := TrackBuilder.new()
	builder.measure(sample_layout().compile().segments)

	var at := 0
	for i in builder.bank.size() - 1:
		if absf(builder.bank[i]) > absf(builder.bank[at]):
			at = i
	var roll: float = (builder.bank[at] + builder.bank[at + 1]) * 0.5
	check_true("the sample circuit banks somewhere (%.1f deg)" % rad_to_deg(roll),
		absf(rad_to_deg(roll)) > 1.0)

	# Mid-quad rather than on a sample point, so the ray lands on one face
	# instead of the seam between two.
	var a: Vector3 = builder.centreline[at]
	var b: Vector3 = builder.centreline[at + 1]
	var mid: Vector3 = custom_track.position + (a + b) * 0.5

	# The lateral direction is worked out here from the centreline rather than
	# taken from the builder, so the test cannot agree with itself about which
	# way is sideways.
	var along := Vector2(b.x - a.x, b.z - a.z).normalized()
	var side := Vector3(-along.y, 0.0, along.x)

	var space: PhysicsDirectSpaceState3D = custom_track.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		mid + Vector3(0, 20, 0), mid - Vector3(0, 20, 0)
	)
	var hit: Dictionary = space.intersect_ray(query)
	check_true("there is road under the banked corner", not hit.is_empty())
	if hit.is_empty():
		return

	# The ribbon collides from both sides, so a normal may come back inverted.
	var normal: Vector3 = hit["normal"]
	if normal.dot(Vector3.UP) < 0.0:
		normal = -normal

	check_near("the surface leans by the banked angle",
		rad_to_deg(acos(clampf(normal.dot(Vector3.UP), -1.0, 1.0))),
		absf(rad_to_deg(roll)), 1.5)
	# A surface rolled about the tangent has its normal tipped the opposite way
	# to the raised edge, so this is what says the outside of the corner is the
	# high side and not the low one.
	check_near("and leans towards the inside of the corner",
		normal.dot(side), -sin(roll), 0.05)

## The banked tile meshes have to survive being packed into a `.tscn` and loaded
## back, or the shipped circuits drive banked and look flat.
##
## Worth its own test because the failure is silent and one-sided: collision is
## generated from the same profile either way, so the car would corner correctly
## on a road that had visibly reverted to being level.
func test_shipped_tracks_keep_their_banked_meshes() -> void:
	# Ardennes and La Sarthe bank their sweepers and Monte Carlo is deliberately
	# flat — it is a street circuit — so the shipped circuits between them check
	# that banking survives being packed *and* that asking for none gets none.
	var want_banked := {"ardennes": true, "monte_carlo": false, "la_sarthe": true}
	for info in GameState.TRACKS:
		var inst: Node3D = load(info["scene"]).instantiate()
		var visuals: Node3D = inst.get_node("RoadVisuals")
		var banked := 0
		var steepest := 0.0
		for holder in visuals.get_children():
			var slope := _road_cross_slope(holder, visuals)
			if slope > BANKED_TILE_M:
				banked += 1
			steepest = maxf(steepest, slope)

		if not want_banked.get(info["id"], false):
			# A flat tile's road surface is level to within its own thickness.
			check("track %s stays flat" % info["id"], banked, 0)
			check_true("track %s is level across the road (%.2f m)"
				% [info["id"], steepest], steepest < 0.1)
			inst.free()
			continue

		check_true("track %s has banked tiles (%d of %d)"
			% [info["id"], banked, visuals.get_child_count()], banked >= 4)
		check_true("track %s banks by a visible amount (%.2f m across the road)"
			% [info["id"], steepest], steepest > BANKED_TILE_M)
		inst.free()

## Banking is a choice, and "flat" has to be one of the answers.
##
## The zero matters twice over: a layout that says nothing about a corner gets
## the default for its radius, and one that says zero gets a flat corner. Those
## have to stay different, or a circuit could never be made flat.
func test_banking_can_be_turned_off() -> void:
	var tool_script := load("res://tools/build_track.gd")

	var flat := TrackBuilder.new()
	flat.measure(tool_script.MONTE_CARLO)
	var worst := 0.0
	for b in flat.bank:
		worst = maxf(worst, absf(b))
	check_near("a circuit asking for flat corners gets none", rad_to_deg(worst), 0.0, 0.001)

	# And a layout that says nothing at all is flat too. Banking is opt-in
	# everywhere: nothing infers it from a corner's radius or from anything else,
	# so a circuit can only lean where its author asked it to.
	var implied := TrackBuilder.new()
	var silent := []
	for seg in tool_script.ARDENNES:
		silent.append(seg.slice(0, 3) if seg[0] == "C" else seg)
	implied.measure(silent)
	var implied_worst := 0.0
	for b in implied.bank:
		implied_worst = maxf(implied_worst, absf(b))
	check_near("a layout that never mentions banking gets none",
		rad_to_deg(implied_worst), 0.0, 0.001)

	# Ardennes is the same circuit with its angles written in, so the difference
	# between the two is only ever what the layout asked for.
	var asked := TrackBuilder.new()
	asked.measure(tool_script.ARDENNES)
	var asked_worst := 0.0
	for b in asked.bank:
		asked_worst = maxf(asked_worst, absf(b))
	check_near("and one that asks for it gets exactly that",
		rad_to_deg(asked_worst), TrackBuilder.BANK_DEGREES[TrackBuilder.MAX_BANK_LEVEL], 0.01)

## A painted circuit's per-corner banking has to survive the compiler and the
## save file, or the choice is lost the moment the editor is closed.
func test_corner_banking_is_authored_and_saved() -> void:
	var layout := _roomy_rectangle()
	var first := layout.compile()
	# A freshly painted circuit is flat everywhere. Banking is something the
	# author turns on, corner by corner, and never something a new track has to
	# be told to stop doing.
	for corner in first.corners:
		check("a new corner is flat at %s" % corner.cell, corner.bank, 0)
	var plain := TrackBuilder.new()
	var result := plain.measure(first.segments)
	var worst := 0.0
	for b in plain.bank:
		worst = maxf(worst, absf(b))
	check_near("and the built circuit is flat", rad_to_deg(worst), 0.0, 0.001)
	check_true("a flat-cornered circuit still closes", result.closed)

	# One corner banked, then round-tripped through the save format.
	var cell: Vector2i = first.corners[1].cell
	layout.corner_banks[cell] = TrackBuilder.MAX_BANK_LEVEL
	layout.id = "user_banktest"
	var banked := layout.compile()
	for corner in banked.corners:
		check("only the corner asked for banks, at %s" % corner.cell,
			corner.bank, TrackBuilder.MAX_BANK_LEVEL if corner.cell == cell else 0)
	var lean := TrackBuilder.new()
	lean.measure(banked.segments)
	var leaned := 0.0
	for b in lean.bank:
		leaned = maxf(leaned, absf(b))
	check_near("and it reaches the angle asked for", rad_to_deg(leaned),
		TrackBuilder.BANK_DEGREES[TrackBuilder.MAX_BANK_LEVEL], 0.01)

	var back := TrackLayout.from_dict(layout.to_dict()).compile()
	for corner in back.corners:
		check("bank survives a save and load at %s" % corner.cell,
			corner.bank, TrackBuilder.MAX_BANK_LEVEL if corner.cell == cell else 0)

	# A track saved before banking existed has no `corner_banks` at all, and must
	# come back flat rather than inheriting anything.
	var old := layout.to_dict()
	old.erase("corner_banks")
	for corner in TrackLayout.from_dict(old).compile().corners:
		check("an older saved track loads flat at %s" % corner.cell, corner.bank, 0)

## How much the painted road surface of one tile rises across its own width, in
## metres. Reads the art's own "road" material rather than the whole tile, so
## the answer is about the driving surface and not about scenery.
##
## The height cut is not decoration. `roadStart` paints its gantry banner with
## the same "road" material as the tarmac, 0.65 units up, and without this the
## start tile reports a 4.5 m "bank" on every circuit ever built — which is how
## this first passed on a track that has no banking at all. The deck sits at
## 0.01, and the steepest banking moves it by under 0.1, so 0.3 separates them
## with room to spare.
const DECK_MAX_Y := 0.3

## Thin bands of tile, in local units, that the surface is compared within. See
## `_road_cross_slope` for why the comparison has to be banded at all.
const SLICE := 0.025

## A tile counts as banked above this much rise across the road, in metres. The
## kit's road is 9.7 m wide between the points banking is carried to, so the
## smallest angle on offer, 1.5 degrees, lifts one edge by 0.26 m and the largest
## by 0.68. At 0.3 every angle a circuit can ask for registers, and a tile with no
## banking on it at all — measured at 0.00 on Monte Carlo — cannot.
const BANKED_TILE_M := 0.3

## How much the painted road surface of one tile rises across its own width, in
## metres. Reads the art's own "road" material rather than the whole tile, so the
## answer is about the driving surface and not about scenery.
##
## **Across, not overall.** Comparing the whole tile's highest road vertex with
## its lowest measures a ramp's *climb* — 2 m of it — as though it were banking,
## which is a false pass waiting to happen on any circuit with a hill on it: it
## fails a deliberately flat one and it would let a banked circuit that had
## silently reverted to level pass on the strength of its ramps. So the surface is
## compared only within thin bands along the tile, where a ramp is level and only
## a lean shows up.
##
## The height cut is not decoration either. `roadStart` paints its gantry banner
## with the same "road" material as the tarmac, 0.65 units up, and without this
## the start tile reports a 4.5 m "bank" on every circuit ever built — which is
## how this first passed on a track that has no banking at all. The deck sits at
## 0.01, and the steepest banking moves it by under 0.1, so 0.3 separates them
## with room to spare.
func _road_cross_slope(holder: Node3D, visuals: Node3D) -> float:
	var mi := _first_mesh_in(holder)
	if mi == null or mi.mesh == null:
		return 0.0
	var bands := {}
	for s in mi.mesh.get_surface_count():
		var mat: Material = mi.mesh.surface_get_material(s)
		if mat == null or mat.resource_name != "road":
			continue
		for v in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
			var local: Vector3 = mi.transform * v
			if local.y > DECK_MAX_Y:
				continue
			var world: Vector3 = visuals.transform * (holder.transform * local)
			var band := int(round(local.z / SLICE))
			var seen: Vector2 = bands.get(band, Vector2(INF, -INF))
			bands[band] = Vector2(minf(seen.x, world.y), maxf(seen.y, world.y))
	var worst := 0.0
	for band: int in bands:
		var seen: Vector2 = bands[band]
		worst = maxf(worst, seen.y - seen.x)
	return worst

## Hills have to arrive gradually.
##
## The old `roadRampLong` was a wedge of eight vertices: the road went from level
## to a 25% grade at a single edge, and back again at the far end. Nothing about
## it looked raised, and the car found both creases. `roadRampLongCurved` eases
## in and out, and the collision ribbon reproduces its profile, so the measure of
## success is that the gradient never changes sharply anywhere on the lap.
func test_slopes_are_eased() -> void:
	var builder := TrackBuilder.new()
	builder.measure(load("res://tools/build_track.gd").ARDENNES)
	var line := builder.centreline

	var worst := 0.0
	var climbs := false
	for i in range(1, line.size() - 1):
		var back: Vector3 = line[i] - line[i - 1]
		var on: Vector3 = line[i + 1] - line[i]
		var back_flat := Vector2(back.x, back.z).length()
		var on_flat := Vector2(on.x, on.z).length()
		if back_flat < 0.01 or on_flat < 0.01:
			continue
		if absf(on.y) > 0.01:
			climbs = true
		worst = maxf(worst, absf(on.y / on_flat - back.y / back_flat))
	check_true("the circuit actually has hills", climbs)
	# The wedge's own grade was 25%, so it broke into the slope by that much in
	# one step. Anything near that here means the eased profile is not reaching
	# the collision ribbon.
	check_true("no crease at the foot of a hill (worst %.1f%%)" % (worst * 100.0),
		worst < 0.10)

## Nothing may emit the wedge ramp any more, on any circuit the game can build.
func test_hills_use_the_eased_ramp() -> void:
	var tool_script := load("res://tools/build_track.gd")
	var layouts := {
		"ardennes": tool_script.ARDENNES,
		"monte_carlo": tool_script.MONTE_CARLO,
		"la_sarthe": tool_script.LA_SARTHE,
		"custom": _raised_sample_layout(),
	}
	for name in layouts:
		var wedges := 0
		var eased := 0
		for seg in layouts[name]:
			if seg[1] == "roadRampLong":
				wedges += int(seg[2])
			elif seg[1] == "roadRampLongCurved":
				eased += int(seg[2])
		check("%s uses no wedge ramps" % name, wedges, 0)
		check_true("%s ramps at all" % name, eased > 0)

## A player-painted circuit with a hill on it, as a segment list. The roomy
## rectangle, because its straights are long enough to actually afford ramps.
func _raised_sample_layout() -> Array:
	var layout := _roomy_rectangle()
	var first := layout.compile()
	layout.elevation[first.runs[1].cells[0]] = 2
	return layout.compile().segments

## The anti-roll bar has to measure the car against the road, not against the
## world, or it spends every banked corner trying to level the car out of the
## banking. On flat ground the two answers are the same, which is exactly why
## this went unnoticed until there was banking to notice it with.
func test_antiroll_reads_the_road() -> void:
	var car: Node = get_first_node_in_group("player_car")
	check_true("car exists for the anti-roll check", car != null)
	if car == null:
		return
	var up: Vector3 = car._surface_up()
	check_true("finds a surface under the car on the grid", up.dot(Vector3.UP) > 0.9)
	check_near("and it is a unit vector", up.length(), 1.0, 0.001)

## Split in two because the raycasts need the bodies to have had a physics step:
## `await` cannot be used here, since it would turn the staged `_physics_process`
## into a coroutine and its return value would stop driving the runner.
func stage_sustained_track() -> void:
	var layout := _roomy_rectangle()
	var first := layout.compile()
	layout.elevation[first.runs[1].cells[0]] = 2
	layout.elevation[first.corners[1].cell] = 2
	layout.elevation[first.runs[2].cells[0]] = 2

	sustained_track = TrackBuilder.new().build(
		"sustained", layout.compile().segments
	).root
	var ground := sustained_track.get_node("Ground")
	sustained_track.remove_child(ground)
	ground.free()
	# Clear of the raced track's 4 km ground plane, and of the custom track.
	sustained_track.position = Vector3(-6000.0, 0.0, 0.0)
	root.add_child(sustained_track)

func test_collision_follows_a_sustained_section() -> void:
	check_true("sustained track built", sustained_track != null)
	if sustained_track == null:
		return
	var space: PhysicsDirectSpaceState3D = sustained_track.get_world_3d().direct_space_state
	var elevated := 0
	for gate in sustained_track.get_node("Checkpoints").get_children():
		var half_h: float = gate.get_child(0).shape.size.y * 0.5
		var road: Vector3 = gate.global_transform.origin - Vector3(0, half_h, 0)
		if road.y > 0.5:
			elevated += 1
		var query := PhysicsRayQueryParameters3D.create(
			road + Vector3(0, 30, 0), road - Vector3(0, 30, 0)
		)
		var hit: Dictionary = space.intersect_ray(query)
		check_true("surface under sustained gate at y=%.1f" % road.y, not hit.is_empty())
		if not hit.is_empty():
			check_near("sustained surface height at y=%.1f" % road.y,
				hit["position"].y, road.y, 0.35)
	check_true("the sustained section really is elevated", elevated >= 3)

## A rectangle with enough straight to afford ramps at level 2 either side of a
## corner, which the smaller test layout cannot.
func _roomy_rectangle() -> TrackLayout:
	var layout := TrackLayout.new()
	layout.display_name = "Roomy"
	var p := Vector2i(0, 0)
	for move in [
		[Vector2i(1, 0), 26], [Vector2i(0, 1), 18],
		[Vector2i(-1, 0), 26], [Vector2i(0, -1), 18],
	]:
		for i in int(move[1]):
			layout.cells.append(p)
			p += move[0] as Vector2i
	layout.start_cell = Vector2i(8, 0)
	return layout

## Every character the interface puts on screen has to exist in the font that
## will actually be there.
##
## Godot's built-in font carries no system fallbacks into the web export, so a
## glyph the desktop borrowed from macOS without anyone noticing renders in the
## browser as a tofu box with its own codepoint printed inside it. The bank badge
## shipped to GitHub Pages that way, reading "2220" — U+2220, the angle sign,
## which `track_grid.gd` now draws with two lines instead.
##
## Reads the scripts that draw and label the interface and asks the font about
## every character in them, escapes included, since that is the form the angle
## sign was written in and a raw scan would have walked straight past it.
## Comments are covered too. They are never drawn, so this is stricter than it
## has to be — but only in the direction of the em dashes and middle dots the
## menus already use, all of which the built-in font has.
func test_ui_text_stays_inside_the_built_in_font() -> void:
	var font := ThemeDB.fallback_font
	check_true("there is a built-in font to check against", font != null)
	if font == null:
		return
	for path in [
		"res://scripts/ui/track_grid.gd", "res://scripts/ui/track_editor.gd",
		"res://scripts/ui/title_screen.gd", "res://scripts/ui/hud.gd",
		# Not a UI script, but the circuit names and blurbs it holds are drawn
		# straight onto the title screen, and they are the strings most likely to
		# want an accent.
		"res://scripts/game/game_state.gd",
		"res://tools/build_editor.gd", "res://tools/build_title.gd",
		"res://tools/build_ui.gd",
	]:
		var text := FileAccess.get_file_as_string(path)
		var missing := {}
		for i in text.length():
			var code := text.unicode_at(i)
			# A `\uXXXX` escape is plain ASCII in the file but a glyph on screen.
			if code == 0x5c and i + 5 < text.length() and text[i + 1] == "u":
				var hex := text.substr(i + 2, 4)
				if hex.is_valid_hex_number():
					code = hex.hex_to_int()
			if code > 0x7f and not font.has_char(code):
				missing[code] = true
		var names := PackedStringArray()
		for code: int in missing:
			names.append("U+%04X" % code)
		check("%s types only glyphs the font has (%s)" % [
			path.get_file(), ", ".join(names)], missing.size(), 0)

## The UI is laid out in pixels, so without content scaling it keeps its pixel
## size and shrinks as a fraction of the screen the denser the display gets: the
## title menu measured 47% of screen width at 1152x648 but 21% at 2560x1440, which
## is why it looked tiny on a Retina laptop panel and fine on an external monitor.
func test_ui_scales_with_the_window() -> void:
	check("content scaling is on",
		ProjectSettings.get_setting("display/window/stretch/mode", ""), "canvas_items")
	# "expand" holds the scale at 1:1 and only reveals more canvas, which is the
	# bug; "keep" letterboxes, unwanted with a 3D view behind the UI.
	check("scaled by height, not letterboxed or left at 1:1",
		ProjectSettings.get_setting("display/window/stretch/aspect", ""), "keep_height")
	var design := Vector2i(
		ProjectSettings.get_setting("display/window/size/viewport_width", 0),
		ProjectSettings.get_setting("display/window/size/viewport_height", 0)
	)
	check_true("a design size is set (%s)" % design, design.x > 0 and design.y > 0)
	check("the root window scales to it", root.content_scale_size, design)

## Godot rewrites project.godot whenever it feels like it — an `--import`, an
## editor open, even a web export — and when it does it drops whole sections and
## every `;` comment in the file. The web renderer override has been lost that way
## twice. Nothing warns: the export still succeeds and the page just renders wrong,
## because web is WebGL 2 only and Forward+ does not exist there.
func test_web_render_settings_survive() -> void:
	# Read the file, not ProjectSettings. `get_setting` resolves feature tags and
	# happily answers for `rendering_method.web` from the untagged value, so it
	# reports the override as present when the line has actually been deleted —
	# which is exactly the failure this is meant to catch.
	var path := "res://project.godot"
	check_true("project.godot is readable", FileAccess.file_exists(path))
	if not FileAccess.file_exists(path):
		return
	var text := FileAccess.get_file_as_string(path)
	check_true("desktop stays on Forward+",
		text.contains('renderer/rendering_method="forward_plus"'))
	check_true("the web renderer override is still in the file",
		text.contains('renderer/rendering_method.web="gl_compatibility"'))
	# The display block goes the same way, and losing it is what made the UI tiny.
	check_true("the stretch mode is still in the file",
		text.contains('window/stretch/mode="canvas_items"'))

## `keep_height` is right for every landscape shape but pins the canvas to 720
## units tall, so a 9:16 phone gets 720 * 9/16 = 405 units of width — narrower
## than the 300-unit track buttons plus the Edit column, which then run off both
## sides. Portrait has to keep the width instead and let the canvas grow tall.
func test_orientation_picks_a_scaling_rule() -> void:
	check("landscape keeps the measured design size",
		ViewportScaling.design_size(Vector2i(1920, 1080)), ViewportScaling.LANDSCAPE)
	check("landscape scales by height",
		ViewportScaling.aspect_mode(Vector2i(1920, 1080)),
		Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT)
	check("portrait turns the design size over",
		ViewportScaling.design_size(Vector2i(1170, 2532)), ViewportScaling.PORTRAIT)
	check("portrait scales by width",
		ViewportScaling.aspect_mode(Vector2i(1170, 2532)),
		Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH)
	# Square is not portrait: it belongs on the already-measured landscape path.
	check("square stays on the landscape path",
		ViewportScaling.design_size(Vector2i(800, 800)), ViewportScaling.LANDSCAPE)
	# The short edge is 720 either way, so a control sized in canvas units covers
	# the same fraction of the thumb-reachable edge in both orientations.
	check("the short edge matches in both orientations",
		mini(ViewportScaling.LANDSCAPE.x, ViewportScaling.LANDSCAPE.y),
		mini(ViewportScaling.PORTRAIT.x, ViewportScaling.PORTRAIT.y))
	# The project setting must stay landscape: it is what a fresh window and this
	# headless suite both get before any scene has run.
	check("the project default is still the landscape rule",
		ProjectSettings.get_setting("display/window/stretch/aspect", ""), "keep_height")

## The rule above is pure and was tested as such, which is exactly why the three
## things that actually broke on a rotating phone were all missed: each is a live
## rewiring that only happens when a real window changes shape.
##
## The camera one made the game unplayable held upright. `Camera3D` holds the
## *vertical* FOV by default, so a 9:16 viewport keeps the whole height and
## throws most of the width away — the car filled the screen and the road ahead
## was gone. Content scaling does not touch the 3D projection, so nothing the UI
## does fixes it.
## Opened on a circuit of its own rather than the starter rectangle. The erase
## test removes a corner, and a rectangle has exactly the four a circuit is not
## allowed to go below — on that layout the edit under test is correctly refused,
## so the test would fail while the feature worked.
func stage_rotation() -> void:
	var layout := sample_layout()
	layout.display_name = "Touch Test"
	TrackStore.save(layout)
	staged_track_ids.append(layout.id)
	GameState.editing_id = layout.id
	staged_editor = load("res://scenes/editor/track_editor.tscn").instantiate()
	root.add_child(staged_editor)

func test_rotation_rewires_the_view() -> void:
	var camera: Camera3D = _find_first("ChaseCamera", "Camera3D")
	var banner: Control = _find_first("Banner", "Label")
	var lap_panel: Control = _find_first("LapPanel", "PanelContainer")
	var grid := _editor_grid()
	check_true("the race scene has a camera, a banner and a lap panel",
		camera != null and banner != null and lap_panel != null)
	check_true("an editor is staged to rotate", grid != null)
	if camera == null or banner == null or lap_panel == null or grid == null:
		return

	check("rotating retargets the canvas",
		root.content_scale_size, ViewportScaling.PORTRAIT)
	check("and the camera keeps the width instead of the height",
		camera.keep_aspect, Camera3D.KEEP_WIDTH)

	# 214 units of lap panel and ~470 of banner do not fit across 720, so on a
	# phone the two were drawn on top of each other. They share the top of the
	# screen only while the canvas is wide.
	var overlap := banner.get_global_rect().intersection(lap_panel.get_global_rect())
	check_true("the banner clears the lap panel (%s vs %s)" % [
		banner.get_global_rect(), lap_panel.get_global_rect()],
		overlap.size.x <= 0.0 or overlap.size.y <= 0.0)

	# The canvas more than halves in width across a rotation. Its pan and zoom
	# were computed against the old size and nothing recomputed them, so the
	# circuit simply left the screen — and the F key that refits it is not
	# something a phone can press.
	var shown := _circuit_screen_rect(grid)
	check_true("the circuit is still on the canvas after rotating (%s in %s)" % [
		shown, grid.size],
		Rect2(Vector2.ZERO, grid.size).encloses(shown))

## A resize that is *not* a rotation must keep what the player was looking at
## where it was: their pan and zoom are deliberate, and refitting on every
## dragged window edge would throw them away. Staged a frame ahead of its
## assertion, because containers re-lay-out on a later frame than the resize.
func stage_a_taller_window() -> void:
	var grid := _editor_grid()
	if grid == null:
		return
	view_centre_before = grid.screen_to_cell_f(grid.size * 0.5)
	view_zoom_before = grid.cell_to_screen(Vector2.ONE) - grid.cell_to_screen(Vector2.ZERO)
	# Still portrait, so this is a resize and not a rotation.
	root.size = Vector2i(720, 1600)

func test_a_plain_resize_keeps_the_view() -> void:
	var grid := _editor_grid()
	if grid == null:
		return
	check_true("a resize that is not a rotation holds the zoom",
		(grid.cell_to_screen(Vector2.ONE) - grid.cell_to_screen(Vector2.ZERO))
			.is_equal_approx(view_zoom_before))
	check_true("and holds the middle of the view (%s vs %s)" % [
		grid.screen_to_cell_f(grid.size * 0.5), view_centre_before],
		grid.screen_to_cell_f(grid.size * 0.5).distance_to(view_centre_before) < 0.01)

## The editor is one set of controls in two arrangements, and the controls
## *move* between them rather than being built twice — so the way this breaks is
## that a trip through portrait and back leaves the sidebar subtly rearranged,
## which nothing else would notice until someone opened the editor on a desktop
## after rotating a phone.
##
## Checked as a round trip against a snapshot taken before anything moved, so it
## fails on a control that comes back to the wrong parent *or* the wrong place in
## its row.
func snapshot_editor_layout() -> Dictionary:
	var out := {}
	if staged_editor == null:
		return out
	# `owned` — a LineEdit and an OptionButton carry internal children whose index
	# cannot even be asked for, and they are not part of this layout anyway.
	for node in staged_editor.find_children("*", "Control", true, true):
		var control := node as Control
		out[String(staged_editor.get_path_to(control))] = control.get_index()
	return out

func test_portrait_reflow_is_reversible() -> void:
	check_true("a layout was snapshotted before rotating",
		not editor_layout_before.is_empty())
	var after := snapshot_editor_layout()
	var moved := PackedStringArray()
	for path: String in editor_layout_before:
		if not after.has(path):
			moved.append(path + " (gone)")
		elif after[path] != editor_layout_before[path]:
			moved.append("%s (%d, was %d)" % [
				path, after[path], editor_layout_before[path]])
	check("every control is back where it started (%s)" % ", ".join(moved),
		moved.size(), 0)
	check("and nothing new appeared", after.size(), editor_layout_before.size())

## What the phone layout has to deliver: the canvas gets the screen's width back,
## and nothing becomes unreachable in the process. The sidebar was 364 units wide
## against a 720-unit portrait canvas, so the circuit was being edited in less
## room than the controls editing it took up.
func test_portrait_gives_the_canvas_the_screen() -> void:
	var grid := _editor_grid()
	var editor: Control = staged_editor
	if grid == null or editor == null:
		return
	var canvas: Vector2 = root.get_visible_rect().size
	check_true("the canvas spans the full width on a phone (%.0f of %.0f)" % [
		grid.size.x, canvas.x],
		grid.size.x >= canvas.x - 1.0)
	check_true("and still has most of the height (%.0f of %.0f)" % [
		grid.size.y, canvas.y],
		grid.size.y > canvas.y * 0.6)

	var side: Control = editor.get_node("Side")
	check_true("the panel is floated off the layout, not docked beside it",
		side != null)
	if side == null:
		return
	check_true("and starts closed, so the canvas is not buried on arrival",
		not side.visible)

	# Opened here and inspected a frame later, once the panel has actually been
	# laid out at its floated width. See [method test_more_panel_holds_the_rest].
	var more: Button = editor.get_node("Split/Stack/TopBar/Slots/Tools/MoreButton")
	more.pressed.emit()
	check_true("MORE opens the panel", side.visible)

	# The bars carry what is wanted while drawing, and Test drive is the payoff
	# the whole screen exists for — none of it may need MORE to reach.
	for path in [
		"Split/Stack/TopBar/Slots/Tools/DrawButton",
		"Split/Stack/TopBar/Slots/Tools/EraseButton",
		"Split/Stack/TopBar/Slots/Tools/FitButton",
		"Split/Stack/TopBar/Slots/Tools/UndoButton",
		"Split/Stack/BottomBar/Slots/GuideCard",
		"Split/Stack/BottomBar/Slots/PhoneActions/TestButton",
		"Split/Stack/BottomBar/Slots/PhoneActions/SaveButton",
		"Split/Stack/BottomBar/Slots/PhoneActions/BackButton",
	]:
		var control := editor.get_node_or_null(path) as Control
		check_true("%s is on a bar, not behind MORE" % path.get_file(),
			control != null and control.is_visible_in_tree())

## What MORE has to be worth opening: everything the bars did not take, still
## there and still reachable. And the panel has to clear MORE itself — a panel
## covering its own switch is one that cannot be shut again, which is what the
## first version did.
## Importing goes through a text field rather than straight off the clipboard.
##
## That is a web-build decision, not a preference. `DisplayServer.clipboard_get`
## is reliable on desktop; in a browser it returns only what was last pasted into
## the canvas, because reading the system clipboard needs an async permissions
## API Godot's web platform does not expose. A focused `LineEdit` receives the
## browser's own paste event, so the field is the one route that behaves the same
## on both -- and this asserts the field is actually the thing being read.
func test_a_pasted_code_opens_through_the_field() -> void:
	var editor: Control = staged_editor
	if editor == null:
		return
	var flyout: Control = editor.get_node_or_null("PasteFlyout")
	var field: LineEdit = editor.get_node_or_null("PasteFlyout/Rows/CodeEdit")
	var open_button: Button = editor.get_node_or_null(
		"PasteFlyout/Rows/PasteButtons/PasteOpenButton")
	check_true("the editor has somewhere to paste a code",
		flyout != null and field != null and open_button != null)
	if flyout == null or field == null or open_button == null:
		return
	check("and it starts closed", flyout.visible, false)

	# A bad code leaves the box open, so the text can be corrected rather than
	# having to be pasted again.
	editor._on_paste_code()
	check_true("choosing paste opens the box", flyout.visible)
	field.text = "TD1-obviously-not-a-code|12"
	open_button.pressed.emit()
	check_true("a bad code keeps the box open to be fixed", flyout.visible)
	check_true("and says what was wrong", not editor._status.text.is_empty())

	var shared := sample_layout()
	shared.display_name = "Pasted In"
	field.text = ShareCode.encode(shared)
	open_button.pressed.emit()
	check("a good code closes the box", flyout.visible, false)
	check("and the circuit is open in the editor",
		editor._layout.display_name, "Pasted In")
	# Unsaved and unnamed by id, exactly as "New circuit" arrives: an imported
	# circuit must not inherit a lap record from a local track of the same name.
	check("as an unsaved circuit", editor._layout.id, "")
	check_true("and it compiles", editor._compiled.ok)

func test_more_panel_holds_the_rest() -> void:
	var editor: Control = staged_editor
	if editor == null:
		return
	var side: Control = editor.get_node_or_null("Side")
	var more: Button = editor.get_node_or_null(
		"Split/Stack/TopBar/Slots/Tools/MoreButton")
	if side == null or more == null:
		return
	check_true("the panel does not cover MORE (%s vs %s)" % [
		side.get_global_rect(), more.get_global_rect()],
		not side.get_global_rect().intersects(more.get_global_rect()))
	for node_name in ["NameEdit", "Picker", "DeleteButton", "LegendToggle",
			"ReadoutCard"]:
		var found := editor.find_children(node_name, "Control", true, false)
		var control: Control = found[0] if not found.is_empty() else null
		check_true("%s is reachable through MORE" % node_name,
			control != null and side.is_ancestor_of(control)
				and control.is_visible_in_tree())
	more.pressed.emit()
	check_true("and MORE shuts the panel again", not side.visible)

## The state a rotating phone actually leaves behind, which the desktop resize
## tests above never produce: the window has finished turning, but the rule that
## was applied is the *previous* orientation's, because the browser fired its
## resize before it had reshaped the canvas and the handler read a size the
## window was about to stop being.
##
## Nothing revisits that read. Every orientation decision in the game — the canvas
## rule, the camera's aspect, the HUD, the editor's layout — hangs off it, so one
## stale read latches: landscape is drawn to the portrait rule, and turning back
## applies the landscape rule to a portrait screen. There is no event left that
## would fix it, which is why it never came right.
##
## Staged by putting the previous orientation's rule on a correctly-sized window
## and winding the watch back to the size the signal *would* have reported.
## Nothing rotates after that: recovering with no further event is the whole
## point, so the recovery has to come from the watch and nowhere else.
##
## Only the aspect is corrupted. Writing `content_scale_size` re-fires
## `size_changed` on the spot and the handler puts it straight back, so it cannot
## be left wrong for a test to find — the aspect is the half that stays stale,
## and it is the half that squashes a landscape screen into a portrait canvas.
func stage_a_stale_rotation() -> void:
	var watch: Node = root.get_node_or_null("ViewportScalingWatch")
	check_true("the window is watched for sizes the signal missed", watch != null)
	if watch == null:
		return
	root.size = Vector2i(1280, 720)
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH
	watch.seen = Vector2i(720, 1280)
	stale_staged_at = frame

## Polled rather than checked on a fixed frame: physics runs at 120 Hz and the
## watch runs on idle frames, so consecutive test frames can share one — or none.
func poll_stale_rotation() -> void:
	if stale_staged_at == 0 or stale_fixed_at > 0:
		return
	if root.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT:
		stale_fixed_at = frame

func test_a_stale_rotation_corrects_itself() -> void:
	var camera: Camera3D = _find_first("ChaseCamera", "Camera3D")
	check_true("a rule applied from a stale size corrects itself with no further"
		+ " rotation (after %d frames)" % (stale_fixed_at - stale_staged_at),
		stale_fixed_at > 0)
	# The correction has to reach every listener, not just the canvas. The camera
	# is the one that made the game unplayable, and it hangs off the same signal.
	check_true("and the camera catches up with it",
		camera == null or camera.keep_aspect == Camera3D.KEEP_HEIGHT)

func _editor_grid() -> TrackGrid:
	return staged_editor.get_node_or_null("Split/Stack/Grid") if staged_editor != null else null

## Pan and pinch are the two things a phone cannot reach through the emulated
## mouse: it collapses every finger onto one pointer, so a second finger simply
## does not exist as far as the mouse path is concerned. Without these, a circuit
## drawn on a phone could never be moved or zoomed — and `fit_view` alone cannot
## get you close enough to hit a badge.
func test_two_fingers_pan_and_pinch_the_canvas() -> void:
	var grid := _editor_grid()
	check_true("an editor is staged for touch", grid != null)
	if grid == null:
		return
	var mid := grid.size * 0.5
	var left := mid - Vector2(80.0, 0.0)
	var right := mid + Vector2(80.0, 0.0)

	var before_cell := grid.screen_to_cell_f(mid)
	var before_zoom := grid.cell_to_screen(Vector2.ONE) - grid.cell_to_screen(Vector2.ZERO)

	# Two fingers moved together, span unchanged: pan, no zoom.
	_grid_touch(grid, 0, left, true)
	_grid_touch(grid, 1, right, true)
	_grid_drag(grid, 0, left + Vector2(60.0, 40.0))
	_grid_drag(grid, 1, right + Vector2(60.0, 40.0))
	check_true("two fingers moving together pan the canvas",
		grid.screen_to_cell_f(mid + Vector2(60.0, 40.0)).distance_to(before_cell) < 0.01)
	check_true("and moving together does not zoom it",
		(grid.cell_to_screen(Vector2.ONE) - grid.cell_to_screen(Vector2.ZERO))
			.is_equal_approx(before_zoom))

	# Now spread them apart about the same midpoint: zoom, no pan.
	var centre := mid + Vector2(60.0, 40.0)
	var pinned := grid.screen_to_cell_f(centre)
	_grid_drag(grid, 0, centre - Vector2(160.0, 0.0))
	_grid_drag(grid, 1, centre + Vector2(160.0, 0.0))
	check_true("spreading them zooms in (%.1f px per cell, was %.1f)" % [
		(grid.cell_to_screen(Vector2.ONE) - grid.cell_to_screen(Vector2.ZERO)).x,
		before_zoom.x],
		(grid.cell_to_screen(Vector2.ONE) - grid.cell_to_screen(Vector2.ZERO)).x
			> before_zoom.x + 0.5)
	# The point between the fingers has to stay under them, or the canvas slides
	# out from under the gesture and pinching to look at a corner walks away
	# from that corner.
	check_true("and holds the point between the fingers (%s vs %s)" % [
		grid.screen_to_cell_f(centre), pinned],
		grid.screen_to_cell_f(centre).distance_to(pinned) < 0.01)

	_grid_touch(grid, 0, Vector2.ZERO, false)
	_grid_touch(grid, 1, Vector2.ZERO, false)
	grid.fit_view()

## A pinch has to leave the circuit exactly as it found it, and two separate
## things stand between it and an accidental edit.
##
## The first is where the gesture *starts*. Fingers land on whatever they land
## on, and the emulated mouse has already reported the first of them as a press —
## so a pinch centred on a corner arrives as a grab of that corner. Closing that
## grab off is not enough on its own: closing it used to count as an edit, which
## put an undo entry on the stack that undoes nothing.
##
## The second is the emulated mouse *during* the gesture. It keeps following one
## finger throughout, and a finger lifted and put back down mid-pinch — which is
## how anyone adjusts their grip — arrives as a fresh press on whatever is under
## it, mid-gesture, with no drag in progress to have been closed off.
func test_a_pinch_does_not_edit_the_circuit() -> void:
	var grid := _editor_grid()
	if grid == null:
		return
	var handles := TrackShape.corners_of(grid.layout.cells)
	var dot := grid.cell_to_screen(Vector2(handles[0]) + Vector2(0.5, 0.5))
	# Second finger placed towards the middle of the canvas, so it lands on the
	# canvas whichever corner of the circuit the first one is on.
	var inward := (grid.size * 0.5 - dot).normalized() * 140.0

	var cells: int = grid.layout.cells.size()
	var edits: Array[int] = []
	grid.layout_edited.connect(func(): edits.append(1))

	# A pinch that begins on a corner handle.
	_grid_mouse(grid, dot, true)
	_grid_touch(grid, 0, dot, true)
	_grid_touch(grid, 1, dot + inward, true)
	_grid_drag(grid, 0, dot - inward * 0.4)
	_grid_drag(grid, 1, dot + inward * 1.4)
	_grid_touch(grid, 0, Vector2.ZERO, false)
	_grid_touch(grid, 1, Vector2.ZERO, false)
	_grid_mouse(grid, dot - inward * 0.4, false)
	check("a pinch beginning on a handle leaves the circuit alone",
		grid.layout.cells.size(), cells)
	check("and puts nothing on the undo stack", edits.size(), 0)

	# A finger re-planted mid-gesture, which reaches the canvas as a press with
	# two fingers already down.
	_grid_touch(grid, 1, dot, true)
	_grid_touch(grid, 2, dot + inward, true)
	_grid_mouse(grid, dot, true)
	_grid_mouse_motion(grid, dot + inward * 2.0)
	_grid_mouse(grid, dot + inward * 2.0, false)
	_grid_touch(grid, 1, Vector2.ZERO, false)
	_grid_touch(grid, 2, Vector2.ZERO, false)
	check("a press arriving mid-gesture is not an edit",
		grid.layout.cells.size(), cells)
	check("and still nothing on the undo stack", edits.size(), 0)
	grid.fit_view()

## Erasing a stroke and removing a corner were both right-button-only, which on a
## touchscreen means unreachable. They are the only two destructive edits, so
## being unable to take anything back out is not a small gap.
func test_erase_mode_reaches_the_right_button_edits() -> void:
	var grid := _editor_grid()
	if grid == null:
		return
	var editor: Control = staged_editor
	var erase: Button = editor.get_node("Split/Side/Rows/ToolRow/EraseButton")
	var draw: Button = editor.get_node("Split/Side/Rows/ToolRow/DrawButton")

	draw.button_pressed = true
	erase.button_pressed = true
	check_true("erasing turns drawing off", not draw.button_pressed)
	check_true("and the canvas agrees", grid.erase_mode and not grid.draw_mode)

	# A tap on a corner dot removes that corner, the same dot that moves it with
	# erase off — one target, and the mode says which of the two it does.
	#
	# Aimed at a corner the shape editor will actually give up: not every one can
	# go — the sample circuit's own bends are all load-bearing — and which ones
	# can is `test_shape_add_and_remove`'s business. So a bend is added first,
	# which is the case anyone removing one is in anyway. What is under test here
	# is only that a tap reaches the removal at all, which before erase mode
	# needed a button a touchscreen does not have.
	var handles := TrackShape.corners_of(grid.layout.cells)
	var bumped := TrackShape.insert_bump(handles, 0, handles[0], -6)
	check_true("a bend can be added to remove again", not bumped.is_empty())
	if bumped.is_empty():
		return
	grid.layout.cells = TrackShape.cells_from_corners(bumped)
	grid.refresh(grid.layout.compile())
	handles = TrackShape.corners_of(grid.layout.cells)

	var removable := -1
	for i in handles.size():
		if not TrackShape.straighten_at(handles, i).is_empty():
			removable = i
			break
	check_true("the staged circuit has a corner that can be removed", removable >= 0)
	if removable < 0:
		return
	var corners: int = grid.compiled.corners.size()
	var dot := grid.cell_to_screen(Vector2(handles[removable]) + Vector2(0.5, 0.5))
	_grid_mouse(grid, dot, true)
	_grid_mouse(grid, dot, false)
	check_true("tapping a dot with erase on removes that corner (%d, was %d)" % [
		grid.compiled.corners.size(), corners],
		grid.compiled.corners.size() < corners)

	# And a drag rubs road out, which is what right-drag did. Aimed at the middle
	# of the longest straight: a corner dot wins the hit test, which is the whole
	# point of the check above, so anywhere near one would be testing that
	# instead.
	var cells: int = grid.layout.cells.size()
	var longest: TrackLayout.Run = grid.compiled.runs[0]
	for run in grid.compiled.runs:
		if run.cells.size() > longest.cells.size():
			longest = run
	var on_road := grid.cell_to_screen(
		Vector2(longest.cells[longest.cells.size() / 2]) + Vector2(0.5, 0.5))
	_grid_mouse(grid, on_road, true)
	_grid_mouse(grid, on_road, false)
	check_true("dragging with erase on rubs road out (%d cells, was %d)" % [
		grid.layout.cells.size(), cells],
		grid.layout.cells.size() < cells)

	erase.button_pressed = false
	check_true("and turning it off returns to shaping", not grid.erase_mode)

## A fingertip covers far more than a cursor's single pixel, so the same hit
## radius that suits a mouse makes every badge a near miss on glass.
func test_touch_widens_the_hit_targets() -> void:
	var grid := _editor_grid()
	if grid == null:
		return
	check_true("a touch device gets a wider grab than a mouse (%.2f vs %.2f cells)"
		% [grid._grab_radius(), TrackGrid.GRAB],
		grid._grab_radius() > TrackGrid.GRAB)
	# Capped, because the radius and bank badges sit 1.2 cells apart and a circle
	# wider than that makes which one was tapped a coin toss.
	check_true("but never wide enough to swallow the badge next door",
		grid._grab_radius() <= TrackGrid.TOUCH_GRAB_MAX_CELLS)

func _grid_touch(grid: TrackGrid, index: int, at: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.pressed = pressed
	e.position = grid.get_global_transform_with_canvas() * at
	grid._input(e)

func _grid_drag(grid: TrackGrid, index: int, at: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = grid.get_global_transform_with_canvas() * at
	grid._input(e)

## The emulated mouse, which is what a single finger actually reaches the canvas
## as. Fed straight to `_gui_input` because that is where the viewport delivers
## it, with positions already in the control's own space.
func _grid_mouse(grid: TrackGrid, at: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = at
	grid._gui_input(e)

func _grid_mouse_motion(grid: TrackGrid, at: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = at
	grid._gui_input(e)

## Where the painted circuit lands on the canvas, in the grid's own coordinates.
func _circuit_screen_rect(grid: TrackGrid) -> Rect2:
	var lo := grid.cell_to_screen(Vector2(grid.layout.cells[0]))
	var hi := lo
	for c in grid.layout.cells:
		lo = lo.min(grid.cell_to_screen(Vector2(c)))
		hi = hi.max(grid.cell_to_screen(Vector2(c) + Vector2.ONE))
	return Rect2(lo, hi - lo)

func _find_first(node_name: String, type: String) -> Node:
	var found := root.find_children(node_name, type, true, false)
	return found[0] if not found.is_empty() else null

## Leaving a race used to be instant, on `ui_cancel`. That is a deliberate reach
## on a keyboard, a thumb-rest on a pad, and nothing at all on a phone — which
## had no way out short of reloading the page. All three routes now arrive at the
## same menu and leaving is the second press.
func test_pause_is_reachable_from_every_input() -> void:
	check_true("there is a pause action at all", InputMap.has_action("pause"))
	if not InputMap.has_action("pause"):
		return
	var keys := PackedInt32Array()
	var buttons := PackedInt32Array()
	for event in InputMap.action_get_events("pause"):
		if event is InputEventKey:
			keys.append((event as InputEventKey).physical_keycode)
		elif event is InputEventJoypadButton:
			buttons.append((event as InputEventJoypadButton).button_index)
	check_true("escape opens it", keys.has(KEY_ESCAPE))
	check_true("and so does the pad's Start", buttons.has(JOY_BUTTON_START))

	var menu: Control = _find_first("PauseMenu", "Control")
	check_true("the race carries a pause menu", menu != null)
	if menu == null:
		return
	# The menu pauses the tree, so it cannot itself be paused or nothing could
	# ever dismiss it.
	check("the menu keeps running while the tree does not",
		menu.process_mode, Node.PROCESS_MODE_ALWAYS)
	var button: Button = _find_first("PauseButton", "Button")
	check_true("and a touch route in exists", button != null)
	if button == null:
		return
	# Escape and Start are physical; only touch needs something on screen. Same
	# rule as the driving pads.
	var was_touch := button.visible
	check("shown on exactly the devices the driving pads are",
		was_touch, DisplayServer.is_touchscreen_available())

## Every joypad binding has to be device `-1` (all devices). `InputMap` matches an
## event only when the binding's device is `-1` or an exact index, so `device 0`
## covers just the first pad the OS enumerates — and a pad that sleeps and
## reconnects can come back on another one. Recorded in the architecture notes
## because `project.godot` cannot hold a comment; this is what actually enforces
## it, including for actions added later.
func test_joypad_bindings_take_any_device() -> void:
	var wrong := PackedStringArray()
	for action in InputMap.get_actions():
		for event in InputMap.action_get_events(action):
			var device := -2
			if event is InputEventJoypadButton or event is InputEventJoypadMotion:
				device = event.device
			if device >= 0:
				wrong.append("%s (device %d)" % [action, device])
	check("every joypad binding accepts any device (%s)" % ", ".join(wrong),
		wrong.size(), 0)

## The reason the whole tree pauses rather than just the car: `lap_tracker`
## accumulates in `_physics_process`, so a menu that left it running would
## quietly add the time spent reading it to the lap being driven.
func stage_pause() -> void:
	var menu: Control = _find_first("PauseMenu", "Control")
	if menu == null:
		return
	paused_lap_time = tracker.lap_time
	# Through the real input path, not by calling the handler: Escape fires
	# `pause` *and* `ui_cancel` from one event, and the bug being guarded is a
	# second listener elsewhere turning one press into two toggles that cancel
	# out. Only a real dispatch can catch that.
	_press_action_key(KEY_ESCAPE)

func test_pausing_stops_the_race() -> void:
	var menu: Control = _find_first("PauseMenu", "Control")
	if menu == null:
		return
	check_true("one press of escape opens the menu", menu.visible)
	check_true("and pauses the tree", paused)
	check_near("so the lap clock stops with it",
		tracker.lap_time, paused_lap_time, 0.0001)

	# The same key shuts it again, so the way in is the way out.
	_press_action_key(KEY_ESCAPE)
	check_true("pressing it again closes the menu", not menu.visible)
	check_true("and unpauses", not paused)

	# Leaving has to unpause first: `paused` belongs to the tree, not the scene,
	# so quitting while set carries the freeze into the title screen.
	menu._set_paused(true)
	check_true("staged paused again", paused)
	menu._resume()
	check_true("resume always leaves the tree running", not paused)

func _press_action_key(keycode: Key) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = keycode
	down.pressed = true
	Input.parse_input_event(down)
	Input.flush_buffered_events()
	var up := InputEventKey.new()
	up.physical_keycode = keycode
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()

func _find_touch_controls() -> Control:
	var found := root.find_children("TouchControls", "Control", true, false)
	return found[0] if not found.is_empty() else null

func _touch_event(index: int, pos: Vector2, pressed: bool) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	return e

## Feed one touch event to the pads and settle the action state it synthesises.
##
## `Input.parse_input_event` buffers: the action a pad presses does not reach
## `Input.is_action_pressed` until the buffer is flushed, which normally happens
## once per frame. In the game that is a frame of latency nobody can feel. Here
## it would mean every assertion read the state from before the touch, so the
## flush is forced rather than spreading one gesture over several frames.
func _feed(touch: Control, event: InputEvent) -> void:
	touch._input(event)
	Input.flush_buffered_events()

## The touch pads do not steer the car — they press the same actions the keyboard
## and the pad press, so the car never learns touch exists.
##
## The multi-finger bookkeeping is the whole reason these are not `Button`s: a
## `Button` is driven by the emulated mouse, which is a single pointer, so it
## cannot hold the gas and steer at the same time. Every check below is a way
## that hand-rolled bookkeeping has to not leak an action.
func test_touch_pads_press_the_driving_actions() -> void:
	var touch := _find_touch_controls()
	check_true("the hud carries touch controls", touch != null)
	if touch == null:
		return
	# Hidden on a machine with no touchscreen, which is the point of the node —
	# but the input path is what is under test, so force them on.
	check("hidden unless the device has a touchscreen",
		touch.visible, DisplayServer.is_touchscreen_available())
	var was_visible: bool = touch.visible
	touch.visible = true

	var gas: Control = touch.get_node("Gas")
	var steer: Control = touch.get_node("SteerLeft")
	check_true("the pads have been laid out", gas.get_global_rect().has_area())
	var on_gas: Vector2 = gas.get_global_rect().get_center()
	var on_steer: Vector2 = steer.get_global_rect().get_center()

	_feed(touch, _touch_event(0, on_gas, true))
	_feed(touch, _touch_event(1, on_steer, true))
	check_true("gas held by the first finger", Input.is_action_pressed("accelerate"))
	check_true("steering held by the second", Input.is_action_pressed("steer_left"))

	# Lifting one finger must not release what another is holding.
	_feed(touch, _touch_event(1, Vector2.ZERO, false))
	check_true("gas survives the other finger lifting",
		Input.is_action_pressed("accelerate"))
	check_true("steering released with its own finger",
		not Input.is_action_pressed("steer_left"))

	# Two fingers on the *same* pad: the first to lift must not release it.
	_feed(touch, _touch_event(2, on_gas, true))
	_feed(touch, _touch_event(0, Vector2.ZERO, false))
	check_true("gas survives while a second finger is still on it",
		Input.is_action_pressed("accelerate"))
	_feed(touch, _touch_event(2, Vector2.ZERO, false))
	check_true("gas releases when the last finger lifts",
		not Input.is_action_pressed("accelerate"))

	# A thumb that slides off the pad has to release it, or the throttle sticks.
	_feed(touch, _touch_event(3, on_gas, true))
	var drag := InputEventScreenDrag.new()
	drag.index = 3
	drag.position = on_gas + Vector2(0.0, -400.0)
	_feed(touch, drag)
	check_true("sliding off a pad releases it",
		not Input.is_action_pressed("accelerate"))
	_feed(touch, _touch_event(3, Vector2.ZERO, false))

	# Leaving the race mid-press must not strand an action down: nothing else
	# would ever send the matching release.
	_feed(touch, _touch_event(4, on_gas, true))
	touch.release_all()
	# The releases it sends are buffered like any other. In the game the flush
	# happens next frame with the node already gone, which is fine — the events
	# are held by `Input`, not by the node that queued them.
	Input.flush_buffered_events()
	check_true("release_all clears a held action",
		not Input.is_action_pressed("accelerate"))

	touch.visible = was_visible

## Portrait is the tight one: the canvas is 720 units wide there against 1280 in
## landscape, and every pad is anchored to a bottom corner, so what has to fit is
## the two steering pads plus the pedal column across that width.
func test_touch_pads_fit_a_portrait_canvas() -> void:
	var touch := _find_touch_controls()
	if touch == null:
		return
	var steer_right: Control = touch.get_node("SteerRight")
	var gas: Control = touch.get_node("Gas")
	# Offsets, not `position`: `position` resolves against the parent's *current*
	# width, so reading it here would only ever re-measure the landscape canvas
	# the suite is running in. `offset_left` is anchor-relative, so the same
	# number describes the control at any canvas width.
	var pads_end: float = steer_right.offset_left + steer_right.size.x
	var pedals_start: float = float(ViewportScaling.PORTRAIT.x) + gas.offset_left
	check_true("the pads clear the pedals across a portrait canvas (%d < %d)"
		% [int(pads_end), int(pedals_start)],
		pads_end < pedals_start)

## Every circuit has to stay reachable however many are saved. The menu used to be
## centred with hardcoded offsets, so it grew downwards off the bottom of the
## screen and took the last circuits, "Build a track" and the hint with it.
func stage_title_menu() -> void:
	for n in 8:
		var layout := sample_layout()
		layout.display_name = "Fits Test %d" % n
		layout.id = ""
		TrackStore.save(layout)
		staged_track_ids.append(layout.id)
	# One circuit named the way a player actually can. Nothing limits what goes
	# in the name field, and a menu row that grows to fit its longest name would
	# push the Edit and Delete buttons off the side of the screen -- the same
	# shape of bug as the editor panel losing Save to a long error message.
	var long_named := sample_layout()
	long_named.display_name = (
		"A Circuit With An Extremely Long Name That Nobody Sensible "
		+ "Would Type But Which The Field Happily Accepts Anyway"
	)
	long_named.id = ""
	TrackStore.save(long_named)
	staged_track_ids.append(long_named.id)
	staged_title = load("res://scenes/title.tscn").instantiate()
	root.add_child(staged_title)

func test_title_menu_fits_however_many_tracks() -> void:
	var title: Control = staged_title
	check_true("title staged", title != null)
	if title == null:
		return
	var rows: Control = title.get_node("Centre/Rows")
	var scroll: ScrollContainer = title.get_node("Centre/Rows/TrackScroll")
	var tracks: VBoxContainer = title.get_node("Centre/Rows/TrackScroll/Tracks")
	var editor_button: Button = title.get_node("Centre/Rows/EditorButton")
	var canvas: Vector2 = root.get_visible_rect().size

	check_true("the menu is centred (%.1f vs %.1f)" % [
		rows.position.x + rows.size.x * 0.5, canvas.x * 0.5],
		absf((rows.position.x + rows.size.x * 0.5) - canvas.x * 0.5) < 2.0)
	check_true("the menu fits top to bottom (%.0f..%.0f in %.0f)" % [
		rows.position.y, rows.position.y + rows.size.y, canvas.y],
		rows.position.y >= -1.0 and rows.position.y + rows.size.y <= canvas.y + 1.0)
	check_true("more circuits than fit unscrolled",
		tracks.get_combined_minimum_size().y > scroll.size.y)
	check_true("so the list scrolls instead of overflowing",
		scroll.get_v_scroll_bar().visible)
	check_true("and 'Build a track' is still on screen",
		editor_button.global_position.y + editor_button.size.y <= canvas.y)

	# A ragged right edge. Every *row* is stretched to the list width regardless,
	# so it is the main button that has to be measured: without a spacer reserving
	# the Edit column, the shipped circuits' buttons ran the full width while the
	# custom ones stopped short.
	var widths := {}
	for row in tracks.get_children():
		widths[snappedf((row.get_child(0) as Control).size.x, 0.5)] = true
	check("every circuit's button is the same width", widths.size(), 1)

	title.queue_free()
	staged_title = null
	for id in staged_track_ids:
		TrackStore.delete(id)
	staged_track_ids.clear()


## The look of every screen comes from one generated resource, and it only
## reaches the screens because `project.godot` names it. Godot rewrites that file
## on its own schedule and has dropped whole sections of it before now — the web
## renderer override twice — so this asserts the line is still there rather than
## asking ProjectSettings, which would answer from a default.
func test_the_project_wears_the_theme() -> void:
	var text := FileAccess.get_file_as_string("res://project.godot")
	check_true("project.godot still names the theme",
		text.contains('theme/custom="res://resources/ui_theme.tres"'))
	var theme := load("res://resources/ui_theme.tres") as Theme
	check_true("and the theme resource loads", theme != null)
	if theme == null:
		return
	# A control with no styling of its own has to come out styled anyway, which
	# is the whole point of a project theme over per-scene themes.
	check_true("a plain Button gets a style",
		theme.get_stylebox("normal", "Button") != null)

## The committed `.tres` is generated from `scripts/ui/ui_theme.gd`, so editing
## the palette does nothing until `tools/build_theme.gd` is re-run. Nothing about
## a stale theme looks broken — the colours are simply the old ones — so the two
## are compared here instead.
func test_theme_resource_matches_its_source() -> void:
	var saved := load("res://resources/ui_theme.tres") as Theme
	var fresh := UiTheme.build()
	if saved == null:
		check_true("theme resource loads", false)
		return
	check("default font size", saved.default_font_size, fresh.default_font_size)
	check("every type variation is baked",
		saved.get_type_variation_list("Button").size(),
		fresh.get_type_variation_list("Button").size())
	var saved_box := saved.get_stylebox("normal", "Button") as StyleBoxFlat
	var fresh_box := fresh.get_stylebox("normal", "Button") as StyleBoxFlat
	check_true("button styles are in step",
		saved_box != null and fresh_box != null
		and saved_box.bg_color.is_equal_approx(fresh_box.bg_color))
	check_true("label colours are in step",
		saved.get_color("font_color", "Label").is_equal_approx(
			fresh.get_color("font_color", "Label")))

## The editor scene is generated by `tools/build_editor.gd` and read by
## `scripts/ui/track_editor.gd` through `@onready` paths. Nothing connects those
## two but a matching set of node names: rename a container in the builder and
## the editor still loads, then throws on the first null the moment it is opened.
func stage_editor_panel() -> void:
	GameState.editing_id = ""
	staged_editor = load("res://scenes/editor/track_editor.tscn").instantiate()
	root.add_child(staged_editor)

func test_editor_panel_is_wired_and_fits() -> void:
	var editor: Control = staged_editor
	check_true("editor staged", editor != null)
	if editor == null:
		return
	for path in [
		"Split/Stack/Grid",
		"Split/Side/Rows/NameEdit",
		"Split/Side/Rows/Picker",
		"Split/Side/Rows/ToolRow/DrawButton",
		"Split/Side/Rows/ToolRow/EraseButton",
		"Split/Side/Rows/ToolRow/FitButton",
		"Split/Side/Rows/GuideCard/Rows/Guide",
		"Split/Side/Rows/ReadoutCard/Rows/Readout",
		"Split/Side/Rows/Status",
		"Split/Side/Rows/LegendToggle",
		"Split/Side/Rows/Actions/CloseButton",
		"Split/Side/Rows/Actions/UndoRow/UndoButton",
		"Split/Side/Rows/Actions/UndoRow/SaveButton",
		"Split/Side/Rows/Actions/TestButton",
		"Split/Side/Rows/Actions/ExitRow/DeleteButton",
		"Split/Side/Rows/Actions/ExitRow/BackButton",
		"LegendFlyout",
	]:
		check_true("editor has %s" % path, editor.get_node_or_null(path) != null)

	# The panel is a stack of fixed heights beside a canvas that fills the rest of
	# the window. Overrun it and the HBox grows past the bottom of the screen,
	# which makes the *canvas* taller than the view — and "fit the circuit to the
	# view" then fits it to a view partly off-screen. Content scaling pins the
	# canvas to 720 units whatever the window, so this is a fixed budget, not
	# something a bigger monitor fixes.
	var canvas: Vector2 = root.get_visible_rect().size
	var rows: Control = editor.get_node("Split/Side/Rows")
	check_true("the panel fits its column (%.0f in %.0f)" % [
		rows.global_position.y + rows.size.y, canvas.y],
		rows.global_position.y + rows.size.y <= canvas.y + 1.0)
	var back: Control = editor.get_node("Split/Side/Rows/Actions/ExitRow/BackButton")
	check_true("and the way out is on screen",
		back.global_position.y + back.size.y <= canvas.y)

	# The legend opens over the canvas because the column has no room for it. It
	# has to clear the panel, or it covers the controls it is describing. It is
	# reference, not a control, so the canvas is not buried in it on arrival —
	# both it and its switch start closed.
	var flyout: Control = editor.get_node("LegendFlyout")
	var toggle: Button = editor.get_node("Split/Side/Rows/LegendToggle")
	check_true("the legend starts closed", not flyout.visible)
	check_true("and its switch agrees", not toggle.button_pressed)

	toggle.button_pressed = true
	var side: Control = editor.get_node("Split/Side")
	# Guards the check below: a flyout laid out at zero size clears everything.
	check_true("the legend has a size once open (%.0f wide)" % flyout.size.x,
		flyout.size.x > 0.0)
	check_true("the legend clears the panel (%.0f vs %.0f)" % [
		flyout.global_position.x + flyout.size.x, side.global_position.x],
		flyout.global_position.x + flyout.size.x <= side.global_position.x)

	editor.queue_free()
	staged_editor = null

## Custom tracks are JSON on disk, so the whole shape has to survive the trip.
func test_layout_round_trip() -> void:
	var layout := sample_layout()
	var compiled := layout.compile()
	layout.corner_sizes[compiled.corners[0].cell] = 1
	layout.elevation[compiled.runs[1].cells[0]] = 1

	check("save", TrackStore.save(layout), OK)
	check_true("id assigned", layout.id.begins_with(TrackStore.ID_PREFIX))

	var back := TrackStore.load_layout(layout.id)
	check_true("loads back", back != null)
	if back == null:
		return
	check("name survives", back.display_name, layout.display_name)
	check("cells survive", back.cells.size(), layout.cells.size())
	check("start cell survives", back.start_cell, layout.start_cell)
	check("corner choices survive", back.corner_sizes.size(), layout.corner_sizes.size())
	check("elevation survives", back.elevation.size(), layout.elevation.size())
	# Same layout in, same circuit out — measured after the edits above, not
	# against the layout as it was before them.
	var before := TrackBuilder.new().measure(layout.compile().segments)
	var after := TrackBuilder.new().measure(back.compile().segments)
	check_near("same lap length after reload", after.length, before.length, 0.01)

	check_true("listed by the store", TrackStore.list_layouts().size() > 0)
	# And offered on the menu, alongside the shipped circuits.
	var ids := []
	for info in GameState.all_tracks():
		ids.append(info["id"])
	check_true("offered on the menu", ids.has(layout.id))
	check_true("shipped tracks still listed first", ids[0] == "ardennes")

	TrackStore.delete(layout.id)
	check_true("delete removes it", TrackStore.load_layout(layout.id) == null)

## A built custom track has to be as complete as a shipped one — the race scene
## makes no distinction, so anything missing here is a crash at load.
func test_custom_track_is_complete() -> void:
	check_true("custom track built", custom_track != null)
	check_true("has a spawn point", custom_track.has_node("SpawnPoint"))
	check_true("has a road surface", custom_track.has_node("RoadSurface"))
	check("gate count", custom_track.get_node("Checkpoints").get_child_count(), 16)
	var visuals: Node = custom_track.get_node("RoadVisuals")
	check("one mesh per piece",
		_count_class(visuals, "MeshInstance3D"), visuals.get_child_count())

## The car has to land on tarmac. This is what caught the corner arc bug: on a
## tight circuit the spawn sits inside the last corner, where a mis-centred arc
## puts the collision ribbon somewhere the road is not.
func test_custom_spawn_is_on_the_road() -> void:
	var spawn: Marker3D = custom_track.get_node("SpawnPoint")
	var at := spawn.global_transform.origin
	var space := custom_track.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		at + Vector3(0, 40, 0), at - Vector3(0, 40, 0)
	)
	var hit: Dictionary = space.intersect_ray(query)
	check_true("something under the spawn", not hit.is_empty())
	if hit.is_empty():
		return
	check("spawn is over the road surface", hit["collider"].name, "RoadSurface")

	# And it starts behind the line facing it, same rule as the shipped tracks.
	var gate0: Area3D = custom_track.get_node("Checkpoints/Checkpoint00")
	var half_h: float = gate0.get_child(0).shape.size.y * 0.5
	var line: Vector3 = gate0.global_transform.origin - Vector3(0, half_h, 0)
	var to_line := line - at
	to_line.y = 0.0
	check_true("starts near the line", to_line.length() < 40.0)
	var forward := Basis(Vector3.UP, spawn.rotation.y) * Vector3(0, 0, 1)
	check_true("faces the line",
		forward.normalized().dot(to_line.normalized()) > 0.8)

func _count_class(n: Node, cls: String) -> int:
	var total := 1 if n.is_class(cls) else 0
	for c in n.get_children():
		total += _count_class(c, cls)
	return total

## The car must start just *behind* the start line, not past it, or the timer
## only begins after a full out lap. Asserts the line is close and ahead.
func test_spawn_is_behind_the_line() -> void:
	for info in GameState.TRACKS:
		var inst: Node3D = load(info["scene"]).instantiate()
		var spawn: Marker3D = inst.get_node("SpawnPoint")
		var gate0: Area3D = inst.get_node("Checkpoints/Checkpoint00")
		var half_h: float = gate0.get_child(0).shape.size.y * 0.5
		var line: Vector3 = gate0.position - Vector3(0, half_h, 0)

		var to_line := line - spawn.position
		to_line.y = 0.0
		check_true("track %s starts near the line" % info["id"], to_line.length() < 40.0)

		# The car model faces local +Z, so that is "forward" from the spawn.
		var forward := Basis(Vector3.UP, spawn.rotation.y) * Vector3(0, 0, 1)
		check_true("track %s faces the line" % info["id"],
			forward.normalized().dot(to_line.normalized()) > 0.8)
		inst.free()

func test_checkpoints() -> void:
	check("checkpoint count", gates.size(), 16)
	var seen := {}
	for i in gates.size():
		check_true("gate %d exists" % i, gates[i] != null)
		seen[i] = true
	check("gate indices unique and sequential", seen.size(), gates.size())

## Regression test for the elevated-collision bug: a ConcavePolygonShape3D is
## one-sided by default, so with the wrong winding the car falls straight
## through raised sections. Casting down at each gate catches that immediately.
func test_road_surface_follows_elevation() -> void:
	var space: PhysicsDirectSpaceState3D = gates[0].get_world_3d().direct_space_state
	var elevated := 0
	for i in gates.size():
		var half_h: float = gates[i].get_child(0).shape.size.y * 0.5
		var road: Vector3 = gates[i].global_transform.origin - Vector3(0, half_h, 0)
		if road.y > 0.5:
			elevated += 1
		var q := PhysicsRayQueryParameters3D.create(
			road + Vector3(0, 30, 0), road - Vector3(0, 30, 0)
		)
		var hit: Dictionary = space.intersect_ray(q)
		check_true("gate %d has surface under it" % i, not hit.is_empty())
		if not hit.is_empty():
			check_near("gate %d surface height" % i, hit.position.y, road.y, 0.35)
	# Guards the test itself: if the layout ever loses its hills, this test would
	# otherwise still pass while checking nothing interesting.
	check_true("circuit has elevated gates", elevated > 0)

# --- staged lap-ordering tests, which need frames to advance ---

func _physics_process(_delta: float) -> bool:
	frame += 1
	if frame == 1:
		tracker = get_first_node_in_group("lap_tracker")
		var cps: Array = get_nodes_in_group("checkpoint")
		gates.resize(cps.size())
		for cp in cps:
			gates[cp.index] = cp
		tracker.lap_completed.connect(func(n, t, b): laps.append([n, t, b]))
		tracker.best_lap = 0.0  # ignore any stored record
		return false

	# A player-built circuit in the same physics world, so raycasts can check a
	# custom track is as solid as a shipped one. Parked beyond the reach of the
	# raced track's 4 km ground plane, with its own ground removed so a hit there
	# can only be road.
	#
	# Added only now, on purpose. LapTracker takes its gate count from the whole
	# "checkpoint" group on its first physics frame, so a second track present
	# any earlier would tell it a lap needs thirty-two gates.
	if frame == 2:
		custom_track = TrackBuilder.new().build(
			"test_custom", sample_layout().compile().segments
		).root
		var ground := custom_track.get_node("Ground")
		custom_track.remove_child(ground)
		ground.free()
		custom_track.position = Vector3(6000.0, 0.0, 0.0)
		root.add_child(custom_track)
		return false

	if frame == 3:
		test_time_formatting()
		test_tuning_invariants()
		test_car_wired_to_tuning()
		test_old_records_migrate_to_the_composite_key()
		test_records_are_kept_per_car_and_surface()
		test_the_throttle_setting_survives_a_restart()
		test_partial_throttle_reaches_the_engine()
		test_the_steering_curve_leaves_full_lock_alone()
		test_shipped_circuits_carry_the_colour_grade()
		test_a_ghost_round_trips_through_bytes()
		test_a_damaged_ghost_is_refused()
		test_a_ghost_interpolates_and_then_holds()
		test_ghosts_go_with_a_deleted_circuit()
		test_the_ghost_car_is_not_a_physics_body()
		test_par_time_reproduces_measured_corner_speeds()
		test_par_time_is_plausible_on_the_shipped_circuits()
		test_the_estimate_uses_a_racing_line()
		test_shipped_par_times_match_the_model()
		test_medals_are_derived_from_the_lap_time()
		test_custom_circuits_get_a_par_of_their_own()
		test_every_car_is_built_from_its_own_model()
		test_lap_records_are_kept_per_car()
		test_a_popped_section_can_be_flattened_from_any_of_its_corners()
		test_par_time_refuses_a_degenerate_circuit()
		test_the_editor_readout_is_affordable_per_mouse_move()
		test_a_circuit_round_trips_through_a_share_code()
		test_a_share_code_survives_being_pasted_badly()
		test_a_bad_share_code_fails_politely()
		test_a_share_code_can_carry_a_ghost_but_does_not_by_default()
		test_audio_resources_match_their_source()
		test_generated_loops_meet_their_own_start()
		test_sound_is_off_until_asked_for()
		test_the_car_is_silent_when_sound_is_off()
		test_the_car_carries_its_audio()
		test_engine_pitch_sweeps_rather_than_climbing_once()
		test_tyres_only_squeal_when_they_are_sliding()
		test_the_crossover_circuit_actually_crosses()
		test_the_tunnel_is_built_and_does_not_collide()
		test_all_tracks_usable()
		test_no_duplicated_instances()
		test_spawn_is_behind_the_line()
		test_checkpoints()
		test_road_surface_follows_elevation()
		test_centreline_has_no_kinks()
		test_shipped_circuits_run_clockwise()
		test_painted_loops_close()
		test_bad_loops_are_rejected()
		test_crossings_are_refused_unless_asked_for()
		test_a_crossing_is_walked_straight_through()
		test_allowing_crossings_still_refuses_everything_else()
		test_ordinary_circuits_walk_identically_either_way()
		test_a_crossing_needs_headroom_to_compile()
		test_a_painted_crossing_builds_with_real_clearance()
		test_one_level_of_crossing_clearance_is_refused()
		test_the_compiler_refuses_crossings_by_default()
		test_handle_edits_only_cross_when_asked()
		test_a_crossing_cannot_be_grabbed_as_a_straight()
		test_the_start_straight_offers_no_headroom()
		test_corner_sizing()
		test_elevation()
		test_layout_round_trip()
		test_shape_edits_stay_valid()
		test_shape_add_and_remove()
		test_shape_prunes_non_corners()
		test_shape_rejects_bad_rings()
		test_bend_can_cross_its_straight()
		test_close_gap()
		test_stroke_fill_is_orthogonal()
		test_timing_gate_sits_on_the_start_line()
		test_starting_grid_leads_up_to_the_line()
		test_gates_stay_evenly_spaced()
		test_title_offers_editing_of_custom_tracks()
		test_title_deletes_a_custom_track()
		test_ui_text_stays_inside_the_built_in_font()
		test_ui_scales_with_the_window()
		test_web_render_settings_survive()
		test_the_project_wears_the_theme()
		test_theme_resource_matches_its_source()
		stage_title_menu()
		stage_editor_panel()
		test_sustained_elevation_across_corners()
		test_a_corner_can_be_raised_on_its_own()
		test_a_multi_level_climb_is_one_hill()
		test_ramp_tiles_follow_the_climb_they_are_on()
		test_start_line_stays_on_the_ground()
		test_elevation_requests_are_reduced_not_broken()
		test_plateau_inside_one_straight_still_works()
		test_corners_are_banked()
		test_shipped_tracks_keep_their_banked_meshes()
		test_banking_can_be_turned_off()
		test_corner_banking_is_authored_and_saved()
		test_slopes_are_eased()
		test_hills_use_the_eased_ramp()
		test_antiroll_reads_the_road()
		stage_sustained_track()
		return false

	if frame == 4:
		# A frame after the HUD was added, so the pads have their final rects —
		# the hit-testing under test is done against those rects.
		test_orientation_picks_a_scaling_rule()
		test_touch_pads_press_the_driving_actions()
		test_touch_pads_fit_a_portrait_canvas()
		test_custom_track_is_complete()
		test_custom_spawn_is_on_the_road()
		test_banked_collision_leans_into_the_corner()
		return false

	if frame == 5:
		# A frame later than the staging, so the new bodies are in the space.
		test_collision_follows_a_sustained_section()
		return false

	if frame == 8:
		# Containers lay out on a later frame, so sizes and positions are only
		# final some frames after the scene is added.
		test_title_menu_fits_however_many_tracks()
		test_a_pasted_code_opens_through_the_field()
		test_a_refused_crossing_can_still_be_raised_on_the_canvas()
		test_dragging_a_bend_flat_straightens_the_road()
		test_dragging_a_corner_into_line_straightens_it()
		test_the_panel_keeps_its_buttons_whatever_the_readout_says()
		test_the_editor_says_how_to_fix_a_crossing()
		test_editor_panel_is_wired_and_fits()
		return false

	# Touch and rotation go last, on frames the lap sequence below does not claim
	# (it steps on every fifth). Rotation leaves the window portrait for two
	# frames, which reshapes everything the layout tests above measure, so nothing
	# that reads a size may run between the turn and the restore.
	if frame == 9:
		stage_rotation()
		return false

	if frame == 11:
		# A frame after staging, so the canvas has a size to hit-test against.
		test_two_fingers_pan_and_pinch_the_canvas()
		test_a_pinch_does_not_edit_the_circuit()
		test_erase_mode_reaches_the_right_button_edits()
		test_touch_widens_the_hit_targets()
		return false

	if frame == 12:
		editor_layout_before = snapshot_editor_layout()
		root.size = Vector2i(720, 1280)
		return false

	if frame == 13:
		test_rotation_rewires_the_view()
		test_portrait_gives_the_canvas_the_screen()
		stage_a_taller_window()
		return false

	if frame == 14:
		test_a_plain_resize_keeps_the_view()
		test_more_panel_holds_the_rest()
		root.size = Vector2i(1280, 720)
		return false

	if frame == 16:
		# A frame after turning back, so the reflow and the containers under it
		# have both run.
		test_portrait_reflow_is_reversible()
		if staged_editor != null:
			staged_editor.queue_free()
			staged_editor = null
		return false

	if frame == 17:
		stage_a_stale_rotation()
		return false

	# Watched from here on rather than on one chosen frame, because the watch runs
	# on idle frames and this runner counts physics ones.
	poll_stale_rotation()

	if frame == 21:
		test_pause_is_reachable_from_every_input()
		test_joypad_bindings_take_any_device()
		stage_pause()
		return false

	if frame == 22:
		# A frame after the press, so a paused physics frame has been through and
		# the lap clock has had its chance to move.
		test_pausing_stops_the_race()
		return false

	# Frame 30 rather than 24, which is 13 physics frames after the staging
	# instead of 7. The recovery this waits for happens on an *idle* frame and
	# this runner counts physics ones, so the gap between them is what the test
	# is really depending on — and on a cold run, where importing has just
	# stalled the process, physics can catch up several frames in a row without
	# an idle frame in between. That produced one failure in three runs. A wider
	# window makes it rare rather than impossible; the honest fix would be for
	# the watch to expose that it has run, rather than for this to guess.
	if frame == 30:
		test_a_stale_rotation_corrects_itself()
		return false

	if frame < 5 or frame % 5 != 0:
		return false
	step += 1

	match step:
		1:
			check_true("not timing before the line", not tracker.timing)
			gates[7].passed.emit(7)
		2:
			check_true("out lap gate ignored", not tracker.timing)
			gates[0].passed.emit(0)
		3:
			check_true("timing starts at the line", tracker.timing)
			check("lap number", tracker.lap_number, 1)
			for i in range(1, 16):
				gates[i].passed.emit(i)
		4:
			check("all gates taken", tracker._next_required, 0)
			gates[0].passed.emit(0)
		5:
			check("lap recorded", laps.size(), 1)
			check_true("first lap is best", laps[0][2])
			check_true("best stored", tracker.best_lap > 0.0)
			# Records are keyed per track, so a time on one circuit must not
			# show up as a record on another.
			check_near("best persisted for this track",
				GameState.best_lap_for("ardennes"), tracker.best_lap, 0.001)
			check("other track unaffected", GameState.best_lap_for("monte_carlo"), 0.0)
			check_splits_recorded()
			check_ghost_recorded()
			gates[1].passed.emit(1)
			gates[2].passed.emit(2)
			gates[9].passed.emit(9)  # skip ahead - a cut
		6:
			check("cut rejected", tracker._next_required, 3)
			# Two gates into the second lap, with the first lap stored: the only
			# point in this sequence where a live delta exists to be read.
			check_delta_against_the_stored_best()
			gates[0].passed.emit(0)  # try to claim the lap early
		7:
			check("early line ignored", laps.size(), 1)
			for i in range(3, 16):
				gates[i].passed.emit(i)
			gates[0].passed.emit(0)
		8:
			check("second lap recorded", laps.size(), 2)
			check("second lap numbered", laps[1][0], 2)
			_report()
			return true
	return false

## Sixteen ordered gates are also sixteen free sector times. Checked inside the
## scripted lap sequence rather than as a test of its own, because a split only
## exists as a side effect of a gate being taken in order -- which is the thing
## that sequence exists to drive.
## Read from `best_splits` rather than from `splits`, and that distinction is the
## point rather than a workaround: `splits` is the lap being *driven*, and
## crossing the line both closes one lap and opens the next, so by the time
## anything can look at a finished lap the live array has already been cleared
## for the new one. The completed lap survives in `best_splits`.
func check_splits_recorded() -> void:
	# Typed explicitly: `tracker` is an untyped Node, so anything read off it is a
	# Variant and cannot be inferred from.
	var finished: PackedFloat32Array = tracker.best_splits
	check("a split per gate", finished.size(), tracker.checkpoint_count)
	if finished.size() != tracker.checkpoint_count:
		return
	# Index 0 is the line, and holds the time the lap was *closed* at rather than
	# a zero at the beginning: crossing it is what ends a lap.
	check_near("the line's split is the lap time",
		finished[0], tracker.last_lap, 0.0001)
	var rising := true
	for i in range(1, finished.size()):
		if finished[i] <= 0.0 or finished[i] > finished[0]:
			rising = false
		if i > 1 and finished[i] < finished[i - 1]:
			rising = false
	check_true("every gate has a split, in order, inside the lap", rising)
	check_near("and they were stored with the record",
		GameState.best_sectors_for("ardennes")[0], tracker.last_lap, 0.0001)

## The recording is taken on the physics step, alongside the lap clock, which is
## what makes a headless run reproduce it.
func check_ghost_recorded() -> void:
	check_true("a ghost was recorded", tracker.ghost != null)
	if tracker.ghost == null:
		return
	check_true("with samples in it", tracker.ghost.count() > 0)
	# 60 Hz against a lap timed on the 120 Hz physics step, so roughly half as
	# many samples as ticks -- and never more than one per tick.
	check_true("sampled no faster than the clock allows",
		float(tracker.ghost.count()) <= tracker.last_lap * Ghost.HZ + 2.0)
	var stored := GhostStore.load_ghost("ardennes")
	check_true("and saved beside the record", stored != null)
	if stored != null:
		check("the saved ghost is the recorded one",
			stored.count(), tracker.ghost.count())

## The delta is what makes a time attack game addictive, and it is only
## meaningful once there is a stored lap to measure against.
##
## Checked *mid-lap*, after two gates of the second lap have been taken. Not at a
## lap boundary: crossing the line opens a new lap and the delta goes back to
## NAN, deliberately, because carrying the last gate's reading into the next lap
## would show a comparison against a gate the car has not reached yet.
func check_delta_against_the_stored_best() -> void:
	check_true("a delta once there is a best lap to compare with",
		not is_nan(tracker.delta))
	check("the best lap kept its splits",
		tracker.best_splits.size(), tracker.checkpoint_count)
	# The second lap is driven by emitting gates by hand on the same frames, so
	# its splits land within a few physics steps of the first lap's. The value is
	# not the point; that it is a real comparison rather than a placeholder is.
	check_true("and it is a plausible size", absf(tracker.delta) < 5.0)
	check_true("and it reads out signed",
		tracker.format_delta(tracker.delta).begins_with("+")
		or tracker.format_delta(tracker.delta).begins_with("-"))
	check("with nothing to show when there is no comparison",
		tracker.format_delta(NAN), "")

func _report() -> void:
	if failures.is_empty():
		print("PASS  %d checks" % checks)
		quit(0)
		return
	print("FAIL  %d of %d checks" % [failures.size(), checks])
	for f in failures:
		print("  - %s" % f)
	quit(1)
