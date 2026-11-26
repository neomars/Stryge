shader_type spatial;
// Traînées de projectiles traceurs : rubans additifs colorés par sommet (alpha = intensité).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

void fragment() {
	ALBEDO = vec3(1.0);
	ALPHA = COLOR.a;
}
