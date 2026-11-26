shader_type spatial;
// Lueurs additives (flash d'impact, feu) : billboard complet.
// INSTANCE_CUSTOM = (luminosité, type 0 flash / 1 feu, graine, inutilisé).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

varying flat vec4 v_c;
varying vec2 v_uv;

void vertex() {
	v_c = INSTANCE_CUSTOM;
	v_uv = UV;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
}

void fragment() {
	vec2 p = v_uv - 0.5;
	float r = length(p) * 2.0;
	float a;
	if (v_c.y < 0.5) {
		a = smoothstep(1.0, 0.0, r);
		a = a * a;
	} else {
		float ang = atan(p.y, p.x);
		float n = 0.55 + 0.45 * sin(ang * 5.0 + TIME * 6.0 + v_c.z * 40.0) * sin(ang * 3.0 - TIME * 4.3 + v_c.z * 17.0);
		a = smoothstep(n, 0.0, r);
	}
	ALBEDO = vec3(1.0);
	ALPHA = clamp(a * v_c.x, 0.0, 1.0);
}
