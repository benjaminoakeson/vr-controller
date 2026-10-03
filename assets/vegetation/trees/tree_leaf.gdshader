shader_type spatial;
render_mode cull_disabled;

#include "res://assets/vegetation/trees/tree_lod.gdshaderinc"

// Leaf cards: double-sided and alpha-scissored. TreeMesher gives leaves normals
// pointing out of the crown. With culling off, Godot flips the normal on back
// faces before this code runs; flipping it back lets both sides of a card keep
// the crown's normal, so the crown shades as one volume from any side.

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_disable, hint_default_white;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0) = 0.5;
uniform float roughness : hint_range(0.0, 1.0) = 0.75;
uniform float specular : hint_range(0.0, 1.0) = 0.15;

void vertex() {
	lod_distance = tree_lod_distance(MODEL_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	if (tree_lod_hidden(FRAGCOORD.xy, lod_distance)) {
		discard;
	}
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	vec4 texel = texture(albedo_texture, UV);
	ALBEDO = texel.rgb * albedo_tint.rgb;
	ALPHA = texel.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
	ROUGHNESS = roughness;
	SPECULAR = specular;
}
