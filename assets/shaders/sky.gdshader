shader_type sky;

// A Horizon Chase sky: flat colour bands, an oversized sun, and stylised cloud
// stripes. No textures, no atmospheric scattering, nothing that needs a probe.
//
// Replaces `ProceduralSkyMaterial`, which was fine and forgettable: it gives a
// smooth two-colour gradient and a small sun disc, and no amount of tuning makes
// that read as anything but a default. The look this game is aiming at treats the
// sky as a graphic — half the frame, banded, with a sun you could point at.
//
// Deliberately cheap, because the web build runs the Compatibility renderer:
// every term here is arithmetic on EYEDIR, there are no loops, no noise textures
// and no derivatives.

group_uniforms colours;
uniform vec3 top_color : source_color = vec3(0.11, 0.36, 0.85);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.82, 0.97);
uniform vec3 ground_color : source_color = vec3(0.34, 0.55, 0.38);
uniform vec3 sun_color : source_color = vec3(1.0, 0.97, 0.86);
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);

group_uniforms shape;
// How high the gradient takes to reach `top_color`. Low values put the whole
// transition near the horizon, which is what makes a sunset read as one.
uniform float horizon_falloff : hint_range(0.05, 2.0) = 0.55;
// Angular radius of the disc, and how far the glow reaches past it. The disc is
// deliberately large — a sun you can see is the point.
uniform float sun_size : hint_range(0.0, 0.5) = 0.07;
uniform float sun_edge : hint_range(0.001, 0.2) = 0.012;
uniform float sun_glow : hint_range(0.0, 1.0) = 0.28;

group_uniforms clouds;
uniform float cloud_amount : hint_range(0.0, 1.0) = 0.45;
// Bands per unit of height, and how hard their edges are. Hard edges are the
// style; softening this towards 1 turns them into haze.
uniform float cloud_bands : hint_range(1.0, 40.0) = 9.0;
uniform float cloud_edge : hint_range(0.01, 1.0) = 0.35;
uniform float cloud_low : hint_range(0.0, 1.0) = 0.04;
uniform float cloud_high : hint_range(0.0, 1.0) = 0.55;

void sky() {
	float height = EYEDIR.y;

	// The gradient, and the ground below it. Both blended rather than clamped so
	// the horizon line itself is soft even though everything above it is banded.
	vec3 col = mix(
		horizon_color, top_color, smoothstep(0.0, horizon_falloff, height)
	);
	col = mix(ground_color, col, smoothstep(-0.04, 0.01, height));

	// The sun. `LIGHT0_DIRECTION` is the way the light travels, so the disc sits
	// opposite it. Drawn even when the light is disabled would be wrong, hence
	// the enabled test — a night preset turns the sun off and must not leave a
	// bright disc hanging in the sky.
	if (LIGHT0_ENABLED) {
		float d = dot(EYEDIR, -LIGHT0_DIRECTION);
		float disc = smoothstep(
			cos(sun_size + sun_edge), cos(sun_size), d
		);
		float glow = pow(max(d, 0.0), 1.0 / max(sun_glow, 0.001));
		col = mix(col, sun_color, clamp(disc + glow * sun_glow, 0.0, 1.0));
	}

	// Cloud stripes: bands in height, pushed around by the direction faced so
	// they are not perfect rings. Confined to a slab above the horizon, because
	// bands running all the way to the zenith read as a fabric rather than as
	// sky.
	float drift = sin(atan(EYEDIR.z, EYEDIR.x) * 2.0) * 0.05;
	float bands = sin((height + drift) * cloud_bands);
	float stripe = smoothstep(1.0 - cloud_edge, 1.0, bands);
	float slab = smoothstep(cloud_low, cloud_low + 0.06, height)
		* (1.0 - smoothstep(cloud_high - 0.15, cloud_high, height));
	col = mix(col, cloud_color, stripe * slab * cloud_amount);

	COLOR = col;
}
