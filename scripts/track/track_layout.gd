class_name TrackLayout
extends RefCounted

## A player-authored circuit, as painted cells on a grid, plus the compiler that
## turns those cells into the segment list `TrackBuilder` walks.
##
## ## Why a grid rather than a segment list
##
## The builder's native input is an ordered list of straights and corners, which
## only makes a circuit if it happens to close — the shipped layouts were solved
## by hand, adjusting straight counts until the walker returned to the origin.
## That is a puzzle, not an editing experience.
##
## A painted grid inverts it. One cell is one tile unit; the player paints a
## closed loop of cells and closure is guaranteed by construction, because a
## loop drawn on a grid necessarily returns to where it started. The compiler
## then has the much easier job of expressing that loop in pieces.
##
## ## How corner radius survives the translation
##
## The obvious objection to a grid is that a painted bend is a single cell, so
## every corner would have to be the smallest tile — losing the fast sweepers
## that make the shipped circuits worth driving.
##
## It turns out the tile set does not work that way. All three Kenney corners
## join the *same two centre lines*; a bigger one simply starts turning earlier
## and finishes later. A corner of size N occupies an NxN block: the bend cell,
## plus N-1 cells taken from the straight leading in and N-1 from the straight
## leading out. So the painted route fixes where the road runs, and radius is a
## free per-corner choice bounded only by how much straight there is to spend.
##
## The compiler therefore defaults every corner to the largest tile that fits
## and lets the editor cycle it down, which is the interesting decision to give
## a player anyway — tight hairpin or long sweeper, at the cost of straight.
##
## ## Elevation
##
## Every segment — each straight and each corner — carries an absolute *level*,
## and the compiler works out where the ramps have to go. Kenney has bridge
## corners (`roadCornerBridge*`) that hold their height, so an elevated stretch
## can carry on round a bend instead of coming back down for it: raise a run, the
## corner after it, and the run after that, and the result is one sustained
## elevated section that starts and ends exactly where the player said.
##
## Height can only *change* inside a straight, because a corner piece has the same
## deck height at both ends. So a run reconciles three numbers: the level of the
## corner before it, its own level, and the level of the corner after. It ramps
## from the first to its own, holds, and ramps to the third — one
## `roadRampLongCurved` per level of difference, two cells each. That piece eases
## into the grade and out of it rather than breaking into it, so the transitions
## are crests and dips instead of ridges; the builder reproduces its profile in
## the collision ribbon so the wheels feel the same road the player can see.
##
## Closure comes from forcing the corner immediately before the start line to
## level zero. Walk the loop and the running height returns to exactly where it
## began, so elevation cannot break the circuit however it is arranged. The old
## behaviour — a plateau inside one straight — is now just the case where both
## neighbouring corners are at zero.

const FORMAT_VERSION := 1

## Kenney ships exactly three corners. The key is the size N of the NxN block.
const CORNER_PIECES := {1: "roadCornerSmall", 2: "roadCornerLarge", 3: "roadCornerLarger"}
const MAX_CORNER := 3

## `roadStart` and `roadStartPositions`, two cells each. The run carrying the
## start line has to find room for both before anything else.
const START_CELLS := 4

## Cells one `roadRampLongCurved` occupies, and how much height it gains. One ramp per
## level, so a level *difference* of N costs 2N cells of straight.
const CELLS_PER_RAMP := 2
const MAX_LEVEL := 3

## Corner tiles that hold their height, by size, for a corner above ground level.
const BRIDGE_CORNER_PIECES := {
	1: "roadCornerBridgeSmall",
	2: "roadCornerBridgeLarge",
	3: "roadCornerBridgeLarger",
}

const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

## A bend in the painted route, and the tile chosen to take it.
class Bend extends RefCounted:
	var cell: Vector2i
	var size: int      # 1..3, the NxN block the tile occupies
	var max_size: int  # largest that fits given the neighbouring straights
	var turn: String   # "left" or "right"
	var in_dir: Vector2i
	var out_dir: Vector2i
	## Height this corner is held at. Corners cannot climb — both ends of the
	## tile share a deck height — so this is simply where the corner sits.
	var level: int
	var max_level: int
	## How hard the road leans into this corner, 0 (flat) to MAX_BANK. Unlike
	## radius and height there is nothing to fit it against — banking spends no
	## cells and cannot stop the loop closing — so every corner can have any of
	## them, and the only reason it is stored per corner is that it is a choice.
	var bank: int

