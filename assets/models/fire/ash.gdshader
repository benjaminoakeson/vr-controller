shader_type spatial;

// Ash heap: the grey ash a fire leaves and the charcoal half buried in it
// (tools/blender/ash_pile.py). Colour comes from the mesh's vertex colours: the ash pale on top and
// dark where it thins over the ground, the charcoal near black. This adds what reads as ash and
// charcoal up close, with no textures: grain and white and dark flecks in the powder, shrinkage
// cracks and a faint sheen on the charcoal. UV.x tells them apart: 0 on ash, 1 on charcoal.
//
// The detail is laid out in model space, so it stays put on the heap. Detail finer than a couple of
// pixels fades out instead of shimmering, so from standing height the heap shows its vertex colours
// and the detail comes in as the player leans close.

group_uniforms ash;
uniform float grain_size_m : hint_range(0.0005, 0.01, 0.0001) = 0.0015;
uniform float grain_strength : hint_range(0.0, 0.5) = 0.12;
uniform float clump_size_m : hint_range(0.002, 0.05, 0.001) = 0.008;
uniform float clump_strength : hint_range(0.0, 0.5) = 0.12;
// Flecks: a cell of this size holds at most one, a round fleck up to this share of the cell across
// (half that at the least).
uniform float fleck_cell_m : hint_range(0.001, 0.02, 0.0005) = 0.003;
uniform float fleck_size : hint_range(0.05, 0.6) = 0.45;
// Shares of the cells holding a white fleck (burnt-out ash) and a dark one (a crumb of charcoal),
// and how far each turns the ash to its colour.
uniform float white_flecks : hint_range(0.0, 1.0) = 0.12;
uniform float dark_flecks : hint_range(0.0, 1.0) = 0.12;
uniform vec3 white_fleck_colour : source_color = vec3(0.86, 0.85, 0.82);
uniform vec3 dark_fleck_colour : source_color = vec3(0.07, 0.065, 0.06);
uniform float white_fleck_strength : hint_range(0.0, 1.0) = 0.5;
uniform float dark_fleck_strength : hint_range(0.0, 1.0) = 0.8;
// Powder scatters light back at grazing angles; a little rim light softens the heap.
uniform float ash_rim : hint_range(0.0, 1.0) = 0.25;
uniform float ash_specular : hint_range(0.0, 1.0) = 0.2;

group_uniforms charcoal;
// Cracks part each face into blocks about this size, longer than wide by crack_stretch, as burnt
// wood checks into blocks along its grain.
uniform float crack_cell_m : hint_range(0.002, 0.02, 0.0005) = 0.008;
uniform float crack_stretch : hint_range(1.0, 4.0) = 2.0;
uniform float crack_width_m : hint_range(0.0001, 0.003, 0.0001) = 0.0007;
uniform float crack_darkness : hint_range(0.0, 1.0) = 0.6;
uniform float charcoal_roughness : hint_range(0.0, 1.0) = 0.6;
uniform float charcoal_specular : hint_range(0.0, 1.0) = 0.4;
group_uniforms;

varying vec3 model_position;
varying vec3 model_normal;

void vertex() {
	model_position = VERTEX;
	model_normal = NORMAL;
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

// 1 for detail size_m across that spans several pixels of pixel_m, falling to 0 by about two.
float shown(float size_m, float pixel_m) {
	return 1.0 - smoothstep(0.25, 0.5, pixel_m / size_m);
}

// 1 within half a width of a line, d metres from its centre, blurred over a pixel of pixel_m. A
// line thinner than a pixel fades to its share of the pixel instead of shimmering. (Derivatives
// are taken once, outside the branches, as they are unreliable inside them.)
float line(float d, float width, float pixel_m) {
	float blur = max(pixel_m, 1e-6);
	float half_width = 0.5 * width;
	return (1.0 - smoothstep(half_width - blur, half_width + blur, d)) * min(1.0, half_width / blur);
}

// How far p is from the nearest border between cells of a jittered grid, in cells: half the gap
// between the nearest and second-nearest cell points.
float cell_border(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float nearest = 8.0;
	float second = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell = vec2(float(x), float(y));
			vec3 seed = vec3(i + cell, 0.0);
			vec2 point = cell + vec2(hash(seed), hash(seed + vec3(0.0, 0.0, 7.3))) - f;
			float d = length(point);
			second = d < nearest ? nearest : min(second, d);
			nearest = min(nearest, d);
		}
	}
	return 0.5 * (second - nearest);
}

void fragment() {
	vec3 colour = COLOR.rgb;
	// About one pixel's width on the heap, in metres.
	float pixel_m = max(length(dFdx(model_position)), length(dFdy(model_position)));
	if (UV.x < 0.5) {
		float clumps = value_noise(model_position / clump_size_m) - 0.5;
		float grain = value_noise(model_position / grain_size_m) - 0.5;
		colour *= 1.0 + 2.0 * clump_strength * clumps * shown(clump_size_m, pixel_m);
		colour *= 1.0 + 2.0 * grain_strength * grain * shown(grain_size_m, pixel_m);

		vec3 cell = floor(model_position / fleck_cell_m);
		float pick = hash(cell);
		float fleck_m = fleck_size * fleck_cell_m * (0.5 + 0.5 * hash(cell + 55.1));
		// The fleck's centre keeps it inside its cell.
		vec3 centre = 0.5 + (1.0 - fleck_size) * (vec3(hash(cell + 13.7), hash(cell + 27.1), hash(cell + 41.3)) - 0.5);
		float from_centre = length(fract(model_position / fleck_cell_m) - centre) * fleck_cell_m;
		float fleck = (1.0 - smoothstep(0.5 * fleck_m - pixel_m, 0.5 * fleck_m + pixel_m, from_centre)) * shown(fleck_m, pixel_m);
		colour = mix(colour, white_fleck_colour, white_fleck_strength * fleck * step(pick, white_flecks));
		colour = mix(colour, dark_fleck_colour, dark_fleck_strength * fleck * step(1.0 - dark_flecks, pick));

		ALBEDO = colour;
		ROUGHNESS = 1.0;
		SPECULAR = ash_specular;
		RIM = ash_rim;
		RIM_TINT = 0.5;
	} else {
		// Each face cracks in its own plane: the two model axes most across its normal.
		vec3 n = abs(model_normal);
		vec2 face = n.x > max(n.y, n.z) ? model_position.yz : (n.y > n.z ? model_position.xz : model_position.xy);
		vec2 cells = face / crack_cell_m * vec2(1.0 / crack_stretch, 1.0);
		// The border distance is in cells across the short way, near enough metres once scaled.
		float crack = line(cell_border(cells) * crack_cell_m, crack_width_m, pixel_m);
		colour *= 1.0 - crack_darkness * crack;
		// Faces dusted with ash (paler in the vertex colours) lose the sheen.
		float dusted = smoothstep(0.01, 0.04, COLOR.g);
		ALBEDO = colour;
		// The sheen is most of what lights charcoal, so the cracks lose it to show.
		ROUGHNESS = mix(charcoal_roughness, 1.0, max(crack, dusted));
		SPECULAR = charcoal_specular * (1.0 - crack);
	}
}
