extends RefCounted
## Carte de campagne : les secteurs sur une carte stylisée de la capitale (Seine, périphérique), leurs étoiles et leurs
## verrous, la fiche du secteur choisi et le choix de la difficulté. Écran de contrôles construit par Screens (même schéma
## que l'atelier) ; le départ passe par Game.select_session (la ville est régénérée).

const UiKit := preload("res://scripts/ui/ui_kit.gd")
const Campaign := preload("res://scripts/meta/campaign.gd")

var scr                                     # Screens
var ctx
var sel := 0                                # secteur choisi (indice dans defs.sectors)
var level := 0                              # difficulté choisie (indice dans defs.levels)
var from := "briefing"                      # écran d'où la carte a été ouverte
var _map: MapCanvas
var _side: VBoxContainer
var _go: Button
var _lv_buttons: Array = []
var _lv_text: Label
var _stars_line: Label


# ---------------------------------------------------------------- carte dessinée

## Carte dessinée : fond quadrillé, Seine, périphérique, secteurs. Reçoit des données toutes prêtes (pas d'accès au profil).
class MapCanvas extends Control:
	const PAD := 40.0
	## Seine, d'amont (sud-est) en aval (nord-ouest), en coordonnées normalisées de la carte.
	const RIVER := [Vector2(1.0, 0.80), Vector2(0.88, 0.76), Vector2(0.76, 0.66), Vector2(0.64, 0.60), Vector2(0.52, 0.585),
			Vector2(0.42, 0.615), Vector2(0.32, 0.60), Vector2(0.24, 0.64), Vector2(0.16, 0.58), Vector2(0.08, 0.60), Vector2(0.0, 0.52)]
	var items: Array = []                   # {num, name, tag, pos, unlocked, stars, n_stars, missing}
	var sel := 0
	var hover := -1
	var stars_total := 0
	var stars_all := 0
	var on_pick := Callable()
	var on_open := Callable()
	var _t := 0.0
	var _river := PackedVector2Array()

	func setup(p_items: Array, p_sel: int, p_total: int, p_all: int) -> void:
		items = p_items
		sel = p_sel
		stars_total = p_total
		stars_all = p_all
		custom_minimum_size = Vector2(620, 480)
		mouse_filter = Control.MOUSE_FILTER_STOP
		var pts := PackedVector2Array()
		for p in RIVER:
			pts.append(p)
		_river = _smooth(pts, 8)
		set_process(true)

	func _process(dt: float) -> void:
		_t += dt
		queue_redraw()

	static func _smooth(pts: PackedVector2Array, sub: int) -> PackedVector2Array:
		var out := PackedVector2Array()
		for i in pts.size() - 1:
			var p0: Vector2 = pts[maxi(i - 1, 0)]
			var p1: Vector2 = pts[i]
			var p2: Vector2 = pts[i + 1]
			var p3: Vector2 = pts[mini(i + 2, pts.size() - 1)]
			for k in sub:
				var t := float(k) / float(sub)
				out.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t
						+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t * t))
		out.append(pts[pts.size() - 1])
		return out

	func _pt(n: Vector2) -> Vector2:
		return Vector2(PAD + n.x * (size.x - 2.0 * PAD), PAD + n.y * (size.y - 2.0 * PAD))

	func _hit(at: Vector2) -> int:
		var best := -1
		var bd := 34.0
		for i in items.size():
			var d := at.distance_to(_pt(items[i]["pos"]))
			if d < bd:
				bd = d
				best = i
		return best

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseMotion:
			var h := _hit((ev as InputEventMouseMotion).position)
			if h != hover:
				hover = h
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if h >= 0 else Control.CURSOR_ARROW
		elif ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				var h2 := _hit(mb.position)
				if h2 >= 0:
					if mb.double_click and on_open.is_valid():
						on_open.call(h2)
					elif on_pick.is_valid():
						on_pick.call(h2)

	func _star(c: Vector2, r: float, filled: bool, col: Color) -> void:
		var pts := PackedVector2Array()
		for k in 10:
			var a := -PI * 0.5 + k * PI / 5.0
			var rr := r if k % 2 == 0 else r * 0.42
			pts.append(c + Vector2(cos(a), sin(a)) * rr)
		if filled:
			draw_colored_polygon(pts, col)
		pts.append(pts[0])
		draw_polyline(pts, col if filled else Color(0.93, 0.98, 1.0, 0.4), 1.2)

	func _lock(c: Vector2, col: Color) -> void:
		draw_rect(Rect2(c + Vector2(-6.0, -1.0), Vector2(12.0, 9.0)), col)
		draw_arc(c + Vector2(0.0, -1.0), 4.2, PI, TAU, 12, col, 2.0)
		draw_line(c + Vector2(-4.2, -1.0), c + Vector2(-4.2, 1.5), col, 2.0)
		draw_line(c + Vector2(4.2, -1.0), c + Vector2(4.2, 1.5), col, 2.0)

	func _draw() -> void:
		var font := get_theme_default_font()
		var main := Color(0.93, 0.98, 1.0, 0.95)
		var dim := Color(0.93, 0.98, 1.0, 0.62)
		var gold := Color(1.0, 0.82, 0.4, 1.0)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.015, 0.045, 0.05, 0.72))
		var gx := 0.0
		while gx <= size.x:
			draw_line(Vector2(gx, 0.0), Vector2(gx, size.y), Color(0.93, 0.98, 1.0, 0.05), 1.0)
			gx += 40.0
		var gy := 0.0
		while gy <= size.y:
			draw_line(Vector2(0.0, gy), Vector2(size.x, gy), Color(0.93, 0.98, 1.0, 0.05), 1.0)
			gy += 40.0
		# périphérique : boucle en tirets autour du centre
		var ring := PackedVector2Array()
		var n_ring := 144
		for k in n_ring + 1:
			var a := TAU * float(k) / float(n_ring)
			ring.append(_pt(Vector2(0.52 + cos(a) * 0.31, 0.52 + sin(a) * 0.36)))
		for k in n_ring:
			if k % 4 != 3:
				draw_line(ring[k], ring[k + 1], Color(0.93, 0.98, 1.0, 0.24), 2.0, true)
		draw_string(font, _pt(Vector2(0.20, 0.80)), "PÉRIPHÉRIQUE", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.93, 0.98, 1.0, 0.40))
		# Seine
		var river_px := PackedVector2Array()
		for p in _river:
			river_px.append(_pt(p))
		draw_polyline(river_px, Color(0.30, 0.55, 0.85, 0.30), 11.0, true)
		draw_polyline(river_px, Color(0.45, 0.72, 1.0, 0.65), 3.0, true)
		draw_string(font, _pt(Vector2(0.80, 0.865)), "SEINE", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.55, 0.78, 1.0, 0.70))
		# fil de la campagne
		for i in items.size() - 1:
			var a1: Vector2 = _pt(items[i]["pos"])
			var b1: Vector2 = _pt(items[i + 1]["pos"])
			var open2: bool = bool(items[i + 1]["unlocked"])
			draw_dashed_line(a1, b1, Color(0.93, 0.98, 1.0, 0.45 if open2 else 0.16), 1.5, 7.0, true, true)
		# secteurs
		for i in items.size():
			var it: Dictionary = items[i]
			var p: Vector2 = _pt(it["pos"])
			var open: bool = bool(it["unlocked"])
			var full: bool = int(it["stars"]) >= int(it["n_stars"]) and int(it["n_stars"]) > 0
			var col: Color = (gold if full else main) if open else Color(0.93, 0.98, 1.0, 0.30)
			var r := 21.0 if i == sel else 18.0
			draw_circle(p, r, Color(0.0, 0.0, 0.0, 0.80))
			draw_arc(p, r, 0.0, TAU, 48, col, 2.4, true)
			if i == sel:
				var rr := r + 8.0 + 2.5 * sin(_t * 4.0)
				draw_arc(p, rr, 0.0, TAU, 56, Color(gold.r, gold.g, gold.b, 0.85), 1.6, true)
				for d in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
					draw_line(p + d * (rr + 3.0), p + d * (rr + 11.0), gold, 2.0)
			elif i == hover:
				draw_arc(p, r + 6.0, 0.0, TAU, 48, Color(main.r, main.g, main.b, 0.5), 1.4, true)
			if open:
				draw_string(font, p + Vector2(-r, 7.0), str(it["num"]), HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, 20, col)
			else:
				_lock(p + Vector2(0.0, -1.0), col)
			# étoiles sous la pastille
			var ns := int(it["n_stars"])
			for k in ns:
				var sc := p + Vector2((float(k) - float(ns - 1) * 0.5) * 15.0, r + 14.0)
				_star(sc, 6.2, open and k < int(it["stars"]), gold)
			# nom et étiquette, du côté où il reste de la place
			var right: bool = p.x < size.x * 0.60
			var gap := 24.0 if i == sel else 14.0           # la bague de la sélection déborde du cercle
			var tx := p.x + r + gap if right else p.x - r - gap - 200.0
			var al := HORIZONTAL_ALIGNMENT_LEFT if right else HORIZONTAL_ALIGNMENT_RIGHT
			var ncol := main if open else dim
			draw_string(font, Vector2(tx, p.y - 2.0), str(it["name"]).to_upper(), al, 200.0, 16, ncol)
			if open:
				draw_string(font, Vector2(tx, p.y + 14.0), str(it["tag"]), al, 200.0, 12, dim)
			else:
				var miss := int(it["missing"])
				draw_string(font, Vector2(tx, p.y + 14.0), "encore %d étoile%s" % [miss, "s" if miss > 1 else ""], al, 200.0, 12, Color(1.0, 0.5, 0.4, 0.9))
		# cumul d'étoiles
		_star(Vector2(PAD - 8.0, size.y - 22.0), 8.0, true, gold)
		draw_string(font, Vector2(PAD + 6.0, size.y - 16.0), "%d / %d étoiles" % [stars_total, stars_all], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, main)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.93, 0.98, 1.0, 0.35), false, 1.0)