## A straight run between two bends.
class Run extends RefCounted:
	var cells: Array[Vector2i] = []
	var free: int         # cells left after the corners at each end take theirs
	var level: int        # height this straight is held at, between its ramps
	var max_level: int
	var entry_level: int  # level of the corner before it
	var exit_level: int   # level of the corner after it
	var is_start: bool
	var key: Vector2i     # the cell elevation is recorded against

	## Cells this run needs for ramps alone, given the three levels it joins.
	func ramp_cells() -> int:
		return CELLS_PER_RAMP * (
			absi(level - entry_level) + absi(exit_level - level)
		)

## Everything the editor and the builder need out of one compile pass.
class Compiled extends RefCounted:
	var ok := false
	var errors: Array[String] = []
	## Cells the player needs to look at, so the editor can point at the problem
	## instead of only describing it.
	var problem_cells: Array[Vector2i] = []
	var segments: Array = []
	var corners: Array[Bend] = []
	var runs: Array[Run] = []
	## The painted loop in visiting order, rotated so it begins at the start run.
	var cycle: Array[Vector2i] = []
	## The cell the start line actually lands on, which is not the first cell of
	## the start run: the corner before it has already taken `size - 1` of them.
	var start_marker := Vector2i.ZERO
	## Builder tile-units -> grid cell coordinates. The builder always walks from
	## its own origin heading south, so its output is the painted route rotated
	## and translated; this puts the two back on top of each other, which is what
	## lets the editor draw real arcs over the painted cells.
	var to_grid := Transform2D()

var id := ""
var display_name := "Untitled"
var cells: Array[Vector2i] = []
## Which cell carries the start line. The run containing it becomes run zero.
var start_cell := Vector2i.ZERO
## Painted loops have no inherent direction; this picks which way round to race.
var reversed := false
## Bend cell -> chosen corner size. Absent means "largest that fits".
var corner_sizes := {}
## Bend cell -> chosen bank level, 0 for a flat corner. Absent means "whatever
## suits the radius", so a circuit that has never been told anything about
## banking still gets sensible corners, and one that has is left exactly as its
## author set it — including deliberately flat.
var corner_banks := {}
## A cell -> the level of the segment containing it. Keyed by cell rather than by
## segment index so that repainting elsewhere on the circuit does not shuffle
## every hill onto a different piece of road. A corner is keyed by its bend cell.
var elevation := {}

# --- compiling ---

## Turns the painted cells into a segment list. Never throws: on a bad loop it
## returns `ok = false` with errors phrased for the player, because the editor
## calls this on every mouse move to drive its live readout.
func compile() -> Compiled:
	var out := Compiled.new()

	if cells.size() < 8:
		out.errors.append("Paint a closed loop — at least eight cells.")
		return out

	var occupied := {}
	var doubled := false
	for c in cells:
		if occupied.has(c):
			doubled = true
		occupied[c] = true

	# Exactly two neighbours everywhere is precisely the condition for a simple
	# closed loop: fewer means a dead end, more means a junction or a blob, and
	# neither can be driven as a circuit.
	var loose := 0
	var junctions := 0
	for c in cells:
		var n := TrackShape.neighbour_count(occupied, c)
		if n == 2:
			continue
		out.problem_cells.append(c)
		if n < 2:
			loose += 1
		else:
			junctions += 1
	# Report every bad cell in one pass rather than stopping at the first, so a
	# player fixing a half-drawn circuit can see all of it at once.
	if loose > 0:
		out.errors.append(
			"%d loose end%s — the road has to join back up into one loop."
			% [loose, "" if loose == 1 else "s"]
		)
	if junctions > 0:
		out.errors.append(
			"%d junction%s — the road cannot branch or run alongside itself."
			% [junctions, "" if junctions == 1 else "s"]
		)
	if not out.problem_cells.is_empty():
		return out

	# TrackShape.walk is the single definition of a valid painted loop; the
	# handle edits in the editor are refused against exactly this test, so the
	# two can never disagree about what counts as a circuit.
	var cycle := TrackShape.walk(cells)
	if cycle.is_empty() or doubled:
		out.errors.append("That is more than one separate loop — join them or erase one.")
		return out
	if reversed:
		cycle.reverse()

	var bends := TrackShape.bend_indices(cycle)
	if bends.size() < 4:
		out.errors.append("A circuit needs at least four corners.")
		return out

	_build_corners_and_runs(cycle, bends, out)
	_fit_corners(occupied, out)

	if not _rotate_to_start(out):
		out.errors.append(
			"No straight long enough for the start line. Every corner is eating "
			+ "its straights — shrink one, or paint a longer section."
		)
		return out

	# After the rotation, because which run holds the start line decides which
	# corner has to be at ground level for the loop's height to close.
	_resolve_elevation(out)

	out.segments = _emit(out)
	out.cycle = _order_from(cycle, out)
	out.to_grid = _grid_transform(out)
	out.ok = out.errors.is_empty()
	return out




