class_name GameState
extends RefCounted

## Which track was picked, and where lap records live. Static so it survives
## the scene change from the title screen into a race without needing an
## autoload registered in project settings.

const RECORDS_PATH := "user://records.cfg"

## Bumped when the shape of the file changes, so a save written by an older build
## can be recognised and rewritten exactly once. See `_migrate`.
const RECORDS_VERSION := 2

## Overridable so the test suite can write records somewhere disposable instead
## of polluting the player's real best laps.
static var records_path: String = RECORDS_PATH

## The three shipped circuits, each cut down from a real one -- Ardennes from
## Spa-Francorchamps, Monte Carlo from Monaco, La Sarthe from Le Mans. See
## `tools/build_track.gd` for how much of each survives a 90-degree tile set.
##
## Names and blurbs are drawn on the title screen, so they stay inside the
## built-in font: no accents, no degree signs. The web export has no system
## fallback and would print a tofu box instead.
const TRACKS := [
	{
		"id": "ardennes",
		"par": {"race|tarmac": 52.23, "race|dirt": 60.18, "race|snow": 71.01, "race_future|tarmac": 49.50, "race_future|dirt": 57.27, "race_future|snow": 67.81},
		"name": "Ardennes",
		"blurb": "A hairpin, a long climb, fast sweepers",
		"scene": "res://scenes/track/track_ardennes.tscn",
	},
	{
		"id": "monte_carlo",
		"par": {"race|tarmac": 42.28, "race|dirt": 49.08, "race|snow": 58.21, "race_future|tarmac": 40.26, "race_future|dirt": 46.86, "race_future|snow": 55.69},
		"name": "Monte Carlo",
		"blurb": "Fourteen tight corners, not one banked",
		"scene": "res://scenes/track/track_monte_carlo.tscn",
	},
	{
		"id": "la_sarthe",
		"par": {"race|tarmac": 65.05, "race|dirt": 75.32, "race|snow": 89.21, "race_future|tarmac": 61.85, "race_future|dirt": 71.84, "race_future|snow": 85.28},
		"name": "La Sarthe",
		"blurb": "Huge straights, chicanes, one big sweeper",
		"scene": "res://scenes/track/track_la_sarthe.tscn",
	},
	{
		"id": "suzuka",
		"par": {"race|tarmac": 38.96, "race|dirt": 45.06, "race|snow": 53.30, "race_future|tarmac": 37.10, "race_future|dirt": 43.05, "race_future|snow": 51.06},
		"name": "Suzuka",
		"blurb": "A figure of eight - the lap bridges over itself",
		"scene": "res://scenes/track/track_suzuka.tscn",
	},
]

## Medals, as multiples of the par time.
##
## A medal is **derived**, never stored: it is the best lap measured against par,
## so there is no new save format, no migration, and no way for a stored medal to
## disagree with the time that earned it. Change these numbers and every medal in
## the game re-evaluates on the spot.
##
## Par is `ParTime.ideal_lap` — a perfect lap on the racing line. The one
## reference for what that is worth in practice is the scripted driver from M10,
## which lapped 0.2% to 5.4% off it using 80% of the car's grip. **Gold is set at
## roughly that pace.**
##
## Honest about the weakness: the spread of that reference is itself several
## percent and circuit-dependent, so gold is harder on some circuits than others.
## Fixing that needs laps driven by people, not by a pursuit controller, and it is
## the same gap that leaves `ParTime.HUMAN_SLACK` unmeasured.
const MEDAL_GOLD := 1.06
const MEDAL_SILVER := 1.15
const MEDAL_BRONZE := 1.30

enum Medal { NONE, BRONZE, SILVER, GOLD }

## Which medal a lap time earns against a par. `NONE` when there is no time yet,
## or no par to measure it against.
static func medal_for(seconds: float, par: float) -> Medal:
	if seconds <= 0.0 or par <= 0.0:
		return Medal.NONE
	if seconds <= par * MEDAL_GOLD:
		return Medal.GOLD
	if seconds <= par * MEDAL_SILVER:
		return Medal.SILVER
	if seconds <= par * MEDAL_BRONZE:
		return Medal.BRONZE
	return Medal.NONE

