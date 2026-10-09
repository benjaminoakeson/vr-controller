// An inventory slot's glass (2026-10-06, documents/inventory.md): a very clear
// flat bubble (SlotBubbleMesh, 2026-10-07; a flat pane before). Nearly
// invisible face on; where its surface turns away from the eye, toward the
// rounded rim, it grows more opaque and brighter (a Fresnel rim), which gives
// it a discernible edge and its depth. Lit, smooth and premultiplied, so the
// sky's reflection and the sun's highlight show at full strength on glass
// that is otherwise nearly transparent. Double-sided: the far wall shows
// faintly through the near one (the mesh draws back to front). No refraction:
// cheap on the Mobile renderer.
shader_type spatial;
render_mode blend_premul_alpha, cull_disabled, depth_draw_never, specular_schlick_ggx;

uniform vec3 tint : source_color = vec3(0.86, 0.95, 1.0);
// Face on, how opaque it is...
uniform float fill_alpha : hint_range(0.0, 1.0, 0.01) = 0.03;
// ...and how much more toward the rim, and how tightly that hugs the rim.
uniform float rim_alpha : hint_range(0.0, 1.0, 0.01) = 0.85;
uniform float rim_power : hint_range(0.5, 8.0, 0.1) = 1.6;
// How much the rim glows of itself, so it shows in shade too.
uniform float rim_glow : hint_range(0.0, 1.0, 0.01) = 0.3;
uniform float roughness : hint_range(0.0, 1.0, 0.01) = 0.06;

void fragment() {
	float facing = clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0);
	float rim = pow(1.0 - facing, rim_power);
	float alpha = clamp(fill_alpha + rim * rim_alpha, 0.0, 1.0);
	ALBEDO = tint;
	ALPHA = alpha;
	// Only the diffuse light is weighed by alpha; reflections and highlights
	// stay whole.
	PREMUL_ALPHA_FACTOR = alpha;
	ROUGHNESS = roughness;
	SPECULAR = 0.5;
	EMISSION = tint * rim * rim_glow;
}
