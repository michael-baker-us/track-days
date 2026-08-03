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

## What a tyre looks like, which is deliberately **not** per car and not per
## circuit.
##
## Lives here rather than in `tools/build_car.gd` because three places need to
## agree about it: the builder that makes the material, `race.gd` — which tints
## every *other* material on the car to the sky and must leave this one alone —
## and the suite that checks the two have not drifted. A constant duplicated
## across a tool and a runtime script is the kind that goes stale silently.
##
## The wheels used to share the bodywork's material, whose rim light is tinted to
## the sky of the circuit being raced. On bodywork that is a line along the
## silhouette; on a small round black object fresnel covers nearly all of it, so
## the rim became the only colour there and **the tyres came out red at Monte
## Carlo and blue at Ardennes**. Removing the rim outright then left black tyres
## on dark tarmac, which is the opposite problem. This is the middle: a fixed cool
## grey, tight to the silhouette, the same at every hour.
const TYRE_MATERIAL := "colormap_tyre"
const TYRE_RIM := Color(0.72, 0.76, 0.82)
const TYRE_RIM_STRENGTH := 0.30
const TYRE_RIM_POWER := 5.0

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

## What this car actually does, measured on the flat plane by the same rig M1 and
## M2 used. See `docs/tuning-journal.md`, M14.
##
## These are **outcomes, not settings**: `tuning` says how much engine force and
## grip the car is given, and these say what that produced. `ParTime` needs the
## outcomes — a par time is about how fast the car goes, not about the numbers
## that make it go — and deriving them from the tuning would mean reimplementing
## the physics.
##
## They are per car because par is per car. A faster car on the same circuit has
## a faster perfect lap, and medals judged against one car's par would hand the
## other an easy gold.
@export var top_speed_kmh: float = 164.9
@export var lateral_g: float = 3.65
@export var braking_g: float = 1.62
## Acceleration at a standstill, fitted to the measured 0-100 time through
## `A * (1 - (v/v_max)^2)`. See `ParTime`.
@export var launch_accel: float = 9.56

## Where the built scene goes, and where the game loads it from.
func scene_path() -> String:
	return "res://scenes/car/%s.tscn" % id
