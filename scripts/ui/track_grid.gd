class_name TrackGrid
extends Control

## The editor's canvas. Shows the circuit, and lets it be reshaped by dragging
## the road itself.
##
## ## Why there are no tool modes
##
## The first version had four: paint, start line, corners, elevation. A click on
## a cell meant whichever the toolbar last said, so the player had to hold the
## current mode in their head and the canvas gave no clue what a click would do.
##
## Instead every action now has its own thing on screen to hit — a corner handle,
## a radius badge, a climb badge, the start flag, the body of a straight. What a
## click does is decided by what is under it, which is visible, so there is no
## mode to remember and no wrong-mode mistakes to undo.
##
## ## Why dragging rather than painting
##
## Painting a closed one-cell-wide ring by hand is the hard way to get a
## circuit: a forty-cell loop has to be traced exactly, and one stray cell or
## one gap invalidates it. Dragging edits the loop as a shape — `TrackShape`
## refuses any drag that would not leave a valid ring — so loose ends and
## junctions are simply not reachable.
##
## Free painting is still there on Shift, for detail work the handles cannot
## express.
##
## ## Why the compiled centreline is drawn over the cells
##
## A painted bend is a right angle; the tile that takes it is an arc starting up
## to two cells early and bulging across the inside. Cells alone would misstate
## the track by around 25 m at the widest corner, so the real centreline is
## overlaid, coloured by height, and that is what the player reads.

signal layout_edited            ## a committed change, worth an undo entry
signal layout_touched           ## live during a drag; recompile but do not record
signal corner_clicked(cell: Vector2i)
signal elevation_clicked(cell: Vector2i)
signal start_clicked(cell: Vector2i)
signal status(text: String)

const MIN_ZOOM := 8.0
const MAX_ZOOM := 48.0
const BASE_CELL := 22.0

## How close, in cells, the cursor has to be to grab a handle or hit a badge.
const GRAB := 0.75

const COL_BG := Color(0.10, 0.11, 0.13)
const COL_GRID := Color(0.16, 0.18, 0.21)
const COL_ROAD := Color(0.29, 0.31, 0.35)
const COL_ROAD_HOT := Color(0.38, 0.41, 0.47)
const COL_LINE := Color(0.55, 0.80, 0.45)
const COL_HIGH := Color(0.95, 0.72, 0.30)
const COL_PROBLEM := Color(0.85, 0.30, 0.30)
const COL_START := Color(0.95, 0.95, 0.98)
const COL_TEXT := Color(0.88, 0.90, 0.93)
const COL_HANDLE := Color(0.55, 0.80, 0.45)
const COL_HANDLE_HOT := Color(1.0, 1.0, 1.0)
const COL_BADGE := Color(0.16, 0.18, 0.22)
const COL_REFUSED := Color(0.85, 0.30, 0.30)

enum Hit { NONE, CORNER, EDGE, RADIUS, CLIMB, START }

var layout: TrackLayout
var compiled: TrackLayout.Compiled

var _cell_px := BASE_CELL
var _origin := Vector2.ZERO
var _hover_cell := Vector2i.ZERO
var _has_hover := false
var _panning := false

## What the cursor is over, and which corner or straight of it.
var _hot := Hit.NONE
var _hot_index := -1

## What is being dragged, if anything.
var _drag := Hit.NONE
var _drag_index := -1
## Set while a drag is being refused, so the road can be drawn red instead of
## silently snapping back and looking broken.
var _drag_refused := false

## Free painting, on Shift. +1 laying road, -1 erasing, 0 not painting.
var _stroke := 0
var _last_painted := Vector2i.ZERO
var _has_last_painted := false
var _painted_any := false

## Corner points of the loop, recomputed whenever the layout changes. Empty when
## the cells are not a valid ring, which is the only time handles disappear.
var _corners: Array[Vector2i] = []
## Cached so a drag does not re-walk the whole circuit on every mouse move.
var _preview: PackedVector2Array = PackedVector2Array()
var _preview_cols: PackedColorArray = PackedColorArray()
## Middle of the circuit, for deciding which side of the road is "inside".
var _centre := Vector2.ZERO