func _build_corners_and_runs(
	cycle: Array[Vector2i], bends: Array[int], out: Compiled
) -> void:
	var n := cycle.size()
	for bi in bends.size():
		var i: int = bends[bi]
		var next_bend: int = bends[(bi + 1) % bends.size()]

		# Index i pairs a straight with the corner that *ends* it, so emission is
		# just run, corner, run, corner in order. Getting this off by one still
		# produces a plausible-looking sequence with every turn present — it
		# simply pairs them with the wrong straights and stops closing.
		var run := Run.new()
		var k := (i + 1) % n
		while k != next_bend:
			run.cells.append(cycle[k])
			k = (k + 1) % n
		out.runs.append(run)

		var corner := Bend.new()
		corner.cell = cycle[next_bend]
		corner.in_dir = cycle[next_bend] - cycle[(next_bend - 1 + n) % n]
		corner.out_dir = cycle[(next_bend + 1) % n] - cycle[next_bend]
		# Matches the builder's own left-turn rotation, so "left" here and "left"
		# in a layout mean the same thing.
		corner.turn = (
			"left" if corner.out_dir == Vector2i(corner.in_dir.y, -corner.in_dir.x)
			else "right"
		)
		out.corners.append(corner)

		run.key = run.cells[0] if not run.cells.is_empty() else corner.cell

## Picks each corner's tile. Every corner starts at the largest Kenney offers and
## is shrunk until it stops overrunning its neighbours or overlapping the road
## elsewhere, so the player gets the fastest circuit their painted loop supports
## without having to think about tile sizes at all.
func _fit_corners(occupied: Dictionary, out: Compiled) -> void:
	for c in out.corners:
		c.size = MAX_CORNER
		c.max_size = MAX_CORNER

	# A corner's block must not lie on top of road it does not own, which is what
	# stops a wide sweeper from paving over the inside of a tight loop.
	for c in out.corners:
		while c.size > 1 and _block_overlaps(occupied, c, c.size):
			c.size -= 1
		c.max_size = c.size

	# Two corners sharing a straight are competing for the same cells. Shrink the
	# greedier one until the run can pay for both. Every pass either shrinks a
	# corner or settles, and corners stop at 1, so this terminates.
	var settled := false
	while not settled:
		settled = true
		for i in out.runs.size():
			var before: Bend = _corner_before(out, i)
			var after: Bend = out.corners[i]
			if (before.size - 1) + (after.size - 1) <= out.runs[i].cells.size():
				continue
			if before.size == 1 and after.size == 1:
				continue  # nothing left to give; the run is simply too short
			settled = false
			if before.size >= after.size and before.size > 1:
				before.size -= 1
			else:
				after.size -= 1

	# Honour an explicit choice, but never past what actually fits.
	for c in out.corners:
		c.max_size = c.size
		if corner_sizes.has(c.cell):
			c.size = clampi(int(corner_sizes[c.cell]), 1, c.max_size)

	# Corners are flat unless the author banked them. Nothing about the shape of a
	# bend implies how much its road should lean, and a circuit that quietly banked
	# every corner the moment it was painted would be one the author had to notice
	# and undo — the wrong way round for something that changes how a track drives.
	for c in out.corners:
		c.bank = (
			clampi(int(corner_banks[c.cell]), 0, TrackBuilder.MAX_BANK_LEVEL)
			if corner_banks.has(c.cell)
			else TrackBuilder.DEFAULT_BANK_LEVEL
		)

	for i in out.runs.size():
		var before: Bend = _corner_before(out, i)
		out.runs[i].free = maxi(0,
			out.runs[i].cells.size() - (before.size - 1) - (out.corners[i].size - 1)
		)

