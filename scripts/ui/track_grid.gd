class_name TrackGrid
extends Control

## The editor's canvas: paints cells, and draws the circuit those cells compile
## to on top of them.
##
## Drawing both matters. A painted bend is a right angle, but the corner tile
## that takes it is an arc that starts turning up to two cells early and bulges
## across the inside of the bend. Showing only the cells would misrepresent the
## track by around 25 m at the widest corner, so the compiled centreline is
## overlaid — coloured by height — and it is the overlay, not the cells, that
## tells the player what they are going to drive.

signal layout_edited
signal cell_activated(cell: Vector2i)

enum Mode { PAINT, START, CORNER, ELEVATION }

const MIN_ZOOM := 8.0
const MAX_ZOOM := 48.0
const BASE_CELL := 22.0

const COL_BG := Color(0.10, 0.11, 0.13)
const COL_GRID := Color(0.16, 0.18, 0.21)
const COL_ROAD := Color(0.29, 0.31, 0.35)
const COL_LINE := Color(0.55, 0.80, 0.45)
const COL_HIGH := Color(0.95, 0.72, 0.30)
const COL_PROBLEM := Color(0.85, 0.30, 0.30)
const COL_START := Color(0.95, 0.95, 0.98)
const COL_TEXT := Color(0.85, 0.87, 0.90)
const COL_HOVER := Color(1.0, 1.0, 1.0, 0.14)

var layout: TrackLayout
var compiled: TrackLayout.Compiled
var mode: int = Mode.PAINT

var _cell_px := BASE_CELL
var _origin := Vector2.ZERO
var _hover := Vector2i.ZERO
var _has_hover := false
## +1 while painting, -1 while erasing, 0 otherwise. Held across motion events so
## a drag keeps doing what the press started, rather than toggling per cell.
var _stroke := 0
var _panning := false

func _ready() -> void:
	focus_mode = Control.FOCUS_ALL

# --- view ---

func cell_to_screen(cell: Vector2) -> Vector2:
	return _origin + cell * _cell_px

func screen_to_cell(pos: Vector2) -> Vector2i:
	var v := (pos - _origin) / _cell_px
	return Vector2i(floori(v.x), floori(v.y))

## Frames the painted circuit, or a blank patch of grid if there is not one yet.
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

	var span := hi - lo
	var margin := 48.0
	_cell_px = clampf(
		minf((size.x - margin) / maxf(span.x, 1.0), (size.y - margin) / maxf(span.y, 1.0)),
		MIN_ZOOM, MAX_ZOOM
	)
	_origin = size * 0.5 - (lo + span * 0.5) * _cell_px
	queue_redraw()

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
		var before := (event.position - _origin) / _cell_px
		_cell_px = clampf(_cell_px * step, MIN_ZOOM, MAX_ZOOM)
		# Keep whatever was under the cursor under the cursor.
		_origin = event.position - before * _cell_px
		queue_redraw()
		return

	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed
		return

	if not event.pressed:
		_stroke = 0
		return

	grab_focus()
	var cell := screen_to_cell(event.position)
	var erasing := event.button_index == MOUSE_BUTTON_RIGHT

	if mode == Mode.PAINT or erasing:
		_stroke = -1 if erasing else 1
		_apply_stroke(cell)
	elif event.button_index == MOUSE_BUTTON_LEFT:
		cell_activated.emit(cell)

func _motion(event: InputEventMouseMotion) -> void:
	if _panning:
		_origin += event.relative
		queue_redraw()
		return

	var cell := screen_to_cell(event.position)
	if not _has_hover or cell != _hover:
		_hover = cell
		_has_hover = true
		queue_redraw()
	if _stroke != 0:
		_apply_stroke(cell)

func _apply_stroke(cell: Vector2i) -> void:
	var had := layout.cells.has(cell)
	if _stroke > 0 and not had:
		layout.cells.append(cell)
	elif _stroke < 0 and had:
		layout.cells.erase(cell)
	else:
		return
	layout_edited.emit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_has_hover = false
		_stroke = 0
		queue_redraw()

