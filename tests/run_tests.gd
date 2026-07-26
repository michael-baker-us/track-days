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

func _initialize() -> void:
	# race.tscn instances whichever track GameState has selected, so the suite
	# exercises the same path the title screen uses.
	GameState.selected_index = 0
	# Never write to the player's real records; the suite completes laps, which
	# would otherwise leave a bogus best time on the title screen.
	GameState.records_path = "user://test_records.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GameState.records_path))
	# Likewise never write into the player's saved circuits.
	TrackStore.dir = "user://test_tracks"
	_clear_dir(TrackStore.dir)
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
		"highland": tool_script.HIGHLAND,
		"flats": tool_script.FLATS,
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
	for entry in [["highland", tool_script.HIGHLAND], ["flats", tool_script.FLATS]]:
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

## Gates must stay evenly spaced around the lap after being offset onto the line,
## or a mis-wrapped arc would bunch them without breaking anything visibly.
func test_gates_stay_evenly_spaced() -> void:
	var result := TrackBuilder.new().build(
		"spacing", load("res://tools/build_track.gd").HIGHLAND)
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
## first road tile. Deliberately reads the art rather than the builder's own
## constant, so a wrong constant cannot make the test agree with itself.
func _gantry_position(root_node: Node3D) -> Vector3:
	var holder: Node3D = root_node.get_node("RoadVisuals").get_child(0)
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
		if seg[1] == "roadRampLong":
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
	check_true("shipped tracks still listed first", ids[0] == "highland")

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
		test_all_tracks_usable()
		test_no_duplicated_instances()
		test_spawn_is_behind_the_line()
		test_checkpoints()
		test_road_surface_follows_elevation()
		test_centreline_has_no_kinks()
		test_painted_loops_close()
		test_bad_loops_are_rejected()
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
		test_gates_stay_evenly_spaced()
		test_title_offers_editing_of_custom_tracks()
		test_ui_scales_with_the_window()
		test_web_render_settings_survive()
		stage_title_menu()
		test_sustained_elevation_across_corners()
		test_a_corner_can_be_raised_on_its_own()
		test_start_line_stays_on_the_ground()
		test_elevation_requests_are_reduced_not_broken()
		test_plateau_inside_one_straight_still_works()
		stage_sustained_track()
		return false

	if frame == 4:
		test_custom_track_is_complete()
		test_custom_spawn_is_on_the_road()
		return false

	if frame == 5:
		# A frame later than the staging, so the new bodies are in the space.
		test_collision_follows_a_sustained_section()
		return false

	if frame == 8:
		# Containers lay out on a later frame, so sizes and positions are only
		# final some frames after the scene is added.
		test_title_menu_fits_however_many_tracks()
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
