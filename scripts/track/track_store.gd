class_name TrackStore
extends RefCounted

## Where player-made circuits live: one JSON file per track under `user://`.
##
## JSON rather than `.tres` deliberately. Godot resource files can name a script
## to attach, so loading one is closer to running code than to reading data —
## acceptable for the tuning presets that ship inside the game, wrong for files
## a player can swap with someone else. A layout is a list of grid cells and a
## handful of integers; JSON expresses that exactly, and a corrupt or hostile
## file can do nothing worse than fail to parse.

const DIR := "user://tracks"

## Custom ids are namespaced so a player cannot name a circuit "highland" and
## inherit the shipped track's lap record.
const ID_PREFIX := "user_"

## Overridable so the test suite writes somewhere disposable instead of into the
## player's saved circuits, the same way `GameState.records_path` is.
static var dir: String = DIR

## Newest first, so a track just saved is at the top of the list.
static func list_layouts() -> Array[TrackLayout]:
	var out: Array[TrackLayout] = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for file in d.get_files():
		if not file.ends_with(".json"):
			continue
		var layout := _read(dir.path_join(file))
		if layout != null:
			out.append(layout)
	out.sort_custom(func(a, b): return a.display_name.naturalnocasecmp_to(b.display_name) < 0)
	return out

static func load_layout(id: String) -> TrackLayout:
	return _read(path_for(id))

static func save(layout: TrackLayout) -> Error:
	if layout.id.is_empty():
		layout.id = new_id(layout.display_name)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f := FileAccess.open(path_for(layout.id), FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(layout.to_dict(), "\t"))
	f.close()
	return OK

static func delete(id: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path_for(id)))

static func path_for(id: String) -> String:
	return dir.path_join("%s.json" % id)

## A stable, filesystem-safe id derived from the name, with a counter appended
## only when it would otherwise collide — so renaming a track keeps its id, and
## with it its lap record.
static func new_id(display_name: String) -> String:
	var slug := ""
	for c in display_name.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			slug += c
		elif not slug.ends_with("_"):
			slug += "_"
	slug = slug.strip_edges(true, true).trim_suffix("_")
	if slug.is_empty():
		slug = "track"

	var base := ID_PREFIX + slug
	var candidate := base
	var n := 2
	while FileAccess.file_exists(path_for(candidate)):
		candidate = "%s_%d" % [base, n]
		n += 1
	return candidate

static func _read(path: String) -> TrackLayout:
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	# A hand-edited or truncated file must not take the menu down with it.
	if not (parsed is Dictionary):
		push_warning("Ignoring unreadable custom track: %s" % path)
		return null
	var layout := TrackLayout.from_dict(parsed)
	if layout.id.is_empty():
		layout.id = path.get_file().get_basename()
	return layout
