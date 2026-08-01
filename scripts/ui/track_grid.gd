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
## Drawing is still a first-class tool, not an afterthought: `draw_mode` gives it
## the whole canvas, with the handles hidden so a stroke cannot be mistaken for a
## drag. Shift is a temporary override for a quick fix without leaving shaping.
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
signal bank_clicked(cell: Vector2i)
signal elevation_clicked(cell: Vector2i)
signal start_clicked(cell: Vector2i)
signal status(text: String)

const MIN_ZOOM := 8.0
const MAX_ZOOM := 48.0
const BASE_CELL := 22.0

## How close, in cells, the cursor has to be to grab a handle or hit a badge.
const GRAB := 0.75

## The same thing for a fingertip, in canvas units, because a finger is a fixed
## size on the glass while a cell is whatever the zoom says.
##
## The cap is the binding constraint, not the floor. A fingertip wants about 80
## canvas units of target on a phone, but the radius and bank badges sit only 1.2
## cells apart, so anything past about one cell stops being a wider target and
## starts being a coin toss between two neighbours. One cell is as far as this can
## go; getting closer than that is what pinching in is for, which touch can now
## do. Overlap at exactly the cap is settled the way it always was, by the order
## `_hit_test` asks its questions in.
const TOUCH_GRAB := 44.0
const TOUCH_GRAB_MAX_CELLS := 1.0

## Trackpad two-finger scroll, in screen pixels per unit of gesture delta. The
## gesture arrives in scroll units rather than pixels, so it needs scaling to feel
## like it is dragging the canvas.
const PAN_GESTURE_SPEED := 14.0

## The canvas paints itself rather than using widgets, so it cannot pick up the
## project theme — but it must not look like a different program either. Anything
## with a counterpart in `UiTheme` takes it from there, and what is left is
## specific to drawing a track: road fill, the two hover states, the start line.
const COL_BG := UiTheme.BG
const COL_GRID := UiTheme.LINE
const COL_ROAD := Color(0.29, 0.31, 0.35)
const COL_ROAD_HOT := Color(0.38, 0.41, 0.47)
const COL_LINE := UiTheme.GREEN
const COL_HIGH := UiTheme.ACCENT
## Distinct from the climb badge's amber, so a glance tells leaning apart from
## climbing without reading either number.
const COL_BANK := Color(0.45, 0.78, 0.95)
const COL_PROBLEM := UiTheme.DANGER
const COL_START := Color(0.95, 0.95, 0.98)
const COL_TEXT := UiTheme.TEXT
const COL_HANDLE := UiTheme.GREEN
const COL_HANDLE_HOT := Color(1.0, 1.0, 1.0)
const COL_BADGE := UiTheme.SURFACE_HI
const COL_REFUSED := UiTheme.DANGER

enum Hit { NONE, CORNER, EDGE, RADIUS, BANK, CLIMB, CORNER_CLIMB, START }

var layout: TrackLayout
var compiled: TrackLayout.Compiled

## When set, the canvas is a drawing surface: left-drag lays road, right-drag
## erases, and no handles are shown or hit-tested.
var draw_mode := false

## Everything a right button does, reachable without one. A touchscreen has no
## second button, which left erasing a stroke and removing a corner with no route
## in at all — the two destructive edits, and the only two the canvas had put
## behind a modifier rather than behind something to hit.
##
## This is the mode the canvas has otherwise avoided, and it is worth it only
## because it is *destructive*: a mode you can see you are in is the cheap way to
## stop a stray thumb rubbing out a circuit. The handles stay visible and still
## take taps, so a corner can be removed by tapping the same dot that moves it.
var erase_mode := false

