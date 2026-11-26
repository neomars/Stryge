extends RefCounted
## Pilote automatique de développement : déroule un scénario et enregistre des captures d'écran.
## Lancement : godot --path . -- --autopilot=demo --out=/tmp/pnc_shots

const Daily := preload("res://scripts/meta/daily.gd")

var game
var ctx
var out_dir := "/tmp/pnc_shots"
var step := 0
var wait := 0.0
var frames := 0
var scenario := "demo"
var _t := 0.0


func setup(p_game, args: Dictionary) -> void:
	game = p_game
	ctx = game.ctx
	scenario = str(args["autopilot"])
	_args = args
	out_dir = str(args.get("out", out_dir))
	DirAccess.make_dir_recursive_absolute(out_dir)
	print("[autopilot] scénario %s -> %s" % [scenario, out_dir])


func _shot(name: String) -> void:
	var path := "%s/%s.png" % [out_dir, name]
	game.capture(path)
	print("[autopilot] capture %s (t=%.1f)" % [path, _t])


var _roof_b := -1

var wait_dt := 0.0


func update(dt: float) -> void:
	_t += dt
	wait_dt = dt
	frames += 1
	if _roof_b >= 0:
		_aim_roof(_roof_b)
	if (scenario == "humans" or scenario == "people" or scenario == "reticle" or scenario == "sensors") and step >= 1:
		_humans_tick(dt)
	if scenario == "blast" and step >= 1:
		ctx.gunship.theta = _hum_theta
	if scenario == "lot8" and step >= 1:
		ctx.gunship.theta = _l8_theta                 # la canonnière ne tourne plus : les infectés cachés le restent
	if wait > 0.0:
		wait -= dt
		return
	match scenario:
		"demo":
			_demo()
		"people", "humans":
			_humans()
		"reticle":
			_reticle()
		"blast":
			_blast()
		"screens":
			_screens()
		"breach":
			_breach()
		"soak":
			_soak()
		"sound":
			_sound()
		"debrief":
			_debrief()
		"progress":
			_progress()
		"campaign":
			_camp_scn()
		"sensors":
			_sensors()
		"modes":
			_modes_scn()
		"daily":
			_daily_scn()
		"endless":
			_endless_scn()
		"specials":
			_specials_scn()
		"places":
			_places_scn()
		"advice":
			_advice_scn()
		"urgent":
			_urgent_scn()
		"lot8":
			_lot8_scn()
		_:
			game.get_tree().quit()


## Vise le centre du toit : point au sol situé sur la droite caméra -> toit.
func _aim_roof(b: int) -> void:
	var gs = ctx.gunship
	var h: float = ctx.city.b_h[b]
	var roof := Vector3(ctx.city.b_cx[b], h * 0.8, ctx.city.b_cz[b])
	var c: Vector3 = gs.pos
	var k: float = c.y / maxf(c.y - roof.y, 1.0)
	var g := c + (roof - c) * k
	gs.aim = Vector2(g.x, g.z)


func _aim_at(p: Vector2) -> void:
	ctx.gunship.aim = p
	ctx.gunship.center_target = p
	ctx.gunship.center = p


## Visite chaque repère nommé de la carte (un cliché par nom) : sert à vérifier que les lieux sont reconnaissables.
var _pl_i := 0
var _pl_seen := {}


func _places_scn() -> void:
	var gs = ctx.gunship
	match step:
		0:
			game.start_mission()
			_aim_at(Vector2.ZERO)
			gs.zoom = 0.17
			gs.fov = 24.0
			wait = 2.5
			step = 1
		1:
			_shot("00_secteur")
			step = 2
		2:
			var pls: Array = ctx.city.places
			while _pl_i < pls.size() and _pl_seen.has(pls[_pl_i]["n"]):
				_pl_i += 1
			if _pl_i >= pls.size():
				game.get_tree().quit()
				return
			var pl: Dictionary = pls[_pl_i]
			_pl_seen[pl["n"]] = true
			_aim_at(Vector2(pl["x"], pl["z"]))
			gs.zoom = 0.2 if str(pl["k"]) in ["parc", "eau"] else 0.4
			gs.fov = clampf(gs.base_fov / gs.zoom, gs.min_fov, 30.0)
			step = 3
			wait = 1.2
		3:
			var pl2: Dictionary = ctx.city.places[_pl_i]
			var slug := str(pl2["n"]).to_lower().replace(" ", "_").replace("'", "").replace("é", "e").replace("è", "e") \
					.replace("ô", "o").replace("-", "_").replace("œ", "oe")
			_shot("lieu_%02d_%s" % [_pl_i, slug])
			_pl_i += 1
			step = 2


## Conseils d'immeuble : trois immeubles menacés (perdu, à défendre, porte attaquée), puis les pertes expliquées à l'écran.
## Clichés : c1 vue d'ensemble, c2 à c4 conseil sous la visée, c5 pertes, c6 flèches hors champ, c7 immeuble rasé, c8 aide.
var _adv_b: Array = []


func _advice_pick(near: Vector2) -> int:
	for k in 30:
		var b: int = ctx.buildings.pick_target(near)
		if b >= 0 and not _adv_b.has(b):
			return b
	return 0


func _advice_scn() -> void:
	var gs = ctx.gunship
	var bs = ctx.buildings
	match step:
		0:
			game.start_mission()
			ctx.director.waves = []
			for sp in [Vector2(-80.0, 40.0), Vector2(70.0, 60.0), Vector2(0.0, -90.0)]:
				_adv_b.append(_advice_pick(sp))
			var a: int = _adv_b[0]
			var b: int = _adv_b[1]
			var c: int = _adv_b[2]
			bs.occ[a] = 9
			bs.infest(a, 4, 40.0)                 # répit : les chiffres restent stables pendant les clichés
			bs.occ[b] = 22
			bs.infest(b, 2, 40.0)
			bs.occ[c] = 11
			bs.siege[c] = 0.45 * bs.door_hp[c]
			bs.idle_t[c] = -100.0                 # la porte ne se relâche pas pendant la prise de vue
			bs.mark_active(c)
			for k in _adv_b:
				print("[advice] immeuble %d : %d habitants, %d infectés, conseil %s" % [k, bs.occ[k], bs.zin[k], bs.advice(k)])
			var mid := Vector2.ZERO
			for k in _adv_b:
				mid += Vector2(ctx.city.b_cx[k], ctx.city.b_cz[k]) / 3.0
			_aim_at(mid)
			gs.zoom = 0.5
			gs.fov = clampf(gs.base_fov / gs.zoom, gs.min_fov, 40.0)
			wait = 1.5
			step = 1
		1:
			_shot("c1_marqueurs")
			gs.zoom = 1.3
			_roof_b = _adv_b[0]
			wait = 1.2
			step = 2
		2:
			_shot("c2_raser")
			_roof_b = _adv_b[1]
			wait = 1.0
			step = 3
		3:
			_shot("c3_ne_pas_raser")
			_roof_b = _adv_b[2]
			wait = 1.0
			step = 4
		4:
			_shot("c4_porte")
			_roof_b = -1
			var pa := Vector2(ctx.city.b_cx[_adv_b[0]], ctx.city.b_cz[_adv_b[0]])
			_aim_at(pa)
			gs.zoom = 0.6
			gs.fov = clampf(gs.base_fov / gs.zoom, gs.min_fov, 40.0)
			ctx.director.civilian_lost(2, "inside", pa)
			ctx.director.civilian_lost(1, "street", pa + Vector2(30.0, 20.0))
			wait = 0.7
			step = 5
		5:
			_shot("c5_perte")
			_aim_at(Vector2(ctx.city.b_cx[_adv_b[0]] + 650.0, ctx.city.b_cz[_adv_b[0]] - 300.0))
			wait = 1.5
			step = 6
		6:
			_shot("c6_fleches")
			_aim_at(Vector2(ctx.city.b_cx[_adv_b[0]], ctx.city.b_cz[_adv_b[0]]))
			gs.zoom = 0.9
			gs.fov = clampf(gs.base_fov / gs.zoom, gs.min_fov, 40.0)
			ctx.director.loss_events.clear()
			bs.destroy(_adv_b[0])                 # perdu (9 habitants, 4 infectés) : rasé à raison
			wait = 0.9
			step = 7
		7:
			_shot("c7_rase_perdu")
			_aim_at(Vector2(ctx.city.b_cx[_adv_b[2]], ctx.city.b_cz[_adv_b[2]]))
			ctx.director.loss_events.clear()
			bs.destroy(_adv_b[2])                 # la porte tenait encore : bavure
			wait = 0.9
			step = 8
		8:
			_shot("c8_rase_tenait")
			game.show_help = true
			wait = 0.5
			step = 9
		9:
			_shot("c9_aide")
			game.get_tree().quit()


## Lot 7 (à lancer avec --difficulty=recruit) : immeuble à raser en rouge, bandeau URGENT, viseur attiré, tailles de texte.
## Clichés : u1 vue d'ensemble, u2 immeuble rouge, u3 noir chaud, u4 texte normal, u5 texte très grand, u6 cible hors champ,
## u7 viseur attiré, u8 priorité suivante, u9 rue, u10 infecté spécial.
var _ur_d0 := 0.0
var _args := {}


