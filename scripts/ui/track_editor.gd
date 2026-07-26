extends Control

## The track editor. Paint a loop of cells; everything else — corner radii, the
## start line, where the hills go — is a decision layered on top of that loop.
##
## The four modes exist because a click on a cell is ambiguous once the circuit
## compiles: it could mean paint here, start here, change this corner, or raise
## this straight. Modes make it explicit and keep the canvas free of modifier-key
## folklore.
##
## Nothing is written to disk until Save, except that Test drive saves first —
## the race scene builds a custom track from the stored layout, so an untested
## unsaved edit has nothing to build from.

const TITLE_SCENE := "res://scenes/title.tscn"
const RACE_SCENE := "res://scenes/race.tscn"
const EDITOR_SCENE := "res://scenes/editor/track_editor.tscn"

const MODES := [
	{"name": "Paint road", "hint": "Drag to lay road, right-drag to erase. Paint one closed loop."},
	{"name": "Start line", "hint": "Click a straight to move the start line. Its straight needs four spare cells."},
	{"name": "Corners", "hint": "Click a corner to tighten it. Wider corners are faster but eat the straights either side."},
	{"name": "Elevation", "hint": "Click a straight to raise it. The climb and descent both have to fit inside that straight."},
]

@onready var _grid: TrackGrid = $Split/Grid
@onready var _name_edit: LineEdit = $Split/Panel/NameEdit
@onready var _picker: OptionButton = $Split/Panel/Picker
@onready var _modes: VBoxContainer = $Split/Panel/Modes
@onready var _hint: Label = $Split/Panel/Hint
@onready var _readout: Label = $Split/Panel/Readout
@onready var _save_button: Button = $Split/Panel/Actions/SaveButton
@onready var _test_button: Button = $Split/Panel/Actions/TestButton
@onready var _delete_button: Button = $Split/Panel/Actions/DeleteButton
@onready var _back_button: Button = $Split/Panel/Actions/BackButton

var _layout: TrackLayout
var _compiled: TrackLayout.Compiled
var _mode_buttons: Array[Button] = []
var _mode := TrackGrid.Mode.PAINT

func _ready() -> void:
	# Esc out of a test drive comes back here rather than to the menu, so the
	# circuit being worked on stays on screen.
	GameState.return_scene = EDITOR_SCENE

	_layout = TrackStore.load_layout(GameState.editing_id) if not GameState.editing_id.is_empty() else null
	if _layout == null:
		_layout = _starter_layout()

	for i in MODES.size():
		var button := Button.new()
		button.text = "%d  %s" % [i + 1, MODES[i]["name"]]
		button.toggle_mode = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_set_mode.bind(i))
		_modes.add_child(button)
		_mode_buttons.append(button)

	_grid.layout = _layout
	_grid.layout_edited.connect(_recompile)
	_grid.cell_activated.connect(_on_cell_activated)
	_name_edit.text_changed.connect(func(t): _layout.display_name = t)
	_picker.item_selected.connect(_on_picked)
	_save_button.pressed.connect(_on_save)
	_test_button.pressed.connect(_on_test)
	_delete_button.pressed.connect(_on_delete)
	_back_button.pressed.connect(func(): get_tree().change_scene_to_file(TITLE_SCENE))

	_name_edit.text = _layout.display_name
	_refresh_picker()
	_set_mode(TrackGrid.Mode.PAINT)
	_recompile()
	# The canvas has no size until the containers have laid out once.
	await get_tree().process_frame
	_grid.fit_view()

## A new track opens as a driveable rectangle rather than a blank grid. An empty
## canvas gives no clue that cells must form one closed loop, and the first thing
## anyone wants to do is drive something and then change it.
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
	var key := (event as InputEventKey).keycode
	if key >= KEY_1 and key <= KEY_4:
		_set_mode(key - KEY_1)
	elif key == KEY_F:
		_grid.fit_view()
	elif key == KEY_S and event.ctrl_pressed:
		_on_save()

func _set_mode(mode: int) -> void:
	_mode = mode
	_grid.mode = mode
	_hint.text = MODES[mode]["hint"]
	for i in _mode_buttons.size():
		_mode_buttons[i].button_pressed = (i == mode)

func _recompile() -> void:
	_compiled = _layout.compile()
	_grid.compiled = _compiled
	_grid.queue_redraw()
	_update_readout()

## The live verdict. Closure is guaranteed by the grid, so this reports what the
## circuit *is* rather than whether it joined up — length, corner mix, climb —
## and falls back to the compiler's complaints when the loop is not yet valid.
func _update_readout() -> void:
	_test_button.disabled = not _compiled.ok
	if not _compiled.ok:
		_readout.text = "\n".join(_compiled.errors)
		return

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
		lines.append("climbs %.1f m" % result.peak)
	if not result.closed:
		# Should be unreachable: a painted loop closes by construction. If it
		# ever fires, the compiler and the builder disagree and that is a bug
		# worth surfacing rather than hiding behind a happy readout.
		lines.append("BUG: builder says this does not close (%s)" % result.summary())
	_readout.text = "\n".join(lines)

func _on_cell_activated(cell: Vector2i) -> void:
	match _mode:
		TrackGrid.Mode.START:
			if _layout.cells.has(cell):
				_layout.start_cell = cell
		TrackGrid.Mode.CORNER:
			_cycle_corner(cell)
		TrackGrid.Mode.ELEVATION:
			_cycle_elevation(cell)
	_recompile()

## Steps a corner down through the tiles that fit and wraps back to the widest,
## so one control covers the whole choice without needing a second button.
func _cycle_corner(cell: Vector2i) -> void:
	for corner in _compiled.corners:
		if corner.cell != cell:
			continue
		var next := corner.size - 1
		if next < 1:
			next = corner.max_size
		_layout.corner_sizes[cell] = next
		return

func _cycle_elevation(cell: Vector2i) -> void:
	for run in _compiled.runs:
		if not run.cells.has(cell):
			continue
		if run.max_level <= 0:
			_readout.text = "That straight is too short for a climb — it needs %d spare cells." % (
				TrackLayout.CELLS_PER_LEVEL + 1
			)
			return
		# Clear the old key first: elevation is recorded against whichever cell
		# was clicked, and leaving a stale one behind would give the run two.
		for c in run.cells:
			_layout.elevation.erase(c)
		var next := (run.level + 1) % (run.max_level + 1)
		if next > 0:
			_layout.elevation[cell] = next
		return

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
	_readout.text = (
		"Saved as %s." % _layout.display_name if err == OK
		else "Could not save (error %d)." % err
	)

func _on_test() -> void:
	_on_save()
	# The race scene picks its track out of the same list the menu shows, so the
	# layout has to be on disk and found by id before the scene change.
	var tracks := GameState.all_tracks()
	for i in tracks.size():
		if tracks[i]["id"] == _layout.id:
			GameState.selected_index = i
			get_tree().change_scene_to_file(RACE_SCENE)
			return
	_readout.text = "Could not find the saved circuit to test."

func _on_delete() -> void:
	if _layout.id.is_empty():
		return
	TrackStore.delete(_layout.id)
	GameState.editing_id = ""
	_layout = _starter_layout()
	_grid.layout = _layout
	_name_edit.text = _layout.display_name
	_refresh_picker()
	_recompile()
	_grid.fit_view()