var _cell_px := BASE_CELL
var _origin := Vector2.ZERO
## Canvas size at the last resize, so the next one knows what changed.
var _last_size := Vector2.ZERO
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
## Corner count when the drag began; the drag may not go below it.
var _drag_floor := 0
## The bend, put aside while the road is being shown straight.
##
## Straightening is applied **live**, so the canvas shows what letting go will
## give you — holding the bend in place and only straightening on release meant
## the drawing disagreed with the outcome, and the player had to know the rule
## rather than see it. Dragging back out of the flat band puts this straight
## back, so nothing is lost by passing through.
##
## Empty whenever the road being shown is the real one.
var _flatten_saved: Array[Vector2i] = []
var _flatten_saved_index := -1
## Whether the drag has actually changed anything yet. A press that grabs a
## handle and lets go without moving is not an edit, and recording one leaves an
## undo entry that undoes nothing — which matters now that a two-finger gesture
## can interrupt a drag that never got going.
var _drag_moved := false

## Fingers currently on the canvas, by touch index, in this control's own
## coordinates. Only fingers that landed on the canvas are tracked, so a thumb
## resting on the panel cannot join a gesture.
var _touches: Dictionary[int, Vector2] = {}
## Midpoint and span of the two-finger gesture at the last event, which is what
## the next one is measured against.
var _gesture_centre := Vector2.ZERO
var _gesture_span := 0.0
## True while two or more fingers are down. The emulated mouse keeps following
## the first of them, so without this the pinch would also be dragging a corner.
var _gesture := false
## Set once a touch has been seen and never cleared: it only widens hit targets,
## and a device that has produced one touch will produce more.
var _touch_seen := false

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
	_last_size = size
	resized.connect(_on_resized)

## `_origin` and `_cell_px` are only meaningful against a given canvas size, so a
## resize nobody accounts for leaves the circuit wherever the old numbers put it.
## Rotating a phone more than halves the canvas width, and the track lands off
## screen with no way back except the F key this editor cannot offer a phone.
##
## An ordinary resize — a dragged window edge — keeps whatever was in the middle
## in the middle, because the player's zoom and pan are deliberate and worth
## preserving. A change of orientation refits instead: the shape of the space has
## changed too much for the old framing to mean anything, and refitting is what
## the player would reach for next anyway.
func _on_resized() -> void:
	var previous := _last_size
	_last_size = size
	if previous.x <= 0.0 or previous.y <= 0.0:
		return
	if (previous.x >= previous.y) != (size.x >= size.y):
		fit_view()
		return
	_origin += (size - previous) * 0.5
	queue_redraw()

## Called by the editor after every recompile.
func refresh(new_compiled: TrackLayout.Compiled) -> void:
	compiled = new_compiled
	_corners = TrackShape.corners_of(layout.cells, layout.allow_crossings)
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
	var grab := _grab_radius()
	if draw_mode or _corners.is_empty():
		return [Hit.NONE, -1]

	# `has_structure`, not `ok`: a circuit refused for a crossing with no
	# headroom is fixed by pressing the elevation badge on one of these very
	# runs, so gating them on validity hid the fix behind the problem.
	if compiled != null and compiled.has_structure():
		for i in compiled.corners.size():
			var corner: TrackLayout.Bend = compiled.corners[i]
			if at.distance_to(_radius_badge_at(corner)) < grab:
				return [Hit.RADIUS, i]
		for i in compiled.corners.size():
			var corner: TrackLayout.Bend = compiled.corners[i]
			if at.distance_to(_bank_badge_at(corner)) < grab:
				return [Hit.BANK, i]
		for i in compiled.runs.size():
			var run: TrackLayout.Run = compiled.runs[i]
			if run.cells.is_empty() or run.max_level <= 0:
				continue
			if at.distance_to(_climb_badge_at(run)) < grab:
				return [Hit.CLIMB, i]
		for i in compiled.corners.size():
			var corner: TrackLayout.Bend = compiled.corners[i]
			if corner.max_level <= 0 and corner.level <= 0:
				continue
			if at.distance_to(_corner_climb_badge_at(corner)) < grab:
				return [Hit.CORNER_CLIMB, i]
		if at.distance_to(Vector2(compiled.start_marker) + Vector2(0.5, 0.5)) < grab:
			return [Hit.START, 0]

	for i in _corners.size():
		if at.distance_to(Vector2(_corners[i]) + Vector2(0.5, 0.5)) < grab:
			return [Hit.CORNER, i]

	var edge := TrackShape.edge_at(_corners, screen_to_cell(pos))
	if edge >= 0:
		return [Hit.EDGE, edge]
	return [Hit.NONE, -1]

