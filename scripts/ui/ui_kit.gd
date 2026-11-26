extends RefCounted
## Éléments d'interface des menus et du débriefing, au style de la visée thermique : texte clair cerclé de noir,
## cadres fins, aucune image. Tout est construit par le code (pas de scène).

const MAIN := Color(0.93, 0.98, 1.0, 0.95)
const DIM := Color(0.93, 0.98, 1.0, 0.62)
const WARN := Color(1.0, 0.5, 0.4, 1.0)
const GOOD := Color(0.65, 1.0, 0.75, 1.0)
const GOLD := Color(1.0, 0.82, 0.4, 1.0)
const BG := Color(0.0, 0.0, 0.0, 0.80)
const LINE := Color(0.93, 0.98, 1.0, 0.35)


## Rangée d'étoiles dessinées (pas de police : les glyphes ★ ne sont pas garantis).
class StarsRow extends Control:
	var n := 0
	var total := 3
	var star_px := 34.0

	func setup(p_n: int, p_total: int = 3, p_px: float = 34.0) -> void:
		n = p_n
		total = p_total
		star_px = p_px
		custom_minimum_size = Vector2(total * (star_px + 8.0), star_px + 6.0)
		queue_redraw()

	func _draw() -> void:
		for i in total:
			var c := Vector2(star_px * 0.5 + i * (star_px + 8.0), star_px * 0.5 + 3.0)
			var pts := PackedVector2Array()
			for k in 10:
				var a := -PI * 0.5 + k * PI / 5.0
				var r := star_px * 0.5 if k % 2 == 0 else star_px * 0.21
				pts.append(c + Vector2(cos(a), sin(a)) * r)
			var on := i < n
			if on:
				draw_colored_polygon(pts, Color(1.0, 0.82, 0.4, 1.0))
			pts.append(pts[0])
			draw_polyline(pts, Color(1.0, 0.82, 0.4, 1.0) if on else Color(0.93, 0.98, 1.0, 0.45), 1.6)


## Coche, croix ou point d'interrogation dessinés (ok = 1 coche, 0 croix, -1 inconnu).
class ResultIcon extends Control:
	var state := 1
	var px := 18.0

	func setup(p_state: int, p_px: float = 18.0) -> void:
		state = p_state
		px = p_px
		custom_minimum_size = Vector2(p_px + 4.0, p_px)
		queue_redraw()

	func _draw() -> void:
		var c := Vector2(px * 0.5 + 2.0, px * 0.5)
		var k := px / 18.0
		if state > 0:
			var col := Color(0.65, 1.0, 0.75, 1.0)
			draw_polyline(PackedVector2Array([c + Vector2(-5, 0) * k, c + Vector2(-1.5, 4) * k, c + Vector2(5.5, -5) * k]), col, 2.2)
		elif state == 0:
			var col2 := Color(1.0, 0.5, 0.4, 1.0)
			draw_line(c + Vector2(-4.5, -4.5) * k, c + Vector2(4.5, 4.5) * k, col2, 2.2)
			draw_line(c + Vector2(4.5, -4.5) * k, c + Vector2(-4.5, 4.5) * k, col2, 2.2)
		else:
			var col3 := Color(0.93, 0.98, 1.0, 0.45)
			draw_polyline(PackedVector2Array([c + Vector2(0, -6) * k, c + Vector2(6, 0) * k, c + Vector2(0, 6) * k, c + Vector2(-6, 0) * k, c + Vector2(0, -6) * k]), col3, 1.4)


const BRONZE := Color(0.84, 0.58, 0.38, 1.0)
const SILVER := Color(0.82, 0.88, 0.95, 1.0)


static func tier_color(tier: String) -> Color:
	match tier:
		"gold":
			return GOLD
		"silver":
			return SILVER
	return BRONZE


