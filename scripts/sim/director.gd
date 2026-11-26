extends RefCounted
## Directeur de mission : vagues, compteurs, messages radio, conditions de victoire et de défaite.

const Priority := preload("res://scripts/sim/priority.gd")

var ctx
## Priorité du moment (immeuble à raser, porte, rue, infecté spécial, objectif) : voir scripts/sim/priority.gd. Calculée à la demande.
var prio = null
var t := 0.0
var duration := 420.0
var max_lost := 25
var lost := 0                 # total des civils perdus (dévorés + éventuellement dégâts collatéraux)
var saved := 0
var kills := 0
var eaten := 0
var collateral := 0            # civils tués par nos tirs (nombre réel, sert au score, aux étoiles et aux médailles)
var destroyed := 0
var state := "idle"           # idle | running | won | lost
var end_reason := ""
var waves: Array = []
var collateral_counts := true
## Part des dégâts collatéraux qui compte dans le seuil de pertes (clé « collateral_weight » de la mission, posée par la difficulté :
## 0,5 en Recrue, 1 sans réglage). Le compte est cumulé en fraction : deux civils à 0,5 font une perte.
var collateral_weight := 1.0
var _collat_acc := 0.0
## Civils ensevelis sous un immeuble déjà perdu que l'on a rasé (conseil « RASER : OUI ») : ils comptent dans le seuil de pertes, au même
## poids que les autres tirs, mais le score les prend au prix d'un civil dévoré et ils ne sont ni une bavure (`collateral`) ni une série rompue.
var contained := 0
## Pertes par cause : "inside" (dévorés dans un immeuble), "street" (dévorés dans la rue), "shot" (civils touchés par nos tirs dans la rue),
## "razed" (ensevelis sous un immeuble rasé). `lost_by` ne garde que ce qui compte dans le seuil de pertes (sa somme vaut `lost`) ;
## `dead_by` compte tous les civils morts de chaque cause, sans pondération (sa somme vaut eaten + collateral + contained).
const CAUSES := ["inside", "street", "shot", "razed"]
var lost_by := {"inside": 0, "street": 0, "shot": 0, "razed": 0}
var dead_by := {"inside": 0, "street": 0, "shot": 0, "razed": 0}
## Pertes récentes pour l'écran : [{"t": date (ctx.time), "n", "cause", "pos", "ok"}] (ok : immeuble perdu rasé à raison). Celles de même
## cause qui se suivent de près sont fusionnées.
var loss_events: Array = []
## Nuit blanche (mode sans fin) : les vagues sont engendrées à la volée d'après data/modes.json (clé « endless » de la mission).
var endless := false
var wave_n := 0               # Nuit blanche : numéro de la dernière vague lancée
var _ecfg: Dictionary = {}
var _next_wave_t := 0.0
var _base_hp := 40.0
var _base_runners := 0.2
## Une intrusion se joue dans un petit immeuble : le joueur y perd quelques civils, pas la moitié du quota. Plafond d'habitants
## d'une vague « breach » (clé « max_occ » de la vague pour en changer) et de l'immeuble infesté dès le début (clé « start_max_occ »).
const BREACH_MAX_OCC := 30
const START_BREACH_MAX_OCC := 16
var _wi := 0
var _warn50 := false
var _warn80 := false
var _last_kill_msg := -99.0
var _last_col_msg := -99.0
var _last_save_msg := -99.0
var _last_breach_msg := -99.0
var _last_loss_msg := -99.0
var _adv_t := 0.0
var _last_raze_msg := -99.0
var _last_siege_msg := -99.0


## La chose à faire maintenant (dictionnaire de Priority.cand : kind, level, pos, b, weapon, title, hint…) ; kind « none » si rien d'urgent.
func urgent() -> Dictionary:
	return prio.get_cur() if prio != null else Priority.NONE


