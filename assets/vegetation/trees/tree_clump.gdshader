shader_type spatial;

#include "res://assets/vegetation/trees/tree_lod.gdshaderinc"

// Leaf clumps: opaque, a flat colour, fading between a tree's detail levels
// like the rest of the tree.

uniform vec4 albedo_color : source_color = vec4(0.16, 0.3, 0.14, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.9;

void vertex() {
	lod_distance = tree_lod_distance(MODEL_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	if (tree_lod_hidden(FRAGCOORD.xy, lod_distance)) {
		discard;
	}
	ALBEDO = albedo_color.rgb;
	ROUGHNESS = roughness;
}