## Dessine un insigne (liste de primitives dans un carré [-1, 1]) centré en c, de demi-côté « half ».
static func draw_insignia(ci: CanvasItem, shape: Array, c: Vector2, half: float, col: Color, w: float = 2.0) -> void:
	for pr in shape:
		match str(pr["t"]):
			"poly":
				var pts := PackedVector2Array()
				for p in pr["p"]:
					pts.append(c + Vector2(float(p[0]), float(p[1])) * half)
				if bool(pr.get("fill", false)):
					ci.draw_colored_polygon(pts, col)
				else:
					pts.append(pts[0])
					ci.draw_polyline(pts, col, w)
			"line":
				var lp := PackedVector2Array()
				for p in pr["p"]:
					lp.append(c + Vector2(float(p[0]), float(p[1])) * half)
				ci.draw_polyline(lp, col, w)
			"circle":
				var cc := c + Vector2(float(pr["c"][0]), float(pr["c"][1])) * half
				var r := float(pr["r"]) * half
				if bool(pr.get("fill", false)):
					ci.draw_circle(cc, r, col)
				else:
					ci.draw_arc(cc, r, 0.0, TAU, 40, col, w, true)
			"arc":
				var ac := c + Vector2(float(pr["c"][0]), float(pr["c"][1])) * half
				ci.draw_arc(ac, float(pr["r"]) * half, deg_to_rad(float(pr["a0"])), deg_to_rad(float(pr["a1"])), 28, col, w, true)


## Insigne de grade ou de cosmétique.
class InsigniaIcon extends Control:
	var shape: Array = []
	var px := 48.0
	var col := Color(0.93, 0.98, 1.0, 0.95)
	var ring := true

	func setup(p_shape: Array, p_px: float = 48.0, p_col: Color = Color(0.93, 0.98, 1.0, 0.95), p_ring: bool = true) -> void:
		shape = p_shape
		px = p_px
		col = p_col
		ring = p_ring
		custom_minimum_size = Vector2(px, px)
		queue_redraw()

	func _draw() -> void:
		var c := Vector2(px * 0.5, px * 0.5)
		if ring:
			draw_arc(c, px * 0.5 - 1.5, 0.0, TAU, 48, Color(col.r, col.g, col.b, col.a * 0.55), 1.5, true)
		var UK = load("res://scripts/ui/ui_kit.gd")
		UK.draw_insignia(self, shape, c, px * 0.5 * 0.62 if ring else px * 0.5 * 0.9, col, maxf(px / 24.0, 1.4))


## Médaille : anneau et étoile de la couleur du palier (terne si elle n'est pas obtenue).
class MedalIcon extends Control:
	var tier := "bronze"
	var got := false
	var px := 38.0

	func setup(p_tier: String, p_got: bool, p_px: float = 38.0) -> void:
		tier = p_tier
		got = p_got
		px = p_px
		custom_minimum_size = Vector2(px, px)
		queue_redraw()

	func _draw() -> void:
		var UK = load("res://scripts/ui/ui_kit.gd")
		var col: Color = UK.tier_color(tier)
		if not got:
			col = Color(0.93, 0.98, 1.0, 0.3)
		var c := Vector2(px * 0.5, px * 0.5)
		if got:
			draw_circle(c, px * 0.42, Color(col.r, col.g, col.b, 0.18))
		draw_arc(c, px * 0.42, 0.0, TAU, 40, col, 2.0, true)
		draw_arc(c, px * 0.32, 0.0, TAU, 36, Color(col.r, col.g, col.b, col.a * 0.5), 1.0, true)
		var pts := PackedVector2Array()
		for k in 10:
			var a := -PI * 0.5 + k * PI / 5.0
			var r := px * 0.22 if k % 2 == 0 else px * 0.09
			pts.append(c + Vector2(cos(a), sin(a)) * r)
		if got:
			draw_colored_polygon(pts, col)
		else:
			pts.append(pts[0])
			draw_polyline(pts, col, 1.2)