## Capture + textes du HUD qui se recouvrent sur cette image (le HUD tient le compte quand debug_rects est vrai).
func _ur_shot(name: String) -> void:
	_shot(name)
	var ov: Array = game.hud.report_overlaps()
	print("[urgent] %s : %d chevauchement(s) de texte" % [name, ov.size()])
	for o in ov:
		print("[urgent]     ", o)


var _mon_n := 0
var _mon_bad := 0
var _mon_pairs := {}
const MON_FRAMES := 260


## Contrôle image par image (après les clichés) : la visée se promène, des immeubles passent en « à raser » ou « à défendre », des pertes, des annonces et le
## drone apparaissent et disparaissent ; on compte les images où deux textes du HUD se recouvrent (la dernière image dessinée est celle qu'on lit ici).
func _ur_monitor() -> void:
	var gs = ctx.gunship
	var bs = ctx.buildings
	if _mon_n > 0:
		var ov: Array = game.hud.report_overlaps()
		if not ov.is_empty():
			_mon_bad += 1
			for o in ov:
				var k := str(o).split(" (")[0]
				_mon_pairs[k] = int(_mon_pairs.get(k, 0)) + 1
	_mon_n += 1
	gs.aim = gs.center + Vector2(cos(float(_mon_n) * 0.045), sin(float(_mon_n) * 0.037)) * 420.0
	if _mon_n == 20:
		ctx.supports.drone_left = 20.0
	if _mon_n % 30 == 10:
		var b: int = bs.pick_target(gs.aim)
		if b >= 0:
			bs.occ[b] = 9 if (_mon_n / 30) % 2 == 0 else 14
			bs.infest(b, 4 if (_mon_n / 30) % 2 == 0 else 1, 40.0)
	if _mon_n % 14 == 1:
		var causes := ["street", "inside", "shot", "street"]
		ctx.director.civilian_lost(1 + (_mon_n / 14) % 3, causes[(_mon_n / 14) % 4], gs.aim + Vector2(160.0, -90.0))
	if _mon_n % 45 == 5:
		var kinds := ["new", "done", "failed"]
		ctx.objectives.toasts.append({"text": "OBJECTIF", "sub": "Chasse aux infectés", "kind": kinds[(_mon_n / 45) % 3], "pts": 500 if (_mon_n / 45) % 3 == 1 else 0, "t": ctx.time})
	if _mon_n >= MON_FRAMES:
		print("[urgent] contrôle image par image : %d images, %d avec des textes qui se recouvrent" % [_mon_n - 1, _mon_bad])
		for k in _mon_pairs.keys():
			print("[urgent]     %s × %d" % [str(k), int(_mon_pairs[k])])
		game.get_tree().quit()


func _ur_target() -> Vector2:
	var pr: Dictionary = ctx.director.urgent()
	if str(pr.get("kind", "none")) == "none":
		return ctx.gunship.aim
	return ctx.director.prio.aim_point(pr)


func _ur_say(label: String) -> void:
	var pr: Dictionary = ctx.director.urgent()
	print("[urgent] %s : %s · %s · niveau %d · rayon %.0f m · aim à %.0f m de la zone · assist actif=%s dedans=%s pause=%.1f" % [label, str(pr.get("kind", "")),
			str(pr.get("title", "")), int(pr.get("level", 0)), float(pr.get("radius", 0.0)), ctx.gunship.aim.distance_to(_ur_target()),
			str(ctx.assist.active), str(ctx.assist.inside), ctx.assist.pause_t])


func _urgent_scn() -> void:
	var gs = ctx.gunship
	var bs = ctx.buildings
	var cr = ctx.crowd
	var hud = game.hud
	match step:
		0:
			game.start_mission()
			ctx.director.waves = []
			ctx.director.max_lost = 5000
			for sp in [Vector2(-80.0, 40.0), Vector2(70.0, 60.0), Vector2(0.0, -90.0)]:
				_adv_b.append(_advice_pick(sp))
			var a: int = _adv_b[0]
			var b: int = _adv_b[1]
			var c: int = _adv_b[2]
			bs.occ[a] = 9
			bs.infest(a, 4, 40.0)
			bs.occ[b] = 22
			bs.infest(b, 2, 40.0)
			bs.occ[c] = 11
			bs.siege[c] = 0.45 * bs.door_hp[c]
			bs.idle_t[c] = -100.0
			bs.mark_active(c)
			print("[urgent] niveau %s, assist %.1f, texte %d" % [str(ctx.difficulty().get("id", "")), ctx.assist.level(), int(_args.get("text", 1))])
			hud.debug_rects = true
			hud.set_text_size(int(_args.get("text", 1)), false)
			_aim_at(Vector2(ctx.city.b_cx[a], ctx.city.b_cz[a]) + Vector2(240.0, 150.0))
			ctx.assist.pause_t = 1.2                     # la vue d'ensemble se fait avant que l'aimant ne ramène la visée
			gs.zoom = 0.5
			gs.fov = clampf(gs.base_fov / gs.zoom, gs.min_fov, 40.0)
			wait = 1.0
			step = 1
		1:
			_ur_say("vue d'ensemble")
			_ur_shot("u1_vue")
			gs.zoom = 1.3
			_roof_b = _adv_b[0]
			wait = 1.2
			step = 2
		2:
			_ur_shot("u2_immeuble_rouge")
			game.white_hot = false
			wait = 0.6
			step = 3
		3:
			_ur_shot("u3_noir_chaud")
			game.white_hot = true
			ctx.director.civilian_lost(2, "street", Vector2(ctx.city.b_cx[_adv_b[0]], ctx.city.b_cz[_adv_b[0]]) + Vector2(40.0, 25.0))
			wait = 0.8
			step = 4
		4:
			_ur_shot("u4_pertes")
			ctx.director.loss_events.clear()
			step = 5
		5:
			_roof_b = -1
			_aim_at(Vector2(ctx.city.b_cx[_adv_b[0]], ctx.city.b_cz[_adv_b[0]]) + Vector2(650.0, 420.0))
			ctx.assist.pause_t = 2.0
			gs.zoom = 1.0
			wait = 0.6
			step = 6
		6:
			_ur_say("hors champ")
			_ur_shot("u6_hors_champ")
			ctx.assist.pause_t = 0.0
			_ur_d0 = gs.aim.distance_to(_ur_target())
			wait = 4.0
			step = 7
		7:
			_ur_say("après 4 s d'aimant (départ à %.0f m)" % _ur_d0)
			gs.zoom = 1.3
			_ur_shot("u7_viseur_attire")
			ctx.director.loss_events.clear()
			bs.destroy(_adv_b[0])
			wait = 1.0
			step = 8
		8:
			_ur_say("après le rasage")
			_ur_shot("u8_suite")
			bs.destroy(_adv_b[1])
			bs.destroy(_adv_b[2])
			if cr.alive_count() < 12:
				cr.spawn_cluster(gs.center, 100.0, 250.0, 6)
			ctx.director.loss_events.clear()
			wait = 3.0
			step = 9
		9:
			var civ = null
			var zom = null
			for p in cr.pool:
				if not p.alive:
					continue
				if p.kind == cr.K_CIVIL and civ == null:
					civ = p
				elif p.kind == cr.K_ZOMBIE and not p.rising and zom == null:
					zom = p
			if civ == null or zom == null:
				print("[urgent] pas de civil ou d'infecté disponible pour la rue")
			else:
				zom.pos = civ.pos + Vector2(6.0, 0.0)
				_aim_at(civ.pos + Vector2(220.0, 140.0))
				gs.zoom = 1.0
			ctx.assist.pause_t = 0.8
			wait = 1.0
			step = 10
		10:
			_ur_say("rue")
			_ur_shot("u9_rue")
			for p in cr.pool:
				if p.alive and p.kind == cr.K_ZOMBIE:
					cr._kill(p, false)
			var sp2 = cr.spawn_special(cr.ZT_IDS.find("colossus"), gs.center, 150.0, 300.0)
			if sp2 != null:
				_aim_at(cr.last_spawn + Vector2(200.0, 120.0))
			ctx.assist.pause_t = 0.8
			wait = 1.2
			step = 11
		11:
			_ur_say("spécial")
			_ur_shot("u10_special")
			step = 12
		12:
			_ur_monitor()


func _demo() -> void:
	var gs = ctx.gunship
	match step:
		0:
			game.start_mission()
			_aim_at(Vector2.ZERO)
			gs.zoom = 0.17
			gs.fov = 24.0
			wait = 2.0
			step = 1
		1:
			_shot("01_apercu")
			var z = ctx.crowd.nearest_zombie(Vector2.ZERO)
			if z != null:
				gs.aim = z.pos
			gs.zoom = 1.0
			ctx.arms.select(0)
			wait = 3.0
			step = 2
		2:
			_shot("02_zombies")
			game.trigger_override = true
			wait = 1.1
			step = 3
		3:
			_shot("03_rafale")
			wait = 0.6
			step = 4
		4:
			_shot("04_rafale_b")
			game.trigger_override = false
			wait = 2.5
			step = 5
		5:
			_shot("05_apres")
			var b: int = ctx.buildings.pick_target(gs.aim)
			if b >= 0:
				gs.aim = Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
			ctx.arms.select(2)
			gs.zoom = 1.0
			wait = 2.5
			step = 6
		6:
			_shot("06_immeuble")
			game.trigger_override = true
			wait = 0.2
			step = 7
		7:
			game.trigger_override = false
			wait = 1.9
			step = 8
		8:
			_shot("07_impact")
			wait = 1.5
			step = 9
		9:
			_shot("08_effondrement")
			wait = 4.0
			step = 10
		10:
			_shot("09_braises")
			game.get_tree().quit()


