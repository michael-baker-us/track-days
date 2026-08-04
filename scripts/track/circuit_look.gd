class_name CircuitLook
extends RefCounted

## What a circuit looks like: an hour paired with a place.
##
## `SkyPreset` says *when* and `SceneryTheme` says *where*, and they are kept
## apart because they compose — a forest can be raced at noon or at midnight. But
## a player choosing between them one at a time is being asked a question about
## lighting rigs, not about circuits. `docs/ideas.md` says as much: "One choice in
## the editor could set both."
##
## So this is the pairing, and it is the only thing anyone picks. The two axes
## stay separate underneath, which is what lets a new look be a line here rather
## than a new preset in each.
##
## It is also what makes `overcast` and `dusk` reachable again. Both were written
## as hours for shipped circuits and then displaced — La Sarthe went to `night`
## once the trackside columns could light it, Suzuka to `storm` — and without a
## pairing to name them they were data nothing could select.

const LOOKS := {
	"bright": {"sky": "noon", "theme": "forest", "label": "Bright forest"},
	"evening": {"sky": "sunset", "theme": "coastal", "label": "Evening coast"},
	"night": {"sky": "night", "theme": "parkland", "label": "Night, lit"},
	"dusk": {"sky": "dusk", "theme": "parkland", "label": "Dusk parkland"},
	"storm": {"sky": "storm", "theme": "meadow", "label": "Storm"},
	"overcast": {"sky": "overcast", "theme": "meadow", "label": "Overcast"},
}

## The order the editor cycles them in, brightest first, so pressing the button
## walks the day rather than jumping about it.
const ORDER := ["bright", "overcast", "storm", "evening", "dusk", "night"]

const DEFAULT := "bright"

## What each shipped circuit looks like. The single place that answers it: before
## this, the hour and the place were listed separately and could disagree about
## which circuits existed.
const BY_TRACK := {
	"ardennes": "bright",
	"monte_carlo": "evening",
	"la_sarthe": "night",
	"suzuka": "storm",
}

static func named(look: String) -> Dictionary:
	return LOOKS.get(look, LOOKS[DEFAULT])

## The look a circuit is built with. `chosen` wins when it names a real look,
## which is how a player's circuit carries its own; otherwise the shipped
## circuits are looked up by name and everything else takes the default.
static func resolve(track_name: String, chosen: String = "") -> Dictionary:
	if LOOKS.has(chosen):
		return LOOKS[chosen]
	return named(String(BY_TRACK.get(track_name, DEFAULT)))

## The *name* of that look rather than its contents.
##
## `resolve` hands back the entry, which is what the sky and the scenery want.
## The colour grade wants the key: a LUT is cached under it and a circuit carries
## it as metadata, and neither can be recovered from a dictionary of three
## strings. Same resolution order, so the two can never disagree about which look
## a circuit has.
static func name_of(track_name: String, chosen: String = "") -> String:
	if LOOKS.has(chosen):
		return chosen
	var by_track := String(BY_TRACK.get(track_name, DEFAULT))
	return by_track if LOOKS.has(by_track) else DEFAULT

static func sky_of(track_name: String, chosen: String = "") -> Dictionary:
	return SkyPreset.named(String(resolve(track_name, chosen)["sky"]))

static func theme_of(track_name: String, chosen: String = "") -> Dictionary:
	return SceneryTheme.named(String(resolve(track_name, chosen)["theme"]))

## The next look in the cycle, so the editor's button has somewhere to go.
static func after(look: String) -> String:
	var at := ORDER.find(look)
	return String(ORDER[(at + 1) % ORDER.size()]) if at >= 0 else String(ORDER[0])
