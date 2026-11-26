extends Control
## Surcouche : réticule, mesures, compteurs, journal radio, carte tactique, écrans de briefing et de fin.
## Dessinée au-dessus du post-traitement thermique, donc nette.

const MAP_PX := 210
const C_MAIN := Color(0.93, 0.98, 1.0, 0.95)
const C_DIM := Color(0.93, 0.98, 1.0, 0.6)
const C_WARN := Color(1.0, 0.5, 0.4, 1.0)
const C_GOOD := Color(0.65, 1.0, 0.75, 1.0)
const C_SIEGE := Color(1.0, 0.82, 0.4, 1.0)
const C_BG := Color(0.0, 0.0, 0.0, 0.62)
## Ordre d'urgence des conseils d'immeuble (BuildingSystem.advice) ; les autres conseils n'ont pas d'étiquette dans le monde.
const ADV_RANK := {"raze": 0, "defend": 1, "siege": 2, "open": 3}
## Durée d'affichage d'une perte (bandeau et repère au sol) et texte de chaque cause : [ce qui s'est passé, ce qu'il faut en retenir].
## Rouge réservé à ce qui est à détruire (l'immeuble perdu à raser) : aucune autre information n'est dessinée de cette couleur.
const C_RAZE := Color(1.0, 0.1, 0.07, 1.0)
const C_RAZE_NOIR := Color(0.78, 0.0, 0.0, 1.0)
## Taille du texte (touche T, mémorisée dans le profil) : coefficient appliqué à toutes les polices et aux interlignes.
const TEXT_SCALES := [1.0, 1.3, 1.6]
const TEXT_NAMES := ["NORMAL", "GRAND", "TRÈS GRAND"]
const TEXT_DEFAULT := 1
## Nom court de chaque priorité (flèche en bord d'écran, carte).
const PRIO_SHORT := {"raze": "RASER", "door": "PORTE", "defend": "IMMEUBLE", "street": "RUE", "special": "SPÉCIAL", "objective": "OBJECTIF"}
const LOSS_SHOW_S := 7.0
const LOSS_TXT := {
	"inside": ["dévorés dans un immeuble", "Les infectés sont à l'intérieur : ne rasez que si l'immeuble est perdu."],
	"street": ["dévorés dans la rue", "Abattez les infectés près des civils qui fuient."],
	"shot": ["tués par vos tirs", "Comptez les civils dans la zone avant de tirer."],
	"razed": ["morts sous les décombres", "Cet immeuble tenait encore : raser tue tous ses habitants (−{c} points chacun)."],
	"razed_ok": ["morts sous un immeuble perdu", "Il était perdu : contagion arrêtée, −{e} points par civil, sans bavure."],
}

var ink_main: Color = C_MAIN
var ink_dim: Color = C_DIM
var ink_warn: Color = C_WARN
var ink_good: Color = C_GOOD
var ink_siege: Color = C_SIEGE
var ink_raze: Color = C_RAZE
var ink_outline := Color(0, 0, 0, 0.85)
var _noir := false
var ts := 1.3                   # coefficient de taille du texte en vigueur (TEXT_SCALES[text_level])
var text_level := 1
var _notice := ""               # message bref au centre (changement de taille du texte)
var _notice_ms := -99999
var _cy := 0.0                  # ordonnée libre sous le bandeau URGENT, pour les pertes et les annonces
var _verdict_slot := Rect2()       # place du conseil « RASER : OUI / NON » sous le viseur (image précédente) : étiquettes et flèches l'évitent, même quand il n'est pas affiché
var _top_limit := 0.0           # ordonnée que les panneaux du haut ne dépassent pas : au-dessus des textes du réticule (calibre, munitions)
var _top_on := {}               # panneaux du haut qui descendent `_cy`, dessinés à l'image précédente (« loss », « drone »)
var _top_h := {}                # leur hauteur la dernière fois qu'ils ont été dessinés
var _reserved: Array = []       # rectangles de texte du HUD que les flèches de bord d'écran évitent
const TOP_TS_MAX := 1.3          # échelle maximale des panneaux du haut (bandeau URGENT, pertes, annonces) : ils restent au-dessus du réticule
var debug_rects := false        # essais : garde le rectangle de chaque texte pour signaler les chevauchements (report_overlaps)
var _rec := false               # les textes dessinés ensuite sont ceux du HUD fixe (pas les étiquettes posées sur la scène)
var _text_new: Array = []       # rectangles des textes du HUD de cette image
var _text_rects: Array = []     # ... de l'image précédente : les étiquettes d'immeuble les évitent
var _dbg: Array = []            # essais : [rectangle, texte] de cette image
var _dbg_prev: Array = []
var _status_bottom := 0.0       # bas du bloc de statut (haut gauche) : les objectifs viennent dessous
var _obj_bottom := 0.0          # bas du panneau des objectifs (0 : aucun) : le journal radio reste au-dessous
var _rw := 1.0                  # épaisseur relative des traits du réticule (réticule cosmétique)

var ctx
var game
var font: Font
var map_tex: ImageTexture = null
var map_k := 1.0
var _map_o := Vector2.ZERO
var _map_half := Vector2.ZERO


func setup(p_ctx, p_game) -> void:
	ctx = p_ctx
	game = p_game
	font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_map()


# ---------------------------------------------------------------- carte statique

const MAP_SS := 2                       # la texture de la carte est calculée à MAP_SS fois la taille affichée (lissage)
const MAP_BG := Color(0.04, 0.06, 0.07, 0.8)
const MAP_PARK := Color(0.1, 0.22, 0.12, 1.0)
const MAP_WATER := Color(0.08, 0.14, 0.30, 1.0)


## Demi-côté (m) de la zone que montre la minicarte : la zone de jeu et 40 m de marge (toute la carte s'il n'y a pas de zone).
func _map_view_half() -> float:
	var sz: Vector2 = ctx.city.size_m()
	return (ctx.zone_radius() + 40.0) if ctx.has_zone() else maxf(sz.x, sz.y) * 0.5


func _build_map() -> void:
	var city = ctx.city
	var vh := _map_view_half()
	var vc: Vector2 = ctx.zone_center()
	map_k = float(MAP_PX) / (2.0 * vh)
	var px := MAP_PX * MAP_SS
	var k2 := float(px) / (2.0 * vh)                   # pixels de texture par mètre
	var half := Vector2(vh - vc.x, vh - vc.y)          # (x + half.x) * k2 : pixel de la texture ; la minicarte est centrée sur la zone
	_map_half = half
	var img := Image.create_empty(px, px, false, Image.FORMAT_RGBA8)
	img.fill(MAP_BG)
	var buf: PackedByteArray = img.get_data()
	# eau et parcs : maillages triangulés des cartes réelles, puis zones rectangulaires des villes générées
	_map_tris(buf, px, city.water_v, city.water_i, half, k2, MAP_WATER)
	_map_tris(buf, px, city.park_v, city.park_i, half, k2, MAP_PARK)
	for a in city.areas:
		var kind: String = a[0]
		if kind == "park" or kind == "water":
			_map_rect(buf, px, (float(a[1]) + half.x) * k2, (float(a[2]) + half.y) * k2,
					(float(a[3]) + half.x) * k2, (float(a[4]) + half.y) * k2, MAP_WATER if kind == "water" else MAP_PARK)
	# immeubles, plus clairs quand ils sont hauts
	for b in city.building_count():
		_map_building(buf, px, city, b, half, k2)
	# rues par-dessus les immeubles (les emprises réelles débordent parfois sur la voirie)
	for e in city.edge_a.size():
		var pa: Vector2 = city.nodes[city.edge_a[e]]
		var pb: Vector2 = city.nodes[city.edge_b[e]]
		var wpx := clampf(city.edge_w[e] * k2 * 0.7, 1.0, 3.0)
		var col2 := Color(0.34, 0.36, 0.38, 1.0) if city.edge_class[e] == 1 else Color(0.22, 0.24, 0.26, 1.0)
		if city.edge_class[e] == 2:
			col2 = Color(0.17, 0.19, 0.2, 1.0)
		var steps := int(pa.distance_to(pb) * k2 * 2.0) + 1
		for st in steps + 1:
			var q := pa.lerp(pb, float(st) / float(steps))
			var cx := (q.x + half.x) * k2 - wpx * 0.5
			var cy := (q.y + half.y) * k2 - wpx * 0.5
			_map_rect(buf, px, cx, cy, cx + wpx, cy + wpx, col2)
	# points d'évacuation et bouches de métro
	for a in city.areas:
		var kind2: String = a[0]
		if kind2 == "evac" or kind2 == "metro":
			_map_rect(buf, px, (float(a[1]) + half.x) * k2, (float(a[2]) + half.y) * k2,
					(float(a[3]) + half.x) * k2, (float(a[4]) + half.y) * k2,
					Color(0.3, 0.9, 0.5, 1.0) if kind2 == "evac" else Color(0.35, 0.85, 1.0, 1.0))
	map_tex = ImageTexture.create_from_image(Image.create_from_data(px, px, false, Image.FORMAT_RGBA8, buf))


func _map_put(buf: PackedByteArray, px: int, x: int, y: int, c: Color) -> void:
	var i := (y * px + x) * 4
	buf[i] = int(c.r * 255.0)
	buf[i + 1] = int(c.g * 255.0)
	buf[i + 2] = int(c.b * 255.0)
	buf[i + 3] = int(c.a * 255.0)


## Rectangle plein en pixels de texture (coordonnées flottantes, bornes comprises).
func _map_rect(buf: PackedByteArray, px: int, x0: float, y0: float, x1: float, y1: float, c: Color) -> void:
	for y in range(maxi(int(floor(y0)), 0), mini(int(floor(y1)) + 1, px)):
		for x in range(maxi(int(floor(x0)), 0), mini(int(floor(x1)) + 1, px)):
			_map_put(buf, px, x, y, c)


## Immeuble : rectangle orienté, rempli au centre des pixels qu'il recouvre (les tout petits tiennent en un pixel).
func _map_building(buf: PackedByteArray, px: int, city, b: int, half: Vector2, k2: float) -> void:
	var cx: float = (city.b_cx[b] + half.x) * k2
	var cy: float = (city.b_cz[b] + half.y) * k2
	var w: float = city.b_w[b] * k2
	var d: float = city.b_d[b] * k2
	var hgt: float = city.b_h[b]
	var g := clampf(0.30 + hgt * 0.006, 0.30, 0.52)
	var col := Color(g, g + 0.02, g + 0.05, 1.0)
	if maxf(w, d) < 2.4:
		var ix := int(cx)
		var iy := int(cy)
		if ix >= 0 and iy >= 0 and ix < px and iy < px:
			_map_put(buf, px, ix, iy, col)
		return
	var yaw: float = city.b_yaw[b]
	var c := cos(yaw)
	var sn := sin(yaw)
	var ex := absf(c) * w * 0.5 + absf(sn) * d * 0.5
	var ey := absf(sn) * w * 0.5 + absf(c) * d * 0.5
	var hx := w * 0.5 + 0.35
	var hz := d * 0.5 + 0.35
	for y in range(maxi(int(floor(cy - ey)), 0), mini(int(ceil(cy + ey)), px)):
		for x in range(maxi(int(floor(cx - ex)), 0), mini(int(ceil(cx + ex)), px)):
			var dx := float(x) + 0.5 - cx
			var dz := float(y) + 0.5 - cy
			var lx := dx * c - dz * sn
			var lz := dx * sn + dz * c
			if absf(lx) <= hx and absf(lz) <= hz:
				_map_put(buf, px, x, y, col)


## Triangles remplis ligne par ligne (centre de pixel) ; sommets en mètres locaux.
func _map_tris(buf: PackedByteArray, px: int, v: PackedVector2Array, ix: PackedInt32Array, half: Vector2, k2: float, c: Color) -> void:
	for t in range(0, ix.size() - 2, 3):
		var a: Vector2 = (v[ix[t]] + half) * k2
		var b: Vector2 = (v[ix[t + 1]] + half) * k2
		var d: Vector2 = (v[ix[t + 2]] + half) * k2
		var y0 := maxi(int(ceil(minf(a.y, minf(b.y, d.y)) - 0.5)), 0)
		var y1 := mini(int(floor(maxf(a.y, maxf(b.y, d.y)) - 0.5)), px - 1)
		for y in range(y0, y1 + 1):
			var yc := float(y) + 0.5
			var xmin := INF
			var xmax := -INF
			if (a.y <= yc and b.y > yc) or (b.y <= yc and a.y > yc):
				var x1 := a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x)
				xmin = minf(xmin, x1)
				xmax = maxf(xmax, x1)
			if (b.y <= yc and d.y > yc) or (d.y <= yc and b.y > yc):
				var x2 := b.x + (yc - b.y) / (d.y - b.y) * (d.x - b.x)
				xmin = minf(xmin, x2)
				xmax = maxf(xmax, x2)
			if (d.y <= yc and a.y > yc) or (a.y <= yc and d.y > yc):
				var x3 := d.x + (yc - d.y) / (a.y - d.y) * (a.x - d.x)
				xmin = minf(xmin, x3)
				xmax = maxf(xmax, x3)
			if xmax < xmin:
				continue
			for x in range(maxi(int(ceil(xmin - 0.5)), 0), mini(int(floor(xmax - 0.5)), px - 1) + 1):
				_map_put(buf, px, x, y, c)


# ---------------------------------------------------------------- aides de dessin

## Palette du HUD : en « noir chaud » l'image est claire, donc encre sombre cerclée de blanc.
func _set_ink(white_hot: bool) -> void:
	_noir = not white_hot
	if white_hot:
		ink_main = C_MAIN
		ink_dim = C_DIM
		ink_warn = C_WARN
		ink_good = C_GOOD
		ink_siege = C_SIEGE
		ink_raze = C_RAZE
		ink_outline = Color(0, 0, 0, 0.85)
	else:
		ink_main = Color(0.02, 0.04, 0.06, 0.97)
		ink_dim = Color(0.02, 0.04, 0.06, 0.72)
		ink_warn = Color(0.86, 0.30, 0.0, 1.0)                 # orange : le rouge pur (C_RAZE_NOIR) est réservé à l'immeuble à raser
		ink_good = Color(0.05, 0.42, 0.14, 1.0)
		ink_siege = Color(0.62, 0.38, 0.0, 1.0)
		ink_raze = C_RAZE_NOIR
		ink_outline = Color(1, 1, 1, 0.85)


## Taille de police réelle d'une taille de base : toutes les tailles écrites dans ce fichier sont des tailles « normales » (touche T).
func _fs(fs: float) -> int:
	return maxi(int(round(fs * ts)), 9)


## Longueur ou interligne de base mis à l'échelle du texte.
func _s(v: float) -> float:
	return v * ts


## Largeur d'une chaîne à la taille de base fs.
func _w(s: String, fs: float) -> float:
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, _fs(fs)).x


