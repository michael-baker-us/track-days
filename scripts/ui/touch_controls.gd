extends Control

## On-screen driving controls for touch devices.
##
## These do not steer the car. They synthesise `InputEventAction`s and push them
## through `Input.parse_input_event`, so `car_controller` keeps reading exactly
## the actions the keyboard and the gamepad feed, and never learns that touch
## exists. Adding a control here cannot change how the car drives; it can only
## change what presses the same buttons.
##
## Godot's `Button` is deliberately not used. Button presses arrive through the
## emulated mouse, and the emulated mouse is a *single* pointer — the first
## finger down owns it — so a `Button` layout physically cannot do gas and steer
## at once, which is most of driving. Raw `InputEventScreenTouch` /
## `InputEventScreenDrag` carry a per-finger `index`, so they can.

## Child node name -> action it presses. The nodes are built by
## `tools/build_touch_controls.gd`; a name here with no matching child is
## ignored, so the two can be edited in either order.
const REGION_ACTIONS := {
	"SteerLeft": &"steer_left",
	"SteerRight": &"steer_right",
	"Gas": &"accelerate",
	"Brake": &"brake",
	"Handbrake": &"handbrake",
}

## Alpha applied to a region while a finger is on it, so a press is visible on a
## screen where a finger is covering the control.
const PRESSED_MODULATE := 1.0
const IDLE_MODULATE := 0.5

## Finger index -> the action that finger is currently holding.
var _held: Dictionary[int, StringName] = {}
## Action -> how many fingers are holding it. Two fingers on the same pad must
## not release it when only the first lifts.
var _counts: Dictionary[StringName, int] = {}
## Resolved once: node name -> Control.
var _regions: Dictionary[StringName, Control] = {}

func _ready() -> void:
	for region_name in REGION_ACTIONS:
		var node := get_node_or_null(NodePath(region_name)) as Control
		if node != null:
			node.modulate.a = IDLE_MODULATE
			_regions[StringName(region_name)] = node
	set_visible_for_device()

## Shown only where there is a touchscreen, so the pads never sit over the track
## on desktop. Split out from `_ready` so the suite can force them on.
func set_visible_for_device() -> void:
	visible = DisplayServer.is_touchscreen_available()
	set_process_input(visible)

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_assign(event.index, event.position)
		else:
			_assign(event.index, Vector2.INF)
	elif event is InputEventScreenDrag:
		# A finger that slides off a pad releases it, and onto another takes it.
		# Without this, sliding from brake to gas leaves the brake held down.
		_assign(event.index, event.position)

## Point `index` at whichever region contains `pos` — or at nothing, for a
## release or a drag into empty space. The single path in and out means a finger
## can never hold two actions, or leak one when it lifts.
func _assign(index: int, pos: Vector2) -> void:
	var found := StringName()
	if pos != Vector2.INF:
		# Touch positions arrive in viewport space; `get_global_rect` is in this
		# CanvasLayer's space. They coincide only while the layer's transform is
		# identity, which is not a thing to rely on from here.
		var local: Vector2 = get_canvas_transform().affine_inverse() * pos
		for region_name in _regions:
			if _regions[region_name].get_global_rect().has_point(local):
				found = REGION_ACTIONS[String(region_name)]
				break

	var previous: StringName = _held.get(index, StringName())
	if previous == found:
		return
	if not previous.is_empty():
		_release(previous)
	if found.is_empty():
		_held.erase(index)
	else:
		_held[index] = found
		_press(found)
	_refresh_modulate()

func _press(action: StringName) -> void:
	_counts[action] = _counts.get(action, 0) + 1
	if _counts[action] == 1:
		_send(action, true)

func _release(action: StringName) -> void:
	var left: int = _counts.get(action, 0) - 1
	_counts[action] = maxi(left, 0)
	if _counts[action] == 0:
		_send(action, false)

func _send(action: StringName, pressed: bool) -> void:
	if not InputMap.has_action(action):
		return
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	# Digital: full lock, then `tuning.steer_speed` ramps it exactly as it ramps
	# the keyboard. Nothing here needs its own feel parameters.
	event.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(event)

func _refresh_modulate() -> void:
	for region_name in _regions:
		var action: StringName = REGION_ACTIONS[String(region_name)]
		var down: bool = _counts.get(action, 0) > 0
		_regions[region_name].modulate.a = PRESSED_MODULATE if down else IDLE_MODULATE

## Leaving the race while a pad is held would otherwise strand that action down —
## `Input` keeps the synthesised press until something sends the matching
## release, and the node that would have sent it is gone.
func release_all() -> void:
	for action in _counts.keys():
		if _counts[action] > 0:
			_send(action, false)
	_counts.clear()
	_held.clear()
	_refresh_modulate()

func _exit_tree() -> void:
	release_all()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		release_all()
