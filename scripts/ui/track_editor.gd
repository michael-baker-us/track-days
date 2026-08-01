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

@onready var _grid: TrackGrid = $Split/Stack/Grid
@onready var _side: PanelContainer = $Split/Side
@onready var _top_bar: PanelContainer = $Split/Stack/TopBar
@onready var _bottom_bar: PanelContainer = $Split/Stack/BottomBar
@onready var _tools_row: HBoxContainer = $Split/Stack/TopBar/Slots/Tools
@onready var _phone_actions: HBoxContainer = $Split/Stack/BottomBar/Slots/PhoneActions
@onready var _bottom_slots: VBoxContainer = $Split/Stack/BottomBar/Slots
@onready var _more_button: Button = $Split/Stack/TopBar/Slots/Tools/MoreButton
@onready var _name_edit: LineEdit = $Split/Side/Rows/NameEdit
@onready var _picker: OptionButton = $Split/Side/Rows/Picker
@onready var _draw_button: Button = $Split/Side/Rows/ToolRow/DrawButton
@onready var _erase_button: Button = $Split/Side/Rows/ToolRow/EraseButton
@onready var _fit_button: Button = $Split/Side/Rows/ToolRow/FitButton
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

## Where each control that the phone layout moves lives when the sidebar has it:
## `[node, parent, index]`, recorded once before anything has moved. Restoring by
## remembered index is what lets the same control go back into the middle of a
## row rather than onto the end of it.
var _sidebar_home: Array = []
## True while the layout is the phone one, so a resize that does not change
## orientation costs nothing.
var _phone_layout := false
var _layout_applied := false

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
	_erase_button.toggled.connect(_set_erase_mode)
	_fit_button.pressed.connect(_grid.fit_view)
	_legend_toggle.toggled.connect(_show_legend)
	_close_button.pressed.connect(_close_gap)
	_name_edit.text_changed.connect(func(t): _layout.display_name = t)
	_picker.item_selected.connect(_on_picked)
	_undo_button.pressed.connect(_undo_last)
	_save_button.pressed.connect(_on_save)
	_test_button.pressed.connect(_on_test)
	_delete_button.pressed.connect(_on_delete)
	_back_button.pressed.connect(func(): get_tree().change_scene_to_file(TITLE_SCENE))

	_more_button.pressed.connect(_toggle_side_panel)

	_name_edit.text = _layout.display_name
	_refresh_picker()
	_reset_undo()
	_recompile()

	_remember_sidebar_homes()
	_apply_layout()
	get_window().size_changed.connect(_apply_layout)

	# The canvas has no size until the containers have laid out once.
	await get_tree().process_frame
	_grid.fit_view()

# --- the two shapes this screen takes ---

## Which controls move into the phone bars, and in what order. Split across the
## two bars by how often they are wanted: what is reached for while shaping goes
## above the canvas, what finishes the job goes below it.
##
## Everything not listed stays in the sidebar, which portrait floats over the
## canvas behind MORE — the name, the circuit picker, the stats, the tips and
## Delete are all things you go looking for, not things you want a bar's worth of
## screen spent on while drawing.
const TOP_BAR_TOOLS := ["DrawButton", "EraseButton", "FitButton", "UndoButton"]
const BOTTOM_BAR_ACTIONS := ["TestButton", "SaveButton", "BackButton"]
## Above the action row, in order. `CloseButton` is here rather than behind MORE
## because an unclosed circuit has exactly one useful next move and burying it
## would strand the drawing you just did.
const BOTTOM_BAR_STACK := ["CloseButton", "GuideCard", "Status"]

## How wide the floated sidebar is on a phone, and the most of the screen it may
## take. A panel that covers the canvas entirely gives nothing to orient against
## when you dismiss it.
const PHONE_PANEL_W := 340.0
const PHONE_PANEL_MAX := 0.82

## The docked width, which has to match `PANEL_W` in `tools/build_editor.gd` —
## the builder sets it on the node and this puts it back after a phone layout has
## floated the panel and changed it.
const SIDEBAR_W := 364.0

func _remember_sidebar_homes() -> void:
	for node_name: String in (
		TOP_BAR_TOOLS + BOTTOM_BAR_STACK + BOTTOM_BAR_ACTIONS
	):
		var node := _find_control(node_name)
		if node != null:
			_sidebar_home.append([node, node.get_parent(), node.get_index()])

func _find_control(node_name: String) -> Control:
	var found := find_children(node_name, "Control", true, false)
	return found[0] if not found.is_empty() else null

