shader_type canvas_item;
render_mode unshaded;

uniform float gate_lift : hint_range(0.0, 1.0) = 0.0;

// Aperture measured in pixels on the original front_station.png.
const vec2 ART_SIZE = vec2(1672.0, 941.0);
const vec2 HUB = vec2(900.0, 376.0);
const float THRESHOLD = 552.0;
const float DOOR_TRAVEL = 367.0;

float aperture_margin(vec2 pixel) {
	float above_hub = max(HUB.y - pixel.y, 0.0) / 186.0;
	float arch_width = 178.0 * sqrt(max(0.0, 1.0 - above_hub * above_hub));
	// The lower part of the vault narrows between the two fixed lanterns.
	float taper = smoothstep(383.0, THRESHOLD, pixel.y);
	float half_width = arch_width - 109.0 * taper;
	return min(min(pixel.y - 190.0, THRESHOLD - pixel.y), half_width - abs(pixel.x - HUB.x));
}

void fragment() {
	if (gate_lift > 0.0) {
		vec2 pixel = UV * ART_SIZE;
		float margin = aperture_margin(pixel);
		if (margin > 0.0) {
			// Reuse the cave stone and paving already lit in the station artwork.
			vec2 wall_uv = (vec2(1405.0, 190.0) + (pixel - vec2(722.0, 190.0)) * vec2(0.46, 0.73)) / ART_SIZE;
			vec3 wall = texture(TEXTURE, wall_uv).rgb * 0.40 + vec3(0.010, 0.014, 0.018);
			float floor_light = smoothstep(448.0, THRESHOLD, pixel.y);
			float near_width = mix(0.43, 0.85, floor_light);
			vec2 floor_uv = vec2(884.0 + (pixel.x - HUB.x) * near_width, 557.0 + (pixel.y - 448.0) * 0.39) / ART_SIZE;
			vec3 paving = texture(TEXTURE, floor_uv).rgb * mix(0.30, 0.83, floor_light);
			vec3 interior = mix(wall, paving, floor_light) * mix(0.64, 1.0, smoothstep(0.0, 21.0, margin));

			vec2 source_pixel = pixel + vec2(0.0, DOOR_TRAVEL * gate_lift);
			float door_margin = aperture_margin(source_pixel);
			vec3 door = texture(TEXTURE, source_pixel / ART_SIZE).rgb;
			float door_mask = smoothstep(0.0, 1.8, door_margin);
			float frame_mask = smoothstep(0.0, 1.6, margin);
			COLOR.rgb = mix(COLOR.rgb, mix(interior, door, door_mask), frame_mask);
		}
	}
}