func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_ARROW

## Called by the editor after every recompile.
func refresh(new_compiled: TrackLayout.Compiled) -> void:
	compiled = new_compiled
	_corners = TrackShape.corners_of(layout.cells)
	_centre = Vector2.ZERO
	for c in layout.cells:
		_centre += Vector2(c)
	_centre /= maxf(1.0, float(layout.cells.size()))
	_rebuild_preview()
	queue_redraw()

func has_handles() -> bool:
	return not _corners.is_empty()

# --- view ---

func cell_to_screen(cell: Vector2) -> Vector2:
	return _origin + cell * _cell_px

func screen_to_cell(pos: Vector2) -> Vector2i:
	var v := (pos - _origin) / _cell_px
	return Vector2i(floori(v.x), floori(v.y))

## Continuous cell coordinates, for hit-testing against handles that sit on
## cell centres rather than filling a cell.
func screen_to_cell_f(pos: Vector2) -> Vector2:
	return (pos - _origin) / _cell_px

## Frames the circuit, or a blank patch of grid if there is not one yet.
func fit_view() -> void:
	if layout == null or layout.cells.is_empty():
		_cell_px = BASE_CELL
		_origin = size * 0.5 - Vector2(_cell_px, _cell_px) * 0.5
		queue_redraw()
		return

	var lo := Vector2(layout.cells[0])
	var hi := lo
	for c in layout.cells:
		lo = lo.min(Vector2(c))
		hi = hi.max(Vector2(c) + Vector2.ONE)

	# Badges hang up to ~1.7 cells outside the road, so fitting the cells alone
	# pushes the outermost ones off screen.
	lo -= Vector2(2.0, 2.0)
	hi += Vector2(2.0, 2.0)

	var span := hi - lo
	var margin := 40.0
	_cell_px = clampf(
		minf((size.x - margin) / maxf(span.x, 1.0), (size.y - margin) / maxf(span.y, 1.0)),
		MIN_ZOOM, MAX_ZOOM
	)
	_origin = size * 0.5 - (lo + span * 0.5) * _cell_px
	queue_redraw()

## Brings a cell into view, so an error the player cannot see can be pointed at.
func focus_on(cell: Vector2i) -> void:
	_origin = size * 0.5 - (Vector2(cell) + Vector2(0.5, 0.5)) * _cell_px
	queue_redraw()

# --- hit testing ---

## What the cursor is over. Ordered smallest target first: the badges are small
## and sit on top of the road, so they have to win over the straight beneath.
func _hit_test(pos: Vector2) -> Array:
	var at := screen_to_cell_f(pos)
	if _corners.is_empty():
		return [Hit.NONE, -1]

	if compiled != null and compiled.ok:
		for i in compiled.corners.size():
			var corner: TrackLayout.Bend = compiled.corners[i]
			if at.distance_to(_radius_badge_at(corner)) < GRAB:
				return [Hit.RADIUS, i]
		for i in compiled.runs.size():
			var run: TrackLayout.Run = compiled.runs[i]
			if run.cells.is_empty() or run.max_level <= 0:
				continue
			if at.distance_to(_climb_badge_at(run)) < GRAB:
				return [Hit.CLIMB, i]
		if at.distance_to(Vector2(compiled.start_marker) + Vector2(0.5, 0.5)) < GRAB:
			return [Hit.START, 0]

	for i in _corners.size():
		if at.distance_to(Vector2(_corners[i]) + Vector2(0.5, 0.5)) < GRAB:
			return [Hit.CORNER, i]

	var edge := TrackShape.edge_at(_corners, screen_to_cell(pos))
	if edge >= 0:
		return [Hit.EDGE, edge]
	return [Hit.NONE, -1]