## `runs[i]` ends at `corners[i]`, so the corner it starts from is the previous.
func _corner_before(out: Compiled, i: int) -> Bend:
	return out.corners[(i - 1 + out.corners.size()) % out.corners.size()]

## The NxN cells a corner tile covers, and whether any of them sit on road the
## corner is not entitled to consume.
func _block_overlaps(occupied: Dictionary, c: Bend, size: int) -> bool:
	var allowed := {c.cell: true}
	for k in range(1, size):
		allowed[c.cell - c.in_dir * k] = true
		allowed[c.cell + c.out_dir * k] = true
	for a in size:
		for b in size:
			var cell: Vector2i = c.cell + c.out_dir * a - c.in_dir * b
			if occupied.has(cell) and not allowed.has(cell):
				return true
	return false

## Works out what height every segment actually sits at.
##
## The player asks for levels; this decides which of those requests can be built.
## Two hard rules, and then a budget:
##
##  - The start run is flat and the corner *before* it is at ground level. The
##    start line and its grid belong on the ground, and pinning that corner to
##    zero is what makes the running height return to where it began — closure
##    for elevation, the same trick the grid pulls for position.
##  - Height only changes inside a straight, so every run has to afford the ramps
##    for the difference between its own level and the corners at either end.
##
## Requests that do not fit are reduced rather than refused, so a click always
## does something and the badge shows what was actually built.
func _resolve_elevation(out: Compiled) -> void:
	var n := out.corners.size()
	for i in n:
		out.corners[i].level = _requested_level_of_corner(out.corners[i])
		out.runs[i].level = _requested_level_of_run(out.runs[i])

	# The two pinned-to-zero rules.
	out.runs[0].level = 0
	out.corners[n - 1].level = 0

	_reduce_to_fit(out)
	_measure_headroom(out)

func _requested_level_of_corner(corner: Bend) -> int:
	if not elevation.has(corner.cell):
		return 0
	return clampi(int(elevation[corner.cell]), 0, MAX_LEVEL)

func _requested_level_of_run(run: Run) -> int:
	for cell in run.cells:
		if elevation.has(cell):
			run.key = cell
			return clampi(int(elevation[cell]), 0, MAX_LEVEL)
	return 0

func _refresh_run_bounds(out: Compiled) -> void:
	var n := out.corners.size()
	for i in n:
		out.runs[i].entry_level = out.corners[(i - 1 + n) % n].level
		out.runs[i].exit_level = out.corners[i].level

## Shaves requested levels until every run can pay for its ramps. Each pass
## either lowers something or settles, and levels stop at zero, so it terminates.
func _reduce_to_fit(out: Compiled) -> void:
	var n := out.corners.size()
	var settled := false
	while not settled:
		settled = true
		_refresh_run_bounds(out)
		for i in n:
			var run: Run = out.runs[i]
			var budget := run.free - (START_CELLS if run.is_start else 0)
			if run.ramp_cells() <= budget:
				continue
			settled = false
			# Bring down whichever of the three levels is highest, preferring the
			# run's own so a sustained section survives a short straight rather
			# than being broken in half by it.
			var before: Bend = out.corners[(i - 1 + n) % n]
			var after: Bend = out.corners[i]
			var highest: int = maxi(run.level, maxi(before.level, after.level))
			if run.level == highest and run.level > 0:
				run.level -= 1
			elif after.level == highest and after.level > 0 and i != n - 1:
				after.level -= 1
			elif before.level == highest and before.level > 0 and (i - 1 + n) % n != n - 1:
				before.level -= 1
			elif run.level > 0:
				run.level -= 1
			else:
				# Nothing left to give: the straight is simply too short for the
				# corners it joins, which _emit reports as a flat section.
				break

## How much higher each segment could go, for the editor to cycle through. Probed
## one segment at a time against the resolved circuit, so the number offered is
## one that will actually be built.
func _measure_headroom(out: Compiled) -> void:
	var n := out.corners.size()
	_refresh_run_bounds(out)
	for i in n:
		out.runs[i].max_level = out.runs[i].level
		for probe in range(out.runs[i].level + 1, MAX_LEVEL + 1):
			var was: int = out.runs[i].level
			out.runs[i].level = probe
			if _all_runs_fit(out):
				out.runs[i].max_level = probe
			out.runs[i].level = was

		out.corners[i].max_level = out.corners[i].level
		# The corner before the start run is pinned down, so it has no headroom.
		if i == n - 1:
			continue
		for probe in range(out.corners[i].level + 1, MAX_LEVEL + 1):
			var was: int = out.corners[i].level
			out.corners[i].level = probe
			_refresh_run_bounds(out)
			if _all_runs_fit(out):
				out.corners[i].max_level = probe
			out.corners[i].level = was
		_refresh_run_bounds(out)