static func medal_name(medal: Medal) -> String:
	match medal:
		Medal.GOLD:
			return "GOLD"
		Medal.SILVER:
			return "SILVER"
		Medal.BRONZE:
			return "BRONZE"
		_:
			return ""

## Seconds a perfect lap of this circuit would take **in the car being driven**,
## or 0.0 if unknown.
##
## Par is per car as well as per circuit, because the cars are not equally quick:
## the Prototype is 13% faster at the top end and 11% grippier than the Racer, so
## a par computed for one hands the other an easy gold. Medals were always
## specified per car; this is what makes that true rather than nominal.
##
## Shipped circuits carry the numbers in `TRACKS`, keyed by car id, rather than
## working them out: the layouts live in `tools/`, and the game does not depend on
## `tools/` at runtime. The suite recomputes every one and fails if it has
## drifted, which is the same arrangement the generated theme resource has.
static func par_for(
	info: Dictionary, car_id: String = "", surface_id: String = ""
) -> float:
	var want := record_key(car_id, surface_id)
	var par = info.get("par", null)
	if par is float or par is int:
		# A custom circuit, already computed for the car and surface being raced.
		return float(par)
	if par is Dictionary:
		if par.has(want):
			return float(par[want])
		# Nothing baked for this combination: no target rather than a wrong one.
		# A medal against the wrong par is worse than no medal.
		return 0.0
	return 0.0

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
		var facts := _facts(layout)
		out.append({
			"id": layout.id,
			"name": layout.display_name,
			"blurb": String(facts["blurb"]),
			"par": float(facts["par"]),
			"layout": layout,
			"custom": true,
		})
	return out

## A one-line summary of a custom circuit for the menu, from the same compile
## the editor uses — so the list cannot claim a length the track does not have.
static func describe(layout: TrackLayout) -> String:
	return String(_facts(layout)["blurb"])

## The blurb and the par time together, from **one** walk of the circuit.
##
## Both want the same `measure()`, and the menu asks for both for every custom
## track it lists. Computed separately that is two builder walks and two racing
## lines per row, on a screen that is built in one go — so they are computed
## together and the menu pays once.
static func _facts(layout: TrackLayout) -> Dictionary:
	var compiled := layout.compile()
	if not compiled.ok:
		return {"blurb": "unfinished — press Edit to finish it", "par": 0.0}
	var builder := TrackBuilder.new()
	var result := builder.measure(compiled.segments)
	var text := "%.0f m, %d corners" % [result.length, compiled.corners.size()]
	if result.peak > 0.5:
		text += ", climbs %.1f m" % result.peak
	return {
		"blurb": text,
		"par": ParTime.ideal_lap(
			builder.centreline, selected_car_spec(), selected_surface
		),
	}

static func selected() -> Dictionary:
	var tracks := all_tracks()
	return tracks[clampi(selected_index, 0, tracks.size() - 1)]

## A lap time is only comparable to another set in the same car on the same
## surface, so a record is keyed on all three. Both extra dimensions are fixed
## today — there is one car and every circuit is tarmac — but the key carries
## them from the start, because the alternative is migrating three save formats
## (records, sector splits, ghosts) once a garage exists rather than one now.
##
## The track is the *section* and the car and surface are the key, for two
## reasons. Deleting a circuit has to take every time set on it, whatever car
## they were set in, and `erase_section` is exactly that sweep. And ids are drawn
## from `[a-z0-9_]` (`TrackStore.new_id`), so a flat `best_<track>_<car>` could
## not be taken apart again: `best_ardennes_kart` is either the kart on Ardennes
## or the default car on a circuit called "ardennes kart".
const DEFAULT_CAR := "default"
const DEFAULT_SURFACE := "tarmac"

## The garage. Order is the order the title screen offers them in, and the first
## is what a new player drives.
##
## Each entry is a `CarSpec`: which model it is made of and how it drives. The
## geometry is measured out of the model by `tools/build_car.gd` rather than
## written down, so adding a car is a spec and a tuning preset.
const CAR_SPECS := [
	"res://resources/cars/race.tres",
	"res://resources/cars/race_future.tres",
]

static func cars() -> Array[CarSpec]:
	var out: Array[CarSpec] = []
	for path in CAR_SPECS:
		out.append(load(path))
	return out

static func car_spec(car_id: String) -> CarSpec:
	for spec in cars():
		if spec.id == car_id:
			return spec
	return load(CAR_SPECS[0])