## Plus grande taille de base (entre fs_min et fs) pour laquelle la chaîne tient dans maxw pixels.
func _fit(s: String, fs: float, maxw: float, fs_min: float = 12.0) -> float:
	var f := fs
	while f > fs_min and _w(s, f) > maxw:
		f -= 1.0
	return f


## Largeur de la colonne de droite (compteurs).
func _rcw() -> float:
	return 250.0 * pow(ts, 0.6)


## Change la taille du texte (0 normal, 1 grand, 2 très grand) ; announce : message au centre et enregistrement dans le profil.
func set_text_size(level: int, announce: bool = true) -> void:
	text_level = clampi(level, 0, TEXT_SCALES.size() - 1)
	ts = float(TEXT_SCALES[text_level])
	if ctx != null and ctx.profile != null:
		ctx.profile.settings["text"] = text_level
		if announce:
			ctx.profile.save()
	if announce:
		_notice = "TEXTE : %s" % str(TEXT_NAMES[text_level])
		_notice_ms = Time.get_ticks_msec()


func cycle_text_size() -> void:
	set_text_size((text_level + 1) % TEXT_SCALES.size())


## Texte du bloc de droite du viseur : jamais sous la minicarte (réduit pour tenir dans la largeur libre).
func _rtxt(pos: Vector2, s: String, fs: float = 16.0, col: Color = Color(-1.0, 0.0, 0.0, 1.0)) -> void:
	var lim := size.x - 20.0
	if game.show_map and pos.y > size.y - MAP_PX - _s(40.0):
		lim = size.x - MAP_PX - 30.0
	_txt(pos, s, _fit(s, fs, lim - pos.x, 9.0), col)


## Essais : textes du HUD qui se recouvrent dans la dernière image dessinée (« A | B (n px²) »). Nécessite debug_rects.
func report_overlaps() -> Array:
	var out: Array = []
	for i in _dbg_prev.size():
		for j in range(i + 1, _dbg_prev.size()):
			var a: Rect2 = _dbg_prev[i][0]
			var b: Rect2 = _dbg_prev[j][0]
			var x: Rect2 = a.intersection(b)
			if x.size.x > 3.0 and x.size.y > 3.0 and x.get_area() > 40.0:
				out.append("%s | %s (%d px²)" % [str(_dbg_prev[i][1]), str(_dbg_prev[j][1]), int(x.get_area())])
	return out


## Vrai si le rectangle touche un texte du HUD de l'image précédente : l'étiquette d'immeuble est alors omise (le cadre reste).
func _label_blocked(r: Rect2) -> bool:
	var q := r.grow(3.0)
	for o in _text_rects:
		if q.intersects(o):
			return true
	for o in _ptr_rects:
		if q.intersects(o):
			return true
	return false


func _txt(pos: Vector2, s: String, fs: float = 16.0, col: Color = Color(-1.0, 0.0, 0.0, 1.0),
		align: int = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0) -> void:
	if col.r < 0.0:
		col = ink_main
	var f := _fs(fs)
	if _rec or debug_rects:
		var tw := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, f).x
		var x0 := pos.x
		if width > 0.0 and align == HORIZONTAL_ALIGNMENT_CENTER:
			x0 = pos.x + (width - tw) * 0.5
		elif width > 0.0 and align == HORIZONTAL_ALIGNMENT_RIGHT:
			x0 = pos.x + width - tw
		var tr := Rect2(x0, pos.y - 0.76 * float(f), tw, 0.98 * float(f))
		if _rec:
			_text_new.append(tr)
		if debug_rects:
			_dbg.append([tr, s])
	draw_string_outline(font, pos, s, align, width, f, clampi(int(round(float(f) / 6.0)) + 1, 3, 6), ink_outline)
	draw_string(font, pos, s, align, width, f, col)


func _mp(x: float, z: float) -> Vector2:
	return _map_o + Vector2((x + _map_half.x) * map_k, (z + _map_half.y) * map_k)


func _in_map(p: Vector2) -> bool:
	return p.x >= _map_o.x and p.y >= _map_o.y and p.x <= _map_o.x + MAP_PX and p.y <= _map_o.y + MAP_PX


# ---------------------------------------------------------------- dessin

func _draw() -> void:
	if ctx == null or game == null:
		return
	var sz := size
	if game.state == "briefing":
		return                                  # le briefing est un écran de contrôles (Screens)
	_set_ink(game.white_hot)
	_ptr_rects.clear()
	_text_rects = _text_new
	_text_new = []
	_dbg_prev = _dbg
	_dbg = []
	_rec = false
	_top_limit = sz.y * 0.5 - 64.0 * ts
	_reserve_new_panels()
	_compute_reserved(sz)
	if game.state != "ended":
		_draw_locks(sz)                       # carrés rouges sur les infectés cachés derrière un immeuble (sous tous les repères)
		_draw_markers(sz)
		_draw_support_marks(sz)
		_draw_specials(sz)
		if bool(ctx.difficulty().get("impact", true)):
			_draw_impacts(sz)             # en Cauchemar, plus d'indicateur de chute : on anticipe soi-même
		_draw_sensors(sz)
		_rec = true
		_draw_reticle(sz)
	_rec = true
	_draw_status(sz)
	_draw_counters(sz)
	_obj_bottom = 0.0
	if game.state != "ended":
		_draw_objectives(sz)
	_draw_weapons(sz)
	if game.state != "ended":
		_draw_supports(sz)
	_draw_map(sz)
	_draw_radio(sz)
	if game.state != "ended":
		_draw_priority(sz)                    # bandeau URGENT, puis dessous : drone, pertes, annonces
		_draw_drone_status(sz)
		_draw_losses(sz)
		_draw_toasts(sz)
	_draw_notice(sz)
	_rec = false
	_set_ink(true)
	if game.show_help:
		_draw_help(sz)
	if game.state == "paused":
		_draw_pause(sz)


# ---------------------------------------------------------------- réticule

const NICE_STEPS: Array = [0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0]


## Nombre à la française : virgule décimale.
func _fr(x: float, d: int = 1) -> String:
	return (("%." + str(d) + "f") % x).replace(".", ",")


## Trait cerclé : lisible sur fond clair comme sur fond sombre.
func _ln(a: Vector2, b: Vector2, col: Color, wd: float = 1.5) -> void:
	wd *= _rw
	draw_line(a, b, Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.5), wd + 2.4)
	draw_line(a, b, col, wd)


func _ring(c: Vector2, r: float, a0: float, a1: float, col: Color, wd: float = 1.5) -> void:
	wd *= _rw
	var pts := maxi(int(absf(a1 - a0) / TAU * 90.0), 3)
	draw_arc(c, r, a0, a1, pts, Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.5), wd + 2.4, true)
	draw_arc(c, r, a0, a1, pts, col, wd, true)


func _dotted_ring(c: Vector2, r: float, col: Color) -> void:
	var n := clampi(int(r * 0.9), 16, 72)
	for i in n:
		if i % 2 == 0:
			var a0 := TAU * float(i) / float(n)
			draw_arc(c, r, a0, a0 + TAU / float(n) * 0.9, 3, col, 1.4, true)


## Pas de graduation « rond » (1, 2, 5, 10... m) dont l'écart à l'écran dépasse min_px.
func _nice_step(mpp: float, min_px: float) -> float:
	for s in NICE_STEPS:
		if float(s) / mpp >= min_px:
			return float(s)
	return float(NICE_STEPS[NICE_STEPS.size() - 1])


## Branche graduée : un trait par pas de terrain, étiquettes en mètres depuis le point visé.
## label : 0 aucune, 1 sous la branche (horizontale), 2 à droite (verticale).
func _arm(c: Vector2, dir: Vector2, start: float, length: float, mpp: float, label: int) -> void:
	if length < 14.0:
		return
	var step := _nice_step(mpp, 26.0)
	var px := step / mpp
	var perp := Vector2(-dir.y, dir.x)
	_ln(c + dir * start, c + dir * (start + length), ink_main, 1.5)
	var every := 1 if px >= 46.0 else 2
	var k := maxi(int(ceil((start + 5.0) / px)), 1)
	while float(k) * px <= start + length:
		var d := float(k) * px
		var big := (k % every) == 0
		var tl := 9.0 if big else 5.0
		_ln(c + dir * d - perp * tl, c + dir * d + perp * tl, ink_main, 1.3)
		if label > 0 and big:
			var m := float(k) * step
			var txt := _fr(m, 0) if m >= 1.0 else _fr(m, 1)
			if label == 1:
				_txt(c + dir * d + perp * (tl + _s(13.0)) - Vector2(_s(24.0), 0.0), txt, 11, ink_dim, HORIZONTAL_ALIGNMENT_CENTER, _s(48.0))
			else:
				_txt(c + dir * d + perp * (tl + _s(4.0)) + Vector2(0.0, _s(4.0)), txt, 11, ink_dim)
		k += 1
	# capuchon d'extrémité, avec l'unité sur les branches étiquetées
	var e := c + dir * (start + length)
	_ln(e - perp * 4.0, e + perp * 4.0, ink_main, 1.5)
	if label == 1:
		_txt(e + Vector2(_s(8.0), _s(4.0)), "M", 11, ink_dim)
	elif label == 2:
		_txt(e + Vector2(-_s(4.0), -_s(8.0)), "M", 11, ink_dim)


## Cadre propre à chaque arme : cercle nu (mitrailleuse), équerres (canon de 40), carré évidé (obusier).
func _reticle_frame(c: Vector2, r: float, style: String) -> void:
	if str(game.reticle_style.get("ring", "solid")) == "dotted":
		_dotted_ring(c, r, ink_main)
	else:
		_ring(c, r, 0.0, TAU, ink_main, 1.5)
	if style == "brackets":
		var s := r * 1.0
		var a := clampf(r * 0.55, 8.0, 26.0)
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				var corner := c + Vector2(sx * s, sy * s) * 0.9
				_ln(corner, corner - Vector2(sx * a, 0.0), ink_main, 1.6)
				_ln(corner, corner - Vector2(0.0, sy * a), ink_main, 1.6)
		_ln(c - Vector2(5.0, 0.0), c + Vector2(5.0, 0.0), ink_main, 1.3)
		_ln(c - Vector2(0.0, 5.0), c + Vector2(0.0, 5.0), ink_main, 1.3)
	elif style == "square":
		var h := r * 1.0
		var gap := maxf(h * 0.35, 6.0)
		for sgn in [-1.0, 1.0]:
			_ln(c + Vector2(-h, sgn * h), c + Vector2(-gap, sgn * h), ink_main, 1.6)
			_ln(c + Vector2(gap, sgn * h), c + Vector2(h, sgn * h), ink_main, 1.6)
			_ln(c + Vector2(sgn * h, -h), c + Vector2(sgn * h, -gap), ink_main, 1.6)
			_ln(c + Vector2(sgn * h, gap), c + Vector2(sgn * h, h), ink_main, 1.6)
		var q := minf(r * 0.28, 14.0)
		_ln(c + Vector2(-q, 0.0), c + Vector2(-3.0, 0.0), ink_main, 1.3)
		_ln(c + Vector2(3.0, 0.0), c + Vector2(q, 0.0), ink_main, 1.3)
		_ln(c + Vector2(0.0, -q), c + Vector2(0.0, -3.0), ink_main, 1.3)
		_ln(c + Vector2(0.0, 3.0), c + Vector2(0.0, q), ink_main, 1.3)
	match str(game.reticle_style.get("center", "dot")):
		"cross":
			_ln(c - Vector2(8.0, 0.0), c + Vector2(8.0, 0.0), ink_main, 1.4)
			_ln(c - Vector2(0.0, 8.0), c + Vector2(0.0, 8.0), ink_main, 1.4)
		"open":
			_ring(c, 3.4, 0.0, TAU, ink_main, 1.3)
		"chevron":
			_ln(c + Vector2(-7.0, 4.0), c + Vector2(0.0, -3.0), ink_main, 1.6)
			_ln(c + Vector2(0.0, -3.0), c + Vector2(7.0, 4.0), ink_main, 1.6)
		_:
			draw_circle(c, 2.2, Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.6))
			draw_circle(c, 1.5, ink_main)


## Personnes dans le rayon d'effet : [infectés, civils].
func _zone_counts(p: Vector3, r: float) -> Vector2i:
	var z := 0
	var cv := 0
	var r2 := r * r
	for i in ctx.crowd.MAX_P:
		var q = ctx.crowd.pool[i]
		if not q.alive or q.kind > 1:
			continue
		var dx: float = q.pos.x - p.x
		var dz: float = q.pos.y - p.z
		if dx * dx + dz * dz <= r2:
			if q.kind == 0:
				z += 1
			else:
				cv += 1
	return Vector2i(z, cv)


func _draw_reticle(sz: Vector2) -> void:
	_rw = float(game.reticle_style.get("width", 1.0))
	_draw_reticle_body(sz)
	_rw = 1.0


