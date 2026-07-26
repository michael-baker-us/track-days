extends SceneTree

# Bakes the shipped circuits into committed .tscn files.
#
# All the geometry lives in scripts/track/track_builder.gd, which the game also
# calls at runtime to build player-authored tracks. This file is only the two
# layouts plus the save step, so a custom track and a shipped one are made of
# exactly the same thing.
#
# Every layout must close: the builder reports a gap that has to be (0, 0) with
# net +/-4 turns and height back to 0, or the loop does not join up. This script
# exits non-zero if any track fails, so a broken circuit cannot ship silently.

# The original circuit: long straights, fast sweepers, and two climbs. Each
# climb replaces exactly 6 units of straight (ramp 2 + bridge 2 + ramp 2), so
# adding elevation did not require re-solving the layout.
const HIGHLAND := [
	["S", "roadStart", 1],
	["S", "roadStartPositions", 1],
	["S", "roadStraightLong", 6],
	["C", "roadCornerLarger", "right"],
	["S", "roadStraightLong", 4],
	["C", "roadCornerLarge", "right"],
	["S", "roadStraightLong", 3],
	["C", "roadCornerLarge", "left"],
	["S", "roadStraightLong", 2],
	["C", "roadCornerLarge", "right"],
	["S", "roadStraightLong", 3],
	["S", "roadRampLong", 1, 1],
	["S", "roadStraightBridge", 2],
	["S", "roadRampLong", 1, -1],
	["S", "roadStraightLong", 2],
	["C", "roadCornerLarger", "right"],
	["S", "roadStraightLong", 3],
	["S", "roadRampLong", 1, 1],
	["S", "roadStraightBridge", 2],
	["S", "roadRampLong", 1, -1],
	["S", "roadStraightLong", 1],
	["S", "roadStraight", 1],
	["C", "roadCornerLarge", "right"],
	["S", "roadStraightLong", 4],
	["S", "roadStraight", 1],
]

# A flat, tighter circuit: no elevation, shorter straights, and two left-hand
# turns so it does not read as another clockwise oval.
const FLATS := [
	["S", "roadStart", 1],
	["S", "roadStartPositions", 1],
	["S", "roadStraightLong", 4],
	["C", "roadCornerLarger", "right"],
	["S", "roadStraightLong", 3],
	["C", "roadCornerLarge", "right"],
	["S", "roadStraightLong", 4],
	["C", "roadCornerLarge", "left"],
	["S", "roadStraightLong", 3],
	["C", "roadCornerLarger", "right"],
	["S", "roadStraightLong", 7],
	["C", "roadCornerLarge", "right"],
	["S", "roadStraightLong", 5],
	["C", "roadCornerLarge", "right"],
	["S", "roadStraightLong", 2],
	["C", "roadCornerLarge", "left"],
	["S", "roadStraightLong", 2],
	["C", "roadCornerLarge", "right"],
	["S", "roadStraightLong", 3],
]

const TRACKS := {
	"highland": {"file": "res://scenes/track/track_highland.tscn", "layout": HIGHLAND},
	"flats": {"file": "res://scenes/track/track_flats.tscn", "layout": FLATS},
}

func _initialize() -> void:
	var ok := true
	for track_name in TRACKS:
		if not _bake(track_name, TRACKS[track_name]):
			ok = false
	quit(0 if ok else 1)

## Returns false if the layout does not close or the save fails, so a bad
## layout fails loudly rather than silently shipping a circuit with a gap in it.
func _bake(track_name: String, spec: Dictionary) -> bool:
	var builder := TrackBuilder.new()
	var result := builder.build(track_name, spec["layout"])
	var out_path: String = spec["file"]

	print("[%s] closure %s" % [track_name, result.summary()])
	print("road collision: %d triangles" % result.triangles)
	print("checkpoints: %d spaced %.0f m apart" % [
		TrackBuilder.CHECKPOINT_COUNT, result.gate_spacing
	])

	TrackBuilder.set_owner_recursive(result.root, result.root)
	var packed := PackedScene.new()
	packed.pack(result.root)
	var err := ResourceSaver.save(packed, out_path)

	print("       %s | lap %.0f m | peak %.1f m | %s" % [
		out_path.get_file(), result.length, result.peak,
		"saved" if err == OK else "SAVE FAILED %s" % err
	])
	result.root.free()
	return result.closed and err == OK
