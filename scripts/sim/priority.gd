extends RefCounted
## Priorité du moment : LA chose à faire maintenant. Un seul calcul, lu par l'écran (bandeau URGENT, flèche, immeuble en rouge), par le
## viseur assisté de la Recrue (scripts/core/assist.gd) et par les essais. Rien ici ne tire ni ne déplace quoi que ce soit.
##
## Ordre des urgences (niveau, du plus haut au plus bas) :
##   5  "raze"      immeuble perdu (BuildingSystem.advice == "raze") avec des habitants : le raser au 105 mm
##   4  "street"    un infecté à moins de 9 m de civils en fuite : l'abattre avant qu'il les rattrape
##   3  "door"      porte attaquée à 55 % ou plus, ou déjà forcée : abattre les infectés devant la porte
##   3  "special"   colosse, hurleur ou alpha en vie
##   2  "street"    infecté à moins de 16 m de civils
##   2  "door"      porte attaquée à moins de 55 %
##   2  "defend"    infectés dans un immeuble qui n'est pas perdu : tenir la rue, ne pas raser
##   1  "objective" zone d'un objectif de mission en cours
##   0  "none"      rien d'urgent
## À niveau égal, le plus proche de la visée gagne ; la priorité en place garde sa place (hystérésis) et les plus basses ne la remplacent
## pas avant HOLD_S secondes : le bandeau et le viseur ne sautent pas d'une cible à l'autre.

const PERIOD := 0.25            # recalcul au plus tous les 0,25 s de jeu (le résultat est mis en cache)
const HOLD_S := 3.0             # une priorité reste au moins 3 s si aucune plus urgente n'apparaît
const STICKY_M := 400.0         # bonus de distance (m) du candidat déjà en place
const DOOR_URGENT := 0.55       # part de la porte attaquée à partir de laquelle on parle d'urgence
const STREET_NEAR_M := 16.0     # infecté « près » de civils
const STREET_NOW_M := 9.0       # infecté « sur » des civils

const NONE := {"kind": "none", "key": "", "level": 0, "pos": Vector2.ZERO, "b": -1, "h": 0.0, "radius": 0.0, "weapon": -1,
		"pull": 0.0, "title": "", "hint": ""}

var ctx
var cur: Dictionary = NONE
var changes := 0                # nombre de changements de cible depuis le début (essais)
var _next_t := -1.0
var _since := -99.0


func setup(p_ctx) -> void:
	ctx = p_ctx
	reset()


func reset() -> void:
	cur = NONE
	changes = 0
	_next_t = -1.0
	_since = -99.0


## La priorité en cours (recalculée si la dernière date de plus de PERIOD secondes de jeu).
func get_cur() -> Dictionary:
	if ctx != null and ctx.time >= _next_t:
		refresh()
	return cur


## Recalcule maintenant.
func refresh() -> void:
	_next_t = ctx.time + PERIOD
	if ctx.director == null or ctx.director.state != "running" or ctx.buildings == null or ctx.city == null or ctx.gunship == null:
		cur = NONE
		return
	var cands: Array = candidates()
	var aim: Vector2 = ctx.gunship.aim
	var cur_key: String = str(cur.get("key", ""))
	var cur_alive := false
	for c in cands:
		if c["key"] == cur_key:
			cur_alive = true
			break
	var held: bool = cur_alive and ctx.time - _since < HOLD_S
	var best: Dictionary = {}
	var best_rank := -INF
	for c in cands:
		var rank := float(c["level"]) * 10000.0 - minf(aim.distance_to(c["pos"]), 9000.0)
		if c["key"] == cur_key:
			rank += STICKY_M
		elif held and int(c["level"]) <= int(cur["level"]):
			continue
		if rank > best_rank:
			best_rank = rank
			best = c
	if best.is_empty():
		if cur_key != "":
			changes += 1
		cur = NONE
		return
	if best["key"] != cur_key:
		_since = ctx.time
		changes += 1
	cur = best


