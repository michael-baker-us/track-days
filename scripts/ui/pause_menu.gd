extends Control

## The way out of a race, and the only one there is on a touchscreen.
##
## ## Why leaving is a menu rather than a keystroke
##
## Escape used to change scene the instant it was pressed. That is fine on a
## keyboard, where Escape is a deliberate reach, and wrong everywhere else: a
## gamepad's B sits under the thumb, and a phone had no way out at all short of
## reloading the page. One mis-press threw away the lap being driven.
##
## So all three routes now arrive at the same place — this menu — and leaving is
## the second press, not the first. That is what makes one design work for a
## keyboard, a pad and a thumb: the *way in* has to differ per device, because
## the devices differ, but what happens next does not.
##
## ## What opens it
##
## `pause` (Escape, and the pad's Start) toggles. `ui_cancel` (Escape again, and
## the pad's B) closes, so the key that opened it also shuts it. Both are read
## here rather than in `race.gd`, in one handler, in that order — Escape fires
## both actions from a single event, and two handlers would toggle twice and
## leave the menu exactly as it was found.
##
## On touch there is a button, shown on the same rule as the driving pads. It is
## the only route that has to exist on screen, because the other two are physical.
##
## ## Why the whole tree pauses
##
## `get_tree().paused` stops the car, the camera and the lap clock together —
## `lap_tracker` accumulates in `_physics_process`, so a menu that did not pause
## would quietly add its own time to the lap. This node runs `PROCESS_MODE_ALWAYS`
## so it can still be dismissed, which is set on the node in `build_ui.gd`; a
## paused menu cannot unpause itself.

const TITLE_SCENE := "res://scenes/title.tscn"

@onready var _resume_button: Button = $Panel/Rows/ResumeButton
@onready var _quit_button: Button = $Panel/Rows/QuitButton
@onready var _throttle_button: Button = $Panel/Rows/ThrottleButton
## A sibling, not a child: it has to be on screen while this menu is not.
@onready var _open_button: Button = get_parent().get_node_or_null("PauseButton")

func _ready() -> void:
	visible = false
	_resume_button.pressed.connect(_resume)
	_quit_button.pressed.connect(_leave)
	_throttle_button.pressed.connect(_toggle_throttle)
	_refresh_throttle()
	if _open_button != null:
		_open_button.pressed.connect(_toggle)
	set_button_visible_for_device()

## Analogue reads how far the trigger is pulled; binary treats any press as full.
## Both labels stay inside the built-in font, which the web export has no
## fallback for.
func _toggle_throttle() -> void:
	GameState.set_analogue_input(not GameState.analogue_input())
	_refresh_throttle()

func _refresh_throttle() -> void:
	_throttle_button.text = (
		"Throttle: Analogue" if GameState.analogue_input() else "Throttle: Binary"
	)

## Shown only where there is a touchscreen, on the same rule as the driving pads:
## a keyboard has Escape and a pad has Start, and neither needs the screen space.
## Split out from `_ready` so the suite can force it on.
func set_button_visible_for_device() -> void:
	if _open_button != null:
		_open_button.visible = DisplayServer.is_touchscreen_available()

func _toggle() -> void:
	_set_paused(not visible)

func _unhandled_input(event: InputEvent) -> void:
	# `pause` first: Escape matches both actions from one event, and testing
	# `ui_cancel` first would close and reopen in the same press.
	if event.is_action_pressed("pause"):
		get_viewport().set_input_as_handled()
		_toggle()
		return
	if visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_resume()

func _set_paused(on: bool) -> void:
	visible = on
	get_tree().paused = on
	if on:
		# A synthesised touch press is held until something sends the matching
		# release, and the pads stop getting events the moment the tree pauses —
		# so pausing mid-corner with the gas down would resume with it still down.
		_release_touch_pads()
		# So a pad can drive the menu it just opened. Resume rather than Quit:
		# the dangerous one should never be the one already under the button.
		_resume_button.grab_focus()

func _resume() -> void:
	_set_paused(false)

## Unpauses before changing scene. `paused` is a property of the tree, not of the
## scene, so leaving while it is set carries the pause into the menu and the
## title screen arrives frozen.
func _leave() -> void:
	_set_paused(false)
	var back: String = GameState.return_scene
	get_tree().change_scene_to_file(back if not back.is_empty() else TITLE_SCENE)

func _release_touch_pads() -> void:
	var pads := get_tree().get_nodes_in_group("touch_controls")
	for pad in pads:
		pad.release_all()
