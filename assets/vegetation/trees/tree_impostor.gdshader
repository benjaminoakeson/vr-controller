shader_type spatial;
render_mode world_vertex_coords, cull_disabled;

#include "res://assets/vegetation/trees/tree_lod.gdshaderinc"

// Distant trees as pictures (TreeImpostors), all of a species' in one
// MultiMesh. Each instance is a tree: its origin is the point the tree's
// detail levels measure their distance to, its basis the tree's turn and size,
// and its custom data the variant's layer (r) and the centre its picture was
// framed on, in the tree's own space (g, b, a).
//
// Each card stands upright and turns about the vertical to face the main
// camera, the same for both eyes, placed so the picture's trunk stands where
// the tree's trunk does. It is lit with the picture's baked normals,
// turned with the card, so it shades like the real tree. Nearer than its fade
// band a card collapses to a point and draws nothing: the tree is drawn by its
// own detail levels there, dissolving into the card over the band.

uniform sampler2DArray color_layers : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2DArray normal_layers : filter_linear_mipmap, repeat_disable;
// Side of the square each picture shows, in metres, before the tree's size.
uniform float card_size = 10.0;
// As lod_fade: (fade in from, fully in at, fade out from, fully out at).
uniform vec4 fade = vec4(0.0);
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
// As the leaf shader's, so the card shades like the leaves it replaces.
uniform float specular : hint_range(0.0, 1.0) = 0.15;

varying flat float layer;
varying flat float distance_to_camera;
varying flat vec3 card_right;
varying flat vec3 card_facing;

void vertex() {
	vec3 centre = MODEL_MATRIX[3].xyz;
	mat3 turn = mat3(MODEL_MATRIX);
	float size = length(MODEL_MATRIX[0].xyz);
	vec3 pictured = INSTANCE_CUSTOM.gba;
	// The tree's own origin, at the foot of its trunk.
	vec3 foot = centre - turn * pictured;
	vec3 camera = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;
	vec3 facing = vec3(camera.x - centre.x, 0.0, camera.z - centre.z);
	facing = length(facing) > 0.001 ? normalize(facing) : vec3(0.0, 0.0, 1.0);
	card_facing = facing;
	card_right = cross(vec3(0.0, 1.0, 0.0), facing);
	distance_to_camera = distance(centre, camera);
	layer = INSTANCE_CUSTOM.r;
	if (distance_to_camera < fade.x) {
		VERTEX = centre;
	} else {
		// The picture's middle shows `pictured`; its trunk is at x = 0.
		vec3 card_centre = foot + (card_right * pictured.x + vec3(0.0, pictured.y, 0.0)) * size;
		// The card's corner from its UV: the picture's top-left is UV (0, 0).
		vec2 corner = vec2(UV.x - 0.5, 0.5 - UV.y) * card_size * size;
		VERTEX = card_centre + card_right * corner.x + vec3(0.0, corner.y, 0.0);
	}
	NORMAL = facing;
}

void fragment() {
	if (tree_lod_hidden_by(fade, FRAGCOORD.xy, distance_to_camera)) {
		discard;
	}
	vec4 texel = texture(color_layers, vec3(UV, layer));
	if (texel.a < alpha_scissor) {
		discard;
	}
	ALBEDO = texel.rgb;
	// Baked looking along -Z: x right, y up, z toward the camera.
	vec3 baked = texture(normal_layers, vec3(UV, layer)).rgb * 2.0 - 1.0;
	vec3 world_normal = normalize(card_right * baked.x + vec3(0.0, baked.y, 0.0) + card_facing * baked.z);
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
	ROUGHNESS = roughness;
	SPECULAR = specular;
}