## What the next lap is recorded against, and what gets driven.
##
## `selected_car` is a real choice now; `selected_surface` is still a placeholder
## until M17. Both were in the record key from the start so that adding them
## needed no save migration — which is exactly what happened here: a second car
## arrived and every existing record kept meaning what it meant.
static var selected_car: String = DEFAULT_CAR
static var selected_surface: String = DEFAULT_SURFACE

## The spec being driven. `DEFAULT_CAR` is not a car id, it is the "nothing chosen
## yet" value the record key has always used, and it resolves to the first car —
## so a save written before the garage existed keeps its records.
static func selected_car_spec() -> CarSpec:
	return car_spec(selected_car)

static func record_section(track_id: String) -> String:
	return "record:%s" % track_id

## Empty arguments mean "whatever is selected now", which is what a race wants;
## the title screen passes nothing and gets the times it is about to offer.
##
## `|` separates because it cannot appear in an id, so the two halves stay
## recoverable however the ids are named.
static func record_key(car_id: String = "", surface_id: String = "") -> String:
	return "%s|%s" % [
		car_id if not car_id.is_empty() else selected_car,
		surface_id if not surface_id.is_empty() else selected_surface,
	]

## The splits of the best lap live beside the time itself, under the same
## car-and-surface key with a suffix. `|` cannot appear in an id, so the suffix
## cannot be mistaken for part of one — and keeping them in the *same section*
## means `clear_best_lap` still takes everything a circuit accumulated with one
## `erase_section`.
static func sector_key(car_id: String = "", surface_id: String = "") -> String:
	return "%s|sectors" % record_key(car_id, surface_id)

static func best_lap_for(
	track_id: String, car_id: String = "", surface_id: String = ""
) -> float:
	var cfg := _open()
	return cfg.get_value(
		record_section(track_id), record_key(car_id, surface_id), 0.0
	)

static func best_sectors_for(
	track_id: String, car_id: String = "", surface_id: String = ""
) -> PackedFloat32Array:
	var cfg := _open()
	return cfg.get_value(
		record_section(track_id), sector_key(car_id, surface_id),
		PackedFloat32Array()
	)

## The time and its splits are written in one open-and-save, and `splits` is
## required rather than optional, because they describe the same lap and are only
## meaningful together. A new record left beside the previous lap's splits would
## show a live delta against a lap nobody ever drove — and it would look
## plausible, which is the dangerous part. Making the caller produce both is the
## cheapest way to make that state unrepresentable.
static func save_best_lap(
	track_id: String, seconds: float, splits: PackedFloat32Array,
	car_id: String = "", surface_id: String = ""
) -> void:
	var cfg := _open()
	var section := record_section(track_id)
	cfg.set_value(section, record_key(car_id, surface_id), seconds)
	cfg.set_value(section, sector_key(car_id, surface_id), splits)
	cfg.save(records_path)

## Every time set on the circuit, not just the current car's — a deleted circuit
## must not leave a record behind for the next one to inherit.
static func clear_best_lap(track_id: String) -> void:
	var cfg := _open()
	var section := record_section(track_id)
	if not cfg.has_section(section):
		return
	cfg.erase_section(section)
	cfg.save(records_path)

## Whether throttle and brake read how far the trigger is pulled, or treat any
## press as full.
##
## A setting rather than a decision because the brief pulls both ways: the look
## is Horizon Chase, which is arcade and binary, while the mode is Forza's time
## attack, where lifting a fraction out of a hairpin is the skill being tested.
##
## Records are deliberately *not* keyed on it. Analogue is a strict superset —
## a full press is 1.0, so anything driveable in binary is driveable in analogue
## — which means a binary record stays an honest target. The reverse does not
## hold, and a binary-mode player may meet a time they cannot match. That is a
## real cost of offering the choice and it is accepted, not overlooked.
const SETTINGS_SECTION := "settings"
const ANALOGUE_INPUT_KEY := "analogue_input"

## Cached: `car_controller` asks every physics frame, and the answer lives in a
## file. -1 means "not read yet" rather than false, so the stored default of
## *true* is not quietly overridden by an uninitialised variable.
static var _analogue_input: int = -1