## A cursor is a point and a fingertip is not, so touch needs a wider net — but
## measured on the glass, not in cells, because a cell is whatever the zoom says
## and a finger is always the same size. See [constant TOUCH_GRAB].
func _grab_radius() -> float:
	if not _touch_seen:
		return GRAB
	return clampf(TOUCH_GRAB / _cell_px, GRAB, TOUCH_GRAB_MAX_CELLS)

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

## The bank badge sits directly beyond the radius badge, on the same ray out of
## the corner. Radius and bank are both answers to "what shape is this bend", so
## they read as a pair, and putting the second one further out rather than beside
## it keeps them apart on a tight circuit where two corners are close together.
func _bank_badge_at(corner: TrackLayout.Bend) -> Vector2:
	var at := Vector2(corner.cell) + Vector2(0.5, 0.5)
	var away := (Vector2(corner.in_dir) - Vector2(corner.out_dir)).normalized()
	if away.dot(at - _centre) < 0.0:
		away = -away
	return at + away * 2.9

## A corner's climb badge sits inside the loop, opposite its radius badge, so the
## two never collide and which is which is obvious from the side it is on.
func _corner_climb_badge_at(corner: TrackLayout.Bend) -> Vector2:
	var at := Vector2(corner.cell) + Vector2(0.5, 0.5)
	var away := (Vector2(corner.in_dir) - Vector2(corner.out_dir)).normalized()
	if away.dot(at - _centre) < 0.0:
		away = -away
	return at - away * 1.7

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

## Raw touch is read here rather than in `_gui_input` for the same reason
## `touch_controls.gd` does it: `emulate_mouse_from_touch` collapses every finger
## onto one pointer, and pan and pinch need two. The pads proved this path works
## on a device, so the editor uses it too rather than a second, untried one.
##
## One finger is deliberately *not* handled here. Emulation already turns it into
## exactly the left-button drag the canvas has always understood, so drawing,
## dragging a corner and tapping a badge all work on a phone without this script
## knowing. Only the part emulation cannot express is taken over.
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		_touch_seen = true
		if touch.pressed:
			var at := _to_local(touch.position)
			if Rect2(Vector2.ZERO, size).has_point(at):
				_touches[touch.index] = at
		else:
			_touches.erase(touch.index)
		_sync_gesture()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if not _touches.has(drag.index):
			return
		_touches[drag.index] = _to_local(drag.position)
		if _gesture:
			_track_gesture()

## Touch positions arrive in viewport space; everything here is in the control's
## own space. They coincide only while every transform between the two is
## identity, which is not a thing to rely on from a script that also has to work
## inside a scaled canvas.
func _to_local(pos: Vector2) -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * pos

## Starts and ends the two-finger gesture as fingers arrive and leave, and rebases
## it whenever the pair changes so that lifting one of three fingers does not
## teleport the view.
func _sync_gesture() -> void:
	var want: bool = _touches.size() >= 2
	if want and not _gesture:
		# The first finger has been dragging a corner or laying road through the
		# emulated mouse this whole time. Close that edit off properly rather than
		# leaving it half-applied — undo can take it back, and `_drag_moved` means
		# a pinch that merely started on a handle records nothing.
		_end_drag()
	_gesture = want
	if _gesture:
		_rebase_gesture()
	else:
		_gesture_span = 0.0

func _rebase_gesture() -> void:
	var points: Array = _touches.values()
	_gesture_centre = (points[0] + points[1]) * 0.5
	_gesture_span = maxf(points[0].distance_to(points[1]), 1.0)

