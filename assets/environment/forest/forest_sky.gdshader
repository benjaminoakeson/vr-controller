shader_type sky;

// A bright day over a forest: a clean blue dome, a warm sun with a haze around
// it, and big soft cumulus drifting past.
//
// Everything here is deliberately HIGH KEY. The sky is the largest thing on
// screen and it sets the mood before the player has looked at anything else, so
// the blue is kept light rather than deep, the horizon burns off almost to white
// the way a hazy summer one does, and the clouds are lit from the sun's side so
// they read as fluffy rather than as grey lids.
//
// The sun follows the level's own DirectionalLight rather than a direction of
// its own, so the disc in the sky is where the shadows say it is. A level with
// no light falls back to `sun_from`.

group_uniforms Sky;
uniform vec4 zenith : source_color = vec4(0.30, 0.56, 0.92, 1.0);
uniform vec4 horizon : source_color = vec4(0.80, 0.90, 0.98, 1.0);

// What shows below the horizon. The levels float, so this is on screen far more
// than it would be in a game with ground -- a warm, hazy green reads as "there
// is a forest down there" where black reads as a hole.
uniform vec4 below_horizon : source_color = vec4(0.36, 0.44, 0.32, 1.0);

// How quickly the blue gives way to the pale horizon. Lower spreads the haze
// further up the dome.
uniform float horizon_falloff : hint_range(0.1, 4.0) = 0.55;

group_uniforms Sun;
uniform vec4 sun_colour : source_color = vec4(1.0, 0.96, 0.86, 1.0);
uniform float sun_size_degrees : hint_range(0.5, 20.0) = 4.0;
uniform float sun_energy : hint_range(0.0, 20.0) = 9.0;

// The warm bloom of sky around the sun. Tight and strong is a hard glare; wide
// and soft is a summer haze.
uniform vec4 sun_haze : source_color = vec4(1.0, 0.93, 0.75, 1.0);
uniform float haze_spread : hint_range(1.0, 64.0) = 7.0;
uniform float haze_strength : hint_range(0.0, 2.0) = 0.55;

// Used only when the level has no DirectionalLight to take the sun from.
uniform vec3 sun_from = vec3(0.35, 0.55, 0.75);

group_uniforms Clouds;
uniform sampler3D cloud_noise : filter_linear, repeat_enable;
uniform vec4 cloud_lit : source_color = vec4(1.0, 0.99, 0.96, 1.0);
uniform vec4 cloud_shaded : source_color = vec4(0.72, 0.78, 0.88, 1.0);

// Bigger makes the clouds smaller and more numerous.
uniform float cloud_scale : hint_range(0.05, 2.0) = 0.5;

// How much of the sky they cover. This is the mood knob: low is a few fair
// weather puffs, high is an overcast lid, and the point of a happy sky is to
// stay well down this range.
uniform float coverage : hint_range(0.0, 1.0) = 0.6;
uniform float cloud_softness : hint_range(0.01, 0.6) = 0.16;
uniform float drift_speed : hint_range(0.0, 0.2) = 0.012;


void sky() {
	vec3 dir = normalize(EYEDIR);
	float up = dir.y;

	// The sun the level is actually lit by, so the disc and the shadows agree.
	//
	// LIGHT0_DIRECTION already points TOWARDS the light in a sky shader -- it is
	// not the direction the light travels, which is what a DirectionalLight's own
	// -Z basis gives you. Negating it puts the sun underground, where it lights
	// the level perfectly and cannot be found anywhere in the sky.
	vec3 sun = LIGHT0_ENABLED ? normalize(LIGHT0_DIRECTION) : normalize(sun_from);
	float towards_sun = dot(dir, sun);

	// The dome. Blue overhead easing to a pale, almost-white horizon, and a soft
	// green below it rather than a hard edge into nothing.
	vec3 colour = mix(horizon.rgb, zenith.rgb, pow(clamp(up, 0.0, 1.0), horizon_falloff));
	colour = mix(colour, below_horizon.rgb, smoothstep(0.0, -0.22, up));

	// Haze first, so the clouds sit in front of it rather than under it.
	colour += sun_haze.rgb * pow(max(towards_sun, 0.0), haze_spread) * haze_strength;

	// Clouds live on a plane rather than on the dome, so they crowd towards the
	// horizon the way real ones do instead of being pasted evenly over the sky.
	// Dividing by `up` is what does it; the floor stops the division running away
	// to infinity at the horizon itself.
	if (up > 0.0) {
		vec3 plane = dir / max(up, 0.09) * cloud_scale;
		plane += vec3(TIME * drift_speed, 0.0, TIME * drift_speed * 0.6);

		// Two reads at different sizes: the big one is the cloud, the small one
		// is its ragged edge. Cheaper than a full fbm and enough at this scale.
		float shape = texture(cloud_noise, plane).r * 0.68
				+ texture(cloud_noise, plane * 2.7 + 4.1).r * 0.32;

		float cloud = smoothstep(coverage, coverage + cloud_softness, shape);

		// Away from the horizon only. Down at the rim the plane projection
		// stretches the noise into streaks, so it is faded out before it shows.
		cloud *= smoothstep(0.0, 0.30, up);

		// Lit from the sun's side. Reading the noise again a short step TOWARDS
		// the sun says whether there is more cloud that way -- if there is, this
		// bit is in its shadow; if there is not, it is the edge catching the
		// light. That one extra read is most of what makes them look solid.
		float towards = texture(cloud_noise, plane + sun * 0.12).r;
		float lit = smoothstep(0.0, 0.3, shape - towards);
		vec3 body = mix(cloud_shaded.rgb, cloud_lit.rgb, clamp(lit + 0.35, 0.0, 1.0));

		colour = mix(colour, body, cloud);
	}

	// The disc last, so nothing is drawn over it.
	float edge = radians(sun_size_degrees);
	float angle = acos(clamp(towards_sun, -1.0, 1.0));
	colour += sun_colour.rgb * (1.0 - smoothstep(edge * 0.75, edge, angle)) * sun_energy;

	COLOR = colour;
}
