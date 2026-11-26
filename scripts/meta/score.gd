extends RefCounted
## Score de la partie : points, série (multiplicateur), statistiques, étoiles et note de fin de mission.
## Le barème est dans data/scoring.json ; les paliers de note et les étoiles sont dans le fichier de mission.

const RATINGS := ["D", "C", "B", "A", "S"]

var ctx
var cfg: Dictionary = {}
var points := 0
var chain := 0
var mult := 1
var feed: Array = []          # [[texte, genre, date]] : derniers gains, pour l'affichage
var st: Dictionary = {}       # statistiques (médailles, débriefing)
var threatened := {}          # immeubles attaqués au cours de la partie (clé = indice)
var cur_w := -1               # arme de l'obus en cours de résolution
var cur_range := 0.0          # distance de tir de cet obus
var result: Dictionary = {}   # rempli par finish()
var _shell_kills := 0
var _acc := 0.0


func setup(p_ctx, p_cfg: Dictionary) -> void:
	ctx = p_ctx
	cfg = p_cfg
	reset()


func reset() -> void:
	points = 0
	chain = 0
	mult = 1
	feed.clear()
	threatened.clear()
	result = {}
	cur_w = -1
	_shell_kills = 0
	_acc = 0.0
	var nw: int = maxi(ctx.weapons.size(), 3)
	st = {
		"kills": 0, "kills_inside": 0, "kills_w": _zeros(nw), "shots_w": _zeros(nw),
		"shells_hit": 0, "shells": 0, "shells_w": _zeros(nw), "hits_w": _zeros(nw), "max_kills_shell": 0, "max_kill_range": 0.0,
		"chain_best": 0, "chain_breaks": 0, "saved": 0, "eaten": 0, "collateral": 0, "contained": 0,
		"runners": 0, "objectives": 0, "obj_points": 0, "supports": 0, "held": 0, "protected": 0,
		"hit_streak": 0, "hit_streak_best": 0, "clean_chain": 0, "clean_best": 0,
		"specials": 0, "kills_colossus": 0, "kills_screamer": 0, "kills_alpha": 0, "waves": 0, "support_kills": 0,
		"decoy_pulled": 0, "drone_seen": 0,
	}


func _zeros(n: int) -> Array:
	var a: Array = []
	a.resize(n)
	a.fill(0)
	return a


func _pts(key: String) -> int:
	return int(cfg.get("points", {}).get(key, 0))


func tier_of(c: int) -> int:
	var m := 1
	for t in cfg.get("chain_tiers", [[0, 1]]):
		if c >= int(t[0]):
			m = int(t[1])
	return m


## Série à atteindre pour le multiplicateur suivant (-1 s'il est au maximum).
func next_tier_at() -> int:
	for t in cfg.get("chain_tiers", [[0, 1]]):
		if int(t[1]) > mult:
			return int(t[0])
	return -1


func _log(text: String, kind: String) -> void:
	feed.append([text, kind, ctx.time])
	if feed.size() > 6:
		feed.pop_front()


# ---------------------------------------------------------------- événements

## Un infecté vient d'être tué (inside : sous les décombres d'un immeuble rasé ; base_pts > 0 : infecté spécial de type ztype).
func on_zombie_killed(runner: bool, inside: bool = false, base_pts: int = 0, ztype: int = 0) -> void:
	var base := base_pts if base_pts > 0 else (_pts("inside_building") if inside else (_pts("runner") if runner else _pts("zombie")))
	chain += 1
	mult = tier_of(chain)
	var gain := base * mult
	points += gain
	st["kills"] += 1
	if inside:
		st["kills_inside"] += 1
	if runner:
		st["runners"] += 1
	st["chain_best"] = maxi(st["chain_best"], chain)
	st["clean_chain"] += 1       # série « sans bavure » : jamais réduite par l'instructeur de tir
	st["clean_best"] = maxi(st["clean_best"], st["clean_chain"])
	if cur_w >= 0:
		st["kills_w"][cur_w] += 1
		_shell_kills += 1
		if not inside:
			st["max_kill_range"] = maxf(st["max_kill_range"], cur_range)
	var tag := ""
	if ztype > 0:
		var zid: String = ctx.crowd.ZT_IDS[ztype]
		st["specials"] += 1
		st["kills_" + zid] = int(st.get("kills_" + zid, 0)) + 1
		tag = "  " + str(ctx.zombie_types.get(zid, {}).get("short", zid))
	_log("+%d" % gain + ("  ×%d" % mult if mult > 1 else "") + tag, "kill")


## Un appui (barrage, drone, leurre, largage) vient d'être demandé.
func on_support(id: String) -> void:
	st["supports"] = int(st["supports"]) + 1
	_log("APPUI  %s" % (ctx.supports.short_name(id) if ctx.supports != null else id.to_upper()), "info")


## Nuit blanche : la vague n est tenue (prime croissante).
func on_wave(n: int, pts: int) -> void:
	st["waves"] = maxi(int(st["waves"]), n)
	points += pts
	_log("VAGUE %d TENUE  +%d" % [n, pts], "good")


