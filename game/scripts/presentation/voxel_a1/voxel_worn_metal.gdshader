shader_type spatial;
render_mode specular_schlick_ggx;

uniform vec4 base_tone : source_color = vec4(0.37, 0.43, 0.49, 1.0);
uniform float base_roughness = 0.68;
varying vec3 local_position;

float block(vec3 p) {
	return fract(sin(dot(p, vec3(73.7, 123.1, 29.41))) * 12481.125);
}

void vertex() {
	local_position = VERTEX;
}

void fragment() {
	vec3 p = local_position * vec3(21.0, 13.0, 21.0);
	vec3 chip = floor(p);
	float small_cell = block(chip);
	float stain = block(floor(chip * 0.27));
	float wear = step(0.63, stain) * step(0.37, small_cell) * (0.82 + 0.18 * small_cell);
	wear = max(wear, step(0.95, small_cell) * 0.41);
	vec3 extent = abs(local_position);
	float edge = max(min(extent.x, extent.y), max(min(extent.y, extent.z), min(extent.z, extent.x)));
	float exposed = smoothstep(0.29, 0.48, edge);
	float polished = exposed * (1.0 - wear) * (0.56 + small_cell * 0.44);
	float graze = polished * 0.20;
	vec3 metal_tint = base_tone.rgb * (0.93 + 0.14 * small_cell) * COLOR.rgb;
	vec3 oxide = mix(vec3(0.142, 0.067, 0.043), vec3(0.36, 0.18, 0.090), stain);
	vec3 pigment_color = mix(metal_tint + graze * vec3(0.10, 0.10, 0.08), oxide, wear * 0.72);
	ALBEDO = pigment_color;
	METALLIC = mix(0.39 + polished * 0.40, 0.06, wear);
	ROUGHNESS = mix(mix(base_roughness, 0.24, polished), 0.91, wear);
	SPECULAR = mix(0.44, 0.68, polished) * (1.0 - wear * 0.54);
	// Broad reflected sky tint stays on polished facets even between torch pools.
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 world_eye = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float sky = pow(max(dot(reflect(-world_eye, world_normal), normalize(vec3(-0.39, 0.73, 0.59))), 0.0), 6.0);
	EMISSION = vec3(0.15, 0.23, 0.31) * sky * polished * pigment_color;
}