# ---------------------------------------------------------------- scénario « humans »
# Gros plan sur les personnages 3D : course, marche, siège de porte, repas, chute, relèvement.
# La caméra est figée de profil par rapport à une grande rue ; les personnages tournent en boucle
# dans une fenêtre de quelques dizaines de mètres, pour pouvoir prendre des images à loisir.

var _hum_edge := -1
var _hum_tc := 0.5
var _hum_half := 20.0
var _hum_theta := 0.0
var _hum_dir := Vector2.RIGHT
var _hum_aim := Vector2.ZERO
var _hum_loop: Array = []
var _hum_feeders: Array = []
var _hum_riser = null


func _humans_street() -> void:
	var g = ctx.graph
	var best := -1.0
	for e in g.ea.size():
		var a: Vector2 = g.node_pos[g.ea[e]]
		var b: Vector2 = g.node_pos[g.eb[e]]
		if ((a + b) * 0.5).length() > 600.0:
			continue
		var sc: float = g.elen[e] + g.ew[e] * 10.0
		if sc > best:
			best = sc
			_hum_edge = e
	var a2: Vector2 = g.node_pos[g.ea[_hum_edge]]
	var b2: Vector2 = g.node_pos[g.eb[_hum_edge]]
	_hum_dir = (b2 - a2).normalized()
	_hum_tc = 0.5
	# on cherche un immeuble dont la porte donne sur cette rue, près du milieu
	var bs := -1
	var bd := INF
	for b in ctx.city.building_count():
		if ctx.city.b_door_edge[b] == _hum_edge:
			var dd: float = absf(ctx.city.b_door_t[b] - 0.5) * g.elen[_hum_edge]
			if dd < bd and dd < 25.0:
				bd = dd
				bs = b
	if bs >= 0:
		_hum_tc = ctx.city.b_door_t[bs] - 6.0 / g.elen[_hum_edge]
	_hum_aim = g.pos_on_edge(_hum_edge, _hum_tc, 0.0)
	_hum_theta = atan2(_hum_dir.x, _hum_dir.y)
	print("[humans] rue %d largeur %.1f longueur %.1f dir %s, immeuble porte %d" % [_hum_edge, g.ew[_hum_edge], g.elen[_hum_edge], _hum_dir, bs])
	_hum_door_b = bs


var _hum_door_b := -1


func _hum_person(kind: int, speed: float, t: float, off: float, goal_t: float) -> Object:
	var cr = ctx.crowd
	var p
	if kind == 0:
		p = cr.spawn_zombie(_hum_edge, t)
		p.runner = speed > 2.8
	else:
		p = cr._alloc()
		p.kind = 1
		p.hp = 20.0
		p.heat = ctx.rng.randf_range(0.93, 1.0)
		p.edge = _hum_edge
		p.t = t
	p.speed = speed
	p.off = off
	p.off_pref = off
	p.side = signf(off) if off != 0.0 else 1.0
	p.pos = ctx.graph.pos_on_edge(p.edge, p.t, p.off)
	cr._route(p, _hum_edge, goal_t, off)
	if kind == 0:
		p.mode = 2
	return p


func _humans() -> void:
	var gs = ctx.gunship
	var g = ctx.graph
	match step:
		0:
			game.start_mission()
			ctx.director.waves = []
			_humans_street()
			_aim_at(_hum_aim)
			gs.theta = _hum_theta
			gs.zoom = 3.0
			ctx.arms.select(0)
			var L: float = g.elen[_hum_edge]
			var u := 1.0 / L              # un mètre en abscisse t
			# civils qui courent, dans les deux sens
			for i in 5:
				var fwd := (i % 2 == 0)
				var t0: float = _hum_tc + (float(i) * 7.0 - 14.0) * u
				var off := (-1.0 if i % 2 == 0 else 1.0) * (1.5 + 0.9 * float(i % 3))
				_hum_loop.append(_hum_person(1, 3.9 + 0.2 * float(i), t0, off, 0.97 if fwd else 0.03))
			# zombies : marche, démarche claudicante, course
			var zs := [1.1, 1.4, 1.2, 3.3, 3.5, 1.5]
			for i in zs.size():
				var fwd := (i % 2 == 1)
				var t0: float = _hum_tc + (float(i) * 6.0 - 15.0) * u
				var off := (1.0 if i % 2 == 0 else -1.0) * (3.0 + 1.0 * float(i % 2))
				_hum_loop.append(_hum_person(0, float(zs[i]), t0, off, 0.97 if fwd else 0.03))
			# zombies qui martèlent une porte
			if _hum_door_b >= 0:
				var b := _hum_door_b
				for k in 2:
					var z = ctx.crowd.spawn_zombie(ctx.city.b_door_edge[b], ctx.city.b_door_t[b])
					if z != null:
						z.off = ctx.city.b_door_off[b] + (0.9 if k == 1 else -0.2)
						z.off_pref = z.off
						z.pos = g.pos_on_edge(z.edge, z.t, z.off)
						z.target_b = b
						z.mode = 3
						z.face = Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
						z.has_face = true
						z.yaw = atan2(-(z.face.x - z.pos.x), -(z.face.y - z.pos.y))
			# un repas : civil au sol, zombie penché dessus
			for i in 2:
				var c = ctx.crowd._alloc()
				c.kind = 2
				c.timer = 9999.0
				c.heat = 0.8
				c.edge = _hum_edge
				c.t = _hum_tc + (-3.0 + 9.0 * float(i)) * u
				c.off = 5.5 if i == 0 else -5.0
				c.pos = g.pos_on_edge(c.edge, c.t, c.off)
				c.lie = 1.0
				c.yaw = 0.5 + float(i)
				var z2 = ctx.crowd.spawn_zombie(_hum_edge, c.t)
				z2.off = c.off + (1.4 if i == 0 else -1.4)
				z2.off_pref = z2.off
				z2.pos = g.pos_on_edge(z2.edge, z2.t, z2.off)
				z2.mode = 0
				z2.idle = 9999.0
				z2.face = c.pos
				z2.has_face = true
				z2.feed = 9999.0
				z2.yaw = atan2(-(c.pos.x - z2.pos.x), -(c.pos.y - z2.pos.y))
				z2.phase = 0.0
				_hum_feeders.append(z2)
			# deux cadavres (civil, zombie)
			for i in 2:
				var d = ctx.crowd._alloc()
				d.kind = 3
				d.corpse_civil = (i == 0)
				d.timer = 9999.0
				d.heat = 0.5
				d.edge = _hum_edge
				d.t = _hum_tc + (10.0 + 4.0 * float(i)) * u
				d.off = 1.0 - 3.0 * float(i)
				d.pos = g.pos_on_edge(d.edge, d.t, d.off)
				d.lie = 1.0
				d.yaw = 1.0 + float(i) * 2.0
			# un zombie qui se relève
			_hum_riser = ctx.crowd.spawn_zombie(_hum_edge, _hum_tc + 3.0 * u)
			_hum_riser.off = -1.5
			_hum_riser.off_pref = -1.5
			_hum_riser.pos = g.pos_on_edge(_hum_edge, _hum_riser.t, -1.5)
			_hum_riser.mode = 0
			_hum_riser.idle = 9999.0
			_hum_riser.rising = true
			_hum_riser.lie = 1.0
			wait = 2.0
			step = 1
		1:
			_shot("h1_zoom3")
			gs.zoom = 8.0
			wait = 1.4
			step = 8
		8:
			_shot("h6_zoom8_a")
			wait = 0.2
			step = 9
		9:
			_shot("h6_zoom8_b")
			wait = 0.2
			step = 10
		10:
			_shot("h6_zoom8_c")
			gs.zoom = 5.0
			wait = 1.0
			step = 2
		2:
			_shot("h2_zoom5_a")
			wait = 0.17
			step = 3
		3:
			_shot("h2_zoom5_b")
			wait = 0.17
			step = 4
		4:
			_shot("h2_zoom5_c")
			game.white_hot = false
			wait = 0.6
			step = 5
		5:
			_shot("h3_noirchaud")
			game.white_hot = true
			game.marks_on = false
			wait = 0.6
			step = 6
		6:
			_shot("h4_sans_marques")
			game.marks_on = true
			gs.zoom = 1.0
			wait = 0.8
			step = 7
		7:
			_shot("h5_zoom1")
			game.get_tree().quit()


## Chaque image : caméra figée, personnages recyclés dans la fenêtre, repas et relèvement en boucle.
func _humans_tick(dt: float) -> void:
	var gs = ctx.gunship
	gs.theta = _hum_theta
	var g = ctx.graph
	var L: float = g.elen[_hum_edge]
	var half_t := _hum_half / L
	for p in _hum_loop:
		if not p.alive:
			continue
		if p.dir > 0 and p.t > _hum_tc + half_t:
			p.t -= 2.0 * half_t
		elif p.dir < 0 and p.t < _hum_tc - half_t:
			p.t += 2.0 * half_t
	for z in _hum_feeders:
		if z.alive:
			z.idle = 9999.0
			z.feed = 9999.0
	var r = _hum_riser
	if r != null and r.alive and not r.rising and r.mode == 0:
		r.rising = true
		r.lie = 1.0