## Badges sit *off* the road, never on it. On it, they steal clicks meant for
## the road underneath — a climb badge at the midpoint of a straight swallowed
## the double-click that is supposed to add a bend there.
##
## Corner badges go outside the loop and climb badges inside, so which kind a
## blob is can be told from where it sits before reading it.
## Both use the centroid to decide which way is out, rather than the direction
## of travel: a loop painted anticlockwise would put every badge on the wrong
## side of the road if this keyed off the turn.
func _radius_badge_at(corner: TrackLayout.Bend) -> Vector2:
	var at := Vector2(corner.cell) + Vector2(0.5, 0.5)
	var away := (Vector2(corner.in_dir) - Vector2(corner.out_dir)).normalized()
	if away.dot(at - _centre) < 0.0:
		away = -away
	return at + away * 1.7

func _climb_badge_at(run: TrackLayout.Run) -> Vector2:
	var mid := Vector2(run.cells[run.cells.size() / 2]) + Vector2(0.5, 0.5)
	var along := Vector2(run.cells[run.cells.size() - 1] - run.cells[0])
	if along.length() < 0.001:
		along = Vector2(1, 0)
	along = along.normalized()
	var across := Vector2(-along.y, along.x)
	if across.dot(_centre - mid) < 0.0:
		across = -across
	return mid + across * 1.6

# --- input ---

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_button(event)
	elif event is InputEventMouseMotion:
		_motion(event)

func _button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not event.pressed:
			return
		var step := 1.12 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12
		var before := screen_to_cell_f(event.position)
		_cell_px = clampf(_cell_px * step, MIN_ZOOM, MAX_ZOOM)
		# Keep whatever was under the cursor under the cursor.
		_origin = event.position - before * _cell_px
		queue_redraw()
		return

	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed
		return

	if not event.pressed:
		_end_drag()
		return

	grab_focus()
	var cell := screen_to_cell(event.position)

	# Shift is the escape hatch into freehand painting, for anything the handles
	# cannot express.
	if event.shift_pressed:
		_stroke = -1 if event.button_index == MOUSE_BUTTON_RIGHT else 1
		_last_painted = cell
		_has_last_painted = true
		_painted_any = false
		_paint(cell)
		return

	var hit := _hit_test(event.position)
	var kind: int = hit[0]
	var index: int = hit[1]

	if event.button_index == MOUSE_BUTTON_RIGHT:
		if kind == Hit.CORNER:
			_straighten(index)
		return

	# Double-clicking a straight pulls a new bend out of it. Without this the
	# handles can only move and remove corners, so a circuit could never gain
	# one and every track would keep the four it started with.
	if event.double_click and kind == Hit.EDGE:
		_insert_bend(index, cell)
		return

	match kind:
		Hit.RADIUS:
			corner_clicked.emit(compiled.corners[index].cell)
		Hit.CLIMB:
			elevation_clicked.emit(_climb_cell(index))
		Hit.START:
			status.emit("Drag the flag along the road to move the start line.")
			_drag = Hit.START
			_drag_index = 0
		Hit.CORNER, Hit.EDGE:
			_drag = kind
			_drag_index = index
		_:
			status.emit(
				"Grab a corner or a straight to reshape the circuit."
				if has_handles() else
				"Shift-drag to lay road, shift-right-drag to erase."
			)

func _climb_cell(run_index: int) -> Vector2i:
	var run: TrackLayout.Run = compiled.runs[run_index]
	return run.cells[run.cells.size() / 2]

func _motion(event: InputEventMouseMotion) -> void:
	if _panning:
		_origin += event.relative
		queue_redraw()
		return

	var cell := screen_to_cell(event.position)
	var moved: bool = not _has_hover or cell != _hover_cell
	_hover_cell = cell
	_has_hover = true

	if _stroke != 0:
		_paint_to(cell)
		return

	if _drag != Hit.NONE:
		_apply_drag(cell)
		return

	var hit := _hit_test(event.position)
	if hit[0] != _hot or hit[1] != _hot_index:
		_hot = hit[0]
		_hot_index = hit[1]
		_update_cursor()
		queue_redraw()
	elif moved:
		queue_redraw()

func _update_cursor() -> void:
	match _hot:
		Hit.CORNER, Hit.EDGE, Hit.START:
			mouse_default_cursor_shape = Control.CURSOR_DRAG
		Hit.RADIUS, Hit.CLIMB:
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_:
			mouse_default_cursor_shape = Control.CURSOR_ARROW

