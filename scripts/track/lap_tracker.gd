extends Node

## Times laps, and enforces that checkpoints are crossed in order.
##
## Ordering is the whole point: collision is a single flat ground plane and the
## guardrails are off, so nothing physically stops the car cutting a corner.
## A lap only counts if every gate was taken in sequence.

signal lap_completed(lap_number: int, time: float, is_best: bool)
signal timing_started
## A gate was taken in order. `delta` is seconds behind (positive) or ahead
## (negative) of the best lap at that same gate, or NAN when there is nothing
## stored to compare against.
signal split_recorded(index: int, split: float, delta: float)

## Which track's record to read and write. Set before the first physics frame.
var track_id: String = "ardennes"

var checkpoint_count: int = 0
var lap_number: int = 0
var lap_time: float = 0.0
var last_lap: float = 0.0
var best_lap: float = 0.0
var timing: bool = false

## Elapsed time at each gate of the lap being driven, and of the best lap stored
## for this circuit. Index 0 is the start line, and holds the time the lap was
## *closed* at — crossing it is what ends a lap, so that entry is the lap time
## itself rather than a zero at the beginning.
##
## A slot is 0.0 until its gate has been taken, so a lap in progress is a
## partially filled array rather than a short one. That keeps index meaning gate
## number the whole way round, which is what lets the two arrays be compared
## slot for slot without either of them carrying a length.
var splits := PackedFloat32Array()
var best_splits := PackedFloat32Array()

## Seconds behind (positive) or ahead (negative) at the last gate taken. NAN
## rather than 0.0 for "no comparison yet", because dead level with the best lap
## is a real and interesting reading that must not look like an absent one.
var delta: float = NAN

## Which index must be crossed next. Anything else is ignored, so a driver who
## skips a gate has to go back for it.
var _next_required: int = 0

var _bound: bool = false

## The best lap recorded on this circuit, for something else to replay, and the
## lap being recorded now. Kept apart so a lap that turns out to be slower can be
## thrown away without having touched the one being chased.
var ghost: Ghost
var _recording: Ghost
var _car: Node3D

func _ready() -> void:
	add_to_group("lap_tracker")

## Accumulated on the physics step, not _process: the physics delta is fixed, so
## lap times track the simulation rather than the render framerate.
func _physics_process(delta: float) -> void:
	if not _bound:
		_bind()
	if timing:
		lap_time += delta
		_record_sample()

## Samples the car onto `Ghost.HZ`'s grid, measured from the start of the lap
## rather than from a running accumulator.
##
## Comparing against `count()` is what keeps the recording aligned: sample n is
## always the pose at n/HZ seconds into the lap, so playback needs no timestamps
## and two recordings of the same circuit are directly comparable frame for
## frame. An accumulator that reset itself each time it fired would drift by up
## to a physics step per sample instead.
func _record_sample() -> void:
	if _recording == null:
		return
	if _car == null:
		_car = get_tree().get_first_node_in_group("player_car")
		if _car == null:
			return
	# Stops rather than growing without bound. A car parked on the circuit still
	# accumulates lap time, and without this a long enough pause would build a
	# recording that `to_bytes` would happily write and `from_bytes` would then
	# refuse — the cap exists on the reading side, so it has to be obeyed on the
	# writing side too. A lap over ten minutes keeps its first ten and its ghost
	# holds the last pose, which is the same thing an unfinished ghost does.
	if _recording.count() >= Ghost.MAX_SAMPLES:
		return
	if lap_time * Ghost.HZ < float(_recording.count()):
		return
	_recording.add(_car.global_transform)

## Binding is deferred rather than done in _ready(): the track is instanced at
## runtime by the race scene, and child _ready() runs before the parent's, so
## the checkpoints do not exist yet when this node is readied.
func _bind() -> void:
	var checkpoints := get_tree().get_nodes_in_group("checkpoint")
	if checkpoints.is_empty():
		return
	checkpoint_count = checkpoints.size()
	splits.resize(checkpoint_count)
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
			_begin_lap()
			timing_started.emit()
		return

	if index != _next_required:
		return

	# Recorded before the branch, so the line gets its split like any other gate.
	# For index 0 that split *is* the lap time, which is what makes the closing
	# entry comparable with a stored one.
	splits[index] = lap_time
	delta = _delta_at(index)
	split_recorded.emit(index, lap_time, delta)

	if index == 0:
		last_lap = lap_time
		var is_best := best_lap <= 0.0 or last_lap < best_lap
		if is_best:
			best_lap = last_lap
			# Duplicated, or the next lap would overwrite the splits the stored
			# record is being compared against, in place, as it is driven.
			best_splits = splits.duplicate()
			# The lap just recorded becomes the one to chase. Promoted before
			# `_begin_lap` below hands `_recording` a fresh buffer, so the ghost
			# now being replayed is the same object that was just saved.
			ghost = _recording
			_save_best()
		lap_completed.emit(lap_number, last_lap, is_best)
		lap_number += 1
		lap_time = 0.0
		_begin_lap()
		_next_required = 1
	else:
		_next_required = (index + 1) % checkpoint_count

## Clears the lap being driven. The delta goes back to NAN rather than staying at
## whatever the line read: carrying the last gate's delta into the next lap would
## show a comparison against a gate the car has not reached yet.
func _begin_lap() -> void:
	splits.resize(checkpoint_count)
	splits.fill(0.0)
	delta = NAN
	_recording = Ghost.new()

## How far behind the stored best lap the current one is at `index`.
##
## Returns NAN unless there is a stored split for that exact gate. Two ways there
## might not be: no record yet, or a record set before the circuit was edited and
## its gates moved. The length check catches the second, which would otherwise
## read out a confident delta between two different places on the track.
func _delta_at(index: int) -> float:
	if best_splits.size() != checkpoint_count:
		return NAN
	if best_splits[index] <= 0.0:
		return NAN
	return splits[index] - best_splits[index]

## Formats a delta as a signed seconds reading, or a placeholder when there is
## nothing to compare against. Always signed: "0.00" would be ambiguous about
## which side of the record it fell on, and dead level is worth showing as such.
static func format_delta(seconds: float) -> String:
	if is_nan(seconds):
		return ""
	return "%+.2f" % seconds

## Formats seconds as m:ss.mmm, or a placeholder when there is no time yet.
static func format_time(seconds: float) -> String:
	if seconds <= 0.0:
		return "--:--.---"
	var minutes := int(seconds / 60.0)
	return "%d:%06.3f" % [minutes, seconds - minutes * 60.0]

func _load_best() -> void:
	best_lap = GameState.best_lap_for(track_id)
	best_splits = GameState.best_sectors_for(track_id)
	ghost = GhostStore.load_ghost(track_id)

func _save_best() -> void:
	# Records are per track, car and surface, so a quick lap in one circumstance
	# cannot look like a record set in another. The time and its splits go in one
	# call because they describe the same lap; see `GameState.save_best_lap`.
	GameState.save_best_lap(track_id, best_lap, best_splits)
	# The recording is deliberately *not* required to succeed. A ghost is a
	# bonus on top of a lap record, and a full disk or a read-only user
	# directory must not stop a genuine best lap being kept.
	if ghost != null and not ghost.is_empty():
		GhostStore.save(track_id, ghost)
