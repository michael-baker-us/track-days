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
	for pair in [["engine.tres", SoundBank.engine()], ["tyre.tres", SoundBank.tyre()]]:
		var stream: AudioStreamWAV = pair[1]
		var err := ResourceSaver.save(stream, OUT_DIR.path_join(pair[0]))
		print("%s: %s (%d frames)" % [
			pair[0], "ok" if err == OK else "FAILED %s" % err,
			stream.data.size() / 2,
		])
		failed = failed or err != OK
	quit(1 if failed else 0)
