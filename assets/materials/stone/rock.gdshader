shader_type spatial;

// Hand-sized rocks: the flint and the stone (flint.tres and stone.tres beside this file). Broad
// mottling between two colours, faint bands through it, and fine pale and dark grains, all laid
// out in the object's own space in metres: the pattern stays on the rock however it turns, and
// keeps its size whatever the model's scale. No textures, and the mesh needs no UVs.

uniform vec3 dark_colour : source_color = vec3(0.25, 0.25, 0.24);
uniform vec3 light_colour : source_color = vec3(0.46, 0.45, 0.42);
// About how wide one patch of the mottling is.
uniform float mottle_size_m : hint_range(0.002, 0.2, 0.001) = 0.03;
// 0 blends the colours in soft clouds; 1 gives patches with crisp edges.
uniform float mottle_sharpness : hint_range(0.0, 1.0) = 0.3;
// Bands that follow the mottling's contours (flint's growth rings, a stone's bedding): how many
// run across one patch, and how far each lightens and darkens the colour.
uniform float bands_per_patch : hint_range(0.0, 8.0) = 0.0;
uniform float band_strength : hint_range(0.0, 0.5) = 0.0;
// Grains: specks about this wide; the amounts are roughly the share of the surface they cover.
uniform float grain_size_m : hint_range(0.0005, 0.02, 0.0001) = 0.002;
uniform vec3 pale_grain_colour : source_color = vec3(0.72, 0.7, 0.66);
uniform float pale_grains : hint_range(0.0, 0.5) = 0.1;
uniform vec3 dark_grain_colour : source_color = vec3(0.1, 0.1, 0.1);
uniform float dark_grains : hint_range(0.0, 0.5) = 0.1;
// The light patches are the roughest, the dark ones the smoothest.
uniform float roughness_dark : hint_range(0.0, 1.0) = 0.8;
uniform float roughness_light : hint_range(0.0, 1.0) = 0.9;
uniform float specular : hint_range(0.0, 1.0) = 0.5;

varying vec3 model_position_m;

void vertex() {
	// The model's own scale (the stone's Model node is scaled down) without its turn, so a pattern
	// in metres neither swims as the rock turns nor shrinks with the model.
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	model_position_m = VERTEX * scale;
}

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float value_noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
			mix(mix(hash(i), hash(i + vec3(1.0, 0.0, 0.0)), f.x),
					mix(hash(i + vec3(0.0, 1.0, 0.0)), hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
			mix(mix(hash(i + vec3(0.0, 0.0, 1.0)), hash(i + vec3(1.0, 0.0, 1.0)), f.x),
					mix(hash(i + vec3(0.0, 1.0, 1.0)), hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y),
			f.z);
}

// 1 where a grain sits: the top `amount` of a noise at grain size, as a soft-edged speck.
float grains(vec3 p, float amount) {
	float n = value_noise(p);
	float edge = 1.0 - amount * 0.6;
	return smoothstep(edge - 0.04, edge + 0.04, n) * step(0.001, amount);
}

void fragment() {
	vec3 p = model_position_m;
	// Two octaves, the finer one at half weight, so the patches have ragged edges.
	float mottle = (value_noise(p / mottle_size_m) * 2.0 + value_noise(p / mottle_size_m * 2.7 + 13.1)) / 3.0;
	float spread = mix(0.35, 0.04, mottle_sharpness);
	float light = smoothstep(0.5 - spread, 0.5 + spread, mottle);
	vec3 colour = mix(dark_colour, light_colour, light);
	// The mottling noise changes by about a third across one patch, hence the 3.
	colour *= 1.0 + band_strength * sin(mottle * bands_per_patch * 6.2831853 * 3.0);

	// Grains fade into their average colour once they are smaller than about a pixel, so they
	// don't shimmer at a distance (fwidth: how far the surface moves across one pixel).
	vec3 g = p / grain_size_m;
	float footprint = length(fwidth(g));
	float sharp = 1.0 - smoothstep(0.5, 1.5, footprint);
	float pale = grains(g, pale_grains);
	float dark = grains(g + 37.7, dark_grains) * (1.0 - pale);
	vec3 grained = mix(mix(colour, pale_grain_colour, pale), dark_grain_colour, dark);
	vec3 averaged = mix(mix(colour, pale_grain_colour, pale_grains * 0.5), dark_grain_colour, dark_grains * 0.5);
	ALBEDO = mix(averaged, grained, sharp);
	ROUGHNESS = mix(roughness_dark, roughness_light, light);
	SPECULAR = specular;
}
