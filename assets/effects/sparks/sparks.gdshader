shader_type spatial;
// One burst of sparks from a strike (2026-10-05), living entirely in this
// shader, as the fire's flames do: each instance of the burst's MultiMesh is one
// spark, and its instance number and the burst's seed pick its way, speed and
// life. Nothing simulates: the burst's script only passes the burst's age, so a
// burst is one instanced draw with no CPU or compute work per spark, and none at
// all once it is hidden.
//
// The burst leaves the node's origin (the struck point) in a cone around
// `direction`, `spread` wide (half-angle, radians). A spark the cone sends into
// the struck surface (against `surface_normal`) bounces off it. Each spark flies
// a closed-form path under gravity with air drag (drag per second, so a spark
// slows to a terminal fall of gravity / drag):
//   p(t) = p0 + v_inf t + (v0 - v_inf)(1 - e^(-drag t)) / drag
// It is drawn as a thin streak trailing back along its velocity, as long as the
// distance it covers in `persistence` (what the eye smears a hot speck into),
// turned about its length to face the main camera, the same for both eyes. It
// cools from white-yellow through orange to dull red and thins as it goes.
// Additive and unshaded: a spark only adds light, and overlaps need no sorting.
// Within near_fade of the eyes a spark fades and then collapses to nothing.
//
// Per-burst values are instance uniforms (SparkBurst sets them). The
// MultiMesh's instances keep identity transforms; the node is placed, unturned,
// at the struck point, and the scene's culling box covers the sparks' reach.
render_mode blend_add, unshaded, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled, world_vertex_coords;

group_uniforms motion;
// How quickly air slows a spark, per second.
uniform float drag : hint_range(0.1, 20.0, 0.1) = 3.0;
// The world's pull, in m/s² (the project's default gravity).
uniform float gravity : hint_range(0.0, 20.0, 0.01) = 9.8;
// The shortest and longest a spark lives, in seconds. The burst hides after the
// longest (SparkBurst reads it from the material, which sets it).
uniform vec2 life = vec2(0.18, 0.55);
// A spark's speed, as a share of the burst's speed: the least and the most.
uniform vec2 speed_range = vec2(0.5, 1.25);
// How much of its speed into the struck surface a spark keeps, bouncing off it.
uniform float bounce : hint_range(0.0, 1.0, 0.01) = 0.4;
group_uniforms;

group_uniforms look;
// A fresh spark's width, in metres; it thins to half by the end of its life.
uniform float width : hint_range(0.0005, 0.02, 0.0005) = 0.0025;
// How long the eye smears a spark over, in seconds, which sets the streak's
// length; and the shortest a streak is, in metres.
uniform float persistence : hint_range(0.0, 0.1, 0.001) = 0.025;
uniform float min_length : hint_range(0.0, 0.05, 0.0005) = 0.004;
uniform vec3 hot_color : source_color = vec3(1.0, 0.92, 0.65);
uniform vec3 warm_color : source_color = vec3(1.0, 0.45, 0.08);
uniform vec3 cool_color : source_color = vec3(0.55, 0.06, 0.0);
// Above the environment's glow threshold (1.1) a fresh spark blooms.
uniform float energy : hint_range(0.0, 10.0, 0.01) = 4.0;
group_uniforms;

group_uniforms comfort;
// Distances from the eyes, in metres: sparks fade from the first to the second
// and are gone nearer than it.
uniform vec2 near_fade = vec2(0.3, 0.12);
group_uniforms;

// Seconds since the burst; outside a spark's life it is not drawn.
instance uniform float age = -1.0;
// Picks this burst's random numbers: a whole number below 2^24.
instance uniform float seed = 0.0;
// The way the sparks mainly go, and the struck surface's normal (world space).
instance uniform vec3 direction = vec3(0.0, 1.0, 0.0);
instance uniform vec3 surface_normal = vec3(0.0, 1.0, 0.0);
// The cone's half-angle, in radians; the sparks' mean speed, in m/s; how many
// of the MultiMesh's instances are sparks this burst.
instance uniform float spread = 0.5;
instance uniform float speed = 3.0;
instance uniform float count = 0.0;

