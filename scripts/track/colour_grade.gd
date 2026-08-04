class_name ColourGrade
extends RefCounted

## The colour grade a circuit is seen through, as a lookup table.
##
## ## Why a LUT rather than the three dials that were here before
##
## `Environment` offers `adjustment_saturation`, `adjustment_contrast` and
## `adjustment_brightness`, and until now those were the whole grade — one
## `Vector3` per hour in `SkyPreset`. They are real and they were doing work, but
## they are **three global scalars**, and a grade made of global scalars can only
## move the whole image at once. It cannot put warm light in the highlights and
## leave the shadows cool, which is the single operation most responsible for a
## game looking like itself rather than like its engine's default.
##
## `adjustment_color_correction` takes a `Texture3D` and is sampled once per pixel
## in the tonemap pass that is already running. So the expressive version costs
## the same as the weak one.
##
## **It works on the web build**, which is why this is the first step of M18 and
## not a desktop luxury: `Adjustments` are supported under the Compatibility
## renderer. Volumetric fog, SSIL, SDFGI and depth of field are not — grading is
## the one large visual lever that survives the platform.
##
## ## The model is ASC CDL, deliberately
##
## Slope, offset and power per channel, then saturation. That is the colour
## decision list the film industry standardised on, it is four parameters, and it
## is exactly enough:
##
## - `slope` is a **multiply**, so it moves the highlights most and leaves black
##   alone. Per-channel slope is how highlights get their colour.
## - `offset` is an **add**, so it moves the shadows most and washes out as things
##   get brighter. Per-channel offset is how shadows get theirs.
## - `power` is a gamma on the midtones, which is the only one of the three that
##   can move the middle without moving either end.
## - `saturation` last, about a flat channel mean.
##
## Split toning therefore needs no parameters of its own: cool shadows and warm
## highlights *are* an offset that crushes red and a slope that lifts it. An
## earlier draft of this carried `shadow_tint` and `highlight_tint` alongside CDL
## and they were the same two dials under different names.
##
## ## Why saturation is a flat mean and not luminance
##
## Because `Environment` did it that way — Godot's tonemap desaturates toward
## `dot(vec3(1.0), color) * 0.33333` — and every grade below was authored against
## that behaviour. A luminance-weighted mean is more correct and would silently
## re-grade six looks the day it was introduced.
##
## ## Authored and derived grades
##
## `GRADES` holds the looks that have been **art-directed**, which is now all six
## of them. Anything absent is *derived* from the `SkyPreset` scalars it would
## otherwise be graded by, and the conversion is exact — `slope = brightness *
## contrast`, `offset = 0.5 * (1 - contrast)`, which is Godot's own
## brightness-then-contrast arithmetic rearranged.
##
## That fallback is what let the six be graded **one at a time**: an ungraded look
## rendered pixel-identical to how it did before this file existed, so the grading
## system could land in one commit and the art direction in the next. It stays
## because it is still the right answer for a *new* look — a seventh hour renders
## as its scalars say until someone sits down with it — and because the suite
## checks the arithmetic either way.

## Cube resolution. 16 is the low end of what film LUTs use (17 and 33 are the
## common sizes) and it is chosen for the web build: 16 cubed is 4096 texels and
## about 12 KB, against 98 KB at 32. The grades here are smooth — no hard curve
## breaks anywhere — and trilinear filtering carries a smooth grade at this size
## without banding. Revisit only if a grade gains a sharp knee.
const SIZE := 16

