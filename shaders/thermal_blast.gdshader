shader_type spatial;
// Boule de feu, éblouissement et onde de choc : effets additifs sans état.
//
//   MODEL_MATRIX[3].xyz = centre   MODEL_MATRIX[1].xyz = (naissance, durée de vie, rayon de départ)
//   MODEL_MATRIX[2].xyz = (rayon final, graine, hauteur d'élévation en m)
//   INSTANCE_CUSTOM     = (luminosité, type, constante de croissance, inutilisé)
//   type 0 = boule de feu (face à la caméra), 1 = onde de choc à plat sur le sol, 2 = éblouissement bref
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform float t_now = 0.0;

varying float v_i;
varying float v_f;
varying float v_age;
varying float v_seed;
varying float v_type;
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
	float t0 = MODEL_MATRIX[1].x;
	float life = MODEL_MATRIX[1].y;
	float s0 = MODEL_MATRIX[1].z;
	float s1 = MODEL_MATRIX[2].x;
	float seed = MODEL_MATRIX[2].y;
	float lift = MODEL_MATRIX[2].z;
	float age = t_now - t0;
	v_i = 0.0;
	v_f = 0.0;
	v_age = age;
	v_seed = seed;
	v_uv = UV;
	v_type = 0.0;
	if (age >= 0.0 && age <= life) {
		float I0 = INSTANCE_CUSTOM.x;
		float type = floor(INSTANCE_CUSTOM.y + 0.5);
		float tau = max(INSTANCE_CUSTOM.z, 0.02);
		v_type = type;
		float u = age / life;
		float grow = 1.0 - exp(-age / tau);
		vec3 pos = p0;
		if (type < 0.5) {
			float r = mix(s0, s1, grow);
			pos.y += lift * (1.0 - exp(-age * 1.4));
			vec3 cam = INV_VIEW_MATRIX[3].xyz;
			pos += normalize(cam - pos) * r * 0.6;
			pos += (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * (2.0 * r);
			v_i = I0 * pow(1.0 - u, 1.8) * smoothstep(0.0, 0.025, age);
		} else if (type < 1.5) {
			pos.y = 0.3;
			pos += vec3(VERTEX.x, 0.0, -VERTEX.y) * (2.0 * s1);
			v_f = grow;
			v_i = I0 * (1.0 - u) * (1.0 - u) * smoothstep(0.0, 0.02, age);
		} else {
			float r = mix(s0, s1, grow);
			vec3 cam = INV_VIEW_MATRIX[3].xyz;
			pos += normalize(cam - pos) * r * 0.6;
			pos += (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * (2.0 * r);
			v_i = I0 * (1.0 - u) * (1.0 - u);
		}
		POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(pos, 1.0);
	} else {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	}
}

void fragment() {
	vec2 p = v_uv * 2.0 - 1.0;
	float d = length(p);
	float a = 0.0;
	if (v_type < 0.5) {
		// boule de feu : cœur très chaud, bord déchiqueté qui s'effrite avec l'âge
		float n = fbm(p * 2.6 + vec2(v_seed * 31.0, v_seed * 7.0) + v_age * 1.8);
		float edge = 0.80 + 0.30 * (n - 0.5) * 2.0;
		a = smoothstep(edge, 0.0, d);
		a = a * a * (0.65 + 0.7 * n);
	} else if (v_type < 1.5) {
		// onde de choc : anneau qui s'étend, irrégulier, avec un voile intérieur
		float ang = atan(p.y, p.x);
		float th = 0.020 + 0.060 * v_f;
		float ring = exp(-pow((d - v_f) / th, 2.0));
		float wob = 0.70 + 0.30 * sin(ang * 7.0 + v_seed * 30.0) * sin(ang * 3.0 - v_seed * 11.0);
		float veil = 0.22 * smoothstep(v_f, 0.0, d) * (1.0 - v_f);
		a = (ring * wob + veil) * (1.0 - smoothstep(0.80, 1.0, d));
	} else {
		a = smoothstep(1.0, 0.0, d);
		a = a * a;
	}
	ALBEDO = vec3(1.0);
	ALPHA = clamp(a * v_i, 0.0, 1.0);
}