## Tous les candidats du moment (sans choix). Chacun : kind, key, level, pos (m), b, h (hauteur visée au-dessus du sol), radius (zone, m),
## weapon (0 : 25 mm, 1 : 40 mm, 2 : 105 mm, -1 : au choix), pull (force de l'attraction du viseur, 0 à 1), title, hint.
func candidates() -> Array:
	var out: Array = []
	var bs = ctx.buildings
	var city = ctx.city
	for b in bs.threatened_list():
		var adv: String = bs.advice(b)
		var occ: int = bs.occ[b]
		var cp := Vector2(city.b_cx[b], city.b_cz[b])
		match adv:
			"raze":
				var inf: int = bs.zin[b]
				out.append(_mk("raze", "raze:%d" % b, 5, cp, b, city.b_h[b] * 0.85, clampf(0.35 * maxf(city.b_w[b], city.b_d[b]), 10.0, 30.0), 2, 1.0,
						"RASEZ L'IMMEUBLE", "PERDU · %d INFECTÉ%s DEDANS · %d HAB." % [inf, "S" if inf > 1 else "", occ]))
			"siege", "open":
				var f: float = clampf(bs.siege[b] / maxf(bs.door_hp[b], 1.0), 0.0, 1.0)
				var forced: bool = adv == "open"
				if not forced and f < 0.12:
					continue                                # la porte vient d'être touchée : pas encore une urgence
				var urgent: bool = forced or f >= DOOR_URGENT
				out.append(_mk("door", "door:%d" % b, 3 if urgent else 2, door_pos(b), b, 0.0, 22.0, 0, 1.0,
						"PORTE FORCÉE" if forced else "DÉFENDEZ LA PORTE",
						"ABATTEZ LES INFECTÉS À L'ENTRÉE · %d HAB." % occ if forced else "PORTE ATTAQUÉE %d %% · %d HAB." % [int(round(100.0 * f)), occ]))
			"defend":
				out.append(_mk("defend", "defend:%d" % b, 2, door_pos(b), b, 0.0, 26.0, 0, 0.8,
						"IMMEUBLE INFESTÉ", "NE RASEZ PAS · TENEZ LA RUE · %d HAB." % occ))
	var st: Dictionary = ctx.crowd.street_threat()
	if not st.is_empty():
		var near: bool = float(st["dist"]) <= STREET_NOW_M
		var n: int = int(st["civ"])
		out.append(_mk("street", "street", 4 if near else 2, st["pos"], -1, 0.0, 24.0, 0, 1.0 if near else 0.7,
				"TIREZ SUR LES INFECTÉS", "%d CIVIL%s POURSUIVI%s" % [n, "S" if n > 1 else "", "S" if n > 1 else ""]))
	var sp: Dictionary = _nearest_special()
	if not sp.is_empty():
		out.append(sp)
	if ctx.objectives != null:
		for m in ctx.objectives.markers():
			var tp := str(m["type"])
			var title := "OBJECTIF"
			var w := -1
			match tp:
				"hold":
					title = "DÉFENDEZ L'IMMEUBLE"
					w = 0
				"evac":
					title = "COUVREZ L'ÉVACUATION"
					w = 0
				"intercept":
					title = "INTERCEPTEZ LE GROUPE"
					w = 1
			var bi: int = int(m["b"])
			out.append(_mk("objective", "obj:%s" % str(m["title"]), 1, m["pos"], bi, 0.0, maxf(float(m["radius"]) * 0.5, 30.0), w, 0.5,
					title, str(m["title"]).to_upper()))
	return out


func _mk(kind: String, key: String, level: int, pos: Vector2, b: int, h: float, radius: float, weapon: int, pull: float, title: String, hint: String) -> Dictionary:
	return {"kind": kind, "key": key, "level": level, "pos": pos, "b": b, "h": h, "radius": radius, "weapon": weapon, "pull": pull,
			"title": title, "hint": hint}


## Porte de l'immeuble : le point de la rue où les infectés la martèlent et d'où ils sortent.
func door_pos(b: int) -> Vector2:
	var city = ctx.city
	if ctx.graph != null and b < city.b_door_edge.size():
		return ctx.graph.pos_on_edge(city.b_door_edge[b], city.b_door_t[b], city.b_door_off[b])
	return Vector2(city.b_cx[b], city.b_cz[b])


## Infecté spécial vivant le plus proche de la visée (colosse : 105 mm, hurleur : 25 mm, alpha et sa meute : 40 mm).
func _nearest_special() -> Dictionary:
	var cr = ctx.crowd
	var aim: Vector2 = ctx.gunship.aim
	var best = null
	var bd := INF
	for i in cr.MAX_P:
		var z = cr.pool[i]
		if not z.alive or z.kind != cr.K_ZOMBIE or z.ztype <= 0 or z.rising:
			continue
		var d: float = aim.distance_squared_to(z.pos)
		if d < bd:
			bd = d
			best = z
	if best == null:
		return {}
	var title := "ABATTEZ L'INFECTÉ SPÉCIAL"
	var hint := ""
	var w := -1
	match int(best.ztype):
		cr.ZT_COLOSSUS:
			title = "ABATTEZ LE COLOSSE"
			hint = "BLINDÉ : IL FAUT LE 105 MM"
			w = 2
		cr.ZT_SCREAMER:
			title = "ABATTEZ LE HURLEUR"
			hint = "SES HURLEMENTS ACCÉLÈRENT LES INFECTÉS"
			w = 0
		cr.ZT_ALPHA:
			title = "ABATTEZ L'ALPHA"
			hint = "IL CONDUIT UNE MEUTE"
			w = 1
	return _mk("special", "special:%d" % best.id, 3, best.pos, -1, 0.0, 20.0, w, 0.8, title, hint)


## Point du sol à viser pour que la ligne de visée passe par la cible (le toit d'un immeuble haut se projette au-delà de son pied).
func aim_point(c: Dictionary = {}) -> Vector2:
	if c.is_empty():
		c = cur
	var p: Vector2 = c.get("pos", Vector2.ZERO)
	var h: float = float(c.get("h", 0.0))
	if h < 0.5 or ctx.gunship == null:
		return p
	var cp: Vector3 = ctx.gunship.pos
	var k: float = cp.y / maxf(cp.y - h, 1.0)
	var g := cp + (Vector3(p.x, h, p.y) - cp) * k
	return Vector2(g.x, g.z)
