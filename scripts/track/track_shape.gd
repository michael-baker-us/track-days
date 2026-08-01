class_name TrackShape
extends RefCounted

## The painted loop seen as a rectilinear polygon — its corners, its straights,
## and the edits that move them.
##
## `TrackLayout.cells` stays the source of truth. This derives handles *from*
## the cells and writes cells back, so dragging a handle and painting a cell are
## edits to the same thing: persistence is unchanged, the compiler never learns
## which one the player used, and the two can be mixed freely.
##
## Every edit here returns a new corner list and is refused unless the loop it
## produces is still simple — one closed ring, every cell with exactly two
## neighbours. That is what makes dragging safe: the player cannot tear a hole
## in the circuit or fold it onto itself, so the failure modes that make
## freehand painting frustrating are unreachable by construction.

const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

## Fewest corners that can still be a circuit, and the shortest straight the
## builder can put a corner tile on either end of.
const MIN_CORNERS := 4
const MIN_EDGE := 2

# --- reading the loop ---

## Cells in visiting order, or empty if they are not one closed ring.
## This is the single definition of "a valid painted loop"; `TrackLayout` and
## the handle edits both defer to it.
##
## ## Crossings
##
## `allow_crossings` lets the ring pass through itself at a cell with all four
## neighbours, which the road then goes **straight through** twice. That is how a
## figure-of-eight, a Dunlop bridge or a Suzuka crossover gets drawn, and it is
## the biggest class of circuit the grid cannot otherwise express.
##
## It is **off by default and every current caller leaves it off**, so the editor
## and the compiler behave exactly as they did. Crossings are being built in
## stages (`docs/roadmap.md`, M13) and a shape the editor would accept but the
## builder could not build would be worse than one it refuses.
##
## The two passes must end up at different heights, but that is not decided here:
## this is topology and elevation belongs to the compiler, which is the only
## thing that knows what level each segment sits at. `walk` says the shape is
## drawable; `TrackLayout.compile` says whether it is a bridge or a collision.
static func walk(
	cells: Array[Vector2i], allow_crossings: bool = false
) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if cells.size() < 4:
		return empty

	var occupied := {}
	for c in cells:
		if occupied.has(c):
			return empty  # a cell painted twice is not a ring
		occupied[c] = true

	# Two neighbours is an ordinary piece of road. Four is a crossing, and only
	# four — three is a T junction, which is a branch and has no place in a
	# circuit however the heights work out.
	var crossings := {}
	for c in cells:
		var n := neighbour_count(occupied, c)
		if n == 2:
			continue
		if allow_crossings and n == 4:
			crossings[c] = true
			continue
		return empty

	# Started from ordinary road, because a crossing has no "the way I came" to
	# reason from until the walk arrives at it with a direction. One must exist:
	# a crossing needs four neighbours, so a ring cannot be made of them alone.
	var start := Vector2i.ZERO
	var started := false
	for c in cells:
		if not crossings.has(c):
			start = c
			started = true
			break
	if not started:
		return empty

	var heading := Vector2i.ZERO
	for d in NEIGHBOURS:
		if occupied.has(start + d):
			heading = d
			break

	# A crossing is on the ring twice, so the ring is longer than the cell count
	# by one per crossing.
	var expected := cells.size() + crossings.size()
	var order: Array[Vector2i] = []
	var at := start
	var closed := false

	for _step in expected:
		order.append(at)
		var next := at + heading
		if not occupied.has(next):
			return empty
		if not crossings.has(next):
			# Ordinary road: leave by the neighbour that is not where we came in.
			var came_from := -heading
			var onward := Vector2i.ZERO
			for d in NEIGHBOURS:
				if d != came_from and occupied.has(next + d):
					onward = d
					break
			if onward == Vector2i.ZERO:
				return empty
			heading = onward
		# A crossing keeps `heading`: the road goes straight over itself rather
		# than turning onto the leg it is crossing. That is what makes the two
		# passes independent, and it is the whole reason a crossing is not a
		# junction.
		at = next
		# Arriving back at `start` is closure, and only because `start` was
		# deliberately picked from ordinary road: an ordinary cell is on the ring
		# once, so reaching it again can only mean the lap is complete. Starting
		# from a crossing would make this wrong — the ring passes through one
		# twice, mid-lap, and the walk would stop half way round.
		if at == start:
			closed = true
			break

	if not closed or order.size() != expected:
		return empty

	# Every cell walked the right number of times: once for road, twice for a
	# crossing. Catches a figure that closes early and leaves a second ring
	# somewhere else, which is the failure the old length check caught.
	var seen := {}
	for c in order:
		seen[c] = int(seen.get(c, 0)) + 1
	for c in cells:
		if int(seen.get(c, 0)) != (2 if crossings.has(c) else 1):
			return empty
	return order

