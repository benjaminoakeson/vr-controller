shader_type spatial;
render_mode unshaded, cull_back, shadows_disabled;

// Reflections rendered from each eye's mirrored position. Showing each eye its
// own image gives the reflection real depth instead of a flat picture.
uniform sampler2D left_eye_reflection : source_color, filter_linear, repeat_disable;
uniform sampler2D right_eye_reflection : source_color, filter_linear, repeat_disable;

void fragment() {
	// The reflection cameras face the viewer, so their images are flipped left to right.
	vec2 mirrored_uv = vec2(1.0 - UV.x, UV.y);
	if (VIEW_INDEX == VIEW_RIGHT) {
		ALBEDO = texture(right_eye_reflection, mirrored_uv).rgb;
	} else {
		ALBEDO = texture(left_eye_reflection, mirrored_uv).rgb;
	}
}
