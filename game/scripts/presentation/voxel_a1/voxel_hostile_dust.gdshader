shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never;

uniform vec4 dust_color : source_color = vec4(0.55, 0.34, 0.21, 0.55);
uniform float progress = 0.0;
uniform float seed = 0.0;

float hash21(vec2 a) {
	return fract(sin(dot(a, vec2(127.1, 311.7))) * 43758.5453123);
}

float cloud(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(cell), hash21(cell + vec2(1.0, 0.0)), f.x),
		mix(hash21(cell + vec2(0.0, 1.0)), hash21(cell + vec2(1.0)), f.x), f.y);
}

void fragment() {
	vec2 voxel_uv = (floor(UV * vec2(23.0, 13.0)) + vec2(0.5)) / vec2(23.0, 13.0);
	vec2 center = voxel_uv - vec2(0.5);
	float field = cloud(voxel_uv * vec2(7.0, 5.0) + vec2(seed, progress * 1.6));
	float grit = hash21(floor(UV * 92.0) + seed);
	float contour = 1.0 - smoothstep(0.10, 0.50, length(center * vec2(1.0, 0.93)) + (0.5 - field) * 0.22);
	ALBEDO = dust_color.rgb * (0.65 + field * 0.49 + grit * 0.12);
	ALPHA = dust_color.a * contour * smoothstep(0.16, 0.64, field) * (1.0 - smoothstep(0.26, 1.0, progress));
}
