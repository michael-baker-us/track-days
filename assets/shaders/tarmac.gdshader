shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// The drivable surface. Kenney paints the road as one flat mid-grey (0.553),
// which at this scale reads as a poured concrete apron rather than tarmac: too
// light against the near-white kerbs, and perfectly even over a 14 m width, so
// a straight has nothing in it for the eye to measure speed against.
//
// The grain is generated from world position rather than sampled from a texture
// on purpose. The road is built as a ribbon of quads whose UVs are inherited
// from tiles of three different lengths, so any texture tiles at three different
// rates and seams at every join; and the web export is single-threaded, where a
// generated NoiseTexture2D is a thread away from being a problem. World-space
// noise has neither issue and costs no asset.
//
// ## Why the loose surfaces need more than a recolour
//
// Tarmac is genuinely flat, so colour noise is an honest description of it and
// the road reads correctly. Dirt and snow are not flat, and painting them as if
// they were is what made them look like coloured card: a rutted field and a
// snowfield are both *surfaces made of relief*, and with no relief the eye has
// nothing to judge them by except a tint.
//
// So the same height field that tints the road now also **bends its normal**.
// Two extra taps give a gradient, the gradient perturbs the world normal, and
// the scene's own sun does the rest — the near side of every clod and drift
// lights and the far side does not. It is bump mapping with a procedural height
// field, which costs no texture and needs no UVs the road does not have.
//
// `relief` is zero on tarmac. That is the point: the three surfaces run the same
// shader, and tarmac asking for no relief is what makes the other two feel
// different rather than merely differently coloured.
//
// `sparkle` is snow's alone, and it is not drawn as glitter. It punches holes of
// low roughness through the surface, so what you see are real specular
// highlights from the real sun, appearing and vanishing as the camera moves.
// Drawn as emission they would sit on the snow like confetti and would be just as
// bright at midnight.

uniform vec3 base_color : source_color = vec3(0.21, 0.21, 0.22);
uniform vec3 grit_color : source_color = vec3(0.38, 0.38, 0.39);
// Metres per unit of noise. Two octaves ride on this: a broad one that reads as
// patching and wear, and a fine one that is the aggregate itself.
uniform float grain_scale = 5.0;
uniform float grain_amount : hint_range(0.0, 1.0) = 0.55;
uniform float base_roughness : hint_range(0.0, 1.0) = 0.86;

// How hard the height field bends the normal. 0 leaves the road perfectly flat.
uniform float relief : hint_range(0.0, 4.0) = 0.0;
// Metres per unit of the *relief* field, kept apart from `grain_scale` because
// what you see the shape of is bigger than what you see the speckle of: clods and
// drifts are a foot across, aggregate is a centimetre.
uniform float relief_scale = 1.6;
// Broad, slow variation over tens of metres — worn patches, drifted banks —
// applied as a brightness rather than a second colour.
uniform float patch_scale = 26.0;
uniform float patch_amount : hint_range(0.0, 0.6) = 0.0;
// Loose stones scattered on dirt: small, lighter, and rougher than what is
// around them.
uniform float stones : hint_range(0.0, 1.0) = 0.0;
// Snow's specular glinting, as holes of low roughness rather than added light.
uniform float sparkle : hint_range(0.0, 1.0) = 0.0;
// How much the road lifts itself out of the dark, as emission.
//
// Zero in daylight. At the dark hours it is the *floor* under the lighting rig:
// the lamps shape the road and the glow guarantees there is a road there to
// shape. Emission rather than a raised ambient because ambient lifts everything
// — the sky, the field, the barriers — and turns night into an overcast
// afternoon, while this lifts only the surface being driven on.
uniform float glow : hint_range(0.0, 1.0) = 0.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// Kept to small constants and a couple of multiplies. The usual
// sin(dot(p, ...)) * 43758.5 hash bands visibly at mediump, which is what the
// fragment stage gets on some of the hardware a web build lands on.
float hash(vec2 p) {
	vec2 h = fract(p * vec2(233.34, 851.73));
	h += dot(h, h + 23.45);
	return fract(h.x * h.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
		u.y
	);
}

// The shape of the surface, in arbitrary units. Two octaves: the lumps and the
// grit riding on them.
float height(vec2 world_xz) {
	vec2 p = world_xz / relief_scale;
	return value_noise(p) * 0.7 + value_noise(p * 3.7) * 0.3;
}

void fragment() {
	vec2 p = world_pos.xz / grain_scale;
	float n = value_noise(p) * 0.55 + value_noise(p * 6.0) * 0.45;
	vec3 albedo = mix(base_color, grit_color, n * grain_amount);

	// Broad wear, as a brightness on whatever colour the grain arrived at, so a
	// worn patch is the same material seen in a different state rather than a
	// stain of a second colour laid over it.
	if (patch_amount > 0.0) {
		float broad = value_noise(world_pos.xz / patch_scale);
		albedo *= 1.0 + (broad - 0.5) * 2.0 * patch_amount;
	}

	float roughness = base_roughness - n * 0.10;

	// Loose stones. Cell noise thresholded hard so they read as objects lying on
	// the dirt rather than as more noise in it.
	if (stones > 0.0) {
		float s = hash(floor(world_pos.xz * 7.0));
		float stone = smoothstep(0.93, 0.985, s) * stones;
		albedo = mix(albedo, grit_color * 1.25, stone);
		roughness += stone * 0.05;
	}

	// Snow's glints, as roughness holes for the sun to find.
	if (sparkle > 0.0) {
		float g = hash(floor(world_pos.xz * 130.0));
		roughness -= smoothstep(0.975, 1.0, g) * sparkle * 0.75;
	}

	ALBEDO = albedo;
	// Proportional to the albedo, so a worn patch and a fresh one stay different
	// in the dark rather than flattening into one lit sheet.
	EMISSION = albedo * glow;
	// Rougher where the aggregate sits proud, so the sun picks out the texture
	// instead of leaving one even sheen across the whole width.
	ROUGHNESS = clamp(roughness, 0.02, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.35;

	// Two extra taps rather than four: the centre sample is shared with the
	// gradient, so the finite difference costs one height() per axis. Relief is
	// added to the world normal rather than replacing it, which keeps a banked
	// corner banked — the road is never far from horizontal, and the difference
	// between this and a proper tangent frame is smaller than the bumps are.
	if (relief > 0.0) {
		float e = 0.22;
		float h0 = height(world_pos.xz);
		float hx = height(world_pos.xz + vec2(e, 0.0)) - h0;
		float hz = height(world_pos.xz + vec2(0.0, e)) - h0;
		vec3 bent = normalize(world_normal + vec3(-hx, 0.0, -hz) * relief);
		NORMAL = normalize((VIEW_MATRIX * vec4(bent, 0.0)).xyz);
	}
}