func _draw_reticle_body(sz: Vector2) -> void:
	var c := sz * 0.5
	var w: Dictionary = ctx.weapons[ctx.arms.current]
	var gs = ctx.gunship
	var rng_m: float = game.aim_range
	var mpp: float = maxf(2.0 * rng_m * tan(deg_to_rad(gs.fov) * 0.5) / sz.y, 0.0005)
	var fore := maxf(rng_m / maxf(gs.altitude, 1.0), 1.0)      # raccourci de perspective sur l'axe vertical de l'écran
	var splash := float(w["splash_radius_m"])
	var r_px := clampf(splash / mpp, 7.0, 300.0)
	var style := str(w.get("reticle", "circle"))
	var amount: float = ctx.arms.ammo[ctx.arms.current]
	var amax := float(w.get("ammo", 1))

	# dispersion des coups à cette distance (écart-type), en pointillé
	var disp_m := float(w["dispersion_mrad"]) * 0.001 * rng_m
	var r_disp := disp_m / mpp
	if r_disp >= 4.0 and r_disp <= 320.0:
		_dotted_ring(c, r_disp, ink_dim)

	# rechargement : arc qui se remplit autour du cercle d'effet
	var per: float = ctx.arms.period()
	var reloading: bool = per > 0.25 and ctx.arms.cooldown > 0.0
	if reloading:
		var f := 1.0 - clampf(ctx.arms.cooldown / per, 0.0, 1.0)
		_ring(c, maxf(r_px - 7.0, 4.0), -PI * 0.5, -PI * 0.5 + TAU * f, ink_warn, 3.0)

	_reticle_frame(c, r_px, style)

	# branches graduées en mètres au sol ; la verticale est étirée par la perspective
	var start := maxf(r_px, r_disp) + 7.0
	var len_x := minf(150.0, c.x - 330.0 - start)
	var len_y := minf(150.0, c.y - maxf(150.0, _cy + _s(17.0) + 3.0) - start)  # la branche haute s'arrête sous les panneaux du haut (+ la place de son « M »)
	_arm(c, Vector2.RIGHT, start, len_x, mpp, 1)
	_arm(c, Vector2.LEFT, start, len_x, mpp, 0)
	_arm(c, Vector2.UP, start, len_y, mpp * fore, 2)
	_arm(c, Vector2.DOWN, start, len_y, mpp * fore, 0)

	# ---- blocs de texte hors de la bande des graduations (c.y ± 12) : à droite le calibre, au-dessous le télémètre ;
	# à gauche le contenu de la zone, puis les munitions
	var ox := clampf(start + _s(36.0), _s(120.0), _s(200.0))
	var xr := c.x + ox
	var xl := c.x - ox
	var cal := int(w.get("caliber_mm", 0))
	_rtxt(Vector2(xr, c.y - _s(40.0)), "%d MM" % cal, 28, ink_main)
	_rtxt(Vector2(xr, c.y - _s(16.0)), "%s · %s C/MIN" % [str(w.get("label", w["short"])), _thousands(int(w["rpm"]))], 13, ink_dim)

	var by := c.y + _s(50.0)
	# télémètre laser : le point clignote à chaque mesure
	var blink := 0.55 + 0.45 * sin(ctx.time * 9.0)
	var lc := Color(ink_warn.r, ink_warn.g, ink_warn.b, blink)
	draw_circle(Vector2(xr + _s(5.0), by - _s(5.0)), _s(4.5), Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.6))
	draw_circle(Vector2(xr + _s(5.0), by - _s(5.0)), _s(3.4), lc)
	_rtxt(Vector2(xr + _s(17.0), by), "TÉLÉMÈTRE LASER", 12, ink_dim)
	by += _s(32.0)
	_rtxt(Vector2(xr, by), "%s M" % _thousands(int(round(rng_m))), 26, ink_main)
	by += _s(21.0)
	_rtxt(Vector2(xr, by), "VOL %s S · SITE %d°" % [_fr(float(w["flight_time_s"])), int(round(game.aim_site))], 13, ink_dim)
	by += _s(19.0)
	_rtxt(Vector2(xr, by), "DISP. ±%s M" % _fr(disp_m), 13, ink_dim)
	by += _s(31.0)
	var pr = ctx.predictor
	if pr != null and pr.level() >= 2 and game.aim_b < 0:
		_rtxt(Vector2(xr, by), "IMPACT ~%d INFECTÉS" % pr.n_hit, 13, ink_warn if pr.n_hit > 0 else ink_dim)
		by += _s(19.0)
		if pr.level() >= 3:
			if pr.n_civ == 0:
				_rtxt(Vector2(xr, by), "AUCUN CIVIL EXPOSÉ", 13, ink_dim)
			elif fmod(ctx.time, 0.8) < 0.5:
				_rtxt(Vector2(xr, by), "~%d CIVILS EXPOSÉS" % pr.n_civ, 13, ink_warn)

	# munitions : juste à gauche, au-dessus de la bande des graduations
	var lw := _s(250.0)
	var ay := c.y - _s(41.0)
	_txt(Vector2(xl - lw, ay), "MUN %s" % _thousands(int(amount)), 22,
			ink_warn if amount < 1.0 or amount / amax < 0.15 else ink_main, HORIZONTAL_ALIGNMENT_RIGHT, lw)
	var gw := _s(150.0)
	var gx := xl - gw
	var gy := ay + _s(9.0)
	draw_rect(Rect2(gx, gy, gw, _s(5.0)), ink_dim, false, 1.0)
	draw_rect(Rect2(gx, gy, gw * clampf(amount / amax, 0.0, 1.0), _s(5.0)), ink_main)
	var st := "PRÊT"
	var st_col := ink_good
	if amount < 1.0:
		st = "MUNITIONS ÉPUISÉES"
		st_col = ink_warn
	elif reloading:
		st = "RECHARGE"
		st_col = ink_warn
	elif ctx.arms.trigger:
		st = "TIR"
		st_col = ink_main
	_txt(Vector2(xl - lw, c.y - _s(14.0)), st, 14, st_col, HORIZONTAL_ALIGNMENT_RIGHT, lw)

	# contenu de la zone visée : au-dessus des munitions, la dernière ligne la plus proche du réticule
	var lines: Array = []                        # [texte, taille, couleur]
	var b: int = game.aim_b
	_verdict_slot = Rect2(xr - 2.0, c.y + _s(50.0 + 32.0 + 21.0 + 19.0 + 31.0) - _s(22.0), _s(228.0), _s(86.0))      # là où le conseil s'affiche si le viseur est sur un immeuble
	var warn_civ := false
	if b >= 0 and ctx.lock != null and ctx.lock.aim_guided(b, splash):
		# le tir serait guidé jusqu'à un infecté caché : le toit visé n'est pas touché, on n'affiche donc ni l'immeuble ni le conseil « raser »
		lines.append(["TIR GUIDÉ", 15, ink_raze])
		lines.append(["INFECTÉ VERROUILLÉ", 13, ink_dim])
	elif b >= 0 and ctx.buildings.status[b] == ctx.buildings.ST_OK:
		lines.append(["IMMEUBLE  H %d M" % int(round(ctx.city.b_h[b])), 15, ink_main])
		lines.append(["HABITANTS %d" % ctx.buildings.occ[b], 15, ink_good])
		var zi: int = ctx.buildings.zin[b]
		if zi > 0:
			lines.append(["INFESTÉ  %d" % zi, 15, ink_warn])
		else:
			lines.append(["SANS INFECTÉ", 13, ink_dim])
		_draw_verdict(xr, by, b)
	elif b >= 0:
		lines.append(["RUINES", 15, ink_dim])
	else:
		var cnt := _zone_counts(game.aim_pos, splash)
		lines.append(["ZONE  Ø %s M" % _fr(splash * 2.0, 0 if splash >= 5.0 else 1), 15, ink_main])
		lines.append(["INFECTÉS %d" % cnt.x, 15, ink_warn if cnt.x > 0 else ink_dim])
		lines.append(["CIVILS %d" % cnt.y, 15, ink_good if cnt.y > 0 else ink_dim])
		warn_civ = cnt.y > 0 and fmod(ctx.time, 0.8) < 0.5
	var zy := ay - _s(32.0)
	var tx0 := c.x - 350.0                          # étendue horizontale des panneaux du haut
	var tx1 := c.x + 350.0
	for i in range(lines.size() - 1, -1, -1):
		var ls := str(lines[i][0])
		var lf := float(lines[i][1])
		var lwid := _w(ls, lf)
		if not (_cy > 0.0 and zy - float(_fs(lf)) < _cy + 4.0 and xl > tx0 and xl - lwid < tx1):      # sous un panneau : ligne omise
			_txt(Vector2(xl - lw, zy), ls, lf, lines[i][2], HORIZONTAL_ALIGNMENT_RIGHT, lw)
		zy -= _s(21.0)
	if warn_civ and not (_cy > 0.0 and zy - float(_fs(13.0)) < _cy + 4.0):
		_txt(Vector2(xl - lw, zy), "CIVILS DANS LA ZONE", 13, ink_warn, HORIZONTAL_ALIGNMENT_RIGHT, lw)


## Impacts d'obus lourds en vol : losange au point de chute, rayon d'effet et temps restant.
func _draw_impacts(sz: Vector2) -> void:
	var cam: Camera3D = game.cam
	var gs = ctx.gunship
	var shown := 0
	for i in range(ctx.arms.shells.size() - 1, -1, -1):
		var sh = ctx.arms.shells[i]
		var w: Dictionary = ctx.weapons[sh.w]
		var rad := float(w["splash_radius_m"])
		if rad < 5.0:
			continue
		var p3: Vector3 = sh.pos
		if cam.is_position_behind(p3):
			continue
		var sp := cam.unproject_position(p3)
		if sp.x < 20.0 or sp.y < 20.0 or sp.x > sz.x - 20.0 or sp.y > sz.y - 20.0:
			continue
		var dist := cam.global_position.distance_to(p3)
		var mpp: float = maxf(2.0 * dist * tan(deg_to_rad(gs.fov) * 0.5) / sz.y, 0.0005)
		var rp := clampf(rad / mpp, 6.0, 400.0)
		var f := clampf(sh.t / maxf(sh.dur, 0.01), 0.0, 1.0)
		_dotted_ring(sp, rp, Color(ink_warn.r, ink_warn.g, ink_warn.b, 0.75))
		var d := 9.0
		var pts := PackedVector2Array([sp + Vector2(0, -d), sp + Vector2(d, 0), sp + Vector2(0, d), sp + Vector2(-d, 0), sp + Vector2(0, -d)])
		draw_polyline(pts, Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.6), 4.0)
		draw_polyline(pts, ink_warn, 1.8)
		_txt(sp + Vector2(-_s(30.0), -d - _s(8.0)), "%s S" % _fr(maxf(sh.t, 0.0)), 13, ink_warn, HORIZONTAL_ALIGNMENT_CENTER, _s(60.0))
		# barre de progression sous le losange
		draw_rect(Rect2(sp + Vector2(-14.0, d + 6.0), Vector2(28.0 * (1.0 - f), 3.0)), ink_warn)
		draw_rect(Rect2(sp + Vector2(-14.0, d + 6.0), Vector2(28.0, 3.0)), ink_warn, false, 1.0)
		shown += 1
		if shown >= 6:
			break


## Capteurs de l'atelier : marqueur d'anticipation du prédicteur et verrou du désignateur laser.
func _draw_sensors(sz: Vector2) -> void:
	var cam: Camera3D = game.cam
	var gs = ctx.gunship
	var c := sz * 0.5
	var pr = ctx.predictor
	if pr != null and pr.shown:
		var mk: Vector2 = pr.marker()
		var gp: Vector2 = pr.group_now()
		var lp := Vector3(mk.x, 0.0, mk.y)
		var behind := cam.is_position_behind(lp)
		var sp := cam.unproject_position(lp)
		var splash := float(ctx.weapons[ctx.arms.current]["splash_radius_m"])
		var col := ink_good if gs.aim.distance_to(mk) <= splash else ink_siege
		if not behind and sp.x > 30.0 and sp.y > 30.0 and sp.x < sz.x - 30.0 and sp.y < sz.y - 30.0:
			var dist := cam.global_position.distance_to(lp)
			var mpp: float = maxf(2.0 * dist * tan(deg_to_rad(gs.fov) * 0.5) / sz.y, 0.0005)
			var r := clampf(splash / mpp, 6.0, 300.0)
			var gsp := cam.unproject_position(Vector3(gp.x, 0.0, gp.y))
			if pr.lead_m() >= 0.8 and gsp.distance_to(sp) > 5.0:
				_ln(gsp, sp, Color(col.r, col.g, col.b, 0.75), 1.2)
				draw_circle(gsp, 2.5, col)
			_dotted_ring(sp, r, Color(col.r, col.g, col.b, 0.9))
			var k := 6.0
			_ln(sp + Vector2(-k, 0), sp + Vector2(k, 0), col, 1.6)
			_ln(sp + Vector2(0, -k), sp + Vector2(0, k), col, 1.6)
			_txt(sp + Vector2(-_s(70.0), -r - _s(10.0)), "GRAPPE %d" % pr.n_follow, 12, col, HORIZONTAL_ALIGNMENT_CENTER, _s(140.0))
			var low := "ANTICIP. +%d M" % int(round(pr.lead_m())) if pr.lead_m() >= 0.8 else "À L'ARRÊT"
			_txt(sp + Vector2(-_s(70.0), r + _s(18.0)), low, 12, col, HORIZONTAL_ALIGNMENT_CENTER, _s(140.0))
		else:
			_edge_pointer(sz, sp, behind, "GRAPPE  %s M" % _thousands(int(round(gs.aim.distance_to(mk) / 10.0)) * 10), ink_siege)
	var des = ctx.designator
	if des != null and des.level() > 0:
		if des.active and des.target != null:
			var tp := Vector3(des.target.pos.x, 0.9, des.target.pos.y)
			if not cam.is_position_behind(tp):
				var sp2 := cam.unproject_position(tp)
				var rr := 17.0 + 2.5 * sin(ctx.time * 8.0)
				var k2 := 7.0
				for sx in [-1.0, 1.0]:
					for sy in [-1.0, 1.0]:
						var corner := sp2 + Vector2(sx * rr, sy * rr)
						_ln(corner, corner - Vector2(sx * k2, 0.0), ink_good, 1.8)
						_ln(corner, corner - Vector2(0.0, sy * k2), ink_good, 1.8)
				_txt(sp2 + Vector2(rr + _s(6.0), -rr - _s(2.0)), "VERROU LASER", 12, ink_good)
		var age: float = ctx.time - des.fail_t
		if age >= 0.0 and age < 1.4:
			var fa := clampf((1.4 - age) / 0.5, 0.0, 1.0)
			_txt(c + Vector2(-_s(100.0), _s(120.0)), "AUCUNE CIBLE À %d M" % int(des.radius()), 14, Color(ink_warn.r, ink_warn.g, ink_warn.b, fa), HORIZONTAL_ALIGNMENT_CENTER, _s(200.0))


## Étiquettes des flèches de bord déjà posées dans cette image : les suivantes sont décalées pour ne pas les recouvrir.
var _ptr_rects: Array = []


## Fait glisser un point du bord de l'écran hors des rectangles de texte du HUD (`_reserved`) : le long du bord haut ou bas
## horizontalement, le long des bords gauche et droit verticalement.
func _slide_out(q: Vector2, sz: Vector2, inset: float) -> Vector2:
	for _pass in 2:
		for r in _reserved + _ptr_rects:
			if not r.has_point(q):
				continue
			if absf(q.y - inset) < 2.0 or absf(q.y - (sz.y - inset)) < 2.0:
				var l: float = r.position.x - 8.0
				var rt: float = r.end.x + 8.0
				var go_left: bool = (q.x - l) <= (rt - q.x)
				if go_left and l < inset:
					go_left = false
				elif not go_left and rt > sz.x - inset:
					go_left = true
				q.x = clampf(l if go_left else rt, inset, sz.x - inset)
			else:
				var u: float = r.position.y - 8.0
				var dn: float = r.end.y + 8.0
				var go_up: bool = (q.y - u) <= (dn - q.y)
				if go_up and u < inset:
					go_up = false
				elif not go_up and dn > sz.y - inset:
					go_up = true
				q.y = clampf(u if go_up else dn, inset, sz.y - inset)
	return q