## Pan by how far the pair moved together, zoom by how much it spread. Doing both
## from one gesture is what makes it feel like the canvas is being handled rather
## than driven: the point between the fingers stays under them throughout.
func _track_gesture() -> void:
	var points: Array = _touches.values()
	var centre: Vector2 = (points[0] + points[1]) * 0.5
	var span: float = maxf(points[0].distance_to(points[1]), 1.0)
	_pan(centre - _gesture_centre)
	_zoom_about(centre, span / _gesture_span)
	_gesture_centre = centre
	_gesture_span = span

func _gui_input(event: InputEvent) -> void:
	# While two fingers are down the emulated mouse is still following the first
	# of them, and every event it sends would be read as a drag on the circuit.
	if _gesture and (event is InputEventMouse):
		return
	if event is InputEventMouseButton:
		_button(event)
	elif event is InputEventMouseMotion:
		_motion(event)
	elif event is InputEventPanGesture:
		# Two-finger scroll on a trackpad. macOS sends this rather than wheel
		# events, and a trackpad has no middle button to pan with at all.
		_pan(-(event as InputEventPanGesture).delta * PAN_GESTURE_SPEED)
	elif event is InputEventMagnifyGesture:
		# Pinch. `factor` is relative, so it composes with itself frame to frame.
		var pinch := event as InputEventMagnifyGesture
		_zoom_about(pinch.position, pinch.factor)

func _pan(by: Vector2) -> void:
	_origin += by
	queue_redraw()

## Zooms while keeping whatever is under `at` under `at`, which is what makes both
## the wheel and a pinch feel like they are working on the thing being pointed at.
func _zoom_about(at: Vector2, factor: float) -> void:
	var before := screen_to_cell_f(at)
	_cell_px = clampf(_cell_px * factor, MIN_ZOOM, MAX_ZOOM)
	_origin = at - before * _cell_px
	queue_redraw()

func _button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not event.pressed:
			return
		# A real wheel notch is a fixed step; high-resolution devices report a
		# smaller `factor` per event and would otherwise zoom absurdly fast.
		var notch: float = 1.0 + 0.12 * (event.factor if event.factor > 0.0 else 1.0)
		var step := notch if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / notch
		_zoom_about(event.position, step)
		return

	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed
		return

	if not event.pressed:
		_panning = false
		_end_drag()
		return

	grab_focus()
	var cell := screen_to_cell(event.position)

	# Cmd or ctrl and drag pans, so a trackpad without a middle button still has a
	# keyboard-and-one-finger way to move the view.
	if event.is_command_or_control_pressed():
		_panning = true
		return

	var hit := _hit_test(event.position)
	var kind: int = hit[0]
	var index: int = hit[1]

	# Erase is checked before drawing and before the handles, because it is the
	# one mode whose whole point is that it overrides what is under the pointer.
	# A corner still wins over the road it sits on, so the dot that moves a corner
	# with erase off is the dot that removes it with erase on — one target, and
	# the mode says which of the two it does.
	if erase_mode and event.button_index == MOUSE_BUTTON_LEFT:
		if kind == Hit.CORNER:
			_straighten(index)
			return
		_begin_stroke(-1, cell)
		return

	# Shift is a temporary override, so a stroke can be laid without leaving
	# shaping mode.
	if draw_mode or event.shift_pressed:
		_begin_stroke(-1 if event.button_index == MOUSE_BUTTON_RIGHT else 1, cell)
		return

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
		Hit.BANK:
			bank_clicked.emit(compiled.corners[index].cell)
		Hit.CLIMB:
			elevation_clicked.emit(_climb_cell(index))
		Hit.CORNER_CLIMB:
			elevation_clicked.emit(compiled.corners[index].cell)
		Hit.START:
			status.emit("Drag the flag along the road to move the start line.")
			_drag = Hit.START
			_drag_index = 0
		Hit.CORNER, Hit.EDGE:
			_drag = kind
			_drag_index = index
			_drag_floor = _corners.size()
			_drag_moved = false
		_:
			status.emit(
				"Grab a corner or a straight to reshape the circuit."
				if has_handles() else
				"Turn Draw on to lay road."
			)

