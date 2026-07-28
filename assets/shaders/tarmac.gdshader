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

uniform vec3 base_color : source_color = vec3(0.21, 0.21, 0.22);
uniform vec3 grit_color : source_color = vec3(0.38, 0.38, 0.39);
// Metres per unit of noise. Two octaves ride on this: a broad one that reads as
// patching and wear, and a fine one that is the aggregate itself.
uniform float grain_scale = 5.0;
uniform float grain_amount : hint_range(0.0, 1.0) = 0.55;
uniform float base_roughness : hint_range(0.0, 1.0) = 0.86;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
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

void fragment() {
	vec2 p = world_pos.xz / grain_scale;
	float n = value_noise(p) * 0.55 + value_noise(p * 6.0) * 0.45;
	ALBEDO = mix(base_color, grit_color, n * grain_amount);
	// Rougher where the aggregate sits proud, so the sun picks out the texture
	// instead of leaving one even sheen across the whole width.
	ROUGHNESS = clamp(base_roughness - n * 0.10, 0.0, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.35;
}