## Landscape is the sidebar this editor has always had. Portrait cannot be: the
## canvas is 720 units wide there and the panel wants 364 of them, so the thing
## being edited ended up with less room than the controls that edit it.
##
## The controls *move* rather than being built twice. Two of each button would
## mean two `disabled` flags, two signal connections and two chances for the pair
## to disagree about which one is lit — and Undo and Test drive both spend most
## of their life disabled, so a stale twin would be visible immediately.
func _apply_layout() -> void:
	if not is_inside_tree():
		return
	var phone := ViewportScaling.is_portrait(get_window().size)
	# A window dragged wider is not a change of layout, and reflowing on every
	# resize event would move controls out from under the pointer.
	if _layout_applied and phone == _phone_layout:
		return
	_layout_applied = true
	_phone_layout = phone
	if phone:
		_move_into_bars()
	else:
		_restore_to_sidebar()
	_top_bar.visible = phone
	_bottom_bar.visible = phone
	_place_side_panel(phone)
	_place_legend(phone)
	_hide_emptied_rows()
	# The canvas has just changed shape twice — once when the window did, and
	# again when the bars took a slice of it — and only the first of those went
	# through the grid's own resize handling. Deferred, because the containers
	# have not laid out yet and `fit_view` measures the canvas it is fitting to.
	_grid.fit_view.call_deferred()

## A row whose buttons have all moved into a bar would otherwise sit in the
## floated panel as a gap with nothing in it.
func _hide_emptied_rows() -> void:
	for node_name in ["ToolRow", "UndoRow"]:
		var row := _find_control(node_name)
		if row != null:
			row.visible = row.get_child_count() > 0

func _move_into_bars() -> void:
	# Before MORE, so the tools row reads left to right in the order listed and
	# MORE stays on the end where a menu button belongs.
	var at := 0
	for node_name: String in TOP_BAR_TOOLS:
		var node := _find_control(node_name)
		if node == null:
			continue
		node.reparent(_tools_row)
		_tools_row.move_child(node, at)
		node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		at += 1
	# Above the action row the bar was built with.
	at = 0
	for node_name: String in BOTTOM_BAR_STACK:
		var node := _find_control(node_name)
		if node == null:
			continue
		node.reparent(_bottom_slots)
		_bottom_slots.move_child(node, at)
		at += 1
	for node_name: String in BOTTOM_BAR_ACTIONS:
		var node := _find_control(node_name)
		if node == null:
			continue
		node.reparent(_phone_actions)
		node.size_flags_horizontal = Control.SIZE_EXPAND_FILL

func _restore_to_sidebar() -> void:
	# Ascending remembered index, so each control lands in a row that already has
	# everything that came before it — restoring in any other order puts them
	# back in the wrong places.
	var homes := _sidebar_home.duplicate()
	homes.sort_custom(func(a, b): return int(a[2]) < int(b[2]))
	for home: Array in homes:
		var node: Control = home[0]
		var parent: Node = home[1]
		if node.get_parent() == parent:
			continue
		node.reparent(parent)
		parent.move_child(node, mini(int(home[2]), parent.get_child_count() - 1))

## The sidebar floats over the canvas on a phone rather than sitting beside it,
## which is the whole reason the canvas gets its width back. It starts closed:
## MORE is a place to go looking, and arriving at a covered canvas would undo the
## point of moving everything out of the way.
func _place_side_panel(phone: bool) -> void:
	if not phone:
		if _side.get_parent() != $Split:
			_side.reparent($Split)
		_side.visible = true
		_side.custom_minimum_size = Vector2(SIDEBAR_W, 0.0)
		return
	if _side.get_parent() != self:
		_side.reparent(self)
	_side.visible = false
	_side.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	var canvas: float = get_viewport_rect().size.x
	var width: float = minf(PHONE_PANEL_W, canvas * PHONE_PANEL_MAX)
	_side.custom_minimum_size = Vector2(width, 0.0)
	_side.offset_left = -width
	_side.offset_right = 0.0
	# Stops short of both bars. Covering the top one would bury MORE under the
	# panel MORE opened, leaving no way to shut it again; covering the bottom one
	# would take Test drive away at the moment you have finished fiddling with
	# the settings you opened this for.
	_side.offset_top = _top_bar.get_combined_minimum_size().y
	_side.offset_bottom = -_bottom_bar.get_combined_minimum_size().y

func _toggle_side_panel() -> void:
	_side.visible = not _side.visible

## The legend clears the sidebar in landscape because the sidebar is always
## there. On a phone it is not, so the flyout gets the canvas edge instead.
func _place_legend(phone: bool) -> void:
	var clearance: float = 12.0 if phone else SIDEBAR_W + 12.0
	_legend.offset_left = -clearance
	_legend.offset_right = -clearance

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
	elif key_event.keycode == KEY_E:
		_erase_button.button_pressed = not _erase_button.button_pressed
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
	if on:
		# Laying road and rubbing it out are opposites; being in both at once is
		# not a state with a meaning, and erase wins every hit test, so leaving
		# both lit would make Draw look broken.
		_erase_button.set_pressed_no_signal(false)
		_grid.erase_mode = false
	_grid.queue_redraw()
	_flash(
		"Drawing: drag to lay road."
		if on else "Shaping: drag corners and straights."
	)
	_update_panel()