# ---------------------------------------------------------------- scénario « reticle »
# Le réticule de chaque arme, en blanc chaud et en noir chaud, avec obus en vol et visée d'immeuble.
# La rue et la foule sont celles du scénario « humans ».

func _reticle() -> void:
	var gs = ctx.gunship
	match step:
		0:
			_humans()
			step = 100
		100:
			ctx.arms.select(0)
			gs.zoom = 1.0
			wait = 1.5
			step = 101
		101:
			_shot("r01_gau_zoom1")
			gs.zoom = 5.0
			wait = 1.3
			step = 102
		102:
			_shot("r02_gau_zoom5")
			ctx.arms.select(1)
			gs.zoom = 3.0
			wait = 1.6
			step = 103
		103:
			_shot("r03_bofors_zoom3")
			_bl_fire(1)
			wait = 0.04
			step = 104
		104:
			game.trigger_override = false
			wait = 0.5
			step = 105
		105:
			_shot("r04_bofors_en_vol")
			ctx.arms.select(2)
			gs.zoom = 2.2
			wait = 1.6
			step = 106
		106:
			_shot("r05_obusier_zoom2")
			_bl_fire(2)
			wait = 0.04
			step = 107
		107:
			game.trigger_override = false
			wait = 0.5
			step = 108
		108:
			_shot("r06_obusier_en_vol")
			wait = 2.5
			step = 109
		109:
			_shot("r07_obusier_recharge")
			game.white_hot = false
			ctx.arms.select(0)
			gs.zoom = 4.0
			wait = 1.5
			step = 110
		110:
			_shot("r08_noir_gau")
			ctx.arms.select(1)
			wait = 1.2
			step = 111
		111:
			_shot("r09_noir_bofors")
			ctx.arms.select(2)
			wait = 1.2
			step = 112
		112:
			_shot("r10_noir_obusier")
			game.white_hot = true
			var b: int = ctx.buildings.pick_target(gs.aim)
			if b >= 0:
				_hum_door_b = -1
				gs.aim = Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
				gs.center_target = gs.aim
				gs.center = gs.aim
			gs.zoom = 1.0
			wait = 2.0
			step = 113
		113:
			_shot("r11_immeuble")
			game.get_tree().quit()


# ---------------------------------------------------------------- scénario « blast »
# Explosions vues de profil sur une grande rue : rafale de 25 mm, obus de 40 mm, obus de 105 mm,
# puis effondrement d'un immeuble. Le déroulé est une liste d'événements datés en temps de jeu ;
# la simulation est ralentie (Engine.time_scale) autour des impacts pour saisir les premiers instants.

var _bl_seq: Array = []
var _bl_t := 0.0
var _bl_si := 0
var _bl_b := -1


func _bl_fire(weapon: int) -> void:
	ctx.arms.select(weapon)
	ctx.arms.cooldown = 0.0
	game.trigger_override = true


func _bl_plan() -> void:
	var slow := 0.3
	_bl_seq = [
		[1.0, "select", 0], [1.0, "zoom", 2.0], [1.2, "fire", 0], [1.65, "stop", 0],
		[1.9, "scale", slow],
		[2.05, "shot", "e1_gau_a"], [2.3, "shot", "e1_gau_b"], [2.8, "shot", "e1_gau_c"],
		[3.5, "scale", 1.0], [6.0, "shot", "e1_gau_d"],
		[6.5, "select", 1], [6.5, "zoom", 2.5], [7.3, "fire", 1], [7.34, "stop", 0],
		[8.3, "scale", slow],
		[8.43, "shot", "e2_bofors_a"], [8.6, "shot", "e2_bofors_b"], [8.95, "shot", "e2_bofors_c"],
		[9.5, "shot", "e2_bofors_d"], [10.0, "scale", 1.0],
		[12.0, "shot", "e2_bofors_e"], [15.0, "shot", "e2_bofors_f"],
		[15.5, "select", 2], [15.5, "zoom", 2.2], [16.5, "fire", 2], [16.54, "stop", 0],
		[17.95, "scale", slow],
		[18.05, "shot", "e3_obusier_a"], [18.25, "shot", "e3_obusier_b"], [18.6, "shot", "e3_obusier_c"],
		[19.3, "shot", "e3_obusier_d"], [20.2, "scale", 1.0],
		[22.0, "shot", "e3_obusier_e"], [26.0, "shot", "e3_obusier_f"], [34.0, "shot", "e3_obusier_g"],
		[34.2, "select", 2], [34.2, "zoom", 5.0], [35.0, "fire", 2], [35.04, "stop", 0],
		[36.45, "scale", slow],
		[36.55, "shot", "e5_zoom_a"], [36.75, "shot", "e5_zoom_b"], [37.1, "shot", "e5_zoom_c"],
		[37.8, "shot", "e5_zoom_d"], [38.7, "scale", 1.0],
		[40.5, "shot", "e5_zoom_e"], [44.5, "shot", "e5_zoom_f"],
		[46.5, "roof", 0], [46.5, "zoom", 1.4], [48.0, "fire", 2], [48.04, "stop", 0],
		[49.4, "scale", slow],
		[49.55, "shot", "e4_chute_a"], [49.8, "shot", "e4_chute_b"], [50.3, "shot", "e4_chute_c"],
		[51.2, "shot", "e4_chute_d"], [52.5, "scale", 1.0],
		[55.0, "shot", "e4_chute_e"], [56.0, "zoom", 3.0], [56.4, "shot", "e4_chute_h"],
		[60.0, "shot", "e4_chute_f"], [70.0, "shot", "e4_chute_g"],
		[70.2, "quit", 0],
	]


func _bl_event(ev: Array) -> void:
	var gs = ctx.gunship
	match ev[1]:
		"select":
			ctx.arms.select(int(ev[2]))
		"zoom":
			gs.zoom = float(ev[2])
		"fire":
			_bl_fire(int(ev[2]))
		"stop":
			game.trigger_override = false
		"scale":
			Engine.time_scale = float(ev[2])
		"shot":
			_shot(str(ev[2]))
		"roof":
			_bl_b = _hum_door_b if _hum_door_b >= 0 else ctx.buildings.pick_target(_hum_aim)
			if _bl_b < 0:
				_bl_b = 0
			ctx.buildings.hp[_bl_b] = 20.0
			_roof_b = _bl_b
		"quit":
			Engine.time_scale = 1.0
			game.get_tree().quit()


func _blast() -> void:
	var gs = ctx.gunship
	if step == 0:
		game.start_mission()
		ctx.director.waves = []
		_humans_street()
		_aim_at(_hum_aim)
		gs.theta = _hum_theta
		gs.zoom = 1.0
		ctx.arms.select(0)
		_bl_plan()
		step = 1
		return
	_bl_t += wait_dt
	while _bl_si < _bl_seq.size() and _bl_seq[_bl_si][0] <= _bl_t:
		var ev: Array = _bl_seq[_bl_si]
		_bl_si += 1
		_bl_event(ev)


# ---------------------------------------------------------------- scénario « screens »
# Écrans de briefing, d'aide, de pause, de fin, polarité noir chaud.

## Écrit la taille du panneau de l'écran ouvert et celle de la fenêtre : un panneau plus haut que la fenêtre déborde
## (boutons coupés en bas), ce que les captures ne montrent qu'à l'œil.
func _print_panel_fit(label: String) -> void:
	var cur: Control = game.screens.current
	if cur == null or cur.get_child_count() == 0:
		print("[autopilot] %s : aucun écran ouvert" % label)
		return
	var cc: Node = cur.get_child(0)
	if cc.get_child_count() == 0:
		return
	var pc: Control = cc.get_child(0)
	var vp: Vector2 = game.get_viewport().get_visible_rect().size
	var h: float = pc.size.y * pc.scale.y
	print("[autopilot] panneau « %s » : %d x %d px (échelle %.2f, soit %d px de haut) dans une fenêtre de %d x %d%s" % [label,
			pc.size.x, pc.size.y, pc.scale.y, h, vp.x, vp.y, "  -> DÉBORDE de %d px" % int(h - vp.y) if h > vp.y else ""])
	print("[autopilot]   position %s, minimum %s, rectangle global %s" % [pc.position, pc.get_combined_minimum_size(), pc.get_global_rect()])


func _screens() -> void:
	var gs = ctx.gunship
	match step:
		0:
			_aim_at(Vector2.ZERO)
			gs.zoom = 0.4
			wait = 1.0
			step = 1
		1:
			_print_panel_fit("briefing")
			_shot("s1_briefing")
			game.start_mission()
			wait = 4.0
			step = 2
		2:
			game.show_help = true
			wait = 0.5
			step = 3
		3:
			_shot("s2_aide")
			game.show_help = false
			game.set_paused(true)
			wait = 0.5
			step = 4
		4:
			_shot("s3_pause")
			game.set_paused(false)
			game.white_hot = false
			wait = 0.8
			step = 5
		5:
			_shot("s4_noir_chaud")
			game.white_hot = true
			ctx.director.lost = 52
			ctx.director.end_reason = "Trop de civils perdus."
			ctx.director.state = "lost"
			wait = 1.0
			step = 6
		6:
			_shot("s5_defaite")
			game.get_tree().quit()


# ---------------------------------------------------------------- scénario « breach »
# Immeuble infecté, siège d'une porte, fuite de civils, frappe de 105 mm et effondrement, en gros plan.

