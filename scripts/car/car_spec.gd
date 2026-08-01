class_name CarSpec
extends Resource

## One car: which model it is made of, and how it drives.
##
## ## Geometry is measured, not written down
##
## `tools/build_car.gd` used to hard-code the body size, the wheel positions and
## the wheel radius as constants, with a warning that they are load-bearing —
## `docs/tuning-journal.md` measured the handling against them. Measuring the
## same numbers off `race.glb` reproduces every one of them exactly, so the
## constants were a *copy* of the art rather than a decision about it.
##
## So a spec names a `.glb` and the builder reads the geometry out of it. Adding
## a car is then a spec and a tuning preset, with nothing to transcribe and
## nothing to get subtly wrong — which is the difference between one car and a
## garage.
##
## ## Feel is not
##
## `tuning` is the one thing here that cannot be derived. Two cars sharing a
## preset feel like the same car in different clothes, which is the whole failure
## mode a garage has to avoid, so every spec carries its own — and every one of
## them has to be *measured*, on the same rig as the first (`docs/tuning-journal.md`).
##
## ## The scale question, deferred on purpose
##
## The road is 14 m wide and these cars are around 2.6 m long, which
## `docs/roadmap.md` flags as a decision that gets harder with every car added.
## It is deferred rather than answered: every car shipped so far is within 12% of
## the same size, so nothing here forces it. A kart or a truck would.

@export var id: String = "race"
## Shown on the title screen, so it stays inside the built-in font — the web
## export has no system fallback and prints a tofu box for anything else.
@export var display_name: String = "Prototype"
@export var source: String = "res://assets/kenney/car_kit/race.glb"
@export var blurb: String = ""

## Feel. Never shared between specs; see above.
@export var tuning: CarTuning

## Godot's default of 1.0 kg is unusable and was the first thing M1 had to fix.
@export var mass: float = 1200.0

## Where the built scene goes, and where the game loads it from.
func scene_path() -> String:
	return "res://scenes/car/%s.tscn" % id