## Zones de texte du HUD que les flèches de bord d'écran évitent (recalculées à chaque image).
func _compute_reserved(sz: Vector2) -> void:
	_reserved.clear()
	_reserved.append(Rect2(0.0, 0.0, _s(250.0), maxf(_status_bottom, _s(215.0)) + 6.0))       # statut, en haut à gauche
	_reserved.append(Rect2(sz.x - _rcw() - 34.0, 0.0, _rcw() + 34.0, _s(250.0)))               # compteurs, en haut à droite
	if _obj_bottom > 0.0:
		_reserved.append(Rect2(0.0, _status_bottom, _s(270.0), _obj_bottom - _status_bottom + 6.0))   # objectifs, à gauche
	_reserved.append(Rect2(0.0, sz.y * 0.5 + _s(34.0), minf(_s(500.0), sz.x * 0.5 - 24.0), sz.y * 0.5 - _s(34.0)))      # journal radio et armes
	if game.show_map:
		_reserved.append(Rect2(sz.x - MAP_PX - 44.0, sz.y - MAP_PX - 44.0, MAP_PX + 44.0, MAP_PX + 44.0))
	var bw := minf(sz.x * 0.5, 680.0) + 40.0
	_reserved.append(Rect2(sz.x * 0.5 - bw * 0.5, 0.0, bw, maxf(_cy, _s(80.0))))               # bandeau URGENT
	if _verdict_slot.size != Vector2.ZERO:
		_reserved.append(_verdict_slot)                                                        # conseil « RASER » sous le viseur


## Vrai si le rectangle est libre : ni texte du HUD (image précédente), ni étiquette ou flèche déjà posée, ni (si strict) zone réservée.
func _label_free(q: Rect2, strict: bool = true) -> bool:
	var g := q.grow(2.0)
	for o in _text_rects:
		if g.intersects(o):
			return false
	for o in _ptr_rects:
		if g.intersects(o):
			return false
	if strict:
		for o in _reserved:
			if g.intersects(o):
				return false
	return true


## Cherche près de r (de plus en plus loin : à gauche, à droite, puis plus bas et plus haut) un emplacement libre qui reste dans l'écran ;
## Rect2() (taille nulle) si rien n'est libre.
func _place_label(r: Rect2, sz: Vector2, strict: bool = true) -> Rect2:
	var offs: Array = [Vector2.ZERO]
	for i in range(1, 9):
		offs.append(Vector2(32.0 * float(i), 0.0))
		offs.append(Vector2(-32.0 * float(i), 0.0))
	for dy in [r.size.y * 1.4, -r.size.y * 1.4, r.size.y * 2.8, -r.size.y * 2.8]:
		offs.append(Vector2(0.0, dy))
		for i in range(1, 5):
			offs.append(Vector2(32.0 * float(i), dy))
			offs.append(Vector2(-32.0 * float(i), dy))
	for o in offs:
		var q := Rect2(r.position + o, r.size)
		if q.position.x < 4.0 or q.end.x > sz.x - 4.0 or q.position.y < 4.0 or q.end.y > sz.y - 4.0:
			continue
		if _label_free(q, strict):
			return q
	return Rect2()


func _edge_pointer(sz: Vector2, sp: Vector2, behind: bool, label: String, col: Color, big: bool = false) -> void:
	var c := sz * 0.5
	var dir := (sp - c) * (-1.0 if behind else 1.0)
	dir = Vector2.UP if dir.length() < 1.0 else dir.normalized()
	var inset := _s(40.0) if big else 46.0
	var half := sz * 0.5 - Vector2(inset, inset)
	var k := minf(half.x / maxf(absf(dir.x), 0.0001), half.y / maxf(absf(dir.y), 0.0001))
	var q := _slide_out(c + dir * k, sz, inset)
	var nrm := Vector2(-dir.y, dir.x)
	var a := _s(26.0) if big else _s(14.0)
	var fc := col
	if big:
		fc.a *= 0.75 + 0.25 * sin(ctx.time * 8.0)
	var tip := q + dir * a
	var bse := q - dir * a * 0.55
	var wing := nrm * a * 0.65
	var poly := PackedVector2Array([tip, bse + wing, bse - wing])
	draw_polyline(PackedVector2Array([tip, bse + wing, bse - wing, tip]), Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.8), 5.0)
	draw_colored_polygon(poly, fc)
	var fsz := 17.0 if big else 12.0
	var fpx := float(_fs(fsz))
	var lw := maxf(_s(150.0), _w(label, fsz) + _s(12.0))
	var lp := q - dir * (a + _s(10.0))
	var lx := clampf(lp.x - lw * 0.5, 4.0, sz.x - lw - 4.0)
	var tw := _w(label, fsz)
	var r0 := Rect2(lx + (lw - tw) * 0.5 - 2.0, lp.y + 4.0 - fpx * 0.8, tw + 4.0, fpx * 1.05)      # l'écriture seule
	_ptr_rects.append(Rect2(q - Vector2(a, a), Vector2(a, a) * 2.0))                                   # la flèche elle-même
	var r := _place_label(r0, sz, true)                  # emplacement libre : ni texte, ni zone réservée, ni autre étiquette
	if r.size == Vector2.ZERO:
		r = _place_label(r0, sz, false)                  # à défaut : sans recouvrir de texte
	if r.size == Vector2.ZERO and big:
		r = r0                                           # la grande flèche de la priorité garde toujours son étiquette
	if r.size != Vector2.ZERO:
		_ptr_rects.append(r)
		_txt(Vector2(r.position.x + r.size.x * 0.5 - lw * 0.5, r.position.y + fpx * 0.8), label, fsz, col, HORIZONTAL_ALIGNMENT_CENTER, lw)


func _draw_markers(sz: Vector2) -> void:
	var cam: Camera3D = game.cam
	var city = ctx.city
	var bs = ctx.buildings
	var aim: Vector2 = ctx.gunship.aim
	var pr: Dictionary = ctx.director.urgent()
	var pr_b := int(pr.get("b", -1)) if str(pr.get("kind", "none")) != "none" else -1
	var cand: Array = []
	for b in bs.threatened_list():
		var adv: String = bs.advice(b)
		if not ADV_RANK.has(adv):
			continue
		cand.append([int(ADV_RANK[adv]), aim.distance_squared_to(Vector2(city.b_cx[b], city.b_cz[b])), b, adv])
	cand.sort_custom(func(x, y): return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]))
	var labelled := 0
	var pointers := 0
	var off_b := -1
	var off_adv := ""
	var off_col := ink_warn
	var off_sp := Vector2.ZERO
	var off_behind := false
	for e in cand:
		var b: int = e[2]
		var adv: String = e[3]
		var raze: bool = adv == "raze"
		var col: Color = ink_raze if raze else (ink_warn if adv == "defend" else ink_siege)
		if raze:
			_draw_raze_outline(b)
		var wp := Vector3(city.b_cx[b], city.b_h[b] + 6.0, city.b_cz[b])
		var behind := cam.is_position_behind(wp)
		var sp := cam.unproject_position(wp)
		var on_screen := not behind and sp.x > -30.0 and sp.y > -30.0 and sp.x < sz.x + 30.0 and sp.y < sz.y + 30.0
		if not on_screen:
			pointers += 1
			if pointers == 1 and b != pr_b:                          # une seule flèche : vers le plus urgent des immeubles hors champ
				off_b = b                                            # (celui de la priorité a déjà sa grande flèche)
				off_adv = adv
				off_col = col
				off_sp = sp
				off_behind = behind
			continue
		var r := _s(13.0)
		if b == pr_b:
			r = _s(20.0)
		if raze:
			col.a = 0.6 + 0.4 * (0.5 + 0.5 * sin(ctx.time * 8.0))
			_box(sp, r, col, 3.2)
		else:
			_box(sp, r, col, 1.8)
		if adv == "siege":
			var f: float = clampf(bs.siege[b] / bs.door_hp[b], 0.0, 1.0)
			draw_rect(Rect2(sp + Vector2(-_s(15.0), r + _s(6.0)), Vector2(_s(30.0) * f, _s(4.0))), col)
			draw_rect(Rect2(sp + Vector2(-_s(15.0), r + _s(6.0)), Vector2(_s(30.0), _s(4.0))), col, false, 1.0)
		if labelled < 4:
			labelled += 1
			var ln := _marker_lines(b, adv)
			var f1 := 20.0 if raze else 15.0
			var y1 := sp.y - r - _s(6.0)
			var y2 := sp.y + r + _s(22.0 if adv != "siege" else 36.0)
			var w1 := _w(str(ln[0]), f1)
			var w2 := _w(str(ln[1]), 13.0)
			var rc1 := Rect2(sp.x - w1 * 0.5, y1 - 0.76 * float(_fs(f1)), w1, 0.98 * float(_fs(f1)))
			var rc2 := Rect2(sp.x - w2 * 0.5, y2 - 0.76 * float(_fs(13.0)), w2, 0.98 * float(_fs(13.0)))
			if b != game.aim_b and not _label_blocked(rc1):
				_txt(Vector2(sp.x - _s(130.0), y1), ln[0], f1, col, HORIZONTAL_ALIGNMENT_CENTER, _s(260.0))
				_ptr_rects.append(rc1)
			if b != game.aim_b and not _label_blocked(rc2):
				_txt(Vector2(sp.x - _s(130.0), y2), ln[1], 13, col, HORIZONTAL_ALIGNMENT_CENTER, _s(260.0))
				_ptr_rects.append(rc2)
		else:
			var wn := _w("%d" % bs.occ[b], 14.0)
			if not _label_blocked(Rect2(sp.x - wn * 0.5, sp.y - r - _s(5.0) - _fs(14.0), wn, _fs(14.0) * 1.2)):
				_txt(sp + Vector2(-_s(20.0), -r - _s(5.0)), "%d" % bs.occ[b], 14, col, HORIZONTAL_ALIGNMENT_CENTER, _s(40.0))
	if off_b >= 0:
		var d_m := int(round(aim.distance_to(Vector2(city.b_cx[off_b], city.b_cz[off_b])) / 10.0)) * 10
		var ln0 := _marker_lines(off_b, off_adv)
		var more := "  (+%d)" % (pointers - 1) if pointers > 1 else ""
		_edge_pointer(sz, off_sp, off_behind, "%s · %d HAB. · %s M%s" % [ln0[0], bs.occ[off_b], _thousands(d_m), more], off_col)
	_draw_priority_marks(sz)
	_draw_metro_marks(sz)
	_draw_objective_markers(sz)


## Cadre à double trait (liseré sombre dessous) : lisible sur fond clair comme sur fond sombre.
func _box(c: Vector2, r: float, col: Color, wd: float) -> void:
	draw_rect(Rect2(c - Vector2(r, r), Vector2(r * 2.0, r * 2.0)), Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.6 * col.a), false, wd + 2.4)
	draw_rect(Rect2(c - Vector2(r, r), Vector2(r * 2.0, r * 2.0)), col, false, wd)


## Infectés cachés derrière un immeuble, « verrouillés » (scripts/core/lock.gd) : un carré rouge fin autour de chacun, seulement tant qu'il est
## caché. Il suit la position du moment de l'infecté et disparaît dès qu'il sort de derrière l'immeuble ou qu'il meurt. Un obus tiré sur le carré
## est guidé jusqu'à la rue (Arms). Les carrés sont dessinés sous les repères et les textes ; un carré qui se superposerait à un texte du HUD est
## omis, et un infecté tout près d'un carré déjà tracé est couvert par lui (un groupe n'est pas un tas de cadres).
const LOCK_MAX := 90                    # carrés tracés au plus (les plus proches de la visée d'abord)
const LOCK_M := 3.2                     # côté d'un carré, en mètres au sol

func _draw_locks(sz: Vector2) -> void:
	var lk = ctx.lock
	if lk == null or lk.hidden_p.is_empty():
		return
	var cam: Camera3D = game.cam
	var aim: Vector2 = ctx.gunship.aim
	var list: Array = []
	for p in lk.hidden_p:
		if p.alive and p.kind == ctx.crowd.K_ZOMBIE:                 # un infecté abattu (cadavre) perd son carré tout de suite
			list.append([aim.distance_squared_to(p.pos), p])
	if list.size() > LOCK_MAX:
		list.sort_custom(func(a, b): return a[0] < b[0])
		list.resize(LOCK_MAX)
	elif list.size() > 1:
		list.sort_custom(func(a, b): return a[0] < b[0])
	var dist: float = cam.global_position.distance_to(Vector3(aim.x, 0.0, aim.y))
	var mpp: float = maxf(2.0 * dist * tan(deg_to_rad(ctx.gunship.fov) * 0.5) / sz.y, 0.0005)
	var h: float = clampf(LOCK_M * 0.5 / mpp, _s(8.0), _s(26.0))       # demi-côté en pixels
	var col := ink_raze
	col.a = 0.95
	var edge := Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.7)
	var done: Array = []
	for e in list:
		var p = e[1]
		var wp := Vector3(p.pos.x, 1.0, p.pos.y)
		if cam.is_position_behind(wp):
			continue
		var sp := cam.unproject_position(wp)
		if not _on_screen(sp, sz, 8.0):
			continue
		var covered := false
		for q in done:
			if (q as Vector2).distance_squared_to(sp) < h * h * 0.64:
				covered = true
				break
		if covered:
			continue
		var on_text := false
		for t in _text_rects:
			if (t as Rect2).grow(h * 0.5).has_point(sp):
				on_text = true
				break
		if on_text:
			continue
		done.append(sp)
		var rc := Rect2(sp - Vector2(h, h), Vector2(h, h) * 2.0)
		draw_rect(rc, edge, false, 3.6)
		draw_rect(rc, col, false, 1.8)


## Immeuble à raser : son toit, cerclé de rouge et teinté, et ses arêtes verticales (l'immeuble lui-même est rouge dans la scène :
## BuildingSystem.is_raze_alert → shader). Rien n'est dessiné si un coin est derrière la caméra.
func _draw_raze_outline(b: int) -> void:
	var city = ctx.city
	var cam: Camera3D = game.cam
	var rot := Basis(Vector3.UP, city.b_yaw[b])
	var hw: float = city.b_w[b] * 0.5
	var hd: float = city.b_d[b] * 0.5
	var ctr := Vector3(city.b_cx[b], 0.0, city.b_cz[b])
	var roof := PackedVector2Array()
	var foot := PackedVector2Array()
	for k in [Vector2(-1.0, -1.0), Vector2(1.0, -1.0), Vector2(1.0, 1.0), Vector2(-1.0, 1.0)]:
		var off := rot * Vector3(k.x * hw, 0.0, k.y * hd)
		var top := ctr + off + Vector3(0.0, city.b_h[b], 0.0)
		var bot := ctr + off
		if cam.is_position_behind(top) or cam.is_position_behind(bot):
			return
		roof.append(cam.unproject_position(top))
		foot.append(cam.unproject_position(bot))
	var pulse := 0.5 + 0.5 * sin(ctx.time * 8.0)
	var fill := ink_raze
	fill.a = 0.14 + 0.14 * pulse
	draw_colored_polygon(roof, fill)
	var line := ink_raze
	line.a = 0.65 + 0.35 * pulse
	for i in 4:
		var j := (i + 1) % 4
		draw_line(foot[i], roof[i], Color(line.r, line.g, line.b, 0.55), 1.6)
		draw_line(roof[i], roof[j], Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.7), 6.0)
	for i in 4:
		var j2 := (i + 1) % 4
		draw_line(roof[i], roof[j2], line, 3.4)


