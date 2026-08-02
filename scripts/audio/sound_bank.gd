class_name SoundBank
extends RefCounted

## The game's sounds, synthesised.
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

## An engine is a **series of explosions**, not a chord.
##
## The first version of this summed sixteen harmonics of 50 Hz with a
## sub-harmonic underneath. That is structurally what an engine's *spectrum* looks
## like, and it sounded like an organ, because the thing that makes an engine an
## engine is not its spectrum — it is that the sound is a train of sharp pressure
## pulses, one per firing, each ringing through the exhaust and dying before the
## next arrives. Steady sine partials have no pulses in them at all. That is why
## the first listener called it annoying.
##
## So a voice here is built by *placing firings in time*: `FIRINGS` impulses
## across the buffer, each an exponentially decaying resonance. Overlapping tails
## give the continuous body; the impulse edges give the lumpiness; the difference
## between the two voices is entirely how the pulses are shaped.
##
## ## Why there are two voices rather than one
##
## A car that only changes *pitch* reads as a siren. The thing an ear uses to hear
## effort is timbre: on power an engine is bright and harsh, and on a closed
## throttle it is dull, quiet and decays fast. Two buffers, crossfaded by the
## throttle at runtime, get that for the cost of one extra stream — and it is the
## single largest difference between this and the version that got switched off.
##
## ## Looping
##
## Everything below is a function of `fposmod(t - t0, buffer_duration)`, so sample
## `i` and sample `i + FRAMES` are identical by construction and the loop cannot
## click, whatever the resonant frequency is. The noise table is indexed modulo
## the buffer for the same reason: white noise of exactly the buffer's length *is*
## periodic. (The tyre synthesis below uses summed partials instead, which is the
## other way to guarantee it — see the note there.)

## Firings in one buffer. 16 across 0.16 s is a 100 Hz firing rate, which is the
## pitch the ear actually hears; the resonances only colour it. Runtime
## `pitch_scale` of 0.8 to 3.0 puts that between 80 and 300 Hz.
const FIRINGS := 16

## Under power: a high resonance that rings on well past the next firing, a strong
## second mode, and enough combustion noise to be harsh.
##
## The decay figures are the load-bearing ones and they are easy to get an order
## of magnitude wrong. Firings are 10 ms apart here, so a decay of 190 leaves 15%
## of a pulse still sounding when the next arrives — overlapping, which is the
## body of the sound. The first attempt used 26, which leaves 77%: that is not a
## pulse train at all, it is the harmonic stack again with extra steps, and it
## measured as one.
static func engine_load() -> AudioStreamWAV:
	return _engine_voice(240.0, 190.0, 0.55, 0.34, 0.75)

## Trailing throttle: lower, softer, and dying fast enough that the gaps between
## firings open up. That gap is what "off the power" sounds like.
static func engine_overrun() -> AudioStreamWAV:
	return _engine_voice(150.0, 320.0, 0.12, 0.09, 0.52)

## One engine voice, as a train of decaying resonant pulses.
##
## `cyl` is deliberately uneven. Real cylinders do not contribute identically —
## the resulting once-per-cycle wobble is most of what separates an engine from a
## sixteenth-note tone generator, and it repeats every four firings, so it costs
## the loop nothing.
static func _engine_voice(
	resonance: float, decay: float, bite: float, rasp: float, peak: float
) -> AudioStreamWAV:
	var duration := float(ENGINE_FRAMES) / float(MIX_RATE)
	var noise := _noise_table(ENGINE_FRAMES, 20260801)
	var cyl := [1.0, 0.84, 0.97, 0.89]
	var samples := PackedFloat32Array()
	samples.resize(ENGINE_FRAMES)

	for pulse in FIRINGS:
		var fired := duration * float(pulse) / float(FIRINGS)
		var amp: float = cyl[pulse % cyl.size()]
		for i in ENGINE_FRAMES:
			# Wrapped, so a pulse late in the buffer decays into the start of it.
			var dt := fposmod(float(i) / float(MIX_RATE) - fired, duration)
			var env: float = exp(-dt * decay)
			if env < 0.002:
				continue
			var v := sin(TAU * resonance * dt)
			# The second mode decays faster than the first, which is what makes
			# the pulse *open* bright and settle dark rather than being one
			# colour throughout.
			v += bite * sin(TAU * resonance * 2.0 * dt) * env
			v += rasp * noise[i] * env
			samples[i] += amp * v * env

	return _to_wav(_normalised(samples, peak))

