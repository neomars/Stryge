extends RefCounted
## Appuis ponctuels demandés à la radio (touches 4 à 7) : barrage d'obusiers, drone de reconnaissance, leurre sonore,
## largage de munitions. Paramètres et niveaux : data/supports.json ; chaque appui s'achète à l'atelier (rubrique APPUIS,
## effet « mod.sup_<id> » = niveau 1 à 3). Le nombre d'appels par mission et le délai entre deux appels dépendent du niveau.
## Il n'y a pas de fusée éclairante : en imagerie thermique elle n'apporterait rien, elle est remplacée par le largage.

var ctx
var defs: Array = []              # définitions de data/supports.json, dans l'ordre des touches
var charges := {}                 # id -> appels restants
var cool := {}                    # id -> secondes avant le prochain appel possible
var shells: Array = []            # obus de barrage en attente : [secondes restantes, point (Vector2)]
var marks: Array = []             # zones d'appui à afficher : {id, pos, r, left, total}
var calls := 0                    # appels réussis depuis le début de la mission
var drone_pos := Vector2.ZERO
var drone_r := 0.0
var drone_left := 0.0
var drop_left := -1.0             # largage en route : secondes avant la livraison (< 0 : aucun)
var drop_refill := 0.0
var last_refused := ""            # dernier motif de refus (affiché par l'interface)
var _by_id := {}
var _pulse := 0.0


func setup(p_ctx, p_defs: Array) -> void:
	ctx = p_ctx
	defs = p_defs
	_by_id.clear()
	for d in defs:
		_by_id[str(d["id"])] = d
	reset()


func reset() -> void:
	charges.clear()
	cool.clear()
	shells.clear()
	marks.clear()
	calls = 0
	drone_left = 0.0
	drop_left = -1.0
	last_refused = ""
	for d in defs:
		var id := str(d["id"])
		charges[id] = int(params(id).get("charges", 0))
		cool[id] = 0.0


## Niveau acheté (0 : appui indisponible, jusqu'à 3).
func level(id: String) -> int:
	var d: Dictionary = _by_id.get(id, {})
	if d.is_empty():
		return 0
	return clampi(int(ctx.mod(str(d.get("upgrade", "")))), 0, (d["levels"] as Array).size())


## Nom court affiché (BARRAGE, DRONE, LEURRE, LARGAGE).
func short_name(id: String) -> String:
	return str((_by_id.get(id, {}) as Dictionary).get("short", id.to_upper()))


## Paramètres de l'appui au niveau acheté (définition + niveau) ; vide si l'appui n'est pas acheté.
func params(id: String) -> Dictionary:
	var lv := level(id)
	if lv <= 0:
		return {}
	var d: Dictionary = _by_id[id]
	var out: Dictionary = d.duplicate()
	out.merge(d["levels"][lv - 1], true)
	out.erase("levels")
	return out


func owned_ids() -> Array:
	var out: Array = []
	for d in defs:
		if level(str(d["id"])) > 0:
			out.append(str(d["id"]))
	return out


func ready(id: String) -> bool:
	return level(id) > 0 and int(charges.get(id, 0)) > 0 and float(cool.get(id, 0.0)) <= 0.0


## État pour l'interface : « none » (non acheté), « empty » (plus d'appels), « cool » (en recharge), « ready », « active ».
func state_of(id: String) -> String:
	if level(id) <= 0:
		return "none"
	if int(charges.get(id, 0)) <= 0 and not is_active(id):
		return "empty"
	if is_active(id):
		return "active"
	if float(cool.get(id, 0.0)) > 0.0:
		return "cool"
	return "ready"


func is_active(id: String) -> bool:
	match id:
		"barrage":
			return not shells.is_empty()
		"drone":
			return drone_left > 0.0
		"decoy":
			return ctx.crowd != null and ctx.crowd.decoy_left > 0.0
		"drop":
			return drop_left >= 0.0
	return false


## Secondes restantes de l'effet de l'appui (0 s'il n'agit pas).
func active_left(id: String) -> float:
	match id:
		"barrage":
			var m := 0.0
			for s in shells:
				m = maxf(m, float(s[0]))
			return m
		"drone":
			return maxf(drone_left, 0.0)
		"decoy":
			return maxf(ctx.crowd.decoy_left, 0.0) if ctx.crowd != null else 0.0
		"drop":
			return maxf(drop_left, 0.0)
	return 0.0