## Deux lignes d'étiquette d'un immeuble menacé : [titre, détail].
func _marker_lines(b: int, adv: String) -> Array:
	var bs = ctx.buildings
	var inf: int = bs.zin[b]
	var o: int = bs.occ[b]
	match adv:
		"raze":
			return ["RASER", "INFESTÉ ×%d · %d HAB." % [inf, o]]
		"defend":
			return ["INFESTÉ ×%d" % inf, "%d HAB. · NE PAS RASER" % o]
		"siege":
			return ["PORTE ATTAQUÉE %d %%" % int(round(100.0 * clampf(bs.siege[b] / bs.door_hp[b], 0.0, 1.0))), "%d HAB. · TIREZ À LA PORTE" % o]
		"open":
			return ["PORTE FORCÉE", "%d HAB." % o]
	return ["", ""]


func _draw_verdict(x: float, y: float, b: int) -> void:
	var bs = ctx.buildings
	var adv: String = bs.advice(b)
	var o: int = bs.occ[b]
	var head := "RASER : NON"
	var why := "AUCUNE MENACE"
	var col := ink_dim
	match adv:
		"raze":
			head = "RASER : OUI"
			why = "IMMEUBLE PERDU"
			col = ink_raze
			col.a = 0.6 + 0.4 * (0.5 + 0.5 * sin(ctx.time * 8.0))
		"defend":
			why = "TENEZ LA RUE"
			col = ink_main
		"siege":
			why = "TIREZ À LA PORTE"
			col = ink_siege
		"open":
			why = "SURVEILLEZ"
			col = ink_siege
		"empty":
			why = "PLUS D'HABITANTS"
	_rtxt(Vector2(x, y), head, 21.0 if adv == "raze" else 18.0, col)
	_rtxt(Vector2(x, y + _s(21.0)), why, 14, col)
	if o > 0 and ctx.arms.current > 0:
		# le prix d'un obus qui détruit l'immeuble : un civil dévoré (−40) si l'immeuble est perdu, une bavure (−150) sinon
		var price := _prices("−{e} POINTS CHACUN" if adv == "raze" else "−{c} POINTS CHACUN")
		_rtxt(Vector2(x, y + _s(40.0)), "LE RASER TUE %d CIVIL%s" % [o, "S" if o > 1 else ""], 13, ink_dim)
		_rtxt(Vector2(x, y + _s(58.0)), price, 13, ink_dim)


func _txt_r(rx: float, y: float, s: String, fs: float = 16.0, col: Color = Color(-1.0, 0.0, 0.0, 1.0)) -> void:
	_txt(Vector2(rx - _w(s, fs), y), s, fs, col)


## Les panneaux du haut se placent d'après `_cy`, celui de l'image précédente : un panneau qui apparaît n'y est pas encore, et les branches du
## réticule, les lignes de la zone d'effet et les étiquettes passeraient dessous pendant une image. On lui réserve donc sa place dès sa première
## image, avec sa hauteur de la dernière fois (ou une estimation).
func _reserve_new_panels() -> void:
	if game.state == "ended" or ctx.director.state != "running":
		return
	var tk := minf(ts, TOP_TS_MAX)
	var add := 0.0
	var d = ctx.director
	if not d.loss_events.is_empty() and not bool(_top_on.get("loss", false)):
		var age: float = ctx.time - float(d.loss_events.back()["t"])
		if age >= 0.0 and age <= LOSS_SHOW_S:
			add += float(_top_h.get("loss", 96.0 * tk))
	if ctx.supports != null and not bool(_top_on.get("drone", false)) and ctx.supports.drone_left > 0.0:
		add += float(_top_h.get("drone", 24.0 * tk))
	_cy += add


## Note qu'un panneau du haut a été dessiné (ou non) à cette image, et sa hauteur.
func _top_note(key: String, h: float) -> void:
	_top_on[key] = h > 0.5
	if h > 0.5:
		_top_h[key] = h


## Couleur d'une priorité : rouge uniquement pour un immeuble à raser, ambre pour tout le reste.
func _prio_col(kind: String) -> Color:
	return ink_raze if kind == "raze" else ink_siege


## Bandeau URGENT (haut, au centre) : la chose à faire maintenant, où (direction et distance depuis la visée) et avec quelle arme.
## Écrit `_cy` : l'ordonnée libre juste dessous (pertes et annonces).
func _draw_priority(sz: Vector2) -> void:
	var save := ts
	ts = minf(ts, TOP_TS_MAX)
	_draw_priority_body(sz)
	ts = save


func _draw_priority_body(sz: Vector2) -> void:
	var y0 := _s(6.0) + (_s(24.0) if _mutator_tag() != "" else 0.0)         # tout en haut de l'écran, sous la ligne des mutateurs s'il y en a
	_cy = y0
	if ctx.director.state != "running":
		return
	var pr: Dictionary = ctx.director.urgent()
	var kind := str(pr.get("kind", "none"))
	if kind == "none":
		_txt(Vector2(0.0, y0 + _s(12.0)), "AUCUNE URGENCE", 14, ink_dim, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
		_cy = y0 + _s(28.0)
		return
	var col := _prio_col(kind)
	var lvl := int(pr["level"])
	var tag := "URGENT" if lvl >= 3 else ("PRIORITÉ" if lvl == 2 else "OBJECTIF")
	var aim: Vector2 = ctx.gunship.aim
	var tgt: Vector2 = ctx.director.prio.aim_point(pr)
	var where: String
	if aim.distance_to(tgt) <= float(pr["radius"]):
		where = "VISEUR DANS LA ZONE · TIREZ"
	else:
		where = "%s · %s M" % [ctx.director.compass_fr(aim, pr["pos"]).to_upper(), _thousands(int(round(aim.distance_to(pr["pos"]) / 10.0)) * 10)]
	var wi := int(pr["weapon"])
	if wi >= 0 and wi < ctx.weapons.size():
		var wn := str(ctx.weapons[wi]["short"])
		where += ("  ·  %s" % wn) if ctx.arms.current == wi else ("  ·  %s (TOUCHE %d)" % [wn, wi + 1])
	var head := "%s · %s" % [tag, str(pr["title"])]
	var hint := str(pr["hint"])
	var maxw := minf(sz.x * 0.5, 660.0)
	var f1 := _fit(head, 26.0, maxw, 15.0)
	var f2 := _fit(where, 17.0, maxw, 12.0)
	var f3 := _fit(hint, 14.0, maxw, 11.0)
	var h1 := float(_fs(f1))
	var h2 := float(_fs(f2))
	var h3 := float(_fs(f3))
	var pw := maxf(maxf(_w(head, f1), _w(where, f2)), _w(hint, f3)) + _s(40.0)
	var ty1 := y0 + _s(7.0) + h1 * 0.95
	var ty2 := ty1 + h2 * 1.35
	var ty3 := ty2 + h3 * 1.35
	var bottom := (ty3 if hint != "" else ty2) + _s(8.0)
	var px := sz.x * 0.5 - pw * 0.5
	var pulse := 0.5 + 0.5 * sin(ctx.time * 7.0)
	draw_rect(Rect2(px, y0, pw, bottom - y0), Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.66))
	if _rec:
		_text_new.append(Rect2(px - 4.0, y0 - 2.0, pw + 8.0, bottom - y0 + 4.0))        # le cadre entier compte comme du texte : étiquettes et flèches l'évitent
	var bc := Color(col.r, col.g, col.b, (0.55 + 0.45 * pulse) if kind == "raze" else 0.9)
	draw_rect(Rect2(px, y0, pw, bottom - y0), bc, false, 2.5)
	draw_rect(Rect2(px, y0, _s(8.0), bottom - y0), bc)
	_txt(Vector2(px, ty1), head, f1, col, HORIZONTAL_ALIGNMENT_CENTER, pw)
	_txt(Vector2(px, ty2), where, f2, ink_main, HORIZONTAL_ALIGNMENT_CENTER, pw)
	if hint != "":
		_txt(Vector2(px, ty3), hint, f3, ink_dim, HORIZONTAL_ALIGNMENT_CENTER, pw)
	_cy = bottom + _s(10.0)


## Repère de la priorité dans la scène : grandes équerres autour d'une cible de la rue (les immeubles ont déjà leur cadre, agrandi) ;
## grande flèche en bord d'écran quand elle est hors champ.
func _draw_priority_marks(sz: Vector2) -> void:
	if ctx.director.state != "running":
		return
	var pr: Dictionary = ctx.director.urgent()
	var kind := str(pr.get("kind", "none"))
	if kind == "none":
		return
	var cam: Camera3D = game.cam
	var col := _prio_col(kind)
	var b := int(pr["b"])
	var p: Vector2 = pr["pos"]
	var bp := p
	if b >= 0 and kind != "raze":
		bp = Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])        # les cadres d'immeuble sont posés sur le toit, pas sur la porte
	var wp := Vector3(bp.x, (ctx.city.b_h[b] + 6.0) if b >= 0 else 3.0, bp.y)
	var behind := cam.is_position_behind(wp)
	var sp := cam.unproject_position(wp)
	if not behind and _on_screen(sp, sz, 10.0):
		if b >= 0:
			return
		var pulse := 0.5 + 0.5 * sin(ctx.time * 8.0)
		var r := _s(34.0) + _s(4.0) * pulse
		var k := _s(12.0)
		var cc := Color(col.r, col.g, col.b, 0.95)
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				var corner := sp + Vector2(sx * r, sy * r)
				_ln(corner, corner - Vector2(sx * k, 0.0), cc, 3.0)
				_ln(corner, corner - Vector2(0.0, sy * k), cc, 3.0)
		_txt(sp + Vector2(-_s(90.0), r + _s(24.0)), str(pr["title"]), 15, col, HORIZONTAL_ALIGNMENT_CENTER, _s(180.0))
	else:
		var d_m := int(round(ctx.gunship.aim.distance_to(p) / 10.0)) * 10
		_edge_pointer(sz, sp, behind, "%s · %s M" % [str(PRIO_SHORT.get(kind, "")), _thousands(d_m)], col, true)


## Texte centré sur cx, coupé en lignes de maxw pixels au plus ; `y` est la ligne de base de la première. Retourne l'ordonnée sous la dernière.
func _txt_wrap(cx: float, y: float, s: String, fs: float, col: Color, maxw: float, y_max: float = INF) -> float:
	var words := s.split(" ")
	var line := ""
	var step := float(_fs(fs)) * 1.25
	for wd in words:
		var t := wd if line == "" else line + " " + wd
		if line != "" and _w(t, fs) > maxw:
			if y <= y_max:
				_txt(Vector2(cx - maxw * 0.5, y), line, fs, col, HORIZONTAL_ALIGNMENT_CENTER, maxw)
			y += step
			line = wd
		else:
			line = t
	if line != "" and y <= y_max:
		_txt(Vector2(cx - maxw * 0.5, y), line, fs, col, HORIZONTAL_ALIGNMENT_CENTER, maxw)
		y += step
	return y


func _draw_losses(sz: Vector2) -> void:
	var save := ts
	ts = minf(ts, TOP_TS_MAX)
	var y0 := _cy
	_draw_losses_body(sz)
	_top_note("loss", _cy - y0)
	ts = save


