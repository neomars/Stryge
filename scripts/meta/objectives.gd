extends RefCounted
## Objectifs de mission : secondaires (annoncés par la radio, avec échéance et récompense) et cachés (jamais annoncés :
## on ne les découvre qu'en les accomplissant). Ils sont décrits dans le fichier de mission, clé « objectives » :
##   {"id": "...", "kind": "secondary" | "hidden", "type": "...", "title": "...", "text": "...",
##    "t": date d'annonce (s), "duration": délai (s), "reward": {"points": n}, ...paramètres du type}
##
## Secondaires
##   hold       aucun infecté ne doit entrer dans l'immeuble marqué pendant « duration » s (assaut + renforts « reinforce »)
##   evac       sauver « count » civils en « duration » s (un immeuble est infesté : ses occupants fuient vers l'évacuation)
##   hunt       neutraliser « count » infectés en « duration » s
##   intercept  anéantir un groupe de « count » infectés avant que plus de « allow » d'entre eux n'entrent dans un immeuble
## Cachés (valeur dans « value »)
##   shell_kills  « value » éliminations d'un seul obus
##   long_shot    une élimination à plus de « value » mètres
##   chain        série de « value » éliminations sans bavure
##   clean_run    « value » secondes de suite sans victime collatérale
##   sharp        « value » obus lourds de suite qui touchent au moins un infecté
##
## Les durées sont des multiples de 10 s, les effectifs des multiples des pas des emplacements de la radio
## (data/radio_script.json : secs 10, hunt_n 5, grp_n 2, civs 1) pour que le texte lu soit exact.
##
## Tout passe par step(dt), appelé par le directeur. Aucune dépendance au rendu : les tests l'exécutent tels quels.

const SECONDARY_TYPES := ["hold", "evac", "hunt", "intercept"]
const HIDDEN_TYPES := ["shell_kills", "long_shot", "chain", "clean_run", "sharp"]
const TICK := 0.25            # cadence des vérifications (s de simulation)
const RESULT_SHOW_S := 9.0    # durée d'affichage d'un résultat dans le panneau
const TOAST_S := 4.5
const GIVE_UP_TICKS := 60     # abandon d'une annonce impossible à placer (15 s)

var ctx
var items: Array = []         # une entrée par objectif de la mission (voir setup)
var max_active := 2           # secondaires simultanés
var toasts: Array = []        # [{"text", "sub", "kind", "t"}] : bandeaux du HUD
var _next_tag := 1
var _acc := 0.0
var _col_seen := 0
var _col_t := 0.0             # date de la dernière victime collatérale


func setup(p_ctx, defs: Array) -> void:
	ctx = p_ctx
	items.clear()
	toasts.clear()
	_next_tag = 1
	_acc = 0.0
	_col_seen = 0
	_col_t = 0.0
	max_active = int(ctx.mission.get("max_active_objectives", 2))
	for d in defs:
		var kind := str(d.get("kind", "secondary"))
		items.append({
			"id": str(d["id"]), "def": d, "kind": kind, "type": str(d["type"]), "title": str(d.get("title", d["id"])),
			"state": "hidden" if kind == "hidden" else "waiting",   # waiting | active | done | failed | skipped | hidden
			"t_start": 0.0, "t_end": 0.0, "t_done": -99.0, "dur": float(d.get("duration", 0.0)),
			"pos": Vector2.ZERO, "has_pos": false, "radius": 0.0, "b": -1,
			"base": 0, "target": 0, "progress": 0.0, "detail": "", "why": "", "pts": 0,
			"tag": 0, "total": 0, "alive": 0, "entered": 0, "occ0": 0, "reinforce": [], "warn": 0, "tries": 0,
		})


# ---------------------------------------------------------------- consultation

func is_done(id: String) -> bool:
	for it in items:
		if it["id"] == id:
			return it["state"] == "done"
	return false


func count_active() -> int:
	var n := 0
	for it in items:
		if it["state"] == "active":
			n += 1
	return n


func count_done(kind: String = "") -> int:
	var n := 0
	for it in items:
		if it["state"] == "done" and (kind == "" or it["kind"] == kind):
			n += 1
	return n


func get_item(id: String) -> Dictionary:
	for it in items:
		if it["id"] == id:
			return it
	return {}


## Secondaires à afficher dans le panneau : en cours, plus ceux qui viennent de se terminer.
func panel_items() -> Array:
	var out: Array = []
	for it in items:
		if it["kind"] == "hidden":
			continue
		var st: String = it["state"]
		if st == "active" or ((st == "done" or st == "failed") and ctx.time - float(it["t_done"]) < RESULT_SHOW_S):
			out.append(it)
	return out