func _begin_stroke(direction: int, cell: Vector2i) -> void:
	_stroke = direction
	_last_painted = cell
	_has_last_painted = true
	_painted_any = false
	_paint(cell)

func _climb_cell(run_index: int) -> Vector2i:
	var run: TrackLayout.Run = compiled.runs[run_index]
	return run.cells[run.cells.size() / 2]

func _motion(event: InputEventMouseMotion) -> void:
	if _panning:
		_pan(event.relative)
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
		Hit.RADIUS, Hit.BANK, Hit.CLIMB, Hit.CORNER_CLIMB:
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_:
			mouse_default_cursor_shape = Control.CURSOR_ARROW

# --- dragging the shape ---

func _apply_drag(cell: Vector2i) -> void:
	if _drag == Hit.START:
		if layout.cells.has(cell):
			layout.start_cell = cell
			_drag_moved = true
			layout_touched.emit()
		return

	# The shape as it really is. While the road is being shown straight, `_corners`
	# is the straightened version and this is the bend it is standing in for.
	var base: Array[Vector2i] = (
		_flatten_saved if not _flatten_saved.is_empty() else _corners
	)
	var base_index: int = (
		_flatten_saved_index if not _flatten_saved.is_empty() else _drag_index
	)

	# Dragged into line: show the road straight, and keep the bend in case the
	# drag carries on past.
	#
	# Two ways to arrive at that, and both have to work, because a section becomes
	# a bump by being dragged into one just as often as by being pushed out.
	#
	# 1. An edge pulled level with the road either side. This needs a *band*
	#    rather than the single cell on the line: a bend shallower than
	#    `MIN_EDGE` cannot be represented, so the cells either side of the line
	#    are ones `move_edge` refuses, and `_step_past_flat` then throws the bend
	#    to the far side — leaving the straighten a knife-edge between two flips.
	# 2. Any drag whose own result simply comes back with fewer corners, which is
	#    `prune` having found the road no longer turns there. That is how a
	#    *corner* dragged back into line reads, and it used to be refused outright
	#    with "the circuit would cross itself" — which was not true and named the
	#    wrong problem.
	var straightened: Array[Vector2i] = []
	if _drag == Hit.EDGE:
		var flat := _straighten_cell(base, base_index, cell)
		if flat != Vector2i.MAX:
			var pruned := TrackShape.move_edge(
				base, base_index, flat, layout.allow_crossings
			)
			if not pruned.is_empty() and pruned.size() < base.size():
				straightened = pruned

	var moved: Array[Vector2i] = (
		TrackShape.move_corner(base, base_index, cell, layout.allow_crossings)
		if _drag == Hit.CORNER
		else TrackShape.move_edge(base, base_index, cell, layout.allow_crossings)
	)
	if straightened.is_empty() and not moved.is_empty() and moved.size() < base.size():
		straightened = moved

	if not straightened.is_empty():
		if _flatten_saved.is_empty():
			_flatten_saved = base.duplicate()
			_flatten_saved_index = base_index
			status.emit("Straight — let go to keep it.")
		# Shown straight, right now. Nothing is committed until the button comes
		# up, and dragging back out puts the bend back.
		layout.cells = TrackShape.cells_from_corners(straightened)
		_corners = straightened
		_drag_moved = true
		layout_touched.emit()
		return

	# Not straight any more: put the bend back and carry on as an ordinary drag.
	if not _flatten_saved.is_empty():
		_corners = _flatten_saved
		_drag_index = _flatten_saved_index
		layout.cells = TrackShape.cells_from_corners(_corners)
		_flatten_saved = []
		_flatten_saved_index = -1

	# Dragging a bend from one side of its straight to the other has to pass
	# through the flat position, where the bend momentarily has no depth and gets
	# pruned away. Stopping there strands the drag at exactly the point the
	# player is trying to cross — the bend could only ever be pushed back to
	# flat, never through to the inside. So the flat position is stepped over,
	# in whichever direction the drag is already going.
	if _drag == Hit.EDGE and moved.size() < _drag_floor:
		var past := _step_past_flat(cell)
		if past != cell:
			moved = TrackShape.move_edge(_corners, _drag_index, past, layout.allow_crossings)
	# A drag reshapes; it never changes how many corners there are. Letting a
	# prune dissolve the handle mid-gesture would renumber the list under the
	# drag, and a new bend dragged back through flat would die on the way rather
	# than continuing out the other side. Corners are added by double-clicking
	# and removed by right-clicking, and only there.
	if moved.is_empty() or moved.size() < _drag_floor:
		# A bend crossing its own straight is refused for a cell or two either
		# side, because a bend shallower than MIN_EDGE cannot be represented.
		# That is a normal part of the gesture, so it stalls quietly — colouring
		# the road red mid-crossing reads as an error when nothing is wrong.
		# A corner dragged somewhere impossible does warn, because there the
		# player has genuinely asked for something that cannot be built.
		if _drag == Hit.CORNER and not _drag_refused:
			_drag_refused = true
			status.emit("Cannot go there — the circuit would cross itself.")
			queue_redraw()
		return

	_drag_refused = false
	layout.cells = TrackShape.cells_from_corners(moved)
	_corners = moved
	_drag_moved = true
	layout_touched.emit()