## Cells the ring passes straight through twice, in no particular order. Empty
## for an ordinary circuit.
static func crossings_in(cells: Array[Vector2i]) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var occupied := {}
	for c in cells:
		occupied[c] = true
	for c in cells:
		if neighbour_count(occupied, c) == 4:
			out.append(c)
	return out

static func neighbour_count(occupied: Dictionary, c: Vector2i) -> int:
	var n := 0
	for d in NEIGHBOURS:
		if occupied.has(c + d):
			n += 1
	return n

## Indices into the cycle where the direction of travel changes.
static func bend_indices(cycle: Array[Vector2i]) -> Array[int]:
	var n := cycle.size()
	var out: Array[int] = []
	for i in n:
		var into := cycle[i] - cycle[(i - 1 + n) % n]
		var away := cycle[(i + 1) % n] - cycle[i]
		if into != away:
			out.append(i)
	return out

## The loop's corner points, in order. Empty if the cells are not a valid loop.
static func corners_of(cells: Array[Vector2i]) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var cycle := walk(cells)
	if cycle.is_empty():
		return out
	for i in bend_indices(cycle):
		out.append(cycle[i])
	return out

## The cells a corner list traces out. Assumes consecutive corners are
## axis-aligned, which every edit here maintains.
static func cells_from_corners(corners: Array[Vector2i]) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var n := corners.size()
	for i in n:
		var a := corners[i]
		var b := corners[(i + 1) % n]
		var d := b - a
		var step := Vector2i(signi(d.x), signi(d.y))
		if step == Vector2i.ZERO:
			continue
		var at := a
		# Stop before b; the next edge contributes it.
		while at != b:
			out.append(at)
			at += step
	return out

# --- validating an edit ---

## True if this corner list describes a circuit the builder can be handed.
static func corners_valid(corners: Array[Vector2i]) -> bool:
	var n := corners.size()
	if n < MIN_CORNERS:
		return false
	for i in n:
		var d := corners[(i + 1) % n] - corners[i]
		# Exactly one axis must change, or the edge is diagonal or degenerate.
		if (d.x != 0) == (d.y != 0):
			return false
		if maxi(absi(d.x), absi(d.y)) < MIN_EDGE:
			return false
	# The cells are the real test: this is what catches a loop folded onto
	# itself, where every edge is legal but the ring touches or crosses.
	return not walk(cells_from_corners(corners)).is_empty()

## Drops corners the loop does not turn at. Moving one corner onto a neighbour's
## line leaves a vertex that is no longer a bend, and left in place it would
## show a handle that does nothing and confuse the corner count.
static func prune(corners: Array[Vector2i]) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var n := corners.size()
	if n == 0:
		return out
	for i in n:
		var prev := corners[(i - 1 + n) % n]
		var next := corners[(i + 1) % n]
		var into := corners[i] - prev
		var away := next - corners[i]
		var straight_x: bool = into.y == 0 and away.y == 0
		var straight_z: bool = into.x == 0 and away.x == 0
		if straight_x or straight_z:
			continue  # not a turn
		out.append(corners[i])
	return out

# --- the edits ---

