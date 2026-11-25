shader_type canvas_item;

// The second camera supplies coverage for objects in front of the player.
// Their visible color comes from the same lit room image at every player depth.
uniform sampler2D lit_room : filter_linear, repeat_disable;

void fragment() {
	float cover = texture(TEXTURE, UV).a;
	COLOR = vec4(texture(lit_room, UV).rgb, cover);
}
