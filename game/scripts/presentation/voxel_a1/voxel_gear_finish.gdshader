shader_type spatial;
render_mode specular_schlick_ggx;

uniform vec4 base_tone : source_color = vec4(0.3, 0.3, 0.3, 1.0);
uniform float base_roughness = 0.72;
uniform float metalness = 0.0;
uniform int finish = 0; // Cloth, leather, wood, and worked metal.
varying vec3 mesh_position;

float cell_noise(vec3 p) {
	return fract(sin(dot(p, vec3(91.67, 127.15, 39.84))) * 14653.127);
}

void vertex() {
	mesh_position = VERTEX;
}

void fragment() {
	float pigment = cell_noise(floor(mesh_position * 68.0));
	float age = cell_noise(floor(mesh_position * 12.0));
	float grain = floor(pigment * 4.0) / 3.0 - 0.5;
	float wear = smoothstep(0.73, 0.98, age) * (0.30 + pigment * 0.70);
	float variation = (finish == 0) ? 0.12 : ((finish == 2) ? 0.21 : 0.15);
	if (finish == 2) {
		float wood = cell_noise(floor(mesh_position * vec3(75.0, 75.0, 8.0)));
		grain = mix(grain, floor(wood * 5.0) / 4.0 - 0.5, 0.76);
	}
	vec3 pigment_color = base_tone.rgb * (1.0 + grain * variation + wear * ((finish == 1) ? 0.12 : 0.075));
	float finish_roughness = clamp(base_roughness + grain * 0.16 - wear * 0.085, 0.19, 0.98);
	ALBEDO = pigment_color;
	METALLIC = metalness;
	ROUGHNESS = finish_roughness;
	SPECULAR = (finish == 3) ? 0.60 : ((finish == 1) ? 0.34 : 0.17);
	if (finish == 3) {
		// A small cool sheen from the room opening complements its existing real lights.
		vec3 normal_world = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 view_world = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
		vec3 reflected = reflect(-view_world, normal_world);
		float skylight = pow(max(dot(reflected, normalize(vec3(-0.37, 0.72, 0.58))), 0.0), 5.0);
		float glint = skylight * (1.0 - finish_roughness) * (0.26 + 0.58 * metalness);
		EMISSION = vec3(0.17, 0.22, 0.25) * pigment_color * glint;
	}
}
