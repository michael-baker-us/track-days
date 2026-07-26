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

static func selected() -> Dictionary:
	return TRACKS[clampi(selected_index, 0, TRACKS.size() - 1)]

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
