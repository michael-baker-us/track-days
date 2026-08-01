class_name SoundBank
extends RefCounted

## The game's two sounds, synthesised.
##
## Lives here rather than in `tools/build_audio.gd` for the same reason
## `UiTheme.build()` does: the tool should place and save, not define. That also
## lets the suite compare the committed resource against a freshly built one
## without instantiating the tool -- which `extends SceneTree`, so calling it
## from a test allocates a second viewport and scenario and leaks them at exit.
##
## ## Why the sound is generated rather than vendored
##
## The Kenney kits are art, not audio, and there was no sound in the project at
## all. Generating it keeps the whole game buildable from what is committed —
## the same reason the theme, the circuits and the car are baked by scripts in
## here — and it means the two sounds can be *tuned against the handling*, which
## is measured, instead of against whatever a downloaded loop happened to be.
##
## ## Why .tres and not .wav
##
## A .wav in the project is an import: Godot writes a .import file and caches the
## converted resource under .godot/, which is neither committed nor stable. An
## `AudioStreamWAV` saved as a resource carries its samples inline, so what is
## committed is exactly what the game loads. Same reasoning as the generated
## scenes.
##
## ## The one rule that makes a loop seamless
##
## Every partial's frequency is an integer multiple of the buffer's own
## fundamental (mix rate / frame count). A component that does not complete a
## whole number of cycles inside the buffer arrives at the loop point mid-swing
## and clicks, once per loop, forever. That is also why the "noise" in the tyre
## squeal is built from a few hundred summed partials rather than from a random
## number generator: random samples cannot be made to meet their own start.


## 22 kHz rather than 44: these are a buzz and a hiss heard over an engine, both
## well under the Nyquist limit here, and the web build downloads every byte.
const MIX_RATE := 22050

## 0.16 s, which makes the buffer's fundamental 6.25 Hz. Every partial below is a
## multiple of that.
const ENGINE_FRAMES := 3528
## 0.32 s: long enough that a repeating hiss does not read as a repeating hiss.
const TYRE_FRAMES := 7056

## A four-stroke-ish buzz: a strong fundamental with a long harmonic tail, and a
## half-frequency component underneath it.
##
## The sub-harmonic is what stops it sounding like an organ. A four-stroke fires
## once every two revolutions, so the pressure pulse that gives an engine its
## lumpiness is at half the shaft frequency — reproducing that is the difference
## between "engine" and "tone".
##
## Runtime pitch comes from `pitch_scale`, so the absolute frequency here only
## sets where the useful range of that multiplier sits.
static func engine() -> AudioStreamWAV:
	var base := float(MIX_RATE) / float(ENGINE_FRAMES)  # 6.25 Hz
	var samples := PackedFloat32Array()
	samples.resize(ENGINE_FRAMES)

	for i in ENGINE_FRAMES:
		var t := float(i) / float(MIX_RATE)
		var v := 0.0
		# Harmonics of 50 Hz. Amplitude falls off slowly, which is what makes it
		# buzz rather than hum; odd harmonics are lifted for a rougher edge.
		for n in range(1, 17):
			var freq := 50.0 * float(n)
			var amp: float = pow(float(n), -0.85)
			if n % 2 == 1:
				amp *= 1.35
			# Phase spread stops every partial peaking together, which would
			# clip the sum into a buzzsaw with no body underneath it.
			v += amp * sin(TAU * freq * t + float(n) * 0.7)
		# The firing pulse, at half the fundamental.
		v += 0.9 * sin(TAU * 25.0 * t)
		samples[i] = v

	assert(_periodic([50.0, 25.0], base), "engine partials do not loop")
	return _to_wav(_normalised(samples, 0.72))

## Tyre scrub: a narrow band of noise with two faint tonal peaks in it.
##
## The "noise" is 240 partials at every multiple of the buffer fundamental
## across the band, each with a scattered phase. Summed, that is
## indistinguishable from filtered noise by ear, and unlike real noise it meets
## its own start exactly — so the loop cannot click.
static func tyre() -> AudioStreamWAV:
	var base := float(MIX_RATE) / float(TYRE_FRAMES)  # 3.125 Hz
	var samples := PackedFloat32Array()
	samples.resize(TYRE_FRAMES)

	# Deterministic, so rebuilding the resource does not produce a different file
	# every time and the suite can compare a fresh build against the committed one.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260801

	var partials := []
	for k in 240:
		# 900 Hz to 3.3 kHz, where tyre scrub lives.
		var freq: float = 900.0 + float(k) * 10.0
		# Snapped onto the buffer's own fundamental, which is what makes it loop.
		freq = round(freq / base) * base
		partials.append([freq, rng.randf_range(0.0, TAU)])

	for i in TYRE_FRAMES:
		var t := float(i) / float(MIX_RATE)
		var v := 0.0
		for p in partials:
			v += sin(TAU * float(p[0]) * t + float(p[1]))
		v /= sqrt(float(partials.size()))
		# Two resonances, so it reads as a tyre rather than as static.
		v += 0.5 * sin(TAU * 1300.0 * t)
		v += 0.3 * sin(TAU * 1900.0 * t)
		samples[i] = v

	assert(_periodic([1300.0, 1900.0], base), "tyre partials do not loop")
	return _to_wav(_normalised(samples, 0.6))

## Fails the build if any partial would not complete whole cycles inside the
## buffer. A click once per loop is the sort of thing that gets shipped, because
## it is inaudible in isolation and maddening underneath an engine.
static func _periodic(freqs: Array, base: float) -> bool:
	for f: float in freqs:
		var cycles: float = f / base
		if absf(cycles - round(cycles)) > 0.0001:
			push_error("%.2f Hz does not loop in this buffer (%.4f cycles)" % [
				f, cycles
			])
			return false
	return true

static func _normalised(samples: PackedFloat32Array, peak: float) -> PackedFloat32Array:
	var loudest := 0.0
	for s in samples:
		loudest = maxf(loudest, absf(s))
	if loudest <= 0.0:
		return samples
	var gain := peak / loudest
	for i in samples.size():
		samples[i] *= gain
	return samples

static func _to_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	# The whole buffer is the loop; there is no attack to preserve.
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = samples.size()
	return wav