# ---------------------------------------------------------------- écran

func setup(p_scr, p_ctx) -> void:
	scr = p_scr
	ctx = p_ctx


func build(v: VBoxContainer, p_from: String) -> void:
	from = p_from
	var defs = ctx.profile.defs
	var cur := str(ctx.mission.get("id", ""))
	sel = maxi(defs.sector_index(cur), 0)
	level = maxi(defs.level_index(str(ctx.difficulty().get("id", defs.default_level))), 0)
	v.add_child(UiKit.label("CAMPAGNE", 30, UiKit.MAIN, HORIZONTAL_ALIGNMENT_CENTER))
	v.add_child(UiKit.label("Chaque étoile décrochée ouvre la route vers le secteur suivant.", 14, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER))
	v.add_child(UiKit.hline())
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 24)
	v.add_child(cols)
	_map = MapCanvas.new()
	_map.on_pick = Callable(self, "select")
	_map.on_open = Callable(self, "open_sector")
	cols.add_child(_map)
	_side = VBoxContainer.new()
	_side.custom_minimum_size = Vector2(440, 0)
	_side.add_theme_constant_override("separation", 4)
	cols.add_child(_side)
	v.add_child(UiKit.hline())
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	v.add_child(bar)
	var hint := UiKit.label("←  →  secteur      ↑  ↓  ou  1 2 3  difficulté", 12, UiKit.DIM)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(hint)
	bar.add_child(UiKit.button("Retour   (Échap)", Callable(scr, "close_campaign"), 180.0))
	bar.add_child(UiKit.button("Modes de jeu   (J)", Callable(scr, "open_modes").bind("campaign"), 220.0))
	_go = UiKit.button("Briefing du secteur   (Entrée)", Callable(self, "open_sector").bind(-1), 330.0)
	bar.add_child(_go)
	_refresh_map()
	_refresh_side()


