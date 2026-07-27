extends CanvasLayer

@onready var _speed: Label = $Root/SpeedPanel/SpeedMargin/Speed
@onready var _lap: Label = $Root/LapPanel/LapMargin/Rows/Lap
@onready var _current: Label = $Root/LapPanel/LapMargin/Rows/Current
@onready var _last: Label = $Root/LapPanel/LapMargin/Rows/Last
@onready var _best: Label = $Root/LapPanel/LapMargin/Rows/Best
@onready var _banner: Label = $Root/Banner
@onready var _speed_panel: PanelContainer = $Root/SpeedPanel
@onready var _touch: Control = $Root/TouchControls

## Where the banner sits under the top edge. Landscape has 1280 units of width,
## so the centred banner and the right-hand lap panel share a line with room to
## spare — that placement is measured and stays. Portrait has 720: the banner
## needs about 470 of them and the lap panel takes 214 off the right, so they
## collide, and the banner drops below the panel instead.
const BANNER_TOP_LANDSCAPE := 90.0
const BANNER_TOP_PORTRAIT := 168.0

## How far the speed readout lifts to clear the gas pedal. The pads only exist on
## a touchscreen, so on desktop it stays in the corner where it was placed.
const SPEED_LIFT_FOR_PADS := 96.0

var _car: VehicleBody3D
var _tracker: Node
var _banner_timer: float = 0.0
var _speed_home: float = 0.0

func _ready() -> void:
	_banner.text = ""
	_speed_home = _speed_panel.position.y
	_reflow()
	get_window().size_changed.connect(_reflow)

## The HUD is anchored to screen edges, so most of it survives an orientation
## change untouched. These two do not: the banner and the lap panel are only far
## enough apart while the canvas is wide, and the speed readout and the gas pedal
## are both pinned to the bottom right corner.
func _reflow() -> void:
	if not is_inside_tree():
		return
	var portrait := ViewportScaling.is_portrait(get_window().size)
	_banner.position.y = BANNER_TOP_PORTRAIT if portrait else BANNER_TOP_LANDSCAPE
	_speed_panel.position.y = (
		_speed_home - SPEED_LIFT_FOR_PADS if _touch.visible else _speed_home
	)

func _process(delta: float) -> void:
	if _car == null:
		_car = get_tree().get_first_node_in_group("player_car")
	if _tracker == null:
		_tracker = get_tree().get_first_node_in_group("lap_tracker")
		if _tracker != null:
			_tracker.lap_completed.connect(_on_lap_completed)

	if _car != null:
		_speed.text = "%3d km/h" % roundi(_car.linear_velocity.length() * 3.6)

	if _tracker != null:
		if _tracker.timing:
			_lap.text = "LAP %d" % _tracker.lap_number
			_current.text = _tracker.format_time(_tracker.lap_time)
			if _banner_timer <= 0.0:
				_banner.text = ""
		else:
			_lap.text = "READY"
			_current.text = _tracker.format_time(0.0)
			# The hint lives in the centred banner, not the corner panel, so it
			# cannot widen the panel off the edge of the screen.
			if _banner_timer <= 0.0:
				_banner.text = "cross the line to start"
		_last.text = "last   %s" % _tracker.format_time(_tracker.last_lap)
		_best.text = "best   %s" % _tracker.format_time(_tracker.best_lap)

	if _banner_timer > 0.0:
		_banner_timer -= delta
		if _banner_timer <= 0.0:
			_banner.text = ""

func _on_lap_completed(_lap_number: int, time: float, is_best: bool) -> void:
	_banner.text = ("NEW BEST  %s" if is_best else "LAP  %s") % _tracker.format_time(time)
	_banner_timer = 3.0
