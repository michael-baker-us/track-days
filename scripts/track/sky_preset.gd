class_name SkyPreset
extends RefCounted

## A time of day: the sun, the sky, the fog, the colour grade — and how dark the
## ground reads — together.
##
## ## Why one struct rather than four settings
##
## They are not independent. A sunset with a noon fog colour has a visible seam
## where the ground plane ends, because fog exists to land that edge into the sky
## and can only do it while it *is* the colour the sky is there. A dark sky with
## noon ambient looks like a mistake rather than an evening. Changing one of these
## without the others is nearly always wrong, so they change together or not at
## all.
##
## ## Why per circuit rather than per session
##
## `docs/ideas.md`: in Horizon Chase every race has its own hour, and that is most
## of why the circuits feel like different places. Three circuits sharing one
## lighting rig look like three parts of one afternoon. Attaching the hour to the
## circuit is what makes Monte Carlo an evening and Ardennes a bright morning
## without either of them needing new art.
##
## ## What is deliberately missing
##
## Nothing, now. `night` was held back until the trackside columns could light
## the road, because a dark circuit with dark lamps is not atmospheric, it is
## unplayable. `dusk` stays, because it is a different hour rather than a stepping
## stone.
##
## ## The lighting rig, which is five numbers rather than one flag
##
## `lit` used to be the whole of it, and it only turned on flat additive discs
## painted on the tarmac. Those light the *road* and nothing else — at night the
## car itself, the barriers and the trees all stayed black, and between two lamps
## the circuit went to guesswork. So each hour now carries a rig:
##
## - `key_energy` / `key_color` / `key_angle` — **the floodlighting**, as a second
##   `DirectionalLight3D` that casts shadows. Not spot lights: a spot goes to zero
##   at its cone edge whatever its attenuation, so cones pointed down at a flat
##   road are discs with dark rims — "a bunch of glowing yellow spots" is what
##   sixty-four of them actually looked like. A real circuit under floodlights is
##   *evenly* lit from many masts at once, which is far closer to a directional
##   light, and this one costs one light and brings shadows with it. The field
##   stays dark because the ground plane is unshaded and receives nothing.
## - `lamp_energy` — the **floodlight masts**: real fixtures standing at the verge
##   on alternating sides, 21 m tall with a lit headframe, each throwing a cone at
##   the road well ahead of itself so consecutive pools overlap end to end. They
##   are what makes a circuit look floodlit rather than merely bright, and they
##   sit *on top of* the key light rather than instead of it — measured, the road
##   under them varies about three to one, which reads as pools rather than as
##   spots.
##   **Set against the hour's own sun, not against the geometry.** A mast delivers
##   `energy * pow(1 - height/range, falloff)` to the road, which for this rig is
##   0.85 of its figure — so these numbers land within sight of the noon sun's
##   1.15, and a night circuit is lit rather than incandescent. Chosen by geometry
##   alone they reached 11.0, which is **33 times the moonlight of the hour they
##   were lighting**, and every surface within reach of a mast blew out to white.
##   Two masts overlap at the midpoints between them, so the delivered figure
##   roughly doubles there; that is the ceiling to keep an eye on.
## - `road_glow` — emission on the road material, and the **floor**: whatever the
##   lamps and the sun are doing, the tarmac never drops below readable. A racing
##   line you cannot see is not a hard circuit, it is a broken one. Kept small,
##   and smaller since the floodlighting became continuous — it is there to stop
##   pure black, not to light the circuit. Emission that does the lighting makes
##   the road look like a lightbox rather than a surface.
## - `headlights` — the car lights the road immediately in front of it. A
##   *detail*, not the light source: when the trackside rig was too sparse to
##   cover the lap, the headlights were the only thing continuously lit and the
##   whole circuit read as a torch beam following the car. Floodlighting is what
##   lights a circuit; headlights are what a car has.
## - `lamp_color` — warm sodium at the evening hours, cold under a storm.