static func analogue_input() -> bool:
	if _analogue_input < 0:
		var cfg := _open()
		var on: bool = cfg.get_value(SETTINGS_SECTION, ANALOGUE_INPUT_KEY, true)
		_analogue_input = 1 if on else 0
	return _analogue_input == 1

static func set_analogue_input(on: bool) -> void:
	_analogue_input = 1 if on else 0
	var cfg := _open()
	cfg.set_value(SETTINGS_SECTION, ANALOGUE_INPUT_KEY, on)
	cfg.save(records_path)

## Whether the car makes any noise.
##
## **Off by default, on purpose.** The engine and tyre sounds are synthesised
## (see `docs/architecture.md`) and the honest verdict on them is that they are
## annoying — they are a buzz and a hiss keyed to speed, not a recording of a
## car. Shipping something irritating as the default is worse than shipping
## silence, so the sound is opt-in until it is worth opting out of.
##
## This is a placeholder for a proper audio pass, not a considered preference.
## When the sounds are worth hearing, the default flips here and nothing else
## changes.
const AUDIO_ENABLED_KEY := "audio_enabled"

static var _audio_enabled: int = -1

static func audio_enabled() -> bool:
	if _audio_enabled < 0:
		var cfg := _open()
		var on: bool = cfg.get_value(SETTINGS_SECTION, AUDIO_ENABLED_KEY, false)
		_audio_enabled = 1 if on else 0
	return _audio_enabled == 1

static func set_audio_enabled(on: bool) -> void:
	_audio_enabled = 1 if on else 0
	var cfg := _open()
	cfg.set_value(SETTINGS_SECTION, AUDIO_ENABLED_KEY, on)
	cfg.save(records_path)

## Drops the cached settings so the next read comes off disk again. For the test
## suite, which repoints `records_path` after this class may already have been
## touched — without it a cached answer would outlive the file it came from.
static func forget_cached_settings() -> void:
	_analogue_input = -1
	_audio_enabled = -1

## Loads the save, bringing it up to date first. Every read and write goes
## through here so there is exactly one place that can encounter an old file.
static func _open() -> ConfigFile:
	var cfg := ConfigFile.new()
	if cfg.load(records_path) != OK:
		# No file yet, so it is born current and never looks migratable.
		cfg.set_value("meta", "version", RECORDS_VERSION)
		return cfg
	_migrate(cfg)
	return cfg

## Version 1 kept every time in one `[records]` section under a flat
## `best_<track>` key, one per circuit. Those are all default-car tarmac laps by
## definition — there was nothing else to drive — so they move across without
## having to be interpreted, and the ambiguity that makes the flat key unusable
## in general does not arise, because at version 1 no composite key exists to
## confuse one with.
##
## Saved on the spot rather than left for the next write, so a player who only
## ever reads their records still converts once instead of on every launch.
static func _migrate(cfg: ConfigFile) -> void:
	if int(cfg.get_value("meta", "version", 1)) >= RECORDS_VERSION:
		return
	if cfg.has_section("records"):
		for key in cfg.get_section_keys("records"):
			var track_id := String(key).trim_prefix("best_")
			cfg.set_value(
				record_section(track_id),
				record_key(DEFAULT_CAR, DEFAULT_SURFACE),
				cfg.get_value("records", key, 0.0)
			)
		cfg.erase_section("records")
	cfg.set_value("meta", "version", RECORDS_VERSION)
	cfg.save(records_path)

## Removing a circuit removes its record with it, which is why deletion lives
## here rather than callers reaching for `TrackStore.delete` directly. Ids are
## derived from the display name and handed straight back out by
## `TrackStore.new_id` the moment the file is gone, so a record left behind is
## inherited by the next circuit the player happens to name the same thing —
## the exact thing `TrackStore.ID_PREFIX` exists to prevent across the shipped
## tracks. It cannot live in `TrackStore` itself: that would make the two
## classes reference each other, and this one already calls into it.
static func delete_track(track_id: String) -> void:
	TrackStore.delete(track_id)
	clear_best_lap(track_id)
	# The recording goes for exactly the same reason the time does, and it is the
	# more visible failure of the two: an inherited lap record is a number that
	# is too good, while an inherited ghost is a translucent car driving through
	# the scenery of a circuit it has never seen.
	GhostStore.clear(track_id)
	if editing_id == track_id:
		editing_id = ""