var _bb := -1

func _breach() -> void:
	var gs = ctx.gunship
	var bs = ctx.buildings
	match step:
		0:
			game.start_mission()
			ctx.director.waves = []
			_bb = bs.pick_target(Vector2(120.0, 80.0))
			if _bb < 0:
				_bb = 0
			var c := Vector2(ctx.city.b_cx[_bb], ctx.city.b_cz[_bb])
			_aim_at(c)
			_roof_b = _bb
			bs.infest(_bb, 5)
			print("[breach] immeuble %d, occupants %d, zombies %d" % [_bb, bs.occ[_bb], bs.zin[_bb]])
			gs.zoom = 1.6
			ctx.arms.select(0)
			wait = 1.0
			step = 1
		1:
			_shot("b1_infecte")
			wait = 4.0
			step = 2
		2:
			_shot("b2_fuite")
			ctx.arms.select(2)
			wait = 1.0
			step = 3
		3:
			game.trigger_override = true
			wait = 0.25
			step = 4
		4:
			game.trigger_override = false
			wait = 0.5
			step = 5
		5:
			_shot("b3_impact")
			wait = 0.8
			step = 6
		6:
			_shot("b4_effondrement")
			wait = 1.2
			step = 7
		7:
			_shot("b5_gravats")
			wait = 5.0
			step = 8
		8:
			_shot("b6_braises")
			game.get_tree().quit()


# ---------------------------------------------------------------- scénario « soak »
# Le robot joue la vraie partie (rendu compris) : détecte les erreurs d'exécution et mesure la fluidité.

var _soak_next := [25.0, 60.0, 100.0, 140.0, 180.0]
var _soak_i := 0
var _soak_retarget := 0.0
var _soak_tgt := {}
var _soak_frames := 0
var _soak_ms := 0.0
var _soak_worst := 0.0
var _soak_last := 0.0
var _soak_report := 30.0


func _soak_visible(p: Vector2) -> bool:
	var o: Vector3 = ctx.gunship.pos
	var t3 := Vector3(p.x, 0.0, p.y)
	var h: Dictionary = ctx.buildings.trace(o, (t3 - o).normalized())
	return h["pos"].distance_to(t3) < 5.0


func _soak_choose() -> Dictionary:
	var gs = ctx.gunship
	var bs = ctx.buildings
	var best_b := -1
	var best_score := 0.0
	for b in bs.infested_list():
		if bs.zin[b] >= 4 or (bs.zin[b] >= 2 and bs.occ[b] <= 2):
			var sc: float = float(bs.zin[b]) - 0.002 * gs.aim.distance_to(Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b]))
			if sc > best_score:
				best_score = sc
				best_b = b
	if best_b >= 0:
		return {"pos": Vector2(ctx.city.b_cx[best_b], ctx.city.b_cz[best_b]), "weapon": 2, "roof": best_b}
	var cr = ctx.crowd
	var zs: Array = []
	for i in cr.MAX_P:
		var p = cr.pool[i]
		if p.alive and p.kind == 0:
			zs.append(p)
	if zs.is_empty():
		return {}
	var best = null
	var bscore := -1.0
	for k in mini(zs.size(), 45):
		var z = zs[ctx.rng.randi_range(0, zs.size() - 1)]
		if not _soak_visible(z.pos):
			continue
		var n := 0
		for o in zs:
			if o.pos.distance_squared_to(z.pos) < 144.0:
				n += 1
		var score: float = float(n) - 0.004 * gs.aim.distance_to(z.pos)
		if score > bscore:
			bscore = score
			best = z
	if best == null:
		return {}
	return {"pos": best.pos, "weapon": 0, "zombie": best}


func _soak() -> void:
	var gs = ctx.gunship
	if step == 0:
		game.start_mission()
		gs.zoom = 1.0
		step = 1
		return
	# fluidité
	var now := float(Time.get_ticks_usec()) / 1000.0
	if _soak_last > 0.0:
		var ft := now - _soak_last
		_soak_ms += ft
		_soak_frames += 1
		_soak_worst = maxf(_soak_worst, ft)
	_soak_last = now
	var d = ctx.director
	if d.t >= _soak_report:
		_soak_report += 30.0
		print("[soak] t=%.0f s : %.1f ms/image en moyenne (pire %.0f ms), zombies %d, civils %d, perdus %d, sauvés %d, kills %d, immeubles détruits %d" % [
				d.t, _soak_ms / maxf(float(_soak_frames), 1.0), _soak_worst, ctx.crowd.n_zombies, ctx.crowd.n_civils,
				d.lost, d.saved, d.kills, d.destroyed])
		_soak_ms = 0.0
		_soak_frames = 0
		_soak_worst = 0.0
	if _soak_i < _soak_next.size() and d.t >= float(_soak_next[_soak_i]):
		_shot("k%d_t%03d" % [_soak_i + 1, int(d.t)])
		_soak_i += 1
	if game.state == "ended" or d.t >= 190.0:
		print("[soak] fin : état %s, t=%.0f s, perdus %d, sauvés %d, kills %d" % [d.state, d.t, d.lost, d.saved, d.kills])
		_shot("k9_fin")
		game.get_tree().quit()
		return
	_soak_robot(1.0 / 60.0)


## Le robot : choisit une cible (immeuble infesté au 105 mm, sinon grappe visible au 25 mm), la rejoint et tire.
func _soak_robot(dt: float) -> void:
	var gs = ctx.gunship
	_soak_retarget -= dt
	if _soak_retarget <= 0.0:
		_soak_retarget = 0.7
		_soak_tgt = _soak_choose()
		if not _soak_tgt.is_empty():
			ctx.arms.select(int(_soak_tgt["weapon"]))
	if _soak_tgt.is_empty():
		game.trigger_override = false
		return
	var p: Vector2 = _soak_tgt["pos"]
	if _soak_tgt.has("zombie") and _soak_tgt["zombie"].alive and _soak_tgt["zombie"].kind == 0:
		p = _soak_tgt["zombie"].pos
		_soak_tgt["pos"] = p
	var to: Vector2 = p - gs.aim
	var stp := 230.0 * dt
	if to.length() > 900.0:
		gs.center_target = p
	if to.length() > stp:
		gs.aim += to.normalized() * stp
		game.trigger_override = false
	else:
		gs.aim = p
		game.trigger_override = true


# ---------------------------------------------------------------- scénario « debrief »
# Déroule une mission en accéléré avec le robot du scénario « soak », photographie l'écran de jeu (score, série),
# force l'aube puis photographie le débriefing. Lancer :
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
#     --rendering-method gl_compatibility -- --autopilot=debrief --out=/tmp/debrief_shots

func _debrief_advance(goal: float) -> bool:
	var d = ctx.director
	var n := 0
	while game.state == "playing" and d.t < goal and n < 90:
		_soak_robot(1.0 / 30.0)
		game._play_frame(1.0 / 30.0)
		n += 1
	return game.state != "playing" or d.t >= goal


func _debrief() -> void:
	var gs = ctx.gunship
	var d = ctx.director
	match step:
		0:
			wait = 0.8
			step = 20
		20:
			_shot("ob0_briefing")
			game.start_mission()
			gs.zoom = 1.0
			d.max_lost = 5000          # le robot est maladroit : on le garde en vie pour voir toute la mission
			step = 1
		1:
			if _debrief_advance(118.0):
				wait = 0.5
				step = 2
		2:
			_shot("ob1_jeu_t118")
			step = 3
		3:
			if _debrief_advance(185.0):
				wait = 0.5
				step = 4
		4:
			_shot("ob2_jeu_t185")
			step = 5
		5:
			if _debrief_advance(280.0):
				wait = 0.5
				step = 6
		6:
			_shot("ob3_jeu_t280")
			# bandeaux : objectif caché révélé, puis objectif accompli
			ctx.objectives._toast("OBJECTIF CACHÉ ACCOMPLI", "Tir groupé", "hidden", 400)
			ctx.objectives._toast("OBJECTIF ACCOMPLI", "Tenir l'immeuble", "done", 700)
			step = 7
		7:
			_debrief_advance(d.t + 0.6)
			wait = 0.4
			step = 8
		8:
			_shot("ob4_bandeau")
			step = 9
		9:
			if game.state == "playing":
				d._end("won", "L'aube se lève : l'évacuation du secteur est terminée.", "end_dawn")
				game._finish()
			wait = 1.2
			step = 10
		10:
			_shot("db2_debrief")
			game.screens._show_page(1)
			wait = 0.5
			step = 11
		11:
			_shot("db3_objectifs")
			var res: Dictionary = ctx.score.finish(d.state == "won")
			print("[debrief] état %s, note %s, %d étoile(s), score %d, série max %d, objectifs %d" % [
					d.state, res["rating"], res["n_stars"], res["total"], res["stats"]["chain_best"], res["objectives"]["done"]])
			for it in ctx.objectives.items:
				print("[debrief]   %-12s %-9s %s" % [it["id"], it["state"], it["why"]])
			game.get_tree().quit()


# ---------------------------------------------------------------- scénario « sound »
# Banc d'essai audio : chaque arme, le déclic à vide, des échanges radio, la radio pendant une rafale (ducking).
# Lancer :  godot --headless --path . -- --autopilot=sound --audio-log --audio-record=/tmp/mix.wav

