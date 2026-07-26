extends Control

## The track editor.
##
## The circuit is edited by dragging the road itself — see `track_grid.gd` for
## why there are no tool modes. This script owns everything around the canvas:
## what the panel says, the undo stack, and saving.
##
## Nothing reaches disk until Save, except that Test drive saves first: the race
## scene builds a custom track from the stored layout, so an unsaved edit has
## nothing to build from.

const TITLE_SCENE := "res://scenes/title.tscn"
const RACE_SCENE := "res://scenes/race.tscn"
const EDITOR_SCENE := "res://scenes/editor/track_editor.tscn"

## Deep enough to undo a whole misjudged reshaping, small enough that the
## snapshots (a few hundred cells each) stay trivial.
const UNDO_LIMIT := 64

@onready var _grid: TrackGrid = $Split/Grid
@onready var _name_edit: LineEdit = $Split/Side/Rows/NameEdit
@onready var _picker: OptionButton = $Split/Side/Rows/Picker
@onready var _draw_button: Button = $Split/Side/Rows/DrawButton
@onready var _guide: Label = $Split/Side/Rows/GuideCard/Rows/Guide
@onready var _status: Label = $Split/Side/Rows/Status
@onready var _readout: Label = $Split/Side/Rows/ReadoutCard/Rows/Readout
@onready var _legend_toggle: Button = $Split/Side/Rows/LegendToggle
@onready var _legend: PanelContainer = $LegendFlyout
@onready var _close_button: Button = $Split/Side/Rows/Actions/CloseButton
@onready var _undo_button: Button = $Split/Side/Rows/Actions/UndoRow/UndoButton
@onready var _save_button: Button = $Split/Side/Rows/Actions/UndoRow/SaveButton
@onready var _test_button: Button = $Split/Side/Rows/Actions/TestButton
@onready var _delete_button: Button = $Split/Side/Rows/Actions/ExitRow/DeleteButton
@onready var _back_button: Button = $Split/Side/Rows/Actions/ExitRow/BackButton

var _layout: TrackLayout
var _compiled: TrackLayout.Compiled
var _undo: Array[Dictionary] = []
var _transient_status := ""

func _ready() -> void:
	ViewportScaling.attach(get_window())
	# Esc out of a test drive comes back here, not to the menu, so the circuit
	# being worked on stays on screen.
	GameState.return_scene = EDITOR_SCENE

	_layout = (
		TrackStore.load_layout(GameState.editing_id)
		if not GameState.editing_id.is_empty() else null
	)
	if _layout == null:
		_layout = _starter_layout()

	_grid.layout = _layout
	_grid.layout_edited.connect(_on_edited)
	_grid.layout_touched.connect(_on_touched)
	_grid.corner_clicked.connect(_cycle_corner)
	_grid.bank_clicked.connect(_cycle_bank)
	_grid.elevation_clicked.connect(_cycle_elevation)
	_grid.status.connect(_flash)

	_draw_button.toggled.connect(_set_draw_mode)
	_legend_toggle.toggled.connect(_show_legend)
	_close_button.pressed.connect(_close_gap)
	_name_edit.text_changed.connect(func(t): _layout.display_name = t)
	_picker.item_selected.connect(_on_picked)
	_undo_button.pressed.connect(_undo_last)
	_save_button.pressed.connect(_on_save)
	_test_button.pressed.connect(_on_test)
	_delete_button.pressed.connect(_on_delete)
	_back_button.pressed.connect(func(): get_tree().change_scene_to_file(TITLE_SCENE))

	_name_edit.text = _layout.display_name
	_refresh_picker()
	_reset_undo()
	_recompile()
	# The canvas has no size until the containers have laid out once.
	await get_tree().process_frame
	_grid.fit_view()

