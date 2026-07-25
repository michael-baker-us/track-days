extends CanvasLayer

@onready var _speed: Label = $Root/SpeedPanel/SpeedMargin/Speed
@onready var _lap: Label = $Root/LapPanel/LapMargin/Rows/Lap
@onready var _current: Label = $Root/LapPanel/LapMargin/Rows/Current
@onready var _last: Label = $Root/LapPanel/LapMargin/Rows/Last
@onready var _best: Label = $Root/LapPanel/LapMargin/Rows/Best
@onready var _banner: Label = $Root/Banner

var _car: VehicleBody3D
var _tracker: Node
var _banner_timer: float = 0.0

func _ready() -> void:
	_banner.text = ""

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
			_lap.text = "OUT LAP"
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
