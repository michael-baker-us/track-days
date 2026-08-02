shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// What is laid *on* the road rather than what the road is made of: rubber down
// the racing line today, tyre tracks later.
//
// It exists because the road itself cannot carry this. The tarmac is Kenney
// tiles — shared cached meshes, one resource serving every instance of a piece —
// and `_reshape_tiles` only rebuilds the handful that are banked or lifted. To
// give the road a lateral coordinate per vertex, every tile would have to be
// inlined into the scene, which throws away the sharing and bloats every circuit.
//
// A separate ribbon generated from the centreline has the coordinate *by
// construction*: it is built across the road, so "how far along" and "how far
// across" are just its own UVs. That is the coordinate `docs/roadmap.md` M17 asks
// for, and it is the single most reusable thing on that list.
//
// The darkness is baked into vertex colour rather than sampled, so this costs one
// draw call and no texture. `blend_mix` with `depth_draw_never` lays it over the
// tarmac without fighting it, exactly as the light pools and the car's shadow do.

uniform vec4 rubber_color : source_color = vec4(0.05, 0.05, 0.06, 1.0);
uniform float strength : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	ALBEDO = rubber_color.rgb;
	// COLOR.a carries how much rubber is at this vertex, worked out along the
	// racing line when the circuit was built.
	ALPHA = COLOR.a * strength;
}
