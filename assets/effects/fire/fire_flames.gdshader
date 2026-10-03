shader_type spatial;
// Flames that live entirely in this shader (2026-10-03). Each instance of the
// fire's MultiMesh is one flame card; its instance number and TIME decide where
// in its life it is, and every life draws fresh random numbers, so nothing
// simulates: no CPU work, no compute pass, and nothing at all while the fire is
// culled. All the cards are one instanced draw. The cost is the blended pixels,
// so the card count and size are the knobs that matter on a standalone headset.
//
// Flames do not fly upward; they stay rooted on the fuel and whip. Each one
// stands on a point of a disc at the fire's origin, flares up quickly, flickers
// in length, and dies back down, then rises again elsewhere on the disc. A wave
// runs up each flame and swings it sideways, the base held and the tip swinging
// most, and the whole fire sways together. What rises is the noise inside each
// flame (the hot gas): it climbs through the tongue and tears its tip into licks.
// Flames in the middle of the disc stand tallest.
//
// Cards turn only about the world's vertical to face the main camera, the same
// for both eyes: they never pitch or roll, so a flame points up from wherever it
// is seen and keeps its way as the player walks round or over it. Seen from
// steeply above a card shortens, as a real flame does; from straight above it
// is edge-on and gone. Cards stand on their bottom edge so they never dip below
// the fuel. The card mesh is split into rows along its height so it can bend.
// Premultiplied: a card adds its colour and dims what is behind it by only
// part of its alpha (occlusion), so overlaps still brighten toward the
// yellow core and need no sorting, yet the flames keep their colour against a
// bright daytime background instead of washing out to pink. Within near_fade of
// the eyes a card fades and then collapses to nothing, so a head in the fire
// costs no full-screen overdraw.
//
// The MultiMesh's instances keep identity transforms (the fire scene stores 24
// and draws visible_instance_count of them); the fire node's own scale scales
// everything here (sizes in metres are before that scale). Flames stand up the
// world's vertical, but the scene's culling box assumes the node stands upright.
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled, world_vertex_coords;

// r: one flame tongue, zero along every border; g: tiling noise spread evenly
// over 0-1 (tools/effects/make_flame_texture.py).
uniform sampler2D flame_texture : filter_linear_mipmap, repeat_enable;

group_uniforms shape;
// Radius of the disc flames stand on, in metres.
uniform float base_radius : hint_range(0.0, 1.0, 0.01) = 0.18;
// Height of a full-grown flame in the middle of the disc, in metres; its width
// is card_aspect of that.
uniform float card_height : hint_range(0.05, 2.0, 0.01) = 0.55;
uniform float card_aspect : hint_range(0.3, 1.5, 0.01) = 0.7;
// Share of their height that flames at the disc's rim lose.
uniform float rim_drop : hint_range(0.0, 1.0, 0.01) = 0.5;
group_uniforms;

group_uniforms motion;
// Seconds from a flame flaring up to dying back. 3600 s (TIME's rollover)
// should be a whole number of lifetimes, or every flame jumps once an hour.
uniform float lifetime : hint_range(0.2, 4.0, 0.01) = 1.25;
// How fast and how far a flame's length flickers: Hz, and a share of its length.
uniform float flicker_rate : hint_range(0.0, 20.0, 0.1) = 3.5;
uniform float flicker_depth : hint_range(0.0, 0.6, 0.01) = 0.15;
// The wave that whips a flame: how far its tip swings, as a share of the
// flame's height; how many waves fit along a flame; how many pass up it a second.
uniform float whip : hint_range(0.0, 1.0, 0.01) = 0.22;
uniform float whip_waves : hint_range(0.0, 3.0, 0.05) = 0.9;
uniform float whip_speed : hint_range(0.0, 8.0, 0.05) = 2.2;
// How far the whole fire sways at its tips, as a share of their height.
uniform float sway : hint_range(0.0, 0.5, 0.01) = 0.1;
// How fast the hot gas climbs through a flame, in flame heights a second.
uniform float gas_rise : hint_range(0.0, 4.0, 0.05) = 1.1;
group_uniforms;

group_uniforms look;
// How much the gas tears a flame apart: at its base, and at its tip.
uniform vec2 tearing = vec2(0.7, 1.5);
uniform vec3 ember_color : source_color = vec3(0.55, 0.06, 0.0);
uniform vec3 flame_color : source_color = vec3(1.0, 0.36, 0.03);
uniform vec3 core_color : source_color = vec3(1.0, 0.78, 0.32);
// Above 1 lets the core pass the environment's glow threshold.
uniform float energy : hint_range(0.0, 4.0, 0.01) = 1.3;
// How much a card dims what is behind it, as a share of its alpha: 0 is purely
// additive (washes out in daylight), 1 is an ordinary blend (needs sorting).
uniform float occlusion : hint_range(0.0, 1.0, 0.01) = 0.5;
group_uniforms;

