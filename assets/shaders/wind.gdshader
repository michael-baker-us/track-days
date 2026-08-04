shader_type spatial;
render_mode world_vertex_coords;

// Wind, as a vertex displacement on the scenery that ought to be moving in it.
//
// Until this existed the circuit had exactly one moving thing in it: the car.
// Everything else was nailed down, and a forest that does not move reads as a
// backdrop rather than as a place. This is the cheapest way to fix that — no CPU
// cost, no per-frame script, no new nodes, and it works under the Compatibility
// renderer, which rules out most of the alternatives.
//
// ## Why the vertex arrives in world space
//
// `world_vertex_coords` means `VERTEX` has already been through the model matrix
// when `vertex()` runs. Two things follow, and both are the point:
//
//  - **The lean direction is a world direction.** Props are placed at whatever
//    yaw the road wanted, and without this the same `direction` would blow a
//    different way for every one of them. Wind that changes direction per tree is
//    not wind.
//  - **No inverse transform.** Displacing in model space would mean carrying a
//    world offset back through the instance basis, which is either an `inverse()`
//    per vertex or an assumption that the scale is uniform. Neither is needed.
//
// ## Why the phase comes from the instance and not the vertex
//
// `MODEL_MATRIX[3].xyz` is where this instance stands. **That is the only piece
// of per-instance identity a `MultiMesh` vertex has** — there is no node per tree
// to hang a phase on, and the trees are a `MultiMesh` precisely so that a forest
// costs one draw call.
//
// Taking the phase from `VERTEX` instead would give every vertex of a single tree
// a different phase, and the tree would shear rather than sway. Taking it from
// nothing at all would put an entire forest in lockstep, which reads as the camera
// moving rather than the trees.

// The prop's own albedo, carried across from the `StandardMaterial3D` the Kenney
// mesh arrived with. Nearly all of the kit is untextured flat colour, so a colour
// and the two constants below are usually the whole material — see
// `TrackBuilder._windy`.
uniform vec4 albedo : source_color = vec4(1.0);

// The exception, and it is the one that matters most: the chequered marker flag
// is a 128px texture, and it is the marker the **default** theme uses, so every
// circuit a player draws is lined with them. Skipping textured surfaces would
// have left exactly those flags dead.
//
// No branch and no companion `bool`, because Godot binds opaque white to a
// `sampler2D` nobody assigned. An untextured prop therefore multiplies its colour
// by 1 and is unaffected, which is why this costs the other five props nothing.
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;

// Which way the wind blows, in world XZ. A unit vector; length scales the sway.
uniform vec2 direction = vec2(0.82, 0.57);

// How far the top of the prop travels, **as a fraction of its own height**, so
// one sensible number covers a fourteen-metre tree and a knee-high marker flag.
uniform float sway : hint_range(0.0, 0.3) = 0.035;

// The prop's height in world units. Never zero: it divides.
uniform float reference_height = 1.0;

// How the lean is distributed up the prop. Above 1 holds the bottom still and
// spends the movement near the top, which is what a trunk does and what stops a
// tree looking like it is sliding along the ground.
uniform float bend : hint_range(1.0, 4.0) = 1.7;

uniform float speed = 0.9;

void vertex() {
	// Where this instance stands, and therefore what this vertex's height above
	// its *own* base is. Deliberately not world Y: scenery beside a raised section
	// of circuit stands on ground of its own, and measuring from y = 0 would bend
	// it as though it were buried.
	vec3 base = MODEL_MATRIX[3].xyz;
	float height = max(VERTEX.y - base.y, 0.0);

	// Two incommensurate coefficients, so a line of props along either world axis
	// still comes out of step with itself.
	float phase = dot(base.xz, vec2(0.21, 0.13));
	float t = TIME * speed + phase;
	// Two rates that do not divide into each other, so the motion never settles
	// into a visible loop the way a single sine does.
	float wave = sin(t) * 0.72 + sin(t * 2.37 + 1.31) * 0.28;

	VERTEX.xz += direction * (wave * sway * reference_height
		* pow(height / reference_height, bend));
}

void fragment() {
	// The Kenney kit is untextured, unlit-flat colour at roughness 1 with no
	// metal, so this reproduces the `StandardMaterial3D` it replaces exactly.
	// **Normals are left alone on purpose.** A few centimetres of lean does not
	// change which way a flat face points by anything the eye can find, and
	// recomputing them would cost more than the displacement does.
	ALBEDO = albedo.rgb * texture(albedo_texture, UV).rgb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
