class_name Ghost
extends RefCounted

## A recorded lap: where the car was and which way it faced, sampled on a fixed
## clock, so it can be replayed alongside the lap being driven now.
##
## ## Why this is straightforward here and would not be elsewhere
##
## `lap_tracker` accumulates in `_physics_process`, which was done so headless
## runs reproduce real lap times. That same decision is what makes a ghost
## honest: the samples are taken on the fixed physics step rather than on render
## frames, so a recording made on a slow machine plays back identically on a fast
## one, and the suite can drive a lap and assert on the result.
##
## ## Sample rate, and a correction to `docs/ideas.md`
##
## Physics runs at **120 Hz**, not the 60 that document assumed, so a two-minute
## lap is ~14,400 ticks rather than 7,200. Recording every tick as position plus
## quaternion would be ~460 KB for one lap of one circuit.
##
## Sampling at 60 Hz halves that, and costs nothing visible: the car is
## interpolated between samples on playback, and at 165 km/h — the measured top
## speed — 60 Hz is a sample every 76 cm. A ghost is a translucent shape seen at
## a distance, not something being collided with.
##
## ## Why it is written as bytes rather than as a resource
##
## Same reasoning as `TrackStore`: a `.tres` can name a script to attach, which
## is wrong for a file players will eventually swap (`docs/roadmap.md`, M11 sends
## these over a share code). This format can do nothing but fail to parse, and
## `from_bytes` is written so it does exactly that rather than half-loading.

const HZ := 60.0
## Position xyz, then rotation as a quaternion xyzw.
const FLOATS_PER_SAMPLE := 7

const MAGIC := 0x48475444  # "TDGH", little-endian
const VERSION := 1
## Magic, version, sample count, then the length of the compressed body.
##
## The body length is in the header purely so a truncated file can be rejected
## by arithmetic. Handing short data to `decompress` works — it fails and the
## size check below catches it — but the engine logs an `ERROR` on the way past,
## and a CI log with expected errors in it is a CI log people stop reading.
const HEADER_BYTES := 16

## A lap over ten minutes is a stuck recording or a hostile file, not a lap. The
## cap exists so a corrupt count cannot ask for a multi-gigabyte allocation
## before anything has had a chance to notice it is wrong.
const MAX_SAMPLES := int(HZ * 600.0)

var samples := PackedFloat32Array()

func count() -> int:
	return samples.size() / FLOATS_PER_SAMPLE

func duration() -> float:
	return maxf(0.0, float(count() - 1)) / HZ

func is_empty() -> bool:
	return count() == 0

func add(t: Transform3D) -> void:
	var q := t.basis.get_rotation_quaternion()
	samples.append_array(PackedFloat32Array([
		t.origin.x, t.origin.y, t.origin.z, q.x, q.y, q.z, q.w,
	]))

## Where the car was `seconds` into the lap, interpolated between samples.
##
## Clamped at both ends rather than wrapping or vanishing: before the start it
## sits on the grid, and a ghost that finished its lap holds the finish line
## while the current lap runs on. Holding is the honest picture — it says "this
## lap was already done by here" — and it avoids a ghost that pops back to the
## start line mid-lap, which reads as a bug whatever the intent.
func pose_at(seconds: float) -> Transform3D:
	var total := count()
	if total == 0:
		return Transform3D()
	var pos := clampf(seconds, 0.0, duration()) * HZ
	var i := clampi(int(floor(pos)), 0, total - 1)
	var j := mini(i + 1, total - 1)
	var frac := pos - float(i)
	return Transform3D(
		Basis(_rotation(i).slerp(_rotation(j), frac)),
		_origin(i).lerp(_origin(j), frac)
	)

func _origin(i: int) -> Vector3:
	var b := i * FLOATS_PER_SAMPLE
	return Vector3(samples[b], samples[b + 1], samples[b + 2])

func _rotation(i: int) -> Quaternion:
	var b := i * FLOATS_PER_SAMPLE
	return Quaternion(
		samples[b + 3], samples[b + 4], samples[b + 5], samples[b + 6]
	).normalized()

## Header, then the samples deflated. Float data does not compress the way text
## does, but a racing line is smooth and neighbouring samples share most of their
## exponent bits, so it is worth the two lines it costs — browser storage is
## finite and the web build is the constrained target.
func to_bytes() -> PackedByteArray:
	var body := samples.to_byte_array().compress(FileAccess.COMPRESSION_DEFLATE)
	var out := PackedByteArray()
	out.resize(HEADER_BYTES)
	out.encode_u32(0, MAGIC)
	out.encode_u32(4, VERSION)
	out.encode_u32(8, count())
	out.encode_u32(12, body.size())
	out.append_array(body)
	return out

## Returns null for anything it does not fully understand, rather than a
## half-populated ghost. A truncated file, a hand-edited one and a file from a
## future version all land here, and a ghost that silently loses its second half
## would look like a driving mistake rather than a broken file.
static func from_bytes(data: PackedByteArray) -> Ghost:
	if data.size() < HEADER_BYTES:
		return null
	if data.decode_u32(0) != MAGIC or data.decode_u32(4) != VERSION:
		return null

	var total := int(data.decode_u32(8))
	if total < 0 or total > MAX_SAMPLES:
		return null

	# Checked before anything is decompressed: a file that is not exactly as long
	# as its own header says is truncated or padded, and saying so here keeps the
	# common corruption off the error log entirely.
	var body_bytes := int(data.decode_u32(12))
	if data.size() != HEADER_BYTES + body_bytes:
		return null

	var floats := total * FLOATS_PER_SAMPLE
	# `decompress` needs the output size up front, which the sample count gives
	# us -- and that is the second check: a body that does not inflate to exactly
	# the length its own header implies is not one of ours.
	var raw := data.slice(HEADER_BYTES).decompress(
		floats * 4, FileAccess.COMPRESSION_DEFLATE
	)
	if raw.size() != floats * 4:
		return null

	var ghost := Ghost.new()
	ghost.samples = raw.to_float32_array()
	return ghost