group_uniforms comfort;
// Distances from the eyes, in metres: cards fade from the first to the second
// and are gone nearer than it.
uniform vec2 near_fade = vec2(0.4, 0.15);
group_uniforms;

varying flat float strength;
varying flat float near_alpha;
varying flat vec2 noise_offset;

uint hash_uint(uint x) {
	x ^= x >> 16u;
	x *= 2146121005u;
	x ^= x >> 15u;
	x *= 2221713035u;
	x ^= x >> 16u;
	return x;
}

// Four random numbers in 0-1 for one life of one flame.
vec4 random4(uint flame, uint life) {
	uint a = hash_uint(flame * 2654435769u ^ hash_uint(life));
	uint b = hash_uint(a);
	uint c = hash_uint(b);
	uint d = hash_uint(c);
	return vec4(float(a >> 8u), float(b >> 8u), float(c >> 8u), float(d >> 8u)) / 16777216.0;
}

void vertex() {
	float scale = length(MODEL_MATRIX[1].xyz);

	// Golden-ratio phases spread the flames' lives evenly through a lifetime.
	float clock = TIME / lifetime + fract(float(INSTANCE_ID) * 0.618034);
	float life = floor(clock);
	float age = clock - life;
	vec4 random = random4(uint(INSTANCE_ID), uint(life));
	float phase = random.z * TAU;

	// Where on the disc it stands, in the fire's own plane, for this life.
	float angle = random.x * TAU;
	float out_from_middle = sqrt(random.y);
	vec2 disc = vec2(cos(angle), sin(angle)) * out_from_middle * base_radius;
	vec3 base = MODEL_MATRIX[3].xyz + MODEL_MATRIX[0].xyz * disc.x + MODEL_MATRIX[2].xyz * disc.y;

	// Flares up fast, dies back slower; its length flickers all the while.
	float flare = smoothstep(0.0, 0.2, age) * (1.0 - smoothstep(0.5, 1.0, age));
	float flicker = 1.0 + flicker_depth * (0.6 * sin(TAU * flicker_rate * TIME + phase)
			+ 0.4 * sin(TAU * flicker_rate * 1.73 * TIME + phase * 2.3));
	float height = card_height * scale * mix(0.65, 1.1, random.w) * (1.0 - rim_drop * out_from_middle)
			* flare * flicker;
	strength = flare;

	vec3 camera = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;
	vec3 to_camera = camera - (base + vec3(0.0, 0.5 * height, 0.0));
	float distance_to_camera = length(to_camera);
	// Toward the camera across the floor. Right over a flame that way swings
	// with every small head movement, but there the card is edge-on and shows
	// nothing.
	vec2 across = to_camera.xz;
	float across_length = length(across);
	vec2 toward = across_length > 0.0001 ? across / across_length : vec2(0.0, 1.0);
	vec3 facing = vec3(toward.x, 0.0, toward.y);
	vec3 card_up = vec3(0.0, 1.0, 0.0);
	vec3 card_right = vec3(facing.z, 0.0, -facing.x);

	near_alpha = smoothstep(near_fade.y, near_fade.x, distance_to_camera);
	if (near_alpha <= 0.0) {
		height = 0.0;
	}
	// The card's corner from its UV, standing on its bottom edge. How far up
	// the flame a vertex lies sets how far it bends: the base holds.
	vec2 corner = vec2(UV.x - 0.5, 1.0 - UV.y);
	float bend = corner.y * corner.y * height;
	float wave_speed = whip_speed * mix(0.8, 1.2, fract(random.z * 7.1));
	float lash = whip * sin(TAU * (corner.y * whip_waves - wave_speed * TIME) + phase);
	vec3 drift = vec3(sin(TIME * 1.3) + 0.5 * sin(TIME * 2.9 + 1.0), 0.0, cos(TIME * 1.1) + 0.5 * sin(TIME * 2.3));
	VERTEX = base + card_right * (corner.x * height * card_aspect + lash * bend)
			+ card_up * corner.y * height + drift * (sway / 1.5) * bend;
	NORMAL = facing;
	// Each life reads its own patch of noise.
	noise_offset = random.zw;
}

void fragment() {
	float tongue = texture(flame_texture, UV).r;
	float along = 1.0 - UV.y;
	// The gas climbs through the card (UV's v grows downward).
	vec2 noise_uv = UV * vec2(0.6, 0.45) + noise_offset + vec2(0.0, TIME * gas_rise * 0.45);
	float noise = texture(flame_texture, noise_uv).g;

	float heat = tongue * (0.85 + (noise - 0.5) * mix(tearing.x, tearing.y, along)) * mix(0.55, 1.0, strength);
	vec3 color = mix(ember_color, flame_color, smoothstep(0.08, 0.4, heat));
	color = mix(color, core_color, smoothstep(0.45, 0.9, heat));

	float alpha = smoothstep(0.04, 0.2, heat) * near_alpha;
	ALBEDO = color * energy * alpha;
	ALPHA = alpha * occlusion;
}