# --- dragging the shape ---

func _apply_drag(cell: Vector2i) -> void:
	if _drag == Hit.START:
		if layout.cells.has(cell):
			layout.start_cell = cell
			layout_touched.emit()
		return

	var moved: Array[Vector2i] = (
		TrackShape.move_corner(_corners, _drag_index, cell) if _drag == Hit.CORNER
		else TrackShape.move_edge(_corners, _drag_index, cell)
	)
	if moved.is_empty():
		# Refused: the drag would tear or fold the loop. Say so rather than
		# letting the road sit still for no visible reason.
		if not _drag_refused:
			_drag_refused = true
			status.emit("Cannot go there — the circuit would cross itself.")
			queue_redraw()
		return

	_drag_refused = false
	var was := _corners.size()
	layout.cells = TrackShape.cells_from_corners(moved)
	# Pruning can dissolve the handle being dragged, which would leave the drag
	# pointing at the wrong corner for every later event.
	if moved.size() != was:
		_end_drag_index(moved, cell)
	_corners = moved
	layout_touched.emit()

## Re-finds the dragged corner after a prune renumbered the list.
func _end_drag_index(moved: Array[Vector2i], cell: Vector2i) -> void:
	if _drag != Hit.CORNER:
		_drag = Hit.NONE
		_drag_index = -1
		return
	var best := -1
	var best_d := 1e9
	for i in moved.size():
		var d := Vector2(moved[i]).distance_to(Vector2(cell))
		if d < best_d:
			best_d = d
			best = i
	_drag_index = best

## Pushes a section of a straight sideways, adding a bend the player can then
## drag. Tries outwards first — growing the circuit is what is usually wanted,
## and it cannot collide with anything — then inwards, then shallower, so a
## double-click on a cramped straight still does something rather than nothing.
func _insert_bend(index: int, cell: Vector2i) -> void:
	var outward := _outward_sign(index)
	for depth in [6, 4, 3, 2]:
		for sign_ in [outward, -outward]:
			var out := TrackShape.insert_bump(_corners, index, cell, depth * sign_)
			if out.is_empty():
				continue
			layout.cells = TrackShape.cells_from_corners(out)
			_corners = out
			status.emit("Added a bend — drag it into shape.")
			layout_edited.emit()
			return
	status.emit("No room for a bend here — try a longer straight.")

## Which way is away from the middle of the circuit, along the axis the given
## straight can move in.
func _outward_sign(index: int) -> int:
	var centre := Vector2.ZERO
	for c in layout.cells:
		centre += Vector2(c)
	centre /= maxf(1.0, float(layout.cells.size()))

	var n := _corners.size()
	var a := _corners[index]
	var b := _corners[(index + 1) % n]
	var mid := (Vector2(a) + Vector2(b)) * 0.5
	var off: float = (mid.y - centre.y) if a.y == b.y else (mid.x - centre.x)
	return 1 if off >= 0.0 else -1

func _straighten(index: int) -> void:
	var out := TrackShape.straighten_at(_corners, index)
	if out.is_empty():
		status.emit("That corner cannot be removed — a circuit needs at least four.")
		return
	layout.cells = TrackShape.cells_from_corners(out)
	_corners = out
	layout_edited.emit()

func _end_drag() -> void:
	var was_dragging: bool = _drag != Hit.NONE
	_drag = Hit.NONE
	_drag_index = -1
	_drag_refused = false
	var painted := _painted_any
	_stroke = 0
	_has_last_painted = false
	_painted_any = false
	if was_dragging or painted:
		layout_edited.emit()
	queue_redraw()

# --- free painting ---

## Fills in every cell between the last one and this one.
##
## Without this a drag paints only the cells the mouse happened to be sampled
## over: at any normal speed that skips most of them, leaving a dotted line the
## validator then correctly reports as full of holes. It made the paint tool
## feel broken, because it was.
func _paint_to(cell: Vector2i) -> void:
	if not _has_last_painted:
		_paint(cell)
		_last_painted = cell
		_has_last_painted = true
		return

	var from := _last_painted
	var delta := cell - from
	var steps := maxi(absi(delta.x), absi(delta.y))
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		_paint(Vector2i(
			from.x + roundi(delta.x * t), from.y + roundi(delta.y * t)
		))
	_last_painted = cell