## Barre d'XP : partie acquise, partie gagnée pendant la mission (or), textes gauche et droite.
class XpBar extends Control:
	var before := 0.0
	var after := 0.0
	var left_text := ""
	var right_text := ""
	var w := 360.0

	func setup(p_w: float, p_before: float, p_after: float, p_left: String, p_right: String) -> void:
		w = p_w
		before = clampf(p_before, 0.0, 1.0)
		after = clampf(p_after, 0.0, 1.0)
		left_text = p_left
		right_text = p_right
		custom_minimum_size = Vector2(w, 34)
		queue_redraw()

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var dim := Color(0.93, 0.98, 1.0, 0.62)
		var main := Color(0.93, 0.98, 1.0, 0.95)
		var y := 18.0
		draw_string(font, Vector2(0, 13), left_text, HORIZONTAL_ALIGNMENT_LEFT, w * 0.6, 13, dim)
		draw_string(font, Vector2(0, 13), right_text, HORIZONTAL_ALIGNMENT_RIGHT, w, 13, dim)
		draw_rect(Rect2(0, y, w, 10), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(0, y, w * before, 10), main)
		if after > before:
			draw_rect(Rect2(w * before, y, w * (after - before), 10), Color(1.0, 0.82, 0.4, 1.0))
		draw_rect(Rect2(0, y, w, 10), Color(0.93, 0.98, 1.0, 0.45), false, 1.0)


## Niveaux d'une amélioration : une pastille par niveau.
class Pips extends Control:
	var level := 0
	var total := 3

	func setup(p_level: int, p_total: int) -> void:
		level = p_level
		total = p_total
		custom_minimum_size = Vector2(total * 20.0, 22)
		queue_redraw()

	func _draw() -> void:
		for i in total:
			var c := Vector2(10.0 + i * 20.0, 11.0)
			if i < level:
				draw_circle(c, 6.0, Color(1.0, 0.82, 0.4, 1.0))
			draw_arc(c, 6.0, 0.0, TAU, 20, Color(1.0, 0.82, 0.4, 1.0) if i < level else Color(0.93, 0.98, 1.0, 0.5), 1.4, true)


## Aperçu d'un réticule : cercle, centre et quatre traits.
class ReticlePreview extends Control:
	var width := 1.0
	var ring := "solid"
	var center := "dot"
	var col := Color(0.93, 0.98, 1.0, 0.95)

	func setup(p: Dictionary, p_col: Color = Color(0.93, 0.98, 1.0, 0.95)) -> void:
		width = float(p.get("width", 1.0))
		ring = str(p.get("ring", "solid"))
		center = str(p.get("center", "dot"))
		col = p_col
		custom_minimum_size = Vector2(56, 56)
		queue_redraw()

	func _draw() -> void:
		var c := Vector2(28, 28)
		var wd := 1.5 * width
		if ring == "dotted":
			for i in 24:
				if i % 2 == 0:
					draw_arc(c, 17.0, TAU * i / 24.0, TAU * (i + 0.9) / 24.0, 3, col, wd, true)
		else:
			draw_arc(c, 17.0, 0.0, TAU, 40, col, wd, true)
		for d in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
			draw_line(c + d * 21.0, c + d * 27.0, col, wd)
		match center:
			"dot":
				draw_circle(c, 2.0, col)
			"cross":
				draw_line(c - Vector2(7, 0), c + Vector2(7, 0), col, wd)
				draw_line(c - Vector2(0, 7), c + Vector2(0, 7), col, wd)
			"open":
				draw_arc(c, 3.2, 0.0, TAU, 14, col, wd, true)
			"chevron":
				draw_polyline(PackedVector2Array([c + Vector2(-6, 4), c + Vector2(0, -3), c + Vector2(6, 4)]), col, wd)


## Aperçu d'une voix radio : trois ondes.
class VoicePreview extends Control:
	var pitch := 1.0
	var dirty := false
	var col := Color(0.93, 0.98, 1.0, 0.95)

	func setup(p: Dictionary, p_col: Color = Color(0.93, 0.98, 1.0, 0.95)) -> void:
		pitch = float(p.get("pitch", 1.0))
		dirty = float(p.get("drive", 0.0)) > 0.1
		col = p_col
		custom_minimum_size = Vector2(56, 56)
		queue_redraw()

	func _draw() -> void:
		var c := Vector2(14, 28)
		draw_circle(c, 3.0, col)
		for i in 3:
			var r := 9.0 + i * 8.0
			draw_arc(c, r, -0.9, 0.9, 10, col, 1.6, true)
		if dirty:
			for i in 5:
				draw_line(Vector2(34 + i * 4, 18 + (i % 2) * 6), Vector2(34 + i * 4, 38 - (i % 3) * 3), col, 1.2)
		if pitch < 0.97:
			draw_string(ThemeDB.fallback_font, Vector2(26, 52), "GRAVE", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, col)
		elif pitch > 1.03:
			draw_string(ThemeDB.fallback_font, Vector2(26, 52), "AIGU", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, col)


