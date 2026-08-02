class_name SceneryTheme
extends RefCounted

## What the land around a circuit is made of: its colour, and how much grows on
## it.
##
## Separate from `SkyPreset` because they answer different questions — one is
## *where* the circuit is, the other is *when* — and the pairs are not fixed. A
## forest can be raced at noon or at night, and Monaco is a harbour at any hour.
## Keeping them apart is what lets four hours and four places make sixteen looks
## rather than four.
##
## ## The prop table is thin, and honestly so
##
## `docs/ideas.md` describes a theme as "a colour palette plus a prop table", and
## the racing kit has exactly two pieces of vegetation — `treeLarge` and
## `treeSmall`. So a theme varies **colour and density**, which is most of the
## effect anyway: a dense dark treeline and a sparse pale one read as different
## countries without either needing a model the kit does not have.

const THEMES := {
	# Deep forest, close to the road. The Ardennes is trees.
	"forest": {
		"ground": Color(0.30, 0.46, 0.33),
		"lines": Color(0.34, 0.51, 0.37),
		"tree_chance": 0.92,
		"tree_scale": 0.68,
	},
	# A harbour: pale dry ground, and almost nothing growing. What stands beside
	# a street circuit is barriers, not woodland.
	"coastal": {
		"ground": Color(0.58, 0.56, 0.46),
		"lines": Color(0.62, 0.60, 0.50),
		"tree_chance": 0.18,
		"tree_scale": 0.55,
	},
	# Open parkland, the Sarthe countryside: grass with stands of trees rather
	# than a wall of them.
	"parkland": {
		"ground": Color(0.36, 0.50, 0.36),
		"lines": Color(0.40, 0.55, 0.40),
		"tree_chance": 0.55,
		"tree_scale": 0.72,
	},
	# The default, and what every circuit looked like before themes existed.
	"meadow": {
		"ground": Color(0.40, 0.54, 0.42),
		"lines": Color(0.44, 0.59, 0.46),
		"tree_chance": 0.8,
		"tree_scale": 0.62,
	},
}

const DEFAULT := "meadow"

## Where each shipped circuit is. Player-drawn circuits take the default until
## the editor offers the choice — which is the same place the hour will be
## offered, since `ideas.md` notes one control could reasonably set both.
const BY_TRACK := {
	"ardennes": "forest",
	"monte_carlo": "coastal",
	"la_sarthe": "parkland",
	"suzuka": "meadow",
}

static func named(theme: String) -> Dictionary:
	return THEMES.get(theme, THEMES[DEFAULT])

static func for_track(track_name: String) -> Dictionary:
	return named(String(BY_TRACK.get(track_name, DEFAULT)))
