shader_type spatial;
// Étincelles et éclats chauds : traînées additives alignées sur la vitesse, calculées sans état.
// Même disposition des données que thermal_debris.gdshader ;
//   MODEL_MATRIX[1].z = longueur de traînée en secondes de vol, INSTANCE_CUSTOM.x = luminosité.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform float t_now = 0.0;
uniform float width_px = 2.2;
uniform float min_len_px = 6.0;

varying float v_a;
varying vec2 v_uv;

const float G = 9.81;

vec3 flight(vec3 p0, vec3 v0, float age) {
	float y0 = max(p0.y, 0.0);
	float t1 = (v0.y + sqrt(v0.y * v0.y + 2.0 * G * y0)) / G;
	float a = min(age, t1);
	vec3 p = vec3(p0.x + v0.x * a, y0 + v0.y * a - 0.5 * G * a * a, p0.z + v0.z * a);
	if (age > t1) {
		// rebond amorti puis arrêt
		float vy = abs(v0.y - G * t1) * 0.3;
		float b = age - t1;
		float t2 = 2.0 * vy / G;
		b = min(b, t2);
		p.x += v0.x * 0.4 * b;
		p.z += v0.z * 0.4 * b;
		p.y = vy * b - 0.5 * G * b * b;
	}
	return p;
}

void vertex() {
	vec3 p0 = MODEL_MATRIX[3].xyz;
	vec3 v0 = MODEL_MATRIX[0].xyz;
	float t0 = MODEL_MATRIX[1].x;
	float life = MODEL_MATRIX[1].y;
	float trail = max(MODEL_MATRIX[1].z, 0.02);
	float age = t_now - t0;
	v_a = 0.0;
	v_uv = UV;
	if (age >= 0.0 && age <= life) {
		vec3 head = flight(p0, v0, age);
		vec3 tail = flight(p0, v0, max(age - trail, 0.0));
		vec4 ch = PROJECTION_MATRIX * VIEW_MATRIX * vec4(head, 1.0);
		vec4 ct = PROJECTION_MATRIX * VIEW_MATRIX * vec4(tail, 1.0);
		vec2 nh = ch.xy / ch.w;
		vec2 nt = ct.xy / ct.w;
		vec2 half_px = VIEWPORT_SIZE * 0.5;
		vec2 dpx = (nh - nt) * half_px;
		float len = length(dpx);
		vec2 dir = (len > 0.01) ? dpx / len : vec2(1.0, 0.0);
		nt -= dir * max(min_len_px - len, 0.0) / half_px;
		vec2 perp = vec2(-dir.y, dir.x) * (width_px * 0.5) / half_px;
		vec2 n = mix(nt, nh, UV.x) + perp * (UV.y * 2.0 - 1.0);
		POSITION = vec4(n, ch.z / ch.w, 1.0);
		float u = age / life;
		v_a = INSTANCE_CUSTOM.x * (1.0 - u) * (1.0 - u) * smoothstep(0.0, 0.03, age);
	} else {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	}
}

void fragment() {
	float across = abs(v_uv.y * 2.0 - 1.0);
	float a = (1.0 - across * across) * mix(0.18, 1.0, v_uv.x);
	ALBEDO = vec3(1.0);
	ALPHA = clamp(a * v_a, 0.0, 1.0);
}
