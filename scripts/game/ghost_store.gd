class_name GhostStore
extends RefCounted

## Where recorded best laps live: one file per track, car and surface under
## `user://ghosts/`.
##
## Separate files rather than another key in `records.cfg` because a ghost is
## a few hundred kilobytes of binary and `ConfigFile` is a text format that is
## read whole, on every lookup, by the title screen. A record is a number; this
## is a recording, and they want different storage.
##
## The *name* still comes from `GameState`, though, so a ghost is keyed on
## exactly what its lap time is keyed on and the two can never disagree about
## which lap they describe.

const DIR := "user://ghosts"

## Overridable so the test suite writes somewhere disposable, the same way
## `GameState.records_path` and `TrackStore.dir` are.
static var dir: String = DIR

## `record_key` is `<car>|<surface>`, and `|` is not a safe filename character on
## every platform the web export is served to, so it becomes `-` here. The track
## id is already filesystem-safe by construction (`TrackStore.new_id`).
static func path_for(
	track_id: String, car_id: String = "", surface_id: String = ""
) -> String:
	var key := GameState.record_key(car_id, surface_id).replace("|", "-")
	return dir.path_join("%s__%s.ghost" % [track_id, key])

static func save(
	track_id: String, ghost: Ghost, car_id: String = "", surface_id: String = ""
) -> Error:
	if ghost == null or ghost.is_empty():
		return ERR_INVALID_DATA
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f := FileAccess.open(
		path_for(track_id, car_id, surface_id), FileAccess.WRITE
	)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(ghost.to_bytes())
	f.close()
	return OK

## Null when there is no ghost, and equally when there is one that cannot be
## read. A corrupt recording is not worth taking the race scene down for -- the
## lap is still driveable, it just has nothing to chase.
static func load_ghost(
	track_id: String, car_id: String = "", surface_id: String = ""
) -> Ghost:
	var path := path_for(track_id, car_id, surface_id)
	if not FileAccess.file_exists(path):
		return null
	var ghost := Ghost.from_bytes(FileAccess.get_file_as_bytes(path))
	if ghost == null:
		push_warning("Ignoring unreadable ghost: %s" % path)
	return ghost

## Every ghost recorded on a circuit, whatever car it was set in.
##
## Called when a circuit is deleted. Ids are handed straight back out once a file
## is gone, so a recording left behind would be replayed against whatever circuit
## next took the name -- a translucent car driving through scenery on a track it
## has never seen.
static func clear(track_id: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	# The doubled separator is what makes this safe: ids can contain single
	# underscores, so a prefix of `user_foo_` would also match `user_foo_2`'s
	# files and delete a different circuit's ghosts. `user_foo__` cannot.
	var prefix := "%s__" % track_id
	for file in d.get_files():
		if file.begins_with(prefix) and file.ends_with(".ghost"):
			DirAccess.remove_absolute(
				ProjectSettings.globalize_path(dir.path_join(file))
			)