func _all_runs_fit(out: Compiled) -> bool:
	_refresh_run_bounds(out)
	for run in out.runs:
		var budget := run.free - (START_CELLS if run.is_start else 0)
		if run.ramp_cells() > budget:
			return false
	return true

## Rotates the runs and corners so that the run carrying the start line comes
## first. Returns false if no run can house the start pieces at all.
func _rotate_to_start(out: Compiled) -> bool:
	var chosen := -1
	for i in out.runs.size():
		if out.runs[i].cells.has(start_cell) and _fits_start(out.runs[i]):
			chosen = i
			break
	if chosen < 0:
		# The painted start cell is gone or its straight is too short; fall back
		# to the roomiest straight so the circuit stays drivable while editing.
		var best := -1
		for i in out.runs.size():
			if not _fits_start(out.runs[i]):
				continue
			if best < 0 or out.runs[i].free > out.runs[best].free:
				best = i
		chosen = best
	if chosen < 0:
		return false

	var runs := out.runs.slice(chosen) + out.runs.slice(0, chosen)
	var corners := out.corners.slice(chosen) + out.corners.slice(0, chosen)
	out.runs.assign(runs)
	out.corners.assign(corners)
	out.runs[0].is_start = true
	return true

func _fits_start(run: Run) -> bool:
	return run.free >= START_CELLS

## `out.corners[i]` is the corner that *follows* `out.runs[i]`, so emission is
## simply run, corner, run, corner all the way round.
func _emit(out: Compiled) -> Array:
	var segments := []
	for i in out.runs.size():
		_emit_run(segments, out.runs[i])
		var c: Bend = out.corners[i]
		# A raised corner needs the tile that holds its height; the flat ones have
		# the same deck at both ends but sit on the ground.
		var piece: String = (
			BRIDGE_CORNER_PIECES[c.size] if c.level > 0 else CORNER_PIECES[c.size]
		)
		# Always explicit, never left to the builder's default: the compiler has
		# already resolved what this corner's bank should be, and a flat corner
		# has to survive the trip as a flat corner rather than being handed back
		# the default for its radius.
		segments.append(["C", piece, c.turn, TrackBuilder.BANK_DEGREES[c.bank]])
	return segments

## A straight, as up to five stretches: a lead-in at the height it was entered,
## a ramp, the held section at its own level, a ramp, and a run-out at the height
## the next corner wants.
##
## Any of those can be empty. A flat run between two flat corners is just the
## lead-in; a sustained section that is already at height and stays there is just
## the held part, with no ramps at all.
func _emit_run(segments: Array, run: Run) -> void:
	var spare := run.free
	if run.is_start:
		# The start line and grid sit on the ground, so these go down before any
		# height is gained. `_resolve_elevation` guarantees the run enters flat.
		segments.append(["S", "roadStart", 1])
		segments.append(["S", "roadStartPositions", 1])
		spare -= START_CELLS

	var up := run.level - run.entry_level
	var down := run.exit_level - run.level
	var ramps := run.ramp_cells()
	if ramps > spare:
		# Should be unreachable — the resolver reduces levels until they fit — but
		# emitting a ramp there is no room for would break the loop's height, so
		# fall back to holding the entry height across the whole run.
		_emit_level(segments, spare, run.entry_level)
		return

	var hold := spare - ramps
	# Give the ramps a little room to breathe at whichever ends have one, and put
	# everything else at the run's own level, which is what makes a raised
	# straight read as a sustained section rather than a brief crest.
	var lead: int = (hold / 4 if up != 0 else 0)
	var run_out: int = ((hold - lead) / 3 if down != 0 else 0)
	var middle := hold - lead - run_out

	_emit_level(segments, lead, run.entry_level)
	if up != 0:
		segments.append(["S", "roadRampLongCurved", absi(up), signi(up)])
	_emit_level(segments, middle, run.level)
	if down != 0:
		segments.append(["S", "roadRampLongCurved", absi(down), signi(down)])
	_emit_level(segments, run_out, run.exit_level)

