shader_type spatial;
// Fumée légère, poussière et traces de brûlure : bouffées translucides sans état.
// Elles dérivent avec le vent, montent, grossissent et refroidissent. Mélange normal (pas additif) :
// une fumée chaude éclaircit le fond, une poussière froide l'estompe un peu.
//
// Disposition des données d'instance (voir particle_set.gd) :
//   MODEL_MATRIX[3].xyz = position de départ     MODEL_MATRIX[0].xyz = vitesse initiale
//   MODEL_MATRIX[1].xyz = (naissance, durée de vie, taille de départ)
//   MODEL_MATRIX[2].xyz = (taille finale, graine, flottabilité en m/s)
//   INSTANCE_CUSTOM     = (opacité, chaleur initiale, constante de refroidissement, type + chaleur finale)
//   type 0 = bouffée (face à la caméra), 1 = trace de brûlure à plat sur le sol
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform float t_now = 0.0;
uniform vec3 wind = vec3(2.4, 0.0, -0.9);
uniform float drag = 0.9;

varying float v_a;
varying float v_h;
varying float v_age;
varying float v_seed;
varying float v_kind;
varying vec2 v_uv;

float h21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	return 0.55 * vnoise(p) + 0.30 * vnoise(p * 2.1 + 7.3) + 0.15 * vnoise(p * 4.3 + 3.1);
}

void vertex() {
	vec3 p0 = MODEL_MATRIX[3].xyz;
	vec3 v0 = MODEL_MATRIX[0].xyz;
	float t0 = MODEL_MATRIX[1].x;
	float life = MODEL_MATRIX[1].y;
	float s0 = MODEL_MATRIX[1].z;
	float s1 = MODEL_MATRIX[2].x;
	float seed = MODEL_MATRIX[2].y;
	float buoy = MODEL_MATRIX[2].z;
	float age = t_now - t0;
	v_a = 0.0;
	v_uv = UV;
	v_age = age;
	v_seed = seed;
	v_kind = 0.0;
	v_h = 0.3;
	if (age >= 0.0 && age <= life) {
		float a0 = INSTANCE_CUSTOM.x;
		float h0 = INSTANCE_CUSTOM.y;
		float tau = max(INSTANCE_CUSTOM.z, 0.05);
		float kind = floor(INSTANCE_CUSTOM.w + 0.001);
		float h_end = fract(INSTANCE_CUSTOM.w + 0.001);
		v_kind = kind;
		float u = age / life;
		float size = mix(s0, s1, sqrt(u));
		float fade_in = smoothstep(0.0, 0.07 * life + 0.12, age);
		float fade_out = 1.0 - smoothstep(0.40, 1.0, u);
		v_a = a0 * fade_in * fade_out;
		v_h = mix(h_end, h0, exp(-age / tau));
		vec3 pos = p0 + v0 * (1.0 - exp(-drag * age)) / drag;
		if (kind < 0.5) {
			pos.y += buoy * age * (1.0 - 0.4 * u);
			pos += wind * age * (0.25 + 0.75 * smoothstep(0.0, 5.0, age));
			// la bouffée est poussée vers la caméra de son rayon : elle ne coupe pas les toits et les façades
			vec3 cam = INV_VIEW_MATRIX[3].xyz;
			pos += normalize(cam - pos) * size * 0.55;
			vec3 right = INV_VIEW_MATRIX[0].xyz;
			vec3 up = INV_VIEW_MATRIX[1].xyz;
			pos += (right * VERTEX.x + up * VERTEX.y) * size;
		} else {
			pos.y = 0.18;
			pos += vec3(VERTEX.x, 0.0, -VERTEX.y) * size;
		}
		POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(pos, 1.0);
	} else {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	}
}

void fragment() {
	vec2 p = v_uv * 2.0 - 1.0;
	float ca = cos(v_seed * 6.2831);
	float sa = sin(v_seed * 6.2831);
	vec2 q = vec2(ca * p.x - sa * p.y, sa * p.x + ca * p.y);
	float d = length(q);
	float n = fbm(q * 1.7 + vec2(v_seed * 37.0, v_seed * 11.0) + v_age * 0.10);
	float shape;
	if (v_kind < 0.5) {
		shape = smoothstep(1.0, 0.12, d + (n - 0.5) * 0.9);
		shape *= 0.50 + 0.50 * n;
	} else {
		shape = smoothstep(1.0, 0.45, d + (n - 0.5) * 0.6);
		shape *= 0.75 + 0.25 * n;
	}
	ALBEDO = vec3(v_h);
	ALPHA = clamp(shape * v_a, 0.0, 1.0);
}