var _sn_seq: Array = []
var _sn_t := 0.0
var _sn_i := 0


func _sound_plan() -> void:
	var g := {"n": 12, "dir": 1, "dist": 700}
	_sn_seq = [
		[0.2, "select", 0],
		[14.0, "say", ["new_group", g]],
		[23.0, "fire", 0], [26.0, "stop", 0],             # rafale de 25 mm pendant l'échange radio (ducking)
		[33.0, "select", 1], [34.0, "fire", 1], [37.2, "stop", 1],   # 40 mm : cinq ou six coups, claquement du chargeur
		[40.0, "select", 2], [41.0, "fire", 2], [41.05, "stop", 2],  # 105 mm : un coup, puis éjection, chargement, verrou
		[50.0, "ammo0", 2], [50.2, "fire", 2], [52.8, "stop", 2],    # chargeur vide : déclics
		[54.0, "say", ["door_forced", {"dir": 5, "dist": 450}]],
		[55.0, "say", ["collateral", {}]],
		[56.0, "say", ["building_lost", {"civ": 7}]],
		[64.0, "say", ["warn_critical", {}]],
		[90.0, "quit", 0],
	]


func _sound_event(ev: Array) -> void:
	match ev[1]:
		"select":
			ctx.arms.select(int(ev[2]))
			ctx.arms.cooldown = 0.0
		"fire":
			ctx.arms.cooldown = 0.0
			game.trigger_override = true
		"stop":
			game.trigger_override = false
		"ammo0":
			ctx.arms.ammo[int(ev[2])] = 0.0
			ctx.arms.cooldown = 0.0
		"say":
			var a: Array = ev[2]
			ctx.say(str(a[0]), a[1], "(sans voix) " + str(a[0]), "info")
		"quit":
			if ctx.sound != null:
				print("[sound] %s" % ctx.sound.stats())
			game.get_tree().quit()


func _sound() -> void:
	if step == 0:
		game.start_mission()
		ctx.director.waves = []
		ctx.gunship.zoom = 1.0
		_sound_plan()
		step = 1
		return
	_sn_t += wait_dt
	while _sn_i < _sn_seq.size() and _sn_seq[_sn_i][0] <= _sn_t:
		var ev: Array = _sn_seq[_sn_i]
		_sn_i += 1
		_sound_event(ev)


# ---------------------------------------------------------------- scénario « progress »
# Profil de démonstration (en mémoire), briefing, chaque rubrique de l'atelier, puis une mission accélérée et la page « Progression ».
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
#     --rendering-method gl_compatibility -- --autopilot=progress --out=/tmp/progress_shots --nosound

func _progress() -> void:
	var prof = ctx.profile
	var d = ctx.director
	match step:
		0:
			prof.xp = 3600
			prof.grade_paid = prof.grade_index()
			prof.credits = 820
			prof.upgrades = {"g25_ammo": 2, "m102_acc": 1, "sen_zoom": 1, "crew_doors": 1}
			prof.medals = {"first_night": {"n": 1}, "first_win": {"n": 1}, "kills_100": {"n": 1}, "obj_first": {"n": 1}, "rate_b": {"n": 1}, "win_5": {"n": 2}}
			prof.owned = ["flt_amber"]
			prof.equipped["insignia"] = "ins_lorraine"
			prof.missions["mission_01"] = {"plays": 2, "wins": 1, "best_score": 7120, "best_rating": 2, "stars_done": [true, false, false], "best_stars": 1}
			game.screens.show_briefing()
			wait = 0.8
			step = 1
		1:
			_shot("pg0_briefing")
			game.screens.open_hangar("briefing", 0)
			wait = 0.6
			step = 2
		2:
			_shot("pg1_atelier_25mm")
			game.screens._hangar.show_tab(3)
			wait = 0.5
			step = 3
		3:
			_shot("pg2_atelier_capteurs")
			game.screens._hangar.show_tab(4)
			wait = 0.5
			step = 4
		4:
			_shot("pg3_atelier_equipage")
			game.screens._hangar.show_tab(5)
			wait = 0.5
			step = 5
		5:
			_shot("pg3b_atelier_appuis")
			game.screens._hangar.show_tab(6)
			wait = 0.5
			step = 6
		6:
			_shot("pg4_atelier_medailles")
			game.screens._hangar.show_tab(7)
			wait = 0.5
			step = 7
		7:
			_shot("pg5_atelier_perso")
			game.screens.close_hangar()
			wait = 0.5
			step = 8
		8:
			game.start_mission()
			d.max_lost = 5000
			ctx.gunship.zoom = 1.0
			step = 9
		9:
			if _debrief_advance(130.0):
				step = 10
		10:
			d._end("won", "L'aube se lève : l'évacuation du secteur est terminée.", "end_dawn")
			game._finish()
			wait = 1.0
			step = 11
		11:
			_shot("pg6_debrief_bilan")
			game.screens._show_page(2)
			wait = 0.5
			step = 12
		12:
			_shot("pg7_progression")
			var pr: Dictionary = ctx.score.result["progress"]
			print("[progress] XP +%d (%d -> %d), crédits +%d, médailles %s, nouveautés %s, promotions %s" % [
					pr["xp_gain"], pr["xp_before"], pr["xp_after"], pr["credits_gain"], str(pr["medals"].map(func(m): return m[0])), str(pr["unlocked"]), str(pr["promotions"])])
			game.get_tree().quit()


# ---------------------------------------------------------------- scénario « campaign »
# Briefing avec choix de difficulté, carte de campagne (secteur ouvert, secteur fermé, difficulté choisie sur la carte),
# retour au briefing, mission en accéléré puis débriefing qui ouvre un nouveau secteur.
# Lancer : xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
#     --rendering-method gl_compatibility -- --autopilot=campaign --out=/tmp/campaign_shots --nosound

func _camp_scn() -> void:
	var prof = ctx.profile
	var d = ctx.director
	match step:
		0:
			prof.xp = 2400
			prof.grade_paid = prof.grade_index()
			prof.credits = 640
			prof.missions["mission_01"] = {"plays": 3, "wins": 2, "best_score": 9120, "best_rating": 2, "stars_done": [false, true, true], "best_stars": 2, "best_diff": 1}
			prof.missions["mission_02"] = {"plays": 1, "wins": 0, "best_score": 2210, "best_rating": -1, "stars_done": [false, false, true], "best_stars": 1, "best_diff": -1}
			game.screens.show_briefing()
			wait = 0.8
			step = 1
		1:
			_shot("cg0_briefing")
			game.screens.open_campaign("briefing")
			wait = 0.8
			step = 2
		2:
			_shot("cg1_carte")
			game.screens._campaign.select(2)
			game.screens._campaign.set_level(2)
			wait = 0.5
			step = 3
		3:
			_shot("cg2_carte_verrou")
			game.screens._campaign.select(1)
			game.screens._campaign.set_level(0)
			wait = 0.5
			step = 4
		4:
			_shot("cg3_carte_montmartre")
			game.screens._campaign.select(4)
			wait = 0.5
			step = 5
		5:
			_shot("cg4_carte_stade")
			game.screens._campaign.select(0)
			game.screens._campaign.set_level(2)
			game.screens.close_campaign("nightmare")
			wait = 0.8
			step = 6
		6:
			_shot("cg5_briefing_cauchemar")
			game.set_difficulty("veteran")
			game.start_mission()
			d.max_lost = 5000
			ctx.gunship.zoom = 1.0
			step = 7
		7:
			if _debrief_advance(130.0):
				step = 8
		8:
			d._end("won", "L'aube se lève : l'évacuation du secteur est terminée.", "end_dawn")
			game._finish()
			wait = 1.0
			step = 9
		9:
			_shot("cg6_debrief")
			var pr: Dictionary = ctx.score.result["progress"]
			print("[campaign] étoiles %d, secteurs ouverts par ce résultat : %s" % [int(pr["stars_total"]), str(pr["sectors_unlocked"])])
			game.screens.open_campaign("debrief")
			wait = 0.6
			step = 10
		10:
			_shot("cg7_carte_apres")
			game.get_tree().quit()


# ---------------------------------------------------------------- scénario « sensors »
# Capteurs de l'atelier (marqueur du prédicteur, verrou laser) puis chaque filtre thermique et chaque réticule cosmétique,
# sur la rue et la foule du scénario « humans ».

var _sx_list: Array = []
var _sx_i := 0