func setup(p_ctx) -> void:
	ctx = p_ctx
	prio = Priority.new()
	prio.setup(ctx)
	var m: Dictionary = ctx.mission
	duration = float(m.get("duration_s", 420.0))
	max_lost = int(m.get("max_civilians_lost", 25))
	collateral_counts = bool(m.get("collateral_counts_as_lost", true))
	collateral_weight = clampf(float(m.get("collateral_weight", 1.0)), 0.0, 1.0)
	waves = m.get("waves", [])
	_ecfg = m.get("endless", {}) if ctx.mode == "endless" else {}
	endless = not _ecfg.is_empty()
	if endless:
		duration = INF
		max_lost = int(_ecfg.get("max_lost", 60))
		waves = []
		_next_wave_t = float(_ecfg.get("first_wave_s", 25.0))
		_base_hp = ctx.rule("zombie_hp", 40.0)
		_base_runners = ctx.rule("runner_ratio", 0.2)


func start() -> void:
	state = "running"
	var c: Vector2 = ctx.gunship.center
	var n0 := int(_ecfg.get("start_zombies", 12)) if endless else int(ctx.mission.get("start_zombies", 30))
	ctx.crowd.spawn_cluster(c, 60.0, 400.0, n0)
	var amb0: float = ctx.rule("amb_target", 0.0)
	if amb0 > 0.0:
		ctx.crowd.fill_ambient(int(amb0 * 0.75))             # les rues sont déjà peuplées de civils qui courent à l'instant zéro
	_breach(int(ctx.mission.get("start_infested_buildings", 1)), 300.0, int(ctx.mission.get("start_max_occ", START_BREACH_MAX_OCC)))
	if ctx.has_mutator("radio_down"):
		ctx.say("radio_fail", {}, "Nocturne 2-1 : panne de liaison avec la station, nous continuons sans elle.", "alert")
	elif endless:
		ctx.say("start_endless", {}, "Base à Nocturne 2-1 : nuit blanche. Les infectés arriveront sans fin, tenez le plus longtemps possible.", "base")
	else:
		ctx.say("start", {}, "Base à Nocturne 2-1 : vous êtes sur zone. Des civils sont retranchés dans les immeubles, aucune troupe au sol. Appui feu autorisé.", "base")


func step(dt: float) -> void:
	if state != "running":
		return
	t += dt
	if ctx.score != null:
		ctx.score.step(dt)
	while _wi < waves.size() and float(waves[_wi]["t"]) <= t:
		_fire_wave(waves[_wi])
		_wi += 1
	if endless and t >= _next_wave_t:
		_endless_wave()
	if ctx.objectives != null:
		ctx.objectives.step(dt)
	_advise(dt)
	if lost > max_lost:
		_end("lost", "Trop de civils perdus : le secteur est tombé.", "end_lost")
	elif t >= duration:
		_end("won", "L'aube se lève : l'évacuation du secteur est terminée.", "end_dawn")
	elif not endless and _wi >= waves.size() and t > 30.0 and ctx.crowd.n_zombies == 0 and ctx.crowd.n_eaten == 0 \
			and ctx.buildings.zombies_inside() == 0:
		_end("won", "Secteur sécurisé : plus aucun infecté détecté.", "end_clear")


func _end(result: String, reason: String, event: String) -> void:
	state = result
	end_reason = reason
	if ctx.objectives != null:
		ctx.objectives.finish()
	if ctx.score != null:
		ctx.score.finish(result == "won")
	ctx.say(event, {}, reason, "base")


func time_left() -> float:
	return maxf(duration - t, 0.0)


## Nuit blanche : le joueur met fin à la patrouille (relève de l'équipage). Le score est conservé.
func end_patrol() -> void:
	if state == "running":
		_end("won", "Relève de l'équipage : fin de la patrouille.", "end_patrol")


# ---------------------------------------------------------------- vagues

func _fire_wave(w: Dictionary) -> void:
	var kind: String = w.get("type", "streets")
	if kind == "breach":
		_breach(int(w.get("count", 1)), float(w.get("radius", 350.0)), int(w.get("max_occ", BREACH_MAX_OCC)))
		return
	if kind == "assault":
		_assault(int(w.get("count", 1)), float(w.get("radius", 350.0)), int(w.get("zombies", 4)), float(w.get("progress", 0.2)),
				int(w.get("min_occ", 3)), float(w.get("min_aim", 0.0)))
		return
	if kind == "metro":
		_metro(int(w.get("count", 8)), float(w.get("r_min", 150.0)), float(w.get("r_max", 550.0)))
		return
	if kind == "special":
		_special(str(w.get("zt", "screamer")), int(w.get("count", 1)), float(w.get("r_min", 150.0)), float(w.get("r_max", 400.0)))
		return
	var got: int = ctx.crowd.spawn_cluster(ctx.gunship.center, float(w.get("r_min", 125.0)),
			float(w.get("r_max", 400.0)), int(w.get("count", 10)))
	if got > 0:
		var sp: Vector2 = ctx.crowd.last_spawn
		ctx.say("new_group", _where(sp, {"n": got}),
				"Base : nouveau groupe d'infectés (%d environ), %s." % [got, where_fr(sp)], "alert")


