shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

// Draws a tree for its impostor picture (TreeImpostors): its colour unlit, or
// its world-space normal packed into colour, with a transparent background
// wherever nothing is drawn. One material per surface: bark (opaque), leaf
// cards (alpha-scissored) or clumps (flat colour).

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform vec4 tint : source_color = vec4(1.0);
// 0 for opaque surfaces.
uniform float alpha_scissor = 0.0;
uniform bool write_normal = false;

vec3 linear_from_srgb(vec3 colour) {
	return mix(colour / 12.92, pow((colour + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), colour));
}

void fragment() {
	vec4 texel = texture(albedo_texture, UV) * tint;
	if (alpha_scissor > 0.0 && texel.a < alpha_scissor) {
		discard;
	}
	if (write_normal) {
		// Godot flips the normal on back faces here; flip it back so leaf cards
		// keep the crown's normal, as tree_leaf.gdshader does.
		vec3 normal = FRONT_FACING ? NORMAL : -NORMAL;
		vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(normal, 0.0)).xyz);
		// The picture is stored as sRGB; pre-undo that so the packed normal
		// comes out exactly.
		ALBEDO = linear_from_srgb(world_normal * 0.5 + 0.5);
	} else {
		ALBEDO = texel.rgb;
	}
}