## Pushes a new bend out of a straight. Without this the handles could only move
## and remove corners, so a circuit could never gain one.
##
## The bend is created at the shallowest depth that fits and then handed straight
## to the drag, so it follows the mouse — out or in, whichever way the player
## moves. An earlier version picked outward for them, which meant the circuit
## could only ever grow.
func _insert_bend(index: int, cell: Vector2i) -> void:
	for depth in [TrackShape.MIN_EDGE, 3, 4]:
		for towards in [_outward_sign(index), -_outward_sign(index)]:
			var out := TrackShape.insert_bump(
				_corners, index, cell, depth * towards, layout.allow_crossings)
			if out.is_empty():
				continue
			layout.cells = TrackShape.cells_from_corners(out)
			_corners = out
			# The bump contributed four corners after `index`; the outer edge of
			# it is the middle pair, which is what the player wants to be holding.
			_drag = Hit.EDGE
			_drag_index = (index + 2) % _corners.size()
			_drag_floor = _corners.size()
			# The bend exists the moment it is inserted, so this is already an edit
			# even if the drag that follows never moves.
			_drag_moved = true
			status.emit("New bend — drag it in or out.")
			layout_touched.emit()
			return
	status.emit("No room for a bend here — try a longer straight.")

## Where this drag would flatten to, or `Vector2i.MAX` if it is not close enough
## to the road either side to count as straightening.
##
## The band is `MIN_EDGE` either way, which is exactly the range no bend can
## occupy: one cell deep is refused by `corners_valid`, so those cells were dead
## space that did nothing but bounce the bump across to the far side. Making the
## whole dead band mean "straighten" costs nothing and turns a knife-edge into
## something you can actually hit.
##
## Measured against the corners either side, not against how far the drag has
## travelled. `_step_past_flat` reads the direction of travel, which answers
## "which way is the player going" rather than "have they arrived".
func _straighten_cell(
	corners: Array[Vector2i], index: int, cell: Vector2i
) -> Vector2i:
	var n := corners.size()
	if n < 4 or index < 0:
		return Vector2i.MAX
	var a := corners[index]
	var b := corners[(index + 1) % n]
	var prev := corners[(index - 1 + n) % n]
	var next := corners[(index + 2) % n]
	if a.y == b.y:
		if prev.y != next.y or absi(cell.y - prev.y) >= TrackShape.MIN_EDGE:
			return Vector2i.MAX
		return Vector2i(cell.x, prev.y)
	if prev.x != next.x or absi(cell.x - prev.x) >= TrackShape.MIN_EDGE:
		return Vector2i.MAX
	return Vector2i(prev.x, cell.y)