## A new track opens as a driveable rectangle rather than a blank grid. An empty
## canvas gives no clue that the cells have to form one closed loop, and the
## first thing anyone wants is to drive something and then change it.
func _starter_layout() -> TrackLayout:
	var layout := TrackLayout.new()
	layout.display_name = "New Circuit"
	var w := 18
	var h := 12
	for x in w:
		layout.cells.append(Vector2i(x, 0))
	for y in range(1, h):
		layout.cells.append(Vector2i(w - 1, y))
	for x in range(w - 2, -1, -1):
		layout.cells.append(Vector2i(x, h - 1))
	for y in range(h - 2, 0, -1):
		layout.cells.append(Vector2i(0, y))
	layout.start_cell = Vector2i(w / 2, 0)
	return layout

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_tree().change_scene_to_file(TITLE_SCENE)
		return
	if not (event is InputEventKey and event.pressed):
		return
	var key_event := event as InputEventKey
	if key_event.keycode == KEY_F:
		_grid.fit_view()
	elif key_event.keycode == KEY_D:
		_draw_button.button_pressed = not _draw_button.button_pressed
	elif key_event.keycode == KEY_Z and key_event.ctrl_pressed:
		_undo_last()
	elif key_event.keycode == KEY_S and key_event.ctrl_pressed:
		_on_save()

## The legend is reference, not a control, so it folds away — and it opens over
## the canvas, because the panel column is 720 units tall on every window and
## never has room for it.
func _show_legend(on: bool) -> void:
	_legend.visible = on

## Drawing and shaping are the two ways to build a circuit, and which one is
## active has to be unmistakable — the canvas hides its handles while drawing, so
## a stroke can never be mistaken for a drag.
func _set_draw_mode(on: bool) -> void:
	_grid.draw_mode = on
	_grid.queue_redraw()
	_flash(
		"Drawing: drag to lay road, right-drag to erase."
		if on else "Shaping: drag corners and straights."
	)
	_update_panel()

## Joins up a half-drawn loop. This is the fiddliest part of drawing a circuit by
## hand, and it is entirely mechanical, so the editor should just do it.
func _close_gap() -> void:
	var added := TrackShape.close_gap(_layout.cells)
	if added.is_empty():
		_flash("Cannot join those ends up — try drawing them closer together.")
		_update_panel()
		return
	_layout.cells.append_array(added)
	_flash("Joined the ends up with %d cells." % added.size())
	_on_edited()
	_grid.fit_view()

# --- editing ---

## A live change mid-drag: recompile so the readout and the preview keep up, but
## do not record it — one drag is one undo step, not sixty.
func _on_touched() -> void:
	_recompile()

func _on_edited() -> void:
	_push_undo()
	_recompile()

## Seeds the stack with the state the player is looking at. Without this entry
## the first edit is unundoable — there is nothing recorded to go back *to*.
func _reset_undo() -> void:
	_undo.clear()
	_undo.append(_layout.to_dict())
	_undo_button.disabled = true

func _push_undo() -> void:
	_undo.append(_layout.to_dict())
	if _undo.size() > UNDO_LIMIT:
		_undo.remove_at(0)
	_undo_button.disabled = _undo.size() < 2

## The stack holds the state *after* each edit, so undoing means dropping the
## current state and restoring the one before it.
func _undo_last() -> void:
	if _undo.size() < 2:
		_flash("Nothing left to undo.")
		return
	_undo.pop_back()
	var restored := TrackLayout.from_dict(_undo[_undo.size() - 1])
	restored.id = _layout.id
	_layout = restored
	_grid.layout = _layout
	_name_edit.text = _layout.display_name
	_undo_button.disabled = _undo.size() < 2
	_recompile()

func _recompile() -> void:
	_compiled = _layout.compile()
	_grid.refresh(_compiled)
	_update_panel()

func _flash(text: String) -> void:
	_transient_status = text
	_status.text = text

## Steps a corner down through the tiles that fit and wraps back to the widest,
## so one control covers the whole choice.
func _cycle_corner(cell: Vector2i) -> void:
	for corner in _compiled.corners:
		if corner.cell != cell:
			continue
		if corner.max_size <= 1:
			_flash("This corner cannot be widened — its straights are too short.")
			return
		var next := corner.size - 1
		if next < 1:
			next = corner.max_size
		_layout.corner_sizes[cell] = next
		_flash("Corner set to %s." % _corner_word(next))
		_on_edited()
		return

func _corner_word(size: int) -> String:
	return ["", "tight", "medium", "sweeping"][clampi(size, 0, 3)]