## Données de la carte : un dictionnaire par secteur, calculé depuis le profil.
func _refresh_map() -> void:
	var defs = ctx.profile.defs
	var prof = ctx.profile
	var items: Array = []
	for i in defs.sectors.size():
		var sc: Dictionary = defs.sectors[i]
		var id := str(sc["id"])
		var pos: Array = sc["map"]
		items.append({"num": i + 1, "name": str(sc["name"]), "tag": str(sc["tag"]), "pos": Vector2(float(pos[0]), float(pos[1])),
				"unlocked": Campaign.is_unlocked(defs, prof, id), "stars": int(prof.mission_record(id)["best_stars"]),
				"n_stars": int(sc.get("n_stars", 3)), "missing": Campaign.stars_missing(defs, prof, id)})
	_map.setup(items, sel, prof.sector_stars(), defs.stars_available)


func select(i: int) -> void:
	var n: int = ctx.profile.defs.sectors.size()
	sel = clampi(i, 0, n - 1)
	_map.sel = sel
	_refresh_side()


func set_level(i: int) -> void:
	var defs = ctx.profile.defs
	level = clampi(i, 0, defs.levels.size() - 1)
	for k in _lv_buttons.size():
		_lv_buttons[k].set_pressed_no_signal(k == level)
	_lv_text.text = _level_text(defs.levels[level])


static func _mult(x: float) -> String:
	var s := ("%.1f" % x).replace(".", ",")
	return s.trim_suffix(",0")


func _level_text(lv: Dictionary) -> String:
	return "%s\nGains : XP ×%s  ·  crédits ×%s" % [str(lv["text"]), _mult(float(lv["xp_mult"])), _mult(float(lv["credit_mult"]))]


