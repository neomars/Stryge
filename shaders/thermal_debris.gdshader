shader_type spatial;
// Débris d'explosion : éclats opaques lancés sur une trajectoire balistique avec deux rebonds
// puis un glissement, qui tournent sur eux-mêmes et refroidissent. Calcul 100 % sans état :
// la position ne dépend que des données de naissance et de l'horloge `t_now`.
//
// Disposition des données d'instance (voir particle_set.gd) :
//   MODEL_MATRIX[3].xyz = position de départ     MODEL_MATRIX[0].xyz = vitesse initiale
//   MODEL_MATRIX[1].xyz = (naissance, durée de vie, taille)
//   MODEL_MATRIX[2].xyz = (inutilisé, graine, rotation en rad/s)
//   INSTANCE_CUSTOM     = (inutilisé, chaleur initiale, constante de refroidissement, inutilisé)
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform float t_now = 0.0;
uniform float min_px = 2.6;       // taille minimale à l'écran (pixels) pour qu'un éclat reste visible de loin
uniform float max_boost = 7.0;

varying float v_h;

const float G = 9.81;

float hash11(float x) {
	return fract(sin(x * 127.1 + 17.3) * 43758.5453);
}

vec3 trajectory(vec3 p0, vec3 v0, float age) {
	float y0 = max(p0.y, 0.0);
	float t1 = (v0.y + sqrt(v0.y * v0.y + 2.0 * G * y0)) / G;
	if (age < t1) {
		return vec3(p0.x + v0.x * age, y0 + v0.y * age - 0.5 * G * age * age, p0.z + v0.z * age);
	}
	// premier impact
	vec3 ph = vec3(p0.x + v0.x * t1, 0.0, p0.z + v0.z * t1);
	float vy_hit = abs(v0.y - G * t1);
	vec2 vh1 = v0.xz * 0.55;
	float vy1 = vy_hit * 0.34;
	float t2 = 2.0 * vy1 / G;
	float a2 = age - t1;
	if (a2 < t2) {
		return vec3(ph.x + vh1.x * a2, vy1 * a2 - 0.5 * G * a2 * a2, ph.z + vh1.y * a2);
	}
	// deuxième impact : petit rebond puis glissement freiné
	vec3 ph2 = vec3(ph.x + vh1.x * t2, 0.0, ph.z + vh1.y * t2);
	vec2 vh2 = vh1 * 0.45;
	float vy2 = vy1 * 0.30;
	float t3 = 2.0 * vy2 / G;
	float a3 = a2 - t2;
	if (a3 < t3) {
		return vec3(ph2.x + vh2.x * a3, vy2 * a3 - 0.5 * G * a3 * a3, ph2.z + vh2.y * a3);
	}
	float a4 = a3 - t3;
	vec2 sl = vh2 * 0.4 * (1.0 - exp(-4.0 * a4)) / 4.0;
	return vec3(ph2.x + vh2.x * t3 + sl.x, 0.0, ph2.z + vh2.y * t3 + sl.y);
}

mat3 rot_axis(vec3 ax, float a) {
	float c = cos(a);
	float s = sin(a);
	float t = 1.0 - c;
	return mat3(
		vec3(t * ax.x * ax.x + c, t * ax.x * ax.y + s * ax.z, t * ax.x * ax.z - s * ax.y),
		vec3(t * ax.x * ax.y - s * ax.z, t * ax.y * ax.y + c, t * ax.y * ax.z + s * ax.x),
		vec3(t * ax.x * ax.z + s * ax.y, t * ax.y * ax.z - s * ax.x, t * ax.z * ax.z + c));
}

void vertex() {
	vec3 p0 = MODEL_MATRIX[3].xyz;
	vec3 v0 = MODEL_MATRIX[0].xyz;
	float t0 = MODEL_MATRIX[1].x;
	float life = MODEL_MATRIX[1].y;
	float size = MODEL_MATRIX[1].z;
	float seed = MODEL_MATRIX[2].y;
	float spin = MODEL_MATRIX[2].z;
	float age = t_now - t0;
	v_h = 0.0;
	if (age >= 0.0 && age <= life) {
		vec3 pos = trajectory(p0, v0, age);
		// la rotation ralentit quand l'éclat se pose
		float ang = spin * (1.0 - exp(-1.2 * age)) / 1.2;
		vec3 ax = normalize(vec3(hash11(seed * 3.1) - 0.5, hash11(seed * 5.7) - 0.5, hash11(seed * 7.3) - 0.5) + vec3(0.001));
		vec3 shape = vec3(0.55 + 0.9 * hash11(seed * 11.0), 0.40 + 0.7 * hash11(seed * 13.0), 0.55 + 0.9 * hash11(seed * 17.0));
		vec3 local = rot_axis(ax, ang) * (VERTEX * shape * size);
		// taille minimale en pixels, au prorata de la distance
		float depth = max(-(VIEW_MATRIX * vec4(pos, 1.0)).z, 1.0);
		float ppm = VIEWPORT_SIZE.y * 0.5 * abs(PROJECTION_MATRIX[1][1]) / depth;
		float boost = clamp(min_px / max(size * ppm, 0.0001), 1.0, max_boost);
		local *= boost;
		// l'éclat rétrécit pendant la dernière seconde et demie
		local *= smoothstep(0.0, 1.5, life - age);
		POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(pos + local, 1.0);
		float h0 = INSTANCE_CUSTOM.y;
		float tau = max(INSTANCE_CUSTOM.z, 0.05);
		v_h = mix(0.24, h0, exp(-age / tau));
	} else {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	}
}

void fragment() {
	ALBEDO = vec3(v_h);
}