## Repères à dessiner (carte et vue) : [{pos, radius, type, title, left}].
func markers() -> Array:
	var out: Array = []
	for it in items:
		if it["state"] == "active" and it["has_pos"]:
			out.append({"pos": it["pos"], "radius": float(it["radius"]), "type": it["type"], "title": it["title"],
					"left": time_left(it), "b": it["b"]})
	return out


## Secondes restantes (-1 s'il n'y a pas d'échéance).
func time_left(it: Dictionary) -> float:
	if float(it["t_end"]) <= 0.0:
		return -1.0
	return maxf(float(it["t_end"]) - ctx.director.t, 0.0)


func active_toasts() -> Array:
	var out: Array = []
	for t in toasts:
		if ctx.time - float(t["t"]) < TOAST_S:
			out.append(t)
	return out


## Pour le débriefing.
func summary() -> Dictionary:
	var sec: Array = []
	var hid: Array = []
	for it in items:
		if it["kind"] == "hidden":
			hid.append({"title": it["title"], "text": str(it["def"].get("text", "")), "found": it["state"] == "done", "pts": it["pts"]})
		elif it["state"] == "done" or it["state"] == "failed":
			sec.append({"title": it["title"], "ok": it["state"] == "done", "pts": it["pts"], "why": it["why"],
					"text": str(it["def"].get("text", ""))})
	return {"secondary": sec, "hidden": hid, "done": count_done(), "points": _points()}


func _points() -> int:
	var s := 0
	for it in items:
		if it["state"] == "done":
			s += int(it["pts"])
	return s


# ---------------------------------------------------------------- pas de simulation

func step(dt: float) -> void:
	_acc += dt
	if _acc < TICK:
		return
	_acc = 0.0
	var d = ctx.director
	if d.collateral != _col_seen:
		_col_seen = d.collateral
		_col_t = d.t
	var active := count_active()
	for it in items:
		if it["state"] == "waiting" and float(it["def"].get("t", 0.0)) <= d.t and active < max_active:
			if _activate(it):
				active += 1
	for it in items:
		if it["state"] == "active":
			_update(it)
		elif it["state"] == "hidden":
			_check_hidden(it)


## Fin de mission : ce qui était en cours est abandonné sans commentaire radio.
func finish() -> void:
	for it in items:
		if it["state"] == "active":
			it["state"] = "failed"
			it["why"] = "Mission terminée."
			it["t_done"] = ctx.time


# ---------------------------------------------------------------- activation

func _activate(it: Dictionary) -> bool:
	var def: Dictionary = it["def"]
	var ok := false
	match it["type"]:
		"hold":
			ok = _start_hold(it, def)
		"evac":
			ok = _start_evac(it, def)
		"hunt":
			ok = _start_hunt(it, def)
		"intercept":
			ok = _start_intercept(it, def)
	if not ok:
		it["tries"] += 1
		if it["tries"] > GIVE_UP_TICKS:
			it["state"] = "skipped"
		return false
	var d = ctx.director
	it["state"] = "active"
	it["t_start"] = d.t
	# l'officier de renseignement rallonge les délais (par pas de 10 s : la radio prononce la durée exacte)
	it["dur"] = float(def["duration"]) + ctx.mod("obj_time_s") if def.has("duration") else 0.0
	it["t_end"] = d.t + float(it["dur"]) if def.has("duration") else 0.0
	_announce(it)
	_update(it)
	return true


func _start_hold(it: Dictionary, def: Dictionary) -> bool:
	var b: int = ctx.director.assault_building(float(def.get("radius", 400.0)), int(def.get("zombies", 4)),
			float(def.get("progress", 0.15)), int(def.get("min_occ", 5)), float(def.get("min_aim", 150.0)))
	if b < 0:
		return false
	it["b"] = b
	it["pos"] = Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
	it["has_pos"] = true
	it["radius"] = 45.0
	it["occ0"] = ctx.buildings.occ[b]
	it["reinforce"] = []
	for r in def.get("reinforce", []):
		it["reinforce"].append({"at": float(r["at"]), "zombies": int(r["zombies"]), "done": false})
	return true