## Fiche du secteur choisi.
func _refresh_side() -> void:
	for c in _side.get_children():
		_side.remove_child(c)
		c.queue_free()
	_lv_buttons.clear()
	var prof = ctx.profile
	var defs = prof.defs
	var sc: Dictionary = defs.sectors[sel]
	var id := str(sc["id"])
	var open: bool = Campaign.is_unlocked(defs, prof, id)
	var rec: Dictionary = prof.mission_record(id)
	_side.add_child(UiKit.label("SECTEUR %d  ·  %s" % [sel + 1, str(sc["tag"]).to_upper()], 13, UiKit.DIM))
	_side.add_child(UiKit.label(str(sc["name"]).to_upper(), 28, UiKit.MAIN if open else UiKit.DIM))
	if not open:
		var miss: int = Campaign.stars_missing(defs, prof, id)
		_side.add_child(UiKit.label("VERROUILLÉ  ·  encore %d étoile%s à décrocher" % [miss, "s" if miss > 1 else ""], 15, UiKit.WARN))
	var txt := UiKit.label(str(sc["text"]), 14, UiKit.MAIN)
	txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	txt.custom_minimum_size = Vector2(430, 0)
	_side.add_child(txt)
	for f in sc.get("features", []):
		_side.add_child(UiKit.label("·  " + str(f), 13, UiKit.DIM))
	_side.add_child(UiKit.hline())
	# fiche personnelle
	if int(rec["plays"]) > 0:
		var rt: int = int(rec["best_rating"])
		var bd: int = int(rec.get("best_diff", -1))
		_side.add_child(UiKit.row("Meilleur score", UiKit.thousands(int(rec["best_score"])), UiKit.DIM, UiKit.MAIN, 14))
		_side.add_child(UiKit.row("Meilleure note", str(prof.RATINGS[rt]) if rt >= 0 else "—", UiKit.DIM, UiKit.rating_color(str(prof.RATINGS[rt]) if rt >= 0 else "—"), 14))
		_side.add_child(UiKit.row("Gagné à la difficulté", str(defs.levels[bd]["name"]) if bd >= 0 and bd < defs.levels.size() else "pas encore gagné", UiKit.DIM, UiKit.MAIN, 14))
	elif open:
		_side.add_child(UiKit.label("Secteur encore vierge.", 14, UiKit.DIM))
	# étoiles à décrocher
	var base: Dictionary = Campaign.load_mission(defs, id)
	var done: Array = rec["stars_done"]
	var stars: Array = base.get("stars", [])
	for i in stars.size():
		var ok: bool = i < done.size() and bool(done[i])
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		var ic := UiKit.StarsRow.new()
		ic.setup(1 if ok else 0, 1, 16.0)
		h.add_child(ic)
		h.add_child(UiKit.label(str(stars[i].get("text", "")), 14, UiKit.GOOD if ok else (UiKit.MAIN if open else UiKit.DIM)))
		_side.add_child(h)
	_side.add_child(UiKit.hline())
	# difficulté
	_side.add_child(UiKit.label("DIFFICULTÉ", 13, UiKit.DIM))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	_side.add_child(hb)
	for i in defs.levels.size():
		var b := Button.new()
		b.text = str(defs.levels[i]["name"])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(138, 32)
		b.add_theme_font_size_override("font_size", 15)
		b.set_pressed_no_signal(i == level)
		b.pressed.connect(set_level.bind(i))
		hb.add_child(b)
		_lv_buttons.append(b)
	_lv_text = UiKit.label(_level_text(defs.levels[level]), 13, UiKit.DIM)
	_lv_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lv_text.custom_minimum_size = Vector2(430, 0)
	_side.add_child(_lv_text)
	_go.disabled = not open


## Ouvre le briefing d'un secteur (le choisi si i < 0). Un secteur fermé reste fermé.
func open_sector(i: int = -1) -> void:
	if i >= 0:
		select(i)
	var prof = ctx.profile
	var defs = prof.defs
	var id := str(defs.sectors[sel]["id"])
	if not Campaign.is_unlocked(defs, prof, id):
		var miss: int = Campaign.stars_missing(defs, prof, id)
		scr.toast("Secteur verrouillé : encore %d étoile%s à décrocher." % [miss, "s" if miss > 1 else ""])
		return
	var lid := str(defs.levels[level]["id"])
	if from == "briefing" and id == str(ctx.mission.get("id", "")) and ctx.mode == "campaign":
		scr.close_campaign(lid)
	else:
		scr.game.select_session(id, lid)


func handle_key(ev: InputEventKey) -> bool:
	var n_s: int = ctx.profile.defs.sectors.size()
	match ev.keycode:
		KEY_LEFT:
			select(maxi(sel - 1, 0))
		KEY_RIGHT:
			select(mini(sel + 1, n_s - 1))
		KEY_TAB:
			select((sel + 1) % n_s)
		KEY_UP:
			set_level(level + 1)
		KEY_DOWN:
			set_level(level - 1)
		KEY_1, KEY_KP_1:
			set_level(0)
		KEY_2, KEY_KP_2:
			set_level(1)
		KEY_3, KEY_KP_3:
			set_level(2)
		KEY_ENTER, KEY_KP_ENTER:
			open_sector(-1)
		_:
			return false
	return true
