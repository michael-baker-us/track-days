class_name CarAudio
extends Node3D

## Engine note, tyre scrub and impacts, driven from what the car is already doing.
##
## Every sound is a buffer baked by `tools/build_audio.gd`; this only moves pitch,
## volume and the balance between two voices. Nothing here synthesises anything at
## runtime, which matters for the web build — it is single-threaded, and a
## per-frame `AudioStreamGenerator` fill would be competing with the physics step
## for the same thread.
##
## ## Two engine voices, crossfaded by the throttle
##
## A car that only changes *pitch* reads as a siren: the ear hears effort as
## timbre, not as frequency. `engine_load` is bright and rings on, `engine_overrun`
## is dull and dies between firings, and the throttle mixes between them at a
## single pitch. It is the largest of the changes that came out of the first sound
## being switched off for being annoying.
##
## ## The scrub knows what it is scrubbing on
##
## Squeal is a tarmac phenomenon — tread stuttering against a hard surface. Dirt
## throws material and snow packs it, so each surface gets its own buffer, chosen
## when the car enters the tree. A squeal on snow was the loudest wrong note in
## the old mix.
##
## ## The gearbox is a lie, deliberately
##
## Pitch could come straight from `VehicleWheel3D.get_rpm()`, and it would be
## wrong: wheel speed rises monotonically from a standstill to top speed, so the
## engine would climb one long slide over twenty seconds and never do the thing
## an engine does. An arcade racer sells acceleration with *repetition* — revs
## climbing, dropping, climbing again — so the speed range is divided into bands
## and the note sweeps through each one.
##
## There is no real gearbox in the physics: `engine_force` is applied directly
## and there is no clutch or torque curve to model. This is honestly a sound
## effect keyed to speed, and calling it a gearbox anywhere in the code would
## suggest the car knows about gears. It does not.

## Where the top gear tops out. Matches the measured 164.9 km/h so the last band
## is reached exactly as the car stops accelerating, rather than a note that is
## still climbing after the speed has flattened.
const TOP_SPEED_KMH := 165.0
const GEARS := 5

## Pitch multiplier at the bottom and top of a band. The baked loop is a 50 Hz
## fundamental, so these put the note between roughly 40 Hz and 150 Hz.
const PITCH_IDLE := 0.8
const PITCH_REDLINE := 3.0
## How far up a band the note starts after a change. Not 0.0: an engine drops
## revs on an upshift, it does not stop.
const REV_AFTER_SHIFT := 0.45

## Engine loudness floor, so an idling car is still present, and how much of the
## rest the throttle is responsible for.
const IDLE_GAIN := 0.25
const THROTTLE_GAIN := 0.75

## `get_skidinfo()` is 1.0 with full grip and falls towards 0 as a wheel slides.
## Scrub below this is the tyres working normally rather than losing the fight,
## and squealing through every corner makes the sound meaningless.
const SQUEAL_FROM := 0.35
## Below this there is no tyre noise however badly the wheels are behaving --
## a stationary car spinning its wheels against a wall should not squeal.
const SQUEAL_MIN_KMH := 8.0

## Smoothing, per second. The pitch has to move quickly enough to feel connected
## and slowly enough that a band change is a shift rather than a click.
const PITCH_LERP := 8.0
const GAIN_LERP := 10.0

## How fast the throttle moves the mix between the two engine voices. Quicker
## than the gain smoothing: lifting off should be heard immediately, because that
## is the whole information the overrun voice carries.
const LOAD_LERP := 14.0

## A change in velocity this big **within one physics frame** is a collision.
## Braking is nowhere near it — the measured 1.62 g stop is about 0.27 m/s per
## frame at 60 Hz — so nothing the driver does on purpose can trip it, and no
## contact monitoring is needed to catch a wall.
const IMPACT_DV := 3.0
## The change that counts as a full-volume hit, and the quietest one worth
## playing at all.
const IMPACT_FULL_DV := 12.0
const IMPACT_MIN_GAIN := 0.15
## Impacts closer together than this are one crash, not several. Without it a car
## scraping along a barrier retriggers every few frames and machine-guns.
const IMPACT_GAP := 0.25