## The six looks, art-directed, in the order the day runs — the same order
## `CircuitLook.ORDER` cycles them in, so this file reads as noon to midnight.
##
## Nothing is derived any more. `of()` still falls back to `from_bcs` for a look
## that has none, which is what a *new* look gets before anyone grades it.
const GRADES := {
	# Ardennes at noon. Crisp and sunny without going grimy: the offset crushes
	# red and green further than blue, so the shade under the trees goes cool,
	# and the slope lifts red and green further than blue, so the sunlit tarmac
	# and the kerbs go warm. Mid grey stays almost exactly neutral, which is what
	# keeps the white kit white.
	"bright": {
		"slope": Vector3(1.14, 1.12, 1.06),
		"offset": Vector3(-0.055, -0.045, -0.02),
		"power": Vector3(1.0, 1.0, 1.0),
		"saturation": 1.38,
	},
	# Flat light, and **the one grade here that the three scalars could not have
	# expressed at all.** Overcast has no blacks: light arrives from the whole
	# sky, so nothing is in shadow of anything. That is a *positive* offset — the
	# bottom of the range lifted while the top stays where it is — and contrast
	# below 1 is not the same move, because it drags the highlights down with it
	# and turns an overcast day into a foggy one.
	#
	# So the shadows go milky, the slope comes down a hair to close the range from
	# the other end, and saturation drops below neutral. The tint is the faintest
	# cool, strongest in the lifted shadows, which is the sky being the only light
	# there is. It is the flattest of the six on purpose: it is what the other five
	# are read against.
	"overcast": {
		"slope": Vector3(0.98, 0.985, 1.00),
		"offset": Vector3(0.028, 0.030, 0.036),
		"power": Vector3(1.0, 1.0, 1.0),
		"saturation": 0.94,
	},
	# Suzuka under weather. **Deliberately not a split** — the only look here with
	# no warmth anywhere, because a storm has no warm light source in it. Blue
	# leads the slope and red is crushed hardest by the offset, so both ends of the
	# range go cool and the image reads one cold colour rather than two.
	#
	# The power is what makes it heavy: above 1 it darkens the midtones while black
	# and white stay pinned, so the mass of the frame sinks without the road going
	# to mud or the kit losing its white. Saturation sits well under neutral —
	# already true of the hour it replaces, and the one part of that grade worth
	# keeping.
	"storm": {
		"slope": Vector3(1.03, 1.05, 1.065),
		"offset": Vector3(-0.035, -0.032, -0.026),
		"power": Vector3(1.06, 1.05, 1.04),
		"saturation": 0.86,
	},
	# Monte Carlo at sunset, and the widest split of the daylight hours. Warm light
	# from a low sun against shade lit only by the sky, so the slope *drops* blue
	# below 1 rather than lifting red: the sunset sky already has its red channel
	# at the top of the range, and lifting further would only flatten the gradient
	# it is made of. Warming from the other end costs nothing and keeps the sky.
	#
	# Blue is left almost uncrushed at the bottom, so the crossover lands at about
	# a fifth of the range — everything darker than the road surface goes cool,
	# everything lighter goes warm. Saturation comes **down** from the 1.45 this
	# hour used to carry: at that height the split had nothing left to do, the
	# stands went fluorescent and the white kit went pink.
	"evening": {
		"slope": Vector3(1.12, 1.05, 0.92),
		"offset": Vector3(-0.045, -0.038, -0.005),
		"power": Vector3(1.0, 1.0, 1.0),
		"saturation": 1.26,
	},
	# The blue hour, and the same shape as `night` an hour early. The sun is gone
	# but the sky is still the brightest thing in frame, so the split is centred on
	# **mid grey**: below it everything is sky-lit and cool, above it is the last
	# warm light and the first of the lamps. Green is carried near red rather than
	# left to lag, which is what stops the white kit going magenta under a violet
	# sky. The shadows are lifted well clear of where this hour used to crush them
	# — parkland at dusk that reads as one black shape is not a look, it is a
	# missing one.
	"dusk": {
		"slope": Vector3(1.14, 1.12, 1.08),
		"offset": Vector3(-0.05, -0.048, -0.02),
		"power": Vector3(1.0, 1.0, 1.0),
		"saturation": 1.18,
	},
	# La Sarthe in the small hours, and the strongest statement of the six. The
	# circuit is lit by warm sodium and sits in a deep blue night, so the split is
	# pushed much harder than at noon: blue is barely crushed at the bottom while
	# red and green are, and red leads the slope at the top. The floodlit road
	# reads sodium and everything the lights do not reach reads blue.
	"night": {
		"slope": Vector3(1.26, 1.18, 1.10),
		"offset": Vector3(-0.075, -0.06, -0.02),
		"power": Vector3(1.0, 1.0, 1.0),
		"saturation": 1.22,
	},
}

## Neutral, and the shape every grade takes.
const IDENTITY := {
	"slope": Vector3.ONE,
	"offset": Vector3.ZERO,
	"power": Vector3.ONE,
	"saturation": 1.0,
}

## Built LUTs, kept for the life of the process. A look is a fixed function of its
## name, six exist, and building one is 4096 evaluations — worth doing once rather
## than on every race start, and far too small to be worth evicting.
static var _cache := {}

