shader_type spatial;
// Light smoke over a fire (2026-10-03), built like the flames
// (fire_flames.gdshader): each instance of the smoke's MultiMesh is one puff
// card whose life comes from its instance number and TIME, so nothing
// simulates, all the puffs are one instanced draw, and a culled fire costs
// nothing. Smoke is the costliest part of the fire on a standalone headset: its
// cards are large and blended, so the puff count, size and opacity are the
// knobs to watch.
//
// A puff appears just above the flames, climbs, slowing as it cools, meanders,
// drifts with the wind, widens, turns slowly and thins into wisps as the noise
// eats it. Cards face the main camera, the same for both eyes. Lit only at
// their corners (vertex lighting), which is all a soft puff needs: grey by day,
// dark at night. Its normal leans up, so the sky and sun light its top. The
// fire's own light leaves the smoke out (it is on RenderLayers.FIRE_SMOKE):
// lit at the corners from a few centimetres away, a puff flared into a bright
// orange ball. The fire lights it through glow instead, an orange tint that
// fades as it climbs.
// Every puff shares one colour, so the order the cards are drawn in hardly
// shows and they need no sorting; the material draws before the flames
// (render_priority), so the flames stay bright where the two overlap. Within
// near_fade of the eyes a puff fades and then collapses to nothing.
//
// As with the flames, the MultiMesh's instances keep identity transforms and
// the fire node's own scale scales the sizes here (in metres before that
// scale); the wind is in world metres a second.
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, specular_disabled, vertex_lighting, world_vertex_coords;

// b: one soft puff, zero along every border; g: tiling noise spread evenly over
// 0-1 (tools/effects/make_flame_texture.py).
uniform sampler2D smoke_texture : filter_linear_mipmap, repeat_enable;

group_uniforms motion;
// Seconds from a puff appearing to gone. 3600 s (TIME's rollover) should be a
// whole number of lifetimes, or every puff jumps once an hour.
uniform float lifetime : hint_range(0.5, 10.0, 0.05) = 4.0;
// Where puffs appear: how high above the fire's origin, and within what radius, in metres.
uniform float start_height : hint_range(0.0, 2.0, 0.01) = 0.5;
uniform float base_radius : hint_range(0.0, 1.0, 0.01) = 0.08;
// How fast a puff climbs when it appears, in metres a second, and what share of
// that it has lost by the end of its life.
uniform float rise_speed : hint_range(0.0, 2.0, 0.01) = 0.45;
uniform float rise_slowing : hint_range(0.0, 1.0, 0.01) = 0.5;
// How far a puff meanders sideways, in metres.
uniform float meander : hint_range(0.0, 0.5, 0.01) = 0.08;
// The drift every puff shares, in world metres a second.
uniform vec3 wind = vec3(0.1, 0.0, 0.04);
// Turn rate of the fastest-turning puffs, in radians a second.
uniform float spin : hint_range(0.0, 2.0, 0.01) = 0.35;
group_uniforms;

group_uniforms look;
// Width of a puff when it appears and when it is gone, in metres.
uniform float start_size : hint_range(0.05, 2.0, 0.01) = 0.3;
uniform float end_size : hint_range(0.05, 4.0, 0.01) = 1.2;
uniform vec3 smoke_color : source_color = vec3(0.78, 0.79, 0.82);
// The densest a puff gets: 0 is clear, 1 opaque.
uniform float opacity : hint_range(0.0, 1.0, 0.01) = 0.45;
// How much the noise has eaten a puff into wisps by the end of its life; a
// third of that from the start, so no puff is ever a clean ball.
uniform float dissolve : hint_range(0.0, 1.0, 0.01) = 0.5;
// The fire's light on the smoke just above it, and how high it reaches, in metres.
uniform vec3 glow_color : source_color = vec3(1.0, 0.45, 0.12);
uniform float glow : hint_range(0.0, 2.0, 0.01) = 0.3;
uniform float glow_height : hint_range(0.01, 2.0, 0.01) = 0.35;
group_uniforms;

group_uniforms comfort;
// Distances from the eyes, in metres: puffs fade from the first to the second
// and are gone nearer than it.
uniform vec2 near_fade = vec2(0.7, 0.3);
group_uniforms;

