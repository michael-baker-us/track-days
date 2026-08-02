class_name SkyPreset
extends RefCounted

## A time of day: the sun, the sky, the fog and the colour grade, together.
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
## unplayable — so the preset carries a `lit` flag and La Sarthe races under it.
## `dusk` stays, because it is a different hour rather than a stepping stone.

const PRESETS := {
	# The look M8 arrived at, kept as the default so nothing that does not ask
	# for an hour changes.
	"noon": {
		"lit": false,
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
		"lit": false,
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
		"lit": false,
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
		"ambient_energy": 1.15,
		"fog_begin": 260.0,
		"grade": Vector3(1.25, 1.18, 1.02),
	},
	# Le Mans in the small hours, and the reason the trackside columns exist. The
	# only preset with `lit` set: the pools of light they throw are what makes a
	# dark circuit driveable, so night and lit columns arrive together or not at
	# all.
	"night": {
		"lit": true,
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
		# Low enough to read as night, high enough that the road is not guesswork
		# between the lamps. The pools carry the rest.
		"ambient": Color(0.30, 0.34, 0.52),
		"ambient_energy": 0.42,
		"fog_begin": 200.0,
		"grade": Vector3(1.2, 1.22, 1.0),
	},
	# Suzuka in flat morning cloud: no drama, and that is the point of having it —
	# a circuit that reads as weather rather than as an hour.
	"overcast": {
		"lit": false,
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
	"suzuka": "overcast",
}

static func named(preset: String) -> Dictionary:
	return PRESETS.get(preset, PRESETS[DEFAULT])

static func for_track(track_name: String) -> Dictionary:
	return named(String(BY_TRACK.get(track_name, DEFAULT)))
