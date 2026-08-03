class_name StartLights
extends Node3D

## The countdown before a race: **3 — 2 — 1 — GO**.
##
## ## Why a countdown rather than a Formula 1 start
##
## The first version was the real thing: five columns of two, coming on a second
## apart and going out together. It is the correct grammar for a motor race and it
## is wrong for this game, because a Formula 1 start asks you to *interpret*
## lights — the signal is the moment they extinguish, which you only recognise if
## you already know that is the rule. An arcade racer wants the opposite: a number
## on the screen counting down, so there is nothing to know.
##
## So the lamps are three, they light one at a time as the count runs down, and
## they all turn **green** on GO. The lamps are decoration; the number is the
## instruction.
##
## ## Why the lights own the sequence and not `race.gd`
##
## `race.gd` needs one fact — whether the car is released — and everything else
## here is presentation. Putting the timing in the lights means a circuit built
## without them (a painted one that fails to place the gantry, say) still races:
## `race.gd` asks for a release and gets one immediately rather than waiting on a
## node that is not there.
##
## ## Why it is not `await`
##
## A coroutine here would run on the scene tree's own timing and keep counting
## while the game is paused — so pausing on the grid would let the race start
## behind the pause menu. Counting in `_process` costs nothing and stops when the
## tree stops, which is the behaviour anyone would expect.

## The number on screen: 3, 2, 1, then 0 for GO. -1 when nothing is showing.
signal counted(number: int)
signal released

## A second a number, which is the cadence everyone already knows.
##
## `LEAD_IN` is the pause before "3" appears, and it is long enough for the car to
## have settled on its suspension first — that settle is visible now the car is
## held on its brakes rather than frozen, and it should happen while nothing else
## is. `GO_HOLD` is how long GO stays up after the car is free.
const STEP := 1.0
const LEAD_IN := 1.1
const GO_HOLD := 0.9
const COUNT_FROM := 3

## Lens colours: red counting down, green on GO, near-black unlit.
##
## ## Why they are not brighter
##
## `LENS_GLOW` was 3.2, on the reasoning that a lens should be pushed above 1 so
## it reads as a lamp rather than as paint. It does the opposite. The scene is
## tonemapped with ACES at a white point of 2.1, and **an unshaded albedo is not
## exempt from that** — anything past the white point compresses toward white, so
## a red at 3.2 came out pale orange and a green at 3.2 came out near-white. The
## lamps were described, accurately, as "yellow and white".
##
## Modelled through the same curve: at x3.2 the green lens retains barely half its
## saturation, at x1.35 it keeps three quarters. The hues below are also purer than
## they were — the old green carried a fifth of a unit of red, which is a straight
## subtraction from how green it can look once everything is compressed.
##
## What makes a lens read as lit is **contrast with a dark housing**, not raw
## magnitude. Blowing past the white point only trades the colour away for
## brightness the tonemapper then takes back.
const LENS_RED := Color(1.0, 0.04, 0.02)
const LENS_GREEN := Color(0.05, 1.0, 0.12)
const LENS_DARK := Color(0.10, 0.10, 0.11)
const LENS_GLOW := 1.6

var _elapsed := 0.0
var _shown := -1
var _done := false
var _lenses: Array[MeshInstance3D] = []

func _ready() -> void:
	for child in get_children():
		if child is MeshInstance3D and String(child.name).begins_with("Lens"):
			_lenses.append(child)
	_paint(-1)

## Whether the car is free. `race.gd` reads this and nothing else.
func is_released() -> bool:
	return _done

## The number currently on screen, or -1 for nothing. 0 is GO.
func showing() -> int:
	return _shown

func _process(delta: float) -> void:
	var over := LEAD_IN + float(COUNT_FROM) * STEP + GO_HOLD
	if _elapsed > over:
		return
	_elapsed += delta
	if _elapsed < LEAD_IN:
		return

	# GO holds on screen for a moment after the car is free, then clears itself.
	if _elapsed >= over:
		_show(-1)
		return

	var steps := int(floorf((_elapsed - LEAD_IN) / STEP))
	var number: int = maxi(COUNT_FROM - steps, 0)
	if number != _shown:
		_show(number)

func _show(number: int) -> void:
	_shown = number
	_paint(number)
	counted.emit(number)
	if number == 0 and not _done:
		_done = true
		released.emit()

## Skips straight to GO. For the suite, and for anything that has to catch up.
func force_release() -> void:
	if _done:
		return
	_elapsed = LEAD_IN + float(COUNT_FROM) * STEP
	_show(0)

## Lamps light one at a time as the count runs down, and all turn green together.
##
## Counting *up* as the number counts *down* is the right way round: three lamps
## lit means "about to go", which is the reading a driver gets at a glance without
## having to look at the number they were told to look at.
func _paint(number: int) -> void:
	# Indexed off how many lamps there actually are, not off `COUNT_FROM`. The two
	# are the same today — three lamps, three numbers — and if they ever drifted,
	# indexing by the constant would leave the extra lamps permanently dark with
	# nothing to say so.
	var total := _lenses.size()
	for i in total:
		var colour := LENS_DARK
		if number == 0:
			colour = LENS_GREEN
		elif number > 0 and i < total - number + 1:
			colour = LENS_RED
		_lenses[i].material_override = lens_material(colour)

## One lens, at a colour.
##
## Unshaded on purpose: a lamp lens is a source, not a surface, and shading it
## would let the trackside floodlighting decide how brightly the start lights
## read — which would make them dimmest at night.
static func lens_material(colour: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = colour if colour == LENS_DARK else colour * LENS_GLOW
	return mat