## Moves one corner. The two straights meeting there stay axis-aligned by
## carrying each neighbour along a single axis, which is what makes a drag feel
## like pulling the road rather than breaking it.
##
## Returns an empty array if the result would not be a valid loop, so a caller
## can simply refuse the drag.
static func move_corner(
	corners: Array[Vector2i], index: int, to: Vector2i
) -> Array[Vector2i]:
	var n := corners.size()
	var out: Array[Vector2i] = corners.duplicate()
	var prev := (index - 1 + n) % n
	var next := (index + 1) % n
	out[index] = to

	# Whichever axis each neighbouring edge runs along is the one to preserve.
	if corners[prev].y == corners[index].y:
		out[prev] = Vector2i(corners[prev].x, to.y)
	else:
		out[prev] = Vector2i(to.x, corners[prev].y)
	if corners[next].y == corners[index].y:
		out[next] = Vector2i(corners[next].x, to.y)
	else:
		out[next] = Vector2i(to.x, corners[next].y)

	return _accept(out)

## Slides a whole straight sideways, carrying the corners at both ends.
static func move_edge(
	corners: Array[Vector2i], index: int, to: Vector2i
) -> Array[Vector2i]:
	var n := corners.size()
	var out: Array[Vector2i] = corners.duplicate()
	var a := corners[index]
	var b := corners[(index + 1) % n]
	if a.y == b.y:
		out[index] = Vector2i(a.x, to.y)
		out[(index + 1) % n] = Vector2i(b.x, to.y)
	else:
		out[index] = Vector2i(to.x, a.y)
		out[(index + 1) % n] = Vector2i(to.x, b.y)
	return _accept(out)

## Pushes a section of a straight out sideways, adding four corners — the way a
## chicane or a new loop of track gets made. `at` is where along the straight to
## put it; `depth` how far out, signed.
static func insert_bump(
	corners: Array[Vector2i], index: int, at: Vector2i, depth: int
) -> Array[Vector2i]:
	var n := corners.size()
	var a := corners[index]
	var b := corners[(index + 1) % n]
	var horizontal: bool = a.y == b.y

	var span: int = absi(b.x - a.x) if horizontal else absi(b.y - a.y)
	var width: int = clampi(span / 3, MIN_EDGE, maxi(MIN_EDGE, span - MIN_EDGE * 2))
	if span < width + MIN_EDGE * 2:
		return []

	var along: int = at.x if horizontal else at.y
	var lo: int = mini(a.x, b.x) if horizontal else mini(a.y, b.y)
	var hi: int = maxi(a.x, b.x) if horizontal else maxi(a.y, b.y)
	# Keep the bump clear of both ends so the corners either side still have
	# straight to sit on.
	var start := clampi(along - width / 2, lo + MIN_EDGE, hi - MIN_EDGE - width)
	var finish := start + width

	var inserted: Array[Vector2i] = []
	if horizontal:
		var y := a.y
		var out_y := y + depth
		var forward: bool = b.x > a.x
		var first: int = start if forward else finish
		var second: int = finish if forward else start
		inserted = [
			Vector2i(first, y), Vector2i(first, out_y),
			Vector2i(second, out_y), Vector2i(second, y),
		]
	else:
		var x := a.x
		var out_x := x + depth
		var forward: bool = b.y > a.y
		var first: int = start if forward else finish
		var second: int = finish if forward else start
		inserted = [
			Vector2i(x, first), Vector2i(out_x, first),
			Vector2i(out_x, second), Vector2i(x, second),
		]

	var out: Array[Vector2i] = []
	out.assign(
		corners.slice(0, index + 1) + inserted + corners.slice(index + 1)
	)
	return _accept(out)

## Straightens the jog a corner belongs to. A single corner cannot be removed
## from a rectilinear ring on its own — they come in pairs — so this tries the
## corner with each of its neighbours and takes whichever leaves a valid loop.
static func straighten_at(corners: Array[Vector2i], index: int) -> Array[Vector2i]:
	var n := corners.size()
	for pair_start in [index, (index - 1 + n) % n]:
		var out: Array[Vector2i] = []
		for i in n:
			if i == pair_start or i == (pair_start + 1) % n:
				continue
			out.append(corners[i])
		var accepted := _accept(out)
		if not accepted.is_empty():
			return accepted
	return []