## Demande l'appui `id` sur le point `at` (sol). Retourne "" si l'appel est parti, sinon le motif du refus.
func request(id: String, at: Vector2) -> String:
	last_refused = ""
	if not _by_id.has(id):
		return _refuse("appui inconnu")
	if ctx.director != null and ctx.director.state != "running":
		return _refuse("mission terminée")
	if level(id) <= 0:
		return _refuse("%s : non acheté (atelier)" % str(_by_id[id]["short"]))
	if int(charges[id]) <= 0:
		return _refuse("%s : plus d'appel disponible" % str(_by_id[id]["short"]))
	if float(cool[id]) > 0.0:
		return _refuse("%s : en recharge (%d s)" % [str(_by_id[id]["short"]), int(ceil(float(cool[id])))])
	var p := params(id)
	match id:
		"barrage":
			var span := float(p.get("delay_s", 6.0)) + float(p.get("spread_s", 3.5))
			var rad := float(p.get("radius_m", 50.0))
			for i in int(p.get("shells", 5)):
				var a: float = ctx.rng.randf() * TAU
				var r: float = rad * sqrt(ctx.rng.randf())
				var delay: float = float(p.get("delay_s", 6.0)) + ctx.rng.randf() * float(p.get("spread_s", 3.5))
				shells.append([delay, at + Vector2(cos(a), sin(a)) * r])
			marks.append({"id": id, "pos": at, "r": rad, "left": span, "total": span})
		"drone":
			drone_pos = at
			drone_r = float(p.get("radius_m", 350.0))
			drone_left = float(p.get("duration_s", 25.0))
		"decoy":
			if not ctx.crowd.place_decoy(at, float(p.get("radius_m", 260.0)), float(p.get("duration_s", 15.0))):
				return _refuse("LEURRE : aucune rue à proximité")
			_pulse = 0.0
		"drop":
			drop_left = float(p.get("delay_s", 4.0))
			drop_refill = float(p.get("refill", 0.5))
	charges[id] = int(charges[id]) - 1
	cool[id] = float(p.get("cooldown_s", 60.0))
	calls += 1
	if ctx.score != null:
		ctx.score.on_support(id)
	ctx.say("sup_" + id, ctx.director.where_params(at), "Nocturne 2-1 : %s demandé." % str(_by_id[id]["name"]).to_lower(), "info")
	return ""


func _refuse(msg: String) -> String:
	last_refused = msg
	return msg


func update(dt: float) -> void:
	for id in cool.keys():
		if float(cool[id]) > 0.0:
			cool[id] = maxf(float(cool[id]) - dt, 0.0)
	# barrage : les obus tombent un à un
	for i in range(shells.size() - 1, -1, -1):
		shells[i][0] = float(shells[i][0]) - dt
		if float(shells[i][0]) <= 0.0:
			var at: Vector2 = shells[i][1]
			shells.remove_at(i)
			ctx.arms.support_shell(at)
	for i in range(marks.size() - 1, -1, -1):
		marks[i]["left"] = float(marks[i]["left"]) - dt
		if float(marks[i]["left"]) <= 0.0:
			marks.remove_at(i)
	if drone_left > 0.0:
		drone_left = maxf(drone_left - dt, 0.0)
	# leurre : une onde au sol à chaque seconde environ, pour voir où il agit
	if ctx.crowd.decoy_left > 0.0:
		_pulse -= dt
		if _pulse <= 0.0:
			_pulse = 1.2
			if ctx.fx != null:
				ctx.fx.decoy_pulse(ctx.crowd.decoy_pos)
	if drop_left >= 0.0:
		drop_left -= dt
		if drop_left < 0.0:
			_deliver_drop()


## Le largage arrive : chaque arme retrouve la part `refill` de sa capacité.
func _deliver_drop() -> void:
	drop_left = -1.0
	for i in ctx.weapons.size():
		var cap := float(ctx.weapons[i].get("ammo", 0))
		ctx.arms.ammo[i] = minf(float(ctx.arms.ammo[i]) + cap * drop_refill, cap)
	ctx.say("sup_drop_done", {}, "Nocturne 2-1 : munitions reçues.", "good")


## Infectés vus par le drone : [{pos, target (Vector2 ou Vector2.INF)}] dans le cercle de reconnaissance.
func drone_contacts(limit: int = 160) -> Array:
	var out: Array = []
	if drone_left <= 0.0 or ctx.crowd == null:
		return out
	var r2 := drone_r * drone_r
	var cr = ctx.crowd
	for i in cr.MAX_P:
		var z = cr.pool[i]
		if not z.alive or z.kind != cr.K_ZOMBIE or z.rising:
			continue
		if z.pos.distance_squared_to(drone_pos) > r2:
			continue
		var tgt := Vector2.INF
		if z.target_b >= 0 and ctx.buildings.targetable(z.target_b) and (z.mode == 1 or z.mode == 3):
			tgt = Vector2(ctx.city.b_cx[z.target_b], ctx.city.b_cz[z.target_b])
		out.append({"pos": z.pos, "target": tgt, "ztype": z.ztype})
		if out.size() >= limit:
			break
	return out
