shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

varying vec3 block_point;
varying vec3 block_normal;
varying vec3 block_tint;
varying float block_finish;

float grain(vec3 grid) {
	return fract(dot(fract(grid * vec3(0.143, 0.179, 0.137)), fract(grid.yzx * 0.247 + 0.65)) * 64.73);
}

void vertex() {
	block_point = VERTEX;
	block_normal = NORMAL;
	block_tint = COLOR.rgb;
	block_finish = UV.x;
}

void fragment() {
	vec3 point = block_point + vec3(5.7, 3.2, 6.1);
	float speckle = grain(floor(point * 15.0));

	if (block_finish > 4.5) {
		// Coarse mineral variation and small stepped chips are visible from the play camera.
		vec3 patch_cell = floor(point * vec3(4.3, 2.0, 5.1));
		float patch = grain(patch_cell);
		float large = grain(floor(point * vec3(1.7, 1.0, 2.1)));
		float pits = smoothstep(0.72, 0.98, grain(floor(point * 13.0)));
		float wear = 0.80 + 0.11 * large + 0.17 * patch - 0.065 * pits + 0.045 * speckle;
		ALBEDO = block_tint * wear * mix(vec3(0.98, 1.0, 0.99), vec3(1.04, 1.01, 0.97), patch);
		ROUGHNESS = 0.93 - 0.08 * patch;
		SPECULAR = 0.20;
	} else if (block_finish < 0.5) {
		float patch = grain(floor(point * vec3(3.5, 4.8, 3.5)));
		float strata = grain(floor(point * vec3(1.7, 2.9, 2.1)));
		float pores = smoothstep(0.82, 1.0, speckle) * 0.10;
		float deposit = smoothstep(0.38, 0.90, patch);
		float top = smoothstep(0.0, 1.0, block_normal.y);
		vec3 tone = block_tint * (0.89 + 0.065 * speckle + 0.12 * strata + 0.10 * deposit - pores * 0.55);
		vec3 patina = mix(vec3(0.87, 0.93, 1.06), vec3(1.09, 1.04, 0.91), strata);
		ALBEDO = tone * mix(vec3(1.0), patina, 0.60);
		ROUGHNESS = 0.91 - top * deposit * 0.18;
		SPECULAR = 0.27;
	} else if (block_finish < 1.5 || (block_finish > 2.5 && block_finish < 3.5)) {
		float oxidation = grain(floor(point * 5.4));
		float scratched = smoothstep(0.82, 1.0, grain(floor(point * vec3(1.8, 32.0, 5.0))));
		float bronze = step(2.5, block_finish);
		float clean = mix(0.81, 1.17, oxidation) + 0.05 * speckle + scratched * 0.10;
		ALBEDO = block_tint * clean;
		ROUGHNESS = mix(0.71, 0.43, oxidation);
		METALLIC = mix(0.22, 0.32, bronze);
		SPECULAR = 0.53;
	} else if (block_finish < 2.5) {
		float fiber = grain(floor(point * vec3(1.8, 23.0, 21.0)));
		ALBEDO = block_tint * (0.79 + 0.27 * fiber + 0.09 * speckle);
		ROUGHNESS = 0.86;
		SPECULAR = 0.26;
	} else {
		ALBEDO = block_tint * (0.92 + 0.13 * speckle);
		EMISSION = block_tint * (0.22 + 0.13 * max(0.0, block_normal.y));
		ROUGHNESS = 0.55;
	}
}