## `count` cells of straight held at `level`. Above the ground that means bridge
## pieces, which are one cell each; on the ground the long tile is used where it
## fits, so a flat straight is not needlessly chopped into single cells.
func _emit_level(segments: Array, count: int, level: int) -> void:
	if count <= 0:
		return
	if level > 0:
		segments.append(["S", "roadStraightBridge", count])
		return
	if count / 2 > 0:
		segments.append(["S", "roadStraightLong", count / 2])
	if count % 2 == 1:
		segments.append(["S", "roadStraight", 1])

## The cycle re-ordered to begin at the first cell of the start run, so the
## editor can highlight the racing order it is about to compile.
func _order_from(cycle: Array[Vector2i], out: Compiled) -> Array[Vector2i]:
	if out.runs.is_empty() or out.runs[0].cells.is_empty():
		return cycle
	var at := cycle.find(out.runs[0].cells[0])
	if at < 0:
		return cycle
	var rotated: Array[Vector2i] = []
	rotated.assign(cycle.slice(at) + cycle.slice(0, at))
	return rotated

## The builder always starts at its own origin heading south, so what it returns
## is this route rotated and translated. Recovering that rigid transform lets the
## editor overlay the real geometry — wide corner arcs and all — on the cells the
## player painted.
func _grid_transform(out: Compiled) -> Transform2D:
	if out.runs.is_empty() or out.runs[0].cells.is_empty():
		return Transform2D()
	var run: Run = out.runs[0]
	# The corner before the start run has already eaten the first cells of it.
	var eaten: int = out.corners[out.corners.size() - 1].size - 1
	var first: Vector2i = run.cells[mini(eaten, run.cells.size() - 1)]
	out.start_marker = first
	# The corner closing the start run entered it travelling along it.
	var dir := Vector2(out.corners[0].in_dir)

	# Godot rotates (0, 1) to (-sin, cos), and the builder's first heading is
	# south, which is (0, 1) in the same axis convention.
	var angle := atan2(-dir.x, dir.y)
	var anchor := Vector2(first) + Vector2(0.5, 0.5) - dir * 0.5
	return Transform2D(angle, anchor)

# --- persistence ---

## Plain JSON in `user://`, not a `.tres`. Godot resource files can carry a
## script path, so loading one is closer to running code than to reading data —
## fine for the tuning presets that ship inside the game, wrong for files a
## player can hand to another player.
func to_dict() -> Dictionary:
	var flat_cells := []
	for c in cells:
		flat_cells.append([c.x, c.y])
	var sizes := {}
	for k in corner_sizes:
		sizes[_key(k)] = corner_sizes[k]
	var banks := {}
	for k in corner_banks:
		banks[_key(k)] = corner_banks[k]
	var levels := {}
	for k in elevation:
		levels[_key(k)] = elevation[k]
	return {
		"version": FORMAT_VERSION,
		"id": id,
		"name": display_name,
		"cells": flat_cells,
		"start": [start_cell.x, start_cell.y],
		"reversed": reversed,
		"corner_sizes": sizes,
		"corner_banks": banks,
		"elevation": levels,
	}

static func from_dict(data: Dictionary) -> TrackLayout:
	var layout := TrackLayout.new()
	layout.id = String(data.get("id", ""))
	layout.display_name = String(data.get("name", "Untitled"))
	layout.reversed = bool(data.get("reversed", false))

	for pair in data.get("cells", []):
		if pair is Array and pair.size() == 2:
			layout.cells.append(Vector2i(int(pair[0]), int(pair[1])))

	var start: Array = data.get("start", [])
	if start.size() == 2:
		layout.start_cell = Vector2i(int(start[0]), int(start[1]))

	for k in data.get("corner_sizes", {}):
		layout.corner_sizes[_unkey(k)] = int(data["corner_sizes"][k])
	# Absent in tracks saved before banking existed, which is exactly right:
	# they get the default for each corner's radius rather than a flat circuit.
	for k in data.get("corner_banks", {}):
		layout.corner_banks[_unkey(k)] = int(data["corner_banks"][k])
	for k in data.get("elevation", {}):
		layout.elevation[_unkey(k)] = int(data["elevation"][k])
	return layout

static func _key(c: Vector2i) -> String:
	return "%d,%d" % [c.x, c.y]

static func _unkey(s: String) -> Vector2i:
	var parts := s.split(",")
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))

func duplicate_layout() -> TrackLayout:
	return TrackLayout.from_dict(to_dict())
