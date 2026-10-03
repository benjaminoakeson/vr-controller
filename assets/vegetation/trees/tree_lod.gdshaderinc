// Crossfade between a tree's detail levels, for every shader a tree draws with.
//
// Each detail level is its own MeshInstance3D (see ProceduralTree). The engine's
// visibility ranges draw a level only near its distances; in the band where two
// levels meet, both are drawn and this hides complementary pixels of each on a
// 4x4 ordered-dither pattern, so the band shows one tree with no gaps and no
// pixel drawn twice. Godot's own visibility-range fade isn't used: the Mobile
// renderer ignores it, and Forward+ draws fading objects alpha-blended.
//
// The distance is measured from the main camera, in every pass, so shadows fade
// with the tree instead of with the light, to the same point the engine measures
// the visibility range to: the centre of the bounds all of a tree's levels share.

// (fade in from, fully in at, fade out from, fully out at), in metres. A range
// whose end isn't past its start doesn't fade.
instance uniform vec4 lod_fade = vec4(0.0, 0.0, 0.0, 0.0);
// The centre of the tree's bounds, in the tree's space.
instance uniform vec3 lod_centre = vec3(0.0);

// Each shader stores tree_lod_distance() here in vertex() and hands it to
// tree_lod_hidden() in fragment(): Godot only lets the stage functions touch varyings.
varying flat float lod_distance;

const float LOD_DITHER[16] = float[16](
		0.0, 8.0, 2.0, 10.0,
		12.0, 4.0, 14.0, 6.0,
		3.0, 11.0, 1.0, 9.0,
		15.0, 7.0, 13.0, 5.0);

float tree_lod_distance(mat4 model_matrix, mat4 main_camera_inverse_view) {
	return distance((model_matrix * vec4(lod_centre, 1.0)).xyz, main_camera_inverse_view[3].xyz);
}

// Whether this pixel belongs to another level at this distance, for a level
// fading as `fade` says (same layout as lod_fade).
bool tree_lod_hidden_by(vec4 fade, vec2 frag_coord, float distance_to_tree) {
	ivec2 cell = ivec2(mod(frag_coord, 4.0));
	float threshold = (LOD_DITHER[cell.y * 4 + cell.x] + 0.5) / 16.0;
	float shown_in = fade.y > fade.x
			? clamp((distance_to_tree - fade.x) / (fade.y - fade.x), 0.0, 1.0) : 1.0;
	float shown_out = fade.w > fade.z
			? clamp((fade.w - distance_to_tree) / (fade.w - fade.z), 0.0, 1.0) : 1.0;
	// Fading in takes the pixels a level fading out at the same distance gives up.
	return threshold < 1.0 - shown_in || threshold >= shown_out;
}

// Whether this pixel belongs to another of this tree's levels at this distance.
bool tree_lod_hidden(vec2 frag_coord, float distance_to_tree) {
	return tree_lod_hidden_by(lod_fade, frag_coord, distance_to_tree);
}