## Infecté spécial (colosse, hurleur, alpha) sur une rue entre r_min et r_max du centre d'orbite ; l'alpha arrive avec sa meute.
func _special(zt_id: String, count: int, r_min: float, r_max: float) -> void:
	var zt: int = ctx.crowd.ZT_IDS.find(zt_id)
	if zt <= 0:
		return
	var name_fr: String = str(ctx.zombie_types.get(zt_id, {}).get("name", zt_id)).to_lower()
	for i in count:
		var p = ctx.crowd.spawn_special(zt, ctx.gunship.center, r_min, r_max)
		if p == null:
			break
		var at: Vector2 = ctx.crowd.last_spawn
		ctx.say("special_" + zt_id, _where(at),
				"Base : %s repéré, %s." % [name_fr, where_fr(at)], "alert")


func _breach(count: int, radius: float, max_occ: int = BREACH_MAX_OCC) -> void:
	var c: Vector2 = ctx.gunship.center
	var done := 0
	var tries := 0
	var nb: int = ctx.buildings.n
	while done < count and tries < 900:
		tries += 1
		var b: int = ctx.wave_rng.randi_range(0, nb - 1)
		# jamais une grande tribune ou une grosse tour : une intrusion y serait un désastre sans issue
		if not ctx.buildings.targetable(b) or ctx.buildings.zin[b] > 0 or ctx.buildings.occ[b] > max_occ:
			continue
		var p := Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
		if p.distance_to(c) > radius or not ctx.in_zone(p):
			continue
		ctx.buildings.infest(b, 4, ctx.rule("breach_grace_s", 0.0))
		done += 1
		ctx.say("breach", _where(p), "Base : intrusion dans un immeuble, %s. Des civils sont piégés !" % where_fr(p), "alert")


## Bouches de métro de la zone de jeu (indices de nœuds).
func metro_list() -> Array:
	var out: Array = []
	for n in ctx.city.metro_nodes:
		if ctx.in_zone(ctx.city.nodes[n], 20.0):
			out.append(n)
	return out


## Vague « metro » : un groupe remonte d'une bouche de métro de la zone située entre r_min et r_max du centre d'orbite (n'importe
## laquelle si aucune n'est à portée, de préférence à plus de 80 m de la visée) et erre ensuite dans les rues ; des rues ordinaires
## si la carte n'a pas de métro.
func _metro(count: int, r_min: float, r_max: float) -> void:
	var city = ctx.city
	var c: Vector2 = ctx.gunship.center
	var near: Array = []
	var all: Array = []
	for n in metro_list():
		var q: Vector2 = city.nodes[n]
		var d := q.distance_to(c)
		if q.distance_to(ctx.gunship.aim) >= 80.0:
			all.append(n)
			if d >= r_min and d <= r_max:
				near.append(n)
	if all.is_empty():
		all = metro_list()
	var cands: Array = near if not near.is_empty() else all
	if cands.is_empty():
		var got0: int = ctx.crowd.spawn_cluster(c, r_min, r_max, count)
		if got0 > 0:
			ctx.say("new_group", _where(ctx.crowd.last_spawn, {"n": got0}),
					"Base : nouveau groupe d'infectés (%d environ), %s." % [got0, where_fr(ctx.crowd.last_spawn)], "alert")
		return
	var node: int = cands[ctx.wave_rng.randi_range(0, cands.size() - 1)]
	var got: int = ctx.crowd.spawn_herd(node, count)
	if got <= 0:
		return
	var p: Vector2 = city.nodes[node]
	if ctx.fx != null:
		ctx.fx.metro_vent(p)
	var sp: Vector2 = ctx.crowd.last_spawn
	ctx.say("new_group_metro", _where(sp, {"n": got}),
			"Base : un groupe d'infectés (%d environ) remonte du métro, %s." % [got, where_fr(sp)], "alert")