## Steps a corner's banking up and wraps back round to flat.
##
## Wrapping through zero rather than stopping at it is what makes a flat corner
## reachable in one obvious way: banking is a choice, and "no banking" has to be
## as easy to ask for as any other setting. Nothing here can fail, so unlike
## radius and height there is no case where the click has to be refused —
## banking costs no cells and cannot stop the circuit closing.
func _cycle_bank(cell: Vector2i) -> void:
	for corner in _compiled.corners:
		if corner.cell != cell:
			continue
		var next := (corner.bank + 1) % (TrackBuilder.MAX_BANK_LEVEL + 1)
		_layout.corner_banks[cell] = next
		_flash("Corner %s." % (
			"flat" if next == 0 else "banked %.0f degrees" % TrackBuilder.BANK_DEGREES[next]
		))
		_on_edited()
		return

## Raises or lowers whichever segment was clicked. A corner is keyed by its own
## bend cell, a straight by any cell along it, and bend cells never belong to a
## run — so which kind was clicked is unambiguous.
func _cycle_elevation(cell: Vector2i) -> void:
	for corner in _compiled.corners:
		if corner.cell != cell:
			continue
		if corner.max_level <= 0:
			_flash(
				"This corner cannot be raised — the straights either side have no "
				+ "room for the ramps."
			)
			return
		var next := (corner.level + 1) % (corner.max_level + 1)
		_set_level(cell, next)
		_flash("Corner %s." % ("back on the ground" if next == 0 else "held at +%d" % next))
		_on_edited()
		return

	for run in _compiled.runs:
		if not run.cells.has(cell):
			continue
		if run.max_level <= 0:
			_flash("This straight is too short for a climb.")
			return
		# Clear the old key first: elevation is recorded against whichever cell
		# was clicked, and a stale one would give the run two.
		for c in run.cells:
			_layout.elevation.erase(c)
		var next := (run.level + 1) % (run.max_level + 1)
		_set_level(cell, next)
		_flash("Straight %s." % ("back on the ground" if next == 0 else "held at +%d" % next))
		_on_edited()
		return

func _set_level(cell: Vector2i, level: int) -> void:
	if level > 0:
		_layout.elevation[cell] = level
	else:
		_layout.elevation.erase(cell)

# --- the panel ---

func _update_panel() -> void:
	_test_button.disabled = not _compiled.ok
	# Offered only when there is actually a gap to close, so it cannot look like
	# a thing that failed to work.
	var closeable: bool = (
		not _compiled.ok and not TrackShape.close_gap(_layout.cells).is_empty()
	)
	_close_button.visible = closeable
	_guide.text = _guidance()
	_readout.text = _summary()
	# A message from the last action outlives one repaint, then gives way to the
	# standing hint, so the panel is never stale but never silent either.
	_status.text = _transient_status if not _transient_status.is_empty() else _standing_hint()
	_transient_status = ""

## What to do next, in one line. This is the only place that answers "I have
## opened the editor, now what", so it always names a concrete next action.
func _guidance() -> String:
	if _grid.draw_mode:
		if _compiled.ok:
			return (
				"Drawing. Drag to lay road, right-drag to erase. Turn Draw off "
				+ "to drag the shape around instead."
			)
		return (
			"Drawing. Keep going until the road is one closed loop — "
			+ "then Join the ends up, or switch Draw off to drag it into shape."
		)
	if not _compiled.ok:
		return "Fix the circuit first — see below."
	if not _grid.has_handles():
		return "Turn Draw on to lay road, or drag the green dots to reshape."
	var raised := 0
	for run in _compiled.runs:
		if run.level > 0:
			raised += 1
	if _compiled.corners.size() <= 4:
		return (
			"Drag a green corner dot to reshape. Double-click a straight to add "
			+ "a new bend — four corners is just an oval."
		)
	if _layout.corner_sizes.is_empty() and raised == 0:
		return (
			"Now try a numbered badge to tighten a corner, or the dot in the "
			+ "middle of a straight to add a climb."
		)
	if raised == 0:
		return (
			"Add a climb: click a faint dot inside the loop. Raise a corner too "
			+ "and the height carries on round it."
		)
	if not _has_sustained_section():
		return (
			"That climb drops back down before the next corner. Raise the corner "
			+ "as well to carry the height through it."
		)
	return "Happy with it? Test drive, then Save."

