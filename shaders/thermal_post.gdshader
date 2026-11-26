shader_type canvas_item;
// Post-traitement de la caméra thermique : halo autour des points chauds, bruit capteur,
// balayage, vignette et polarité blanc chaud / noir chaud.
// Marquage couleur (touche C) : les personnages sont dessinés avec un canal éteint
// (zombie : vert absent, civil : bleu absent) ; on le lit ici pour teinter la silhouette et son halo.
// Immeuble à raser : vert ET bleu absents (aucun personnage n'a cette signature) ; il est teinté en rouge dans tous les cas,
// y compris quand le marquage couleur est coupé.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform bool white_hot = true;
uniform float gain : hint_range(0.5, 3.0) = 1.35;
uniform float lift : hint_range(-0.5, 0.5) = -0.05;
uniform float gamma : hint_range(0.5, 2.0) = 1.0;
uniform float bloom_strength : hint_range(0.0, 3.0) = 1.1;
uniform float bloom_threshold : hint_range(0.0, 1.0) = 0.32;
uniform float bloom_radius_px : hint_range(1.0, 40.0) = 6.0;
uniform float noise_amount : hint_range(0.0, 0.3) = 0.045;
uniform float scan_amount : hint_range(0.0, 0.3) = 0.035;
uniform float vignette_amount : hint_range(0.0, 1.0) = 0.5;
uniform vec3 tint = vec3(0.90, 0.97, 1.0);
uniform float flash = 0.0;
uniform float mark_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec3 zombie_tint = vec3(1.0, 0.42, 0.24);
uniform vec3 civil_tint = vec3(0.45, 1.0, 0.70);
uniform vec3 alert_tint = vec3(1.0, 0.10, 0.06);

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = SCREEN_PIXEL_SIZE;
	vec3 c0 = texture(screen_tex, uv).rgb;
	float base = c0.r;
	float bl = 0.0;
	vec2 bm = vec2(0.0);
	float ba = 0.0;
	for (int i = 0; i < 12; i++) {
		float a = float(i) * 0.5235988;
		vec2 d = vec2(cos(a), sin(a));
		vec3 s1 = texture(screen_tex, uv + d * px * bloom_radius_px).rgb;
		vec3 s2 = texture(screen_tex, uv + d * px * bloom_radius_px * 2.6).rgb;
		bl += s1.r + s2.r;
		vec2 d1 = vec2(max(s1.r - s1.g, 0.0), max(s1.r - s1.b, 0.0));
		vec2 d2 = vec2(max(s2.r - s2.g, 0.0), max(s2.r - s2.b, 0.0));
		float a1 = min(d1.x, d1.y);                       // part « les deux canaux absents » : immeuble à raser
		float a2 = min(d2.x, d2.y);
		ba += a1 + a2;
		bm += (d1 - vec2(a1)) + (d2 - vec2(a2));
	}
	bl /= 24.0;
	bm /= 24.0;
	ba /= 24.0;
	float h = base + bloom_strength * max(bl - bloom_threshold, 0.0);
	h = pow(max((h + lift) * gain, 0.0), gamma);
	float t = floor(TIME * 30.0);
	float n = hash12(floor(FRAGCOORD.xy * 0.5) + vec2(t * 17.0, t * 5.0));
	h += (n - 0.5) * noise_amount;
	float col_noise = hash12(vec2(floor(FRAGCOORD.x * 0.5), 3.0));
	h += (col_noise - 0.5) * noise_amount * 0.35;
	h *= 1.0 - scan_amount * (0.5 + 0.5 * sin(FRAGCOORD.y * 3.14159));
	float v = length((uv - 0.5) * vec2(1.0, 0.85));
	h *= mix(1.0, 1.0 - smoothstep(0.30, 0.85, v), vignette_amount);
	h = clamp(h, 0.0, 1.0);

	// intensité du marquage : sur la silhouette (exacte) et dans son halo (diffus)
	vec2 mk0 = clamp(vec2(c0.r - c0.g, c0.r - c0.b) / max(c0.r, 0.04), 0.0, 1.0) * smoothstep(0.05, 0.18, c0.r);
	float al_c = min(mk0.x, mk0.y);                       // immeuble à raser sur ce pixel (exact)
	vec2 mk = mk0 - vec2(al_c);                           // ce qui reste est le marquage des personnages
	float al = clamp(max(al_c, ba * 3.5), 0.0, 1.0);      // ... et son halo
	vec2 m = clamp(max(mk, bm * 3.5), 0.0, 1.0) * mark_strength;
	vec3 tc = mix(mix(tint, zombie_tint, m.x), civil_tint, m.y);
	tc = mix(tc, alert_tint, al);
	float mm = max(max(m.x, m.y), al);
	vec3 col;
	if (white_hot) {
		// les silhouettes marquées sont relevées sans écraser leur relief interne (visage, mains, vêtements)
		h = mix(h, 0.40 + 0.60 * h, clamp(mk.x + mk.y, 0.0, 1.0) * mark_strength);
		h = mix(h, 0.50 + 0.50 * h, al_c);                // l'immeuble rouge reste franc même quand il est froid
		col = tc * h;
	} else {
		float hi = 1.0 - h;
		col = mix(tint * hi, tc * (0.20 + 0.50 * hi), mm);
		col = mix(col, alert_tint * (0.40 + 0.60 * hi), al);
	}
	COLOR = vec4(col + vec3(flash), 1.0);
}