const PRESETS := {
	# The look M8 arrived at, kept as the default so nothing that does not ask
	# for an hour changes.
	"noon": {
		"ground_tint": 1.0,
		# Broad daylight: the sun does all of it.
		"key_energy": 0.0,
		"key_color": Color(1.0, 0.97, 0.92),
		"key_angle": Vector3(-70.0, 25.0, 0.0),
		"lamp_energy": 0.0,
		"lamp_color": Color(1.0, 0.86, 0.62),
		"road_glow": 0.0,
		"headlights": 0.0,
		"silhouette": Color(0.30, 0.42, 0.55),
		"sun_angle": Vector3(-50.0, 35.0, 0.0),
		"sun_color": Color(1.0, 0.96, 0.89),
		"sun_energy": 1.15,
		"top": Color(0.11, 0.36, 0.85),
		"horizon": Color(0.62, 0.82, 0.97),
		"ground": Color(0.34, 0.55, 0.38),
		"sun_disc": Color(1.0, 0.97, 0.86),
		"cloud": Color(1.0, 1.0, 1.0),
		"cloud_amount": 0.45,
		"horizon_falloff": 0.55,
		"sun_size": 0.07,
		"ambient": Color(0.66, 0.70, 0.76),
		"ambient_energy": 0.9,
		"fog_begin": 420.0,
		"grade": Vector3(1.35, 1.10, 1.02),  # saturation, contrast, brightness
	},
	# Monaco in the evening: the sun low over the harbour, the sky going warm at
	# the bottom and deep at the top. The lowest sun angle here, because a long
	# shadow across the road is most of what says "late".
	"sunset": {
		"ground_tint": 0.62,
		# The sun is low but still the light, so the masts are on at a fraction of
		# their night energy — the hour a circuit's floodlights are switched on
		# while the sky is still bright. Monte Carlo races here, and without them
		# it was one of two shipped circuits with no track lighting at all.
		"key_energy": 0.35,
		"key_color": Color(1.0, 0.93, 0.82),
		"key_angle": Vector3(-68.0, 25.0, 0.0),
		"lamp_energy": 0.14,
		"lamp_color": Color(1.0, 0.84, 0.58),
		"road_glow": 0.015,
		"headlights": 0.1,
		"silhouette": Color(0.26, 0.18, 0.34),
		"sun_angle": Vector3(-14.0, 118.0, 0.0),
		"sun_color": Color(1.0, 0.72, 0.42),
		"sun_energy": 1.05,
		"top": Color(0.16, 0.20, 0.52),
		"horizon": Color(0.99, 0.62, 0.36),
		"ground": Color(0.34, 0.30, 0.30),
		"sun_disc": Color(1.0, 0.83, 0.48),
		"cloud": Color(1.0, 0.72, 0.55),
		"cloud_amount": 0.6,
		"horizon_falloff": 0.85,
		"sun_size": 0.11,
		"ambient": Color(0.55, 0.50, 0.60),
		"ambient_energy": 0.85,
		"fog_begin": 300.0,
		"grade": Vector3(1.45, 1.14, 1.0),
	},
	# Le Mans after the light has gone but before it is dark. As close to night as
	# this can get while the trackside columns are still unlit.
	"dusk": {
		"ground_tint": 0.34,
		# The hour lamps are actually for. Real lamps and headlights, but no
		# painted pools: a hard-edged disc of light on the tarmac only reads
		# when the tarmac around it is genuinely dark, and at dusk it is not.
		"key_energy": 0.85,
		"key_color": Color(1.0, 0.92, 0.80),
		"key_angle": Vector3(-70.0, 20.0, 0.0),
		"lamp_energy": 0.24,
		"lamp_color": Color(1.0, 0.86, 0.64),
		"road_glow": 0.03,
		"headlights": 0.3,
		"silhouette": Color(0.10, 0.12, 0.24),
		"sun_angle": Vector3(-8.0, 205.0, 0.0),
		"sun_color": Color(0.62, 0.66, 0.95),
		"sun_energy": 0.75,
		"top": Color(0.05, 0.07, 0.22),
		"horizon": Color(0.35, 0.33, 0.55),
		"ground": Color(0.16, 0.18, 0.22),
		"sun_disc": Color(0.80, 0.82, 1.0),
		"cloud": Color(0.42, 0.42, 0.62),
		"cloud_amount": 0.5,
		"horizon_falloff": 1.1,
		"sun_size": 0.06,
		# Lifted well above the others on purpose: this is the light that stops a
		# dark circuit being an unreadable one, and it is doing the job the
		# lighting columns will do properly later.
		"ambient": Color(0.46, 0.50, 0.68),
		"ambient_energy": 0.55,
		"fog_begin": 260.0,
		"grade": Vector3(1.25, 1.18, 1.02),
	},
	# Le Mans in the small hours, and the reason the trackside columns exist. The
	# only preset with `lit` set: the pools of light they throw are what makes a
	# dark circuit driveable, so night and lit columns arrive together or not at
	# all.
	"night": {
		"ground_tint": 0.22,
		# Everything on. The lamps are the light source, the pools are what they
		# put on the tarmac, and the glow is the floor under both — a circuit you
		# cannot see between the lamps is not atmospheric, it is unplayable.
		"key_energy": 1.25,
		"key_color": Color(1.0, 0.93, 0.82),
		"key_angle": Vector3(-74.0, 18.0, 0.0),
		"lamp_energy": 0.35,
		"lamp_color": Color(1.0, 0.87, 0.66),
		"road_glow": 0.05,
		"headlights": 0.5,
		"silhouette": Color(0.05, 0.06, 0.13),
		# The moon, near enough. Low and cold, and weak enough that the pools of
		# light do the work.
		"sun_angle": Vector3(-32.0, 232.0, 0.0),
		"sun_color": Color(0.55, 0.62, 0.90),
		"sun_energy": 0.28,
		"top": Color(0.015, 0.02, 0.07),
		"horizon": Color(0.10, 0.12, 0.26),
		"ground": Color(0.05, 0.06, 0.09),
		"sun_disc": Color(0.86, 0.90, 1.0),
		"cloud": Color(0.13, 0.15, 0.28),
		"cloud_amount": 0.35,
		"horizon_falloff": 1.2,
		"sun_size": 0.035,
		# Much lower than it was, and that is a *consequence* of the floodlighting
		# working. Ambient is a flat fill: every unit of it is contrast the lights
		# do not get to create, and a night lit mostly by ambient looks like an
		# overcast afternoon with the brightness pulled down. Now that a key light
		# lights the circuit and casts shadows, this only has to keep the shadowed
		# side of things off pure black.
		"ambient": Color(0.30, 0.34, 0.52),
		"ambient_energy": 0.22,
		"fog_begin": 200.0,
		"grade": Vector3(1.2, 1.22, 1.0),
	},
	# Weather, as a **colour treatment** rather than a simulation. Horizon Chase
	# does rain and snow as strong tinted overlays with a matching sky, not as wet
	# surfaces and spray, which is both cheaper and more in keeping.
	#
	# Deliberately *not* a grip change, though `docs/ideas.md` notes that is what
	# would make it a gameplay variant rather than a filter. Grip belongs to the
	# surface, and records are keyed on `track|car|surface` — so lowering it here
	# would make every lap time on this circuit quietly incomparable with every
	# other. That is M17's job, and it has the key to do it with.
	"storm": {
		# Dark for a different reason: it is daytime under a black sky. The lamps
		# are on and cool, the glow does most of the readability work, and there
		# are no pools — the ground is still lit, so a disc on the road would
		# read as a decal rather than as a lamp.
		"key_energy": 0.75,
		"key_color": Color(0.90, 0.94, 1.0),
		"key_angle": Vector3(-72.0, 30.0, 0.0),
		"lamp_energy": 0.22,
		"lamp_color": Color(0.86, 0.90, 1.0),
		"road_glow": 0.04,
		"headlights": 0.25,
		"ground_tint": 0.5,
		"silhouette": Color(0.30, 0.33, 0.36),
		# High and weak: an overcast sky has no direction to it, and a low sun
		# would cast long shadows through cloud that is meant to be solid.
		"sun_angle": Vector3(-70.0, 40.0, 0.0),
		"sun_color": Color(0.78, 0.81, 0.86),
		"sun_energy": 0.5,
		"top": Color(0.26, 0.29, 0.34),
		"horizon": Color(0.52, 0.55, 0.58),
		"ground": Color(0.24, 0.28, 0.26),
		"sun_disc": Color(0.70, 0.73, 0.78),
		"cloud": Color(0.36, 0.39, 0.44),
		# Nearly solid, and dark against a dark sky, so the bands read as weather
		# rather than as decoration.
		"cloud_amount": 0.95,
		"horizon_falloff": 1.6,
		"sun_size": 0.2,
		"ambient": Color(0.60, 0.64, 0.70),
		"ambient_energy": 0.42,
		# The closest fog of any hour: shortening how far you can see is most of
		# what makes weather feel like weather.
		"fog_begin": 120.0,
		# Desaturated and flat, which is the one place this look goes *down* in
		# saturation rather than up.
		"grade": Vector3(0.82, 1.06, 0.98),
	},
	# Suzuka in flat morning cloud: no drama, and that is the point of having it —
	# a circuit that reads as weather rather than as an hour.
	"overcast": {
		"ground_tint": 0.86,
		# Flat and grey rather than dark. Nothing is lit; the road only wants a
		# little lifting out of the murk.
		"key_energy": 0.0,
		"key_color": Color(0.96, 0.97, 1.0),
		"key_angle": Vector3(-70.0, 25.0, 0.0),
		"lamp_energy": 0.0,
		"lamp_color": Color(0.92, 0.94, 1.0),
		"road_glow": 0.02,
		"headlights": 0.0,
		"silhouette": Color(0.52, 0.58, 0.64),
		"sun_angle": Vector3(-62.0, 15.0, 0.0),
		"sun_color": Color(0.92, 0.94, 0.98),
		"sun_energy": 0.8,
		"top": Color(0.55, 0.61, 0.70),
		"horizon": Color(0.80, 0.83, 0.87),
		"ground": Color(0.38, 0.46, 0.40),
		"sun_disc": Color(0.95, 0.96, 1.0),
		"cloud": Color(0.90, 0.92, 0.96),
		"cloud_amount": 0.85,
		"horizon_falloff": 1.4,
		"sun_size": 0.14,
		"ambient": Color(0.72, 0.75, 0.80),
		"ambient_energy": 1.0,
		"fog_begin": 220.0,
		"grade": Vector3(1.1, 1.05, 1.0),
	},
}

const DEFAULT := "noon"

## Which hour each shipped circuit is raced at. Player-drawn circuits take the
## default until the editor offers the choice.
const BY_TRACK := {
	"ardennes": "noon",
	"monte_carlo": "sunset",
	"la_sarthe": "night",
	"suzuka": "storm",
}

static func named(preset: String) -> Dictionary:
	return PRESETS.get(preset, PRESETS[DEFAULT])

static func for_track(track_name: String) -> Dictionary:
	return named(String(BY_TRACK.get(track_name, DEFAULT)))
