class_name RoadSurface
extends RefCounted

## What the road is made of, and how much of it the tyres can use.
##
## ## Why this is a race-time choice, not a property of the circuit
##
## `docs/ideas.md` proposed it per circuit — a winter Ardennes, a dirt La Sarthe.
## Racing it is the same thing seen from the other side: the circuit does not
## change, the *conditions* do, and a lap record has been keyed on
## `track|car|surface` since M8 precisely so a time set on one could never be
## compared with a time set on another.
##
## Choosing it beside the car makes that key do its job. The same circuit in the
## same car on snow keeps its own record, its own ghost, its own sector splits and
## its own medal, and none of them can be mistaken for the dry ones.
##
## ## Grip is the whole mechanic
##
## The colours make it read as snow; `grip` makes it *be* snow. Everything else
## about the car is unchanged, which is not laziness but a finding: M2b measured
## that braking here is brake-limited rather than traction-limited — stopping
## distance was byte-identical at grip 1.4, 2.5 and 4.0 — so lowering grip changes
## cornering and leaves braking alone. That is the wrong way round for real snow
## and it is what this physics model does; see `docs/tuning-journal.md`, M17.
##
## `grip` multiplies the tyre friction the car's tuning asks for, so it composes
## with a car rather than overriding it: a grippier car is still grippier on snow.
##
## ## What the tyres leave behind
##
## `mark_always` is the difference between rubber and a rut. On tarmac a tyre only
## marks the road when it is *sliding*, which is why laying rubber means something;
## on anything loose it marks the road simply by rolling over it, and sliding only
## makes the mark stronger. `mark` is what colour that is — dark on tarmac, churned
## brown on dirt, and a blue-grey rut in white snow.
##
## `mark_depth` says whether that mark has a *shape*. Only the loose surfaces do,
## and the distinction is physical rather than decorative: a tyre on dirt or snow
## **displaces material**, so it leaves a trough with a shoulder either side for
## the sun to catch. A tyre on tarmac deposits a film of rubber and moves nothing,
## so a rubber mark standing proud of the road would be a lie visible from every
## angle the light is low at. Tarmac gets a flat mark, which is what the baked
## racing-line rubber already is.
##
## ## Why there is a whole block of look here
##
## `relief`, `stones` and `sparkle` are what stop the loose surfaces reading as
## coloured card. Tarmac really is flat, so describing it with colour noise alone
## is honest and it looks right; dirt and snow are *made of* relief, and with none
## of it the eye has only a tint to go on. They drive the same road shader, which
## bends the surface normal with a procedural height field — see
## `assets/shaders/tarmac.gdshader`.
##
## `field` and `field_amount` carry the condition off the road. A white circuit
## through a green summer field read as a painted road rather than as snow, so the
## outfield comes with it — blended toward, not replaced, so the circuit's theme
## and its hour still show through.

const SURFACES := {
	"tarmac": {
		# Genuinely flat, so it asks for no relief at all. That is what makes the
		# other two feel like different materials rather than different tints.
		"relief": 0.0,
		"relief_scale": 1.6,
		"patch": 0.05,
		"stones": 0.0,
		"sparkle": 0.0,
		"field": Color(0.0, 0.0, 0.0),
		"field_amount": 0.0,
		"mark": Color(0.05, 0.05, 0.06),
		"mark_always": false,
		"mark_depth": false,
		"label": "Dry",
		"grip": 1.0,
		"base": Color(0.21, 0.21, 0.22),
		"grit": Color(0.38, 0.38, 0.39),
		"grain": 0.55,
		"roughness": 0.86,
	},
	"dirt": {
		# Clods and ruts, at about a foot across, plus stones lying loose on top.
		"relief": 2.2,
		"relief_scale": 1.1,
		"patch": 0.22,
		"stones": 0.55,
		"sparkle": 0.0,
		# Racing on dirt through a green summer field looked like a mistake
		# rather than a condition, so the outfield dries out with the road.
		"field": Color(0.44, 0.38, 0.25),
		"field_amount": 0.55,
		"mark": Color(0.24, 0.17, 0.10),
		"mark_always": true,
		"mark_depth": true,
		"label": "Dirt",
		"grip": 0.72,
		"base": Color(0.40, 0.30, 0.20),
		"grit": Color(0.54, 0.43, 0.30),
		# Coarser than tarmac, which is most of what says "loose" without a
		# texture: the grain is the only surface detail the shader has.
		"grain": 0.85,
		"roughness": 0.95,
	},
	"snow": {
		# Drifts rather than clods: softer and much broader, so the surface rolls
		# instead of breaking up. `sparkle` is snow's alone.
		"relief": 1.4,
		"relief_scale": 2.6,
		"patch": 0.12,
		"stones": 0.0,
		"sparkle": 0.85,
		# Snow does not stop at the kerb. Without this the circuit was a white
		# ribbon laid across a lawn, which read as a painted road, not a
		# blizzard.
		"field": Color(0.87, 0.90, 0.95),
		"field_amount": 0.88,
		"mark": Color(0.55, 0.60, 0.70),
		"mark_always": true,
		"mark_depth": true,
		"label": "Snow",
		"grip": 0.5,
		"base": Color(0.84, 0.87, 0.93),
		"grit": Color(0.96, 0.97, 1.0),
		# Nearly smooth and nearly white: snow is flat bright, and grain would
		# read as gravel.
		"grain": 0.3,
		"roughness": 0.94,
	},
}

## The order the title screen cycles them in, driest first.
const ORDER := ["tarmac", "dirt", "snow"]

const DEFAULT := "tarmac"

static func named(surface: String) -> Dictionary:
	return SURFACES.get(surface, SURFACES[DEFAULT])

## How much of the car's own grip is available here, 0 to 1.
static func grip_of(surface: String) -> float:
	return float(named(surface)["grip"])

static func label_of(surface: String) -> String:
	return String(named(surface)["label"])

static func after(surface: String) -> String:
	var at := ORDER.find(surface)
	return String(ORDER[(at + 1) % ORDER.size()]) if at >= 0 else DEFAULT