func _sensors() -> void:
	var gs = ctx.gunship
	match step:
		0:
			_humans()
			step = 200
		200:
			ctx.mods = {"predict": 3, "laser": 3}
			ctx.arms.select(0)
			gs.zoom = 2.0
			wait = 2.0
			step = 201
		201:
			_shot("s01_predicteur_25mm")
			var pr = ctx.predictor
			print("[sensors] prédicteur : grappe %d, avance %.2f m, infectés à l'impact %d, civils %d" % [pr.n_follow, pr.lead_m(), pr.n_hit, pr.n_civ])
			ctx.arms.select(1)
			wait = 1.2
			step = 202
		202:
			_shot("s02_predicteur_40mm")
			game._toggle_designator()
			wait = 1.5
			step = 203
		203:
			_shot("s03_verrou_laser")
			var des = ctx.designator
			print("[sensors] laser : verrou %s, désignations %d, distance visée-cible %.1f m" % [str(des.active), des.locks,
					gs.aim.distance_to(des.target.pos) if des.target != null else -1.0])
			gs.zoom = 6.0
			wait = 1.5
			step = 204
		204:
			_shot("s04_verrou_zoom6")
			game._toggle_designator()
			ctx.mods = {}
			gs.zoom = 2.0
			game.show_help = false
			_sx_list = ctx.profile.defs.cos_items["filter"].map(func(c): return str(c["id"]))
			_sx_i = 0
			step = 210
		210:
			if _sx_i >= _sx_list.size():
				_sx_list = ctx.profile.defs.cos_items["reticle"].map(func(c): return str(c["id"]))
				_sx_i = 0
				ctx.profile.equipped["filter"] = "flt_white"
				game.apply_cosmetics()
				ctx.arms.select(1)
				step = 220
				return
			ctx.profile.equipped["filter"] = _sx_list[_sx_i]
			game.apply_cosmetics()
			wait = 0.5
			step = 211
		211:
			_shot("cf_%s" % _sx_list[_sx_i])
			_sx_i += 1
			step = 210
		220:
			if _sx_i >= _sx_list.size():
				ctx.mods = {"laser": 3}
				game.show_help = true
				wait = 0.4
				step = 230
				return
			ctx.profile.equipped["reticle"] = _sx_list[_sx_i]
			game.apply_cosmetics()
			wait = 0.5
			step = 221
		221:
			_shot("cr_%s" % _sx_list[_sx_i])
			_sx_i += 1
			step = 220
		230:
			_shot("s05_aide_laser")
			game.get_tree().quit()


# ---------------------------------------------------------------- scénarios « modes », « daily », « endless »
# Écrans du lot 5 : briefing avec mutateurs, écran des mutateurs, page des modes de jeu ; puis le défi du jour et la Nuit blanche
# de bout en bout (briefing, jeu, débriefing). Lancer :
#   ... -- --autopilot=modes --out=/tmp/modes_shots --nosound
#   ... -- --autopilot=daily --daily=2026-11-23 --out=/tmp/daily_shots --nosound
#   ... -- --autopilot=endless --endless --mission=mission_02 --out=/tmp/endless_shots --nosound

func _demo_profile() -> void:
	var prof = ctx.profile
	var today: String = Daily.today()
	prof.xp = 5200
	prof.grade_paid = prof.grade_index()
	prof.credits = 1200
	prof.stats["wins"] = 4
	prof.missions["mission_01"] = {"plays": 3, "wins": 3, "best_score": 12100, "best_rating": 3, "stars_done": [true, true, true], "best_stars": 3, "best_diff": 1}
	prof.missions["mission_02"] = {"plays": 2, "wins": 2, "best_score": 9800, "best_rating": 2, "stars_done": [true, true, false], "best_stars": 2, "best_diff": 1}
	var yesterday: String = Daily.previous_day(today)
	prof.daily = {"last_win": yesterday, "streak": 3, "best_streak": 5, "plays": 9, "wins": 6,
			"today": {"date": today, "best": 8120, "plays": 2, "won": false},
			"board": [
				{"date": yesterday, "score": 14200, "rating": "A", "won": true, "sector": "mission_03", "mut": 1},
				{"date": Daily.previous_day(yesterday), "score": 11800, "rating": "B", "won": true, "sector": "mission_01", "mut": 0},
				{"date": today, "score": 8120, "rating": "B", "won": false, "sector": "mission_04", "mut": 2},
				{"date": Daily.previous_day(Daily.previous_day(yesterday)), "score": 6400, "rating": "C", "won": true, "sector": "mission_02", "mut": 1}]}
	prof.endless = {"mission_01": {"plays": 2, "best_score": 12840, "best_waves": 11, "best_time": 912}}


func _modes_scn() -> void:
	match step:
		0:
			_demo_profile()
			game.toggle_mutator("fog")
			game.toggle_mutator("ammo_scarce")
			game.screens.show_briefing()
			wait = 0.8
			step = 1
		1:
			_shot("md0_briefing_mutateurs")
			game.screens.open_mutators()
			wait = 0.5
			step = 2
		2:
			_shot("md1_ecran_mutateurs")
			game.screens._mutators.handle_key(_fake_key(KEY_3))
			game.screens._mutators.handle_key(_fake_key(KEY_4))
			wait = 0.4
			step = 3
		3:
			_shot("md2_mutateurs_quatre_essais")
			game.screens.close_mutators()
			game.screens.open_modes("briefing")
			wait = 0.5
			step = 4
		4:
			_shot("md3_modes")
			game.screens._modes.step_sector(1)
			game.screens._modes.set_level(2)
			wait = 0.4
			step = 5
		5:
			_shot("md4_modes_secteur_2")
			game.get_tree().quit()


func _fake_key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	return ev


func _daily_scn() -> void:
	var d = ctx.director
	match step:
		0:
			_demo_profile()
			game.screens.show_briefing()
			wait = 0.8
			step = 1
		1:
			_print_panel_fit("briefing défi du jour")
			_shot("dl0_briefing_defi")
			game.screens.open_mutators()
			wait = 0.5
			step = 2
		2:
			_shot("dl1_mutateurs_imposes")
			game.screens.close_mutators()
			game.start_mission()
			d.max_lost = 5000
			ctx.gunship.zoom = 1.0
			step = 3
		3:
			if _debrief_advance(100.0):
				wait = 0.4
				step = 4
		4:
			_shot("dl2_jeu")
			d._end("won", "L'aube se lève : l'évacuation du secteur est terminée.", "end_dawn")
			game._finish()
			wait = 1.0
			step = 5
		5:
			_shot("dl3_debrief_bilan")
			game.screens._show_page(2)
			wait = 0.5
			step = 6
		6:
			_shot("dl4_progression")
			var pr: Dictionary = ctx.score.result["progress"]
			print("[daily] mode %s, rang %s, série %s, première victoire %s, XP +%d" % [str(pr["mode"]), str(pr["daily"].get("rank")),
					str(pr["daily"].get("streak")), str(pr["daily"].get("first_win")), int(pr["xp_gain"])])
			game.get_tree().quit()


func _endless_scn() -> void:
	var d = ctx.director
	match step:
		0:
			_demo_profile()
			game.screens.show_briefing()
			wait = 0.8
			step = 1
		1:
			_print_panel_fit("briefing Nuit blanche")
			_shot("en0_briefing_nuit_blanche")
			game.start_mission()
			d.max_lost = 5000
			ctx.gunship.zoom = 1.0
			step = 2
		2:
			if _debrief_advance(230.0):
				wait = 0.4
				step = 3
		3:
			_shot("en1_jeu")
			game.set_paused(true)
			wait = 0.5
			step = 4
		4:
			_shot("en2_pause")
			game.set_paused(false)
			d.end_patrol()
			game._finish()
			wait = 1.0
			step = 5
		5:
			_shot("en3_debrief_bilan")
			game.screens._show_page(2)
			wait = 0.5
			step = 6
		6:
			_shot("en4_progression")
			var pr: Dictionary = ctx.score.result["progress"]
			print("[endless] vagues %d, record %s, XP +%d, crédits +%d" % [int(ctx.score.result["waves"]), str(pr["endless"]), int(pr["xp_gain"]), int(pr["credits_gain"])])
			game.get_tree().quit()


# ---------------------------------------------------------------- scénario « specials »
# Colosse, hurleur et alpha avec sa meute en gros plan, puis les quatre appuis ponctuels.

var _sp_i := 0


func _specials_scn() -> void:
	var gs = ctx.gunship
	var cr = ctx.crowd
	match step:
		0:
			game.start_mission()
			ctx.director.max_lost = 5000
			for p in cr.pool:
				if p.alive:
					cr._kill(p, false)
			step = 1
			wait = 0.3
		1:
			var zt: int = cr.ZT_IDS.find(["colossus", "screamer", "alpha"][_sp_i])
			var sp = cr.spawn_special(zt, gs.center, 150.0, 300.0)
			if sp == null:
				print("[specials] aucune place pour ", cr.ZT_IDS[zt])
				step = 3
				return
			_aim_at(cr.last_spawn)
			gs.zoom = 3.4
			wait = 1.5
			step = 2
		2:
			_shot("sp%d_%s" % [_sp_i, ["colosse", "hurleur", "alpha"][_sp_i]])
			_sp_i += 1
			for p in cr.pool:
				if p.alive:
					cr._kill(p, false)
			step = 1 if _sp_i < 3 else 3
			wait = 0.3
		3:
			# appuis : barrage, drone, leurre, largage
			cr.spawn_cluster(gs.center, 120.0, 260.0, 26)
			_aim_at(cr.last_spawn)
			gs.zoom = 0.9
			for id in ["barrage", "drone", "decoy", "drop"]:
				ctx.mods["sup_" + id] = 2
			ctx.supports.reset()
			for id in ["drone", "decoy", "barrage", "drop"]:
				print("[specials] appui %s -> « %s »" % [id, ctx.supports.request(id, gs.aim)])
			wait = 3.0
			step = 4
		4:
			_shot("sp3_appuis_t3")
			wait = 4.0
			step = 5
		5:
			_shot("sp4_appuis_t7")
			wait = 2.5
			step = 6
		6:
			_shot("sp5_appuis_t9")
			game.get_tree().quit()


# ---------------------------------------------------------------- lot 8 : carrés rouges, obus guidés, groupes du métro, civils de la rue