func _draw_losses_body(sz: Vector2) -> void:
	var d = ctx.director
	if d.loss_events.is_empty():
		return
	var cam: Camera3D = game.cam
	var aim: Vector2 = ctx.gunship.aim
	var shown := 0
	var y := _cy
	var maxw := sz.x - 2.0 * _s(280.0)
	for i in range(d.loss_events.size() - 1, -1, -1):
		var e: Dictionary = d.loss_events[i]
		var age: float = ctx.time - float(e["t"])
		if age > LOSS_SHOW_S or age < 0.0:
			break
		var a := clampf(minf(age / 0.15, (LOSS_SHOW_S - age) / 1.5), 0.0, 1.0)
		var txt: Array = LOSS_TXT[str(e["cause"]) + ("_ok" if bool(e.get("ok", false)) else "")]
		var n: int = int(e["n"])
		var pos: Vector2 = e["pos"]
		var col := ink_warn
		col.a *= a
		var save := ink_outline
		ink_outline = Color(save.r, save.g, save.b, save.a * a)
		var where := ""
		if pos != Vector2.ZERO:
			where = " · %s, %d m" % [d.compass_fr(aim, pos), int(round(aim.distance_to(pos) / 50.0)) * 50]
			var wp := Vector3(pos.x, 3.0, pos.y)
			var behind := cam.is_position_behind(wp)
			var sp := cam.unproject_position(wp)
			if not behind and _on_screen(sp, sz, 20.0):
				var rr := _s(14.0) + _s(10.0) * clampf(age / 1.2, 0.0, 1.0)
				draw_arc(sp, rr, 0.0, TAU, 28, Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.6 * a), 5.0)
				draw_arc(sp, rr, 0.0, TAU, 28, col, 2.4)
				if not _label_blocked(Rect2(sp.x - _s(22.0), sp.y - rr - _s(6.0) - _s(15.0), _s(44.0), _s(19.0))):
					_txt(sp + Vector2(-_s(40.0), -rr - _s(6.0)), "−%d" % n, 17, col, HORIZONTAL_ALIGNMENT_CENTER, _s(80.0))
			elif shown < 1:
				_edge_pointer(sz, sp, behind, "−%d · %s" % [n, str(txt[0]).to_upper()], col)
		if shown == 0:
			var head := "%d CIVIL%s PERDU%s" % [n, "S" if n > 1 else "", "S" if n > 1 else ""]
			_txt(Vector2(0.0, y + _s(24.0)), head, 22, col, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
			var c2 := ink_main
			c2.a *= a
			var l2 := _cap(str(txt[0])) + where
			_txt(Vector2(0.0, y + _s(48.0)), l2, _fit(l2, 15.0, maxw, 11.0), c2, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
			var c3 := ink_dim
			c3.a *= a
			var l3 := _prices(str(txt[1]))
			y += _s(54.0)
			y = _txt_wrap(sz.x * 0.5, y + _s(15.0), l3, 13, c3, maxw, _top_limit - _s(5.0)) + _s(6.0)
		else:
			var c4 := ink_dim
			c4.a *= a
			var l4 := "avant : %s (%d)%s" % [str(txt[0]), n, where]
			if y + _s(22.0) <= _top_limit:                 # pas de place avant les textes du réticule : l'événement plus ancien reste sur la vue (anneau)
				_txt(Vector2(0.0, y + _s(16.0)), l4, _fit(l4, 13.0, maxw, 10.0), c4, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
				y += _s(21.0)
		ink_outline = save
		shown += 1
		if shown >= 3:
			break
	_cy = y


func _cap(s: String) -> String:
	return s.substr(0, 1).to_upper() + s.substr(1)


## Remplace {e} (points perdus par civil dévoré) et {c} (par civil tué par nos tirs) par les valeurs du barème (data/scoring.json).
func _prices(s: String) -> String:
	var pts: Dictionary = ctx.score.cfg.get("points", {}) if ctx.score != null else {}
	return s.replace("{e}", str(absi(int(pts.get("civ_eaten", -40))))).replace("{c}", str(absi(int(pts.get("civ_collateral", -150)))))




## Bouches de métro (secteurs qui en ont) : petit repère cyan quand la bouche est à l'écran et proche de la visée.
func _draw_metro_marks(sz: Vector2) -> void:
	var city = ctx.city
	if city.metro_nodes.is_empty():
		return
	var cam: Camera3D = game.cam
	var gs = ctx.gunship
	var col := Color(0.35, 0.85, 1.0, 0.9) if game.white_hot else Color(0.05, 0.3, 0.55, 1.0)
	for n in city.metro_nodes:
		var p: Vector2 = city.nodes[n]
		if p.distance_to(gs.aim) > 650.0:
			continue
		var wp := Vector3(p.x, 3.0, p.y)
		if cam.is_position_behind(wp):
			continue
		var sp := cam.unproject_position(wp)
		if sp.x < 24.0 or sp.y < 24.0 or sp.x > sz.x - 24.0 or sp.y > sz.y - 24.0:
			continue
		draw_arc(sp, 11.0, 0.0, TAU, 20, col, 1.6)
		var fpx := float(_fs(11.0))
		var tw := _w("MÉTRO", 11.0)
		var r0 := Rect2(sp.x - tw * 0.5 - 2.0, sp.y + _s(28.0) - fpx * 0.8, tw + 4.0, fpx * 1.05)
		var rl := _place_label(r0, sz, false)            # près de la bouche, mais hors des textes du HUD et des autres étiquettes
		if rl.size != Vector2.ZERO:
			var lw := maxf(_s(60.0), tw + 12.0)
			_ptr_rects.append(rl)
			_txt(Vector2(rl.position.x + rl.size.x * 0.5 - lw * 0.5, rl.position.y + fpx * 0.8), "MÉTRO", 11, col, HORIZONTAL_ALIGNMENT_CENTER, lw)


# ---------------------------------------------------------------- appuis et infectés spéciaux

## Rayon en pixels d'une longueur au sol, à la distance du point lp (même calcul que le prédicteur).
func _ground_px(lp: Vector3, meters: float, sz: Vector2) -> float:
	var dist: float = game.cam.global_position.distance_to(lp)
	var mpp: float = maxf(2.0 * dist * tan(deg_to_rad(ctx.gunship.fov) * 0.5) / sz.y, 0.0005)
	return meters / mpp


func _on_screen(sp: Vector2, sz: Vector2, margin: float = 24.0) -> bool:
	return sp.x > margin and sp.y > margin and sp.x < sz.x - margin and sp.y < sz.y - margin


## Zones des appuis : cercle du barrage (avec le temps avant l'impact), repère du leurre, infectés cernés par le drone.
func _draw_support_marks(sz: Vector2) -> void:
	var sup = ctx.supports
	if sup == null:
		return
	var cam: Camera3D = game.cam
	for m in sup.marks:
		var p: Vector2 = m["pos"]
		var lp := Vector3(p.x, 0.0, p.y)
		var behind := cam.is_position_behind(lp)
		var sp := cam.unproject_position(lp)
		var label := "BARRAGE  %d s" % int(ceil(float(m["left"])))
		if not behind and _on_screen(sp, sz):
			var r := clampf(_ground_px(lp, float(m["r"]), sz), 8.0, 900.0)
			var a := 0.55 + 0.35 * sin(ctx.time * 9.0)
			draw_arc(sp, r, 0.0, TAU, 64, Color(ink_siege.r, ink_siege.g, ink_siege.b, a), 1.8)
			_txt(sp + Vector2(-_s(80.0), -minf(r, 400.0) - _s(8.0)), label, 12, ink_siege, HORIZONTAL_ALIGNMENT_CENTER, _s(160.0))
		else:
			_edge_pointer(sz, sp, behind, label, ink_siege)
	var cr = ctx.crowd
	if cr.decoy_left > 0.0:
		var dp := Vector3(cr.decoy_pos.x, 2.0, cr.decoy_pos.y)
		var dsp := cam.unproject_position(dp)
		var dlabel := "LEURRE  %d s" % int(ceil(cr.decoy_left))
		if not cam.is_position_behind(dp) and _on_screen(dsp, sz):
			var rr := 12.0 + 4.0 * sin(ctx.time * 6.0)
			draw_arc(dsp, rr, 0.0, TAU, 24, ink_siege, 1.6)
			draw_arc(dsp, rr * 0.5, 0.0, TAU, 16, ink_siege, 1.2)
			_txt(dsp + Vector2(-_s(60.0), rr + _s(16.0)), dlabel, 12, ink_siege, HORIZONTAL_ALIGNMENT_CENTER, _s(120.0))
		else:
			_edge_pointer(sz, dsp, cam.is_position_behind(dp), dlabel, ink_siege)
	if sup.drone_left > 0.0:
		var cs: Array = sup.drone_contacts(160)
		var lines := 0
		for c in cs:
			var zp: Vector2 = c["pos"]
			var wp := Vector3(zp.x, 1.0, zp.y)
			if cam.is_position_behind(wp):
				continue
			var zs := cam.unproject_position(wp)
			if not _on_screen(zs, sz, 6.0):
				continue
			draw_arc(zs, 9.0, 0.0, TAU, 14, ink_good, 1.3)
			var tg: Vector2 = c["target"]
			if tg != Vector2.INF and lines < 40:
				var tw := Vector3(tg.x, 8.0, tg.y)
				if not cam.is_position_behind(tw):
					_ln(zs, cam.unproject_position(tw), Color(ink_siege.r, ink_siege.g, ink_siege.b, 0.45), 1.0)
					lines += 1



## Infectés spéciaux : losange et étiquette (colosse : jauge de blindage restant), flèche au bord pour le plus proche hors champ.
func _draw_specials(sz: Vector2) -> void:
	var cr = ctx.crowd
	var cam: Camera3D = game.cam
	var gs = ctx.gunship
	var far_sp := Vector2.ZERO
	var far_behind := false
	var far_label := ""
	var far_d := INF
	var pr_key := str(ctx.director.urgent().get("key", ""))
	for i in cr.MAX_P:
		var z = cr.pool[i]
		if not z.alive or z.kind != cr.K_ZOMBIE or z.ztype <= 0 or z.rising:
			continue
		var cfg: Dictionary = cr.ztype_cfg(z.ztype)
		var wp := Vector3(z.pos.x, 2.4 * z.scale_v, z.pos.y)
		var behind := cam.is_position_behind(wp)
		var sp := cam.unproject_position(wp)
		var d_m: float = gs.aim.distance_to(z.pos)
		var label := "%s  %s M" % [str(cfg.get("short", "")), _thousands(int(round(d_m / 10.0)) * 10)]
		var col := ink_siege if z.ztype == cr.ZT_SCREAMER else ink_warn
		if not behind and _on_screen(sp, sz, 20.0):
			_diamond(sp + Vector2(0.0, -24.0), 8.0, col, 1.8)
			var fpx := float(_fs(12.0))
			var tw := _w(label, 12.0)
			var r0 := Rect2(sp.x - tw * 0.5 - 2.0, sp.y - _s(40.0) - fpx * 0.8, tw + 4.0, fpx * 1.05)
			var rl := _place_label(r0, sz, false)          # près du losange, mais hors des textes du HUD et des autres étiquettes
			if rl.size != Vector2.ZERO:
				var lw := maxf(_s(140.0), tw + 12.0)
				_ptr_rects.append(rl)
				_txt(Vector2(rl.position.x + rl.size.x * 0.5 - lw * 0.5, rl.position.y + fpx * 0.8), label, 12, col, HORIZONTAL_ALIGNMENT_CENTER, lw)
			if z.ztype == cr.ZT_COLOSSUS:
				var hp_max: float = float(cfg.get("hp", 780.0)) * ctx.rule("zombie_hp", 40.0) / 40.0
				var f := clampf(z.hp / maxf(hp_max, 1.0), 0.0, 1.0)
				draw_rect(Rect2(sp + Vector2(-20.0, -16.0), Vector2(40.0, 3.0)), Color(col.r, col.g, col.b, 0.35))
				draw_rect(Rect2(sp + Vector2(-20.0, -16.0), Vector2(40.0 * f, 3.0)), col)
		elif d_m < far_d and pr_key != "special:%d" % z.id:
			far_d = d_m
			far_sp = sp
			far_behind = behind
			far_label = label
	if far_d < INF:
		_edge_pointer(sz, far_sp, far_behind, far_label, ink_warn)


## Barre des appuis achetés (touches 4 à 7) : nom, appels restants, recharge ou temps d'action restant.
func _draw_supports(sz: Vector2) -> void:
	var sup = ctx.supports
	if sup == null:
		return
	var h := _s(48.0)
	var x := _s(290.0)
	var y := sz.y - h - _s(12.0)
	var n_own := 0
	for d0 in sup.defs:
		if sup.level(str(d0["id"])) > 0:
			n_own += 1
	if n_own == 0:
		return
	var room := sz.x - (float(MAP_PX) + 44.0 if game.show_map else 24.0) - x          # la barre ne passe pas sous la carte
	var w := minf(_s(112.0), (room - 8.0 * float(n_own - 1)) / float(n_own))
	for d in sup.defs:
		var id := str(d["id"])
		if sup.level(id) <= 0:
			continue
		var st: String = sup.state_of(id)
		var col := ink_main
		var line2 := ""
		var f := 1.0
		match st:
			"ready":
				line2 = "PRÊT  ×%d" % int(sup.charges[id])
				col = ink_good
			"cool":
				line2 = "%d s  ×%d" % [int(ceil(float(sup.cool[id]))), int(sup.charges[id])]
				col = ink_dim
				f = 1.0 - float(sup.cool[id]) / maxf(float(sup.params(id).get("cooldown_s", 60.0)), 1.0)
			"active":
				line2 = "EN COURS %d s" % int(ceil(sup.active_left(id)))
				col = ink_siege
			"empty":
				line2 = "ÉPUISÉ"
				col = ink_warn
		var t1 := "%d  %s" % [int(d["key"]), str(d["short"])]
		_txt(Vector2(x + _s(6.0), y + _s(19.0)), t1, _fit(t1, 14.0, w - _s(10.0), 10.0), ink_main if st != "empty" else ink_dim)
		_txt(Vector2(x + _s(6.0), y + _s(39.0)), line2, _fit(line2, 13.0, w - _s(10.0), 10.0), col)
		draw_rect(Rect2(x, y, w, h), Color(ink_dim.r, ink_dim.g, ink_dim.b, 0.55), false, 1.0)
		draw_rect(Rect2(x, y + h - 3.0, w * clampf(f, 0.0, 1.0), 3.0), col)
		x += w + 8.0


# ---------------------------------------------------------------- objectifs

func _diamond(c: Vector2, r: float, col: Color, wd: float = 1.6) -> void:
	var pts := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0), c + Vector2(0, -r)])
	draw_polyline(pts, col, wd)


## Coche ou croix de résultat (dessinées : les glyphes ✓ ✗ ne sont pas garantis dans la police).
func _result_icon(c: Vector2, ok: bool, col: Color) -> void:
	if ok:
		draw_polyline(PackedVector2Array([c + Vector2(-5, 0), c + Vector2(-1.5, 4), c + Vector2(5.5, -5)]), col, 2.0)
	else:
		draw_line(c + Vector2(-4.5, -4.5), c + Vector2(4.5, 4.5), col, 2.0)
		draw_line(c + Vector2(4.5, -4.5), c + Vector2(-4.5, 4.5), col, 2.0)


const OBJ_TAG := {"hold": "IMMEUBLE", "evac": "ÉVACUATION", "intercept": "GROUPE"}


## Repères des objectifs : losange et cercle sur la cible, ou flèche au bord de l'écran quand elle est hors champ.
func _draw_objective_markers(sz: Vector2) -> void:
	var ob = ctx.objectives
	if ob == null:
		return
	var cam: Camera3D = game.cam
	var gs = ctx.gunship
	var foot: float = 2.0 * game.aim_range * tan(deg_to_rad(gs.fov) * 0.5) * sz.x / maxf(sz.y, 1.0)
	var pxm: float = sz.x / maxf(foot, 1.0)
	for m in ob.markers():
		var p: Vector2 = m["pos"]
		var bi: int = m["b"]
		var wp := Vector3(p.x, (ctx.city.b_h[bi] + 6.0) if bi >= 0 else 4.0, p.y)
		var behind := cam.is_position_behind(wp)
		var sp := cam.unproject_position(wp)
		var d_m: float = gs.aim.distance_to(p)
		var tag: String = OBJ_TAG.get(m["type"], "OBJECTIF")
		var label := "%s  %s M" % [tag, _thousands(int(round(d_m / 10.0)) * 10)]
		if not behind and sp.x > 28.0 and sp.y > 28.0 and sp.x < sz.x - 28.0 and sp.y < sz.y - 28.0:
			_diamond(sp, 13.0, ink_siege, 2.0)
			if float(m["radius"]) > 30.0:
				var rpx := clampf(float(m["radius"]) * pxm, 18.0, 240.0)
				draw_arc(sp, rpx, 0.0, TAU, 48, Color(ink_siege.r, ink_siege.g, ink_siege.b, 0.55), 1.4)
			_txt(sp + Vector2(-_s(80.0), _s(30.0)), label, 12, ink_siege, HORIZONTAL_ALIGNMENT_CENTER, _s(160.0))
		else:
			_edge_pointer(sz, sp, behind, label, ink_siege)


