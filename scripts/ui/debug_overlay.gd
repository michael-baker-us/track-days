extends CanvasLayer

@onready var _label: Label = $Panel/MarginContainer/Label

var _car: VehicleBody3D
var _debug_visible: bool = true

func _ready() -> void:
	visible = _debug_visible

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		_debug_visible = not _debug_visible
		visible = _debug_visible

func _process(_delta: float) -> void:
	if not visible:
		return
	if _car == null:
		_car = get_tree().get_first_node_in_group("player_car")
		if _car == null:
			return

	var speed_kmh := _car.linear_velocity.length() * 3.6
	var lines := PackedStringArray([
		"speed: %.1f km/h" % speed_kmh,
		"engine_force: %.0f" % _car.engine_force,
		"brake: %.0f" % _car.brake,
		"steering: %.2f rad" % _car.steering,
	])

	for child in _car.get_children():
		if child is VehicleWheel3D:
			lines.append("%s: contact=%s skid=%.2f" % [child.name, child.is_in_contact(), child.get_skidinfo()])

	_label.text = "\n".join(lines)