func _paint(cell: Vector2i) -> void:
	var had := layout.cells.has(cell)
	if _stroke > 0 and not had:
		layout.cells.append(cell)
	elif _stroke < 0 and had:
		layout.cells.erase(cell)
	else:
		return
	_painted_any = true
	layout_touched.emit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_has_hover = false
		if _drag != Hit.NONE or _stroke != 0:
			_end_drag()
		_hot = Hit.NONE
		_hot_index = -1
		queue_redraw()

# --- drawing ---

func _rebuild_preview() -> void:
	_preview = PackedVector2Array()
	_preview_cols = PackedColorArray()
	if compiled == null or not compiled.ok or compiled.segments.is_empty():
		return
	var builder := TrackBuilder.new()
	var result := builder.measure(compiled.segments)
	if builder.centreline.size() < 2:
		return
	var peak := maxf(result.peak, 0.001)
	for p in builder.centreline:
		_preview.append(compiled.to_grid * (Vector2(p.x, p.z) / TrackBuilder.SCALE))
		_preview_cols.append(COL_LINE.lerp(COL_HIGH, clampf(p.y / peak, 0.0, 1.0)))

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COL_BG)
	_draw_grid()
	if layout == null:
		return
	_draw_cells()
	if compiled != null:
		_draw_problems()
		_draw_centreline()
		if compiled.ok:
			_draw_badges()
			_draw_start()
	_draw_handles()
	_draw_hover()

func _draw_grid() -> void:
	# Skip the grid when zoomed out far enough that it would be solid lines.
	if _cell_px < 10.0:
		return
	var first := screen_to_cell(Vector2.ZERO)
	var last := screen_to_cell(size) + Vector2i.ONE
	for x in range(first.x, last.x + 1):
		var sx := cell_to_screen(Vector2(x, 0)).x
		draw_line(Vector2(sx, 0), Vector2(sx, size.y), COL_GRID, 1.0)
	for y in range(first.y, last.y + 1):
		var sy := cell_to_screen(Vector2(0, y)).y
		draw_line(Vector2(0, sy), Vector2(size.x, sy), COL_GRID, 1.0)

func _draw_cells() -> void:
	var inset := 1.0 if _cell_px > 12.0 else 0.0
	# The straight under the cursor lights up, so it is obvious that grabbing it
	# will move that piece of road and not some other.
	var hot_cells := {}
	if _hot == Hit.EDGE and _hot_index >= 0 and _drag == Hit.NONE:
		for c in _edge_cells(_hot_index):
			hot_cells[c] = true
	for c in layout.cells:
		var at := cell_to_screen(Vector2(c)) + Vector2(inset, inset)
		var col := COL_ROAD_HOT if hot_cells.has(c) else COL_ROAD
		if _drag_refused:
			col = col.lerp(COL_REFUSED, 0.35)
		draw_rect(Rect2(at, Vector2.ONE * (_cell_px - inset * 2.0)), col)