## Assaut : un petit groupe arrive sur la porte déjà entamée d'un immeuble habité (au moins min_occ civils).
func _assault(count: int, radius: float, zombies: int, progress: float, min_occ: int = 3, min_aim: float = 0.0) -> void:
	for i in count:
		var b := assault_building(radius, zombies, progress, min_occ, min_aim)
		if b < 0:
			break
		var p := Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
		ctx.say("assault", _where(p), "Base : assaut en cours sur un immeuble, %s. Des civils sont barricadés à l'intérieur." % where_fr(p), "alert")


## Choisit un immeuble habité (au moins min_occ civils), intact, ni infesté ni assiégé, à moins de `radius` du centre
## d'orbite, d'au moins `min_aim` mètres de la visée et à moins de `max_evac` mètres d'un point d'évacuation. -1 s'il n'y en a pas.
func pick_building(radius: float, min_occ: int, min_aim: float = 0.0, max_evac: float = INF) -> int:
	var nb: int = ctx.buildings.n
	for tries in 300:
		var b: int = ctx.wave_rng.randi_range(0, nb - 1)
		if _pickable(b, radius, min_occ, min_aim, max_evac):
			return b
	# tirage au hasard sans résultat (immeubles rares : tribunes, tours) : on parcourt tous les immeubles une fois
	var found: Array = []
	for b in nb:
		if ctx.buildings.occ[b] >= min_occ and _pickable(b, radius, min_occ, min_aim, max_evac):
			found.append(b)
	if found.is_empty():
		return -1
	return found[ctx.wave_rng.randi_range(0, found.size() - 1)]


func _pickable(b: int, radius: float, min_occ: int, min_aim: float, max_evac: float) -> bool:
	if not ctx.buildings.targetable(b) or ctx.buildings.zin[b] > 0 or ctx.buildings.siege[b] > 0.0:
		return false
	if ctx.buildings.occ[b] < min_occ:
		return false
	var p := Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
	if p.distance_to(ctx.gunship.center) > radius or p.distance_to(ctx.gunship.aim) < min_aim or not ctx.in_zone(p):
		return false
	if max_evac < INF and evac_distance(p) > max_evac:
		return false
	return true


## Points d'évacuation utilisables : ceux de la zone de jeu (tous, si la carte n'en a aucun dans la zone).
func evac_list() -> Array:
	var out: Array = []
	for en in ctx.city.evac_nodes:
		if ctx.in_zone(ctx.city.nodes[en], 20.0):
			out.append(en)
	if out.is_empty():
		for en in ctx.city.evac_nodes:
			out.append(en)
	return out


## Distance (m) d'un point au point d'évacuation le plus proche.
func evac_distance(p: Vector2) -> float:
	var best := INF
	for en in evac_list():
		best = minf(best, ctx.city.nodes[en].distance_to(p))
	return best


## Lance un assaut sur un immeuble habité (voir pick_building) : `zombies` infectés arrivent sur la porte, déjà entamée
## de `progress`. Retourne l'immeuble, ou -1. Ne dit rien à la radio : l'appelant s'en charge.
func assault_building(radius: float, zombies: int, progress: float, min_occ: int = 3, min_aim: float = 0.0) -> int:
	for tries in 40:
		var b := pick_building(radius, min_occ, min_aim)
		if b < 0:
			return -1
		if ctx.crowd.spawn_assault(b, zombies) > 0:
			ctx.buildings.siege[b] = ctx.buildings.door_hp[b] * progress
			ctx.buildings.mark_active(b)
			return b
	return -1


# ---------------------------------------------------------------- Nuit blanche

