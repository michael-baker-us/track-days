extends Node

## Times laps, and enforces that checkpoints are crossed in order.
##
## Ordering is the whole point: collision is a single flat ground plane and the
## guardrails are off, so nothing physically stops the car cutting a corner.
## A lap only counts if every gate was taken in sequence.

signal lap_completed(lap_number: int, time: float, is_best: bool)
signal timing_started

## Which track's record to read and write. Set before the first physics frame.
var track_id: String = "highland"

var checkpoint_count: int = 0
var lap_number: int = 0
var lap_time: float = 0.0
var last_lap: float = 0.0
var best_lap: float = 0.0
var timing: bool = false

## Which index must be crossed next. Anything else is ignored, so a driver who
## skips a gate has to go back for it.
var _next_required: int = 0

var _bound: bool = false

func _ready() -> void:
	add_to_group("lap_tracker")

## Accumulated on the physics step, not _process: the physics delta is fixed, so
## lap times track the simulation rather than the render framerate.
func _physics_process(delta: float) -> void:
	if not _bound:
		_bind()
	if timing:
		lap_time += delta

## Binding is deferred rather than done in _ready(): the track is instanced at
## runtime by the race scene, and child _ready() runs before the parent's, so
## the checkpoints do not exist yet when this node is readied.
func _bind() -> void:
	var checkpoints := get_tree().get_nodes_in_group("checkpoint")
	if checkpoints.is_empty():
		return
	checkpoint_count = checkpoints.size()
	for cp in checkpoints:
		cp.passed.connect(_on_checkpoint_passed)
	_load_best()
	_bound = true

func _on_checkpoint_passed(index: int) -> void:
	if checkpoint_count == 0:
		return

	# Before the first crossing of the start line we are on an out lap, so
	# everything is ignored until the line itself is crossed.
	if not timing:
		if index == 0:
			timing = true
			lap_time = 0.0
			lap_number = 1
			_next_required = 1
			timing_started.emit()
		return

	if index != _next_required:
		return

	if index == 0:
		last_lap = lap_time
		var is_best := best_lap <= 0.0 or last_lap < best_lap
		if is_best:
			best_lap = last_lap
			_save_best()
		lap_completed.emit(lap_number, last_lap, is_best)
		lap_number += 1
		lap_time = 0.0
		_next_required = 1
	else:
		_next_required = (index + 1) % checkpoint_count

## Formats seconds as m:ss.mmm, or a placeholder when there is no time yet.
static func format_time(seconds: float) -> String:
	if seconds <= 0.0:
		return "--:--.---"
	var minutes := int(seconds / 60.0)
	return "%d:%06.3f" % [minutes, seconds - minutes * 60.0]

func _load_best() -> void:
	best_lap = GameState.best_lap_for(track_id)

func _save_best() -> void:
	# Records are per track, so a quick lap on one circuit cannot look like a
	# record on another.
	GameState.save_best_lap(track_id, best_lap)