## The one destructive mode, and the only way in to either destructive edit
## without a right button — see `erase_mode` in `track_grid.gd`.
func _set_erase_mode(on: bool) -> void:
	_grid.erase_mode = on
	if on:
		_draw_button.set_pressed_no_signal(false)
		_grid.draw_mode = false
	_grid.queue_redraw()
	_flash(
		"Erasing: drag to rub road out, tap a green dot to remove that corner."
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
	if _grid.erase_mode:
		return (
			"Erasing. Drag to rub road out, or tap a green dot to remove that "
			+ "corner. Turn Erase off to go back to shaping."
		)
	if _grid.draw_mode:
		if _compiled.ok:
			return (
				"Drawing. Drag to lay road. Turn Draw off to drag the shape "
				+ "around instead."
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
	if _grid.erase_mode:
		return "drag rubs road out · tap a dot removes a corner · E leaves erasing"
	if _grid.draw_mode:
		return "drag lays road · D leaves drawing · E erases"
	if not _compiled.ok:
		return "D to draw · E to erase · shift-drag lays road"
	return "drag corners and straights · Erase removes one"

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

	# The same builder walk the measurement already needed, kept so the
	# centreline it fills can be handed to the lap estimate. `measure` instances
	# no tiles, which is what makes it affordable on every mouse move.
	var builder := TrackBuilder.new()
	var result := builder.measure(_compiled.segments)
	var widths := {1: 0, 2: 0, 3: 0}
	var lefts := 0
	for corner in _compiled.corners:
		widths[corner.size] += 1
		if corner.turn == "left":
			lefts += 1

	var straight := _longest_straight()
	# The estimate is the *ideal* lap rather than the par a medal will want.
	# `ParTime.HUMAN_SLACK` is the one constant in that model which has not been
	# measured, and showing a number derived from it here would launder a
	# placeholder into something that looks authored.
	var ideal := ParTime.ideal_lap(builder.centreline)

	# The readout has a fixed height budget — feedback is pinned and reference
	# scrolls, see docs/architecture.md — so the two facts added here are folded
	# into the lines already present rather than given lines of their own, and the
	# nudge below *replaces* the least important line rather than adding to it.
	var lines := [
		"%.0f m lap, about %s on a perfect run" % [result.length, _rough(ideal)],
		"%d corners — %d tight, %d medium, %d sweeping" % [
			_compiled.corners.size(), widths[1], widths[2], widths[3]
		],
	]

	var warning := _pathology(result, straight)
	if warning.is_empty():
		lines.append("%d left / %d right · longest straight %.0f m" % [
			lefts, _compiled.corners.size() - lefts, straight
		])
	else:
		lines.append(warning)
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

## An estimated lap as minutes and whole seconds, deliberately without the
## milliseconds `LapTracker.format_time` gives a real one. The model drives every
## corner exactly at the limit and has one constant in it that is still a
## placeholder; printing thousandths of a second off that would claim an accuracy
## it does not have.
func _rough(seconds: float) -> String:
	if seconds <= 0.0:
		return "--"
	var minutes := int(seconds / 60.0)
	return "%d:%02d" % [minutes, int(seconds) - minutes * 60]

## Metres of the longest straight, from the compiler's own count of the cells a
## run has left once the corners at each end have taken theirs. Read off `free`
## rather than measured off the centreline so it cannot disagree with the number
## the corner-sizing rules are enforcing.
func _longest_straight() -> float:
	var most := 0
	for run in _compiled.runs:
		most = maxi(most, run.free)
	return float(most) * TrackBuilder.SCALE

## A nudge when a circuit is legal but not much fun to drive. Advice, never a
## refusal — the shape rules already decide what can be built, and a design tool
## that argued with what it had just accepted would be worse than a quiet one.
##
## Both thresholds are read off things already measured rather than picked:
##
## - Sixteen gates are spread evenly round the lap, and each is 4 m deep against
##   a 2.56 m car. Under about 30 m apart they stop reading as sectors and start
##   reading as a queue.
## - The car needs roughly 250 m to reach its measured 165 km/h from a corner.
##   Nothing near that anywhere on the lap means it never gets out of the
##   mid-range, which is what a circuit of nothing but hairpins feels like.
func _pathology(result: TrackBuilder.BuildResult, straight: float) -> String:
	if result.gate_spacing > 0.0 and result.gate_spacing < 30.0:
		return (
			"Very short lap — the 16 timing gates end up %.0f m apart, so sector "
			+ "times will be nearly meaningless. Worth lengthening."
		) % result.gate_spacing
	if straight < 60.0 and _compiled.corners.size() >= 8:
		return (
			"No real straight anywhere — top speed needs about 250 m of clear "
			+ "road. Fine if you want it technical, but nothing will stretch its legs."
		)
	return ""

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
	# Via GameState rather than TrackStore, so the circuit's lap record goes with
	# it and cannot be inherited by the next track given the same name.
	GameState.delete_track(_layout.id)
	_layout = _starter_layout()
	_grid.layout = _layout
	_name_edit.text = _layout.display_name
	_reset_undo()
	_refresh_picker()
	_recompile()
	_grid.fit_view()
