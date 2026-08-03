class_name CarLights
extends Node3D

## The car's headlights, and when they are on.
##
## ## Why the car needs its own light at all
##
## Every other answer to "the circuit is too dark" lights the *road*: additive
## pools painted on the tarmac, emission in the road material, lamps on the
## columns. None of them light the piece of road the driver is actually looking
## at, which is the twenty metres directly ahead of the car — the lamps are 70 m
## apart, so between two of them there was nothing at all. A pair of headlights is
## the one light that travels with the thing that needs to see.
##
## It is also the only one that moves. A circuit lit entirely by static lamps
## reads as a diorama; a beam that swings across the barrier as the car turns into
## a corner is what makes the dark feel like something the car is driving through.
##
## ## Why the hour is handed to them
##
## The first version worked the hour out for itself, by reading the scene's sun
## and ambient energies and turning on in proportion to how dark that was. It was
## a nicer shape — one rule, no plumbing, automatically right for a circuit nobody
## had thought about — and it was **wrong**, because scene brightness does not
## order the hours. `dusk` deliberately carries an ambient of 1.15, *higher than
## noon's 0.9*, to keep an evening from turning into a silhouette. Summed with its
## sun it is exactly as bright as `sunset`, so a rule reading brightness switched
## the headlights off at the one hour they most obviously belong at.
##
## The preset is the authority, and it says so directly. The circuit carries its
## `headlights` figure as metadata, the same way it carries `road_glow`, and
## `race.gd` hands it over when it drops the car on the grid — beside the line
## that already tints the car's rim light to the sky. Painted circuits work
## because the metadata is written from the *resolved* preset rather than from a
## track id.
##
## ## Why they are not shadow casters
##
## Two shadow-casting spot lights following the camera would be the most expensive
## thing in the frame on a Compatibility-renderer web build, and what they would
## buy is the car's own silhouette thrown down the road in front of it — which is
## wrong anyway, since the beams start ahead of the bodywork.

## How far apart the beams sit, how high, and how far **clear of the nose** they
## are placed. The car's front faces local +Z, and `AHEAD` is added to half the
## body length by `tools/build_car.gd` rather than being an absolute position, so
## a longer car does not end up with its lights inside it.
##
## > The first version put them at z = 1.15 on a body whose nose is at 1.28 — so
## > the beams were **inside the bodywork**, 0.42 m up, pitched only 9 degrees
## > down. From there the cone's lower edge met the road 0.86 m ahead and its
## > centre 2.65 m ahead: a hot patch immediately in front of the car, which is
## > exactly what "it is lighting the tyres, not the track" looks like. Half the
## > cone went above the horizon and lit nothing at all.
const SPACING := 0.44
const HEIGHT := 0.95
const AHEAD := 0.06

## Aimed down, and outward so the pair covers the road's width rather than
## lighting one lane twice.
##
## The numbers are a compromise the geometry forces. A light this low aimed at
## road 30 m away is within a degree of horizontal, so a wide cone always spills
## somewhere: pitched down enough to clear the car, the pool starts about 1.9 m
## ahead of the nose, runs brightest around 8 m, and tapers away down the road.
## That is what a headlight looks like. What it must not do is start *under* the
## car.
const PITCH := -7.0
const SPLAY := 8.0

const RANGE := 70.0
const ANGLE := 42.0
const COLOUR := Color(1.0, 0.96, 0.86)

## What the beams are worth at an hour that asks for everything. The preset's
## figure scales this, so 1.0 is a full night beam and 0.2 is a low sun.
##
## Sized **against the trackside masts**, not on its own. A mast delivers about
## 1.4 to the road; at 6.5 these beams delivered 3.4, so the brightest thing on a
## night circuit was still the patch of road in front of the car and the whole lap
## read as a torch being carried round it. The circuit is lit by the circuit.
const FULL_ENERGY := 2.0

var _beams: Array[SpotLight3D] = []
var _hour := 0.0

func _ready() -> void:
	for child in get_children():
		if child is SpotLight3D:
			_beams.append(child)
	# Applied again here because the hour usually arrives *first*. `race.gd`
	# instances the car, tints its rim and sets its hour, and only then adds it to
	# the tree — so at the moment `set_hour` is called there are no beams
	# collected yet, and a version that only wrote them there did nothing at all
	# in the real game while passing every test, because the suite's car was
	# already in the tree.
	_apply()

## How much headlight this hour asks for, 0 for none. Safe to call before the car
## is in the tree.
func set_hour(strength: float) -> void:
	_hour = maxf(strength, 0.0)
	_apply()

func _apply() -> void:
	for beam in _beams:
		beam.light_energy = FULL_ENERGY * _hour
		# Switched off rather than left at zero energy: a spot light with no
		# energy is still a light the renderer clusters and considers.
		beam.visible = _hour > 0.01