@onready var _engine: AudioStreamPlayer3D = $Engine
@onready var _overrun: AudioStreamPlayer3D = $Overrun
@onready var _tyre: AudioStreamPlayer3D = $Tyre
@onready var _impact: AudioStreamPlayer3D = $Impact

var _car: VehicleBody3D
var _wheels: Array[VehicleWheel3D] = []
var _pitch := PITCH_IDLE
var _engine_gain := 0.0
var _load_mix := 0.0
var _tyre_gain := 0.0
var _last_velocity := Vector3.ZERO
var _since_impact := 0.0

func _ready() -> void:
	_car = get_parent() as VehicleBody3D
	if _car != null:
		for child in _car.get_children():
			if child is VehicleWheel3D:
				_wheels.append(child)
		_last_velocity = _car.linear_velocity
	# Chosen here rather than baked into the car scene: the surface is picked on
	# the title screen, and one car scene serves every condition.
	var scrub := "res://resources/audio/tyre_%s.tres" % GameState.selected_surface
	if ResourceLoader.exists(scrub):
		_tyre.stream = load(scrub)
	_apply()

## Starts or stops both loops together.
##
## Stopped rather than muted: a silent loop still costs a mix every frame, and
## the whole point of the switch is that someone did not want this running.
func _set_playing(on: bool) -> void:
	if on == _engine.playing:
		return
	for player in [_engine, _overrun, _tyre]:
		if on:
			player.play()
		else:
			player.stop()
	if not on:
		_impact.stop()

## Whether there is anyone to hear this.
##
## Under `--headless` the audio driver is a stub that never mixes, so starting a
## loop there does no work anyone benefits from — and the playback objects it
## creates are still held by the audio server at shutdown, which ends every
## suite run with "2 resources still in use". Nothing about the *logic* is
## skipped: pitch and gain are still computed and still applied to the players
## every frame, so the suite asserts on exactly what the game would do.
func _audible() -> bool:
	return DisplayServer.get_name() != "headless"

func _physics_process(delta: float) -> void:
	# Runs while the tree is paused (see `PROCESS_MODE_ALWAYS`, set on this node
	# by tools/build_car.gd) purely so the loops can be silenced. A paused game
	# that keeps droning is worse than one that goes quiet, and audio playback
	# does not stop on its own when the tree does.
	# Read every frame rather than at `_ready`, because the switch is on the pause
	# menu — so the moment it can be changed is the moment this node is the only
	# thing still running.
	_set_playing(GameState.audio_enabled() and _audible())

	var paused := get_tree().paused
	for player in [_engine, _overrun, _tyre, _impact]:
		player.stream_paused = paused
	if paused or _car == null or not _engine.playing:
		return

	var speed_kmh := _car.linear_velocity.length() * 3.6
	_pitch = lerpf(_pitch, _target_pitch(speed_kmh), minf(1.0, PITCH_LERP * delta))

	var throttle: float = clampf(
		absf(_car.engine_force) / maxf(_car.tuning.engine_force, 1.0), 0.0, 1.0
	)
	_engine_gain = lerpf(
		_engine_gain, IDLE_GAIN + THROTTLE_GAIN * throttle,
		minf(1.0, GAIN_LERP * delta)
	)
	_load_mix = lerpf(_load_mix, throttle, minf(1.0, LOAD_LERP * delta))
	_tyre_gain = lerpf(
		_tyre_gain, _squeal(speed_kmh), minf(1.0, GAIN_LERP * delta)
	)
	_check_impact(delta)
	_apply()

