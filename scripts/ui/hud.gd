extends CanvasLayer

@onready var _speed: Label = $Root/SpeedPanel/SpeedMargin/Speed
@onready var _lap: Label = $Root/LapPanel/LapMargin/Rows/Lap
@onready var _current: Label = $Root/LapPanel/LapMargin/Rows/Current
@onready var _delta: Label = $Root/LapPanel/LapMargin/Rows/Delta
@onready var _last: Label = $Root/LapPanel/LapMargin/Rows/Last
@onready var _best: Label = $Root/LapPanel/LapMargin/Rows/Best
@onready var _banner: Label = $Root/Banner
@onready var _lap_panel: PanelContainer = $Root/LapPanel
@onready var _speed_panel: PanelContainer = $Root/SpeedPanel
@onready var _touch: Control = $Root/TouchControls

## Where the banner sits under the top edge. Landscape has 1280 units of width,
## so the centred banner and the right-hand lap panel share a line with room to
## spare — that placement is measured and stays. Portrait has 720: the banner
## needs about 470 of them and the lap panel takes 214 off the right, so they
## collide, and the banner drops below the panel instead.
##
## The portrait position is *measured off the panel* rather than written down as
## a number. It used to be a constant, and adding the delta row grew the panel
## past it — the two overlapped again, and only the suite noticed. A constant
## here is a copy of the panel's height that nothing keeps in step.
const BANNER_TOP_LANDSCAPE := 90.0
const BANNER_GAP_PORTRAIT := 6.0

## How far the speed readout lifts to clear the gas pedal. The pads only exist on
## a touchscreen, so on desktop it stays in the corner where it was placed.
const SPEED_LIFT_FOR_PADS := 96.0

var _car: VehicleBody3D
var _tracker: Node
var _banner_timer: float = 0.0
var _speed_home: float = 0.0
## Last colour written to the delta row, so an unchanged one is not rewritten.
var _delta_colour := Color(0, 0, 0, 0)

func _ready() -> void:
	_banner.text = ""
	_speed_home = _speed_panel.position.y
	_reflow()
	get_window().size_changed.connect(_reflow)
	# The panel lays out some frames after the scene is added, and again whenever
	# a row's text changes width, so its height is not known at `_ready`. Watching
	# it is what lets the banner be positioned from the panel rather than from a
	# guess about how tall it will end up.
	_lap_panel.resized.connect(_reflow)

## The HUD is anchored to screen edges, so most of it survives an orientation
## change untouched. These two do not: the banner and the lap panel are only far
## enough apart while the canvas is wide, and the speed readout and the gas pedal
## are both pinned to the bottom right corner.
func _reflow() -> void:
	if not is_inside_tree():
		return
	var portrait := ViewportScaling.is_portrait(get_window().size)
	_banner.position.y = (
		_lap_panel.position.y + _lap_panel.size.y + BANNER_GAP_PORTRAIT
		if portrait else BANNER_TOP_LANDSCAPE
	)
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
		_show_delta()
		_last.text = "last   %s" % _tracker.format_time(_tracker.last_lap)
		_best.text = "best   %s" % _tracker.format_time(_tracker.best_lap)

	if _banner_timer > 0.0:
		_banner_timer -= delta
		if _banner_timer <= 0.0:
			_banner.text = ""

## The gap to the best lap at the last gate crossed, green for ahead and red for
## behind.
##
## The colours are the theme's, not this file's: `UiTheme.GREEN` and
## `UiTheme.DANGER` already mean "a good result" and "a bad one" on the editor
## canvas and on every button, and a HUD that invented its own pair would be the
## second place a reader has to learn what green means here.
##
## Blank rather than a placeholder when there is nothing to compare against.
## Unlike the last and best rows, which show `--:--.---` to hold their width, an
## empty delta is only ever transient — the first lap on a circuit — and a dash
## sitting under the running clock reads as a broken readout.
## Guarded on the colour actually changing. `Label.set_text` already returns early
## when handed the string it is holding, but `add_theme_color_override` does not —
## it writes and notifies every time, and this runs on every rendered frame while
## the delta only changes sixteen times a lap.
func _show_delta() -> void:
	var delta: float = _tracker.delta
	_delta.text = _tracker.format_delta(delta)
	if is_nan(delta):
		return
	var colour: Color = UiTheme.DANGER if delta > 0.0 else UiTheme.GREEN
	if colour == _delta_colour:
		return
	_delta_colour = colour
	_delta.add_theme_color_override("font_color", colour)

func _on_lap_completed(_lap_number: int, time: float, is_best: bool) -> void:
	_banner.text = ("NEW BEST  %s" if is_best else "LAP  %s") % _tracker.format_time(time)
	_banner_timer = 3.0