## Vague n de la Nuit blanche : « rue » (ou métro) + assaut, intrusion et infectés spéciaux selon le calendrier de modes.json.
func _endless_wave() -> void:
	wave_n += 1
	ctx.wave_no = wave_n
	var e: Dictionary = _ecfg
	var f_int := clampf(t / maxf(float(e.get("ramp_s", 780.0)), 1.0), 0.0, 1.0)
	var f_cnt := clampf(t / maxf(float(e.get("count_ramp_s", 960.0)), 1.0), 0.0, 1.0)
	var iv: Array = e.get("interval_s", [30.0, 14.0])
	var cn: Array = e.get("count", [7, 30])
	var rr: Array = e.get("runner_ratio", [0.2, 0.5])
	var count := int(round(lerpf(float(cn[0]), float(cn[1]), f_cnt)))
	_next_wave_t = t + lerpf(float(iv[0]), float(iv[1]), f_int)
	# les infectés d'une vague tardive sont plus coriaces et plus souvent des coureurs
	var rules: Dictionary = ctx.mission.get("rules", {})
	var hp_f := clampf(t / maxf(float(e.get("hp_ramp_s", 1500.0)), 1.0), 0.0, 1.0)
	rules["zombie_hp"] = _base_hp * (1.0 + float(e.get("hp_growth", 1.0)) * hp_f)
	var r0 := maxf(float(rr[0]), 0.01)
	rules["runner_ratio"] = clampf(_base_runners * lerpf(1.0, float(rr[1]) / r0, f_cnt), 0.0, 0.7)
	ctx.mission["rules"] = rules
	# prime de la vague précédente tenue
	if wave_n >= 2 and ctx.score != null:
		var wp: Array = e.get("wave_points", [60, 15])
		ctx.score.on_wave(wave_n - 1, int(wp[0]) + int(wp[1]) * (wave_n - 2))
	if wave_n >= 2:
		ctx.say("wave", {"wave": wave_n} if wave_n <= 60 else {}, "Base : vague %d." % wave_n, "base")
	if _due(e.get("metro", {})):
		_metro(count, 150.0, 550.0)
	else:
		_fire_wave({"type": "streets", "count": count, "r_min": 125.0, "r_max": 400.0})
	var asl: Dictionary = e.get("assault", {})
	if _due(asl):
		var zr: Array = asl.get("zombies", [4, 9])
		var zn := int(round(lerpf(float(zr[0]), float(zr[1]), f_cnt)))
		_assault(1, 350.0, zn, 0.2, int(asl.get("min_occ", 4)), 0.0)
	var brl: Dictionary = e.get("breach", {})
	if _due(brl):
		_breach(1, 350.0, int(brl.get("max_occ", 24)))
	var sp: Dictionary = e.get("specials", {})
	for zt_id in ["screamer", "alpha", "colossus"]:
		var sc: Dictionary = sp.get(zt_id, {})
		if _due(sc):
			var rep_n := 1 + int(float(wave_n - int(sc.get("from", 1))) / maxf(float(sc.get("every", 1)) * 4.0, 1.0))
			_special(zt_id, rep_n, 150.0, 400.0)


## La vague en cours est-elle au calendrier {every, from} d'un événement ?
func _due(sched: Dictionary) -> bool:
	if sched.is_empty():
		return false
	var every := maxi(int(sched.get("every", 1)), 1)
	var from := int(sched.get("from", 1))
	return wave_n >= from and (wave_n - from) % every == 0


# ---------------------------------------------------------------- événements

## Un civil (ou plusieurs) est perdu. cause : "inside" (dévoré dans un immeuble), "street" (dévoré dans la rue),
## "shot" (touché par nos tirs) ; « eaten » (dévoré, ancien nom : la rue) et « collateral » (nos tirs) sont acceptés. Les civils ensevelis
## sous un immeuble rasé passent par on_building_destroyed. `at` : lieu de la perte (mètres), pour le repère affiché à l'écran.
func civilian_lost(n: int, cause: String, at: Vector2 = Vector2.ZERO) -> void:
	if cause == "eaten":
		cause = "street"
	elif cause == "collateral":
		cause = "shot"
	if cause == "shot":
		if ctx.score != null:
			ctx.score.on_collateral(n)
		_add_collateral(n, cause, at)
		if t - _last_col_msg > 6.0:
			_last_col_msg = t
			ctx.say("collateral", {}, "Base : civils touchés par vos tirs ! Identifiez vos cibles.", "alert")
	else:
		if ctx.score != null:
			ctx.score.on_eaten(n)
		eaten += n
		lost += n
		lost_by[cause] += n
		dead_by[cause] += n
		_note_loss(n, cause, at)
		_say_loss(cause, at)
	_check_thresholds()