varying flat float age;
varying flat float strength;
varying flat float warmth;
varying flat vec2 noise_offset;

uint hash_uint(uint x) {
	x ^= x >> 16u;
	x *= 2146121005u;
	x ^= x >> 15u;
	x *= 2221713035u;
	x ^= x >> 16u;
	return x;
}

// Four random numbers in 0-1 for one life of one puff.
vec4 random4(uint puff, uint life) {
	uint a = hash_uint(puff * 2654435769u ^ hash_uint(life));
	uint b = hash_uint(a);
	uint c = hash_uint(b);
	uint d = hash_uint(c);
	return vec4(float(a >> 8u), float(b >> 8u), float(c >> 8u), float(d >> 8u)) / 16777216.0;
}

void vertex() {
	float scale = length(MODEL_MATRIX[1].xyz);

	// Golden-ratio phases spread the puffs' births evenly through a lifetime.
	float clock = TIME / lifetime + fract(float(INSTANCE_ID) * 0.618034);
	float life = floor(clock);
	age = clock - life;
	float seconds = age * lifetime;
	vec4 random = random4(uint(INSTANCE_ID), uint(life));

	float angle = random.x * TAU;
	vec2 disc = vec2(cos(angle), sin(angle)) * sqrt(random.y) * base_radius;
	vec3 birth = MODEL_MATRIX[3].xyz + MODEL_MATRIX[0].xyz * disc.x + MODEL_MATRIX[2].xyz * disc.y
			+ vec3(0.0, start_height * scale, 0.0);
	// Slows evenly over its life, so the climb eases off as the puff cools.
	float climb = rise_speed * mix(0.85, 1.15, random.z) * seconds * (1.0 - 0.5 * rise_slowing * age);
	vec3 wandering = vec3(sin(seconds * 1.1 + random.z * TAU), 0.0, cos(seconds * 0.9 + random.w * TAU))
			* meander * age;
	vec3 centre = birth + (vec3(0.0, climb, 0.0) + wandering) * scale + wind * seconds;
	float size = mix(start_size, end_size, sqrt(age)) * scale * mix(0.8, 1.2, random.w);

	vec3 camera = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;
	vec3 to_camera = camera - centre;
	float distance_to_camera = length(to_camera);
	vec3 facing = to_camera / max(distance_to_camera, 0.0001);
	// Up is the world's up laid into the card's plane; seen from straight above
	// that vanishes, so it hands over to the camera's own up.
	vec3 up = vec3(0.0, 1.0, 0.0) - facing * facing.y;
	vec3 camera_up = MAIN_CAM_INV_VIEW_MATRIX[1].xyz;
	camera_up -= facing * dot(camera_up, facing);
	up = normalize(mix(camera_up, up, smoothstep(0.05, 0.3, length(up))));
	vec3 right = cross(up, facing);
	// Each puff turns its own way, from its own starting turn.
	float turn = random.x * TAU + spin * (random.z * 2.0 - 1.0) * seconds;
	vec3 card_up = up * cos(turn) + right * sin(turn);
	vec3 card_right = right * cos(turn) - up * sin(turn);

	float near_alpha = smoothstep(near_fade.y, near_fade.x, distance_to_camera);
	if (near_alpha <= 0.0) {
		size = 0.0;
	}
	vec2 corner = vec2(UV.x - 0.5, 0.5 - UV.y);
	VERTEX = centre + (card_right * corner.x + card_up * corner.y) * size;
	NORMAL = normalize(facing + vec3(0.0, 2.0, 0.0));

	strength = opacity * smoothstep(0.0, 0.15, age) * (1.0 - smoothstep(0.45, 1.0, age)) * near_alpha;
	warmth = glow * (1.0 - smoothstep(0.0, glow_height * scale, climb * scale));
	noise_offset = random.zw;
}

void fragment() {
	float puff = texture(smoke_texture, UV).b;
	// The noise drifts slowly through the puff as it climbs (UV's v grows downward).
	float noise = texture(smoke_texture, UV * 0.35 + noise_offset + vec2(0.0, age * 0.3)).g;
	float density = puff * mix(1.0, smoothstep(0.15, 0.85, noise), dissolve * mix(0.35, 1.0, age));

	ALBEDO = smoke_color;
	EMISSION = glow_color * warmth;
	ALPHA = density * strength;
}