## What the tyres are doing to the road, which is not the same sound on all three
## surfaces.
##
## Squeal is a *tarmac* phenomenon — it is the tread stuttering against a hard
## surface, and it is tonal. On dirt the tyre is throwing material, which is
## broadband and much lower; on snow it is packing it, which is quieter and duller
## than either. Playing a squeal on snow was the loudest wrong note in the old
## mix once surfaces existed.
##
## The band is built from a few hundred partials snapped onto the buffer's own
## fundamental rather than from random samples. That is the other way to guarantee
## a seamless loop: every component completes a whole number of cycles inside the
## buffer, so it meets its own start exactly. Summed with scattered phases it is
## indistinguishable from filtered noise by ear.
const TYRE_VOICES := {
	"tarmac": {"low": 900.0, "high": 3300.0, "peaks": [1300.0, 1900.0], "grit": 0.0, "peak": 0.6},
	"dirt": {"low": 220.0, "high": 2400.0, "peaks": [], "grit": 0.5, "peak": 0.62},
	"snow": {"low": 140.0, "high": 1100.0, "peaks": [], "grit": 0.16, "peak": 0.42},
}

static func tyre(surface: String = "tarmac") -> AudioStreamWAV:
	var voice: Dictionary = TYRE_VOICES.get(surface, TYRE_VOICES["tarmac"])
	var base := float(MIX_RATE) / float(TYRE_FRAMES)  # 3.125 Hz
	var samples := PackedFloat32Array()
	samples.resize(TYRE_FRAMES)

	# Deterministic, so rebuilding the resource does not produce a different file
	# every time and the suite can compare a fresh build against the committed one.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260801

	var low: float = voice["low"]
	var high: float = voice["high"]
	var partials := []
	for k in 240:
		var freq: float = low + (high - low) * float(k) / 239.0
		# Snapped onto the buffer's own fundamental, which is what makes it loop.
		freq = round(freq / base) * base
		partials.append([freq, rng.randf_range(0.0, TAU)])

	for i in TYRE_FRAMES:
		var t := float(i) / float(MIX_RATE)
		var v := 0.0
		for p in partials:
			v += sin(TAU * float(p[0]) * t + float(p[1]))
		v /= sqrt(float(partials.size()))
		# Resonances, where the surface has any: they are what make tarmac read
		# as a squeal rather than as static.
		for f: float in (voice["peaks"] as Array):
			v += (0.5 if f < 1500.0 else 0.3) * sin(TAU * f * t)
		samples[i] = v

	# Loose material thrown up by the tread. A noise table of exactly the buffer
	# length is periodic, so this loops for the same reason everything else does.
	var grit: float = voice["grit"]
	if grit > 0.0:
		var noise := _noise_table(TYRE_FRAMES, 20260802)
		for i in TYRE_FRAMES:
			samples[i] += grit * noise[i] * absf(noise[(i * 7) % TYRE_FRAMES])

	var check: Array = (voice["peaks"] as Array).duplicate()
	assert(_periodic(check, base), "tyre partials do not loop")
	return _to_wav(_normalised(samples, voice["peak"]))

## Hitting something. A one-shot, not a loop.
##
## Exists because the barriers became solid: running out of road used to be a
## silent event that simply stopped the car, which reads as the game freezing
## rather than as a crash. Three parts, because an impact is three things at once
## — the thud of mass arriving, the broadband crack of the collision itself, and
## the rail ringing afterwards.
const IMPACT_FRAMES := 5512

static func impact() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(IMPACT_FRAMES)
	var noise := _noise_table(IMPACT_FRAMES, 20260803)

	for i in IMPACT_FRAMES:
		var t := float(i) / float(MIX_RATE)
		# Mass arriving: low, and the slowest of the three to go.
		var v := 0.9 * sin(TAU * 68.0 * t) * exp(-t * 14.0)
		# The crack. Gone in 40 ms, which is what makes it read as a hit rather
		# than as a rush.
		v += 0.8 * noise[i] * exp(-t * 26.0)
		# The rail ringing. Inharmonic on purpose: a metal barrier is not tuned,
		# and two partials a musical interval apart would sound like a chime.
		v += 0.25 * sin(TAU * 430.0 * t) * exp(-t * 9.0)
		v += 0.18 * sin(TAU * 611.0 * t) * exp(-t * 11.0)
		samples[i] = v

	var wav := _to_wav(_normalised(samples, 0.85))
	# The one stream here that must not loop.
	wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return wav

## A fixed field of white noise, exactly the buffer's length.
##
## Indexed modulo that length it is periodic, so it loops seamlessly — the
## restriction that forces the tyre band to be built from partials does not apply
## to a table that *is* the buffer.
static func _noise_table(frames: int, seed_value: int) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out := PackedFloat32Array()
	out.resize(frames)
	for i in frames:
		out[i] = rng.randf_range(-1.0, 1.0)
	return out

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