var _l8_theta := 0.0
var _l8_spot := {}
var _l8_hidden: Array = []
var _l8_seen: Array = []


## Premier immeuble haut (le plus proche du centre) dont l'arrière cache le sol à la canonnière : {b, hid, dir, seen}.
func _l8_find() -> Dictionary:
	var gs = ctx.gunship
	var bs = ctx.buildings
	var city = ctx.city
	var eye: Vector3 = gs.pos
	var e2 := Vector2(eye.x, eye.z)
	var order: Array = []
	for b in bs.n:
		if bs.status[b] != bs.ST_OK or city.b_h[b] < 20.0:
			continue
		var bp := Vector2(city.b_cx[b], city.b_cz[b])
		if bp.distance_to(gs.center) > 320.0 or bp.distance_to(e2) < 300.0:
			continue
		order.append([bp.distance_to(gs.center), b])
	order.sort_custom(func(a, c): return a[0] < c[0])
	for e in order:
		var b: int = e[1]
		var bp := Vector2(city.b_cx[b], city.b_cz[b])
		var dir: Vector2 = (bp - e2).normalized()
		for dist in [10.0, 13.0, 16.0, 20.0]:
			var zp: Vector2 = bp + dir * dist
			if bs.building_at(zp.x, zp.y) >= 0 or not bs.blocked(eye, Vector3(zp.x, 1.0, zp.y)):
				continue
			var d3: Vector3 = (Vector3(zp.x, 0.0, zp.y) - eye).normalized()
			if int(bs.trace(eye, d3)["b"]) < 0:
				continue
			var seen := Vector2.INF
			for d2 in [28.0, 40.0, 55.0]:
				var vp: Vector2 = bp - dir * d2
				if bs.building_at(vp.x, vp.y) < 0 and not bs.blocked(eye, Vector3(vp.x, 1.0, vp.y)):
					seen = vp
					break
			if seen != Vector2.INF:
				return {"b": b, "hid": zp, "dir": dir, "seen": seen}
	return {}


func _l8_still(pos: Vector2):
	var z = ctx.crowd._alloc()
	z.kind = ctx.crowd.K_ZOMBIE
	z.pos = pos
	z.hp = 40.0
	z.idle = 9999.0
	z.mode = 0
	return z


func _l8_shot(name: String) -> void:
	_shot(name)
	var ov: Array = game.hud.report_overlaps()
	print("[lot8] %s : %d chevauchement(s) de texte, %d carré(s) rouge(s), niveau de verrouillage %.0f" % [name, ov.size(), ctx.lock.hidden.size(), ctx.lock.level])
	for o in ov:
		print("[lot8]     ", o)


func _lot8_scn() -> void:
	var gs = ctx.gunship
	var bs = ctx.buildings
	var cr = ctx.crowd
	var hud = game.hud
	match step:
		0:
			game.start_mission()
			ctx.director.waves = []
			ctx.director.max_lost = 5000
			for p in cr.pool:
				if p.alive and p.kind == cr.K_ZOMBIE:
					cr._kill(p, false)
			hud.debug_rects = true
			hud.set_text_size(int(_args.get("text", 1)), false)
			_l8_theta = gs.theta
			gs.zoom = 0.6
			gs.aim = gs.center
			print("[lot8] niveau %s, verrouillage %.0f, zone %.0f m, %d bouches de métro dont %d dans la zone, %d sorties" % [str(ctx.difficulty().get("id", "")), ctx.lock.level, ctx.zone_radius(),
					ctx.city.metro_nodes.size(), ctx.director.metro_list().size(), ctx.director.evac_list().size()])
			if _args.has("l8probe"):
				game.get_tree().quit()
				return
			wait = 2.0
			step = 1
		1:
			_l8_shot("l8_1_zone")
			_l8_spot = _l8_find()
			if _l8_spot.is_empty():
				print("[lot8] aucun immeuble qui cache la rue : arrêt")
				game.get_tree().quit()
				return
			var hid: Vector2 = _l8_spot["hid"]
			var dir: Vector2 = _l8_spot["dir"]
			var side := Vector2(-dir.y, dir.x)
			for dd2 in [0.0, -2.5, 2.5, -5.0, 5.0]:
				for ds in [0.0, 3.5, -3.5, 7.0, -7.0]:
					var q: Vector2 = hid + dir * dd2 + side * ds
					if _l8_hidden.size() < 5 and bs.building_at(q.x, q.y) < 0 and bs.blocked(gs.pos, Vector3(q.x, 1.0, q.y)):
						_l8_hidden.append(_l8_still(q))
			var seen: Vector2 = _l8_spot["seen"]
			for off2 in [Vector2.ZERO, side * 5.0, -side * 6.0]:
				_l8_seen.append(_l8_still(seen + off2))
			print("[lot8] immeuble %d (%.0f m) : %d infectés cachés derrière, %d en vue" % [int(_l8_spot["b"]), ctx.city.b_h[int(_l8_spot["b"])], _l8_hidden.size(), _l8_seen.size()])
			gs.aim = hid.lerp(seen, 0.4)
			gs.zoom = 1.6
			wait = 1.2
			step = 2
		2:
			_l8_shot("l8_2_carres_rouges")
			game.white_hot = false
			wait = 0.6
			step = 3
		3:
			_l8_shot("l8_3_carres_noir_chaud")
			game.white_hot = true
			var lvl: float = ctx.lock.level
			ctx.lock.level = 0.0                    # le même plan sans l'aide
			wait = 0.6
			step = 4
		4:
			_l8_shot("l8_4_sans_carres")
			ctx.lock.level = float(ctx.difficulty().get("lock", 1.0))
			gs.aim = _l8_spot["hid"]
			wait = 0.8
			step = 5
		5:
			ctx.arms.select(1)
			ctx.arms.cooldown = 0.0
			game.trigger_override = true
			wait = 0.05
			step = 6
		6:
			game.trigger_override = false
			wait = 0.5
			step = 7
		7:
			var sh = ctx.arms.shells[0] if ctx.arms.shells.size() > 0 else null
			print("[lot8] obus en vol : b=%s, hauteur d'impact %.1f m" % [str(sh.b) if sh != null else "?", sh.pos.y if sh != null else -1.0])
			_l8_shot("l8_5_obus_en_vol")
			wait = 0.9
			step = 8
		8:
			var alive := 0
			for z in _l8_hidden:
				if z.alive and z.kind == cr.K_ZOMBIE:
					alive += 1
			print("[lot8] après l'impact : %d infecté(s) caché(s) encore debout sur %d" % [alive, _l8_hidden.size()])
			_l8_shot("l8_6_apres_impact")
			ctx.arms.select(2)
			ctx.arms.cooldown = 0.0
			game.trigger_override = true
			wait = 0.1
			step = 9
		9:
			game.trigger_override = false
			ctx.arms.select(0)                      # on change d'arme tout de suite : l'obusier se recharge à côté
			game.trigger_override = true
			wait = 0.3
			step = 10
		10:
			game.trigger_override = false
			_l8_shot("l8_7_armes_rechargement")
			step = 11
		11:
			# groupe du métro et civils de la rue
			var mt: Array = ctx.director.metro_list()
			if mt.is_empty():
				print("[lot8] métro vide : %d nœuds, zone %s, centre %s, rayon %.0f" % [ctx.city.metro_nodes.size(), str(ctx.mission.get("zone")), str(ctx.zone_center()), ctx.zone_radius()])
				game.get_tree().quit()
				return
			var node: int = mt[0]
			for n in mt:
				if ctx.city.nodes[n].distance_to(gs.center) < ctx.city.nodes[node].distance_to(gs.center):
					node = n
			var got: int = cr.spawn_herd(node, 9)
			gs.aim = ctx.city.nodes[node] + Vector2(12.0, 6.0)
			gs.zoom = 1.6
			print("[lot8] groupe du métro : %d infectés en %s" % [got, str(ctx.city.nodes[node])])
			wait = 2.0
			step = 12
		12:
			_l8_shot("l8_8_groupe_metro")
			# la plus forte grappe de civils des rues (rayon 70 m) : on cadre large pour les voir courir ensemble
			var best_n := 0
			var best_c := Vector2.ZERO
			var civ = null
			for p in cr.pool:
				if not (p.alive and p.kind == cr.K_CIVIL and p.amb):
					continue
				var n := 0
				var acc := Vector2.ZERO
				for q in cr.pool:
					if q.alive and q.kind == cr.K_CIVIL and q.amb and q.pos.distance_to(p.pos) < 70.0:
						n += 1
						acc += q.pos
				if n > best_n:
					best_n = n
					best_c = acc / float(n)
					civ = p
			print("[lot8] civils des rues : %d en vie, plus forte grappe : %d (rayon 70 m)" % [cr.n_amb, best_n])
			if civ != null:
				# un infecté arrive derrière l'un d'eux
				var zc = cr.spawn_zombie(civ.edge, clampf(civ.t - float(civ.dir) * 22.0 / maxf(ctx.graph.elen[civ.edge], 1.0), 0.02, 0.98))
				zc.mode = 0
				zc.idle = 0.0
				zc.seeker = false
				gs.aim = best_c
				gs.zoom = 0.55                     # cadrage large : on voit plusieurs civils courir en même temps
			wait = 1.5
			step = 13
		13:
			_l8_shot("l8_9_civils_fuient")
			step = 14
		14:
			_ur_monitor()