## Civils tués par nos tirs (dans la rue ou sous un immeuble rasé) : nombre réel pour le score, part pondérée pour le seuil de pertes.
func _add_collateral(n: int, cause: String, at: Vector2, justified: bool = false) -> void:
	if justified:
		contained += n
	else:
		collateral += n
	dead_by[cause] += n
	_count_collateral(n, cause)
	_note_loss(n, cause, at, justified)


## Ajoute des civils tués par nos tirs au compte des pertes, pondérés par la difficulté (fractions cumulées).
func _count_collateral(n: int, cause: String = "shot") -> void:
	if not collateral_counts:
		return
	_collat_acc += float(n) * collateral_weight
	var k := int(_collat_acc + 0.0001)
	_collat_acc -= float(k)
	lost += k
	lost_by[cause] += k


## Mémorise la perte pour l'écran ; les pertes de même cause, proches dans le temps et l'espace, ne font qu'un seul événement.
func _note_loss(n: int, cause: String, at: Vector2, ok: bool = false) -> void:
	var now: float = ctx.time
	if not loss_events.is_empty():
		var last: Dictionary = loss_events[loss_events.size() - 1]
		if last["cause"] == cause and bool(last["ok"]) == ok and now - float(last["t"]) < 2.5 and (last["pos"] as Vector2).distance_to(at) < 150.0:
			last["n"] = int(last["n"]) + n
			last["t"] = now
			last["pos"] = at
			return
	loss_events.append({"t": now, "n": n, "cause": cause, "pos": at, "ok": ok})
	if loss_events.size() > 8:
		loss_events.pop_front()


## Explication à la radio : où des civils viennent d'être dévorés (en dehors de la consigne « raser » déjà donnée pour cet immeuble).
func _say_loss(cause: String, at: Vector2) -> void:
	if at == Vector2.ZERO or ctx.crowd == null or ctx.buildings == null or ctx.gunship == null:
		return
	if cause == "inside":
		var b: int = ctx.buildings.building_at(at.x, at.y)
		if b >= 0 and ctx.buildings.advice(b) == "raze":
			return                                # la consigne « immeuble perdu, rasez-le » couvre ce cas
		if t - _last_loss_msg > 25.0:
			_last_loss_msg = t
			ctx.say("loss_inside", _where(at), "Base : des civils sont dévorés dans un immeuble, %s. Tenez la rue autour de l'immeuble." % where_fr(at), "alert")
	elif t - _last_loss_msg > 30.0:
		_last_loss_msg = t
		ctx.say("loss_street", _where(at), "Base : civils dévorés dans la rue, %s. Abattez les infectés près des fuyards." % where_fr(at), "alert")


## Conseils parlés, une fois par immeuble : « immeuble perdu, rasez-le » et « porte attaquée, abattez les infectés devant la porte ».
func _advise(dt: float) -> void:
	_adv_t += dt
	if _adv_t < 0.5 or ctx.buildings == null or ctx.city == null:
		return
	_adv_t = 0.0
	var bs = ctx.buildings
	for b in bs.threatened_list():
		var adv: String = bs.advice(b)
		var p := Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
		if adv == "raze" and (bs.advised[b] & 1) == 0 and t - _last_raze_msg > 8.0:
			bs.advised[b] |= 1
			_last_raze_msg = t
			ctx.say("raze_advice", _where(p), "Base : immeuble perdu, %s. Vous pouvez le raser." % where_fr(p), "alert")
		elif adv == "siege" and (bs.advised[b] & 2) == 0 and bs.occ[b] >= 3 and bs.siege[b] >= 0.3 * bs.door_hp[b] and t - _last_siege_msg > 20.0:
			bs.advised[b] |= 2
			_last_siege_msg = t
			ctx.say("siege_alert", _where(p), "Base : porte attaquée, %s. Abattez les infectés devant la porte." % where_fr(p), "alert")