varying flat float heat;
varying flat float brightness;

uint hash_uint(uint x) {
	x ^= x >> 16u;
	x *= 2146121005u;
	x ^= x >> 15u;
	x *= 2221713035u;
	x ^= x >> 16u;
	return x;
}

// Four random numbers in 0-1 for one spark of one burst.
vec4 random4(uint spark, uint burst) {
	uint a = hash_uint(spark * 2654435769u ^ hash_uint(burst));
	uint b = hash_uint(a);
	uint c = hash_uint(b);
	uint d = hash_uint(c);
	return vec4(float(a >> 8u), float(b >> 8u), float(c >> 8u), float(d >> 8u)) / 16777216.0;
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec4 random = random4(uint(INSTANCE_ID), uint(seed));
	float lifetime = mix(life.x, life.y, random.w);
	float t = age;
	bool shown = float(INSTANCE_ID) < count && t >= 0.0 && t < lifetime;
	t = max(t, 0.0);

	// Its way out: evenly over the cone's cap.
	vec3 mainly = normalize(direction);
	vec3 helper = abs(mainly.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 u = normalize(cross(mainly, helper));
	vec3 w = cross(mainly, u);
	float cos_off = mix(cos(spread), 1.0, random.x);
	float sin_off = sqrt(max(0.0, 1.0 - cos_off * cos_off));
	float around = random.y * TAU;
	vec3 way = mainly * cos_off + (u * cos(around) + w * sin(around)) * sin_off;
	vec3 v0 = way * speed * mix(speed_range.x, speed_range.y, random.z);
	vec3 normal = normalize(surface_normal);
	float into = dot(v0, normal);
	if (into < 0.0) {
		v0 -= (1.0 + bounce) * into * normal;
	}

	vec3 terminal = vec3(0.0, -gravity / drag, 0.0);
	float slowed = exp(-drag * t);
	vec3 position = origin + terminal * t + (v0 - terminal) * (1.0 - slowed) / drag;
	vec3 velocity = terminal + (v0 - terminal) * slowed;

	heat = 1.0 - t / lifetime;
	float spark_speed = length(velocity);
	vec3 along = spark_speed > 0.0001 ? velocity / spark_speed : mainly;
	float streak = max(min_length, spark_speed * persistence);
	vec3 to_camera = MAIN_CAM_INV_VIEW_MATRIX[3].xyz - position;
	float distance_to_camera = length(to_camera);
	vec3 side = cross(along, to_camera);
	float side_length = length(side);
	side = side_length > 0.000001 ? side / side_length : u;

	float near_alpha = smoothstep(near_fade.y, near_fade.x, distance_to_camera);
	brightness = near_alpha * smoothstep(0.0, 0.15, heat);
	if (!shown || near_alpha <= 0.0) {
		// Every corner on one point: nothing to draw.
		streak = 0.0;
		side = vec3(0.0);
		brightness = 0.0;
	}
	// The head leads at UV.y 0; the tail trails back along the velocity.
	VERTEX = position - along * streak * UV.y + side * (UV.x - 0.5) * width * mix(0.5, 1.0, heat);
	NORMAL = distance_to_camera > 0.0001 ? to_camera / distance_to_camera : vec3(0.0, 1.0, 0.0);
}

void fragment() {
	vec3 color = mix(cool_color, warm_color, smoothstep(0.0, 0.5, heat));
	color = mix(color, hot_color, smoothstep(0.55, 0.9, heat));
	// Soft across the streak, brightest at the head.
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	float alpha = across * across * (1.0 - 0.8 * UV.y) * brightness;
	ALBEDO = color * energy * mix(0.35, 1.0, heat);
	ALPHA = alpha;
}