## The target nudged one cell further along the direction of travel, so a bend
## being dragged across its own straight lands on the far side instead of on the
## line. Returns `cell` unchanged when there is no direction to infer.
func _step_past_flat(cell: Vector2i) -> Vector2i:
	var n := _corners.size()
	var a := _corners[_drag_index]
	var b := _corners[(_drag_index + 1) % n]
	if a.y == b.y:
		var step := signi(cell.y - a.y)
		return cell if step == 0 else cell + Vector2i(0, step)
	var step_x := signi(cell.x - a.x)
	return cell if step_x == 0 else cell + Vector2i(step_x, 0)

## Which way is away from the middle of the circuit, along the axis the given
## straight can move in. Only used to pick which side to *try* first.
func _outward_sign(index: int) -> int:
	var n := _corners.size()
	var a := _corners[index]
	var b := _corners[(index + 1) % n]
	var mid := (Vector2(a) + Vector2(b)) * 0.5
	var off: float = (mid.y - _centre.y) if a.y == b.y else (mid.x - _centre.x)
	return 1 if off >= 0.0 else -1

func _straighten(index: int) -> void:
	var out := TrackShape.straighten_at(_corners, index, layout.allow_crossings)
	if out.is_empty():
		status.emit("That corner cannot be removed — a circuit needs at least four.")
		return
	layout.cells = TrackShape.cells_from_corners(out)
	_corners = out
	layout_edited.emit()

func _end_drag() -> void:
	# Nothing to apply here: if the road is being shown straight it already *is*
	# straight, in `layout.cells` and in `_corners` both. Letting go simply stops
	# the bend being available to put back.
	if not _flatten_saved.is_empty():
		status.emit("Straightened — drag the road out again to put a bend back.")

	# `_drag_moved`, not merely "a drag was in progress": grabbing a handle and
	# letting go without moving is not an edit, and recording one leaves an undo
	# entry that undoes nothing. A pinch beginning on a handle does exactly that.
	var changed: bool = _drag_moved
	_drag = Hit.NONE
	_drag_index = -1
	_drag_refused = false
	_drag_floor = 0
	_drag_moved = false
	_flatten_saved = []
	_flatten_saved_index = -1
	var painted := _painted_any
	_stroke = 0
	_has_last_painted = false
	_painted_any = false
	if changed or painted:
		layout_edited.emit()
	queue_redraw()

# --- free painting ---

## Fills in every cell between the last one and this one.
##
## Two things this has to get right, and the first version got neither:
##
## Without any fill, a drag paints only the cells the mouse happened to be
## sampled over. At any normal speed that skips most of them, leaving a dotted
## line the validator then correctly reports as full of holes — the paint tool
## read as broken because it was.
##
## And the fill has to move one axis at a time, which is why it defers to
## `TrackShape.orthogonal_path` — see there for why a diagonal fill breaks the
## road.
func _paint_to(cell: Vector2i) -> void:
	if not _has_last_painted:
		_paint(cell)
		_last_painted = cell
		_has_last_painted = true
		return

	for step in TrackShape.orthogonal_path(_last_painted, cell):
		_paint(step)
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
	if compiled == null or not compiled.has_structure():
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
		if compiled.has_structure() and not draw_mode:
			_draw_badges()
			_draw_start()
	if not draw_mode:
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
		# Erase is the one destructive mode, so the road it would take says so
		# before anything is taken — fainter than a refused drag, which is an
		# error rather than a state.
		if erase_mode:
			col = col.lerp(COL_REFUSED, 0.20)
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
		_bank_badge(
			_bank_badge_at(corner), corner.bank,
			_hot == Hit.BANK and _hot_index == i
		)
	# Straights and corners both carry a height, so both get a badge — raising a
	# corner is what lets an elevated stretch carry on round the bend instead of
	# dropping back down for it.
	for i in compiled.runs.size():
		var run: TrackLayout.Run = compiled.runs[i]
		if run.cells.is_empty() or run.max_level <= 0:
			continue
		_climb_badge(
			_climb_badge_at(run), run.level,
			_hot == Hit.CLIMB and _hot_index == i
		)
	for i in compiled.corners.size():
		var corner: TrackLayout.Bend = compiled.corners[i]
		if corner.max_level <= 0 and corner.level <= 0:
			continue
		_climb_badge(
			_corner_climb_badge_at(corner), corner.level,
			_hot == Hit.CORNER_CLIMB and _hot_index == i
		)

