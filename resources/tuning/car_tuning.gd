class_name CarTuning
extends Resource

## Every parameter that defines how the car feels, in one swappable resource.
##
## .tres files are plain text, so presets diff cleanly in git and can be
## swapped to A/B two feels back to back. Geometry (wheel positions, radius,
## which wheels steer or drive) stays in car.tscn - that describes the car,
## not how it feels.
##
## Convention: the defaults below ARE the "grippy arcade" baseline, arrived at
## by measurement in docs/tuning-journal.md. Godot only serialises properties
## that differ from a script's defaults, so grippy.tres is intentionally empty
## and every other preset records just its deltas - which makes the diff
## between two feels exactly the set of values that differ.

@export_group("Drivetrain")
@export var engine_force: float = 8000.0
@export var reverse_force: float = 3000.0
## VehicleBody3D brake force saturates around 150 - past that the wheels just
## lock and deceleration is capped by tyre grip instead, which reads as an
## instant stop. Useful range is roughly 20-60.
@export var brake_force: float = 32.0
## Aerodynamic drag. Force grows with speed squared, so this sets top speed
## (where engine force balances it) and makes acceleration taper naturally.
##
## Trimmed from 5.0 to pay for downforce. Loading the tyres harder costs top
## speed through the wheels' own resistance — measured at 8 km/h, 164 down to
## 156 — and drag is the right place to win it back because it dominates at the
## top end and is negligible at low speed: 0-100 moved by 0.03 s.
@export var drag_coefficient: float = 4.2

@export_group("Grip")
## Grip only limits cornering here, not braking: brake_force sits below its
## saturation point so stopping is brake-limited, and measured braking is
## identical (1.62 g) at every grip level tested. That decoupling is what lets
## grip be set purely for how the car turns.
##
## At 1.4/1.7 the car managed 1.3 g and could only hold the circuit's corners at
## 50-64 km/h against a 165 km/h top speed, which made it hard to stay on track.
## These give ~3.6 g, so corners go at 83-108 km/h and the pace flows.
## Rear above front so it washes into mild understeer rather than snapping into
## oversteer.
@export var friction_front: float = 4.0
@export var friction_rear: float = 4.5
## Must stay well below friction_rear, or the handbrake would *add* grip.
@export var handbrake_rear_friction: float = 1.2
@export var handbrake_force: float = 40.0

@export_group("Steering")
@export var max_steer_angle: float = 0.6
@export var steer_speed: float = 4.0
@export var steer_falloff_reference_kmh: float = 200.0

@export_group("Suspension")
## Godot's default stiffness (5.0) is tuned for a far lighter body than 1200 kg
## and lets the chassis sink onto its own collision box, starving the wheels of
## load and traction.
@export var suspension_stiffness: float = 60.0
@export var suspension_max_force: float = 12000.0
@export var suspension_travel: float = 0.2
@export var damping_compression: float = 0.9
@export var damping_relaxation: float = 0.95

@export_group("Stability")
## Virtual anti-roll bar. VehicleBody3D has no roll stiffness of its own, so
## quick steering reversals unload the inside wheels and put the car on two
## wheels. This resists body roll without reducing grip.
@export var antiroll_stiffness: float = 15.0
@export var antiroll_damping: float = 4.0

## Downforce: a force straight down, growing with speed squared.
##
## The single most effective thing for the hills, and it fixed two complaints at
## once. A crest throws the car up at road speed times the grade — 5.5 m/s at
## 150 km/h over Kenney's 12.5% ramp — and this cut the resulting airtime from
## 1.46 s to 0.67 s. It also stopped the car spinning under power at speed:
## sideslip from a light steering input at 150 km/h fell from 34.5 deg to 3.4 deg.
##
## The cost is small and was measured, not assumed: mean cornering grip at
## 110 km/h rose only 2.45 g to 2.54 g, so the car on the flat feels as it did.
## Halving it to 5.0 gave back most of the airtime (1.10 s), so 9.0 it is.
@export var downforce_coefficient: float = 9.0

@export_group("Airborne")
## What the car does with no wheels on the ground, which is where the hills lost
## it. `VehicleBody3D` gives no help here: the anti-roll bar still applies torque
## with no grip to react against, and whatever rotation the car took off with it
## keeps — so a twitch before the crest becomes a crooked landing and a spin.
##
## Measured over Highland's first climb at 150 km/h, steering hard while airborne:
## sideslip on landing went from 18.6 deg to 4.3 deg with these, at no cost to
## cornering grip.
@export var air_level_torque: float = 6.0
@export var air_angular_damping: float = 3.5

@export_group("Camera")
## Camera lives here too: swapping a feel preset should swap how the car is
## framed, since chase distance and FOV kick are a large part of perceived speed.
## Sized against the car, which is only ~2.6 m long: at 7 m back it rendered as
## a speck filling ~3% of screen width. ~4 m puts it nearer 12%, which reads as
## a third-person racer rather than a distant camera drone.
@export var camera_follow_offset: Vector3 = Vector3(0.0, 1.4, -4.2)
@export var camera_look_offset: Vector3 = Vector3(0.0, 0.45, 0.0)
@export var camera_position_lag: float = 4.0
@export var camera_rotation_lag: float = 5.0
@export var camera_base_fov: float = 70.0
@export var camera_max_fov_kick: float = 12.0
## Should track actual top speed so the FOV kick reaches full value there.
@export var camera_fov_reference_kmh: float = 165.0