## The grade for a look: art-directed if anyone has authored it, otherwise
## converted from the `SkyPreset` scalars that used to do this job.
static func of(look: String) -> Dictionary:
	if GRADES.has(look):
		return GRADES[look]
	return from_bcs(SkyPreset.named(String(CircuitLook.named(look)["sky"]))["grade"])

## The exact CDL equivalent of Godot's brightness/contrast/saturation dials.
##
## Godot applies them in that order, brightness as a multiply from black and
## contrast as a lerp about 0.5:
##
##     colour = colour * brightness
##     colour = 0.5 + (colour - 0.5) * contrast
##
## which expands to `colour * (brightness * contrast) + 0.5 * (1 - contrast)` —
## a slope and an offset. The conversion is therefore lossless rather than
## approximate, which is the whole reason the migration can be asserted.
##
## `grade` arrives in `SkyPreset`'s order: saturation, contrast, brightness.
static func from_bcs(grade: Vector3) -> Dictionary:
	var contrast := grade.y
	var brightness := grade.z
	var slope := brightness * contrast
	var offset := 0.5 * (1.0 - contrast)
	return {
		"slope": Vector3(slope, slope, slope),
		"offset": Vector3(offset, offset, offset),
		"power": Vector3.ONE,
		"saturation": grade.x,
	}

## Applies a grade to one colour. The reference implementation: the LUT is this
## function sampled on a cube, and the suite compares the two.
static func apply(colour: Color, grade: Dictionary) -> Color:
	var slope: Vector3 = grade.get("slope", Vector3.ONE)
	var offset: Vector3 = grade.get("offset", Vector3.ZERO)
	var power: Vector3 = grade.get("power", Vector3.ONE)
	var saturation: float = grade.get("saturation", 1.0)

	var v := Vector3(colour.r, colour.g, colour.b)
	# **Deliberately not clamped here.** Godot's own chain clamps nothing between
	# contrast and saturation — only the framebuffer write at the end does — so a
	# dark pixel that an offset takes below zero stays below zero and drags the
	# channel mean down with it. Clamping at this point is a plausible-looking
	# mistake worth about 0.03 in the shadows, which is exactly the range the
	# migration has to be exact in. It cost four failing checks to find.
	v = Vector3(
		v.x * slope.x + offset.x,
		v.y * slope.y + offset.y,
		v.z * slope.z + offset.z,
	)

	# Skipped entirely at the default, which is what keeps a derived grade
	# bit-exact against the three dials it replaced: Godot has no power step, so
	# the only safe version of one is a version that does nothing when unused.
	# When it *is* used, negatives clamp first — a fractional exponent on a
	# negative base is NaN.
	if power != Vector3.ONE:
		v = Vector3(
			pow(maxf(v.x, 0.0), power.x),
			pow(maxf(v.y, 0.0), power.y),
			pow(maxf(v.z, 0.0), power.z),
		)

	# A flat mean, matching Godot's own tonemap rather than being correct. See
	# the class comment.
	var mean := (v.x + v.y + v.z) / 3.0
	v = Vector3(mean, mean, mean).lerp(v, saturation)

	return Color(
		clampf(v.x, 0.0, 1.0), clampf(v.y, 0.0, 1.0), clampf(v.z, 0.0, 1.0)
	)

## The grade sampled onto a cube, as the images the texture is built from.
##
## Laid out the way `adjustment_color_correction` samples it: the incoming colour
## is the texture coordinate, so **red is x, green is y and blue is the slice**.
## Getting that order wrong produces a picture that is graded, plausible and
## channel-swapped, which is why it is stated here rather than left to the loop.
##
## Separate from `lut` so the suite has something to check. `ImageTexture3D` is a
## GPU resource and `get_data` comes back **empty under `--headless`**, where
## there is no rendering server holding it — so a test written against the texture
## can only assert that it exists. This is the same data on the way in.
static func slices(look: String) -> Array[Image]:
	var grade := of(look)
	var out: Array[Image] = []
	var last := float(SIZE - 1)
	for b in SIZE:
		var slice := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGB8)
		for g in SIZE:
			for r in SIZE:
				slice.set_pixel(r, g, apply(
					Color(float(r) / last, float(g) / last, float(b) / last),
					grade
				))
		out.append(slice)
	return out

## The lookup table for a look, built once and cached.
static func lut(look: String) -> ImageTexture3D:
	if _cache.has(look):
		return _cache[look]
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RGB8, SIZE, SIZE, SIZE, false, slices(look))
	_cache[look] = tex
	return tex
