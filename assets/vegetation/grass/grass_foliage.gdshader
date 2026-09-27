shader_type spatial;
// Grass clump colouring for TerraBrush foliage (MultiMesh strategy). TerraBrush's
// include still owns placement, LOD rings, wind, rotation and scale; this shader
// only replaces the fragment. Opaque on purpose: the blades have no alpha texture,
// and skipping alpha-to-coverage keeps them cheaper on standalone GPUs.
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://addons/terrabrush/Resources/Shaders/foliage_multimesh_shader_include.gdshaderinc"

group_uniforms grass;
uniform vec3 root_color : source_color = vec3(0.17, 0.32, 0.09);
uniform vec3 tip_color : source_color = vec3(0.62, 0.80, 0.32);
// Clump height in mesh space before TerraBrush's meshScale, in metres.
uniform float clump_height : hint_range(0.01, 10.0, 0.01) = 2.2;
// Shapes the root-to-tip blend; above 1 keeps more of each blade dark.
uniform float gradient_power : hint_range(0.2, 4.0, 0.05) = 1.2;
// With the definition's useGroundColor on: how far the root takes the terrain colour.
uniform float ground_color_blend : hint_range(0.0, 1.0, 0.01) = 0.8;
// Darkens the terrain colour at the root so clumps keep some contact shading.
uniform float ground_root_darkening : hint_range(0.0, 1.0, 0.01) = 0.25;
// Per-clump brightness variation, as a fraction of the colour.
uniform float clump_variation : hint_range(0.0, 0.5, 0.01) = 0.12;
// Bends lighting normals toward world up so thin blades shade like the ground.
uniform float normal_up_blend : hint_range(0.0, 1.0, 0.01) = 0.6;
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.9;
uniform float specular : hint_range(0.0, 1.0, 0.01) = 0.2;
group_uniforms;

varying flat vec3 _instancePosition;
varying float _bladeHeight;

void vertex() {
	// Read before TerraBrush moves the vertex into the world.
	_bladeHeight = clamp(VERTEX.y / clump_height, 0.0, 1.0);
	_instancePosition = vec3(0.0);
	calculateFoliageVertex(INSTANCE_ID, VERTEX, NORMAL, COLOR, _instancePosition);
}

void fragment() {
	vec3 root = root_color;
	if (UseGroundColor) {
		// COLOR carries the terrain albedo under this clump.
		root = mix(root_color, COLOR.rgb * (1.0 - ground_root_darkening), ground_color_blend);
	}

	vec3 color = mix(root, tip_color, pow(_bladeHeight, gradient_power));
	color *= 1.0 + hash_noise_range(_instancePosition).y * clump_variation;

	ALBEDO = color * FoliageAlbedo.rgb;
	ROUGHNESS = roughness;
	SPECULAR = specular;

	vec3 up_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	NORMAL = normalize(mix(NORMAL, up_view, normal_up_blend));
}