## Fires the crash sound when the car's velocity changes faster than driving can
## change it.
##
## Measured against the physics rather than against a contact signal on purpose.
## `contact_monitor` costs a broadphase report every frame for something that
## happens seconds apart, and it reports touching rather than *hitting* — a car
## resting against a barrier is in contact continuously. A step change in
## velocity is exactly the thing worth hearing, and it catches landings from a
## crest as well as walls.
func _check_impact(delta: float) -> void:
	_since_impact += delta
	var change := (_car.linear_velocity - _last_velocity).length()
	_last_velocity = _car.linear_velocity
	if change < IMPACT_DV or _since_impact < IMPACT_GAP:
		return
	_since_impact = 0.0
	var force := clampf(
		(change - IMPACT_DV) / (IMPACT_FULL_DV - IMPACT_DV), 0.0, 1.0
	)
	_impact.volume_db = _to_db(lerpf(IMPACT_MIN_GAIN, 1.0, force))
	# Bigger hits are lower: a heavy impact loads more of the structure, and a
	# glancing one is mostly the rail.
	_impact.pitch_scale = lerpf(1.25, 0.8, force)
	if _audible():
		_impact.play()

## Where in its band the note sits, given how fast the car is going.
##
## The band is found by dividing the speed range rather than by tracking a
## current gear, so it cannot get stuck in one: braking hard drops the note the
## way accelerating raises it, with no state to unwind.
func _target_pitch(speed_kmh: float) -> float:
	var through := clampf(speed_kmh / TOP_SPEED_KMH, 0.0, 1.0)
	var band := minf(floorf(through * float(GEARS)), float(GEARS - 1))
	var within := through * float(GEARS) - band
	return lerpf(
		lerpf(PITCH_IDLE, PITCH_IDLE + 0.4, band / float(GEARS - 1)),
		PITCH_REDLINE,
		lerpf(REV_AFTER_SHIFT, 1.0, within) if band > 0.0 else within
	)

## How hard the worst-behaved wheel is sliding, 0 to 1.
##
## Worst rather than average: one wheel breaking away is the moment worth
## hearing, and averaging it across four hides it behind the three that are still
## gripping.
func _squeal(speed_kmh: float) -> float:
	if speed_kmh < SQUEAL_MIN_KMH:
		return 0.0
	var worst := 1.0
	for wheel in _wheels:
		if wheel.is_in_contact():
			worst = minf(worst, wheel.get_skidinfo())
	if worst >= SQUEAL_FROM:
		return 0.0
	return clampf((SQUEAL_FROM - worst) / SQUEAL_FROM, 0.0, 1.0)

func _apply() -> void:
	# One pitch across both voices — they are the same engine seen in two states,
	# and letting them drift apart would be two engines.
	_engine.pitch_scale = _pitch
	_overrun.pitch_scale = _pitch
	_engine.volume_db = _to_db(_engine_gain * _load_mix)
	_overrun.volume_db = _to_db(_engine_gain * (1.0 - _load_mix))
	# Scrub rises in pitch with how hard it is being asked for, which is most of
	# what distinguishes a protest from a slide.
	_tyre.pitch_scale = 0.85 + 0.3 * _tyre_gain
	_tyre.volume_db = _to_db(_tyre_gain)

## Releases the streams on the way out.
##
## Without this the engine exits with "2 resources still in use": a playing
## `AudioStreamPlayer3D` holds its stream, and both players are still looping
## when the tree comes down. Harmless in itself, but it is an `ERROR` on the way
## out of every headless run, and a suite whose log ends in errors is a suite
## nobody reads the end of.
func _exit_tree() -> void:
	for player in [_engine, _overrun, _tyre, _impact]:
		if player != null:
			player.stop()
			player.stream = null

## Silence is -80 dB rather than the -inf a zero linear gain converts to. Godot
## treats -inf as a real number here and it propagates into the mixer.
static func _to_db(gain: float) -> float:
	if gain <= 0.001:
		return -80.0
	return linear_to_db(gain)