func _edge_cells(index: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var n := _corners.size()
	if n == 0:
		return out
	var a := _corners[index]
	var b := _corners[(index + 1) % n]
	var step := Vector2i(signi(b.x - a.x), signi(b.y - a.y))
	var at := a
	while at != b:
		out.append(at)
		at += step
	out.append(b)
	return out

func _draw_problems() -> void:
	for c in compiled.problem_cells:
		var at := cell_to_screen(Vector2(c))
		draw_rect(Rect2(at, Vector2.ONE * _cell_px), COL_PROBLEM, false, 2.0)

func _draw_centreline() -> void:
	if _preview.size() < 2:
		return
	var pts := PackedVector2Array()
	for p in _preview:
		pts.append(cell_to_screen(p))
	draw_polyline_colors(pts, _preview_cols, maxf(2.0, _cell_px * 0.12))

## A dot on every corner. These are the grab points, so they are drawn last and
## brightest — if the player only notices one thing on the canvas, it should be
## that the corners are handles.
func _draw_handles() -> void:
	if _corners.is_empty() or _cell_px < 11.0:
		return
	var r := clampf(_cell_px * 0.24, 4.0, 9.0)
	for i in _corners.size():
		var at := cell_to_screen(Vector2(_corners[i]) + Vector2(0.5, 0.5))
		var hot: bool = (
			(_hot == Hit.CORNER and _hot_index == i and _drag == Hit.NONE)
			or (_drag == Hit.CORNER and _drag_index == i)
		)
		draw_circle(at, r + 2.0, COL_BG)
		draw_circle(at, r, COL_HANDLE_HOT if hot else COL_HANDLE)

func _draw_badges() -> void:
	if _cell_px < 14.0:
		return
	for i in compiled.corners.size():
		var corner: TrackLayout.Bend = compiled.corners[i]
		_badge(
			_radius_badge_at(corner), str(corner.size), COL_TEXT,
			_hot == Hit.RADIUS and _hot_index == i
		)
	for i in compiled.runs.size():
		var run: TrackLayout.Run = compiled.runs[i]
		if run.cells.is_empty() or run.max_level <= 0:
			continue
		var hot: bool = _hot == Hit.CLIMB and _hot_index == i
		# A raised straight shows its height; a flat one that *could* be raised
		# shows a faint prompt, so the option is discoverable without a mode.
		if run.level > 0:
			_badge(_climb_badge_at(run), "+%d" % run.level, COL_HIGH, hot)
		elif hot:
			_badge(_climb_badge_at(run), "+", COL_TEXT, true)
		else:
			var at := cell_to_screen(_climb_badge_at(run))
			draw_circle(at, maxf(2.0, _cell_px * 0.09), COL_TEXT * Color(1, 1, 1, 0.35))

func _badge(cell: Vector2, text: String, col: Color, hot: bool) -> void:
	var font := ThemeDB.fallback_font
	var pt := int(clampf(_cell_px * 0.46, 10.0, 15.0))
	var at := cell_to_screen(cell)
	var r := maxf(_cell_px * 0.42, 9.0)
	draw_circle(at, r, COL_HANDLE_HOT if hot else COL_BADGE)
	draw_circle(at, r, COL_TEXT * Color(1, 1, 1, 0.5), false, 1.0)
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, pt).x
	draw_string(
		font, at + Vector2(-w * 0.5, pt * 0.36), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, pt, COL_BG if hot else col
	)

## A bar across the road at the start line, plus an arrow for which way the lap
## runs — a painted loop has no inherent direction.
func _draw_start() -> void:
	if compiled.corners.is_empty():
		return
	var cell: Vector2i = compiled.start_marker
	var dir := Vector2(compiled.corners[0].in_dir)
	var across := Vector2(-dir.y, dir.x)

	var centre := cell_to_screen(Vector2(cell) + Vector2(0.5, 0.5))
	var half := across * _cell_px * 0.5
	var hot: bool = _hot == Hit.START or _drag == Hit.START
	var col := COL_HANDLE_HOT if hot else COL_START
	draw_line(centre - half, centre + half, col, maxf(2.0, _cell_px * 0.16))

	var tip := centre + dir * _cell_px * 0.9
	draw_line(centre, tip, col, maxf(1.5, _cell_px * 0.08))
	draw_line(tip, tip - dir * _cell_px * 0.3 + across * _cell_px * 0.2, col, 1.5)
	draw_line(tip, tip - dir * _cell_px * 0.3 - across * _cell_px * 0.2, col, 1.5)

func _draw_hover() -> void:
	if not _has_hover or _drag != Hit.NONE:
		return
	# Only highlight a bare cell when there is nothing more specific under the
	# cursor; otherwise the handle or badge is the thing being pointed at.
	if _hot != Hit.NONE:
		return
	draw_rect(
		Rect2(cell_to_screen(Vector2(_hover_cell)), Vector2.ONE * _cell_px),
		Color(1, 1, 1, 0.10)
	)