## A banked corner shows how hard it leans; a flat one shows a faint dot, so the
## option is there to be found without a mode or a tooltip — and so that "this
## corner is deliberately flat" is a state you can see rather than infer.
func _bank_badge(at: Vector2, level: int, hot: bool) -> void:
	if level > 0:
		_badge(at, str(level), COL_BANK, hot, true)
	elif hot:
		_badge(at, "", COL_TEXT, true, true)
	else:
		draw_circle(
			cell_to_screen(at), maxf(2.0, _cell_px * 0.09),
			COL_TEXT * Color(1, 1, 1, 0.35)
		)

## A raised segment shows its height; a flat one that *could* be raised shows a
## faint dot, so the option is discoverable without a mode or a tooltip.
func _climb_badge(at: Vector2, level: int, hot: bool) -> void:
	if level > 0:
		_badge(at, "+%d" % level, COL_HIGH, hot)
	elif hot:
		_badge(at, "+", COL_TEXT, true)
	else:
		draw_circle(
			cell_to_screen(at), maxf(2.0, _cell_px * 0.09),
			COL_TEXT * Color(1, 1, 1, 0.35)
		)

## `angle_mark` prefixes the label with a drawn angle sign, for the bank badges.
## See [method _draw_angle] for why it is drawn and not typed.
func _badge(cell: Vector2, text: String, col: Color, hot: bool,
		angle_mark: bool = false) -> void:
	var font := ThemeDB.fallback_font
	var pt := int(clampf(_cell_px * 0.46, 10.0, 15.0))
	var at := cell_to_screen(cell)
	var r := maxf(_cell_px * 0.42, 9.0)
	draw_circle(at, r, COL_HANDLE_HOT if hot else COL_BADGE)
	draw_circle(at, r, COL_TEXT * Color(1, 1, 1, 0.5), false, 1.0)
	var ink := COL_BG if hot else col

	# Mark, gap and label measured together and then centred as one, so a badge
	# carrying both still reads as centred in its disc.
	var mark := pt * 0.60 if angle_mark else 0.0
	var gap := pt * 0.18 if angle_mark and not text.is_empty() else 0.0
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, pt).x
	var left := at.x - (mark + gap + w) * 0.5
	if angle_mark:
		_draw_angle(Vector2(left + mark * 0.5, at.y), mark, ink)
	draw_string(
		font, Vector2(left + mark + gap, at.y + pt * 0.36), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, pt, ink
	)

## The angle sign on a bank badge, as two lines rather than the character U+2220.
##
## Godot's built-in font does not contain that glyph. On desktop nothing showed,
## because the OS font provider quietly supplied it from a system font; the web
## export has no system fonts to fall back on, so every bank badge on GitHub
## Pages rendered as a tofu box reading "2220" — its own codepoint. Two lines are
## cheaper than shipping a font for one glyph, and this canvas draws everything
## else by hand anyway. Anything else typed here has to stay inside the built-in
## font; `tests/run_tests.gd` checks that it does.
func _draw_angle(at: Vector2, size: float, col: Color) -> void:
	var half := size * 0.5
	var vertex := at + Vector2(-half, half)
	var width := maxf(1.0, size * 0.11)
	draw_line(vertex, at + Vector2(half, half), col, width, true)
	draw_line(vertex, at + Vector2(half, -half), col, width, true)

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
	# cursor; otherwise the handle or badge is the thing being pointed at. While
	# drawing there is nothing else, and the square is the brush tip.
	if _hot != Hit.NONE and not draw_mode:
		return
	draw_rect(
		Rect2(cell_to_screen(Vector2(_hover_cell)), Vector2.ONE * _cell_px),
		Color(1, 1, 1, 0.10)
	)