func on_collateral(n: int) -> void:
	if n <= 0:
		return
	points += n * _pts("civ_collateral")
	st["collateral"] += n
	var before := chain
	if chain > 0:
		st["chain_breaks"] += 1
	st["clean_chain"] = 0
	# l'instructeur de tir sauve une partie de la série
	chain = int(floor(float(chain) * clampf(ctx.mod("chain_keep"), 0.0, 0.9)))
	mult = tier_of(chain)
	if before >= 5:
		_log("SÉRIE ROMPUE (%d)" % before if chain == 0 else "SÉRIE RÉDUITE (%d > %d)" % [before, chain], "bad")
	_log("%d  civil%s touché%s" % [n * _pts("civ_collateral"), "s" if n > 1 else "", "s" if n > 1 else ""], "bad")


func on_eaten(n: int) -> void:
	points += n * _pts("civ_eaten")
	st["eaten"] += n


## Civils ensevelis sous un immeuble déjà perdu, rasé sur le conseil du jeu : le prix d'un civil dévoré, sans bavure ni série rompue.
func on_contained(n: int) -> void:
	if n <= 0:
		return
	points += n * _pts("civ_eaten")
	st["contained"] += n
	_log("%d  immeuble perdu rasé (%d civil%s)" % [n * _pts("civ_eaten"), n, "s" if n > 1 else ""], "info")


func on_saved(n: int) -> void:
	var gain := n * _pts("civ_saved")
	points += gain
	st["saved"] += n
	_log("+%d  civil sauvé" % gain if n == 1 else "+%d  civils sauvés" % gain, "good")


func add_bonus(label: String, pts: int) -> void:
	points += pts
	_log("+%d  %s" % [pts, label], "good")


## Récompense d'un objectif accompli (comptée à part dans le débriefing).
func add_objective(label: String, pts: int) -> void:
	points += pts
	st["objectives"] += 1
	st["obj_points"] += pts
	_log("+%d  %s" % [pts, label], "good")


func on_shot(w: int) -> void:
	st["shots_w"][w] += 1


## Appelé par Arms autour de la résolution d'un obus : begin_shell avant les dégâts, end_shell après.
func begin_shell(w: int, range_m: float) -> void:
	cur_w = w
	cur_range = range_m
	_shell_kills = 0


func end_shell(hit_zombies: int) -> void:
	st["shells"] += 1
	if cur_w >= 0:
		st["shells_w"][cur_w] += 1
	var hit: bool = hit_zombies > 0 or _shell_kills > 0
	if hit:
		st["shells_hit"] += 1
		if cur_w >= 0:
			st["hits_w"][cur_w] += 1
	if cur_w >= 1:                                   # série d'obus lourds au but
		st["hit_streak"] = st["hit_streak"] + 1 if hit else 0
		st["hit_streak_best"] = maxi(st["hit_streak_best"], st["hit_streak"])
	st["max_kills_shell"] = maxi(st["max_kills_shell"], _shell_kills)
	cur_w = -1
	_shell_kills = 0


func step(dt: float) -> void:
	_acc += dt
	if _acc < 1.0:
		return
	_acc -= 1.0
	for b in ctx.buildings.threatened_list():
		threatened[b] = true


# ---------------------------------------------------------------- bilan

## Part des obus lourds (40 mm et 105 mm) qui ont touché au moins un infecté ; -1 si aucun n'a été tiré.
## Le 25 mm tire 30 coups par seconde en rafale : son taux de touche n'a pas de sens.
func accuracy() -> float:
	var n: int = 0
	var h: int = 0
	for w in range(1, st["shells_w"].size()):
		n += int(st["shells_w"][w])
		h += int(st["hits_w"][w])
	return -1.0 if n == 0 else float(h) / float(n)


func rating_for(total: int) -> String:
	var targets: Array = ctx.mission.get("score_targets", [2500, 4500, 7000, 10500])
	var r := "D"
	for i in targets.size():
		if total >= int(targets[i]):
			r = RATINGS[i + 1]
	return r


## Points manquants pour la note suivante (0 si S).
func rating_gap(total: int) -> Array:
	var targets: Array = ctx.mission.get("score_targets", [2500, 4500, 7000, 10500])
	for i in targets.size():
		if total < int(targets[i]):
			return [RATINGS[i + 1], int(targets[i]) - total]
	return ["", 0]