## Panneau des objectifs en cours (colonne de gauche, sous le statut) : titre, échéance, avancement ; résultats un instant.
func _draw_objectives(sz: Vector2) -> void:
	var ob = ctx.objectives
	if ob == null:
		return
	var items: Array = ob.panel_items()
	if items.is_empty():
		return
	var x := 24.0
	var pw := minf(_s(236.0), 340.0)                      # au texte très grand le panneau reste en deçà du bloc munitions du viseur
	var y := _status_bottom + _s(18.0)
	_txt(Vector2(x, y), "OBJECTIFS", 12, ink_dim)
	y += _s(24.0)
	var n := 0
	for it in items:
		if n >= 3:
			break
		n += 1
		if it["state"] == "active":
			var left: float = ob.time_left(it)
			var col := ink_warn if (left >= 0.0 and left <= 15.0) else ink_siege
			var title := str(it["title"]).to_upper()
			var tm := "%d:%02d" % [int(left) / 60, int(left) % 60] if left >= 0.0 else ""
			_txt(Vector2(x, y), title, _fit(title, 14.0, pw - (_w(tm, 14.0) + 8.0 if tm != "" else 0.0), 10.0), col)
			if tm != "":
				_txt(Vector2(x, y), tm, 14, col, HORIZONTAL_ALIGNMENT_RIGHT, pw)
			var detail := str(it["detail"])
			_txt(Vector2(x, y + _s(20.0)), detail, _fit(detail, 12.0, pw, 9.0), ink_dim)
			var f: float = float(it["progress"])
			draw_rect(Rect2(x, y + _s(28.0), pw, _s(3.0)), Color(ink_dim.r, ink_dim.g, ink_dim.b, 0.3))
			draw_rect(Rect2(x, y + _s(28.0), pw * f, _s(3.0)), col)
			y += _s(50.0)
		else:
			var ok: bool = it["state"] == "done"
			var age: float = ctx.time - float(it["t_done"])
			var a := clampf((ob.RESULT_SHOW_S - age) / 2.0, 0.0, 1.0)
			var c := ink_good if ok else ink_warn
			c.a *= a
			var save := ink_outline
			ink_outline = Color(save.r, save.g, save.b, save.a * a)
			_result_icon(Vector2(x + _s(7.0), y - _s(5.0)), ok, c)
			var rt := str(it["title"]).to_upper()
			_txt(Vector2(x + _s(22.0), y), rt, _fit(rt, 13.0, pw - _s(70.0), 10.0), c)
			if ok and int(it["pts"]) > 0:
				_txt(Vector2(x, y), "+%d" % int(it["pts"]), 13, c, HORIZONTAL_ALIGNMENT_RIGHT, pw)
			ink_outline = save
			y += _s(27.0)
	_obj_bottom = y


## Drone d'observation : temps restant et infectés cernés, sous le bandeau URGENT.
func _draw_drone_status(sz: Vector2) -> void:
	var save := ts
	ts = minf(ts, TOP_TS_MAX)
	var y0 := _cy
	_draw_drone_status_body(sz)
	_top_note("drone", _cy - y0)
	ts = save


func _draw_drone_status_body(sz: Vector2) -> void:
	var sup = ctx.supports
	if sup == null or sup.drone_left <= 0.0:
		return
	var cs: Array = sup.drone_contacts(160)
	_txt(Vector2(0.0, _cy + _s(14.0)), "DRONE  %d s  ·  %d INFECTÉS CERNÉS" % [int(ceil(sup.drone_left)), cs.size()], 13, ink_good,
			HORIZONTAL_ALIGNMENT_CENTER, sz.x)
	_cy += _s(24.0)


