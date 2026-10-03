shader_type spatial;

#include "res://assets/vegetation/trees/tree_lod.gdshaderinc"

// Bark and inner wood in one material, so a tree's wood is one draw call.
// TreeMesher sets UV2.x to 1 on cut faces (inner wood) and 0 on bark. It is
// constant across each triangle, so neighbouring pixels almost always take the
// same branch; gradients are taken before the branch to keep mipmapping
// correct at the few pixels where they don't.

uniform sampler2D bark_albedo : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform vec4 bark_tint : source_color = vec4(1.0);
uniform float bark_roughness : hint_range(0.0, 1.0) = 0.9;
uniform sampler2D inner_albedo : source_color, filter_linear_mipmap, repeat_disable, hint_default_white;
uniform vec4 inner_tint : source_color = vec4(1.0);
uniform float inner_roughness : hint_range(0.0, 1.0) = 0.75;

void vertex() {
	lod_distance = tree_lod_distance(MODEL_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	if (tree_lod_hidden(FRAGCOORD.xy, lod_distance)) {
		discard;
	}
	vec2 uv_dx = dFdx(UV);
	vec2 uv_dy = dFdy(UV);
	if (UV2.x > 0.5) {
		ALBEDO = textureGrad(inner_albedo, UV, uv_dx, uv_dy).rgb * inner_tint.rgb;
		ROUGHNESS = inner_roughness;
	} else {
		ALBEDO = textureGrad(bark_albedo, UV, uv_dx, uv_dy).rgb * bark_tint.rgb;
		ROUGHNESS = bark_roughness;
	}
}
