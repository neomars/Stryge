shader_type spatial;
// Sol, routes, parcs et eau : la chaleur de base vient de la couleur de sommet
// (r = chaleur, g = amplitude du grain, b = indicateur d'eau).
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform float atmos_k = 0.00005;

varying vec3 v_pos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	v_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float base = COLOR.r;
	float amp = COLOR.g;
	float water = COLOR.b;
	float n = vnoise(v_pos.xz * 0.045) * 0.5 + vnoise(v_pos.xz * 0.23) * 0.3 + vnoise(v_pos.xz * 1.1) * 0.2;
	float heat = base + (n - 0.5) * 0.10 * amp;
	heat += water * 0.02 * sin(v_pos.x * 0.21 + TIME * 0.7) * sin(v_pos.z * 0.17 - TIME * 0.5);
	heat *= exp(-length(VERTEX) * atmos_k);
	ALBEDO = vec3(heat);
}