func _start_evac(it: Dictionary, def: Dictionary) -> bool:
	# les civils doivent pouvoir atteindre l'évacuation dans le délai : immeuble proche d'un point d'évacuation
	# (contrainte relâchée si, après quelques essais, aucun immeuble ne la respecte)
	var max_evac: float = float(def.get("max_evac", 300.0)) if int(it["tries"]) < 8 else INF
	var b: int = ctx.director.pick_building(float(def.get("radius", 400.0)), int(def.get("min_occ", 6)), float(def.get("min_aim", 150.0)), max_evac)
	if b < 0:
		return false
	ctx.buildings.infest(b, int(def.get("zombies", 1)))
	it["b"] = b
	it["pos"] = Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
	it["has_pos"] = true
	it["radius"] = 45.0
	it["base"] = ctx.director.saved
	it["target"] = int(def["count"])
	return true


func _start_hunt(it: Dictionary, def: Dictionary) -> bool:
	it["base"] = ctx.director.kills
	it["target"] = int(def["count"])
	return true


func _start_intercept(it: Dictionary, def: Dictionary) -> bool:
	var cr = ctx.crowd
	var c: Vector2 = cr.pick_street_point(ctx.gunship.center, float(def.get("r_min", 175.0)), float(def.get("r_max", 425.0)))
	if c == Vector2.INF:
		return false
	var radius := float(def.get("radius", 110.0))
	var tag := _next_tag
	var n: int = cr.spawn_tagged_group(c, radius, int(def["count"]), tag)
	if n <= 0:
		return false
	_next_tag += 1
	it["tag"] = tag
	it["total"] = n
	it["alive"] = n
	it["entered"] = 0
	it["pos"] = cr.last_spawn
	it["has_pos"] = true
	it["radius"] = radius
	return true


func _announce(it: Dictionary) -> void:
	var def: Dictionary = it["def"]
	var params := {"secs": int(it["dur"])}
	if it["has_pos"]:
		params.merge(ctx.director.where_params(it["pos"]))
	match it["type"]:
		"hold":
			params["hold"] = int(it["dur"])
		"evac":
			params["civs"] = int(def["count"])
		"hunt":
			params["hunt_n"] = int(def["count"])
		"intercept":
			params["grp_n"] = int(it["total"])
	var fb := "Base : nouvel objectif — %s. %s" % [it["title"], str(def.get("text", ""))]
	ctx.say("obj_" + str(it["type"]), params, fb, "alert")
	_toast("NOUVEL OBJECTIF", str(it["title"]), "new")


# ---------------------------------------------------------------- suivi

func _update(it: Dictionary) -> void:
	var left: float = time_left(it)
	if left < 0.0:
		left = INF                        # pas d'échéance
	match it["type"]:
		"hold":
			_update_hold(it, left)
		"evac":
			_update_evac(it, left)
		"hunt":
			_update_hunt(it, left)
		"intercept":
			_update_intercept(it, left)
	# rappels d'échéance : une fois à 30 s, une fois à 10 s (seulement pour les objectifs assez longs)
	if it["state"] == "active" and left > 0.0 and float(it["dur"]) >= 50.0:
		if left <= 30.0 and (int(it["warn"]) & 1) == 0:
			it["warn"] = int(it["warn"]) | 1
			ctx.say("obj_time30", {}, "Nocturne 2-1 : trente secondes sur l'objectif.", "info")
		elif left <= 10.0 and (int(it["warn"]) & 2) == 0:
			it["warn"] = int(it["warn"]) | 2
			ctx.say("obj_time10", {}, "Tireur : dix secondes.", "info")


func _update_hold(it: Dictionary, left: float) -> void:
	var bs = ctx.buildings
	var b: int = it["b"]
	var d = ctx.director
	var gone: bool = bs.status[b] != bs.ST_OK
	var inside: bool = bs.zin[b] > 0 or bs.turning[b] > 0
	var dur := float(it["dur"])
	it["progress"] = clampf(1.0 - left / dur, 0.0, 1.0)
	var door := 100 if gone else int(round(100.0 * (1.0 - clampf(bs.siege[b] / maxf(bs.door_hp[b], 1.0), 0.0, 1.0))))
	it["detail"] = "Occupants %d   ·   porte %d %%" % [bs.occ[b], door]
	for r in it["reinforce"]:
		if not r["done"] and d.t - float(it["t_start"]) >= float(r["at"]):
			r["done"] = true
			if ctx.crowd.spawn_assault(b, int(r["zombies"])) > 0:
				bs.mark_active(b)
				ctx.say("obj_reinforce", {}, "Nocturne 2-1 : nouveaux infectés sur l'immeuble protégé.", "alert")
	if gone:
		_fail(it, "L'immeuble a été détruit.")
	elif inside:
		_fail(it, "Des infectés sont entrés dans l'immeuble.")
	elif left <= 0.0:
		_succeed(it)


