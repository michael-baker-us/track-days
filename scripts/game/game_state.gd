class_name GameState
extends RefCounted

## Which track was picked, and where lap records live. Static so it survives
## the scene change from the title screen into a race without needing an
## autoload registered in project settings.

const RECORDS_PATH := "user://records.cfg"

## Overridable so the test suite can write records somewhere disposable instead
## of polluting the player's real best laps.
static var records_path: String = RECORDS_PATH

const TRACKS := [
	{
		"id": "highland",
		"name": "Highland",
		"blurb": "Long straights, fast sweepers, two climbs",
		"scene": "res://scenes/track/track_highland.tscn",
	},
	{
		"id": "flats",
		"name": "The Flats",
		"blurb": "Flat and technical, two left-handers",
		"scene": "res://scenes/track/track_flats.tscn",
	},
]

static var selected_index: int = 0

## Where Esc out of a race goes. The editor points it at itself so that taking a
## circuit for a lap and coming back does not throw away the edit in progress.
static var return_scene: String = "res://scenes/title.tscn"

## Which custom track the editor should open. Empty means start a new one.
static var editing_id: String = ""

## The shipped circuits followed by whatever the player has built, which is the
## order the title screen lists them in and the order `selected_index` counts
## through. Built-ins come first so their indices never move when a custom track
## is added or deleted.
##
## A shipped track carries a `scene` to instance; a custom one carries a
## `layout` for `TrackBuilder` to build on the spot. `race.gd` is the only place
## that has to care which.
static func all_tracks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.assign(TRACKS)
	for layout in TrackStore.list_layouts():
		out.append({
			"id": layout.id,
			"name": layout.display_name,
			"blurb": describe(layout),
			"layout": layout,
			"custom": true,
		})
	return out

## A one-line summary of a custom circuit for the menu, from the same compile
## the editor uses — so the list cannot claim a length the track does not have.
static func describe(layout: TrackLayout) -> String:
	var compiled := layout.compile()
	if not compiled.ok:
		return "unfinished — press Edit to finish it"
	var result := TrackBuilder.new().measure(compiled.segments)
	var text := "%.0f m, %d corners" % [result.length, compiled.corners.size()]
	if result.peak > 0.5:
		text += ", climbs %.1f m" % result.peak
	return text

static func selected() -> Dictionary:
	var tracks := all_tracks()
	return tracks[clampi(selected_index, 0, tracks.size() - 1)]

## One place that knows how a record is keyed, shared by the tracker that
## writes them and the title screen that displays them.
static func record_key(track_id: String) -> String:
	return "best_%s" % track_id

static func best_lap_for(track_id: String) -> float:
	var cfg := ConfigFile.new()
	if cfg.load(records_path) != OK:
		return 0.0
	return cfg.get_value("records", record_key(track_id), 0.0)

static func save_best_lap(track_id: String, seconds: float) -> void:
	var cfg := ConfigFile.new()
	cfg.load(records_path)
	cfg.set_value("records", record_key(track_id), seconds)
	cfg.save(records_path)
