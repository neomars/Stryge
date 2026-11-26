shader_type spatial;
// Bâtiments en chaleur : toit, façades avec fenêtres éclairées selon les occupants,
// effondrement et feu pilotés par INSTANCE_CUSTOM = (occupation, infestation, effondrement, feu).
// Immeuble à raser : occupation + 2,0. Il n'écrit alors que le canal rouge (verts et bleu absents, signature qu'aucun personnage
// n'a) ; thermal_post.gdshader la reconnaît et colore l'immeuble en rouge, que le marquage couleur soit actif ou non.
// Une ruine n'est pas un bloc uniforme : l'immeuble s'affaisse en penchant, puis il reste des gravats
// irréguliers aux bords déchiquetés, avec des braises qui s'éteignent peu à peu.
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform float roof_base : hint_range(0.0, 1.0) = 0.21;
uniform float wall_base : hint_range(0.0, 1.0) = 0.27;
uniform float window_lit : hint_range(0.0, 1.0) = 0.92;
uniform float window_zombie : hint_range(0.0, 1.0) = 0.50;
uniform float window_cold : hint_range(0.0, 1.0) = 0.13;
uniform float atmos_k = 0.00005;

varying vec3 v_fac;
varying vec3 v_nloc;
varying flat vec4 v_state;
varying flat float v_id;
varying flat vec3 v_sz;

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

float rubble_noise(vec2 p) {
	return 0.50 * vnoise(p) + 0.30 * vnoise(p * 2.3 + 11.0) + 0.20 * vnoise(p * 5.7 + 3.0);
}

void vertex() {
	vec3 sz = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	float id = float(INSTANCE_ID);
	float col = smoothstep(0.0, 1.0, INSTANCE_CUSTOM.z);
	// affaissement : le haut de l'immeuble part de côté pendant qu'il se tasse
	float slump = sin(col * PI) * VERTEX.y;
	VERTEX.x += slump * (hash21(vec2(id, 3.7)) - 0.5) * 0.5;
	VERTEX.z += slump * (hash21(vec2(id, 9.1)) - 0.5) * 0.5;
	VERTEX.y *= mix(1.0, 0.07, col);
	v_fac = VERTEX * sz;
	v_nloc = NORMAL;
	v_state = INSTANCE_CUSTOM;
	v_id = id;
	v_sz = sz;
}

void fragment() {
	// la face du dessous (au niveau du sol) ne sert jamais : on évite qu'elle scintille à travers une ruine
	if (v_nloc.y < -0.5) {
		discard;
	}
	float alert = step(1.5, v_state.x);
	float occ = v_state.x - 2.0 * alert;
	float inf = v_state.y;
	float col = smoothstep(0.0, 1.0, v_state.z);
	float fire = clamp(v_state.w, 0.0, 1.0);
	float ruin = smoothstep(0.55, 1.0, v_state.z);

	// bruit de gravats, lié à l'immeuble pour que chaque ruine ait sa forme
	vec2 q = v_fac.xz * 0.40 + vec2(v_id * 3.17, v_id * 1.73);
	float n = rubble_noise(q);

	// bords déchiquetés une fois l'immeuble à terre
	if (ruin > 0.5) {
		float e = min(0.5 * v_sz.x - abs(v_fac.x), 0.5 * v_sz.z - abs(v_fac.z));
		float rag = (rubble_noise(v_fac.xz * 0.9 + vec2(v_id * 5.3, 2.0)) - 0.40) * 12.0;
		if (e < rag) {
			discard;
		}
	}

	float heat;
	if (v_nloc.y > 0.5) {
		// toit : légèrement plus chaud quand l'immeuble est habité (déperditions)
		heat = roof_base + 0.17 * occ + 0.12 * inf;
		heat += (hash21(floor(v_fac.xz * 0.6) + v_id) - 0.5) * 0.04;
	} else {
		float u = (abs(v_nloc.x) > 0.5) ? v_fac.z : v_fac.x;
		vec2 cell_uv = vec2(u / 3.2, v_fac.y / 3.1);
		vec2 cell = floor(cell_uv);
		vec2 f = fract(cell_uv);
		float is_window = step(0.18, f.x) * step(f.x, 0.82) * step(0.22, f.y) * step(f.y, 0.78);
		heat = wall_base + (hash21(cell + v_id * 0.37) - 0.5) * 0.03;
		if (v_fac.y > 3.2) {
			float h = hash21(cell * 1.7 + vec2(v_id * 0.173, 7.0));
			float wh;
			if (h < occ) {
				wh = window_lit;
			} else if (h < occ + inf) {
				wh = window_zombie;
			} else {
				wh = window_cold;
			}
			// empreinte d'un pixel en cellules de façade : au-delà d'une cellule, on moyenne
			vec2 fwc = fwidth(cell_uv);
			float px = max(fwc.x, fwc.y);
			float fade = smoothstep(0.30, 0.90, px);
			float wmean = mix(wall_base, wh, 0.36);
			float wval = mix(wh, wmean, fade);
			heat = mix(heat, wval, mix(is_window, 1.0, fade));
		}
	}

	// immeuble encore debout et touché : plaques chaudes irrégulières plutôt qu'un voile uniforme
	float patch = smoothstep(0.30, 0.62, n);
	heat = mix(heat, 1.0, clamp(fire * 1.8, 0.0, 1.0) * patch * (1.0 - col));

	// gravats : pierres froides parsemées de braises, d'autant plus nombreuses que le feu est vif
	float base = mix(0.27, 0.52, smoothstep(0.10, 0.80, fire));
	float peak = mix(0.58, 1.0, smoothstep(0.10, 0.90, fire));
	float thr = 1.05 - 0.95 * fire;
	float flick = 0.88 + 0.12 * sin(TIME * (3.0 + 5.0 * hash21(floor(q * 3.0))) + n * 30.0);
	float ember = smoothstep(thr, thr + 0.30, n) * flick;
	float rubble = mix(base + (n - 0.5) * 0.16, peak, ember);
	heat = mix(heat, rubble, col);

	heat *= exp(-length(VERTEX) * atmos_k);
	if (alert > 0.5) {
		// la chaleur de l'immeuble à raser bat comme un voyant : plus vive, jamais éteinte
		float pulse = 0.5 + 0.5 * sin(TIME * 6.0);
		heat = clamp(heat * 1.2 + 0.14 + 0.16 * pulse, 0.0, 1.0);
		ALBEDO = vec3(heat, 0.0, 0.0);
	} else {
		ALBEDO = vec3(heat);
	}
}
