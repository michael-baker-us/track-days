class_name TyreSpray
extends Node3D

## What the tyres throw into the air, as distinct from what they leave on the
## ground.
##
## `TyreMarks` and this read the **same two fields** out of `RoadSurface` and
## answer opposite halves of one question. `mark_always` says whether a tyre
## displaces material by rolling over it or only by sliding on it; that is the
## whole difference between a dust plume that follows the car everywhere on dirt
## and a puff of smoke that only appears when tarmac is abused. Neither file has
## a table of its own.
##
## ## `CPUParticles3D`, and the constraint is also the simple answer
##
## `GPUParticles3D` under the Compatibility renderer throws WebGL errors with a
## *View Depth* draw order, and particle trails and SDF collision are unsupported
## there at all — so the whole reason to reach for the GPU version is unavailable
## on the build that matters. Four emitters of two dozen particles is nothing to
## a CPU, and it works identically on desktop and in a browser. `draw_order` is
## left at `INDEX` rather than being set to view depth for the same reason.
##
## ## Why the emitters are built here and not baked into the car
##
## Exactly the reasoning `TyreMarks` uses: what the tyres are running on is
## chosen on the title screen, so the colour and the behaviour are not known when
## `tools/build_car.gd` runs. The car scene carries one empty node and this fills
## it in when it enters the tree — which also keeps four particle systems' worth
## of properties out of every committed car scene, where an instance override is
## a trap the project has already been caught by.
##
## ## The emitters do not hang off the wheels, and that was the first attempt
##
## Parenting each emitter to its `VehicleWheel3D` and dropping it by the wheel
## radius looks exactly right and is wrong, because **the wheel node carries the
## roll**. Godot turns that node as the wheel rotates — it is what makes the mesh
## parented to it spin — so at 70 km/h the emitter was orbiting the axle fifty
## times a second, throwing dust in every direction including into the road, and
## a point offset below the axle was only at the contact patch once per
## revolution.
##
## They are children of this node instead, moved to `get_contact_point()` every
## physics frame: the same number `TyreMarks` lays its marks at, so a plume and a
## rut cannot come from different places. Their basis is then the car's, which is
## what makes "up and behind" mean anything. `local_coords` is off, so a plume is
## left behind rather than towed along like a scarf.

## The speed at which a loose surface is throwing up as much as it is going to.
## Not the camera's reference — this is about the tyre rather than about the car,
## and it saturates a long way below top speed because a wheel rolling at 90 km/h
## is already displacing everything it can.
const REFERENCE_KMH := 90.0

## Below this there is nothing to draw, and the emitter is switched off rather
## than run at a ratio nobody can see.
const FLOOR := 0.02

## How long a mote hangs, and how fast it leaves the tyre. Gravity is well under
## the real thing on purpose: dust hangs, and the arc of a correctly-simulated
## grain of dirt is a stone's.
const LIFETIME := 0.6
const SPEED_MIN := 1.8
const SPEED_MAX := 4.0
const GRAVITY := Vector3(0.0, -2.4, 0.0)
const SPREAD := 30.0
## Up and *behind*, the car's forward being -Z.
const THROW := Vector3(0.0, 0.9, 1.0)

## What a sliding tyre makes on a surface with nothing loose on it.
##
## **Not `grit`, and that was found by rendering it.** A loose surface throws up
## the loose material lying on it, which is exactly what `grit` is. Tarmac has
## none, so what comes off a sliding tyre there is not displaced material at all
## — it is burnt rubber, and burnt rubber is pale. Reading `grit` for it drew a
## near-black plume on a near-black road: physically it was the aggregate *in*
## the asphalt, which is a real colour for the road and the wrong one for smoke.
const SMOKE := Color(0.82, 0.82, 0.84)

## What a wet road throws, which is water rather than either of the above:
## paler than smoke and colourless, because the road under it is not what is
## being lifted.
const WATER := Color(0.88, 0.92, 0.96)

## Sized against the **chase camera**, not against a side view. The first pass
## was tuned from a camera six metres away and looked right there; from where the
## game actually sits — 4.2 m behind the car, with the plume immediately in front
## of it — the same motes were half-metre boxes floating over the road.
const AMOUNT := 52
const SIZE_MIN := 0.055
const SIZE_MAX := 0.15
## How much bigger a mote gets over its life. Dust spreads as it slows.
const GROWTH := 1.8

var _car: VehicleBody3D
var _wheels: Array[VehicleWheel3D] = []
var _emitters: Array[CPUParticles3D] = []
## How much loose material this road has on it, 0 to 1: all of it on dirt and
## snow, as much as it is raining on anything else, and none on a dry road. It
## is what decides whether *rolling* throws anything, and holding it as an
## amount rather than as a flag is what lets a drizzle throw less than a
## downpour without a second rule.
var _loose := 0.0
var _rain := 0.0

## Handed over by `race.gd` before the car enters the tree, the way the hour is
## handed to the headlights. The rain belongs to the circuit and the surface
## belongs to the race, and this node is the only thing that needs both.
func set_rain(amount: float) -> void:
	_rain = clampf(amount, 0.0, 1.0)

