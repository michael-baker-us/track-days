extends SceneTree

# Bakes resources/audio/*.tres from `SoundBank`.
#
# Thin on purpose, like tools/build_theme.gd: the synthesis lives in
# scripts/audio/sound_bank.gd so the suite can build a fresh copy to compare the
# committed one against without instantiating this script — which extends
# SceneTree, and allocates a whole second one when a test calls `new()` on it.

const OUT_DIR := "res://resources/audio"

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var failed := false
	var bank := [
		["engine_load.tres", SoundBank.engine_load()],
		["engine_overrun.tres", SoundBank.engine_overrun()],
		["impact.tres", SoundBank.impact()],
		["count.tres", SoundBank.count_tone()],
		["go.tres", SoundBank.go_tone()],
		["ui_move.tres", SoundBank.ui_move()],
		["ui_pick.tres", SoundBank.ui_pick()],
		["kerb.tres", SoundBank.kerb()],
	]
	# One scrub per surface: squeal is a tarmac phenomenon, and playing it on snow
	# was the loudest wrong note in the old mix.
	for surface in SoundBank.TYRE_VOICES.keys():
		bank.append(["tyre_%s.tres" % surface, SoundBank.tyre(surface)])
	for pair in bank:
		var stream: AudioStreamWAV = pair[1]
		var err := ResourceSaver.save(stream, OUT_DIR.path_join(pair[0]))
		print("%s: %s (%d frames)" % [
			pair[0], "ok" if err == OK else "FAILED %s" % err,
			stream.data.size() / 2,
		])
		failed = failed or err != OK
	quit(1 if failed else 0)