static func box(bg: Color, border: Color, w: int = 1, mx: float = 14.0, my: float = 8.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(w)
	s.content_margin_left = mx
	s.content_margin_right = mx
	s.content_margin_top = my
	s.content_margin_bottom = my
	return s


static func make_theme() -> Theme:
	var th := Theme.new()
	th.set_color("font_color", "Label", MAIN)
	th.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.85))
	th.set_constant("outline_size", "Label", 3)
	th.set_font_size("font_size", "Label", 16)
	th.set_stylebox("panel", "PanelContainer", box(BG, LINE, 1, 26.0, 20.0))
	th.set_stylebox("normal", "Button", box(Color(0, 0, 0, 0.55), LINE))
	th.set_stylebox("hover", "Button", box(Color(0.93, 0.98, 1.0, 0.14), MAIN))
	th.set_stylebox("pressed", "Button", box(Color(0.93, 0.98, 1.0, 0.30), MAIN, 2))
	th.set_stylebox("focus", "Button", box(Color(0.93, 0.98, 1.0, 0.10), MAIN, 2))
	th.set_stylebox("disabled", "Button", box(Color(0, 0, 0, 0.35), Color(1, 1, 1, 0.15)))
	th.set_color("font_color", "Button", MAIN)
	th.set_color("font_hover_color", "Button", Color(1, 1, 1, 1))
	th.set_color("font_pressed_color", "Button", Color(1, 1, 1, 1))
	th.set_color("font_focus_color", "Button", Color(1, 1, 1, 1))
	th.set_color("font_disabled_color", "Button", Color(0.93, 0.98, 1.0, 0.35))
	th.set_font_size("font_size", "Button", 18)
	return th


static func label(text: String, size: int = 16, col: Color = MAIN, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = align
	return l


static func hline() -> ColorRect:
	var r := ColorRect.new()
	r.color = LINE
	r.custom_minimum_size = Vector2(0, 1)
	return r


static func spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


## Ligne « libellé ....... valeur ».
static func row(left: String, right: String, lcol: Color = MAIN, rcol: Color = MAIN, size: int = 16) -> HBoxContainer:
	var h := HBoxContainer.new()
	var a := label(left, size, lcol)
	a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(a)
	h.add_child(label(right, size, rcol, HORIZONTAL_ALIGNMENT_RIGHT))
	return h


static func button(text: String, cb: Callable, min_w: float = 200.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 44)
	b.pressed.connect(cb)
	return b


static func thousands(n: int) -> String:
	var neg := n < 0
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = " " + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if neg else "") + s + out


const MONTHS := ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"]


## « 2026-11-23 » -> « 23 novembre 2026 » (ou « 23 nov. » si short).
static func date_fr(date: String, short: bool = false) -> String:
	var p := date.split("-")
	if p.size() != 3 or not p[1].is_valid_int() or not p[2].is_valid_int():
		return date
	var mo: String = MONTHS[clampi(int(p[1]) - 1, 0, 11)]
	if short:
		return "%d %s" % [int(p[2]), mo if mo.length() <= 4 else mo.substr(0, 3) + "."]
	return "%d%s %s %s" % [int(p[2]), "er" if int(p[2]) == 1 else "", mo, p[0]]


## Durée en « 12 min 05 » (ou « 45 s » en dessous d'une minute).
static func duration_fr(secs: int) -> String:
	if secs < 60:
		return "%d s" % secs
	return "%d min %02d" % [secs / 60, secs % 60]


static func rating_color(r: String) -> Color:
	match r:
		"S":
			return GOLD
		"A":
			return GOOD
		"B":
			return MAIN
		"C":
			return DIM
	return WARN