## Message bref au centre : nouvelle taille du texte.
func _draw_notice(sz: Vector2) -> void:
	var age := float(Time.get_ticks_msec() - _notice_ms) / 1000.0
	if _notice == "" or age < 0.0 or age > 1.8:
		return
	var a := clampf((1.8 - age) / 0.5, 0.0, 1.0)
	var save := ink_outline
	ink_outline = Color(save.r, save.g, save.b, save.a * a)
	var col := ink_main
	col.a *= a
	var dim := ink_dim
	dim.a *= a
	_txt(Vector2(0.0, sz.y * 0.27), _notice, 26, col, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
	_txt(Vector2(0.0, sz.y * 0.27 + _s(28.0)), "T : changer la taille du texte", 14, dim, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
	ink_outline = save


## Bandeaux : nouvel objectif, objectif accompli ou perdu, objectif caché découvert (sous le bandeau URGENT et les pertes).
func _draw_toasts(sz: Vector2) -> void:
	var save := ts
	ts = minf(ts, TOP_TS_MAX)
	_draw_toasts_body(sz)
	ts = save


func _draw_toasts_body(sz: Vector2) -> void:
	var ob = ctx.objectives
	if ob == null:
		return
	var ts_: Array = ob.active_toasts()
	var shown := 0
	var maxw := sz.x - 2.0 * _s(280.0)
	if _cy + _s(100.0) > _top_limit:
		return                                   # plus de place au-dessus du réticule : l'annonce reste dans le journal radio
	for i in range(ts_.size() - 1, -1, -1):
		if shown >= 2:
			break
		var t: Dictionary = ts_[i]
		var age: float = ctx.time - float(t["t"])
		var a := clampf(minf(age / 0.25, (ob.TOAST_S - age) / 0.8), 0.0, 1.0)
		var col := ink_main
		match str(t["kind"]):
			"done", "hidden":
				col = ink_good
			"failed":
				col = ink_warn
			"new":
				col = ink_siege
		col.a *= a
		var save := ink_outline
		ink_outline = Color(save.r, save.g, save.b, save.a * a)
		var y := _cy + shown * _s(88.0)
		var l1 := str(t["text"])
		_txt(Vector2(0, y + _s(16.0)), l1, _fit(l1, 13.0, maxw, 10.0), Color(col.r, col.g, col.b, col.a * 0.85), HORIZONTAL_ALIGNMENT_CENTER, sz.x)
		var l2 := str(t["sub"]).to_upper()
		_txt(Vector2(0, y + _s(48.0)), l2, _fit(l2, 26.0, maxw, 14.0), col, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
		if int(t["pts"]) > 0:
			_txt(Vector2(0, y + _s(72.0)), "+%s POINTS" % _thousands(int(t["pts"])), 15, col, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
		ink_outline = save
		shown += 1


func _draw_status(sz: Vector2) -> void:
	var w: Dictionary = ctx.weapons[ctx.arms.current]
	var gs = ctx.gunship
	var y := _s(40.0)
	_txt(Vector2(24, y), str(w["name"]).to_upper(), 20)
	var foot: float = 2.0 * game.aim_range * tan(deg_to_rad(gs.fov) * 0.5) * sz.x / maxf(sz.y, 1.0)
	var st := _s(23.0)
	y += _s(28.0)
	_txt(Vector2(24, y), "CHAMP %s°  ·  %s M" % [_fr(gs.fov), _thousands(int(round(foot)))], 15, ink_dim)
	y += st
	_txt(Vector2(24, y), "DIST %s M" % _thousands(int(round(game.aim_range))), 15, ink_dim)
	y += st
	_txt(Vector2(24, y), "AZ %03d°   SITE %d°" % [int(round(game.aim_bearing)), int(round(game.aim_site))], 15, ink_dim)
	y += st
	_txt(Vector2(24, y), "BLANC CHAUD" if game.white_hot else "NOIR CHAUD", 15, ink_dim)
	y += st
	if not ctx.city.places.is_empty():
		var place: String = ctx.city.place_at(gs.aim.x, gs.aim.y)
		if place != "":
			_txt(Vector2(24, y), place.to_upper(), _fit(place.to_upper(), 15.0, _s(250.0), 11.0), ink_main)
		y += st
	if ctx.sound != null and (ctx.sound.muted or ctx.sound.voices_muted):
		_txt(Vector2(24, y), ctx.sound.status(), 14, ink_warn)
		y += st
	var pr = ctx.predictor
	if pr != null and pr.level() > 0:
		var on: bool = pr.shown
		_txt(Vector2(24, y), "PRÉDICTEUR N%d  %s" % [pr.level(), ("GRAPPE %d" % pr.n_follow) if on else "AUCUN INFECTÉ"], 13,
				ink_main if on else ink_dim)
		y += _s(21.0)
	var des = ctx.designator
	if des != null and des.level() > 0:
		var lk: bool = des.active
		_txt(Vector2(24, y), "LASER N%d  %s" % [des.level(), "VERROUILLÉ" if lk else "LIBRE · CLIC DROIT"], 13, ink_good if lk else ink_dim)
		y += _s(21.0)
	_status_bottom = y


func _draw_counters(sz: Vector2) -> void:
	var d = ctx.director
	var rc := _rcw()
	var x := sz.x - 24.0 - rc
	var tag := _sector_tag()
	var y := _s(22.0)
	if tag != "":
		_txt(Vector2(x, y), tag, _fit(tag, 12.0, rc, 9.0), ink_dim, HORIZONTAL_ALIGNMENT_RIGHT, rc)
	var tl := int(d.t) if d.endless else int(d.time_left())
	y += _s(30.0)
	_txt(Vector2(x, y), "%02d:%02d" % [tl / 60, tl % 60], 22, ink_main, HORIZONTAL_ALIGNMENT_RIGHT, rc)
	if d.endless:
		_txt(Vector2(x, y), "VAGUE %d" % maxi(d.wave_n, 1), 18, ink_siege, HORIZONTAL_ALIGNMENT_LEFT, rc)
	var mt := _mutator_tag()
	if mt != "":
		_txt(Vector2(0.0, _s(26.0)), mt, 13, ink_siege, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
	var lost_col := ink_warn if d.lost * 5 >= d.max_lost * 4 else ink_main
	y += _s(28.0)
	_txt(Vector2(x, y), "PERTES %d / %d" % [d.lost, d.max_lost], 18, lost_col, HORIZONTAL_ALIGNMENT_RIGHT, rc)
	y += _s(21.0)
	var bk := _loss_breakdown(d)
	_txt_r(x + rc, y, bk, _fit(bk, 12.0, rc, 9.0), ink_dim)
	y += _s(25.0)
	_txt(Vector2(x, y), "SAUVÉS %d" % d.saved, 16, ink_good, HORIZONTAL_ALIGNMENT_RIGHT, rc)
	y += _s(21.0)
	_txt(Vector2(x, y), "INFECTÉS NEUTRALISÉS %d" % d.kills, 14, ink_dim, HORIZONTAL_ALIGNMENT_RIGHT, rc)
	y += _s(36.0)
	_draw_score(x, y, rc)


## Origine des pertes comptées dans PERTES (leur somme est le chiffre affiché) : « IMM. 5 · RUE 2 · TIRS 1 · RASÉS 2 ».
func _loss_breakdown(d) -> String:
	var parts: Array = []
	for pr in [["inside", "IMM."], ["street", "RUE"], ["shot", "TIRS"], ["razed", "RASÉS"]]:
		var v: int = d.lost_by[pr[0]]
		if v > 0:
			parts.append("%s %d" % [pr[1], v])
	return " · ".join(parts) if not parts.is_empty() else "AUCUNE PERTE"


## « LES HALLES · CAUCHEMAR » : secteur et difficulté de la partie ("" dans les essais sans campagne).
func _sector_tag() -> String:
	var sc: Dictionary = ctx.profile.defs.sector(str(ctx.mission.get("id", ""))) if ctx.profile != null else {}
	if sc.is_empty():
		return ""
	var head := "%s · %s" % [str(sc["name"]).to_upper(), str(ctx.difficulty().get("name", "")).to_upper()]
	if ctx.mode == "endless":
		head = "NUIT BLANCHE · " + head
	elif ctx.mode == "daily":
		head = "DÉFI DU JOUR · " + head
	return head


## « BROUILLARD · PANNE RADIO » : mutateurs actifs ("" s'il n'y en a pas).
func _mutator_tag() -> String:
	if ctx.mutators.is_empty() or ctx.profile == null:
		return ""
	var names: Array = []
	for id in ctx.mutators:
		names.append(str(ctx.profile.defs.mutator(str(id)).get("short", id)).to_upper())
	return " · ".join(names)


func _draw_weapons(sz: Vector2) -> void:
	var x := 24.0
	var step := _s(30.0)
	var y := sz.y - _s(14.0) - step * float(ctx.weapons.size() - 1)
	for i in ctx.weapons.size():
		var w: Dictionary = ctx.weapons[i]
		var sel: bool = i == ctx.arms.current
		var col := ink_main if sel else ink_dim
		var yi: float = y + float(i) * step
		_txt(Vector2(x + _s(14.0), yi), "%d   %s   %d" % [i + 1, w["short"], int(ctx.arms.ammo[i])], 19.0 if sel else 15.0, col)
		if sel:
			draw_rect(Rect2(x, yi - _s(19.0), _s(4.0), _s(24.0)), ink_main)
		# rechargement propre à chaque arme : une arme qu'on vient de quitter finit de se recharger en arrière-plan
		var f: float = ctx.arms.reload_fraction(i)
		if f > 0.0:
			draw_rect(Rect2(x + _s(14.0), yi + _s(5.0), _s(150.0) * (1.0 - f), _s(4.0)), col)
			draw_rect(Rect2(x + _s(14.0), yi + _s(5.0), _s(150.0), _s(4.0)), col, false, 1.0)


func _draw_radio(sz: Vector2) -> void:
	var lines: Array = []
	for r in ctx.radio_log:
		var age: float = ctx.time - float(r[2])
		if age < 16.0 and game.state != "briefing":
			lines.append([r[0], r[1], age])
	if lines.size() > 3:
		lines = lines.slice(lines.size() - 3)
	var fsz := _fs(14.0)
	var wy := sz.y - _s(14.0) - _s(30.0) * float(ctx.weapons.size() - 1)       # première ligne de la liste des armes
	var y := wy - _s(32.0)
	var y_min := maxf(sz.y * 0.5 + _s(34.0), _obj_bottom + 8.0)               # ni sur le réticule ni sur les objectifs
	var width := minf(_s(470.0), sz.x * 0.5 - _s(60.0) - 24.0)
	for i in range(lines.size() - 1, -1, -1):
		var text: String = lines[i][0]
		var kind: String = lines[i][1]
		var age: float = lines[i][2]
		var col := ink_warn if kind == "alert" else (ink_good if kind == "good" else ink_main)
		col.a = clampf((16.0 - age) / 3.0, 0.0, 1.0) * 0.95
		var h := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width, fsz).y
		var top := y - h
		if top < y_min:
			break
		var base := Vector2(24.0, top + font.get_ascent(fsz))
		draw_multiline_string_outline(font, base, text, HORIZONTAL_ALIGNMENT_LEFT, width, fsz, -1, 4, Color(ink_outline.r, ink_outline.g, ink_outline.b, 0.8 * col.a))
		draw_multiline_string(font, base, text, HORIZONTAL_ALIGNMENT_LEFT, width, fsz, -1, col)
		y = top - _s(7.0)


func _draw_map(sz: Vector2) -> void:
	if not game.show_map or map_tex == null:
		return
	_map_o = Vector2(sz.x - MAP_PX - 20.0, sz.y - MAP_PX - 20.0)
	draw_texture_rect(map_tex, Rect2(_map_o, Vector2(MAP_PX, MAP_PX)), false)
	draw_rect(Rect2(_map_o, Vector2(MAP_PX, MAP_PX)), ink_dim, false, 1.0)
	var gs = ctx.gunship
	# orbite
	var prev := Vector2.ZERO
	var has_prev := false
	for i in 73:
		var a := float(i) / 72.0 * TAU
		var q := _mp(gs.center.x + gs.radius * cos(a), gs.center.y - gs.radius * sin(a))
		if has_prev and _in_map(q) and _in_map(prev):
			draw_line(prev, q, Color(1, 1, 1, 0.22), 1.0)
		prev = q
		has_prev = true
	# panne radio : la station ne transmet plus la situation, la carte ne montre que le terrain et la nacelle
	var blind: bool = ctx.has_mutator("radio_down")
	if blind:
		_txt(_map_o + Vector2(0.0, 14.0), "LIAISON COUPÉE", 12, ink_warn, HORIZONTAL_ALIGNMENT_CENTER, float(MAP_PX))
	# portes assiégées, puis immeubles infestés
	for b in ([] if blind else ctx.buildings.siege_list()):
		var q1 := _mp(ctx.city.b_cx[b], ctx.city.b_cz[b])
		draw_rect(Rect2(q1 - Vector2(3, 3), Vector2(6, 6)), ink_siege, false, 1.5)
	for b in ([] if blind else ctx.buildings.infested_list()):
		if ctx.buildings.advice(b) == "raze":
			continue                                                                   # immeuble perdu : dessiné en rouge plus bas, par-dessus
		var q2 := _mp(ctx.city.b_cx[b], ctx.city.b_cz[b])
		draw_rect(Rect2(q2 - Vector2(3, 3), Vector2(6, 6)), ink_warn, false, 1.5)
	# appuis : zones du barrage, rayon du drone et du leurre
	if ctx.supports != null:
		for m in ctx.supports.marks:
			_map_circle(m["pos"], float(m["r"]), ink_siege)
		if ctx.supports.drone_left > 0.0:
			_map_circle(ctx.supports.drone_pos, ctx.supports.drone_r, ink_good)
		if ctx.crowd.decoy_left > 0.0:
			_map_circle(ctx.crowd.decoy_pos, ctx.crowd.decoy_r, ink_siege)
	# objectifs
	if ctx.objectives != null and not blind:
		for m in ctx.objectives.markers():
			var qo := _mp(m["pos"].x, m["pos"].y)
			if float(m["radius"]) > 30.0:
				draw_arc(qo, maxf(float(m["radius"]) * map_k, 5.0), 0.0, TAU, 24, ink_siege, 1.0)
			_diamond(qo, 5.0, ink_siege, 1.6)
	# personnes
	for i in ([] if blind else range(ctx.crowd.MAX_P)):
		var p = ctx.crowd.pool[i]
		if not p.alive or p.kind == 3:
			continue
		var q3 := _mp(p.pos.x, p.pos.y)
		if p.kind == 1:
			draw_rect(Rect2(q3 - Vector2(1.2, 1.2), Vector2(2.4, 2.4)), ink_main)
		elif p.ztype > 0:
			draw_rect(Rect2(q3 - Vector2(2.5, 2.5), Vector2(5, 5)), ink_warn)
		else:
			draw_rect(Rect2(q3 - Vector2(1, 1), Vector2(2, 2)), ink_warn)
	# immeubles à raser : carré rouge plein cerclé d'un anneau qui bat (le fond de la carte est sombre : rouge vif dans les deux modes)
	if not blind:
		var pulse := 0.5 + 0.5 * sin(ctx.time * 8.0)
		for b in ctx.buildings.infested_list():
			if ctx.buildings.advice(b) != "raze":
				continue
			var qr := _mp(ctx.city.b_cx[b], ctx.city.b_cz[b])
			if not _in_map(qr):
				continue
			draw_rect(Rect2(qr - Vector2(6.0, 6.0), Vector2(12.0, 12.0)), Color(0.0, 0.0, 0.0, 0.8))
			draw_rect(Rect2(qr - Vector2(4.5, 4.5), Vector2(9.0, 9.0)), C_RAZE)
			draw_arc(qr, 9.0 + 3.0 * pulse, 0.0, TAU, 24, Color(C_RAZE.r, C_RAZE.g, C_RAZE.b, 0.95), 2.0)
	# bouches de métro
	for mn in ctx.city.metro_nodes:
		var qm := _mp(ctx.city.nodes[mn].x, ctx.city.nodes[mn].y)
		draw_arc(qm, 4.0, 0.0, TAU, 14, Color(0.35, 0.85, 1.0, 0.95) if game.white_hot else Color(0.05, 0.3, 0.55, 1.0), 1.6)
	# points d'évacuation
	for en in ctx.city.evac_nodes:
		var q4 := _mp(ctx.city.nodes[en].x, ctx.city.nodes[en].y)
		draw_line(q4 - Vector2(4, 0), q4 + Vector2(4, 0), ink_good, 2.0)
		draw_line(q4 - Vector2(0, 4), q4 + Vector2(0, 4), ink_good, 2.0)
	# visée et direction de regard
	var aim_p := _mp(gs.aim.x, gs.aim.y)
	var fwd := Vector2(gs.aim.x - gs.pos.x, gs.aim.y - gs.pos.z).normalized()
	var tail := aim_p - fwd * 30.0
	if _in_map(aim_p):
		draw_arc(aim_p, 5.0, 0.0, TAU, 20, ink_main, 1.5)
		if _in_map(tail):
			draw_line(tail, aim_p, ink_main, 1.0)
	var gp := _mp(gs.pos.x, gs.pos.z)
	if _in_map(gp):
		draw_circle(gp, 3.0, ink_main)
	else:
		# la nacelle tourne autour de la zone, hors de la carte : un repère au bord indique de quel côté elle se trouve
		var mc := _map_o + Vector2(MAP_PX, MAP_PX) * 0.5
		var dv := (gp - mc).normalized()
		var bp := mc + dv * (float(MAP_PX) * 0.5 / maxf(absf(dv.x), absf(dv.y)))
		var nv := dv.orthogonal()
		draw_colored_polygon(PackedVector2Array([bp + dv * 1.0, bp - dv * 9.0 + nv * 5.0, bp - dv * 9.0 - nv * 5.0]), ink_main)
	# priorité du moment : anneau sur la cible et trait depuis la visée (rouge pour un immeuble à raser, ambre sinon)
	if not blind and ctx.director.state == "running":
		var pr: Dictionary = ctx.director.urgent()
		var kind := str(pr.get("kind", "none"))
		if kind != "none":
			var pp: Vector2 = pr["pos"]
			var qp := _mp(pp.x, pp.y)
			var pc := C_RAZE if kind == "raze" else Color(1.0, 0.82, 0.4, 1.0)
			var pu := 0.5 + 0.5 * sin(ctx.time * 7.0)
			if _in_map(qp):
				if _in_map(aim_p) and aim_p.distance_to(qp) > 12.0:
					draw_line(aim_p, qp, Color(pc.r, pc.g, pc.b, 0.75), 1.4)
				draw_arc(qp, 11.0 + 3.0 * pu, 0.0, TAU, 28, Color(0.0, 0.0, 0.0, 0.7), 4.0)
				draw_arc(qp, 11.0 + 3.0 * pu, 0.0, TAU, 28, pc, 2.2)


## Cercle de rayon `meters` autour d'un point du monde, tracé sur la carte seulement là où il tient dans le cadre.
func _map_circle(center: Vector2, meters: float, col: Color) -> void:
	var r := maxf(meters * map_k, 3.0)
	var c := _mp(center.x, center.y)
	var prev := c + Vector2(r, 0.0)
	for i in range(1, 41):
		var a := float(i) / 40.0 * TAU
		var q := c + Vector2(cos(a), sin(a)) * r
		if _in_map(prev) and _in_map(q):
			draw_line(prev, q, col, 1.2)
		prev = q


func _draw_help(sz: Vector2) -> void:
	var rows := [
		["SOURIS", "orienter la nacelle"],
		["ZQSD / WASD", "orienter (Maj = rapide)"],
		["CLIC GAUCHE", "tirer"],
		["1 2 3 / TAB", "25 mm · 40 mm · 105 mm (chacune se recharge à part)"],
		["MOLETTE", "zoom"],
		["ESPACE", "blanc chaud / noir chaud"],
		["C", "marquage couleur civils / zombies"],
		["R", "recentrer l'orbite sur la visée"],
		["M", "carte tactique"],
		["N", "couper / rétablir le son"],
		["V", "couper / rétablir les voix radio"],
		["T", "taille du texte (3 niveaux)"],
		["H", "cette aide"],
		["ÉCHAP / P", "pause"],
	]
	if ctx.designator != null and ctx.designator.level() > 0:
		rows.insert(4, ["CLIC DROIT / E", "désigner un infecté au laser · relâcher"])
	if ctx.supports != null and not ctx.supports.owned_ids().is_empty():
		rows.insert(4, ["4 5 6 7", "appuis sur la visée : barrage · drone · leurre · largage"])
	var tips := [
		"Le bandeau URGENT (en haut) dit quoi faire maintenant : la cible, sa direction, sa distance, l'arme à prendre.",
		"Mode Recrue : le viseur est attiré vers la zone urgente. Bougez la souris pour reprendre la main.",
		"Raser un immeuble (105 mm) tue TOUS ses habitants. Ne le faites que s'il est perdu :",
		"  OUI : %d infectés dedans ou plus (ils sortent alors en flot) et %d habitants au plus." % [ctx.buildings.raze_min_inf(), int(ctx.rule("raze_max_occ", 14.0))],
		"  OUI aussi : 2 habitants ou moins avec 2 infectés, ou immeuble submergé (≥ ⅓ d'infectés).",
		"  NON : la porte tient encore (abattez les infectés devant la porte au 25 mm).",
		"  NON : moins de %d infectés dedans, ou trop d'habitants à ensevelir (tenez la rue)." % ctx.buildings.raze_min_inf(),
		"Un immeuble à raser est ROUGE : dans la scène, par son cadre, et sur la minicarte. Le conseil RASER : OUI / NON suit la visée.",
		_prices("Immeuble perdu rasé : −{e} points par civil, comme un civil dévoré, sans bavure."),
		_prices("Immeuble qui tenait encore ou civil tué par un tir : −{c} points, série rompue."),
	]
	if ctx.lock != null and ctx.lock.level > 0.0:
		tips.append("Un carré rouge entoure un infecté caché derrière un immeuble : visez-le, le tir est guidé jusqu'à la rue.")
	# mise en page en unités de base (texte « normal »), puis réduite si besoin pour tenir dans l'écran
	var base_h := 72.0 + (rows.size() - 1) * 22.0 + 34.0 + tips.size() * 20.0
	var base_w := 700.0
	var save_ts := ts
	ts = minf(save_ts, minf((sz.y - 24.0) / base_h, (sz.x - 24.0) / base_w))
	var h := base_h * ts
	var o := Vector2(sz.x * 0.5 - 340.0 * ts, maxf((sz.y - h) * 0.5 + 30.0 * ts, 36.0 * ts))
	draw_rect(Rect2(o - Vector2(20.0, 30.0) * ts, Vector2(base_w, base_h) * ts), C_BG)
	_txt(o, "COMMANDES", 18)
	for i in rows.size():
		var y := o.y + (30.0 + i * 22.0) * ts
		_txt(Vector2(o.x, y), rows[i][0], 15, ink_dim)
		_txt(Vector2(o.x + 160.0 * ts, y), rows[i][1], 15, ink_main)
	var ty := o.y + (30.0 + rows.size() * 22.0 + 14.0) * ts
	_txt(Vector2(o.x, ty), "QUOI FAIRE, ET QUAND RASER UN IMMEUBLE", 18)
	for i in tips.size():
		_txt(Vector2(o.x, ty + (26.0 + i * 20.0) * ts), str(tips[i]), 14, ink_siege if (i == 2) else ink_main)
	ts = save_ts


func _draw_pause(sz: Vector2) -> void:
	draw_rect(Rect2(Vector2.ZERO, sz), Color(0, 0, 0, 0.5))
	_txt(Vector2(0, sz.y * 0.5), "PAUSE", 40, ink_main, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
	_txt(Vector2(0, sz.y * 0.5 + _s(36.0)), "Échap ou P pour reprendre", 16, ink_dim, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
	_txt(Vector2(0, sz.y * 0.5 + _s(64.0)), "T : taille du texte (%s)" % str(TEXT_NAMES[text_level]).to_lower(), 16, ink_dim, HORIZONTAL_ALIGNMENT_CENTER, sz.x)
	if ctx.director.endless:
		_txt(Vector2(0, sz.y * 0.5 + _s(92.0)), "Entrée : mettre fin à la patrouille (le score est conservé)", 16, ink_siege, HORIZONTAL_ALIGNMENT_CENTER, sz.x)


## Score, série et derniers gains (en haut à droite, sous les compteurs).
func _draw_score(x: float, y: float, rc: float) -> void:
	var sc = ctx.score
	if sc == null:
		return
	_txt(Vector2(x, y), "SCORE %s" % _thousands(sc.points), 20, ink_warn if sc.points < 0 else ink_main, HORIZONTAL_ALIGNMENT_RIGHT, rc)
	var col := ink_main if sc.mult <= 1 else (ink_siege if sc.mult < 4 else ink_good)
	var y2 := y + _s(24.0)
	_txt(Vector2(x, y2), "SÉRIE %d   ×%d" % [sc.chain, sc.mult], 15, col, HORIZONTAL_ALIGNMENT_RIGHT, rc)
	var nxt: int = sc.next_tier_at()
	if nxt > 0:
		var base: int = 0
		for t in sc.cfg.get("chain_tiers", []):
			if int(t[1]) == sc.mult:
				base = int(t[0])
		var f := clampf(float(sc.chain - base) / float(maxi(nxt - base, 1)), 0.0, 1.0)
		var bw := rc * 0.42
		draw_rect(Rect2(x + rc - bw, y2 + _s(8.0), bw, _s(3.0)), Color(ink_dim.r, ink_dim.g, ink_dim.b, 0.35))
		draw_rect(Rect2(x + rc - bw, y2 + _s(8.0), bw * f, _s(3.0)), ink_dim)
	var fy := y2 + _s(30.0)
	var shown := 0
	for i in range(sc.feed.size() - 1, -1, -1):
		var e: Array = sc.feed[i]
		var age: float = ctx.time - float(e[2])
		var life: float = float(sc.cfg.get("feed_s", 4.0))
		if age > life or shown >= 3:
			continue
		var c := ink_main
		if e[1] == "bad":
			c = ink_warn
		elif e[1] == "good":
			c = ink_good
		elif e[1] == "kill":
			c = ink_dim
		c.a *= clampf((life - age) / 1.2, 0.0, 1.0)
		_txt(Vector2(x, fy + shown * _s(21.0)), str(e[0]), 14, c, HORIZONTAL_ALIGNMENT_RIGHT, rc)
		shown += 1


func _thousands(n: int) -> String:
	if n < 0:
		return "-" + _thousands(-n)
	var s := str(n)
	if n >= 1000:
		s = "%d %03d" % [n / 1000, n % 1000]
	return s