## True once height is held across a corner rather than rising and falling inside
## a single straight — the difference between a crest and a raised section.
func _has_sustained_section() -> bool:
	for corner in _compiled.corners:
		if corner.level > 0:
			return true
	return false

func _standing_hint() -> String:
	if _grid.draw_mode:
		return "drag lays road · right-drag erases · D leaves drawing"
	if not _compiled.ok:
		return "shift-drag lays road · shift-right-drag erases · D to draw"
	return "drag corners and straights · right-click a corner removes it"

## The live verdict: what the circuit *is*, since closure is guaranteed by the
## shape editing rather than being something to check.
func _summary() -> String:
	if not _compiled.ok:
		var lines := _compiled.errors.duplicate()
		lines.append("")
		lines.append(
			"A circuit is one closed loop of road, one cell wide. "
			+ "Join the ends up below, or undo with ctrl+Z."
		)
		return "\n".join(lines)

	var result := TrackBuilder.new().measure(_compiled.segments)
	var widths := {1: 0, 2: 0, 3: 0}
	var lefts := 0
	for corner in _compiled.corners:
		widths[corner.size] += 1
		if corner.turn == "left":
			lefts += 1

	var lines := [
		"%.0f m lap" % result.length,
		"%d corners — %d tight, %d medium, %d sweeping" % [
			_compiled.corners.size(), widths[1], widths[2], widths[3]
		],
		"%d left / %d right" % [lefts, _compiled.corners.size() - lefts],
	]
	if result.peak > 0.5:
		var raised_corners := 0
		for corner in _compiled.corners:
			if corner.level > 0:
				raised_corners += 1
		lines.append("climbs %.1f m%s" % [
			result.peak,
			"" if raised_corners == 0 else ", held through %d corner%s" % [
				raised_corners, "" if raised_corners == 1 else "s"
			]
		])
	if not result.closed:
		# Should be unreachable: both the shape editor and the compiler refuse
		# anything that is not a closed ring. If it fires they have drifted
		# apart, which is worth surfacing rather than hiding.
		lines.append("BUG: builder says this does not close (%s)" % result.summary())
	return "\n".join(lines)

# --- files ---

func _refresh_picker() -> void:
	_picker.clear()
	_picker.add_item("New circuit")
	_picker.set_item_metadata(0, "")
	var selected := 0
	for layout in TrackStore.list_layouts():
		_picker.add_item(layout.display_name)
		var idx := _picker.item_count - 1
		_picker.set_item_metadata(idx, layout.id)
		if layout.id == _layout.id and not _layout.id.is_empty():
			selected = idx
	_picker.selected = selected
	_delete_button.disabled = _layout.id.is_empty()

func _on_picked(index: int) -> void:
	var id: String = _picker.get_item_metadata(index)
	_layout = TrackStore.load_layout(id) if not id.is_empty() else _starter_layout()
	GameState.editing_id = _layout.id
	_grid.layout = _layout
	_name_edit.text = _layout.display_name
	_delete_button.disabled = _layout.id.is_empty()
	_reset_undo()
	_recompile()
	_grid.fit_view()

func _on_save() -> void:
	_layout.display_name = _name_edit.text.strip_edges()
	if _layout.display_name.is_empty():
		_layout.display_name = "Untitled"
		_name_edit.text = _layout.display_name
	var err := TrackStore.save(_layout)
	GameState.editing_id = _layout.id
	_refresh_picker()
	_flash(
		"Saved as %s." % _layout.display_name if err == OK
		else "Could not save (error %d)." % err
	)
	_update_panel()

func _on_test() -> void:
	_on_save()
	# The race scene picks its track out of the same list the menu shows, so the
	# layout has to be on disk and findable by id before the scene change.
	var tracks := GameState.all_tracks()
	for i in tracks.size():
		if tracks[i]["id"] == _layout.id:
			GameState.selected_index = i
			get_tree().change_scene_to_file(RACE_SCENE)
			return
	_flash("Could not find the saved circuit to test.")

func _on_delete() -> void:
	if _layout.id.is_empty():
		return
	TrackStore.delete(_layout.id)
	GameState.editing_id = ""
	_layout = _starter_layout()
	_grid.layout = _layout
	_name_edit.text = _layout.display_name
	_reset_undo()
	_refresh_picker()
	_recompile()
	_grid.fit_view()
