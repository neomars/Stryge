shader_type spatial;
// Personnages 3D : maillage humanoïde articulé, animé entièrement ici (squelette procédural).
// INSTANCE_CUSTOM = (chaleur, type + graine d'apparence, phase de pas, allure)
//   type : 0 zombie, 1 civil, 2 civil dévoré (au sol), 3 cadavre de civil, 4 cadavre de zombie ;
//          la graine est la partie fractionnaire (0..0.999) : elle choisit la morphologie, les vêtements,
//          les cheveux, le sac, le manteau, le style de course ou de démarche
//   allure (type 0/1) : 0 à l'arrêt, ~0.3 marche, ~1 course ; zombie : 3 = martèle une porte,
//          4 = dévore, 5..6 = se relève (5 + degré de chute) ; corps (type 2..4) : 0..1 = degré de chute
// Le canal vert / bleu de la sortie porte le marquage « zombie » / « civil » lu par le post-traitement.
//
// Marche et course : cycle à phase de pied (attaque du talon, appui, décollement, balancé) dont l'amplitude de
// hanche est calée sur la longueur de foulée du simulateur (pas de glissade des pieds) ; le bassin est posé de
// façon que le pied le plus bas touche toujours le sol. Les os sont décrits dans scripts/world/human_mesh.gd.
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform float atmos_k = 0.00005;
uniform float min_px = 24.0;      // hauteur nominale minimale à l'écran (pixels) : en dessous, on grossit
uniform float max_boost = 4.2;    // grossissement maximal appliqué pour garder la lisibilité de loin
uniform bool debug_gray = false;  // sortie en gris (banc d'essai des poses)

varying flat vec4 v_cust;
varying float v_heat;             // chaleur de la zone (lissée entre sommets)
varying float v_cloth;            // 1 sur un vêtement, 0 sur la peau
varying float v_up;               // composante verticale de la normale (monde)
varying vec3 v_lp;                // position de repos : sert aux motifs (plis, déchirures)
varying flat vec4 v_var;          // x : déchirures, y : sang, w : décalage de motif

// articulations (repère du maillage, voir human_mesh.gd)
const vec3 HIPC = vec3(0.0, 0.93, 0.0);
const vec3 WAIST = vec3(0.0, 1.04, 0.0);
const vec3 NECK = vec3(0.0, 1.50, 0.0);
const vec3 CROWN = vec3(0.0, 1.74, 0.06);
const vec3 SH_R = vec3(0.192, 1.425, 0.0);
const vec3 EL_R = vec3(0.208, 1.14, 0.0);
const vec3 WR_R = vec3(0.211, 0.865, 0.0);
const vec3 HIP_R = vec3(0.092, 0.935, 0.0);
const vec3 KN_R = vec3(0.094, 0.50, -0.004);
const vec3 AN_R = vec3(0.095, 0.085, 0.0);

const float LEG_REACH = 1.69;     // 2 x (cuisse + mollet)
const float REST_FOOT = -0.925;   // bas du pied sous la hanche, jambe tendue

struct Pose {
	float pel_yaw;  float pel_roll;  float pel_pitch;  float sway;
	float lean;     float twist;     float roll;
	float hpitch;   float hroll;     float hyaw;
	float sh_r;     float sh_l;      float sp_r;       float sp_l;
	float el_r;     float el_l;      float wr_r;       float wr_l;
	float hip_r;    float hip_l;     float ls_r;       float ls_l;
	float kn_r;     float kn_l;      float psi_r;      float psi_l;
	float lie;      float fly;
	float an_r;     float an_l;      float bob;
};

