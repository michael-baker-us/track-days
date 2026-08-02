shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// The pool of light a trackside column throws onto the road at night.
//
// Additive flat colour rather than a real `OmniLight3D`, for two reasons and
// both matter. A circuit carries twenty-odd columns, and twenty-odd point lights
// is a great deal to ask of the Compatibility renderer the web build is stuck
// with. And a real light produces a smooth falloff gradient — exactly the kind of
// shading this look avoids everywhere else, from the unshaded ground plane to the
// flat-banded sky.
//
// `depth_draw_never` because it lies a few centimetres above the road and must
// not fight it, and `shadows_disabled` because a light pool that cast a shadow
// would be a contradiction.

uniform vec4 pool_color : source_color = vec4(1.0, 0.86, 0.62, 1.0);
uniform float strength : hint_range(0.0, 4.0) = 1.0;
// Where the pool stops being bright and starts fading. A wide core with a short
// edge reads as a lamp; an even gradient reads as mist.
uniform float core : hint_range(0.0, 1.0) = 0.12;

void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	float a = 1.0 - smoothstep(core, 1.0, r);
	// Squared so the centre stays hot while the edge goes quickly, which is what
	// keeps the pools reading as separate lamps rather than as one wash.
	ALBEDO = pool_color.rgb * strength * a * a;
	ALPHA = 1.0;
}