func _update_evac(it: Dictionary, left: float) -> void:
	var bs = ctx.buildings
	var b: int = it["b"]
	var got: int = ctx.director.saved - int(it["base"])
	var need: int = int(it["target"])
	it["progress"] = clampf(float(got) / float(need), 0.0, 1.0)
	it["detail"] = "Évacués %d / %d" % [mini(got, need), need]
	if got >= need:
		_succeed(it)
	elif left <= 0.0:
		_fail(it, "Temps écoulé.")
	else:
		var still: int = ctx.crowd.n_civils + (bs.occ[b] if bs.status[b] == bs.ST_OK else 0)
		if need - got > still:
			_fail(it, "Il ne reste plus assez de civils.")


func _update_hunt(it: Dictionary, left: float) -> void:
	var got: int = ctx.director.kills - int(it["base"])
	var need: int = int(it["target"])
	it["progress"] = clampf(float(got) / float(need), 0.0, 1.0)
	it["detail"] = "Neutralisés %d / %d" % [mini(got, need), need]
	if got >= need:
		_succeed(it)
	elif left <= 0.0:
		_fail(it, "Temps écoulé.")


func _update_intercept(it: Dictionary, left: float) -> void:
	var cr = ctx.crowd
	var alive := 0
	var acc := Vector2.ZERO
	for i in cr.MAX_P:
		var p = cr.pool[i]
		if p.alive and p.kind == cr.K_ZOMBIE and p.tag == int(it["tag"]):
			alive += 1
			acc += p.pos
	it["alive"] = alive
	if alive > 0:
		it["pos"] = acc / float(alive)
	var allow := int(it["def"].get("allow", 2))
	var total: int = it["total"]
	it["progress"] = clampf(float(total - alive) / float(maxi(total, 1)), 0.0, 1.0)
	it["detail"] = "Restants %d   ·   entrés %d / %d" % [alive, it["entered"], allow]
	if it["entered"] > allow:
		_fail(it, "Le groupe a atteint les immeubles.")
	elif alive == 0:
		_succeed(it)
	elif left <= 0.0:
		_fail(it, "Temps écoulé.")


## Un infecté marqué entre dans un immeuble (appelé par la foule).
func on_entered(tag: int) -> void:
	for it in items:
		if it["state"] == "active" and int(it["tag"]) == tag:
			it["entered"] += 1


# ---------------------------------------------------------------- objectifs cachés

func _check_hidden(it: Dictionary) -> void:
	if ctx.score == null:
		return
	var st: Dictionary = ctx.score.st
	var v := float(it["def"].get("value", 0))
	var d = ctx.director
	var ok := false
	match it["type"]:
		"shell_kills":
			ok = st["max_kills_shell"] >= int(v)
		"long_shot":
			ok = st["max_kill_range"] >= v
		"chain":
			ok = st["clean_best"] >= int(v)
		"clean_run":
			ok = d.t >= v and d.t - _col_t >= v
		"sharp":
			ok = st["hit_streak_best"] >= int(v)
	if not ok:
		return
	var pts := _reward(it)
	it["state"] = "done"
	it["t_done"] = ctx.time
	it["pts"] = pts
	if ctx.score != null:
		ctx.score.add_objective(str(it["title"]), pts)
	_toast("OBJECTIF CACHÉ ACCOMPLI", str(it["title"]), "hidden", pts)
	ctx.say("obj_hidden", {}, "Base : objectif de bonus accompli — %s." % it["title"], "good")


# ---------------------------------------------------------------- résultats

func _reward(it: Dictionary) -> int:
	return int(it["def"].get("reward", {}).get("points", 0))


func _succeed(it: Dictionary) -> void:
	var pts := _reward(it)
	it["state"] = "done"
	it["t_done"] = ctx.time
	it["pts"] = pts
	it["progress"] = 1.0
	if ctx.score != null:
		ctx.score.add_objective(str(it["title"]), pts)
	_toast("OBJECTIF ACCOMPLI", str(it["title"]), "done", pts)
	ctx.say("obj_done", {}, "Base : objectif accompli — %s." % it["title"], "good")


func _fail(it: Dictionary, why: String) -> void:
	it["state"] = "failed"
	it["why"] = why
	it["t_done"] = ctx.time
	_toast("OBJECTIF PERDU", str(it["title"]), "failed")
	ctx.say("obj_failed", {}, "Base : objectif perdu — %s." % it["title"], "alert")


func _toast(text: String, sub: String, kind: String, pts: int = 0) -> void:
	toasts.append({"text": text, "sub": sub, "kind": kind, "pts": pts, "t": ctx.time})
	if toasts.size() > 6:
		toasts.pop_front()