float hash11(float x) {
	return fract(sin(x * 127.1 + 17.3) * 43758.5453);
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
			mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

// rotations autour d'un pivot : la position et la normale tournent ensemble
void rot_x(inout vec3 p, inout vec3 n, vec3 pv, float a) {
	float c = cos(a);
	float s = sin(a);
	vec3 q = p - pv;
	p = pv + vec3(q.x, q.y * c - q.z * s, q.y * s + q.z * c);
	n = vec3(n.x, n.y * c - n.z * s, n.y * s + n.z * c);
}

void rot_y(inout vec3 p, inout vec3 n, vec3 pv, float a) {
	float c = cos(a);
	float s = sin(a);
	vec3 q = p - pv;
	p = pv + vec3(q.x * c + q.z * s, q.y, -q.x * s + q.z * c);
	n = vec3(n.x * c + n.z * s, n.y, -n.x * s + n.z * c);
}

void rot_z(inout vec3 p, inout vec3 n, vec3 pv, float a) {
	float c = cos(a);
	float s = sin(a);
	vec3 q = p - pv;
	p = pv + vec3(q.x * c - q.y * s, q.x * s + q.y * c, q.z);
	n = vec3(n.x * c - n.y * s, n.x * s + n.y * c, n.z);
}

Pose pose_rest() {
	Pose o;
	o.pel_yaw = 0.0; o.pel_roll = 0.0; o.pel_pitch = 0.0; o.sway = 0.0;
	o.lean = 0.0; o.twist = 0.0; o.roll = 0.0;
	o.hpitch = 0.0; o.hroll = 0.0; o.hyaw = 0.0;
	o.sh_r = 0.0; o.sh_l = 0.0; o.sp_r = 0.07; o.sp_l = 0.07;
	o.el_r = 0.15; o.el_l = 0.15; o.wr_r = 0.0; o.wr_l = 0.0;
	o.hip_r = 0.0; o.hip_l = 0.0; o.ls_r = 0.0; o.ls_l = 0.0;
	o.kn_r = 0.04; o.kn_l = 0.04; o.psi_r = 0.0; o.psi_l = 0.0;
	o.lie = 0.0; o.fly = 0.0;
	o.an_r = 0.0; o.an_l = 0.0; o.bob = 0.0;
	return o;
}

Pose pose_mix(Pose a, Pose b, float t) {
	Pose o;
	o.pel_yaw = mix(a.pel_yaw, b.pel_yaw, t); o.pel_roll = mix(a.pel_roll, b.pel_roll, t);
	o.pel_pitch = mix(a.pel_pitch, b.pel_pitch, t); o.sway = mix(a.sway, b.sway, t);
	o.lean = mix(a.lean, b.lean, t); o.twist = mix(a.twist, b.twist, t); o.roll = mix(a.roll, b.roll, t);
	o.hpitch = mix(a.hpitch, b.hpitch, t); o.hroll = mix(a.hroll, b.hroll, t); o.hyaw = mix(a.hyaw, b.hyaw, t);
	o.sh_r = mix(a.sh_r, b.sh_r, t); o.sh_l = mix(a.sh_l, b.sh_l, t);
	o.sp_r = mix(a.sp_r, b.sp_r, t); o.sp_l = mix(a.sp_l, b.sp_l, t);
	o.el_r = mix(a.el_r, b.el_r, t); o.el_l = mix(a.el_l, b.el_l, t);
	o.wr_r = mix(a.wr_r, b.wr_r, t); o.wr_l = mix(a.wr_l, b.wr_l, t);
	o.hip_r = mix(a.hip_r, b.hip_r, t); o.hip_l = mix(a.hip_l, b.hip_l, t);
	o.ls_r = mix(a.ls_r, b.ls_r, t); o.ls_l = mix(a.ls_l, b.ls_l, t);
	o.kn_r = mix(a.kn_r, b.kn_r, t); o.kn_l = mix(a.kn_l, b.kn_l, t);
	o.psi_r = mix(a.psi_r, b.psi_r, t); o.psi_l = mix(a.psi_l, b.psi_l, t);
	o.lie = mix(a.lie, b.lie, t); o.fly = mix(a.fly, b.fly, t);
	o.an_r = 0.0; o.an_l = 0.0; o.bob = 0.0;
	return o;
}

// ------------------------------------------------------------------ marche et course

// jambe : u = position dans le cycle (0 = attaque du talon), beta = part d'appui.
// hn : balancement de hanche normalisé (+1 jambe devant, -1 derrière) ; en appui il décroît linéairement, ce qui
// garde le pied immobile par rapport au sol (le bassin avance à vitesse constante). En phase aérienne, une courbe
// d'Hermite raccorde les vitesses pour éviter toute saccade au décollement et à l'attaque.
// kn : flexion du genou ; psi : inclinaison absolue du pied (positif = pointe en haut).
void leg_cycle(float u, float beta, float k_ld, float k_ps, float k_sw, float run,
		out float hn, out float kn, out float psi) {
	float heel = 0.30 - 0.18 * run;
	float toe = -0.70 - 0.20 * run;
	float m = -2.0 * (1.0 - beta) / beta;   // pente de raccordement (par unité d'avancement du balancé)
	if (u < beta) {
		float s = u / beta;
		hn = 1.0 - 2.0 * s;
		kn = k_ld * sin(PI * clamp(s * 2.2, 0.0, 1.0)) + k_ps * smoothstep(0.55, 1.0, s);
		psi = mix(heel, 0.0, smoothstep(0.0, 0.14, s)) + toe * smoothstep(0.62, 1.0, s);
	} else {
		float s = (u - beta) / (1.0 - beta);
		float s2 = s * s;
		float s3 = s2 * s;
		hn = (2.0 * s3 - 3.0 * s2 + 1.0) * -1.0 + (s3 - 2.0 * s2 + s) * m
				+ (-2.0 * s3 + 3.0 * s2) + (s3 - s2) * m;
		kn = k_sw * sin(PI * pow(s, 0.72)) + k_ps * (1.0 - smoothstep(0.0, 0.30, s));
		psi = mix(toe, heel, smoothstep(0.0, 0.85, s));
	}
}

// jambes d'une marche ou d'une course ; zf < 1 raidit les genoux (zombie)
void walk_legs(inout Pose o, float ph, float g, float zf,
		out float hn_l, out float hn_r, out float run, out float mv, out float osc) {
	run = smoothstep(0.35, 0.95, g);
	mv = smoothstep(0.02, 0.18, g);
	float stride = mix(1.25, 2.6, run);
	float beta = mix(0.62, 0.38, run);
	float sin_a = clamp(stride * beta / LEG_REACH, 0.0, 0.95);
	float k_ld = mix(0.14, 0.50, run) * zf;
	float k_ps = mix(0.45, 0.85, run) * zf;
	float k_sw = mix(0.85, 1.35, run) * zf;
	float ul = fract(ph / TAU);
	float ur = fract(ph / TAU + 0.5);
	float kl; float kr; float pl; float pr;
	leg_cycle(ul, beta, k_ld, k_ps, k_sw, run, hn_l, kl, pl);
	leg_cycle(ur, beta, k_ld, k_ps, k_sw, run, hn_r, kr, pr);
	o.hip_l = asin(clamp(sin_a * hn_l, -0.98, 0.98)) * mv;
	o.hip_r = asin(clamp(sin_a * hn_r, -0.98, 0.98)) * mv;
	o.kn_l = 0.04 + kl * mv;
	o.kn_r = 0.04 + kr * mv;
	o.psi_l = pl * mv;
	o.psi_r = pr * mv;
	osc = cos(TAU * (ul - beta * 0.5));   // +1 : appui gauche à mi-course
	float fl = 0.0;
	if (beta < 0.5) {
		if (ul >= beta && ul < 0.5) {
			fl = sin(PI * (ul - beta) / (0.5 - beta));
		} else if (ul >= 0.5 + beta) {
			fl = sin(PI * (ul - 0.5 - beta) / (0.5 - beta));
		}
	}
	o.fly = fl * run * mv;
}

// civil : marche ou course d'un être humain qui fuit, buste droit, bras qui pompent
Pose civil_pose(float seed, float ph, float g) {
	Pose o = pose_rest();
	float hn_l; float hn_r; float run; float mv; float osc;
	walk_legs(o, ph, g, 1.0, hn_l, hn_r, run, mv, osc);
	float style = hash11(seed * 19.0 + 1.0);
	float idle = 1.0 - mv;
	o.pel_yaw = -0.09 * mv * (0.6 + 0.8 * run) * hn_l;
	o.twist = 0.20 * mv * (0.6 + 0.9 * run) * hn_l;
	o.pel_roll = -0.04 * mv * (0.7 + 0.5 * run) * osc + 0.03 * idle * sin(TIME * 0.5 + seed * 10.0);
	o.sway = -0.03 * mv * osc;
	o.pel_pitch = mv * mix(0.04, 0.10, run);
	o.lean = mv * mix(0.05, 0.24 + 0.08 * (style - 0.5), run) + idle * (0.02 + 0.02 * sin(TIME * 1.6 + seed * 20.0));
	o.roll = -0.5 * o.pel_roll;
	float glance = smoothstep(0.55, 0.85, sin(TIME * 0.8 + seed * 40.0)) * run;
	o.hpitch = -0.63 * (o.lean + o.pel_pitch);
	o.hroll = -0.8 * (o.roll + o.pel_roll);
	o.hyaw = ((style > 0.5) ? 0.9 : -0.9) * glance + 0.08 * sin(TIME * 0.9 + seed * 7.0) * idle;
	float arm = mix(0.50, 0.95, run) * mv * (0.85 + 0.3 * style);
	o.sh_r = arm * hn_l + 0.10 * run * mv;
	o.sh_l = arm * hn_r + 0.10 * run * mv;
	float fw_r = clamp(0.5 + 0.5 * hn_l, 0.0, 1.0);
	float fw_l = clamp(0.5 + 0.5 * hn_r, 0.0, 1.0);
	float eb = mix(0.12, 1.25, run) * mv + 0.12;
	o.el_r = eb + (0.20 + 0.25 * run) * fw_r * mv;
	o.el_l = eb + (0.20 + 0.25 * run) * fw_l * mv;
	o.sp_r = 0.07 + 0.05 * run;
	o.sp_l = o.sp_r;
	o.wr_r = 0.08 + 0.30 * run * mv;
	o.wr_l = o.wr_r;
	return o;
}

// zombie : buste voûté, bras tendus ou ballants selon l'individu, jambe qui traîne, tête ballante
Pose zombie_pose(float seed, float ph_in, float g) {
	Pose o = pose_rest();
	float s1 = hash11(seed * 19.0 + 1.0);
	float s2 = hash11(seed * 23.0 + 2.0);
	float s3 = hash11(seed * 29.0 + 3.0);
	float s4 = hash11(seed * 31.0 + 4.0);
	float ph = ph_in + 0.30 * sin(ph_in * 0.5 + seed * 17.0);
	float hn_l; float hn_r; float run; float mv; float osc;
	walk_legs(o, ph, g, 0.88, hn_l, hn_r, run, mv, osc);
	float idle = 1.0 - mv;
	// jambe qui traîne
	if (s1 > 0.5) {
		o.hip_r *= 0.55;
		o.kn_r = 0.04 + (o.kn_r - 0.04) * 0.25;
		o.psi_r = mix(o.psi_r, -0.32, 0.7 * mv);
	} else {
		o.hip_l *= 0.55;
		o.kn_l = 0.04 + (o.kn_l - 0.04) * 0.25;
		o.psi_l = mix(o.psi_l, -0.32, 0.7 * mv);
	}
	float w1 = sin(ph * 0.7 + s1 * 6.0);
	float w2 = sin(ph * 0.6 + s2 * 6.0);
	float up = mix(0.55, 1.0, mv);
	float shr; float shl; float elr; float ell; float wr;
	if (s4 < 0.40) {
		// bras tendus devant, poignets ballants
		shr = (1.30 + 0.10 * w1) * up;
		shl = (1.05 + 0.14 * w2) * up;
		elr = 0.20 + 0.14 * w2;
		ell = 0.34 + 0.14 * w1;
		wr = -0.75;
	} else if (s4 < 0.65) {
		// un bras levé, l'autre pendant
		shr = (1.75 + 0.12 * w1) * up;
		shl = 0.20 + 0.30 * hn_r * mv;
		elr = 0.55 + 0.15 * w2;
		ell = 0.25;
		wr = -0.55;
	} else if (s4 < 0.85) {
		// bras ballants, épaules tombantes
		shr = 0.40 + 0.35 * hn_l * mv + 0.08 * w1;
		shl = 0.40 + 0.35 * hn_r * mv + 0.08 * w2;
		elr = 0.42;
		ell = 0.46;
		wr = -0.40;
	} else {
		// les deux bras levés
		shr = (1.90 + 0.10 * w1) * up;
		shl = (1.80 + 0.12 * w2) * up;
		elr = 0.80 + 0.10 * w2;
		ell = 0.70 + 0.10 * w1;
		wr = -0.50;
	}
	// à la course, les bras battent l'air
	o.sh_r = mix(shr, 0.95 + 0.60 * hn_l, run * 0.7);
	o.sh_l = mix(shl, 0.95 + 0.60 * hn_r, run * 0.7);
	o.el_r = elr + 0.30 * run;
	o.el_l = ell + 0.30 * run;
	o.wr_r = wr;
	o.wr_l = wr;
	o.sp_r = 0.10;
	o.sp_l = 0.10 + 0.10 * s2;
	o.lean = 0.28 + 0.12 * run + 0.12 * s2 + 0.05 * sin(TIME * 1.3 + seed * 30.0) * idle;
	o.pel_pitch = 0.06 + 0.04 * s2;
	o.roll = (s3 - 0.5) * 0.22 + 0.05 * sin(ph * 0.5) * mv + 0.04 * sin(TIME * 0.9 + seed * 20.0) * idle;
	o.twist = 0.15 * hn_l * mv;
	o.pel_yaw = -0.08 * hn_l * mv;
	o.pel_roll = -0.05 * osc * mv;
	o.sway = -0.025 * osc * mv;
	o.hpitch = 0.30 + 0.15 * s1 + ((s4 > 0.65 && s4 < 0.85) ? 0.25 : 0.0);
	o.hroll = (s2 - 0.5) * 0.6 + 0.12 * sin(ph * 1.7 + s3 * 6.0);
	o.hyaw = 0.35 * sin(TIME * 0.4 + seed * 30.0) * idle + 0.15 * sin(ph * 0.5 + s2 * 9.0) * mv;
	return o;
}

// zombie qui martèle une porte : bras levés puis rabattus, buste qui accompagne le coup
Pose pound_pose(float seed, float ph) {
	Pose o = pose_rest();
	float k = 0.5 + 0.5 * sin(ph);
	float k2 = 0.5 + 0.5 * sin(ph - 0.5);
	o.sh_r = mix(0.75, 2.05, k);
	o.sh_l = mix(0.75, 2.05, k2);
	o.el_r = mix(0.2, 0.7, k);
	o.el_l = mix(0.2, 0.7, k2);
	o.sp_r = 0.16;
	o.sp_l = 0.16;
	o.wr_r = -0.30;
	o.wr_l = -0.30;
	o.lean = 0.12 + 0.30 * (1.0 - k);
	o.pel_pitch = 0.08;
	o.hpitch = 0.20;
	o.hyaw = 0.10 * sin(ph * 0.5);
	o.hip_l = 0.20;
	o.hip_r = -0.18;
	o.kn_l = 0.16;
	o.kn_r = 0.12;
	o.ls_l = 0.10;
	o.ls_r = 0.10;
	return o;
}

// zombie qui dévore : accroupi, penché presque à l'horizontale, bras vers sa proie, secousses de la tête
Pose feed_pose(float seed, float ph) {
	Pose o = pose_rest();
	float sh = 0.5 + 0.5 * sin(ph * 6.0);
	o.pel_pitch = 0.40;
	o.lean = 0.62 + 0.08 * sh;
	o.sh_r = 0.80;
	o.sh_l = 1.00;
	o.el_r = 0.90 + 0.30 * sh;
	o.el_l = 0.70 + 0.30 * (1.0 - sh);
	o.sp_r = 0.12;
	o.sp_l = 0.12;
	o.wr_r = -0.4;
	o.wr_l = -0.4;
	o.hpitch = 0.10 + 0.30 * sh;
	o.hroll = 0.20 * sin(ph * 4.0);
	o.hip_l = 0.75;
	o.hip_r = 0.50;
	o.kn_l = 1.05;
	o.kn_r = 0.80;
	o.ls_l = 0.12;
	o.ls_r = 0.12;
	return o;
}

// corps au sol : membres écartés, tressaillements tant que le corps se fait dévorer
Pose lie_pose(float seed, float ph, float twitch) {
	Pose o = pose_rest();
	float s1 = hash11(seed * 19.0 + 1.0);
	float s2 = hash11(seed * 23.0 + 2.0);
	float s3 = hash11(seed * 29.0 + 3.0);
	o.sh_r = 0.3 + 0.9 * s1 + twitch * 0.35 * sin(ph * 1.3);
	o.sh_l = 0.2 + 0.9 * s2 + twitch * 0.35 * sin(ph * 1.7 + 1.0);
	o.sp_r = 0.5 + 0.8 * s2;
	o.sp_l = 0.5 + 0.8 * s3;
	o.el_r = 0.3 + 0.6 * s3;
	o.el_l = 0.3 + 0.6 * s1;
	o.wr_r = -0.3 * s1;
	o.wr_l = -0.3 * s2;
	o.hip_r = 0.15 + 0.35 * s2;
	o.hip_l = -0.10 - 0.30 * s3;
	o.ls_r = 0.12 + 0.20 * s1;
	o.ls_l = 0.12 + 0.20 * s3;
	o.kn_r = 0.2 + 0.5 * s3 + twitch * 0.2 * sin(ph * 2.1);
	o.kn_l = 0.2 + 0.4 * s1;
	o.psi_r = -0.4;
	o.psi_l = -0.4;
	o.hroll = (s1 - 0.5) * 0.8;
	o.hpitch = (s2 - 0.5) * 0.5;
	o.roll = (s3 - 0.5) * 0.2;
	return o;
}

// angles du pied et hauteur du bassin : le pied le plus bas touche le sol
void finalize(inout Pose o) {
	float hr = o.hip_r - o.pel_pitch;
	float hl = o.hip_l - o.pel_pitch;
	o.an_r = o.psi_r - (hr - o.kn_r);
	o.an_l = o.psi_l - (hl - o.kn_l);
	float cr = cos(o.psi_r);
	float sr = sin(o.psi_r);
	float cl = cos(o.psi_l);
	float sl = sin(o.psi_l);
	float low_r = min(-0.075 * cr - 0.062 * sr, -0.065 * cr + 0.235 * sr);
	float low_l = min(-0.075 * cl - 0.062 * sl, -0.065 * cl + 0.235 * sl);
	float y_r = -(0.435 * cos(hr) + 0.415 * cos(hr - o.kn_r)) + low_r;
	float y_l = -(0.435 * cos(hl) + 0.415 * cos(hl - o.kn_l)) + low_l;
	o.bob = (REST_FOOT - min(y_r, y_l)) * (1.0 - abs(o.lie)) + 0.07 * o.fly;
}

// ------------------------------------------------------------------ chaleur des zones

float zone_heat(int rg, float ins_t, float ins_l, bool short_sl, bool bald, bool coat) {
	float c_top = coat ? ins_t - 0.10 : ins_t;
	if (rg == 0 || rg == 4) {
		return 1.0;
	} else if (rg == 1) {
		return c_top;
	} else if (rg == 2) {
		return short_sl ? 0.97 : c_top * 0.97;
	} else if (rg == 3) {
		return short_sl ? 1.0 : c_top * 0.94;
	} else if (rg == 5) {
		return ins_l;
	} else if (rg == 6) {
		return ins_l * 0.90;
	} else if (rg == 7) {
		return 0.42;
	} else if (rg == 8) {
		return bald ? 1.0 : 0.60;
	} else if (rg == 9) {
		return 0.62;
	} else if (rg == 10) {
		return 0.38;
	}
	return 0.50;
}

void vertex() {
	v_cust = INSTANCE_CUSTOM;
	float kind = floor(v_cust.y + 0.001);
	float seed = fract(v_cust.y);
	float ph = v_cust.z;
	float g = v_cust.w;
	int bone = int(UV2.x + 0.5);
	int region = int(UV2.y + 0.5);
	int acc = int(UV.x + 0.5);
	float cav = UV.y;

	// ---- apparence tirée de la graine
	float fem = step(0.5, hash11(seed * 13.0 + 4.0));
	float sw = mix(1.05, 0.92, fem) * (0.97 + 0.06 * hash11(seed * 61.0 + 1.0));
	float hw = mix(0.97, 1.07, fem) * (0.97 + 0.06 * hash11(seed * 67.0 + 2.0));
	float th = (0.90 + 0.22 * hash11(seed * 71.0 + 3.0)) * mix(1.0, 0.94, fem);
	float tz = 0.92 + 0.16 * hash11(seed * 73.0 + 4.0);
	float tall = 0.965 + 0.07 * hash11(seed * 79.0 + 5.0);
	float hs = hash11(seed * 31.0 + 5.0);
	bool hood = hs < 0.11;
	bool cap = hs >= 0.11 && hs < 0.22;
	bool long_hair = fem > 0.5 && hs >= 0.22 && hs < 0.60;
	bool pony = fem > 0.5 && hs >= 0.60 && hs < 0.76;
	bool bald = fem < 0.5 && hs >= 0.22 && hs < 0.30;
	bool pack = hash11(seed * 37.0 + 7.0) < ((kind < 0.5) ? 0.12 : 0.20);
	bool coat = hash11(seed * 43.0 + 11.0) < 0.28;
	bool short_sl = !coat && hash11(seed * 47.0 + 13.0) < 0.22;
	float ins_t = 0.70 + 0.14 * hash11(seed * 53.0 + 17.0);
	float ins_l = 0.62 + 0.16 * hash11(seed * 59.0 + 19.0);
	bool zomb = kind < 0.5 || kind > 3.5;
	v_var = vec4((zomb && hash11(seed * 83.0 + 21.0) > 0.45) ? 1.0 : 0.0,
			(zomb && hash11(seed * 89.0 + 23.0) > 0.40) ? 1.0 : 0.0, 0.0, seed);

	// ---- pose
	Pose o;
	float lie_amt = 0.0;
	if (kind < 0.5) {
		if (g > 4.5) {
			// zombie qui se relève : du sol à la station debout
			lie_amt = clamp(g - 5.0, 0.0, 1.0);
			o = pose_mix(zombie_pose(seed, ph, 0.0), lie_pose(seed, ph, 0.0), smoothstep(0.0, 0.7, lie_amt));
		} else if (g > 3.5) {
			o = feed_pose(seed, ph);
		} else if (g > 2.5) {
			o = pound_pose(seed, ph);
		} else {
			o = zombie_pose(seed, ph, g);
		}
	} else if (kind < 1.5) {
		o = civil_pose(seed, ph, g);
	} else {
		// corps : la chute part de la dernière attitude (course ou marche), puis les membres s'abandonnent
		lie_amt = clamp(g, 0.0, 1.0);
		float twitch = (kind < 2.5) ? lie_amt : 0.0;
		Pose st = (kind < 3.5) ? civil_pose(seed, ph, 1.0) : zombie_pose(seed, ph, 0.3);
		o = pose_mix(st, lie_pose(seed, ph, twitch), smoothstep(0.0, 0.55, lie_amt));
	}
	o.lie = lie_amt * ((seed > 0.5) ? 1.0 : -1.0);
	finalize(o);

	// ---- chaleur de la zone (par sommet, pour des dégradés lisses)
	float hv = zone_heat(region, ins_t, ins_l, short_sl, bald, coat);
	v_heat = min(hv + 0.16 * cav, 1.0);
	bool is_cloth = (region == 1 || region == 5 || region == 6 || region == 9 || (region == 2 || region == 3) && !short_sl);
	v_cloth = is_cloth ? 1.0 : 0.0;
	v_lp = VERTEX;

	vec3 p = VERTEX;
	vec3 n = NORMAL;

	// ---- morphologie : carrure, bassin, épaisseur des membres, profondeur du buste
	float sgn = (p.x >= 0.0) ? 1.0 : -1.0;
	if (bone == 1) {
		p.x *= mix(0.5 * (sw + hw), sw, smoothstep(1.04, 1.40, p.y));
		p.z *= tz;
	} else if (bone == 0) {
		p.x *= hw;
		p.z *= mix(1.0, tz, 0.5);
	} else if (bone >= 3 && bone <= 6) {
		float ax0 = sgn * 0.205;
		p.x = ax0 * sw + (p.x - ax0) * th;
		p.z *= th;
	} else if (bone >= 7) {
		float ax0 = sgn * 0.094;
		p.x = ax0 * hw + (p.x - ax0) * th;
		p.z *= mix(1.0, th, 0.7);
	}
	vec3 sh_r = vec3(SH_R.x * sw, SH_R.y, SH_R.z);
	vec3 sh_l = vec3(-SH_R.x * sw, SH_R.y, SH_R.z);
	vec3 el_r = vec3(EL_R.x * sw, EL_R.y, EL_R.z);
	vec3 el_l = vec3(-EL_R.x * sw, EL_R.y, EL_R.z);
	vec3 wr_r = vec3(WR_R.x * sw, WR_R.y, WR_R.z);
	vec3 wr_l = vec3(-WR_R.x * sw, WR_R.y, WR_R.z);
	vec3 hip_r = vec3(HIP_R.x * hw, HIP_R.y, HIP_R.z);
	vec3 hip_l = vec3(-HIP_R.x * hw, HIP_R.y, HIP_R.z);
	vec3 kn_r = vec3(KN_R.x * hw, KN_R.y, KN_R.z);
	vec3 kn_l = vec3(-KN_R.x * hw, KN_R.y, KN_R.z);
	vec3 an_r = vec3(AN_R.x * hw, AN_R.y, AN_R.z);
	vec3 an_l = vec3(-AN_R.x * hw, AN_R.y, AN_R.z);

	// ---- accessoires : non portés, ils se replient sur leur pivot ; portés, ils ont leur propre mouvement
	float run_a = smoothstep(0.35, 0.95, g) * ((kind > 0.5 && kind < 1.5) ? 1.0 : 0.0);
	float mv_a = smoothstep(0.02, 0.18, g) * ((kind < 1.5) ? 1.0 : 0.0);
	if (acc > 0) {
		bool on = false;
		vec3 pivot = vec3(0.0, 1.5, 0.0);
		if (acc == 1) {
			on = hood;
		} else if (acc == 2) {
			on = pack;
			pivot = vec3(0.0, 1.2, 0.1);
		} else if (acc == 3) {
			on = coat;
			pivot = vec3(0.0, 1.0, 0.0);
		} else if (acc == 4) {
			on = long_hair;
			pivot = CROWN;
		} else if (acc == 5) {
			on = pony;
			pivot = CROWN;
		} else if (acc == 6) {
			on = cap;
		}
		if (!on) {
			p = pivot;
			n = vec3(0.0, 1.0, 0.0);
			v_heat = 0.0;
		} else if (acc == 4 || acc == 5) {
			// cheveux : flottent vers l'arrière à la course et rebondissent à chaque foulée
			float w = clamp((1.78 - p.y) / 0.38, 0.0, 1.0);
			float a = -(0.12 + 0.55 * run_a) * w - 0.15 * w * mv_a * (0.5 + 0.5 * sin(2.0 * ph));
			rot_x(p, n, CROWN, a);
		} else if (acc == 2) {
			p.y += 0.014 * mv_a * (0.4 + run_a) * sin(2.0 * ph + 1.0);
		} else if (acc == 3) {
			// manteau : le pan se gonfle et part vers l'arrière
			float w = clamp((1.04 - p.y) / 0.48, 0.0, 1.0) * ((p.z > 0.0) ? 1.0 : 0.35);
			float a = -(0.10 + 0.45 * run_a) * w * (0.8 + 0.2 * sin(2.0 * ph));
			rot_x(p, n, WAIST, a);
			p.x *= 1.0 + 0.14 * run_a * w;
		}
	}

	// ---- parties du corps manquantes chez certains zombies
	if (kind < 0.5 || kind > 3.5) {
		float miss = hash11(seed * 41.0);
		// avant-bras arraché : tout ce qui est sous le coude se replie sur un moignon à hauteur du coude
		if (bone == 6 && miss > 0.86 && p.y < 1.10) {
			p = vec3(-EL_R.x * sw, 1.10, 0.0);
			n = vec3(0.0, -1.0, 0.0);
		} else if (bone == 4 && miss < 0.04 && p.y < 1.10) {
			p = vec3(EL_R.x * sw, 1.10, 0.0);
			n = vec3(0.0, -1.0, 0.0);
		}
	}

	// ---- articulations propres à chaque os, puis rattachement au corps
	if (region == 4 && (bone == 4 || bone == 6)) {
		// poignet : mains ballantes ou poings serrés
		if (bone == 4) {
			rot_x(p, n, wr_r, o.wr_r);
		} else {
			rot_x(p, n, wr_l, o.wr_l);
		}
	}
	if (bone == 2) {
		rot_y(p, n, NECK, o.hyaw);
		rot_x(p, n, NECK, -o.hpitch);
		rot_z(p, n, NECK, o.hroll);
	} else if (bone == 3 || bone == 4) {
		if (bone == 4) {
			rot_x(p, n, el_r, o.el_r);
		}
		rot_x(p, n, sh_r, o.sh_r);
		rot_z(p, n, sh_r, o.sp_r);
	} else if (bone == 5 || bone == 6) {
		if (bone == 6) {
			rot_x(p, n, el_l, o.el_l);
		}
		rot_x(p, n, sh_l, o.sh_l);
		rot_z(p, n, sh_l, -o.sp_l);
	} else if (bone >= 7 && bone <= 9) {
		if (bone == 9) {
			rot_x(p, n, an_r, o.an_r);
		}
		if (bone >= 8) {
			rot_x(p, n, kn_r, -o.kn_r);
		}
		rot_x(p, n, hip_r, o.hip_r);
		rot_z(p, n, hip_r, o.ls_r);
	} else if (bone >= 10) {
		if (bone == 12) {
			rot_x(p, n, an_l, o.an_l);
		}
		if (bone >= 11) {
			rot_x(p, n, kn_l, -o.kn_l);
		}
		rot_x(p, n, hip_l, o.hip_l);
		rot_z(p, n, hip_l, -o.ls_l);
	}
	if (bone >= 1 && bone <= 6) {
		// haut du corps : torsion et inclinaison d'abord, flexion à la taille ensuite
		rot_y(p, n, WAIST, o.twist);
		rot_z(p, n, WAIST, o.roll);
		rot_x(p, n, WAIST, -o.lean);
	}
	// bassin (racine de tout le corps)
	rot_y(p, n, HIPC, o.pel_yaw);
	rot_z(p, n, HIPC, o.pel_roll);
	rot_x(p, n, HIPC, -o.pel_pitch);
	p.x += o.sway;
	p.y += o.bob;

	// corps couché : bascule autour des hanches, sans enfoncer le dos dans le sol
	float a_l = 1.5708 * abs(o.lie);
	if (a_l > 0.001) {
		float sg = sign(o.lie);
		rot_x(p, n, vec3(0.0, 0.94, 0.0), -sg * a_l);
		p.y += 0.94 * (cos(a_l) - 1.0) + 0.10 * sin(a_l);
	}
	if (a_l > 0.001) {
		// corps couché : rien ne s'enfonce sous le sol (les membres s'aplatissent contre lui)
		p.y = max(p.y, 0.03);
	}
	p *= tall;

	// taille minimale à l'écran : on grossit autour des pieds
	vec3 org = MODEL_MATRIX[3].xyz;
	float depth = max(-(VIEW_MATRIX * vec4(org, 1.0)).z, 1.0);
	float ppm = VIEWPORT_SIZE.y * 0.5 * abs(PROJECTION_MATRIX[1][1]) / depth;
	float hm = 1.8 * length(MODEL_MATRIX[1].xyz);
	float boost = clamp(min_px / max(hm * ppm, 0.001), 1.0, max_boost);
	p *= boost;

	n = normalize(n);
	vec3 nw = (MODEL_MATRIX * vec4(n, 0.0)).xyz;
	v_up = nw.y / max(length(nw), 0.001);
	VERTEX = p;
	NORMAL = n;
}

void fragment() {
	float kind = floor(v_cust.y + 0.001);
	float body = pow(max(v_cust.x, 0.0), 0.6);
	float h = body * v_heat;
	// plis du tissu : motif doux, sur les vêtements seulement
	float tx = vnoise(v_lp.xy * 9.0 + vec2(v_lp.z * 5.0, v_var.w * 40.0));
	h *= 1.0 + v_cloth * (tx - 0.5) * 0.16;
	// zombies : déchirures laissant voir la peau (surtout vers les bords du vêtement), sang séché plus froid
	if (v_var.x > 0.5) {
		float tn = vnoise(v_lp.xy * vec2(17.0, 12.0) + vec2(v_var.w * 31.0, v_lp.z * 9.0));
		float hem = smoothstep(1.30, 0.80, v_lp.y + 0.25 * sin(v_var.w * 50.0));
		float tear = smoothstep(0.74, 0.80, tn) * (0.35 + 0.65 * hem);
		h = mix(h, body * 0.98, tear * v_cloth);
	}
	if (v_var.y > 0.5) {
		float blood = smoothstep(0.66, 0.78, vnoise(v_lp.xy * vec2(8.0, 2.6) + vec2(9.0, v_var.w * 17.0)));
		h *= 1.0 - 0.26 * blood;
	}
	// émissivité : les bords, vus de biais, paraissent plus froids ; les faces tournées vers le ciel reflètent le froid
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	h *= mix(0.70, 1.0, pow(facing, 0.5));
	h *= 1.0 - 0.15 * max(v_up, 0.0) + 0.05 * max(-v_up, 0.0);
	h *= exp(-length(VERTEX) * atmos_k);
	if (debug_gray) {
		ALBEDO = vec3(h);
	} else {
		float zm = (kind < 0.5) ? 1.0 : 0.0;
		float cm = (kind > 0.5 && kind < 2.5) ? 1.0 : 0.0;
		ALBEDO = vec3(h, h * (1.0 - zm), h * (1.0 - cm));
	}
}
