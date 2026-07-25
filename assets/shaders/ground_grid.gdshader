shader_type spatial;
render_mode unshaded, cull_back;

uniform float grid_size = 5.0;
uniform float line_width = 0.05;
uniform vec3 base_color : source_color = vec3(0.24, 0.28, 0.24);
uniform vec3 line_color : source_color = vec3(0.85, 0.9, 0.85);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 grid_uv = mod(world_pos.xz, grid_size);
	float line = step(grid_uv.x, line_width) + step(grid_uv.y, line_width);
	ALBEDO = mix(base_color, line_color, clamp(line, 0.0, 1.0));
}
