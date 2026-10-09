shader_type spatial;
render_mode cull_disabled;

// Dead leaves: litter on the ground and the ball a picked-up cluster becomes. Each leaf's colour
// comes from the mesh's vertex colours; this adds what reads as a dead leaf up close: paler veins,
// darker decay blotches, a paler underside and a dry, matte finish. No textures.
//
// UV is each leaf's own frame (tools/blender/leaf_litter.py): x across it, 0.5 on the midrib and
// 0 and 1 at its widest; y along it, 0 at the base and 1 at the tip. UV.y below -0.5 marks what is
// no leaf (the ball's core), which gets no veins. The lateral veins' defaults follow that script's
// oak outline, so each runs out to a lobe.

uniform float vein_lightness : hint_range(0.0, 1.0) = 0.3;
// Widths in UV across a leaf (about 7 cm wide, so 0.03 is about 2 mm).
uniform float midrib_width : hint_range(0.0, 0.1) = 0.03;
uniform float vein_width : hint_range(0.0, 0.1) = 0.018;
// Where along UV.y the first lateral vein leaves the midrib and how far apart the veins are, on
// the right (x) and left (y) halves: the left lobes sit a little further up.
uniform vec2 vein_first = vec2(-0.023, 0.024);
uniform vec2 vein_spacing = vec2(0.185, 0.18);
// How far up the leaf a vein climbs for each unit of UV it runs out from the midrib.
uniform float vein_slant : hint_range(0.0, 2.0) = 0.5;
uniform float lateral_veins : hint_range(0.0, 8.0, 1.0) = 4.0;
uniform float blotch_size_m : hint_range(0.005, 0.2, 0.001) = 0.025;
uniform float blotch_darkness : hint_range(0.0, 1.0) = 0.35;
uniform vec3 underside_tint : source_color = vec3(0.78, 0.72, 0.6);
uniform float underside_mix : hint_range(0.0, 1.0) = 0.35;
uniform float roughness : hint_range(0.0, 1.0) = 0.9;
uniform float specular : hint_range(0.0, 1.0) = 0.25;

varying vec3 model_position;

void vertex() {
	// Blotches stay put on the leaves however the model moves (a ball in the hand).
	model_position = VERTEX;
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

// 1 within half a width of a line, d away from its centre. A line thinner than a pixel fades to
// its share of the pixel instead of shimmering.
float line(float d, float width) {
	float blur = max(fwidth(d), 1e-5);
	float half_width = 0.5 * width;
	return (1.0 - smoothstep(half_width - blur, half_width + blur, d)) * min(1.0, half_width / blur);
}

void fragment() {
	vec3 colour = COLOR.rgb;
	float across = abs(UV.x - 0.5);
	float right = step(0.5, UV.x);
	// The midrib narrows towards the tip.
	float veins = line(across, midrib_width * clamp(1.2 - UV.y, 0.3, 1.2));
	float first = mix(vein_first.y, vein_first.x, right);
	float spacing = mix(vein_spacing.y, vein_spacing.x, right);
	float along = (UV.y - vein_slant * across - first) / spacing;
	float nearest = floor(along + 0.5);
	float lateral = line(abs(along - nearest) * spacing / sqrt(1.0 + vein_slant * vein_slant), vein_width);
	lateral *= step(-0.5, nearest) * step(nearest, lateral_veins - 0.5);
	veins = max(veins, lateral) * step(-0.5, UV.y);
	colour *= 1.0 + vein_lightness * veins;

	float decay = value_noise(model_position / blotch_size_m);
	colour *= (0.92 + 0.16 * decay) * (1.0 - blotch_darkness * smoothstep(0.62, 0.82, decay));

	if (!FRONT_FACING) {
		float brightness = max(colour.r, max(colour.g, colour.b));
		colour = mix(colour, underside_tint * brightness, underside_mix);
	}
	ALBEDO = colour;
	ROUGHNESS = roughness;
	SPECULAR = specular;
}
