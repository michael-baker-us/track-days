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
## Kenney has no banked or raised corner pieces, so a plateau has to live inside
## one straight run and come back down before the next corner. That is exactly
## what the hand-built Highland layout does. A run is given a *level*; each level
## costs a `roadRampLong` up and another down, and the compiler places the ramps
## and bridge inside the run's spare cells. Because every plateau returns to zero
## within its own run, the loop's height closes for free, the same way its
## position does.

const FORMAT_VERSION := 1

## Kenney ships exactly three corners. The key is the size N of the NxN block.
const CORNER_PIECES := {1: "roadCornerSmall", 2: "roadCornerLarge", 3: "roadCornerLarger"}
const MAX_CORNER := 3

## `roadStart` and `roadStartPositions`, two cells each. The run carrying the
## start line has to find room for both before anything else.
const START_CELLS := 4

## One level of elevation is a `roadRampLong` up and another down, two cells
## each, plus at least one bridge cell on top.
const CELLS_PER_LEVEL := 4
const MAX_LEVEL := 3

## Longest plateau the compiler will build, in bridge cells. Past this a climb
## stops reading as a hill and starts reading as a second, higher circuit.
const MAX_BRIDGE := 4

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

## A straight run between two bends.
class Run extends RefCounted:
	var cells: Array[Vector2i] = []
	var free: int         # cells left after the corners at each end take theirs
	var level: int        # plateau height, in ramp pieces
	var max_level: int
	var is_start: bool
	var key: Vector2i     # the cell elevation is recorded against

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
## A cell within a run -> that run's plateau level. Keyed by cell rather than by
## run index so that repainting elsewhere on the circuit does not shuffle every
## hill onto a different straight.
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
	for c in cells:
		occupied[c] = true

	# Exactly two neighbours everywhere is precisely the condition for a simple
	# closed loop: fewer means a dead end, more means a junction or a blob, and
	# neither can be driven as a circuit.
	var loose := 0
	var junctions := 0
	for c in cells:
		var n := _neighbour_count(occupied, c)
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

	var cycle := _walk(occupied, cells[0])
	if cycle.size() != cells.size():
		out.errors.append("That is more than one separate loop — join them or erase one.")
		return out
	if reversed:
		cycle.reverse()

	var bends := _find_bends(cycle)
	if bends.size() < 4:
		out.errors.append("A circuit needs at least four corners.")
		return out

	_build_corners_and_runs(cycle, bends, out)
	_fit_corners(occupied, out)
	_apply_elevation(out)

	if not _rotate_to_start(out):
		out.errors.append(
			"No straight long enough for the start line. Every corner is eating "
			+ "its straights — shrink one, or paint a longer section."
		)
		return out

	out.segments = _emit(out)
	out.cycle = _order_from(cycle, out)
	out.to_grid = _grid_transform(out)
	out.ok = out.errors.is_empty()
	return out

func _neighbour_count(occupied: Dictionary, c: Vector2i) -> int:
	var n := 0
	for d in NEIGHBOURS:
		if occupied.has(c + d):
			n += 1
	return n

## Follows the loop from a starting cell, always stepping to the neighbour that
## is not where we just came from.
func _walk(occupied: Dictionary, from: Vector2i) -> Array[Vector2i]:
	var order: Array[Vector2i] = [from]
	var prev := from
	var cur := from
	for d in NEIGHBOURS:
		if occupied.has(from + d):
			cur = from + d
			break
	while cur != from:
		order.append(cur)
		var next := cur
		for d in NEIGHBOURS:
			var cand := cur + d
			if occupied.has(cand) and cand != prev:
				next = cand
				break
		prev = cur
		cur = next
		if order.size() > occupied.size():
			break
	return order

## Indices into the cycle where travel direction changes.
func _find_bends(cycle: Array[Vector2i]) -> Array[int]:
	var n := cycle.size()
	var out: Array[int] = []
	for i in n:
		var into := cycle[i] - cycle[(i - 1 + n) % n]
		var away := cycle[(i + 1) % n] - cycle[i]
		if into != away:
			out.append(i)
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

func _apply_elevation(out: Compiled) -> void:
	for run in out.runs:
		var spare := run.free
		run.max_level = clampi((spare - 1) / CELLS_PER_LEVEL, 0, MAX_LEVEL)
		run.level = 0
		for cell in run.cells:
			if elevation.has(cell):
				run.key = cell
				run.level = clampi(int(elevation[cell]), 0, run.max_level)
				break

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
	# The start pieces come out of the same budget as everything else.
	out.runs[0].max_level = clampi(
		(out.runs[0].free - START_CELLS - 1) / CELLS_PER_LEVEL, 0, MAX_LEVEL
	)
	out.runs[0].level = mini(out.runs[0].level, out.runs[0].max_level)
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
		segments.append(["C", CORNER_PIECES[c.size], c.turn])
	return segments

func _emit_run(segments: Array, run: Run) -> void:
	var spare := run.free
	if run.is_start:
		segments.append(["S", "roadStart", 1])
		segments.append(["S", "roadStartPositions", 1])
		spare -= START_CELLS

	if run.level <= 0:
		_emit_flat(segments, spare)
		return

	# Ramps first, then as much plateau as the leftovers allow, then split what
	# remains evenly either side so the hill sits in the middle of the straight.
	var rest := spare - run.level * CELLS_PER_LEVEL
	var bridge := clampi(rest - 2, 1, MAX_BRIDGE)
	var flat := rest - bridge
	_emit_flat(segments, flat / 2)
	segments.append(["S", "roadRampLong", run.level, 1])
	segments.append(["S", "roadStraightBridge", bridge])
	segments.append(["S", "roadRampLong", run.level, -1])
	_emit_flat(segments, flat - flat / 2)

func _emit_flat(segments: Array, count: int) -> void:
	if count <= 0:
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
