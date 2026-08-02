shader_type spatial;
// Double-sided because the source model's windscreen is single-sided geometry
// and disappears from one side without it. Carried over from the
// `StandardMaterial3D` this replaced, where it was `CULL_DISABLED`.
render_mode cull_disabled;

// The car's paint, plus the one lighting trick this look actually uses.
//
// Everything below the rim term is what `StandardMaterial3D` was already doing:
// one shared material sampling Kenney's palette atlas, nearest-filtered because
// neighbouring swatches are unrelated colours and linear sampling blends them
// into seams along every UV island edge. Metallic zero, roughness one — this is
// flat paint, not a showroom.
//
// The rim is a fresnel edge tinted towards the sky. A car in flat colour against
// a road in flat colour has no silhouette at speed; a bright edge gives it one
// without reflections, without a probe, and without the clearcoat that would pull
// the whole look towards realism (`docs/ideas.md` reverses an earlier instinct
// for exactly that reason).
//
// It is EMISSION rather than a light contribution on purpose: it has to show on
// the shaded side of the car, which is precisely where the silhouette is hardest
// to read.

uniform sampler2D albedo_texture : source_color, filter_nearest_mipmap;
uniform vec4 rim_color : source_color = vec4(0.62, 0.82, 0.97, 1.0);
uniform float rim_strength : hint_range(0.0, 2.0) = 0.35;
// How tightly the rim hugs the edge. Low values wash the whole car; this wants
// to be a line, not a glow.
uniform float rim_power : hint_range(1.0, 8.0) = 3.5;

void fragment() {
	ALBEDO = texture(albedo_texture, UV).rgb;
	METALLIC = 0.0;
	ROUGHNESS = 1.0;

	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	EMISSION = rim_color.rgb * pow(1.0 - facing, rim_power) * rim_strength;
}