## Prune, then validate. Every edit goes through here, so "would this break the
## circuit" is answered in exactly one place.
static func _accept(corners: Array[Vector2i]) -> Array[Vector2i]:
	var pruned := prune(corners)
	var empty: Array[Vector2i] = []
	return pruned if corners_valid(pruned) else empty

## Joins the two loose ends of a half-drawn loop with a right-angled path.
##
## Drawing a circuit freehand almost always ends with the two ends near each
## other but not touching, and closing that last stretch by hand is the fiddliest
## part of the whole job. Returns the cells to add, or empty if the ends cannot
## be joined without running into road that is already there.
static func close_gap(cells: Array[Vector2i]) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if cells.size() < 4:
		return empty

	var occupied := {}
	for c in cells:
		occupied[c] = true
	var ends: Array[Vector2i] = []
	for c in cells:
		var n := neighbour_count(occupied, c)
		if n == 0:
			return empty  # an isolated cell is not an end to join
		if n == 1:
			ends.append(c)
	if ends.size() != 2:
		return empty

	# Two right-angled routes join any pair of cells; take whichever lands on no
	# existing road, so closing the gap cannot create a junction.
	for corner in [Vector2i(ends[1].x, ends[0].y), Vector2i(ends[0].x, ends[1].y)]:
		var path := _leg(ends[0], corner) + _leg(corner, ends[1])
		var ok := true
		var added: Array[Vector2i] = []
		var seen := {}
		for cell in path:
			if cell == ends[0] or cell == ends[1]:
				continue
			if occupied.has(cell) or seen.has(cell):
				ok = false
				break
			seen[cell] = true
			added.append(cell)
		if not ok:
			continue
		var merged: Array[Vector2i] = cells.duplicate()
		merged.append_array(added)
		if not walk(merged).is_empty():
			return added
	return empty

## A path of cells from `from` to `to`, one orthogonal step at a time and
## excluding `from`.
##
## Stepping one axis at a time is the whole point. A straight interpolation
## towards the target lays a *diagonal* staircase, and two cells that meet only
## at their corners are not neighbours here — so every diagonal step is a break
## in the road. One sloppy freehand stroke produced six loose ends that way.
static func orthogonal_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var at := from
	# Bounded so a wild jump cannot walk a very long way.
	var guard := 0
	while at != to and guard < 4096:
		guard += 1
		var d := to - at
		# Take the axis with further to go, so the staircase tracks the stroke.
		if d.x != 0 and absi(d.x) >= absi(d.y):
			at += Vector2i(signi(d.x), 0)
		else:
			at += Vector2i(0, signi(d.y))
		out.append(at)
	return out

## Cells from `a` to `b` inclusive along one axis.
static func _leg(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var d := b - a
	var step := Vector2i(signi(d.x), signi(d.y))
	if step == Vector2i.ZERO:
		return [a]
	var at := a
	while at != b:
		out.append(at)
		at += step
	out.append(b)
	return out

# --- hit testing ---

## Index of the straight a cell lies on, or -1. Corners belong to no straight,
## so grabbing near a bend never slides the wrong piece of road.
static func edge_at(corners: Array[Vector2i], cell: Vector2i) -> int:
	var n := corners.size()
	for i in n:
		var a := corners[i]
		var b := corners[(i + 1) % n]
		if a.y == b.y:
			if cell.y != a.y:
				continue
			if cell.x > mini(a.x, b.x) and cell.x < maxi(a.x, b.x):
				return i
		else:
			if cell.x != a.x:
				continue
			if cell.y > mini(a.y, b.y) and cell.y < maxi(a.y, b.y):
				return i
	return -1

## The midpoint of a straight, where its badge sits.
static func edge_midpoint(corners: Array[Vector2i], index: int) -> Vector2:
	var n := corners.size()
	return (Vector2(corners[index]) + Vector2(corners[(index + 1) % n])) * 0.5