func _ready() -> void:
	_car = get_parent() as VehicleBody3D
	if _car == null:
		return
	var surface := RoadSurface.named(GameState.selected_surface)
	var loose := bool(surface["mark_always"])
	_loose = 1.0 if loose else _rain
	# Three different things get thrown, and which one it is is not a matter of
	# taste: a loose surface throws itself, a wet one throws water, and a dry
	# hard one throws burnt rubber. Surface first — dirt in the rain is still
	# dirt.
	var thrown: Color = surface["grit"] if loose else (
		WATER if _rain > 0.0 else SMOKE)
	var material := spray_material(thrown)
	for child in _car.get_children():
		if not child is VehicleWheel3D:
			continue
		var wheel := child as VehicleWheel3D
		var puff := _emitter(material)
		# Somewhere sensible until the first contact report arrives.
		puff.position = wheel.position - Vector3(0.0, wheel.wheel_radius, 0.0)
		add_child(puff)
		_wheels.append(wheel)
		_emitters.append(puff)

func _emitter(material: Material) -> CPUParticles3D:
	var puff := CPUParticles3D.new()
	puff.name = "Spray"
	puff.emitting = false
	puff.amount = AMOUNT
	puff.lifetime = LIFETIME
	# World space, so the plume is left behind rather than towed.
	puff.local_coords = false
	puff.direction = THROW.normalized()
	puff.spread = SPREAD
	puff.initial_velocity_min = SPEED_MIN
	puff.initial_velocity_max = SPEED_MAX
	puff.gravity = GRAVITY
	puff.scale_amount_min = SIZE_MIN
	puff.scale_amount_max = SIZE_MAX
	var growth := Curve.new()
	growth.add_point(Vector2(0.0, 1.0 / GROWTH))
	growth.add_point(Vector2(1.0, 1.0))
	puff.scale_amount_curve = growth
	puff.mesh = QuadMesh.new()
	puff.material_override = material
	# Nothing here casts a shadow. A few dozen quads in the atlas would cost the
	# car's own shadow, which is the one that tells a driver where the car is.
	puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return puff

## Billboarded, unshaded and fading out over its life.
##
## **Unshaded on purpose**, and it is the one debatable choice here: the ground
## plane is unshaded for reasons M16 measured, and dust lit by the scene would be
## black at every hour that is not noon. The cost is that a night plume is
## brighter than the night around it. The alternative is worse — a lighting rig
## built for a circuit does not light a cloud convincingly, and the frame would
## simply lose the effect after dusk.
static func spray_material(tint: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Plain camera-facing, not `BILLBOARD_PARTICLES` — that mode is for sprite
	# sheets and wants animation frames this has none of. `keep_scale` is not
	# optional with it: a billboard rebuilds its own basis, and without this every
	# mote comes out at the mesh's 1 m instead of its own size.
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.28)
	# Written to the depth buffer, a cloud of overlapping quads punches holes in
	# whatever is drawn after it.
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return mat

## How hard a tyre is throwing material right now, 0 to 1.
##
## Two ways to reach it, and the surface decides whether the first exists.
##
## **Rolling** displaces whatever is loose on the road and nothing at all on dry
## tarmac, which is `mark_always` — the same field that decides whether a tyre
## marks the road by rolling — plus the rain, which puts something loose on a
## surface that had none. It rises with speed to a saturation point well below
## the car's.
##
## **Sliding** displaces material on every surface, and is deliberately *not*
## gated on speed: a stationary car spinning its wheels is the one place a
## standing plume is exactly right, and gating it would have thrown that away to
## tidy up a case nobody meets.
##
## The two are a maximum rather than a sum. A dirt car sliding at speed is
## already throwing everything the tyre can lift, and adding the two put it at
## twice the density of anything that had been looked at.
func spray_rate(slip: float, speed_kmh: float) -> float:
	var rolling := clampf(speed_kmh / REFERENCE_KMH, 0.0, 1.0) * _loose
	var sliding := clampf(
		(slip - TyreMarks.SLIP_FLOOR) / (1.0 - TyreMarks.SLIP_FLOOR), 0.0, 1.0)
	return maxf(rolling, sliding)

func _physics_process(_delta: float) -> void:
	if _car == null:
		return
	var speed_kmh: float = _car.linear_velocity.length() * 3.6
	for i in _wheels.size():
		var wheel := _wheels[i]
		var puff := _emitters[i]
		var rate := 0.0
		if wheel.is_in_contact():
			rate = spray_rate(
				clampf(1.0 - wheel.get_skidinfo(), 0.0, 1.0), speed_kmh)
			# Left where it was when the wheel is off the ground: the contact
			# point is only meaningful while there is a contact, and a plume
			# should stop rather than follow a jump.
			puff.global_position = wheel.get_contact_point()
		# Weight rather than count. `amount_ratio` — the property that would scale
		# the emission itself — is `GPUParticles3D` only, and the CPU version's
		# `amount` cannot be written every frame because setting it reallocates
		# the particle array and restarts the system, which pops. `color`
		# multiplies each particle's own colour, so the plume thins out as a slide
		# ends instead of stopping dead, and it costs nothing.
		puff.color = Color(1.0, 1.0, 1.0, rate)
		puff.emitting = rate > FLOOR