func _star(def: Dictionary, won: bool, total: int) -> Dictionary:
	var d = ctx.director
	var ok := false
	var gap := ""
	var v: float = float(def.get("value", 0))
	match str(def.get("type", "")):
		"win":
			ok = won
			gap = "Il fallait tenir le secteur."
		"lost_max":
			ok = won and d.lost <= int(v)
			gap = "Il fallait perdre %d civil%s de moins." % [d.lost - int(v), "s" if d.lost - int(v) > 1 else ""]
		"collateral_max":
			ok = won and d.collateral <= int(v)
			gap = "Il fallait %d victime%s collatérale%s de moins." % [d.collateral - int(v), "s" if d.collateral - int(v) > 1 else "", "s" if d.collateral - int(v) > 1 else ""]
		"destroyed_max":
			ok = won and d.destroyed <= int(v)
			gap = "Il fallait raser %d immeuble%s de moins." % [d.destroyed - int(v), "s" if d.destroyed - int(v) > 1 else ""]
		"kills_min":
			ok = won and d.kills >= int(v)
			gap = "Il manquait %d infecté%s neutralisé%s." % [int(v) - d.kills, "s" if int(v) - d.kills > 1 else "", "s" if int(v) - d.kills > 1 else ""]
		"saved_min":
			ok = won and d.saved >= int(v)
			gap = "Il manquait %d civil%s sauvé%s." % [int(v) - d.saved, "s" if int(v) - d.saved > 1 else "", "s" if int(v) - d.saved > 1 else ""]
		"score_min":
			ok = won and total >= int(v)
			gap = "Il manquait %d points." % maxi(int(v) - total, 0)
		"rating_min":
			var need: String = str(def.get("value", "A"))
			ok = won and RATINGS.find(rating_for(total)) >= RATINGS.find(need)
			var targets: Array = ctx.mission.get("score_targets", [])
			var idx: int = RATINGS.find(need) - 1
			gap = "Il manquait %d points pour la note %s." % [maxi(int(targets[idx]) - total, 0), need] if idx >= 0 and idx < targets.size() else ""
		"objective":
			ok = ctx.objectives != null and ctx.objectives.is_done(str(def.get("id", "")))
			gap = "Objectif non réussi."
		"objectives_min":
			var done: int = ctx.objectives.count_done("secondary") if ctx.objectives != null else 0
			ok = won and done >= int(v)
			gap = "Il manquait %d objectif%s secondaire%s." % [int(v) - done, "s" if int(v) - done > 1 else "", "s" if int(v) - done > 1 else ""]
	return {"text": str(def.get("text", "")), "ok": ok, "gap": "" if ok else gap}


## Bilan de fin de mission : bonus, total, note, étoiles. À appeler une seule fois, quand le directeur conclut.
func finish(won: bool) -> Dictionary:
	if not result.is_empty():
		return result
	var d = ctx.director
	var bonuses: Array = []
	var prot := 0
	for b in threatened.keys():
		if ctx.buildings.status[b] == ctx.buildings.ST_OK:
			prot += ctx.buildings.occ[b]
			st["held"] += 1
	prot += ctx.crowd.n_civils
	st["protected"] = prot
	if won and not d.endless:
		if prot > 0:
			bonuses.append(["Civils protégés (%d)" % prot, prot * _pts("protected_civ")])
		var margin: int = d.max_lost - d.lost
		if margin > 0:
			bonuses.append(["Marge sur le seuil de pertes (%d)" % margin, margin * _pts("lost_margin")])
		if d.time_left() > 1.0:
			bonuses.append(["Secteur sécurisé avant l'aube (%d s)" % int(d.time_left()), int(d.time_left()) * _pts("time_left_per_s")])
	var obj_pts: int = int(st["obj_points"])
	var sub := points - obj_pts
	if obj_pts > 0:
		bonuses.push_front(["Objectifs accomplis (%d)" % int(st["objectives"]), obj_pts])
	var total := sub
	for b in bonuses:
		total += int(b[1])
	total = maxi(total, 0)    # le score final ne descend jamais sous zéro
	var rated: bool = won or d.endless          # Nuit blanche : la patrouille est toujours notée, même si le secteur tombe
	var rating := rating_for(total) if rated else "—"
	var gap: Array = rating_gap(total) if rated else ["", 0]
	var stars: Array = []
	var n_stars := 0
	if ctx.mode == "campaign":                  # les étoiles sont celles de la campagne : le défi du jour et la Nuit blanche n'en ont pas
		for def in ctx.mission.get("stars", []):
			var s := _star(def, won, total)
			stars.append(s)
			if s["ok"]:
				n_stars += 1
	result = {
		"won": won, "reason": d.end_reason, "subtotal": sub, "bonuses": bonuses, "total": total,
		"rating": rating, "rating_next": gap[0], "rating_missing": gap[1],
		"stars": stars, "n_stars": n_stars if won else 0,
		"accuracy": accuracy(), "stats": st.duplicate(true),
		"lost": d.lost, "max_lost": d.max_lost, "eaten": d.eaten, "collateral": d.collateral,
		"lost_by": d.lost_by.duplicate(), "dead_by": d.dead_by.duplicate(),     # causes des pertes (voir Director.CAUSES), pour le bilan
		"contained": d.contained,                                               # dont ensevelis sous un immeuble perdu, rasé à raison
		"collateral_weight": d.collateral_weight if d.collateral_counts else 0.0,
		"saved": d.saved, "kills": d.kills, "destroyed": d.destroyed, "time": d.t,
		"mode": ctx.mode, "mutators": ctx.mutators.duplicate(), "waves": d.wave_n,
		"objectives": ctx.objectives.summary() if ctx.objectives != null else {"secondary": [], "hidden": [], "done": 0, "points": 0},
	}
	return result