func civilian_saved(n: int) -> void:
	saved += n
	if ctx.score != null:
		ctx.score.on_saved(n)
	if t - _last_save_msg > 15.0:
		_last_save_msg = t
		ctx.say("saved", {}, "Base : des civils ont rejoint un point d'évacuation.", "good")


func zombie_killed(n: int, runner: bool = false, points: int = 0, ztype: int = 0) -> void:
	kills += n
	if ctx.score != null:
		for i in n:
			ctx.score.on_zombie_killed(runner, false, points, ztype)
	if ztype > 0:
		var id: String = ctx.crowd.ZT_IDS[ztype]
		var nm: String = str(ctx.zombie_types.get(id, {}).get("name", id)).to_lower()
		ctx.say(id + "_down", {}, "Nocturne 2-1 : %s neutralisé." % nm, "good")
	if t - _last_kill_msg > 14.0:
		_last_kill_msg = t
		ctx.say("kills", {}, "Nocturne 2-1 : cibles neutralisées.", "info")


func on_building_destroyed(b: int, occ_alive: int, zombies: int, was_lost: bool = false) -> void:
	destroyed += 1
	kills += zombies
	if ctx.score != null:
		for i in zombies:
			ctx.score.on_zombie_killed(false, true)
	if occ_alive > 0:
		var at := Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
		if was_lost:
			# immeuble déjà perdu (le conseil disait OUI) : ce n'est pas une bavure, les civils étaient condamnés
			if ctx.score != null:
				ctx.score.on_contained(occ_alive)
			_add_collateral(occ_alive, "razed", at, true)
			ctx.say("building_contained", {}, "Nocturne 2-1 : immeuble perdu rasé, contagion arrêtée.", "info")
		else:
			if ctx.score != null:
				ctx.score.on_collateral(occ_alive)
			_add_collateral(occ_alive, "razed", at)
			ctx.say("building_lost", {"civ": occ_alive}, "Nocturne 2-1 : immeuble détruit, %d civils sous les décombres." % occ_alive, "alert")
	else:
		ctx.say("building_clear", {}, "Nocturne 2-1 : immeuble détruit, %d infectés neutralisés." % zombies, "info")
	_check_thresholds()


func on_breach(b: int) -> void:
	if t - _last_breach_msg > 4.0:
		_last_breach_msg = t
		var pb := Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
		ctx.say("door_forced", _where(pb), "Base : porte forcée, des infectés pénètrent dans un immeuble, %s." % where_fr(pb), "alert")


func _check_thresholds() -> void:
	if not _warn50 and lost * 2 >= max_lost:
		_warn50 = true
		ctx.say("warn_half", {}, "Base : pertes civiles à %d sur %d tolérées. Il faut tenir les rues !" % [lost, max_lost], "alert")
	if not _warn80 and lost * 5 >= max_lost * 4:
		_warn80 = true
		ctx.say("warn_critical", {}, "Base : seuil critique, %d civils perdus. Une de plus et le secteur tombe." % lost, "alert")


# ---------------------------------------------------------------- aides de langage

static func compass_idx(from: Vector2, to: Vector2) -> int:
	var d := to - from
	var ang := fposmod(rad_to_deg(atan2(d.x, -d.y)), 360.0)
	return int(round(ang / 45.0)) % 8


static func compass_fr(from: Vector2, to: Vector2) -> String:
	var names := ["au nord", "au nord-est", "à l'est", "au sud-est", "au sud", "au sud-ouest", "à l'ouest", "au nord-ouest"]
	return names[compass_idx(from, to)]


## Paramètres de position pour la radio parlée : direction (0 = nord, sens horaire) et distance en mètres, depuis la visée.
func where_params(p: Vector2, extra: Dictionary = {}) -> Dictionary:
	return _where(p, extra)


func _where(p: Vector2, extra: Dictionary = {}) -> Dictionary:
	var a: Vector2 = ctx.gunship.aim
	var out := {"dir": compass_idx(a, p), "dist": int(round(a.distance_to(p)))}
	out.merge(extra)
	return out


## « au nord-est de votre visée, à 650 m ».
func where_fr(p: Vector2) -> String:
	var a: Vector2 = ctx.gunship.aim
	var dist := int(round(a.distance_to(p) / 50.0)) * 50
	return "%s de votre visée, à %d m" % [compass_fr(a, p), dist]
