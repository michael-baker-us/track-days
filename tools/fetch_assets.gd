extends SceneTree

## Downloads everything `AssetManifest` names, from Poly Haven's public API.
##
##   godot --headless --path . --script tools/fetch_assets.gd
##
## The same split the rest of `tools/` makes: this fetches, the game never runs
## it, and what it fetches is **gitignored**. What gets committed is only what the
## game ships — and, unlike the plan this was written from, that turns out to be
## the same file.
##
## ## There is no downsizing step, and finding that out is why the API came first
##
## The roadmap assumed a 4K source downloaded and reduced locally, the way a
## `.blend` would be. Poly Haven serves **every resolution as its own file** —
## 1K, 2K, 4K and 8K, each already encoded — so asking for 1K is asking for a
## 1.2 MB file rather than downloading 40 MB and throwing most of it away. The
## manifest names the resolution the game ships and this fetches exactly that.
##
## ## Every id is checked against the API, not assumed
##
## An id that does not exist fails here, now, with a name — rather than at import
## time on someone else's machine, months later, with no way to tell whether the
## asset was renamed or never existed.

const API := "https://api.polyhaven.com"
const INTO := "res://assets/polyhaven"
## Which file format each kind of asset is fetched in lives in the manifest, not
## here: a colour map wants JPEG and a sky wants `.hdr`, and the difference is a
## property of the asset rather than of the fetcher.

var _http: HTTPRequest
var _failures: Array[String] = []

func _initialize() -> void:
	_http = HTTPRequest.new()
	root.add_child(_http)
	_run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(INTO))
	var wanted := 0
	var fetched := 0
	var bytes := 0
	for id in AssetManifest.ids():
		var entry: Dictionary = AssetManifest.ASSETS[id]
		var files := await _json("%s/files/%s" % [API, id])
		if files.is_empty():
			_failures.append("%s: no such asset on Poly Haven" % id)
			continue
		# Both platforms' resolutions, since one machine builds both exports.
		var resolutions := {}
		for platform in AssetManifest.MAX_RESOLUTION:
			resolutions[String(entry[platform])] = true
		var kind := AssetManifest.kind_of(String(id))
		for resolution in resolutions:
			for map in kind["maps"]:
				wanted += 1
				var format: String = kind["format"]
				var url: String = files.get(map, {}).get(resolution, {}).get(
					format, {}).get("url", "")
				if url.is_empty():
					_failures.append("%s: no %s at %s" % [id, map, resolution])
					continue
				var to := "%s/%s_%s_%s.%s" % [INTO, id, map, resolution, format]
				var got := await _download(url, to)
				if got <= 0:
					_failures.append("%s: %s at %s would not download"
						% [id, map, resolution])
					continue
				fetched += 1
				bytes += got
				print("  %s %s %s  %.2f MB" % [id, map, resolution, got / 1048576.0])

	print("\nfetched %d of %d files, %.1f MB into %s" % [
		fetched, wanted, bytes / 1048576.0, INTO])
	for failure in _failures:
		printerr("  FAILED %s" % failure)
	# Non-zero on any miss: a half-fetched asset set is worse than none, because
	# the import will succeed on what arrived and the surface will be wrong in a
	# way nobody can see.
	quit(1 if not _failures.is_empty() else 0)

func _json(url: String) -> Dictionary:
	var body := await _fetch(url)
	if body.is_empty():
		return {}
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}

func _download(url: String, to: String) -> int:
	var body := await _fetch(url)
	if body.is_empty():
		return 0
	var file := FileAccess.open(to, FileAccess.WRITE)
	if file == null:
		return 0
	file.store_buffer(body)
	file.close()
	return body.size()

## Named `_fetch` rather than `_get`: `Object._get` is the property-lookup hook
## every Godot object has, and overriding it with a different signature is a
## parse error rather than a subtle bug, which is the good outcome.
##
## One request at a time, deliberately. This runs once when an id is added, the
## files are a megabyte each, and a parallel fetcher against someone else's free
## API is a way to be rate-limited rather than a way to be quick.
func _fetch(url: String) -> PackedByteArray:
	if _http.request(url) != OK:
		return PackedByteArray()
	var result = await _http.request_completed
	# [result, code, headers, body]
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS or int(result[1]) != 200:
		printerr("  %s -> result %d, HTTP %d" % [url, int(result[0]), int(result[1])])
		return PackedByteArray()
	return result[3]
