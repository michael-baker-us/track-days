shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

// The soft patch of dark under the car.
//
// A shader rather than a texture because the whole thing is one radial falloff,
// and generating it costs nothing next to vendoring an image and an .import file
// for a blurred circle.
//
// `depth_draw_never` matters: this sits a couple of centimetres above the road
// and would otherwise fight the tarmac for the depth buffer at any distance.
// `unshaded` matters for the same reason the ground plane is — a shadow that
// took lighting would go bright in the sun, which is precisely backwards.

uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.55);
// Where the falloff starts and ends, in UV radius. A hard core with a soft edge
// reads as contact; an even gradient reads as fog under the car.
uniform float core : hint_range(0.0, 1.0) = 0.34;
uniform float edge : hint_range(0.0, 1.0) = 0.5;
// Faded from outside as the car leaves the ground.
uniform float fade : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	// The quad is 1x1 in UV, so the centre is (0.5, 0.5) and the radius to a
	// side is 0.5.
	float r = length(UV - vec2(0.5));
	float a = 1.0 - smoothstep(core, edge, r);
	ALBEDO = shadow_color.rgb;
	ALPHA = shadow_color.a * a * fade;
}