# --- drawing ---

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COL_BG)
	_draw_grid()
	if layout == null:
		return
	_draw_cells()
	if compiled != null:
		_draw_problems()
		_draw_centreline()
		_draw_corner_labels()
		_draw_start()
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
	for c in layout.cells:
		var at := cell_to_screen(Vector2(c)) + Vector2(inset, inset)
		draw_rect(Rect2(at, Vector2.ONE * (_cell_px - inset * 2.0)), COL_ROAD)

func _draw_problems() -> void:
	for c in compiled.problem_cells:
		var at := cell_to_screen(Vector2(c))
		draw_rect(Rect2(at, Vector2.ONE * _cell_px), COL_PROBLEM, false, 2.0)

## The compiled centreline, pushed back into grid space and coloured by height so
## a climb is visible without a separate elevation view.
func _draw_centreline() -> void:
	if compiled.segments.is_empty():
		return
	var builder := TrackBuilder.new()
	var result := builder.measure(compiled.segments)
	if builder.centreline.size() < 2:
		return

	var points := PackedVector2Array()
	var colours := PackedColorArray()
	var peak := maxf(result.peak, 0.001)
	for p in builder.centreline:
		var grid: Vector2 = compiled.to_grid * (Vector2(p.x, p.z) / TrackBuilder.SCALE)
		points.append(cell_to_screen(grid))
		colours.append(COL_LINE.lerp(COL_HIGH, clampf(p.y / peak, 0.0, 1.0)))
	draw_polyline_colors(points, colours, maxf(2.0, _cell_px * 0.12))

func _draw_corner_labels() -> void:
	if _cell_px < 14.0:
		return
	var font := ThemeDB.fallback_font
	var pt := int(clampf(_cell_px * 0.5, 9.0, 16.0))
	for corner in compiled.corners:
		var at := cell_to_screen(Vector2(corner.cell)) + Vector2.ONE * _cell_px * 0.5
		draw_string(
			font, at + Vector2(-pt * 0.5, pt * 0.4), str(corner.size),
			HORIZONTAL_ALIGNMENT_LEFT, -1, pt, COL_TEXT
		)
	for run in compiled.runs:
		if run.level <= 0 or run.cells.is_empty():
			continue
		var mid: Vector2i = run.cells[run.cells.size() / 2]
		var at := cell_to_screen(Vector2(mid)) + Vector2.ONE * _cell_px * 0.5
		draw_string(
			font, at + Vector2(-pt * 0.6, pt * 0.4), "+%d" % run.level,
			HORIZONTAL_ALIGNMENT_LEFT, -1, pt, COL_HIGH
		)

## A bar across the road at the start line, plus an arrow showing which way the
## lap runs — the loop itself has no inherent direction.
func _draw_start() -> void:
	if compiled.runs.is_empty() or compiled.runs[0].cells.is_empty():
		return
	var run: TrackLayout.Run = compiled.runs[0]
	var cell: Vector2i = run.cells[0]
	var dir := Vector2(compiled.corners[0].in_dir)
	var across := Vector2(-dir.y, dir.x)

	var centre := cell_to_screen(Vector2(cell) + Vector2(0.5, 0.5))
	var half := across * _cell_px * 0.5
	draw_line(centre - half, centre + half, COL_START, maxf(2.0, _cell_px * 0.14))

	var tip := centre + dir * _cell_px * 0.9
	draw_line(centre, tip, COL_START, maxf(1.5, _cell_px * 0.08))
	draw_line(tip, tip - dir * _cell_px * 0.3 + across * _cell_px * 0.2, COL_START, 1.5)
	draw_line(tip, tip - dir * _cell_px * 0.3 - across * _cell_px * 0.2, COL_START, 1.5)

func _draw_hover() -> void:
	if not _has_hover:
		return
	draw_rect(Rect2(cell_to_screen(Vector2(_hover)), Vector2.ONE * _cell_px), COL_HOVER)
