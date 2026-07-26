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

func _initialize() -> void:
	# race.tscn instances whichever track GameState has selected, so the suite
	# exercises the same path the title screen uses.
	GameState.selected_index = 0
	# Never write to the player's real records; the suite completes laps, which
	# would otherwise leave a bogus best time on the title screen.
	GameState.records_path = "user://test_records.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.records_path))
	root.add_child(load("res://scenes/race.tscn").instantiate())

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

func test_tuning_invariants() -> void:
	for path in ["res://resources/tuning/grippy.tres", "res://resources/tuning/drifty.tres"]:
		var tuning: CarTuning = load(path)
		var name: String = path.get_file()
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

func _count_class(n: Node, cls: String) -> int:
	var total := 1 if n.is_class(cls) else 0
	for c in n.get_children():
		total += _count_class(c, cls)
	return total

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

	if frame == 3:
		test_time_formatting()
		test_tuning_invariants()
		test_car_wired_to_tuning()
		test_all_tracks_usable()
		test_no_duplicated_instances()
		test_checkpoints()
		test_road_surface_follows_elevation()
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
				GameState.best_lap_for("highland"), tracker.best_lap, 0.001)
			check("other track unaffected", GameState.best_lap_for("flats"), 0.0)
			gates[1].passed.emit(1)
			gates[2].passed.emit(2)
			gates[9].passed.emit(9)  # skip ahead - a cut
		6:
			check("cut rejected", tracker._next_required, 3)
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

func _report() -> void:
	if failures.is_empty():
		print("PASS  %d checks" % checks)
		quit(0)
		return
	print("FAIL  %d of %d checks" % [failures.size(), checks])
	for f in failures:
		print("  - %s" % f)
	quit(1)
