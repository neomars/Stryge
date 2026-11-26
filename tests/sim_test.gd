extends SceneTree
## Tests logiques sans rendu.
##   godot --headless --path . -s tests/sim_test.gd            (rapide)
##   godot --headless --path . -s tests/sim_test.gd -- --bots=6 (nombre de parties du robot)

const Ctx := preload("res://scripts/ctx.gd")
const CityData := preload("res://scripts/world/city_data.gd")
const CityGen := preload("res://scripts/world/city_generator.gd")
const StreetGraph := preload("res://scripts/world/street_graph.gd")
const BuildingSystem := preload("res://scripts/sim/building_system.gd")
const Crowd := preload("res://scripts/sim/crowd.gd")
const Director := preload("res://scripts/sim/director.gd")
const Gunship := preload("res://scripts/core/gunship.gd")
const Arms := preload("res://scripts/core/arms.gd")
const Sound := preload("res://scripts/core/sound.gd")
const Predictor := preload("res://scripts/core/predictor.gd")
const Designator := preload("res://scripts/core/designator.gd")
const Assist := preload("res://scripts/core/assist.gd")
const Lock := preload("res://scripts/core/lock.gd")
const Priority := preload("res://scripts/sim/priority.gd")
const Supports := preload("res://scripts/core/supports.gd")
const Score := preload("res://scripts/meta/score.gd")
const Objectives := preload("res://scripts/meta/objectives.gd")
const Defs := preload("res://scripts/meta/defs.gd")
const Profile := preload("res://scripts/meta/profile.gd")
const Upgrades := preload("res://scripts/meta/upgrades.gd")
const Campaign := preload("res://scripts/meta/campaign.gd")
const Mutators := preload("res://scripts/meta/mutators.gd")
const Daily := preload("res://scripts/meta/daily.gd")
const Main := preload("res://scripts/main.gd")
const Hud := preload("res://scripts/ui/hud.gd")

var failures := 0
var n_bots := 4
var no_objectives := false      # --noobj : parties du robot sans objectifs (mesure de l'effet des objectifs sur l'équilibrage)
var bot_sector := "mission_02"  # --sector=mission_03 : secteur joué par le robot (Montmartre par défaut : ni gagné d'avance ni perdu d'avance)
var bot_level := "veteran"      # --level=recruit|veteran|nightmare : difficulté jouée par le robot
var bot_trace := false          # --bottrace : une ligne d'état toutes les 10 s pour chaque partie du robot
var bots_only := false          # --botsonly : ne joue que les parties du robot (réglage de l'équilibrage)
var vis_only := false           # --vis : mesure la part des rues visibles depuis la canonnière dans chaque secteur
var bot_mfile := ""             # --mfile=chemin.json : le robot joue cette mission (variante d'essai) au lieu de celle du secteur
var idle_only := false          # --idle : durée de tenue d'un secteur sans aucune intervention (mesure sans robot, pour comparer les secteurs)
var lot6_only := false           # --lot6 : seulement les essais des pertes lisibles et du conseil « raser »
var bot_seed0 := 1914           # --seed0=N : première graine des parties du robot (échantillons indépendants)
var lot7_only := false           # --lot7 : seulement les essais de la priorité urgente, de l'immeuble rouge et du viseur assisté
var lot8_only := false           # --lot8 : seulement les essais du lot 8 (zone réduite, cadence par arme, métro, civils de la rue, carrés rouges)
var probe8 := false              # --probe8 : mesure (sans verdict) du comportement de la foule dans le secteur --sector sur --secs secondes
var probe_secs := 120.0
var lot5_only := false          # --lot5 : ne lance que les tests des mutateurs, spéciaux, appuis et modes de jeu (itération rapide)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok     ", msg)
	else:
		failures += 1
		print("  ECHEC  ", msg)


func _json(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text())


func _make_world(seed_v: int, mission: Dictionary = {}, size: float = 2400.0, style: String = "latin", mode: String = "campaign", mutators: Array = [], file: String = ""):
	var ctx = Ctx.new()
	ctx.mode = mode
	ctx.mutators = mutators.duplicate()
	ctx.weapons = _json("res://data/weapons.json")["weapons"]
	ctx.mission = mission if not mission.is_empty() else _json("res://data/mission_01.json")
	ctx.rng.seed = seed_v + 7
	ctx.wave_rng.seed = seed_v + 8
	var defs_w = Defs.load_all()
	ctx.zombie_types = defs_w.zombie_types
	ctx.score = Score.new()
	ctx.score.setup(ctx, _json("res://data/scoring.json"))
	ctx.objectives = Objectives.new()
	ctx.objectives.setup(ctx, [] if no_objectives else ctx.mission.get("objectives", []))
	var city
	if file != "":
		city = CityData.new()                       # secteur réel : carte convertie de l'IGN / OpenStreetMap
		if not city.load_json("res://data/cities/%s.json" % file):
			push_error("carte introuvable : %s" % file)
	else:
		city = CityGen.new().generate(seed_v, size, style)
	var graph = StreetGraph.new()
	graph.build(city)
	graph.snap_doors(city)
	ctx.city = city
	ctx.graph = graph
	var cam := Camera3D.new()
	cam.near = 1200.0
	cam.far = 9000.0
	root.add_child(cam)
	ctx.buildings = BuildingSystem.new()
	ctx.crowd = Crowd.new()
	ctx.director = Director.new()
	ctx.gunship = Gunship.new()
	ctx.arms = Arms.new()
	ctx.buildings.setup(ctx, city)
	ctx.crowd.setup(ctx)
	ctx.director.setup(ctx)
	ctx.gunship.setup(ctx, cam)
	ctx.arms.setup(ctx)
	ctx.supports = Supports.new()
	ctx.supports.setup(ctx, defs_w.supports)
	return ctx


## Monde d'un secteur de la campagne : sa ville, sa mission transformée par la difficulté.
func _make_sector_world(sector_id: String, level_id: String = "veteran"):
	var d = Defs.load_all()
	var base: Dictionary = Campaign.load_mission(d, sector_id)
	var m: Dictionary = Campaign.apply_difficulty(base, d.level(level_id))
	var c: Dictionary = m["city"]
	var ctx = _make_world(int(c["seed"]), m, float(c["size"]), str(c["style"]), "campaign", [], str(c.get("file", "")))
	ctx.base_mission = base
	return ctx


## Égalité profonde où 55 et 55.0 sont le même nombre.
func _deep_equal(a, b) -> bool:
	if typeof(a) == TYPE_DICTIONARY and typeof(b) == TYPE_DICTIONARY:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not _deep_equal(a[k], b[k]):
				return false
		return true
	if typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _deep_equal(a[i], b[i]):
				return false
		return true
	if (typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT) and (typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT):
		return absf(float(a) - float(b)) < 0.000001
	return a == b


func _sim(ctx, dt: float) -> void:
	ctx.time += dt
	ctx.gunship.update(dt)
	ctx.arms.update(dt)
	ctx.buildings.step(dt)
	ctx.crowd.step(dt)
	ctx.director.step(dt)


var _ran := false


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--bots="):
			n_bots = int(a.substr(7))
		elif a == "--noobj":
			no_objectives = true
		elif a.begins_with("--sector="):
			bot_sector = a.substr(9)
		elif a.begins_with("--level="):
			bot_level = a.substr(8)
		elif a == "--bottrace":
			bot_trace = true
		elif a == "--botsonly":
			bots_only = true
		elif a == "--vis":
			vis_only = true
		elif a.begins_with("--mfile="):
			bot_mfile = a.substr(8)
		elif a == "--idle":
			idle_only = true
		elif a == "--lot5":
			lot5_only = true
		elif a == "--lot6":
			lot6_only = true
		elif a == "--lot7":
			lot7_only = true
		elif a == "--lot8":
			lot8_only = true
		elif a == "--probe8":
			probe8 = true
		elif a.begins_with("--secs="):
			probe_secs = float(a.substr(7))
		elif a.begins_with("--seed0="):
			bot_seed0 = int(a.substr(8))


## Les tests tournent à la première image : la racine est alors bien dans l'arbre (la caméra aussi).
func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	var t0 := Time.get_ticks_msec()
	if vis_only:
		_vis_report()
		quit(0)
		return true
	if idle_only:
		_idle_report()
		quit(0)
		return true
	if lot5_only:
		_test_mutators()
		_test_specials()
		_test_supports()
		_test_daily()
		_test_endless()
		_test_modes_profile()
		_test_lot5_radio()
		print("\nDurée %.1f s — échecs : %d" % [(Time.get_ticks_msec() - t0) / 1000.0, failures])
		quit(1 if failures > 0 else 0)
		return true
	if probe8:
		_probe8()
		quit(0)
		return true
	if lot8_only:
		_test_lot8()
		print("\nDurée %.1f s — échecs : %d" % [(Time.get_ticks_msec() - t0) / 1000.0, failures])
		quit(1 if failures > 0 else 0)
		return true
	if lot7_only:
		_test_urgent_assist()
		print("\nDurée %.1f s — échecs : %d" % [(Time.get_ticks_msec() - t0) / 1000.0, failures])
		quit(1 if failures > 0 else 0)
		return true
	if lot6_only:
		_test_readable_losses()
		print("\nDurée %.1f s — échecs : %d" % [(Time.get_ticks_msec() - t0) / 1000.0, failures])
		quit(1 if failures > 0 else 0)
		return true
	if bots_only:
		_test_bot_games()
		print("\nDurée %.1f s — échecs : %d" % [(Time.get_ticks_msec() - t0) / 1000.0, failures])
		quit(1 if failures > 0 else 0)
		return true
	_test_city()
	_test_json()
	_test_ballistics()
	_test_walk()
	_test_score()
	_test_objectives()
	_test_progression_data()
	_test_profile()
	_test_campaign()
	_test_sectors()
	_test_real_cities()
	_test_workshop()
	_test_mods_in_game()
	_test_sensors()
	_test_voice_styles()
	_test_mutators()
	_test_specials()
	_test_supports()
	_test_daily()
	_test_endless()
	_test_modes_profile()
	_test_lot5_radio()
	_test_readable_losses()
	_test_urgent_assist()
	_test_lot8()
	_test_idle_game()
	_test_bot_games()
	print("\nDurée %.1f s — échecs : %d" % [(Time.get_ticks_msec() - t0) / 1000.0, failures])
	quit(1 if failures > 0 else 0)
	return true


# ---------------------------------------------------------------- ville

func _test_city() -> void:
	print("# ville et graphe")
	var t := Time.get_ticks_msec()
	var ctx = _make_world(1914)
	var city = ctx.city
	print("   %d nœuds, %d tronçons, %d immeubles, %d zones — monde prêt en %d ms" % [
			city.nodes.size(), city.edge_a.size(), city.building_count(), city.areas.size(), Time.get_ticks_msec() - t])
	_check(city.building_count() > 5000, "plus de 5000 immeubles")
	var bad := 0
	for b in city.building_count():
		var e: int = city.b_door_edge[b]
		var hw: float = ctx.graph.ew[e] * 0.5
		var off: float = absf(city.b_door_off[b])
		if e < 0 or e >= ctx.graph.ea.size() or off < hw + 1.0 or off > hw + 30.0:
			bad += 1
	_check(bad == 0, "portes accrochées à une rue (%d douteuses)" % bad)
	var path: PackedInt64Array = ctx.graph.astar.get_id_path(0, city.nodes.size() - 1)
	_check(not path.is_empty(), "le réseau routier est connexe (coin à coin : %d nœuds)" % path.size())
	_check(city.evac_nodes.size() == 9, "9 points d'évacuation")
	var occ_total := 0
	for b in city.building_count():
		occ_total += city.b_occ[b]
	print("   habitants : %d" % occ_total)


func _test_json() -> void:
	print("# format JSON")
	var ctx = _make_world(77)
	var city = ctx.city
	var s := JSON.stringify(city.to_dict())
	var c2 = CityData.new()
	var ok: bool = c2.from_dict(JSON.parse_string(s))
	_check(ok and c2.building_count() == city.building_count() and c2.nodes.size() == city.nodes.size()
			and c2.edge_a.size() == city.edge_a.size() and c2.evac_nodes.size() == city.evac_nodes.size(),
			"aller-retour JSON (%d Ko)" % (s.length() / 1024))
	_check(absf(c2.b_h[100] - city.b_h[100]) < 0.11, "hauteurs conservées")
	var g2 = StreetGraph.new()
	g2.build(c2)
	g2.snap_doors(c2)
	_check(c2.b_door_edge[500] == city.b_door_edge[500], "portes recalculées à l'identique")


# ---------------------------------------------------------------- balistique

func _test_ballistics() -> void:
	print("# tracé de rayon et dégâts")
	var ctx = _make_world(1914)
	var city = ctx.city
	var bs = ctx.buildings
	var tall := 0
	for b in city.building_count():
		if city.b_h[b] > city.b_h[tall]:
			tall = b
	var c := Vector3(city.b_cx[tall], 0.0, city.b_cz[tall])
	var origin := c + Vector3(1500.0, 2100.0, 0.0)
	var target := c + Vector3(0.0, city.b_h[tall] - 0.5, 0.0)
	var hit: Dictionary = bs.trace(origin, (target - origin).normalized())
	_check(hit["b"] == tall and absf(hit["pos"].y - city.b_h[tall]) < 3.0,
			"rayon sur le toit de la plus haute tour (%.0f m) -> immeuble %d, y=%.1f" % [city.b_h[tall], hit["b"], hit["pos"].y])
	var e: int = ctx.graph.nearest_edge(Vector2(0, 0))[0]
	var sp: Vector2 = ctx.graph.pos_on_edge(e, 0.5, 0.0)
	var o2 := Vector3(sp.x + 1500.0, 2100.0, sp.y)
	var hit2: Dictionary = bs.trace(o2, (Vector3(sp.x, 0.0, sp.y) - o2).normalized())
	_check(hit2["b"] == -1 and absf(hit2["pos"].y) < 0.01, "rayon sur l'axe d'une rue -> sol")
	# effondrement
	var pre: float = ctx.buildings.hp[tall]
	ctx.director.start()
	var lost0: int = ctx.director.lost
	bs.damage(tall, 1000.0)
	_check(bs.status[tall] == 1, "un immeuble sans points de vie s'effondre")
	for i in 60:
		bs.step(0.1)
	_check(bs.status[tall] == 2 and bs.height_of(tall) < city.b_h[tall] * 0.1, "ruines basses après 3 s")
	_check(ctx.director.lost >= lost0 and ctx.director.destroyed == 1, "la destruction est comptée (%d civils sous les décombres)" % (ctx.director.lost - lost0))
	# dégâts de zone sur la foule
	var e2: int = ctx.graph.nearest_edge(Vector2(300, 300))[0]
	for i in 8:
		ctx.crowd.spawn_zombie(e2, 0.5)
	var p0: Vector2 = ctx.graph.pos_on_edge(e2, 0.5, 0.0)
	ctx.crowd.step(0.05)
	var before: int = ctx.crowd.count_near(p0, 30.0, 0)
	var res: Vector2i = ctx.crowd.damage_area(p0.x, p0.y, 30.0, 500.0, 0.0)
	ctx.crowd.step(0.05)
	_check(before == 8 and res.x == 8 and ctx.crowd.count_near(p0, 30.0, 0) == 0, "105 mm : 8 zombies à portée tués (avant=%d, tués=%d)" % [before, res.x])
	# arme : un coup tiré arrive après le temps de vol
	ctx.gunship.aim = p0
	ctx.gunship.update(0.0)
	ctx.arms.select(2)
	ctx.arms.cooldown = 0.0
	ctx.arms.trigger = true
	ctx.arms.update(0.01)
	ctx.arms.trigger = false
	_check(ctx.arms.shells.size() == 1, "un obus de 105 mm est en vol")
	for i in 30:
		ctx.arms.update(0.1)
	_check(ctx.arms.shells.is_empty(), "l'obus a explosé après son temps de vol")


# ---------------------------------------------------------------- foule

func _test_walk() -> void:
	print("# déplacement d'un zombie")
	var ctx = _make_world(1914)
	var edge: int = ctx.graph.nearest_edge(Vector2(-900, -900))[0]
	var z = ctx.crowd.spawn_zombie(edge, 0.5)
	z.speed = 8.0
	z.seeker = true                      # (lot 8 : 30 % seulement des infectés cherchent un immeuble ; celui-ci en est un)
	ctx.crowd._assign(z)
	_check(z.mode == 1 and z.target_b >= 0, "le zombie choisit un immeuble habité (mode=%d)" % z.mode)
	var tb: int = z.target_b
	var before: int = ctx.buildings.zin[tb]
	ctx.buildings.door_hp[tb] = 6.0
	var steps := 0
	var saw_siege := false
	var siege_since := -1
	while z.alive and steps < 20000:
		ctx.crowd.step(0.1)
		ctx.buildings.step(0.1)
		if z.mode == 3 and not saw_siege:
			saw_siege = true
			siege_since = steps
		steps += 1
	_check(saw_siege, "arrivé à la porte, il la martèle (siège)")
	_check(not z.alive and ctx.buildings.zin[tb] == before + 1,
			"la porte de l'immeuble %d cède après ~6 s et il entre (%d pas, siège de %.1f s)" % [tb, steps, (steps - siege_since) * 0.1])
	# un siège abandonné se relâche
	var b2: int = ctx.buildings.pick_target(Vector2(300, 300))
	ctx.buildings.pound(b2, 20.0)
	var s0: float = ctx.buildings.siege[b2]
	for i in 100:
		ctx.buildings.step(0.1)
	_check(ctx.buildings.siege[b2] < s0 - 5.0, "sans assaillants, la porte se consolide (%.0f -> %.0f)" % [s0, ctx.buildings.siege[b2]])


# ---------------------------------------------------------------- score

func _test_score() -> void:
	print("# score, série, notes et étoiles")
	var ctx = _make_world(1914)
	var sc = ctx.score
	_check(sc.tier_of(0) == 1 and sc.tier_of(4) == 1 and sc.tier_of(5) == 2 and sc.tier_of(15) == 3 and sc.tier_of(30) == 4,
			"multiplicateur de série : ×1 jusqu'à 4, ×2 dès 5, ×3 dès 15, ×4 dès 30")
	for i in 5:
		sc.on_zombie_killed(false)
	_check(sc.points == 60 and sc.mult == 2 and sc.chain == 5, "5 éliminations : 4×10 + 1×(10×2) = 60 points, série ×2 (%d, ×%d)" % [sc.points, sc.mult])
	sc.on_saved(2)
	_check(sc.points == 60 + 240 and sc.chain == 5, "un civil sauvé rapporte 120 points, sans multiplicateur et sans toucher à la série")
	sc.on_collateral(1)
	_check(sc.chain == 0 and sc.mult == 1 and sc.points == 60 + 240 - 150, "une bavure retire 150 points et rompt la série")
	sc.on_eaten(2)
	_check(sc.points == 150 - 80 and sc.chain == 0, "deux civils dévorés : -80 points")
	# obus : statistiques de salve
	sc.reset()
	sc.begin_shell(2, 1200.0)
	for i in 3:
		sc.on_zombie_killed(true)
	sc.end_shell(3)
	_check(sc.st["max_kills_shell"] == 3 and sc.st["shells_hit"] == 1 and is_equal_approx(sc.st["max_kill_range"], 1200.0)
			and sc.st["kills_w"][2] == 3 and sc.st["runners"] == 3, "statistiques d'obus : 3 éliminations d'un coup, portée 1200 m, arme 3")
	_check(sc.points == 3 * 14, "un coureur vaut 14 points (%d)" % sc.points)
	# notes
	var tg: Array = sc.ctx.mission["score_targets"]
	var seq := [sc.rating_for(0), sc.rating_for(int(tg[0]) - 1), sc.rating_for(int(tg[0])), sc.rating_for(int(tg[1])),
			sc.rating_for(int(tg[2])), sc.rating_for(int(tg[3]))]
	_check(seq == ["D", "D", "C", "B", "A", "S"], "paliers de note D, C, B, A, S : %s" % str(seq))
	_check(sc.rating_gap(int(tg[1]) - 500) == ["B", 500] and sc.rating_gap(99999)[1] == 0, "points manquants pour la note suivante")
	# étoiles et bilan d'une victoire
	var ctx2 = _make_world(1914)
	var d2 = ctx2.director
	d2.start()
	d2.lost = 10
	d2.saved = 5
	d2.t = 100.0
	ctx2.score.points = 3000
	d2.state = "won"
	d2.end_reason = "test"
	var r: Dictionary = ctx2.score.finish(true)
	_check(r["won"] and r["n_stars"] == 2 and r["stars"][0]["ok"] and r["stars"][1]["ok"] and not r["stars"][2]["ok"],
			"victoire à 3 000 points avec 10 civils perdus : 2 étoiles (%d)" % r["n_stars"])
	_check(r["total"] > 3000 and r["rating"] != "D", "les bonus de fin s'ajoutent au score (%d -> %d, note %s)" % [3000, r["total"], r["rating"]])
	_check(r["rating_next"] != "" and r["rating_missing"] > 0, "on sait combien de points manquent pour la note %s (%d)" % [r["rating_next"], r["rating_missing"]])
	var again: Dictionary = ctx2.score.finish(true)
	_check(again["total"] == r["total"], "le bilan n'est calculé qu'une fois")
	var ctx3 = _make_world(1914)
	ctx3.director.start()
	ctx3.score.points = 20000
	ctx3.director.state = "lost"
	var r3: Dictionary = ctx3.score.finish(false)
	_check(r3["n_stars"] == 0 and r3["rating"] == "—", "une défaite ne donne ni étoile ni note")
	# intégration : un obus de 105 mm sur 6 zombies et 1 civil
	var ctx4 = _make_world(1914)
	ctx4.director.start()
	var e: int = ctx4.graph.nearest_edge(Vector2(300, 300))[0]
	for i in 6:
		ctx4.crowd.spawn_zombie(e, 0.5)
	var p0: Vector2 = ctx4.graph.pos_on_edge(e, 0.5, 0.0)
	ctx4.crowd.step(0.05)
	var shell = Arms.Shell.new()
	shell.w = 2
	shell.pos = Vector3(p0.x, 0.0, p0.y)
	shell.range = 1800.0
	ctx4.arms._impact(shell)
	_check(ctx4.score.st["kills"] == 6 and ctx4.score.st["max_kills_shell"] == 6 and ctx4.score.chain == 6,
			"un obus de 105 mm qui tue 6 infectés les compte dans le score (%d éliminations, série %d)" % [ctx4.score.st["kills"], ctx4.score.chain])
	_check(ctx4.score.st["shells_hit"] == 1 and ctx4.score.st["max_kill_range"] >= 1800.0 - 0.1, "portée de la meilleure élimination : %.0f m" % ctx4.score.st["max_kill_range"])


# ---------------------------------------------------------------- objectifs

func _obj_world(defs: Array, seed_v: int = 1914):
	var ctx = _make_world(seed_v)
	ctx.objectives.setup(ctx, defs)
	ctx.director.start()
	return ctx


## Fait avancer le directeur (et donc les objectifs) de `secs` secondes, sans la foule ni les immeubles.
func _obj_run(ctx, secs: float) -> void:
	for i in int(secs / 0.25):
		ctx.time += 0.25
		ctx.director.step(0.25)


func _radio_said(ctx, needle: String) -> bool:
	for r in ctx.radio_log:
		if str(r[0]).contains(needle):
			return true
	return false


## Clés de la banque de voix attendues par le script radio (même règle que tools/audio/make_voices.py).
func _bank_keys(radio: Dictionary) -> Array:
	var keys: Array = []
	var slots: Dictionary = radio["slots"]
	for ev in radio["events"].values():
		for variant in ev["variants"]:
			for line in variant:
				for a in line["say"]:
					var s: String = a
					if s.begins_with("{") and s.ends_with("}"):
						var nm := s.substr(1, s.length() - 2)
						var sl: Dictionary = slots[nm]
						if sl.has("values"):
							for i in sl["values"].size():
								keys.append("%s|{%s}=%d" % [line["who"], nm, i])
						else:
							var r: Array = sl["range"]
							var v := int(r[0])
							while v <= int(r[1]):
								keys.append("%s|{%s}=%d" % [line["who"], nm, v])
								v += int(r[2])
					else:
						keys.append("%s|%s" % [line["who"], s.split("|")[0]])
	return keys


func _slot_ok(radio: Dictionary, slot: String, v: int) -> bool:
	var r: Array = radio["slots"][slot]["range"]
	return v >= int(r[0]) and v <= int(r[1]) and (v - int(r[0])) % int(r[2]) == 0


## Défauts des objectifs d'une mission : identifiants, types, valeurs que la radio sait annoncer, échéances dans la nuit.
func _objective_problems(m: Dictionary, radio: Dictionary) -> Array:
	var ids := {}
	var bad: Array = []
	for d in m["objectives"]:
		if ids.has(d["id"]):
			bad.append("id en double " + str(d["id"]))
		ids[d["id"]] = true
		var ty: String = d["type"]
		if d["kind"] == "hidden":
			if not Objectives.HIDDEN_TYPES.has(ty) or not d.has("value"):
				bad.append("caché invalide " + str(d["id"]))
			continue
		if not Objectives.SECONDARY_TYPES.has(ty) or not d.has("t") or not d.has("duration") or not d.has("reward"):
			bad.append("secondaire invalide " + str(d["id"]))
			continue
		if float(d["t"]) + float(d["duration"]) > float(m.get("duration_s", 420.0)):
			bad.append("échéance après l'aube " + str(d["id"]))
		if not _slot_ok(radio, "secs", int(d["duration"])):
			bad.append("durée non lisible à la radio " + str(d["id"]))
		if ty == "hold" and not _slot_ok(radio, "hold", int(d["duration"])):
			bad.append("durée « tenir » non lisible " + str(d["id"]))
		if ty == "evac" and not _slot_ok(radio, "civs", int(d["count"])):
			bad.append("effectif civils non lisible " + str(d["id"]))
		if ty == "hunt" and not _slot_ok(radio, "hunt_n", int(d["count"])):
			bad.append("effectif chasse non lisible " + str(d["id"]))
		if ty == "intercept" and not _slot_ok(radio, "grp_n", int(d["count"])):
			bad.append("effectif groupe non lisible " + str(d["id"]))
		if not radio["events"].has("obj_" + ty):
			bad.append("pas de réplique radio pour " + ty)
	return bad


func _test_objectives() -> void:
	print("# objectifs")
	# --- cohérence des données
	var m: Dictionary = _json("res://data/mission_01.json")
	var radio: Dictionary = _json("res://data/radio_script.json")
	var bad: Array = _objective_problems(m, radio)
	var n_sec := 0
	var n_hid := 0
	for d in m["objectives"]:
		if d["kind"] == "hidden":
			n_hid += 1
		else:
			n_sec += 1
	_check(bad.is_empty(), "mission 1 : %d objectifs secondaires et %d cachés valides, annonçables par la radio %s" % [n_sec, n_hid, str(bad)])
	var need_ev := ["obj_done", "obj_failed", "obj_hidden", "obj_time30", "obj_time10", "obj_reinforce"]
	var miss_ev: Array = need_ev.filter(func(e): return not radio["events"].has(e))
	_check(miss_ev.is_empty(), "événements radio de suivi présents %s" % str(miss_ev))
	var bank: Dictionary = _json("res://audio/radio/voices.json")["clips"]
	var absent: Array = _bank_keys(radio).filter(func(k): return not bank.has(k))
	_check(absent.is_empty(), "la banque de voix contient toutes les phrases du script (%d manquantes) %s" % [absent.size(), str(absent.slice(0, 4))])

	# --- chasse : réussite, échec, récompense
	var hunt := {"id": "h", "kind": "secondary", "type": "hunt", "t": 0, "duration": 30, "count": 5, "title": "Chasse", "reward": {"points": 111}}
	var c1 = _obj_world([hunt])
	_obj_run(c1, 1.0)
	var it1: Dictionary = c1.objectives.get_item("h")
	_check(it1["state"] == "active" and _radio_said(c1, "nouvel objectif"), "la chasse est annoncée à la date prévue")
	var p_before: int = c1.score.points
	c1.director.zombie_killed(5)
	_obj_run(c1, 0.5)
	_check(it1["state"] == "done" and c1.objectives.is_done("h") and c1.score.points >= p_before + 111,
			"5 éliminations : chasse accomplie, +111 points (%d -> %d)" % [p_before, c1.score.points])
	_check(c1.score.st["objectives"] == 1 and c1.score.st["obj_points"] == 111 and _radio_said(c1, "objectif accompli"), "récompense comptée à part et annoncée")
	var c1b = _obj_world([hunt])
	_obj_run(c1b, 1.0)
	c1b.director.zombie_killed(3)
	_obj_run(c1b, 31.0)
	_check(c1b.objectives.get_item("h")["state"] == "failed" and not c1b.objectives.is_done("h") and c1b.score.st["objectives"] == 0,
			"échéance dépassée avec 3 éliminations sur 5 : objectif perdu, aucune récompense")

	# --- au plus deux objectifs en même temps ; le suivant démarre quand une place se libère
	var trio: Array = []
	for i in 3:
		trio.append({"id": "q%d" % i, "kind": "secondary", "type": "hunt", "t": 0, "duration": 60, "count": 5, "title": "Q%d" % i, "reward": {"points": 10}})
	var c2 = _obj_world(trio)
	_obj_run(c2, 1.0)
	_check(c2.objectives.count_active() == 2 and c2.objectives.get_item("q2")["state"] == "waiting", "deux objectifs actifs au plus, le troisième attend")
	c2.director.zombie_killed(5)
	_obj_run(c2, 1.0)
	_check(c2.objectives.get_item("q2")["state"] == "active", "dès qu'une place se libère, l'objectif suivant est annoncé")

	# --- évacuation
	var evac := {"id": "e", "kind": "secondary", "type": "evac", "t": 0, "duration": 60, "count": 2, "min_occ": 3, "zombies": 1, "radius": 1200, "min_aim": 0, "title": "Évacuer", "reward": {"points": 222}}
	var c3 = _obj_world([evac])
	_obj_run(c3, 1.0)
	var it3: Dictionary = c3.objectives.get_item("e")
	var b3: int = it3["b"]
	_check(it3["state"] == "active" and b3 >= 0 and c3.buildings.zin[b3] >= 1 and it3["has_pos"], "évacuation : un immeuble est infesté et repéré (immeuble %d, %d occupants)" % [b3, c3.buildings.occ[b3]])
	c3.director.civilian_saved(1)
	_obj_run(c3, 0.5)
	_check(it3["state"] == "active" and absf(float(it3["progress"]) - 0.5) < 0.01, "1 civil sauvé sur 2 : avancement 50 %")
	c3.director.civilian_saved(1)
	_obj_run(c3, 0.5)
	_check(it3["state"] == "done", "2 civils sauvés : évacuation accomplie")
	var c3b = _obj_world([evac])
	_obj_run(c3b, 1.0)
	c3b.buildings.occ[c3b.objectives.get_item("e")["b"]] = 0
	_obj_run(c3b, 0.5)
	_check(c3b.objectives.get_item("e")["state"] == "failed", "plus assez de civils à sauver : échec immédiat (%s)" % c3b.objectives.get_item("e")["why"])

	# --- tenir un immeuble
	var hold := {"id": "t", "kind": "secondary", "type": "hold", "t": 0, "duration": 40, "radius": 1200, "min_occ": 3, "min_aim": 0, "zombies": 3,
			"progress": 0.1, "reinforce": [{"at": 10, "zombies": 2}], "title": "Tenir", "reward": {"points": 333}}
	var c4 = _obj_world([hold])
	_obj_run(c4, 1.0)
	var it4: Dictionary = c4.objectives.get_item("t")
	var b4: int = it4["b"]
	var att0 := _attackers(c4, b4)
	_check(it4["state"] == "active" and att0 >= 1 and c4.buildings.siege[b4] > 0.0, "tenir : %d assaillants en route sur l'immeuble %d, porte entamée" % [att0, b4])
	_obj_run(c4, 10.0)
	var att1 := _attackers(c4, b4)
	_check(att1 == att0 + 2 and _radio_said(c4, "nouveaux infectés"), "renfort à 10 s : %d -> %d assaillants, annoncé" % [att0, att1])
	_kill_attackers(c4, b4)
	_obj_run(c4, 31.0)
	_check(it4["state"] == "done" and c4.score.st["obj_points"] == 333, "assaillants abattus et délai tenu : objectif accompli")
	var c4b = _obj_world([hold])
	_obj_run(c4b, 1.0)
	c4b.buildings.zin[c4b.objectives.get_item("t")["b"]] = 1
	_obj_run(c4b, 0.5)
	_check(c4b.objectives.get_item("t")["state"] == "failed", "un infecté entre dans l'immeuble : objectif perdu")
	var c4c = _obj_world([hold])
	_obj_run(c4c, 1.0)
	c4c.buildings.destroy(c4c.objectives.get_item("t")["b"])
	_obj_run(c4c, 0.5)
	_check(c4c.objectives.get_item("t")["state"] == "failed", "immeuble détruit : objectif perdu")

	# --- interception d'un groupe
	var icp := {"id": "i", "kind": "secondary", "type": "intercept", "t": 0, "duration": 60, "count": 8, "allow": 1, "radius": 120, "r_min": 100, "r_max": 1200,
			"title": "Intercepter", "reward": {"points": 444}}
	var c5 = _obj_world([icp])
	_obj_run(c5, 1.0)
	var it5: Dictionary = c5.objectives.get_item("i")
	var tagged := _tagged(c5, int(it5["tag"]))
	_check(it5["state"] == "active" and it5["total"] == 8 and tagged == 8 and it5["has_pos"], "interception : groupe de %d infectés marqués" % tagged)
	_kill_tagged(c5, int(it5["tag"]))
	_obj_run(c5, 0.5)
	_check(it5["state"] == "done" and c5.score.st["obj_points"] == 444, "groupe anéanti : objectif accompli")
	var c5b = _obj_world([icp])
	_obj_run(c5b, 1.0)
	var tg5: int = c5b.objectives.get_item("i")["tag"]
	c5b.objectives.on_entered(tg5)
	_obj_run(c5b, 0.5)
	var still_active: bool = c5b.objectives.get_item("i")["state"] == "active"
	c5b.objectives.on_entered(tg5)
	_obj_run(c5b, 0.5)
	_check(still_active and c5b.objectives.get_item("i")["state"] == "failed", "un infecté entré est toléré, le second fait échouer l'objectif")

	# --- objectifs cachés
	var hid: Array = [
		{"id": "x1", "kind": "hidden", "type": "shell_kills", "value": 8, "title": "Tir groupé", "reward": {"points": 10}},
		{"id": "x2", "kind": "hidden", "type": "long_shot", "value": 3000, "title": "Tir lointain", "reward": {"points": 20}},
		{"id": "x3", "kind": "hidden", "type": "chain", "value": 60, "title": "Série", "reward": {"points": 30}},
		{"id": "x4", "kind": "hidden", "type": "clean_run", "value": 20, "title": "Sans bavure", "reward": {"points": 40}},
		{"id": "x5", "kind": "hidden", "type": "sharp", "value": 6, "title": "Au but", "reward": {"points": 50}},
	]
	var c6 = _obj_world(hid)
	_obj_run(c6, 5.0)
	_check(c6.objectives.count_done("hidden") == 0 and c6.objectives.panel_items().is_empty(), "les objectifs cachés restent invisibles tant qu'ils ne sont pas accomplis")
	c6.score.st["max_kills_shell"] = 8
	c6.score.st["max_kill_range"] = 3050.0
	c6.score.st["clean_best"] = 60
	c6.score.st["hit_streak_best"] = 6
	_obj_run(c6, 1.0)
	_check(c6.objectives.is_done("x1") and c6.objectives.is_done("x2") and c6.objectives.is_done("x3") and c6.objectives.is_done("x5")
			and not c6.objectives.is_done("x4"), "tir groupé, tir lointain, série et obus au but sont révélés ; « sans bavure » attend ses 20 s")
	_obj_run(c6, 16.0)
	_check(c6.objectives.is_done("x4") and c6.score.st["obj_points"] == 150 and c6.objectives.active_toasts().size() >= 1 and _radio_said(c6, "bonus"),
			"sans bavure après 20 s : 150 points de récompenses cachées en tout, annoncés (%d)" % c6.score.st["obj_points"])
	var c6b = _obj_world([hid[3]])
	_obj_run(c6b, 10.0)
	c6b.director.civilian_lost(1, "collateral")
	_obj_run(c6b, 15.0)
	var early: bool = c6b.objectives.is_done("x4")
	_obj_run(c6b, 8.0)
	_check(not early and c6b.objectives.is_done("x4"), "une victime collatérale relance le compte des secondes sans bavure")

	# --- série d'obus lourds au but (score)
	var c7 = _make_world(1914)
	for i in 4:
		c7.score.begin_shell(2, 1500.0)
		c7.score.end_shell(1)
	c7.score.begin_shell(2, 1500.0)
	c7.score.end_shell(0)
	c7.score.begin_shell(1, 1500.0)
	c7.score.end_shell(2)
	c7.score.begin_shell(0, 1500.0)
	c7.score.end_shell(0)
	_check(c7.score.st["hit_streak_best"] == 4 and c7.score.st["hit_streak"] == 1, "série d'obus au but : meilleure %d, en cours %d (le 25 mm ne compte pas)" % [c7.score.st["hit_streak_best"], c7.score.st["hit_streak"]])

	# --- bilan de fin
	var c8 = _obj_world([hunt, hid[0]])
	_obj_run(c8, 1.0)
	c8.director.zombie_killed(5)
	c8.score.st["max_kills_shell"] = 9
	_obj_run(c8, 1.0)
	c8.director.lost = 12
	c8.director.t = 200.0
	c8.director.state = "won"
	c8.director.end_reason = "test"
	var r8: Dictionary = c8.score.finish(true)
	var first_bonus: Array = r8["bonuses"][0]
	_check(str(first_bonus[0]).begins_with("Objectifs accomplis (2)") and int(first_bonus[1]) == 121 and r8["objectives"]["done"] == 2
			and r8["objectives"]["secondary"].size() == 1 and r8["objectives"]["hidden"].size() == 1, "le bilan détaille les objectifs : %s" % str(first_bonus))
	var sum := int(r8["subtotal"])
	for b in r8["bonuses"]:
		sum += int(b[1])
	_check(sum == r8["total"], "sous-total + lignes de bonus = total (%d)" % r8["total"])
	var ctx9 = _obj_world([hunt])
	_obj_run(ctx9, 1.0)
	ctx9.director._end("lost", "test", "end_lost")
	_check(ctx9.objectives.get_item("h")["state"] == "failed", "fin de mission : l'objectif en cours est abandonné")


func _attackers(ctx, b: int) -> int:
	var n := 0
	for i in ctx.crowd.MAX_P:
		var p = ctx.crowd.pool[i]
		if p.alive and p.kind == 0 and p.target_b == b and p.mode == 1:
			n += 1
	return n


func _kill_attackers(ctx, b: int) -> void:
	for i in ctx.crowd.MAX_P:
		var p = ctx.crowd.pool[i]
		if p.alive and p.kind == 0 and p.target_b == b:
			ctx.crowd.damage_area(p.pos.x, p.pos.y, 2.0, 9999.0, 0.0)


func _tagged(ctx, tag: int) -> int:
	var n := 0
	for i in ctx.crowd.MAX_P:
		var p = ctx.crowd.pool[i]
		if p.alive and p.kind == 0 and p.tag == tag:
			n += 1
	return n


func _kill_tagged(ctx, tag: int) -> void:
	for i in ctx.crowd.MAX_P:
		var p = ctx.crowd.pool[i]
		if p.alive and p.kind == 0 and p.tag == tag:
			ctx.crowd.damage_area(p.pos.x, p.pos.y, 0.5, 9999.0, 0.0)



# ---------------------------------------------------------------- progression : données, profil, atelier

const KNOWN_MODS := ["predict", "zoom_max", "laser", "door_hp", "civ_speed", "obj_time_s", "chain_keep", "xp_bonus", "credit_bonus",
		"sup_barrage", "sup_drone", "sup_decoy", "sup_drop"]


func _new_profile(path: String = ""):
	var d = Defs.load_all()
	var p = Profile.new()
	p.setup(d, path)
	return p


## Résultat de fin de mission fabriqué à la main (même forme que Score.finish).
func _fake_result(over: Dictionary = {}) -> Dictionary:
	var res := {
		"won": true, "reason": "test", "subtotal": 6000, "bonuses": [], "total": 6500, "rating": "B", "rating_next": "A", "rating_missing": 2000,
		"stars": [{"text": "a", "ok": true, "gap": ""}, {"text": "b", "ok": false, "gap": "x"}, {"text": "c", "ok": false, "gap": "y"}], "n_stars": 1,
		"accuracy": 0.5, "lost": 20, "max_lost": 50, "eaten": 10, "collateral": 10, "saved": 8, "kills": 120, "destroyed": 6, "time": 420.0,
		"stats": {"kills_w": [80, 30, 10], "shells_w": [0, 40, 20], "hits_w": [0, 20, 10], "chain_best": 25, "clean_best": 25,
				"max_kills_shell": 5, "max_kill_range": 2600.0, "hit_streak_best": 4, "protected": 100},
		"objectives": {"secondary": [{"ok": true}, {"ok": true}, {"ok": false}], "hidden": [{"found": true}, {"found": false}], "done": 2, "points": 900},
	}
	res.merge(over, true)
	return res


func _test_progression_data() -> void:
	print("# progression : données")
	var d = Defs.load_all()
	_check(d.ok(), "les fichiers de progression et de campagne se chargent (%s)" % d.error)
	# grades
	var g: Array = d.grades
	var inc := g.size() == 10 and int(g[0]["xp"]) == 0
	for i in range(1, g.size()):
		if int(g[i]["xp"]) <= int(g[i - 1]["xp"]):
			inc = false
	_check(inc, "10 grades, de Sergent à Colonel, aux seuils d'XP croissants")
	_check(str(g[0]["name"]) == "Sergent" and str(g[g.size() - 1]["name"]) == "Colonel", "premier grade Sergent, dernier Colonel")
	# atelier
	var weapons: Array = _json("res://data/weapons.json")["weapons"]
	var cats := {}
	for c in d.up_cats:
		cats[str(c["id"])] = true
	var bad := 0
	var n_levels := 0
	var ids := {}
	for it in d.up_items:
		var id := str(it["id"])
		if ids.has(id) or not cats.has(str(it["cat"])) or (it["levels"] as Array).is_empty():
			bad += 1
			continue
		ids[id] = true
		var prev_cost := 0
		var prev_grade := 0
		for lv in it["levels"]:
			n_levels += 1
			if int(lv["cost"]) <= prev_cost or int(lv["grade"]) < prev_grade or int(lv["grade"]) >= g.size() or str(lv["desc"]) == "":
				bad += 1
			prev_cost = int(lv["cost"])
			prev_grade = int(lv["grade"])
			for k in lv["effects"].keys():
				var key := str(k)
				if key.begins_with("mod."):
					if not KNOWN_MODS.has(key.substr(4)):
						bad += 1
				else:
					var dot := key.find(".")
					var wsel := key.substr(1, dot - 1)
					var stat := key.substr(dot + 1)
					var wi := -1 if wsel == "*" else int(wsel)
					if not key.begins_with("w") or dot < 0 or wi >= weapons.size() or not (weapons[0 if wi < 0 else wi] as Dictionary).has(stat):
						bad += 1
	_check(bad == 0, "atelier : %d améliorations, %d niveaux, coûts croissants, effets reconnus (%d anomalies)" % [d.up_items.size(), n_levels, bad])
	_check(d.up_items.size() >= 20, "l'atelier propose au moins 20 améliorations")
	var per_cat := {}
	for it in d.up_items:
		per_cat[str(it["cat"])] = int(per_cat.get(str(it["cat"]), 0)) + 1
	_check(per_cat.size() == d.up_cats.size() and int(per_cat.get("sensor", 0)) >= 3, "toutes les catégories sont garnies (capteurs : %d)" % int(per_cat.get("sensor", 0)))
	# médailles
	var facts := Profile.mission_facts(_fake_result())
	facts.merge(_new_profile().career_facts())
	var mbad := 0
	var mids := {}
	for m in d.medal_list:
		if mids.has(str(m["id"])) or not d.tiers.has(str(m["tier"])) or (m["cond"] as Array).is_empty():
			mbad += 1
		mids[str(m["id"])] = true
		for c in m["cond"]:
			if not facts.has(str(c[0])) or not [">=", "<=", "=="].has(str(c[1])):
				mbad += 1
				print("     condition inconnue : ", m["id"], " ", c)
	_check(mbad == 0, "médailles : %d, identifiants uniques, paliers et conditions reconnus (%d anomalies)" % [d.medal_list.size(), mbad])
	_check(d.medal_list.size() >= 30 and d.medal_list.size() <= 70, "entre 30 et 70 médailles (%d)" % d.medal_list.size())
	var tiers_n := {}
	for m in d.medal_list:
		tiers_n[str(m["tier"])] = int(tiers_n.get(str(m["tier"]), 0)) + 1
	print("   paliers : ", tiers_n)
	# cosmétiques
	var cbad := 0
	var ncos := 0
	var seen := {}
	for sl in d.slots:
		var sid := str(sl["id"])
		var defaults := 0
		for c in d.cos_items[sid]:
			ncos += 1
			if seen.has(str(c["id"])):
				cbad += 1
			seen[str(c["id"])] = true
			var u: Dictionary = c["unlock"]
			if u.has("default"):
				defaults += 1
			if u.has("medal") and not mids.has(str(u["medal"])):
				cbad += 1
			if u.has("grade") and int(u["grade"]) >= g.size():
				cbad += 1
			if sid == "insignia":
				if (c["shape"] as Array).is_empty():
					cbad += 1
				for pr in c["shape"]:
					if not ["poly", "line", "circle", "arc"].has(str(pr["t"])):
						cbad += 1
			if sid == "filter" and ((c["tint"] as Array).size() != 3 or (c["zombie"] as Array).size() != 3 or (c["civil"] as Array).size() != 3):
				cbad += 1
		if defaults != 1:
			cbad += 1
	_check(cbad == 0, "cosmétiques : %d éléments dans %d emplacements, un seul par défaut, déblocages valides (%d anomalies)" % [ncos, d.slots.size(), cbad])
	# toute médaille citée par un cosmétique existe ; chaque insigne de médaille est atteignable
	var eq: Dictionary = d.default_equipped()
	_check(eq.size() == d.slots.size(), "un cosmétique par défaut dans chaque emplacement : %s" % str(eq))


func _test_profile() -> void:
	print("# profil du joueur")
	var p = _new_profile()
	_check(p.grade_index() == 0 and p.grade_name() == "Sergent" and p.xp == 0 and p.credits == 0, "profil neuf : Sergent, 0 XP, 0 crédit")
	p.xp = 999
	_check(p.grade_index() == 0 and p.grade_progress() == Vector2i(999, 1000), "999 XP : encore Sergent (999 / 1000)")
	p.xp = 1000
	_check(p.grade_index() == 1 and p.grade_name() == "Sergent-chef", "1 000 XP : Sergent-chef")
	p.xp = 999999
	_check(p.grade_index() == 9 and p.grade_progress().y == 0, "XP énorme : Colonel, plus de grade suivant")

	# sauvegarde et rechargement
	var path := "user://pnc_test_profile.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var q = _new_profile(path)
	q.xp = 3000
	q.credits = 777
	q.grade_paid = q.grade_index()
	q.upgrades = {"g25_ammo": 2, "sen_zoom": 1}
	q.medals = {"first_win": {"n": 1}}
	q.owned = ["flt_amber"]
	q.equipped["filter"] = "flt_amber"
	q.stats["kills"] = 321
	q.missions = {"mission_01": {"plays": 3, "wins": 2, "best_score": 7000, "best_rating": 2, "stars_done": [true, false, true], "best_stars": 2, "best_diff": 1}}
	q.settings = {"sector": "mission_02", "difficulty": "nightmare"}
	q.stats["nm_wins"] = 2
	_check(q.save() and FileAccess.file_exists(path), "sauvegarde écrite")
	_check(not FileAccess.file_exists(path + ".tmp"), "pas de fichier temporaire oublié (écriture atomique)")
	var r = _new_profile(path)
	_check(r.load_file(), "rechargement")
	_check(r.xp == 3000 and r.credits == 777 and r.level("g25_ammo") == 2 and r.level("sen_zoom") == 1, "XP, crédits et améliorations conservés")
	_check(r.has_medal("first_win") and r.owned == ["flt_amber"] and r.equipped["filter"] == "flt_amber", "médailles, achats et équipement conservés")
	_check(int(r.stats["kills"]) == 321 and int(r.missions["mission_01"]["best_stars"]) == 2 and r.missions["mission_01"]["stars_done"] == [true, false, true], "statistiques et fiche de mission conservées")
	_check(JSON.stringify(r.to_dict()) == JSON.stringify(q.to_dict()), "aller-retour identique")
	_check(r.settings == {"sector": "mission_02", "difficulty": "nightmare"} and int(r.missions["mission_01"]["best_diff"]) == 1 and int(r.stats["nm_wins"]) == 2,
			"secteur et difficulté choisis, record par difficulté et victoires Cauchemar conservés")

	# données hors catalogue ou triées sur le volet : ignorées
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "xp": -50, "credits": 10, "upgrades": {"g25_ammo": 99, "inconnue": 3, "sen_zoom": -4},
			"medals": {"medaille_inconnue": {"n": 1}, "first_win": {"n": 2}}, "owned": ["cosmetique_inconnu", "flt_amber"],
			"equipped": {"filter": "flt_violet", "reticle": "flt_amber"}}))
	f.close()
	var u = _new_profile(path)
	_check(u.load_file() and u.xp == 0 and u.level("g25_ammo") == u.max_level("g25_ammo") and u.level("inconnue") == 0 and u.level("sen_zoom") == 0,
			"fichier trafiqué : XP négative ramenée à 0, niveau plafonné, identifiant inconnu écarté")
	_check(not u.has_medal("medaille_inconnue") and u.has_medal("first_win") and u.owned == ["flt_amber"], "médaille et cosmétique inconnus écartés")
	_check(u.equipped["filter"] == "flt_white" and u.equipped["reticle"] == "ret_classic", "équipement verrouillé ou mal placé : retour au défaut")

	# fichier corrompu : mis de côté, profil neuf
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{ ceci n'est pas du json")
	f.close()
	var c = _new_profile(path)
	var ok: bool = c.load_file()
	_check(not ok and c.load_error != "" and c.xp == 0 and FileAccess.file_exists(path + ".bad"), "fichier corrompu : copie .bad, profil neuf (« %s »)" % c.load_error)
	var none = _new_profile("user://pnc_n_existe_pas.json")
	_check(not none.load_file() and none.load_error == "", "pas de fichier : profil neuf, sans erreur")
	var mem = _new_profile("")
	_check(mem.save() and mem.path == "", "profil en mémoire : save() sans effet")
	for ext in ["", ".bad", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ext))

	# fin de mission : XP, crédits, médailles, étoiles, records
	var a = _new_profile()
	var rep: Dictionary = a.apply_mission(_fake_result(), "mission_01")
	var xl: Array = rep["xp_lines"]
	var sum := 0
	for l in xl:
		sum += int(l[1])
	_check(sum == rep["xp_gain"] - rep["medal_xp"] and a.xp == rep["xp_after"] and rep["xp_after"] - rep["xp_before"] == rep["xp_gain"], "les lignes d'XP additionnent le gain (%d XP, dont %d de médailles)" % [rep["xp_gain"], rep["medal_xp"]])
	print("   lignes d'XP : ", xl)
	_check(a.credits == rep["credits_gain"], "les crédits gagnés sont ceux du rapport (%d)" % a.credits)
	var got := []
	for m in rep["medals"]:
		got.append(m[0])
	_check(got.has("first_night") and got.has("first_win") and got.has("kills_100") and got.has("obj_first") and got.has("hidden_first") and got.has("rate_b"),
			"médailles d'un premier succès : %s" % str(got))
	_check(not got.has("rate_a") and not got.has("kills_200") and not got.has("win_5"), "pas de médaille que la mission n'a pas méritée")
	_check(rep["new_stars"] == 1 and rep["new_rating"] and rep["record"], "première étoile, première note, premier record")
	var xp1: int = a.xp
	var cr1: int = a.credits
	var rep2: Dictionary = a.apply_mission(_fake_result(), "mission_01")
	_check(rep2["new_stars"] == 0 and not rep2["new_rating"] and not rep2["record"] and rep2["medals"].is_empty(), "même résultat rejoué : ni étoile, ni note, ni médaille en double")
	_check(a.xp - xp1 < rep["xp_gain"] and a.credits - cr1 < rep["credits_gain"], "… et donc un gain moindre (%d XP au lieu de %d)" % [a.xp - xp1, rep["xp_gain"]])
	_check(int(a.stats["missions"]) == 2 and int(a.stats["wins"]) == 2 and int(a.stats["kills"]) == 240, "statistiques de carrière cumulées")

	# défaite : fraction de l'XP, pas d'étoile ni de note
	var b = _new_profile()
	var lost: Dictionary = _fake_result({"won": false, "rating": "—", "n_stars": 0, "total": 2000})
	var repl: Dictionary = b.apply_mission(lost, "mission_01")
	var has_loss := false
	for l in repl["xp_lines"]:
		if str(l[0]) == "Mission perdue" and int(l[1]) < 0:
			has_loss = true
	_check(has_loss and repl["new_stars"] == 0 and not repl["new_rating"], "défaite : ligne « Mission perdue » négative, aucune étoile ni note")
	_check(b.xp > 0 and b.xp < 600, "… mais on garde une partie de l'XP (%d)" % b.xp)
	_check(not b.has_medal("first_win") and b.has_medal("first_night"), "défaite : médaille de participation seulement")
	# difficulté
	var e1 = _new_profile()
	var e2 = _new_profile()
	e1.apply_mission(_fake_result(), "m")
	e2.apply_mission(_fake_result(), "m", 1.5)
	_check(e2.xp > e1.xp, "difficulté ×1,5 : plus d'XP (%d contre %d)" % [e2.xp, e1.xp])

	# promotion : prime versée une seule fois, médaille de grade obtenue dans la foulée
	var h = _new_profile()
	h.xp = 2500
	h.grade_paid = h.grade_index()
	var cr0: int = h.credits
	var rh: Dictionary = h.apply_mission(_fake_result(), "m")
	_check(rh["grade_before"] == 1 and rh["grade_after"] >= 2 and rh["promotions"].size() >= 1, "passage de Sergent-chef à %s" % h.grade_name())
	var prime_expected := 0
	for gi in rh["promotions"]:
		prime_expected += int(h.defs.grades[gi]["credits"])
	_check(rh["promo_credits"] == prime_expected and prime_expected > 0, "prime de promotion versée (%d crédits)" % prime_expected)
	var rh2: Dictionary = h.apply_mission(_fake_result(), "m")
	var twice := false
	for gi in rh2["promotions"]:
		if gi <= rh["grade_after"]:
			twice = true
	_check(not twice and h.grade_paid == h.grade_index(), "pas de seconde prime pour un grade déjà payé (grade %d, promotions suivantes : %s)" % [rh["grade_after"], str(rh2["promotions"])])
	var has_adj := false
	for m in rh["medals"]:
		if m[0] == "grade_adj":
			has_adj = true
	_check(has_adj, "la médaille « Gradé » arrive avec la promotion à Adjudant")
	# bonus Mentor / Intendant
	var k1 = _new_profile()
	var k2 = _new_profile()
	k2.upgrades = {"crew_xp": 3, "crew_credit": 3}
	k1.apply_mission(_fake_result(), "m")
	k2.apply_mission(_fake_result(), "m")
	_check(k2.xp > k1.xp and k2.credits > k1.credits, "Mentor et Intendant augmentent l'XP (%d > %d) et les crédits (%d > %d)" % [k2.xp, k1.xp, k2.credits, k1.credits])


# ---------------------------------------------------------------- campagne

const WAVE_KINDS := ["streets", "assault", "breach", "metro", "special"]
const SPECIAL_KINDS := ["colossus", "screamer", "alpha"]
const STAR_KINDS := ["win", "lost_max", "collateral_max", "destroyed_max", "kills_min", "saved_min", "score_min", "rating_min", "objective", "objectives_min"]


## Défauts d'une mission de la campagne : ville, vagues, étoiles, seuils de notes, objectifs.
func _mission_problems(m: Dictionary, radio: Dictionary, tag: String) -> Array:
	var bad: Array = []
	var c: Dictionary = m.get("city", {})
	if not c.has("seed") or not c.has("size") or not CityGen.style_names().has(str(c.get("style", ""))):
		bad.append("%s : ville mal décrite" % tag)
		return bad
	var has_metro := int(CityGen.STYLES[str(c["style"])].get("metro", CityGen.STYLE_DEFAULT["metro"])) > 0
	if str(c.get("file", "")) != "":                  # ville réelle : ses bouches de métro sont dans son fichier
		var cj = _json("res://data/cities/%s.json" % str(c["file"]))
		has_metro = cj != null and (cj.get("metro_nodes", []) as Array).size() > 0
	var dur := float(m.get("duration_s", 0.0))
	if dur < 300.0 or int(m.get("max_civilians_lost", 0)) < 1 or int(m.get("start_zombies", -1)) < 0:
		bad.append("%s : durée ou seuils" % tag)
	var last := -1.0
	var events := {"streets": "new_group", "assault": "assault", "breach": "breach", "metro": "new_group_metro"}
	for w in m["waves"]:
		var ty := str(w.get("type", "streets"))
		if not WAVE_KINDS.has(ty):
			bad.append("%s : vague inconnue %s" % [tag, ty])
			continue
		if int(w.get("min_level", 0)) < 0 or int(w.get("min_level", 0)) > 2:
			bad.append("%s : niveau minimal de vague invalide (%s)" % [tag, str(w.get("min_level"))])
		if float(w["t"]) < last or float(w["t"]) > dur - 20.0:
			bad.append("%s : vague mal datée (%s)" % [tag, str(w["t"])])
		last = float(w["t"])
		if ty == "metro" and not has_metro:
			bad.append("%s : vague métro dans une ville sans métro" % tag)
		if ty == "assault" and int(w.get("zombies", 0)) < 2:
			bad.append("%s : assaut trop faible" % tag)
		if (ty == "streets" or ty == "metro") and int(w.get("count", 0)) < 3:
			bad.append("%s : groupe trop petit" % tag)
		if ty == "special":
			var zt := str(w.get("zt", ""))
			if not SPECIAL_KINDS.has(zt) or int(w.get("count", 0)) < 1 or int(w.get("count", 0)) > 3 or float(w.get("r_min", 300.0)) >= float(w.get("r_max", 800.0)):
				bad.append("%s : vague spéciale mal décrite (%s)" % [tag, str(w)])
			elif not radio["events"].has("special_" + zt) or not radio["events"].has(zt + "_down"):
				bad.append("%s : pas de réplique radio pour %s" % [tag, zt])
			continue
		if not radio["events"].has(events[ty]):
			bad.append("%s : pas de réplique radio « %s »" % [tag, events[ty]])
	var stars: Array = m.get("stars", [])
	if stars.size() != 3:
		bad.append("%s : %d étoiles au lieu de 3" % [tag, stars.size()])
	for st in stars:
		if not STAR_KINDS.has(str(st.get("type", ""))) or str(st.get("text", "")) == "":
			bad.append("%s : étoile invalide" % tag)
	var tg: Array = m.get("score_targets", [])
	if tg.size() != 4 or not (float(tg[0]) < float(tg[1]) and float(tg[1]) < float(tg[2]) and float(tg[2]) < float(tg[3])):
		bad.append("%s : seuils de notes" % tag)
	for pb in _objective_problems(m, radio):
		bad.append("%s : %s" % [tag, pb])
	return bad


## Infectés attendus sur toute la nuit : départ + vagues + assauts.
func _zombie_load(m: Dictionary) -> int:
	var n := int(m["start_zombies"])
	for w in m["waves"]:
		match str(w.get("type", "streets")):
			"assault":
				n += int(w["zombies"])
			"breach":
				n += 4 * int(w.get("count", 1))
			"special":
				n += int(w["count"]) * (7 if str(w.get("zt", "")) == "alpha" else 1)
			_:
				n += int(w["count"])
	return n


func _test_campaign() -> void:
	print("# campagne : secteurs, difficultés, déblocage")
	var d = Defs.load_all()
	_check(d.ok() and d.sectors.size() == 5 and d.levels.size() == 3, "%d secteurs et %d niveaux de difficulté se chargent (%s)" % [d.sectors.size(), d.levels.size(), d.error])
	var radio: Dictionary = _json("res://data/radio_script.json")
	var bank: Dictionary = _json("res://audio/radio/voices.json")["clips"]
	var absent: Array = _bank_keys(radio).filter(func(k): return not bank.has(k))
	_check(absent.is_empty(), "la banque de voix couvre tout le script, répliques « métro » comprises (%d manquantes) %s" % [absent.size(), str(absent.slice(0, 4))])
	var bad: Array = []
	var ids := {}
	var prev_unlock := -1
	var n_stars := 0
	for sc in d.sectors:
		var sid := str(sc["id"])
		if ids.has(sid):
			bad.append("secteur en double " + sid)
		ids[sid] = true
		if int(sc["unlock"]) < prev_unlock:
			bad.append("déblocage non croissant " + sid)
		prev_unlock = int(sc["unlock"])
		var mp: Array = sc["map"]
		if mp.size() != 2 or float(mp[0]) < 0.0 or float(mp[0]) > 1.0 or float(mp[1]) < 0.0 or float(mp[1]) > 1.0:
			bad.append("position sur la carte " + sid)
		if str(sc.get("name", "")) == "" or str(sc.get("text", "")) == "" or str(sc.get("tag", "")) == "" or (sc.get("features", []) as Array).is_empty():
			bad.append("textes manquants " + sid)
		var m: Dictionary = Campaign.load_mission(d, sid)
		if m.is_empty() or str(m.get("id", "")) != sid:
			bad.append("mission illisible ou mal nommée " + sid)
			continue
		n_stars += (m["stars"] as Array).size()
		bad.append_array(_mission_problems(m, radio, sid))
		for lv in d.levels:
			bad.append_array(_mission_problems(Campaign.apply_difficulty(m, lv), radio, "%s/%s" % [sid, str(lv["id"])]))
	_check(bad.is_empty(), "5 missions : villes, vagues, étoiles et objectifs valides à chaque difficulté %s" % str(bad.slice(0, 5)))
	_check(int(d.sectors[0]["unlock"]) == 0 and prev_unlock <= n_stars and d.stars_available == n_stars,
			"premier secteur ouvert d'emblée ; le dernier s'ouvre à %d étoiles sur %d possibles" % [prev_unlock, n_stars])

	# --- niveaux de difficulté
	var lv_bad: Array = []
	var prev: Dictionary = {}
	for lv in d.levels:
		for k in ["xp_mult", "credit_mult", "waves", "start", "lost", "hp", "runners", "doors"]:
			if not lv.has(k) or float(lv[k]) <= 0.0:
				lv_bad.append("%s : %s" % [str(lv["id"]), k])
		if not prev.is_empty() and not (float(lv["waves"]) >= float(prev["waves"]) and float(lv["start"]) >= float(prev["start"]) and float(lv["lost"]) <= float(prev["lost"])
				and float(lv["hp"]) >= float(prev["hp"]) and float(lv["doors"]) <= float(prev["doors"]) and float(lv["xp_mult"]) > float(prev["xp_mult"])
				and float(lv["credit_mult"]) > float(prev["credit_mult"])):
			lv_bad.append("niveau non monotone : " + str(lv["id"]))
		prev = lv
	# Cauchemar reprend les effectifs du fichier de mission (×1) ; Recrue et Vétéran les allègent ; « collat » (part des civils tués par nos
	# tirs qui compte dans le seuil de pertes) est dans ]0 ; 1] et ne baisse jamais de Cauchemar vers Recrue
	var nmv: Dictionary = d.level("nightmare")
	for k in ["waves", "start", "lost", "hp", "runners"]:
		if absf(float(nmv[k]) - 1.0) > 0.0001:
			lv_bad.append("Cauchemar n'est pas le réglage plein : " + k)
	var prev_c := 0.0
	for lv in d.levels:
		var cw := float(lv.get("collat", 1.0))
		if cw <= 0.0 or cw > 1.0 or cw < prev_c:
			lv_bad.append("collat : " + str(lv["id"]))
		prev_c = cw
	if absf(float(nmv.get("collat", 1.0)) - 1.0) > 0.0001 or float(d.level("recruit")["collat"]) >= float(d.level("veteran")["collat"]):
		lv_bad.append("collat : Cauchemar compte tout, Recrue moins que Vétéran")
	_check(lv_bad.is_empty() and d.level_by_id.has(d.default_level) and d.level_by_id.has(d.first_level) and d.level("inconnu") == d.level(d.default_level),
			"difficultés : multiplicateurs positifs, croissants de Recrue à Cauchemar, Cauchemar = réglage plein %s" % str(lv_bad))
	_check(bool(d.level("recruit")["impact"]) and bool(d.level("veteran")["impact"]) and not bool(d.level("nightmare")["impact"]),
			"seul le Cauchemar coupe l'indicateur de chute des obus")

	var m1: Dictionary = Campaign.load_mission(d, "mission_01")
	var before := JSON.stringify(m1)
	var vm: Dictionary = Campaign.apply_difficulty(m1, d.level("veteran"))
	var rm: Dictionary = Campaign.apply_difficulty(m1, d.level("recruit"))
	var nm: Dictionary = Campaign.apply_difficulty(m1, d.level("nightmare"))
	_check(JSON.stringify(m1) == before, "la mission d'origine n'est pas modifiée par la difficulté")
	var ncmp: Dictionary = nm.duplicate(true)
	_check(_deep_equal(ncmp["waves"], m1["waves"]) and int(nm["start_zombies"]) == int(m1["start_zombies"]) and int(nm["max_civilians_lost"]) == int(m1["max_civilians_lost"])
			and str(vm["difficulty"]["id"]) == "veteran" and str(nm["difficulty"]["id"]) == "nightmare" and absf(float(nm["collateral_weight"]) - 1.0) < 0.0001
			and float(rm["collateral_weight"]) < float(vm["collateral_weight"]) and float(vm["collateral_weight"]) < 1.0,
			"Cauchemar : vagues, infectés de départ et seuil de pertes du fichier ; dégâts collatéraux comptés en entier, moins en Vétéran, moins encore en Recrue")
	var mono := true
	var detail: Array = []
	for sc in d.sectors:
		var base: Dictionary = Campaign.load_mission(d, str(sc["id"]))
		var a: Dictionary = Campaign.apply_difficulty(base, d.level("recruit"))
		var b: Dictionary = Campaign.apply_difficulty(base, d.level("veteran"))
		var c: Dictionary = Campaign.apply_difficulty(base, d.level("nightmare"))
		var na := _zombie_load(a)
		var nb := _zombie_load(b)
		var nc := _zombie_load(c)
		detail.append("%d<%d<%d" % [na, nb, nc])
		if not (na < nb and nb < nc and int(a["max_civilians_lost"]) > int(b["max_civilians_lost"]) and int(b["max_civilians_lost"]) > int(c["max_civilians_lost"])
				and float(a["rules"]["zombie_hp"]) < float(b["rules"]["zombie_hp"]) and float(b["rules"]["zombie_hp"]) < float(c["rules"]["zombie_hp"])
				and float(a["rules"]["door_hp_min"]) > float(b["rules"]["door_hp_min"]) and float(b["rules"]["door_hp_min"]) > float(c["rules"]["door_hp_min"])
				and float(a["rules"]["runner_ratio"]) < float(b["rules"]["runner_ratio"]) and float(b["rules"]["runner_ratio"]) < float(c["rules"]["runner_ratio"])):
			mono = false
	_check(mono, "chaque secteur : plus d'infectés, plus résistants, plus de coureurs, portes plus fragiles et moins de pertes tolérées de Recrue à Cauchemar (infectés %s)" % str(detail))
	_check(int(rm["max_civilians_lost"]) == 88 and int(vm["max_civilians_lost"]) == 74 and int(nm["max_civilians_lost"]) == 55 and int(m1["max_civilians_lost"]) == 55,
			"quota de pertes du secteur 1 : 88 en Recrue, 74 en Vétéran, 55 en Cauchemar (%d / %d / %d)" % [int(rm["max_civilians_lost"]), int(vm["max_civilians_lost"]), int(nm["max_civilians_lost"])])
	var hunt_ok := true
	for o in nm["objectives"]:
		if o["kind"] == "secondary" and o["type"] == "hunt" and (int(o["count"]) % 5 != 0 or int(o["count"]) < 10 or int(o["count"]) > 40):
			hunt_ok = false
	_check(hunt_ok, "les effectifs de chasse restent des multiples de 5 que la radio sait dire")

	# --- déblocage par les étoiles
	var p = _new_profile()
	_check(Campaign.unlocked_ids(d, p) == ["mission_01"] and Campaign.stars_missing(d, p, "mission_02") == 2 and str(Campaign.next_locked(d, p)["id"]) == "mission_02",
			"profil neuf : seul le Quartier latin est ouvert, il manque 2 étoiles pour Montmartre")
	_check(Campaign.start_level(d, p) == "recruit", "première partie d'un profil neuf : Recrue")
	p.stats["missions"] = 1
	_check(Campaign.start_level(d, p) == "recruit", "une mission jouée mais jamais gagnée : toujours Recrue (le niveau de référence attend la première victoire)")
	p.settings["difficulty"] = "veteran"          # enregistré tout seul au lancement d'une partie, jamais choisi : ne retient pas un débutant
	_check(Campaign.start_level(d, p) == "recruit", "un niveau enregistré par défaut ne compte pas avant la première victoire")
	p.settings["picked"] = true
	_check(Campaign.start_level(d, p) == "veteran", "un niveau choisi par le joueur est repris même sans victoire")
	p.settings.erase("picked")
	p.settings.erase("difficulty")
	p.stats["wins"] = 1
	_check(Campaign.start_level(d, p) == "veteran", "après une victoire : Vétéran par défaut")
	p.settings["difficulty"] = "nightmare"
	_check(Campaign.start_level(d, p) == "nightmare", "après une victoire, la dernière difficulté jouée est reprise")
	p.settings.erase("difficulty")
	p.stats["wins"] = 0
	p.missions["mission_01"] = {"plays": 1, "wins": 1, "best_score": 0, "best_rating": -1, "stars_done": [true, true, false], "best_stars": 2, "best_diff": -1}
	_check(Campaign.total_stars(d, p) == 2 and Campaign.unlocked_ids(d, p) == ["mission_01", "mission_02"], "2 étoiles : Montmartre s'ouvre")
	p.missions["mission_02"] = {"plays": 1, "wins": 1, "best_score": 0, "best_rating": -1, "stars_done": [true, true, true], "best_stars": 3, "best_diff": -1}
	_check(Campaign.unlocked_ids(d, p).size() == 3 and Campaign.stars_missing(d, p, "mission_04") == 2, "5 étoiles : Les Halles s'ouvrent, il en manque 2 pour La Défense")
	p.settings["sector"] = "mission_03"
	_check(Campaign.start_sector(d, p) == "mission_03", "le dernier secteur joué est repris")
	p.settings["sector"] = "mission_05"
	_check(Campaign.start_sector(d, p) == "mission_01", "un secteur encore fermé n'est jamais proposé : retour au premier")
	_check(Campaign.newly_unlocked(d, 1, 4) == ["mission_02", "mission_03"] and Campaign.newly_unlocked(d, 4, 4).is_empty() and Campaign.newly_unlocked(d, 0, 15).size() == 4,
			"secteurs ouverts par un gain d'étoiles")
	_check(not Campaign.is_unlocked(d, p, "inconnu") and Campaign.stars_missing(d, p, "inconnu") == 0, "secteur inconnu : jamais ouvert")

	# --- récompenses et médailles de campagne
	var win3 := _fake_result({"won": true, "n_stars": 3, "diff": 2, "stars": [{"text": "a", "ok": true, "gap": ""}, {"text": "b", "ok": true, "gap": ""}, {"text": "c", "ok": true, "gap": ""}]})
	var q = _new_profile()
	var rq: Dictionary = q.apply_mission(win3, "mission_01", 1.6, 1.4, 2)
	var gm: Array = []
	for m in rq["medals"]:
		gm.append(m[0])
	_check(rq["sectors_unlocked"] == ["mission_02"] and int(rq["stars_total"]) == 3 and int(q.missions["mission_01"]["best_diff"]) == 2 and int(q.stats["nm_wins"]) == 1,
			"victoire à 3 étoiles en Cauchemar : Montmartre s'ouvre, record par difficulté et victoire Cauchemar comptés")
	_check(gm.has("vet_win") and gm.has("nm_win") and not gm.has("sector_2") and not gm.has("sector_all"), "médailles Épreuve du feu et Cauchemar vaincu, mais pas encore Reconnaissance : %s" % str(gm))
	var rq2: Dictionary = q.apply_mission(win3, "mission_02", 1.0, 1.0, 1)
	var gm2: Array = []
	for m in rq2["medals"]:
		gm2.append(m[0])
	_check(gm2.has("sector_2") and rq2["sectors_unlocked"] == ["mission_03"], "deuxième secteur gagné : Reconnaissance, Les Halles s'ouvrent (%s)" % str(gm2))
	var z1 = _new_profile()
	var z2 = _new_profile()
	var rz1: Dictionary = z1.apply_mission(_fake_result(), "mission_01", 1.0, 1.0, 1)
	var rz2: Dictionary = z2.apply_mission(_fake_result(), "mission_01", 1.0, 1.4, 1)
	var has_label := false
	for l in rz2["credits_lines"]:
		if str(l[0]).begins_with("Difficulté"):
			has_label = true
	_check(rz2["credits_gain"] > rz1["credits_gain"] and has_label, "crédits ×1,4 : %d contre %d, ligne « Difficulté » au bilan" % [rz2["credits_gain"], rz1["credits_gain"]])
	var full = _new_profile()
	for k in range(1, 5):
		full.missions["mission_0%d" % k] = {"plays": 1, "wins": 1, "best_score": 1, "best_rating": 1, "stars_done": [true, true, true], "best_stars": 3, "best_diff": 1}
	var rf: Dictionary = full.apply_mission(win3, "mission_05", 1.0, 1.0, 1)
	var gf: Array = []
	for m in rf["medals"]:
		gf.append(m[0])
	_check(gf.has("stars_15") and gf.has("sector_all") and int(rf["stars_total"]) == 15 and full.sector_stars() == d.stars_available,
			"15 étoiles et 5 secteurs gagnés : Ciel étoilé et Tour de Paris (%s)" % str(gf))
	var lost_run = _new_profile()
	var rl: Dictionary = lost_run.apply_mission(_fake_result({"won": false, "n_stars": 0, "diff": 2}), "mission_01", 1.6, 1.4, 2)
	_check(int(lost_run.stats["nm_wins"]) == 0 and int(lost_run.missions["mission_01"]["best_diff"]) == -1, "une défaite en Cauchemar ne compte ni comme victoire ni comme record de difficulté")


## Cartes réelles (data/cities) : format, portes précalculées, réseau connexe, maillages, repères nommés.
func _test_real_cities() -> void:
	print("# cartes réelles de Paris (pnc-city-2)")
	var d = Defs.load_all()
	var expect := {"mission_01": "quartier_latin", "mission_02": "montmartre", "mission_03": "halles", "mission_04": "defense", "mission_05": "stade"}
	for sc in d.sectors:
		var mj: Dictionary = Campaign.load_mission(d, str(sc["id"]))
		_check(str(mj["city"].get("file", "")) == str(expect.get(str(sc["id"]), "?")), "%s : la mission désigne sa carte réelle (%s)" % [sc["id"], str(mj["city"].get("file", ""))])
	for sid in expect.values():
		var city = CityData.new()
		var ok: bool = city.load_json("res://data/cities/%s.json" % sid)
		_check(ok and city.is_real() and city.building_count() > 5000 and city.nodes.size() > 1500, "%s : carte lue (%d immeubles, %d nœuds, %d tronçons)" % [sid, city.building_count(), city.nodes.size(), city.edge_a.size()])
		var g = StreetGraph.new()
		g.build(city)
		g.snap_doors(city)
		# réseau connexe : un parcours en largeur depuis le nœud 0 atteint tous les nœuds
		var seen := PackedByteArray()
		seen.resize(city.nodes.size())
		var queue: Array = [0]
		seen[0] = 1
		var head := 0
		while head < queue.size():
			var n: int = queue[head]
			head += 1
			for e in g.adj[n]:
				var o: int = g.eb[e] if g.ea[e] == n else g.ea[e]
				if seen[o] == 0:
					seen[o] = 1
					queue.append(o)
		_check(queue.size() == city.nodes.size(), "%s : réseau routier connexe (%d / %d nœuds)" % [sid, queue.size(), city.nodes.size()])
		# portes : précalculées, valides, identiques à un recalcul pour un échantillon
		var bad := 0
		var far := 0
		var drift := 0
		var pre_n: int = city.pre_door_edge.size()
		for b in city.building_count():
			var e2: int = city.b_door_edge[b]
			if e2 < 0 or e2 >= g.ea.size() or city.b_door_t[b] < 0.0 or city.b_door_t[b] > 1.0:
				bad += 1
				continue
			var pos_e: Vector2 = g.pos_on_edge(e2, city.b_door_t[b], city.b_door_off[b])
			if city.b_occ[b] > 0 and pos_e.distance_to(city.b_door_pos[b]) > 8.05:
				drift += 1
			if city.b_occ[b] > 0 and city.b_occ[b] < 60 and city.b_door_pos[b].distance_to(g.pos_on_edge(e2, city.b_door_t[b], 0.0)) > g.ew[e2] * 0.5 + 38.5:
				far += 1
		_check(pre_n == city.building_count() and bad == 0, "%s : %d portes précalculées, toutes sur un tronçon valide (%d douteuses)" % [sid, pre_n, bad])
		_check(drift == 0, "%s : dans un immeuble habité, on sort à moins de 8 m de la porte (%d écarts)" % [sid, drift])
		_check(far == 0, "%s : aucun immeuble habité à plus de 38 m d'une chaussée (%d)" % [sid, far])
		var sample_ok := 0
		var sample_n := 0
		for b in range(0, city.building_count(), 97):
			var ne: Array = g.nearest_edge(Vector2(city.b_cx[b], city.b_cz[b]))
			sample_n += 1
			var pe: int = city.b_door_edge[b]
			var c0 := Vector2(city.b_cx[b], city.b_cz[b])
			var pa: Vector2 = g.node_pos[g.ea[pe]]
			var pb: Vector2 = g.node_pos[g.eb[pe]]
			var tt := clampf((c0 - pa).dot(pb - pa) / maxf((pb - pa).length_squared(), 0.0001), 0.0, 1.0)
			if (pa + (pb - pa) * tt).distance_to(c0) <= float(ne[2]) + 8.5:
				sample_ok += 1
		_check(sample_ok == sample_n, "%s : la porte précalculée est sur une rue à moins de 8,5 m de la plus proche (%d / %d)" % [sid, sample_ok, sample_n])
		# évacuations accessibles
		var reach := 0
		for en in city.evac_nodes:
			if seen[en] == 1:
				reach += 1
		_check(city.evac_nodes.size() == 9 and reach == 9, "%s : 9 points d'évacuation sur le réseau" % sid)
		# maillages d'eau et de parcs : indices valides, triangles non vides
		var mesh_ok: bool = not city.water_v.is_empty() or not city.park_v.is_empty()
		for pair in [[city.water_v, city.water_i], [city.park_v, city.park_i]]:
			var vv: PackedVector2Array = pair[0]
			var ii: PackedInt32Array = pair[1]
			if ii.size() % 3 != 0:
				mesh_ok = false
			for k in ii:
				if k < 0 or k >= vv.size():
					mesh_ok = false
					break
		_check(mesh_ok, "%s : maillages d'eau (%d triangles) et de parcs (%d) valides" % [sid, city.water_i.size() / 3, city.park_i.size() / 3])
		# ponts : seuls les tronçons marqués traversent l'eau
		var n_bridge := 0
		for e3 in city.edge_flag.size():
			if (city.edge_flag[e3] & 1) != 0:
				n_bridge += 1
		_check(city.places.size() >= 2, "%s : %d repères nommés, %d ponts" % [sid, city.places.size(), n_bridge])
		# aller-retour JSON
		var c2 = CityData.new()
		var rt: bool = c2.from_dict(JSON.parse_string(JSON.stringify(city.to_dict())))
		_check(rt and c2.building_count() == city.building_count() and c2.places.size() == city.places.size()
				and c2.water_i.size() == city.water_i.size() and c2.pre_door_edge.size() == city.pre_door_edge.size()
				and c2.edge_flag == city.edge_flag, "%s : aller-retour JSON complet" % sid)
	# noms de lieux : le repère le plus proche est annoncé
	var ql = CityData.new()
	ql.load_json("res://data/cities/quartier_latin.json")
	var nd: Dictionary = {}
	for pl in ql.places:
		if pl["n"] == "Notre-Dame":
			nd = pl
	_check(not nd.is_empty() and ql.place_at(nd["x"], nd["z"]) == "Notre-Dame" and ql.place_at(nd["x"] + 40.0, nd["z"] - 30.0) == "Notre-Dame"
			and ql.place_at(1150.0, 1150.0) == "", "lieu visé : Notre-Dame reconnu sur place, rien au loin")
	var sf = CityData.new()
	sf.load_json("res://data/cities/stade.json")
	var pitch := Vector2.ZERO
	for pl2 in sf.places:
		if pl2["n"] == "Stade de France":
			pitch = Vector2(pl2["x"], pl2["z"])
	var near_node := INF
	for nd2 in sf.nodes:
		near_node = minf(near_node, nd2.distance_to(pitch))
	_check(near_node > 90.0, "Stade de France : aucune rue sur la pelouse (la plus proche à %.0f m)" % near_node)


## Villes de la campagne, vagues « métro », assauts sur les tribunes, parties sans joueur.
func _test_sectors() -> void:
	print("# secteurs : villes, métro, tribunes")
	var d = Defs.load_all()
	var occ_by := {}
	for sc in d.sectors:
		var sid := str(sc["id"])
		var t0 := Time.get_ticks_msec()
		var ctx = _make_sector_world(sid)
		var city = ctx.city
		var style := str(ctx.mission["city"]["style"])
		var occ_total := 0
		var hmax := 0.0
		var n_tall := 0
		var no_door := 0
		for b in city.building_count():
			occ_total += ctx.buildings.occ[b]
			hmax = maxf(hmax, city.b_h[b])
			if city.b_h[b] > 60.0:
				n_tall += 1
			var e: int = city.b_door_edge[b]
			if e < 0 or e >= ctx.graph.ea.size():
				no_door += 1
		occ_by[style] = occ_total
		var wsum := 0.0
		for e in ctx.graph.ew.size():
			wsum += ctx.graph.ew[e]
		var wmean: float = wsum / maxf(float(ctx.graph.ew.size()), 1.0)
		print("   %s : %d immeubles, %d habitants, %d de plus de 60 m (max %.0f m), rues de %.1f m en moyenne, %d bouches de métro — prêt en %d ms" % [
				style, city.building_count(), occ_total, n_tall, hmax, wmean, city.metro_nodes.size(), Time.get_ticks_msec() - t0])
		_check(no_door == 0 and city.evac_nodes.size() >= 5 and city.building_count() > 4000, "%s : tous les immeubles ont une porte sur une rue, %d points d'évacuation" % [style, city.evac_nodes.size()])
		match style:
			"montmartre":
				_check(wmean < 10.0 and city.building_count() > 10000, "Montmartre : ruelles étroites (%.1f m) et immeubles serrés (%d)" % [wmean, city.building_count()])
			"halles":
				_check(city.metro_nodes.size() == 8 and occ_total > int(occ_by.get("latin", 0)), "Les Halles : 8 bouches de métro, plus d'habitants que le Quartier latin (%d > %d)" % [occ_total, int(occ_by.get("latin", 0))])
			"defense":
				_check(hmax > 150.0 and n_tall > 150, "La Défense : de vraies tours (%.0f m au plus haut), %d immeubles de plus de 60 m" % [hmax, n_tall])
			"stade":
				var stands: Array = []
				for b in city.building_count():
					if ctx.buildings.occ[b] >= 60:
						stands.append(b)
				var dmin := INF
				for nd in city.nodes:
					dmin = minf(dmin, nd.length())
				_check(stands.size() == 4 and dmin > 100.0, "Stade de France : 4 tribunes de 60 civils ou plus, aucune rue à moins de %.0f m du centre" % dmin)
		# une nuit entière sans joueur : aucune erreur, le secteur finit par tomber
		ctx.director.start()
		var t := 0.0
		var t1 := Time.get_ticks_msec()
		while ctx.director.state == "running" and t < 700.0:
			_sim(ctx, 0.1)
			t += 0.1
		var dd = ctx.director
		print("   %s sans joueur : %s à t=%.0f s — perdus %d/%d, dévorés %d (%d ms)" % [style, dd.state, dd.t, dd.lost, dd.max_lost, dd.eaten, Time.get_ticks_msec() - t1])
		_check(dd.state == "lost", "%s : sans intervention, le secteur tombe" % style)

	# --- vague « métro » : le groupe sort d'une bouche
	var hx = _make_sector_world("mission_03")
	var n0: int = hx.crowd.n_zombies
	hx.director._fire_wave({"t": 0, "type": "metro", "count": 8, "r_min": 300.0, "r_max": 1100.0})
	var near_metro := INF
	for n in hx.city.metro_nodes:
		near_metro = minf(near_metro, hx.city.nodes[n].distance_to(hx.crowd.last_spawn))
	_check(hx.crowd.n_zombies > n0 and near_metro < 120.0 and _radio_said(hx, "métro"),
			"vague métro : %d infectés sortent à %.0f m d'une bouche, annoncés à la radio" % [hx.crowd.n_zombies - n0, near_metro])
	var lx = _make_world(1914)                        # ville générée : pas de métro (les cinq secteurs réels en ont tous, lot 8)
	_check(lx.city.metro_nodes.is_empty(), "(préalable) la ville générée n'a pas de bouche de métro")
	var l0: int = lx.crowd.n_zombies
	lx.director._fire_wave({"t": 0, "type": "metro", "count": 8, "r_min": 300.0, "r_max": 1100.0})
	_check(lx.crowd.n_zombies > l0 and _radio_said(lx, "nouveau groupe"), "ville sans métro : la vague retombe sur des rues ordinaires (%d infectés)" % (lx.crowd.n_zombies - l0))

	# --- tribunes : assaut ciblé, porte renforcée, objectif « tenir la tribune », jamais d'intrusion tirée au sort
	var sx = _make_sector_world("mission_05")
	var stand: int = sx.director.assault_building(700.0, 6, 0.25, 60, 60.0)
	_check(stand >= 0 and sx.buildings.occ[stand] >= 60 and sx.buildings.siege[stand] > 0.0, "assaut ciblé : une tribune de %d civils est attaquée" % (sx.buildings.occ[stand] if stand >= 0 else 0))
	_check(stand >= 0 and sx.buildings.door_hp[stand] > 130.0, "la porte d'une tribune résiste plus qu'une porte ordinaire (%.0f contre au plus 130)" % (sx.buildings.door_hp[stand] if stand >= 0 else 0.0))
	var hold_def: Dictionary = {}
	for o in sx.mission["objectives"]:
		if o["id"] == "hold_s1":
			hold_def = (o as Dictionary).duplicate(true)
	hold_def["t"] = 0
	var sy = _make_sector_world("mission_05")
	sy.objectives.setup(sy, [hold_def])
	sy.director.start()
	_obj_run(sy, 2.0)
	var hit: Dictionary = sy.objectives.get_item("hold_s1")
	_check(hit["state"] == "active" and sy.buildings.occ[hit["b"]] >= 60, "objectif « Tenir la tribune » : une tribune est désignée (%s)" % str(hit["state"]))
	var sz = _make_sector_world("mission_05")
	for b in sz.city.building_count():
		if sz.buildings.occ[b] < 60:
			sz.buildings.occ[b] = 0
	sz.director._breach(30, 5000.0)
	var infested := 0
	for b in sz.city.building_count():
		if sz.buildings.zin[b] > 0:
			infested += 1
	_check(infested == 0, "une vague d'intrusion n'infeste jamais une tribune (%d immeubles infestés)" % infested)
	# recherche d'un immeuble rare : le tirage au hasard peut échouer, le parcours complet trouve
	var rare: int = sx.director.pick_building(3000.0, 90, 0.0)
	_check(rare >= 0 and sx.buildings.occ[rare] >= 90, "immeuble rare (≥ 90 civils) toujours trouvé (%d)" % (sx.buildings.occ[rare] if rare >= 0 else 0))
	_check(sx.director.pick_building(3000.0, 5000, 0.0) == -1, "aucun immeuble de 5 000 habitants : -1")


func _test_workshop() -> void:
	print("# atelier et cosmétiques")
	var p = _new_profile()
	_check(not p.can_buy("g25_ammo")["ok"], "sans crédit, aucun achat : %s" % p.can_buy("g25_ammo")["why"])
	p.credits = 99
	_check(not p.buy("g25_ammo") and p.credits == 99 and p.level("g25_ammo") == 0, "99 crédits ne suffisent pas pour un article à 100")
	p.credits = 100
	_check(p.buy("g25_ammo") and p.credits == 0 and p.level("g25_ammo") == 1, "100 crédits : niveau 1 acheté, solde 0")
	p.credits = 10000
	_check(not p.can_buy("g25_ammo")["ok"] and "grade" in str(p.can_buy("g25_ammo")["why"]), "niveau 2 verrouillé par le grade : %s" % p.can_buy("g25_ammo")["why"])
	p.xp = 2600
	_check(p.buy("g25_ammo") and p.level("g25_ammo") == 2, "grade Adjudant : niveau 2 acheté")
	_check(not p.can_buy("g25_ammo")["ok"], "niveau 3 verrouillé jusqu'au grade de Major : %s" % p.can_buy("g25_ammo")["why"])
	p.xp = 7600
	_check(p.buy("g25_ammo") and p.level("g25_ammo") == 3 and not p.buy("g25_ammo") and p.next_level("g25_ammo").is_empty(), "niveau 3 puis plus rien à acheter")
	p.credits = 10000000
	p.xp = 999999
	var n := 0
	for it in p.defs.up_items:
		while p.buy(str(it["id"])):
			n += 1
	_check(p.shop_complete() and p.total_levels() == p.defs.total_upgrade_levels(), "tout acheter est possible : %d niveaux" % p.total_levels())
	var meds: Array = p.check_medals()
	var ids := []
	for m in meds:
		ids.append(m[0])
	_check(ids.has("shop_first") and ids.has("shop_all") and ids.has("grade_col"), "médailles de carrière sans mission : atelier complet et grade de colonel")

	# effets sur les armes
	var base: Array = _json("res://data/weapons.json")["weapons"]
	var q = _new_profile()
	q.upgrades = {"g25_ammo": 3, "g25_acc": 2, "crew_regen": 2, "m102_dmg": 3, "g25_rate": 1}
	var w: Array = q.weapons(base)
	_check(int(base[0]["ammo"]) == 3000 and float(base[0]["dispersion_mrad"]) == 1.8, "les données d'origine ne sont pas modifiées")
	_check(int(w[0]["ammo"]) == 4800, "25 mm : munitions 3000 × 1,6 = %d" % int(w[0]["ammo"]))
	_check(is_equal_approx(float(w[0]["dispersion_mrad"]), 1.8 * 0.8), "25 mm : dispersion −20 %% (%.3f)" % float(w[0]["dispersion_mrad"]))
	_check(is_equal_approx(float(w[0]["regen_per_s"]), 20.0 * (1.0 + 0.6 + 0.4)), "régénération : amélioration d'arme et soutier s'additionnent (%.1f)" % float(w[0]["regen_per_s"]))
	_check(is_equal_approx(float(w[1]["regen_per_s"]), 0.5 * 1.4) and is_equal_approx(float(w[2]["regen_per_s"]), 0.1 * 1.4), "le soutier joue sur toutes les armes")
	_check(int(w[0]["rpm"]) == 1944 and int(w[1]["rpm"]) == 100, "cadence du 25 mm +8 %% (%d), les autres armes inchangées" % int(w[0]["rpm"]))
	_check(is_equal_approx(float(w[2]["splash_radius_m"]), 22.0 * 1.18) and is_equal_approx(float(w[2]["damage_building"]), 100.0 * 1.45), "105 mm : éclat +18 %% et dégâts d'immeuble +45 %%")
	_check(is_equal_approx(float(w[2]["flash_radius_m"]), 22.0 * 1.18), "la lueur de l'explosion suit le rayon d'éclat")
	var md: Dictionary = _new_profile().mods()
	_check(md.is_empty(), "profil neuf : aucun réglage")
	q.upgrades = {"sen_predict": 2, "sen_zoom": 3, "sen_laser": 1, "crew_doors": 3, "crew_obj": 1, "crew_chain": 2}
	md = q.mods()
	_check(int(md["predict"]) == 2 and is_equal_approx(float(md["zoom_max"]), 16.0) and int(md["laser"]) == 1, "capteurs : prédicteur 2, zoom ×16, laser 1")
	_check(is_equal_approx(float(md["door_hp"]), 0.3) and is_equal_approx(float(md["obj_time_s"]), 10.0) and is_equal_approx(float(md["chain_keep"]), 0.5), "équipage : portes +30 %%, délais +10 s, série gardée à 50 %%")

	# cosmétiques
	var c = _new_profile()
	_check(c.equipped["insignia"] == "ins_chevron" and c.equipped["filter"] == "flt_white" and c.equipped["reticle"] == "ret_classic" and c.equipped["voice"] == "vox_std", "équipement de départ")
	_check(not c.equip("filter", "flt_green") and c.equipped["filter"] == "flt_white", "filtre vert verrouillé (grade Sergent-chef)")
	c.xp = 1000
	_check(c.equip("filter", "flt_green") and c.equipped["filter"] == "flt_green", "filtre vert disponible au grade de Sergent-chef")
	_check(not c.equip("reticle", "flt_green") and not c.equip("filter", "ret_bold"), "un cosmétique ne va que dans son emplacement")
	_check(not c.equip("insignia", "ins_skull") and "médaille" in c.unlock_text("ins_skull"), "insigne de médaille verrouillé : %s" % c.unlock_text("ins_skull"))
	c.medals["kills_200"] = {"n": 1}
	_check(c.equip("insignia", "ins_skull"), "… disponible avec la médaille")
	_check(not c.can_buy_cosmetic("flt_amber")["ok"] and c.can_buy_cosmetic("ret_fine")["why"].contains("crédits"), "achats en crédits : %s / %s" % [c.can_buy_cosmetic("flt_amber")["why"], c.can_buy_cosmetic("ret_fine")["why"]])
	c.credits = 60
	_check(c.buy_cosmetic("ret_fine") and c.credits == 0 and c.equip("reticle", "ret_fine") and not c.buy_cosmetic("ret_fine"), "réticule fin acheté 60 crédits, équipé, non rachetable")
	var before: Dictionary = c.unlocked_set()
	c.xp = 11000
	var after: Dictionary = c.unlocked_set()
	_check(after.size() > before.size(), "monter en grade débloque des cosmétiques (%d -> %d)" % [before.size(), after.size()])


func _test_mods_in_game() -> void:
	print("# effets de l'atelier en jeu")
	var base = _make_world(1914)
	var strong = Ctx.new()
	# portes : mêmes tirages au sort, résistance multipliée
	strong.mods = {"door_hp": 0.3}
	strong.weapons = base.weapons
	strong.mission = base.mission
	strong.rng.seed = 1914 + 7
	var city = base.city
	var bs2 = BuildingSystem.new()
	strong.city = city
	bs2.setup(strong, city)
	var ok := true
	for b in range(0, city.building_count(), 97):
		if not is_equal_approx(bs2.door_hp[b], base.buildings.door_hp[b] * 1.3):
			ok = false
	_check(ok, "portes renforcées : résistance ×1,3 pour les mêmes immeubles")

	# civils plus rapides
	var c1 = _make_world(1914)
	var c2 = _make_world(1914)
	c2.mods = {"civ_speed": 0.24}
	var b0 := 0
	for b in c1.city.building_count():
		if c1.city.b_occ[b] > 0:
			b0 = b
			break
	c1.crowd.spawn_civilian_at_door(b0)
	c2.crowd.spawn_civilian_at_door(b0)
	var s1 := 0.0
	var s2 := 0.0
	for i in c1.crowd.MAX_P:
		if c1.crowd.pool[i].alive:
			s1 = c1.crowd.pool[i].speed
			break
	for i in c2.crowd.MAX_P:
		if c2.crowd.pool[i].alive:
			s2 = c2.crowd.pool[i].speed
			break
	_check(s1 > 0.0 and is_equal_approx(s2, s1 * 1.24), "guide d'évacuation : civils +24 %% (%.2f -> %.2f m/s)" % [s1, s2])

	# délai des objectifs : la durée annoncée suit
	var o = _make_world(1914)
	o.mods = {"obj_time_s": 20.0}
	o.director.start()
	var guard := 0
	var first = null
	while first == null and guard < 4000:
		_sim(o, 0.1)
		guard += 1
		for it in o.objectives.items:
			if it["state"] == "active" and it["kind"] == "secondary":
				first = it
	_check(first != null and is_equal_approx(float(first["dur"]), float(first["def"]["duration"]) + 20.0), "officier de renseignement : délai +20 s (%s)" % (str(first["dur"]) if first != null else "aucun objectif"))
	# toute durée possible reste dans les durées que la radio sait prononcer (30 à 180 s, par pas de 10)
	var max_dur := 0.0
	var step_ok := true
	for def in o.mission.get("objectives", []):
		if def.has("duration"):
			max_dur = maxf(max_dur, float(def["duration"]))
			if int(def["duration"]) % 10 != 0:
				step_ok = false
	_check(step_ok and max_dur + 30.0 <= 180.0, "durées d'objectifs : multiples de 10 s, au plus %d s avec le meilleur officier (limite radio : 180 s)" % int(max_dur + 30.0))

	# série : l'instructeur de tir
	var k1 = _make_world(1914)
	var k2 = _make_world(1914)
	k2.mods = {"chain_keep": 0.5}
	for k in [k1, k2]:
		for i in 40:
			k.score.on_zombie_killed(false)
		k.score.on_collateral(1)
	_check(k1.score.chain == 0 and k1.score.mult == 1, "bavure sans instructeur : série à 0")
	_check(k2.score.chain == 20 and k2.score.mult == 3, "instructeur niveau 2 : on garde 50 %% de la série (20, ×3)")
	_check(k2.score.st["clean_chain"] == 0 and k2.score.st["clean_best"] == 40 and k2.score.st["chain_best"] == 40, "… mais la série « sans bavure » repart de zéro (record 40)")
	var res: Dictionary = k2.score.finish(true)
	var f := Profile.mission_facts(res)
	_check(int(f["clean_best"]) == 40 and int(f["won"]) == 1 and f["rating"] >= -1, "faits de mission tirés d'un vrai bilan (série %d, note %d)" % [f["clean_best"], f["rating"]])
	# zoom de l'optique
	var g = Gunship.new()
	_check(g.zoom_max == 8.0 and is_equal_approx(g.min_fov, 0.45), "optique de base : zoom ×8, champ minimal 0,45°")


# ---------------------------------------------------------------- capteurs (prédicteur, désignateur laser)

## Personne posée à la main dans la foule (les tests des capteurs pilotent les positions eux-mêmes).
func _put(ctx, pos: Vector2, kind: int = 0):
	var p = ctx.crowd._alloc()
	p.kind = kind
	p.pos = pos
	p.hp = 40.0
	return p


func _sensor_world(mods: Dictionary):
	var ctx = _make_world(1914)
	ctx.mods = mods
	ctx.predictor = Predictor.new()
	ctx.predictor.setup(ctx)
	ctx.designator = Designator.new()
	ctx.designator.setup(ctx)
	ctx.gunship.aim = Vector2.ZERO
	return ctx


## Fait avancer des personnes à vitesse constante et relève le prédicteur à chaque pas de 0,25 s.
func _march(ctx, people: Array, v: Vector2, steps: int) -> void:
	for i in steps:
		for p in people:
			p.pos += v * 0.25
		ctx.predictor.update(0.25)


func _test_sensors() -> void:
	print("# capteurs : prédicteur de tir et désignateur laser")
	# --- prédicteur
	var ctx = _sensor_world({})
	ctx.arms.select(1)                                   # 40 mm : vol 1,1 s, rayon d'effet 8 m
	var zs: Array = []
	for i in 5:
		zs.append(_put(ctx, Vector2(10.0 + i, 5.0 - i)))
	_march(ctx, zs, Vector2(1.5, 0.0), 6)
	_check(not ctx.predictor.shown, "sans prédicteur : aucun marqueur")

	ctx.mods = {"predict": 1}
	_march(ctx, zs, Vector2(1.5, 0.0), 6)
	var pr = ctx.predictor
	_check(pr.shown and pr.n_follow == 5, "niveau 1 : la grappe de 5 infectés est suivie (%d)" % pr.n_follow)
	_check(absf(pr.group_v.x - 1.5) < 0.05 and absf(pr.group_v.y) < 0.05, "vitesse de la grappe mesurée : %s m/s (attendu 1,5 ; 0)" % str(pr.group_v))
	var ahead: Vector2 = pr.marker() - pr.group_now()
	_check(absf(ahead.x - 1.5 * 1.1) < 0.1 and absf(ahead.y) < 0.1, "marqueur = grappe + vitesse × temps de vol du 40 mm (+%.2f m)" % ahead.x)
	ctx.arms.select(2)                                   # 105 mm : vol 1,5 s
	_check(absf(pr.lead_m() - 1.5 * 1.5) < 0.1, "l'avance suit l'arme sélectionnée : 105 mm -> %.2f m" % pr.lead_m())
	ctx.arms.select(0)                                   # 25 mm : vol 0,8 s, marqueur dès le niveau 1
	_check(pr.shown and absf(pr.lead_m() - 1.5 * 0.8) < 0.1, "le marqueur existe aussi pour le 25 mm : %.2f m" % pr.lead_m())
	_check(pr.n_hit == 0, "pas d'estimation des infectés touchés au niveau 1")

	# mesure aberrante : un personnage qui « saute » de 50 m entre deux relevés n'est pas une vitesse
	var ctx2 = _sensor_world({"predict": 1})
	var jumper = _put(ctx2, Vector2(20.0, 0.0))
	for i in 4:
		jumper.pos = Vector2(20.0, 0.0) if i % 2 == 0 else Vector2(-30.0, 0.0)
		ctx2.predictor.update(0.25)
	_check(ctx2.predictor.shown and ctx2.predictor.group_v == Vector2.ZERO, "une vitesse aberrante (téléportation) est ignorée")

	# estimation de l'impact : des coureurs encore hors de la zone y seront à l'arrivée de l'obus
	var ctx3 = _sensor_world({"predict": 2})
	ctx3.arms.select(1)
	var runners: Array = []
	for i in 5:
		runners.append(_put(ctx3, Vector2(-16.4, -2.0 + i)))
	var civ_a = _put(ctx3, Vector2(1.0, 1.0), 1)
	var civ_b = _put(ctx3, Vector2(-2.0, 3.0), 1)
	_march(ctx3, runners, Vector2(3.6, 0.0), 6)           # arrivent vers x = -11 (hors des 8 m du point visé)
	var now_in: int = ctx3.crowd.count_near(Vector2.ZERO, 8.0, 0)
	_check(now_in == 0 and ctx3.predictor.n_hit == 5, "niveau 2 : 0 infecté dans la zone maintenant, 5 attendus à l'impact (%d / %d)" % [now_in, ctx3.predictor.n_hit])
	_check(ctx3.predictor.n_civ == 0, "niveau 2 : pas de décompte des civils")
	ctx3.mods = {"predict": 3}
	_march(ctx3, runners, Vector2(0.0, 0.0), 1)
	_check(ctx3.predictor.n_civ == 2, "niveau 3 : 2 civils exposés signalés (%d)" % ctx3.predictor.n_civ)
	civ_a.alive = false
	civ_b.alive = false

	# --- désignateur laser
	var c4 = _sensor_world({"laser": 1})
	var des = c4.designator
	var za = _put(c4, Vector2(20.0, 0.0))
	var zb = _put(c4, Vector2(0.0, 50.0))
	_check(des.designate() and des.target == za and des.active, "niveau 1 : désigne l'infecté le plus proche (20 m)")
	des.release()
	za.kind = 3
	_check(not des.designate() and des.fail_t >= 0.0 and not des.active, "niveau 1 : rien à 30 m -> échec signalé")
	c4.mods = {"laser": 2}
	_check(des.designate() and des.target == zb, "niveau 2 : désigne à 50 m (rayon 60 m)")
	c4.mods = {"laser": 0}
	des.release()
	des.toggle()
	_check(not des.active, "sans désignateur : le clic droit ne fait rien")

	# suivi d'une cible qui marche à 2 m/s
	for lv in [1, 2]:
		var c5 = _sensor_world({"laser": lv})
		c5.arms.select(1)
		var z = _put(c5, Vector2(10.0, 0.0))
		c5.designator.designate()
		for i in 80:
			z.pos += Vector2(2.0, 0.0) * 0.05
			c5.designator.update(0.05)
		var gap: float = c5.gunship.aim.x - z.pos.x
		if lv == 1:
			_check(c5.designator.active and absf(gap) < 1.0 and absf(c5.gunship.aim.y - z.pos.y) < 0.5, "niveau 1 : la nacelle suit la cible (écart %.2f m)" % gap)
		else:
			_check(c5.designator.active and gap > 1.6 and gap < 2.8, "niveau 2 : visée avancée du chemin de la cible pendant le vol de l'obus (+%.2f m, attendu ≈ 2,2)" % gap)
		# un mouvement franc de la souris casse le verrou
		c5.gunship.aim += Vector2(0.0, 200.0)
		c5.designator.update(0.05)
		_check(not c5.designator.active, "niveau %d : détourner la nacelle relâche le verrou" % lv)

	# cible abattue : niveau 1 relâche, niveau 2 enchaîne sur l'infecté suivant
	for lv in [1, 2]:
		var c6 = _sensor_world({"laser": lv})
		var a = _put(c6, Vector2(5.0, 0.0))
		var b = _put(c6, Vector2(30.0, 10.0))
		c6.designator.designate()
		a.kind = 3
		c6.designator.update(0.05)
		if lv == 1:
			_check(not c6.designator.active, "niveau 1 : cible abattue -> le verrou tombe")
		else:
			_check(c6.designator.active and c6.designator.target == b, "niveau 2 : cible abattue -> l'infecté suivant est désigné")
	# plus aucun infecté : le verrou tombe aussi au niveau 2
	var c7 = _sensor_world({"laser": 2})
	var only = _put(c7, Vector2(5.0, 0.0))
	c7.designator.designate()
	only.alive = false
	c7.designator.update(0.05)
	_check(not c7.designator.active, "plus d'infecté à portée : le verrou tombe")

	# niveau 3 : obus lourds mieux groupés tant que le verrou tient (mesure sur 300 tirs)
	var c8 = _sensor_world({"laser": 3})
	var street_pt: Vector2 = c8.graph.pos_on_edge(0, 0.5, 0.0)
	c8.gunship.aim = street_pt
	c8.gunship.update(0.0)
	_check(c8.designator.dispersion_factor(1) == 1.0, "niveau 3 : sans verrou, dispersion normale")
	var spread_free := _shell_spread(c8, 1, 300)
	c8.designator.active = true
	_check(c8.designator.dispersion_factor(0) == 1.0 and c8.designator.dispersion_factor(1) == 0.5 and c8.designator.dispersion_factor(2) == 0.5,
			"niveau 3 : verrou -> ×0,5 pour le 40 et le 105 mm, pas pour le 25 mm")
	var spread_lock := _shell_spread(c8, 1, 300)
	var ratio := spread_lock / maxf(spread_free, 0.001)
	_check(ratio > 0.35 and ratio < 0.7, "dispersion mesurée du 40 mm : %.1f m -> %.1f m avec le verrou (rapport %.2f, attendu ≈ 0,5)" % [spread_free, spread_lock, ratio])

	# partie courte avec les deux capteurs : aucune erreur, estimations cohérentes
	var g = _sensor_world({"predict": 3, "laser": 3})
	g.director.start()
	var worst_n := 0
	var locks := 0
	var t := 0.0
	while t < 150.0 and g.director.state == "running":
		g.time += 0.1
		g.designator.update(0.1)
		g.gunship.update(0.1)
		g.arms.update(0.1)
		g.buildings.step(0.1)
		g.crowd.step(0.1)
		g.predictor.update(0.1)
		g.director.step(0.1)
		t += 0.1
		if fmod(t, 4.0) < 0.1:
			var z2 = g.crowd.nearest_zombie(g.gunship.aim)
			if z2 != null:
				g.gunship.aim = z2.pos + Vector2(3.0, 0.0)
			if g.designator.active:
				g.designator.release()
			elif g.designator.designate():
				locks += 1
		worst_n = maxi(worst_n, g.predictor.n_hit)
		if not is_finite(g.gunship.aim.x) or not is_finite(g.gunship.aim.y):
			break
	_check(is_finite(g.gunship.aim.x) and is_finite(g.gunship.aim.y), "partie de 150 s avec capteurs : visée toujours valide")
	_check(locks > 0 and g.predictor.n_hit >= 0 and g.predictor.n_civ >= 0, "partie de 150 s avec capteurs : %d verrouillages, jusqu'à %d infectés estimés" % [locks, worst_n])


## Écart quadratique moyen (m) des points d'impact de `n` tirs de l'arme `w` autour de leur moyenne.
func _shell_spread(ctx, w: int, n: int) -> float:
	ctx.arms.current = w
	ctx.arms.shells.clear()
	for i in n:
		ctx.arms._fire_one(ctx.weapons[w])
	var pts: Array = []
	var mean := Vector2.ZERO
	for sh in ctx.arms.shells:
		var q := Vector2(sh.pos.x, sh.pos.z)
		pts.append(q)
		mean += q
	mean /= float(maxi(pts.size(), 1))
	var acc := 0.0
	for q in pts:
		acc += (q as Vector2).distance_squared_to(mean)
	ctx.arms.shells.clear()
	return sqrt(acc / float(maxi(pts.size(), 1)))


## Voix radio alternatives (cosmétiques) : chaque réglage agit sur les effets du bus « Radio ».
func _test_voice_styles() -> void:
	print("# voix radio : réglages des effets du bus")
	var ctx = _make_world(1914)
	var snd = Sound.new()
	ctx.sound = snd
	snd.setup(ctx, root)
	var bus := AudioServer.get_bus_index("Radio")
	_check(bus >= 0 and AudioServer.get_bus_effect_count(bus) >= 1, "le bus Radio existe avec son filtre passe-bas")
	var defs = Defs.load_all()
	var bad := 0
	var seen_pitch := false
	var seen_drive := false
	for v in defs.cos_items["voice"]:
		snd.set_voice_style(v)
		var lpf_ok := false
		var pitch_state := -1.0     # -1 : effet absent ou coupé
		var drive_state := -1.0
		for i in AudioServer.get_bus_effect_count(bus):
			var e = AudioServer.get_bus_effect(bus, i)
			var on := AudioServer.is_bus_effect_enabled(bus, i)
			if e is AudioEffectLowPassFilter:
				lpf_ok = is_equal_approx((e as AudioEffectLowPassFilter).cutoff_hz, clampf(float(v.get("lpf_hz", 3800.0)), 1500.0, 9000.0))
			elif e is AudioEffectPitchShift and on:
				pitch_state = (e as AudioEffectPitchShift).pitch_scale
			elif e is AudioEffectDistortion and on:
				drive_state = (e as AudioEffectDistortion).drive
		var want_pitch := float(v.get("pitch", 1.0))
		var want_drive := float(v.get("drive", 0.0))
		var pitch_ok: bool = (pitch_state < 0.0) if absf(want_pitch - 1.0) <= 0.01 else is_equal_approx(pitch_state, clampf(want_pitch, 0.5, 2.0))
		var drive_ok: bool = (drive_state < 0.0) if want_drive <= 0.01 else is_equal_approx(drive_state, clampf(want_drive, 0.0, 1.0))
		if not (lpf_ok and pitch_ok and drive_ok):
			bad += 1
			print("   voix %s : filtre %s, hauteur %s (voulu %s), saturation %s (voulu %s)" % [v["id"], str(lpf_ok), str(pitch_state), str(want_pitch), str(drive_state), str(want_drive)])
		seen_pitch = seen_pitch or absf(want_pitch - 1.0) > 0.01
		seen_drive = seen_drive or want_drive > 0.01
	_check(bad == 0, "les %d voix radio règlent filtre, hauteur et saturation comme prévu" % defs.cos_items["voice"].size())
	_check(seen_pitch and seen_drive, "au moins une voix modifie la hauteur et une autre sature")
	snd.set_voice_style({})
	var back_ok := true
	for i in AudioServer.get_bus_effect_count(bus):
		var e2 = AudioServer.get_bus_effect(bus, i)
		if (e2 is AudioEffectPitchShift or e2 is AudioEffectDistortion) and AudioServer.is_bus_effect_enabled(bus, i):
			back_ok = false
	_check(back_ok, "voix standard : effets de hauteur et de saturation coupés")


# ---------------------------------------------------------------- parties complètes

# ---------------------------------------------------------------- lot 5 : mutateurs, infectés spéciaux, appuis, modes de jeu

func _near(a, b, eps: float = 0.001) -> bool:
	return absf(float(a) - float(b)) <= eps


## Monde du lot 5 : mode, mutateurs et appuis achetés (réglages `mods`) au choix. Le directeur est « en cours » mais ne tire
## aucune vague : les mesures ne dépendent que de ce que le test y met.
func _world5(mods: Dictionary = {}, mode: String = "campaign", mutators: Array = [], seed_v: int = 1914):
	var ctx = _make_world(seed_v, {}, 2400.0, "latin", mode, mutators)
	ctx.mods = mods.duplicate()
	ctx.supports.reset()
	ctx.director.waves = []
	ctx.director.state = "running"
	return ctx


## Avance les systèmes de `secs` secondes (pas de 0,1 s), appuis compris, sans le directeur (aucune vague).
func _run5(ctx, secs: float) -> void:
	for i in int(round(secs * 10.0)):
		ctx.time += 0.1
		ctx.gunship.update(0.1)
		ctx.arms.update(0.1)
		ctx.supports.update(0.1)
		ctx.buildings.step(0.1)
		ctx.crowd.step(0.1)


## Immobilise les zombies vivants (mesures de dégâts et de portée sans déplacement).
func _freeze(ctx) -> void:
	for i in ctx.crowd.MAX_P:
		var p = ctx.crowd.pool[i]
		if p.alive and p.kind == Crowd.K_ZOMBIE:
			p.idle = 9999.0


## Un immeuble habité dont la porte tient encore (cible possible d'un siège), différent de `skip`.
func _first_targetable(ctx, skip: int = -1) -> int:
	for b in ctx.city.building_count():
		if b != skip and ctx.buildings.targetable(b):
			return b
	return -1


## L'immeuble habité le plus proche de `pos` dont la porte tient encore.
func _nearest_targetable(ctx, pos: Vector2) -> int:
	var best := -1
	var bd := INF
	for b in ctx.city.building_count():
		if ctx.buildings.targetable(b):
			var dd := Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b]).distance_to(pos)
			if dd < bd:
				bd = dd
				best = b
	return best


## Un tronçon dont le milieu est à au moins `min_d` mètres de `from`.
func _edge_far(ctx, from: Vector2, min_d: float) -> int:
	var g = ctx.graph
	for e in g.ea.size():
		var mid: Vector2 = (g.node_pos[g.ea[e]] + g.node_pos[g.eb[e]]) * 0.5
		if mid.distance_to(from) >= min_d:
			return e
	return -1


## Un obus de l'arme w tombe au sol à (x, z), comme un tir de la canonnière.
func _impact5(ctx, w: int, x: float, z: float) -> void:
	var s = Arms.Shell.new()
	s.pos = Vector3(x, 0.0, z)
	s.w = w
	s.range = 2500.0
	ctx.arms._impact(s)


func _radio_count(ctx, needle: String) -> int:
	var n := 0
	for r in ctx.radio_log:
		if str(r[0]).contains(needle):
			n += 1
	return n


# ---------------------------------------------------------------- mutateurs

func _test_mutators() -> void:
	print("# mutateurs")
	var d = Defs.load_all()
	var base: Dictionary = Campaign.load_mission(d, "mission_01")
	_check(d.mutators.size() == 6 and d.max_mutators == 3, "six mutateurs, trois actifs au plus (%d, maximum %d)" % [d.mutators.size(), d.max_mutators])
	var bad := 0
	for m in d.mutators:
		if str(m["name"]) == "" or str(m["short"]) == "" or str(m["text"]) == "" or not m.has("bonus") or (m["effects"] as Dictionary).is_empty():
			bad += 1
		if absf(float(m.get("bonus", 0.0))) > 0.5:
			bad += 1
		for x in m.get("excludes", []):
			if not d.mutator_by_id.has(str(x)) or not (d.mutator(str(x)).get("excludes", []) as Array).has(str(m["id"])):
				bad += 1              # une exclusion doit viser un mutateur qui existe, et jouer dans les deux sens
	_check(bad == 0, "mutateurs : nom, texte, bonus et effets présents, exclusions réciproques (%d anomalies)" % bad)
	_check(Mutators.clean(d, []).is_empty(), "clean : liste vide")
	_check(Mutators.clean(d, ["fog", "fog", "inconnu", "runners"]) == ["fog", "runners"], "clean : doublons et inconnus écartés")
	_check(Mutators.clean(d, ["doors_weak", "doors_strong", "fog"]) == ["doors_weak", "fog"], "clean : l'incompatible venu après est écarté")
	_check(Mutators.clean(d, ["fog", "radio_down", "ammo_scarce", "runners"]).size() == 3, "clean : trois mutateurs au plus")
	_check(Mutators.toggled(d, ["doors_weak"], "doors_strong") == ["doors_strong"], "toggled : choisir les portes blindées retire les portes fragiles")
	_check(Mutators.toggled(d, ["fog", "runners"], "fog") == ["runners"], "toggled : un second appui retire le mutateur")
	_check(Mutators.toggled(d, ["fog", "runners", "ammo_scarce"], "radio_down") == ["fog", "runners", "ammo_scarce"], "toggled : déjà trois mutateurs, rien ne change")
	_check(Mutators.toggled(d, ["fog", "runners", "doors_weak"], "doors_strong") == ["fog", "runners", "doors_strong"], "toggled : l'échange d'un incompatible reste possible au maximum")
	_check(_near(Mutators.reward_mult(d, []), 1.0) and _near(Mutators.reward_mult(d, ["fog", "ammo_scarce"]), 1.12 * 1.15)
			and _near(Mutators.reward_mult(d, ["doors_strong", "doors_weak"]), 0.9),
			"gains : aucun mutateur ×1, brouillard + munitions rares ×%.3f, portes blindées ×0,9 (l'incompatible écarté ne compte pas)" % Mutators.reward_mult(d, ["fog", "ammo_scarce"]))
	_check(Mutators.names(d, ["fog", "doors_weak"]) == "Brouillard · Portes fragiles" and Mutators.names(d, []) == "", "noms : « Brouillard · Portes fragiles », vide sans mutateur")
	_check(Mutators.has_effect(d, ["radio_down"], "radio_down") and not Mutators.has_effect(d, ["fog"], "radio_down"), "has_effect : panne radio seulement")

	# mission transformée, jamais modifiée sur place
	var copy: Dictionary = base.duplicate(true)
	var m1: Dictionary = Mutators.apply(base, d, ["doors_weak", "runners"])
	var r0: Dictionary = base["rules"]
	var r1: Dictionary = m1["rules"]
	_check(_near(r1["door_hp_min"], float(r0["door_hp_min"]) * 0.5) and _near(r1["door_hp_max"], float(r0["door_hp_max"]) * 0.5),
			"portes fragiles : résistance des portes ×0,5 (%d à %d s)" % [int(r1["door_hp_min"]), int(r1["door_hp_max"])])
	_check(_near(r1["runner_ratio"], float(r0["runner_ratio"]) * 2.0), "coureurs : part de coureurs ×2 (%.2f)" % float(r1["runner_ratio"]))
	_check(_deep_equal(base, copy), "la mission d'origine n'est pas modifiée")
	_check(m1["mutators"] == ["doors_weak", "runners"], "la mission transformée porte la liste des mutateurs")
	var m_cap: Dictionary = Mutators.apply({"rules": {"runner_ratio": 0.5}}, d, ["runners"])
	_check(_near(m_cap["rules"]["runner_ratio"], Campaign.RUNNER_MAX), "coureurs : la part de coureurs est plafonnée (%.1f)" % Campaign.RUNNER_MAX)
	var m2: Dictionary = Mutators.apply(base, d, ["radio_down"])
	var n_hid := 0
	var n_sec := 0
	for o in m2["objectives"]:
		if str(o.get("kind", "secondary")) == "hidden":
			n_hid += 1
		else:
			n_sec += 1
	_check(n_sec == 0 and n_hid == 5, "panne radio : plus aucun objectif annoncé, les 5 objectifs cachés restent (%d + %d)" % [n_sec, n_hid])
	_check(_deep_equal(Mutators.apply(base, d, ["fog"])["rules"], base["rules"]), "brouillard : les règles de la mission ne changent pas")

	# armes
	var w0: Array = _json("res://data/weapons.json")["weapons"]
	var w0_copy: Array = w0.duplicate(true)
	var w1: Array = Mutators.weapons(w0, d, ["ammo_scarce"])
	_check(int(w1[0]["ammo"]) == 1800 and _near(w1[0]["regen_per_s"], 10.0) and int(w1[2]["ammo"]) == 36 and _near(w1[2]["regen_per_s"], 0.05),
			"munitions rares : réserves ×0,6 (%d / %d / %d) et régénération ×0,5" % [int(w1[0]["ammo"]), int(w1[1]["ammo"]), int(w1[2]["ammo"])])
	_check(_deep_equal(w0, w0_copy) and _deep_equal(Mutators.weapons(w0, d, ["fog"]), w0), "armes d'origine intactes ; sans munitions rares, armes inchangées")

	# dans le jeu : réserves de départ, régénération, portes
	var ctx = _make_world(1914, {}, 2400.0, "latin", "campaign", ["ammo_scarce"])
	ctx.weapons = w1
	ctx.arms.setup(ctx)
	_check(_near(ctx.arms.ammo[0], 1800.0) and _near(ctx.arms.ammo[1], 144.0) and _near(ctx.arms.ammo[2], 36.0), "en jeu : réserves de départ réduites (%d / %d / %d)" % [int(ctx.arms.ammo[0]), int(ctx.arms.ammo[1]), int(ctx.arms.ammo[2])])
	ctx.arms.ammo[2] = 0.0
	for i in 1000:
		ctx.arms.update(0.1)
	_check(_near(ctx.arms.ammo[2], 5.0, 0.01), "en jeu : le 105 mm se recharge deux fois moins vite (%.2f obus en 100 s au lieu de 10)" % float(ctx.arms.ammo[2]))
	var wa = _make_world(2024, base)
	var wb = _make_world(2024, Mutators.apply(base, d, ["doors_weak"]))
	var sa := 0.0
	var sb := 0.0
	for b in wa.city.building_count():
		sa += wa.buildings.door_hp[b]
		sb += wb.buildings.door_hp[b]
	_check(_near(sb / sa, 0.5, 0.005), "en jeu : les portes résistent deux fois moins longtemps (rapport %.3f)" % (sb / sa))

	# panne radio : seuls les échanges internes de l'avion passent
	var rd = _make_world(1914, {}, 2400.0, "latin", "campaign", ["radio_down"])
	rd.say("new_group", {}, "ALERTE-BASE", "alert")
	rd.say("sup_barrage", {}, "APPUI-BASE", "info")
	rd.say("radio_fail", {}, "PANNE-ANNONCEE", "alert")
	rd.say("colossus_down", {}, "COLOSSE-ABATTU", "good")
	_check(not _radio_said(rd, "ALERTE-BASE") and not _radio_said(rd, "APPUI-BASE") and _radio_said(rd, "PANNE-ANNONCEE") and _radio_said(rd, "COLOSSE-ABATTU"),
			"panne radio : les alertes de la station se taisent, l'annonce de la panne et les échanges internes passent")
	rd.director.start()
	_check(_radio_said(rd, "panne de liaison") and not _radio_said(rd, "vous êtes sur zone"), "panne radio : le départ annonce la panne, pas la mission")
	var nr = _make_world(1914)
	nr.say("new_group", {}, "ALERTE-BASE", "alert")
	_check(_radio_said(nr, "ALERTE-BASE"), "sans mutateur, la station parle")


# ---------------------------------------------------------------- infectés spéciaux

func _test_specials() -> void:
	print("# infectés spéciaux")
	var d = Defs.load_all()
	var bad := 0
	for id in ["colossus", "screamer", "alpha"]:
		var t: Dictionary = d.zombie_type(id)
		var arm: Array = t.get("armor", [])
		if t.is_empty() or arm.size() != 3 or float(t.get("hp", 0)) <= 0.0 or int(t.get("points", 0)) <= 0 or str(t.get("name", "")) == "" or str(t.get("short", "")) == "":
			bad += 1
			continue
		for a in arm:
			if float(a) <= 0.0 or float(a) > 1.0:
				bad += 1
		var sp: Array = t.get("speed", [])
		if sp.size() != 2 or float(sp[0]) <= 0.0 or float(sp[1]) < float(sp[0]):
			bad += 1
	_check(bad == 0, "data/zombies.json : trois types, blindage à trois valeurs dans ]0 ; 1], vitesse, points, noms (%d anomalies)" % bad)

	# --- vagues spéciales par secteur et par difficulté : « min_level » les réserve à Vétéran et au-delà dans les secteurs serrés
	var nsp := {}
	var same_vet := true
	for sc in d.sectors:
		var base: Dictionary = Campaign.load_mission(d, str(sc["id"]))
		var row: Array = []
		for lid in ["recruit", "veteran", "nightmare"]:
			var mm: Dictionary = Campaign.apply_difficulty(base, d.level(lid))
			var n_sp := 0
			for w in mm["waves"]:
				if str(w.get("type", "")) == "special":
					n_sp += 1
			row.append(n_sp)
			if lid == "veteran":
				same_vet = same_vet and (mm["waves"] as Array).size() == (base["waves"] as Array).size()
		nsp[str(sc["id"])] = row
	_check(nsp["mission_01"] == [0, 0, 0] and nsp["mission_02"] == [2, 2, 2] and nsp["mission_03"] == [0, 3, 3] and nsp["mission_04"] == [0, 4, 4] and nsp["mission_05"] == [4, 4, 4],
			"vagues spéciales (Recrue, Vétéran, Cauchemar) : aucune au secteur 1, 2/2/2, 0/3/3, 0/4/4 et 4/4/4 : %s" % str(nsp))
	_check(same_vet, "Vétéran garde toutes les vagues de chaque secteur (« min_level » ne retire rien à la difficulté de référence)")

	# --- colosse
	var ctx = _world5()
	var cr = ctx.crowd
	var c = cr.spawn_special(Crowd.ZT_COLOSSUS, ctx.gunship.center, 200.0, 900.0)
	if c == null:
		_check(false, "colosse : aucune rue disponible pour le faire apparaître")
		return
	_check(c.ztype == Crowd.ZT_COLOSSUS and _near(c.hp, 780.0) and c.scale_v > 1.5 and _near(c.door_mult, 4.5) and c.points == 300 and not c.runner,
			"colosse : %d PV, taille ×%.2f, portes ×%.1f, %d points" % [int(c.hp), c.scale_v, c.door_mult, c.points])
	var hp0: float = c.hp
	var cuts: Array = []
	for w in 3:
		var before: float = c.hp
		cr.damage_area(c.pos.x, c.pos.y, 0.05, 100.0, 0.0, w)
		cuts.append(before - c.hp)
	_check(_near(cuts[0], 4.0) and _near(cuts[1], 30.0) and _near(cuts[2], 100.0), "blindage du colosse : %.0f / %.0f / %.0f %% des dégâts (25 mm, 40 mm, 105 mm)" % cuts)
	c.hp = hp0
	# la chaîne complète : un obus de chaque arme tombe sur lui
	var dealt: Array = []
	for w in 3:
		var before: float = c.hp
		_impact5(ctx, w, c.pos.x, c.pos.y)
		dealt.append(before - c.hp)
	_check(_near(dealt[0], 1.12, 0.01) and _near(dealt[1], 39.0, 0.01) and _near(dealt[2], 500.0, 0.01),
			"obus sur le colosse : %.2f (25 mm), %.1f (40 mm), %.0f (105 mm) points de vie retirés" % dealt)
	c.hp = hp0
	for i in 300:
		_impact5(ctx, 0, c.pos.x, c.pos.y)
	_check(c.kind == Crowd.K_ZOMBIE and c.hp > 0.55 * hp0, "300 obus de 25 mm n'entament pas le colosse (%.0f %% de ses PV restent)" % (100.0 * c.hp / hp0))
	c.hp = hp0
	_impact5(ctx, 2, c.pos.x, c.pos.y)
	var alive_after_one: bool = c.kind == Crowd.K_ZOMBIE
	_impact5(ctx, 2, c.pos.x, c.pos.y)
	_check(alive_after_one and c.kind == Crowd.K_DEAD, "deux obus de 105 mm abattent le colosse (un seul ne suffit pas)")
	var st: Dictionary = ctx.score.st
	_check(int(st["kills_colossus"]) == 1 and int(st["specials"]) == 1 and ctx.director.kills == 1 and ctx.score.points >= 300,
			"abattre un colosse : compté dans les spéciaux (%d), %d points" % [int(st["specials"]), ctx.score.points])
	_check(_radio_said(ctx, "colosse neutralisé"), "la radio annonce « colosse neutralisé »")

	# --- le colosse enfonce les portes 4,5 fois plus vite
	var sg = _world5()
	var b1: int = _first_targetable(sg)
	var b2: int = _first_targetable(sg, b1)
	var col = sg.crowd.spawn_special(Crowd.ZT_COLOSSUS, sg.gunship.center, 200.0, 900.0)
	var zom = sg.crowd.spawn_zombie(0, 0.5)
	if col != null and zom != null and b1 >= 0 and b2 >= 0:
		for pair in [[col, b1], [zom, b2]]:
			var z = pair[0]
			var b: int = pair[1]
			z.mode = 3
			z.target_b = b
			z.face = Vector2(sg.city.b_cx[b], sg.city.b_cz[b])
			z.has_face = true
			z.idle = 0.0
		for i in 10:
			sg.crowd.step(0.1)
		var ratio: float = float(sg.buildings.siege[b1]) / maxf(float(sg.buildings.siege[b2]), 0.0001)
		_check(_near(ratio, 4.5, 0.15), "siège : le colosse martèle une porte %.1f fois plus vite qu'un infecté ordinaire" % ratio)
	else:
		_check(false, "siège : colosse, zombie ou immeubles introuvables")

	# --- hurleur
	var sc = _world5()
	var scr = sc.crowd
	var s = scr.spawn_special(Crowd.ZT_SCREAMER, sc.gunship.center, 200.0, 900.0)
	if s == null:
		_check(false, "hurleur : aucune rue disponible")
		return
	var nb = scr.spawn_zombie(s.edge, clampf(s.t + 0.02, 0.02, 0.98))
	var far_e: int = _edge_far(sc, s.pos, 400.0)
	var far = scr.spawn_zombie(far_e, 0.5)
	_freeze(sc)
	_check(s.ztype == Crowd.ZT_SCREAMER and s.hp < 40.0 and s.scream_t >= 1.5 and s.scream_t <= 3.5, "hurleur : fragile (%d PV), premier cri dans %.1f s" % [int(s.hp), s.scream_t])
	var steps := 0
	while scr.screams < 1 and steps < 60:
		scr.step(0.1)
		steps += 1
	_check(scr.screams == 1 and nb.frenzy > 4.0 and far.frenzy <= 0.0, "le hurleur crie : le voisin s'emballe (%.1f s de frénésie), l'infecté éloigné non" % nb.frenzy)
	_check(_near(scr._eff_speed(nb) / nb.speed, 1.7, 0.01) and _near(scr._eff_speed(far) / far.speed, 1.0, 0.01), "frénésie : vitesse ×%.1f pour le voisin, ×1 pour l'éloigné" % (scr._eff_speed(nb) / nb.speed))
	var steps2 := 0
	while scr.screams < 2 and steps2 < 120:
		scr.step(0.1)
		steps2 += 1
	_check(scr.screams == 2 and absf(float(steps2) * 0.1 - 7.0) <= 0.3, "il crie de nouveau %.1f s plus tard (toutes les 7 s)" % (float(steps2) * 0.1))
	for i in 60:
		scr.step(0.1)
	_check(nb.frenzy <= 0.0, "la frénésie retombe au bout de 5 s")
	var hp_s: float = s.hp
	scr.damage_area(s.pos.x, s.pos.y, 0.05, 28.0, 0.0, 0)
	var alive_one: bool = s.kind == Crowd.K_ZOMBIE
	scr.damage_area(s.pos.x, s.pos.y, 0.05, 28.0, 0.0, 0)
	_check(hp_s <= 40.0 and alive_one and s.kind == Crowd.K_DEAD and int(sc.score.st["kills_screamer"]) == 1, "deux obus de 25 mm font taire le hurleur (compté dans les spéciaux)")

	# --- alpha et sa meute
	var ac = _world5()
	var acr = ac.crowd
	var a = acr.spawn_special(Crowd.ZT_ALPHA, ac.gunship.center, 200.0, 900.0)
	if a == null:
		_check(false, "alpha : aucune rue disponible")
		return
	var pack: Array = []
	for i in acr.MAX_P:
		var q = acr.pool[i]
		if q.alive and q.pack == a.id + 1:
			pack.append(q)
	_check(a.pack == 0 and pack.size() >= 5 and pack.size() <= 8 and acr.count_special(Crowd.ZT_ALPHA) == 1, "alpha : une meute de %d infectés (de 5 à 8)" % pack.size())
	acr.step(0.25)
	_check(_near(acr._eff_speed(pack[0]) / pack[0].speed, 1.3, 0.01), "la meute court %.1f fois plus vite tant que l'alpha vit" % (acr._eff_speed(pack[0]) / pack[0].speed))
	for i in 40:
		acr.step(0.1)
	var same := 0
	for m in pack:
		if m.target_b == a.target_b:
			same += 1
	_check(a.target_b >= 0 and same == pack.size(), "la meute vise l'immeuble de son chef (%d / %d)" % [same, pack.size()])
	var armor_a: Array = []
	var hp_a: float = a.hp
	for w in 3:
		var before: float = a.hp
		acr.damage_area(a.pos.x, a.pos.y, 0.05, 100.0, 0.0, w)
		armor_a.append(before - a.hp)
	_check(_near(armor_a[0], 50.0) and _near(armor_a[1], 80.0) and _near(armor_a[2], 100.0) and a.kind == Crowd.K_ZOMBIE, "blindage de l'alpha : 50 / 80 / 100 % des dégâts")
	a.hp = hp_a
	var alive_pack: Array = pack.filter(func(q): return q.alive and q.kind == Crowd.K_ZOMBIE)
	acr.damage_area(a.pos.x, a.pos.y, 0.05, 500.0, 0.0, 2)
	var released := true
	var panicked := true
	for m in alive_pack:
		if m.pack != 0:
			released = false
		if m.mode != 3 and not m.rising and (m.mode != 0 or m.idle < 4.4):
			panicked = false
	_check(a.kind == Crowd.K_DEAD and released and panicked, "l'alpha tombe : la meute ne le suit plus et s'immobilise 4,5 s (%d infectés)" % alive_pack.size())
	_check(int(ac.score.st["kills_alpha"]) == 1 and _radio_said(ac, "alpha neutralisé"), "alpha compté dans les spéciaux, annoncé à la radio")

	# --- vagues « spéciales » du directeur
	var dw = _world5()
	dw.director._fire_wave({"type": "special", "zt": "colossus", "count": 2, "r_min": 300.0, "r_max": 800.0})
	_check(dw.crowd.count_special(Crowd.ZT_COLOSSUS) == 2 and _radio_said(dw, "colosse repéré"), "vague spéciale : deux colosses apparaissent, la radio les annonce")
	dw.director._fire_wave({"type": "special", "zt": "alpha", "count": 1, "r_min": 300.0, "r_max": 800.0})
	_check(dw.crowd.count_special(Crowd.ZT_ALPHA) == 1 and dw.crowd.n_zombies >= 8, "vague spéciale : un alpha arrive avec sa meute (%d infectés en tout)" % dw.crowd.n_zombies)
	var before_n: int = dw.crowd.count_special()
	dw.director._fire_wave({"type": "special", "zt": "dragon", "count": 3})
	_check(dw.crowd.count_special() == before_n, "vague spéciale de type inconnu : ignorée")


# ---------------------------------------------------------------- appuis ponctuels

func _test_supports() -> void:
	print("# appuis ponctuels")
	var d = Defs.load_all()
	var ids: Array = []
	for s in d.supports:
		ids.append(str(s["id"]))
	_check(ids == ["barrage", "drone", "decoy", "drop"], "quatre appuis, dans l'ordre des touches 4 à 7 : %s" % str(ids))
	# la boutique décrit ce que le jeu fait
	var bad := 0
	for s in d.supports:
		var it: Dictionary = d.up_by_id.get(str(s["upgrade"]), {})
		if it.is_empty() or (it["levels"] as Array).size() != (s["levels"] as Array).size() or int(s["key"]) != 4 + ids.find(str(s["id"])):
			bad += 1
			continue
		for k in (s["levels"] as Array).size():
			var lv: Dictionary = s["levels"][k]
			var txt := str(it["levels"][k]["desc"])
			var needles: Array = ["%d appel" % int(lv["charges"]), "recharge %d s" % int(lv["cooldown_s"])]
			match str(s["id"]):
				"barrage":
					needles.append_array(["%d obus" % int(lv["shells"]), "%d m" % int(lv["radius_m"])])
				"drone", "decoy":
					needles.append_array(["%d s," % int(lv["duration_s"]), "rayon %d m" % int(lv["radius_m"])])
				"drop":
					needles.append("caissons pleins" if float(lv["refill"]) >= 1.0 else "+%d %%" % int(round(float(lv["refill"]) * 100.0)))
			for nd in needles:
				if not txt.contains(str(nd)):
					bad += 1
					print("     boutique : « %s » ne contient pas « %s »" % [txt, nd])
			if int(it["levels"][k]["effects"].get("mod.sup_" + str(s["id"]), 0)) != k + 1:
				bad += 1
	_check(bad == 0, "la boutique décrit exactement les appuis de data/supports.json (%d écarts)" % bad)

	# --- non acheté, charges, recharge
	var ctx = _world5()
	var sp = ctx.supports
	var at: Vector2 = ctx.gunship.center
	_check(sp.request("barrage", at).contains("non acheté") and sp.calls == 0 and sp.state_of("barrage") == "none" and sp.owned_ids().is_empty(),
			"appui non acheté : refusé (« %s »)" % sp.last_refused)
	_check(sp.request("inconnu", at) != "", "appui inconnu : refusé")
	ctx.mods = {"sup_barrage": 2, "sup_drone": 2, "sup_decoy": 2, "sup_drop": 2}
	sp.reset()
	_check(sp.owned_ids().size() == 4 and int(sp.charges["barrage"]) == 2 and sp.state_of("barrage") == "ready" and sp.ready("barrage"), "niveau 2 acheté : 2 appels de barrage disponibles")
	_check(sp.request("barrage", at) == "" and sp.shells.size() == 7 and sp.calls == 1 and int(ctx.score.st["supports"]) == 1 and sp.state_of("barrage") == "active",
			"barrage demandé : 7 obus en route, appel compté, appui actif")
	_check(_radio_said(ctx, "barrage demandé"), "la radio répète l'appel")
	var again: String = sp.request("barrage", at)
	_check(again.contains("recharge") and int(sp.charges["barrage"]) == 1 and sp.calls == 1, "second appel immédiat : refusé, en recharge (« %s »)" % again)
	_run5(ctx, 61.0)
	_check(sp.shells.is_empty() and sp.state_of("barrage") == "ready", "au bout de la recharge (60 s), l'appui est de nouveau prêt")
	_check(sp.request("barrage", at) == "" and int(sp.charges["barrage"]) == 0, "second appel accepté : plus aucun appel en réserve")
	_run5(ctx, 70.0)
	_check(sp.state_of("barrage") == "empty" and sp.request("barrage", at).contains("plus d'appel") and sp.calls == 2, "réserve épuisée : refusé (« %s »)" % sp.last_refused)
	sp.reset()
	_check(int(sp.charges["barrage"]) == 2 and sp.calls == 0 and sp.shells.is_empty(), "une nouvelle mission remet les appels à zéro")
	ctx.director.state = "won"
	_check(sp.request("drone", at).contains("terminée") and sp.calls == 0, "mission terminée : plus d'appui")
	ctx.director.state = "running"

	# --- barrage : calendrier des obus, précision, comptage
	var tb = _world5({"sup_barrage": 3})
	var spb = tb.supports
	var cb: Vector2 = tb.gunship.center
	_check(spb.request("barrage", cb) == "" and spb.shells.size() == 9, "barrage de niveau 3 : 9 obus")
	var inside := true
	for sh in spb.shells:
		if (sh[1] as Vector2).distance_to(cb) > 60.01:
			inside = false
	_check(inside, "les 9 obus sont tirés dans les 60 m du point visé")
	var first := -1.0
	var last := -1.0
	for i in 120:
		_run5(tb, 0.1)
		if first < 0.0 and spb.shells.size() < 9:
			first = tb.time
		if last < 0.0 and spb.shells.is_empty():
			last = tb.time
	_check(first >= 5.95 and last <= 9.65 and last > first, "les obus tombent entre %.1f s et %.1f s après l'appel (6 s de délai, 3,5 s d'étalement)" % [first, last])
	_check(tb.arms.shots == 0 and int(tb.score.st["shells"]) == 0, "le barrage ne compte ni dans les tirs ni dans la précision du joueur")

	# bout en bout : des infectés immobiles là où tombent les obus meurent, un autre, loin, survit
	var ke = _world5({"sup_barrage": 3})
	var kc = ke.crowd
	var ground: Array = []
	for attempt in 12:
		var cand: Vector2 = kc.pick_street_point(ke.gunship.center, 50.0, 600.0)
		if cand == Vector2.INF:
			continue
		ke.supports.reset()
		if ke.supports.request("barrage", cand) != "":
			continue
		ground.clear()
		for sh in ke.supports.shells:
			var pt: Vector2 = sh[1]
			var h: Dictionary = ke.buildings.trace(Vector3(pt.x, 1500.0, pt.y), Vector3.DOWN)
			if h["pos"].y < 4.0:
				ground.append(pt)
		if ground.size() >= 3:
			break
	var placed: Array = []
	for pt in ground:
		var z = kc.spawn_zombie(0, 0.5)
		z.pos = pt
		z.idle = 9999.0
		placed.append(z)
	var ctrl = kc.spawn_zombie(0, 0.5)
	var tgt: Vector2 = ke.supports.marks[0]["pos"] if not ke.supports.marks.is_empty() else ke.gunship.center
	ctrl.pos = tgt + Vector2(400.0, 0.0)
	ctrl.idle = 9999.0
	_run5(ke, 11.0)
	var dead := 0
	for z in placed:
		if z.kind == Crowd.K_DEAD:
			dead += 1
	_check(ground.size() >= 3 and dead >= ground.size() and ctrl.kind == Crowd.K_ZOMBIE, "barrage : %d infectés placés sur les points d'impact au sol, %d morts ; l'infecté éloigné survit" % [ground.size(), dead])
	_check(int(ke.score.st["support_kills"]) == ke.director.kills and ke.director.kills >= dead, "morts du barrage comptées à part (%d)" % int(ke.score.st["support_kills"]))

	# --- largage de munitions
	var td = _world5({"sup_drop": 1})
	for i in 3:
		td.arms.ammo[i] = 0.0
	_check(td.supports.request("drop", td.gunship.center) == "" and td.supports.state_of("drop") == "active", "largage demandé : en route")
	_run5(td, 3.5)
	_check(td.arms.ammo[2] < 1.0 and td.arms.ammo[1] < 5.0, "avant l'arrivée du largage (4 s), les caissons sont toujours vides")
	_run5(td, 1.5)
	var okr := true
	for i in 3:
		var cap := float(td.weapons[i]["ammo"])
		var regen := float(td.weapons[i]["regen_per_s"])
		if td.arms.ammo[i] < cap * 0.5 or td.arms.ammo[i] > cap * 0.5 + regen * 6.0 + 1.0:
			okr = false
	_check(okr and td.supports.state_of("drop") == "empty", "le largage de niveau 1 rend la moitié des munitions (%d / %d / %d)" % [int(td.arms.ammo[0]), int(td.arms.ammo[1]), int(td.arms.ammo[2])])
	_check(_radio_said(td, "munitions reçues"), "la radio annonce la livraison")
	var tf = _world5({"sup_drop": 3})
	for i in 3:
		tf.arms.ammo[i] = float(tf.weapons[i]["ammo"]) * 0.8
	tf.supports.request("drop", tf.gunship.center)
	_run5(tf, 4.2)
	var full := true
	for i in 3:
		if tf.arms.ammo[i] > float(tf.weapons[i]["ammo"]) + 0.001 or tf.arms.ammo[i] < float(tf.weapons[i]["ammo"]) - 0.001:
			full = false
	_check(full, "largage de niveau 3 : caissons pleins, sans dépasser la capacité")

	# --- drone : les infectés du cercle seulement, avec l'immeuble qu'ils visent
	var tn = _world5({"sup_drone": 1})
	var dc: Vector2 = tn.gunship.center
	tn.crowd.spawn_cluster(dc, 20.0, 250.0, 12)
	tn.crowd.spawn_cluster(dc, 420.0, 580.0, 12)         # hors des 350 m du drone, mais dans la zone de jeu (600 m)
	_freeze(tn)
	var seen_one = null
	for i in tn.crowd.MAX_P:
		var z = tn.crowd.pool[i]
		if z.alive and z.pos.distance_to(dc) < 250.0:
			seen_one = z
			break
	var tb1: int = _first_targetable(tn)
	if seen_one != null and tb1 >= 0:
		seen_one.mode = 1
		seen_one.target_b = tb1
	_check(tn.supports.drone_contacts().is_empty(), "drone non lancé : aucun contact")
	var drone_at: Vector2 = dc
	_check(tn.supports.request("drone", drone_at) == "" and tn.supports.state_of("drone") == "active", "drone lancé")
	var want_in := 0
	for i in tn.crowd.MAX_P:
		var z = tn.crowd.pool[i]
		if z.alive and z.kind == Crowd.K_ZOMBIE and z.pos.distance_to(drone_at) <= 350.0:
			want_in += 1
	var contacts: Array = tn.supports.drone_contacts()
	var all_in := true
	var with_target := 0
	for c2 in contacts:
		if (c2["pos"] as Vector2).distance_to(drone_at) > 350.01:
			all_in = false
		if c2["target"] != Vector2.INF:
			with_target += 1
	_check(contacts.size() == want_in and want_in >= 12 and all_in and tn.crowd.n_zombies >= want_in + 6, "le drone cerne les %d infectés des 350 m, pas les %d autres" % [want_in, tn.crowd.n_zombies - want_in])
	_check(with_target == 1 and seen_one != null, "il montre l'immeuble visé par l'infecté qui en a un (%d)" % with_target)
	_run5(tn, 26.0)
	_check(tn.supports.drone_contacts().is_empty() and tn.supports.active_left("drone") <= 0.0 and tn.supports.state_of("drone") == "empty", "au bout de 25 s, le drone repart")

	# --- leurre sonore : les infectés errants convergent, par paquets de 24 au plus par tick, sauf ceux qui sont à une porte
	var tl = _world5({"sup_decoy": 3})
	var lc: Vector2 = tl.gunship.center
	tl.crowd.spawn_cluster(lc, 30.0, 200.0, 40)
	var door_b: int = _nearest_targetable(tl, lc)
	var sieger = tl.crowd.spawn_zombie(tl.city.b_door_edge[door_b], tl.city.b_door_t[door_b])
	sieger.mode = 3
	sieger.target_b = door_b
	sieger.face = Vector2(tl.city.b_cx[door_b], tl.city.b_cz[door_b])
	sieger.has_face = true
	_check(tl.supports.request("decoy", lc) == "" and tl.crowd.decoy_left > 0.0 and tl.supports.state_of("decoy") == "active", "leurre lancé (30 s, rayon 420 m)")
	var dpos: Vector2 = tl.crowd.decoy_pos
	var mean0 := 0.0
	var n_in := 0
	for i in tl.crowd.MAX_P:
		var z = tl.crowd.pool[i]
		if z.alive and z.kind == Crowd.K_ZOMBIE and z != sieger and z.pos.distance_to(dpos) < 420.0:
			mean0 += z.pos.distance_to(dpos)
			n_in += 1
	mean0 /= maxf(float(n_in), 1.0)
	tl.crowd.step(0.21)
	var n_dec := 0
	for i in tl.crowd.MAX_P:
		var z = tl.crowd.pool[i]
		if z.alive and z.mode == Crowd.MODE_DECOY:
			n_dec += 1
	_check(n_dec >= 20 and n_dec <= 24 and n_in > 24, "premier tick : %d infectés détournés sur %d (24 au plus par tick : le bruit se propage, il ne téléporte pas)" % [n_dec, n_in])
	_run5(tl, 5.0)
	n_dec = 0
	for i in tl.crowd.MAX_P:
		var z = tl.crowd.pool[i]
		if z.alive and z.mode == Crowd.MODE_DECOY:
			n_dec += 1
	_check(n_dec >= n_in - 4, "quelques secondes plus tard, presque tous les infectés du rayon convergent (%d / %d)" % [n_dec, n_in])
	_check(sieger.mode == 3, "l'infecté qui martèle une porte n'est pas attiré")
	_run5(tl, 20.0)
	var mean1 := 0.0
	var n1 := 0
	for i in tl.crowd.MAX_P:
		var z = tl.crowd.pool[i]
		if z.alive and z.kind == Crowd.K_ZOMBIE and z.mode == Crowd.MODE_DECOY:
			mean1 += z.pos.distance_to(dpos)
			n1 += 1
	mean1 /= maxf(float(n1), 1.0)
	_check(n1 > 0 and mean1 < mean0 - 20.0, "en 25 s, les infectés attirés se rapprochent du leurre (distance moyenne %.0f m -> %.0f m)" % [mean0, mean1])
	_run5(tl, 8.0)
	var left_dec := 0
	for i in tl.crowd.MAX_P:
		var z = tl.crowd.pool[i]
		if z.alive and z.mode == Crowd.MODE_DECOY:
			left_dec += 1
	_check(tl.crowd.decoy_left <= 0.0 and left_dec == 0, "le leurre se tait : plus personne n'est attiré")

	# --- les appuis restent utilisables en panne radio, sans annonce de la station
	var rr = _world5({"sup_drone": 1}, "campaign", ["radio_down"])
	_check(rr.supports.request("drone", rr.gunship.center) == "" and not _radio_said(rr, "demandé"), "panne radio : l'appui part, sa réplique radio est supprimée")


# ---------------------------------------------------------------- défi du jour

## Monde d'un scénario du jour : secteur, mutateurs, graine de la ville et graine des vagues.
func _plan_world(d, plan: Dictionary, perturb_rng: bool):
	var base: Dictionary = Campaign.load_mission(d, str(plan["sector"]))
	var m: Dictionary = Mutators.apply(Campaign.apply_difficulty(base, d.level(str(plan["level"]))), d, plan["mutators"])
	var c: Dictionary = m["city"]
	var ctx = _make_world(int(plan["seed"]), m, float(c["size"]), str(c["style"]), "daily", plan["mutators"], str(c.get("file", "")))
	ctx.wave_rng.seed = int(plan["wave_seed"])
	if perturb_rng:
		for i in 137:
			ctx.rng.randf()            # les tirs et les effets du joueur consomment ce générateur à leur rythme
	return ctx


func _test_daily() -> void:
	print("# défi du jour")
	var d = Defs.load_all()
	_check(Daily.seed_of("abc") == 440920331 and Daily.seed_of("") == 2166136261, "graine d'un texte : FNV-1a 32 bits (« abc » -> %d)" % Daily.seed_of("abc"))
	_check(Daily.valid_date("2026-11-23") and not Daily.valid_date("2026-13-01") and not Daily.valid_date("26-11-23") and not Daily.valid_date("2026-11-xx")
			and not Daily.valid_date("nonsense") and not Daily.valid_date("2026-00-10") and not Daily.valid_date("2026-11-32") and not Daily.valid_date(""), "dates valides ou non")
	_check(Daily.previous_day("2026-03-01") == "2026-02-28" and Daily.previous_day("2024-03-01") == "2024-02-29" and Daily.previous_day("2027-01-01") == "2026-12-31"
			and Daily.previous_day("nonsense") == "", "veille d'une date : fin de mois, année bissextile, nouvel an, date invalide")
	var cfg: Dictionary = d.mode_cfg("daily")
	var prob := 0.0
	for p in cfg["mutators"]:
		prob += float(p)
	_check(_near(prob, 1.0) and int(cfg["board"]) >= 5 and d.level_by_id.has(str(cfg["level"])), "data/modes.json : probabilités de mutateurs = 1, classement, niveau %s" % str(cfg["level"]))

	var p1: Dictionary = Daily.plan(d, "2026-11-23")
	_check(_deep_equal(p1, Daily.plan(d, "2026-11-23")) and not _deep_equal(p1, Daily.plan(d, "2026-11-24")), "le scénario ne dépend que de la date : identique à chaque appel, différent d'un jour à l'autre")
	var v := Engine.get_version_info()
	if int(v["major"]) == 4 and int(v["minor"]) == 7:
		var pins := {
			"2026-11-23": ["mission_04", ["doors_strong"], 42965, 3234592821],
			"2026-11-24": ["mission_01", ["doors_weak"], 34085, 2984488021],
			"2026-12-25": ["mission_05", [], 45051, 4102473064],
			"2027-01-01": ["mission_01", ["fog"], 80852, 2267268642],
			"2024-02-29": ["mission_03", [], 5815, 3208735438],
		}
		var drift := 0
		for date in pins:
			var pl: Dictionary = Daily.plan(d, str(date))
			var want: Array = pins[date]
			if str(pl["sector"]) != want[0] or pl["mutators"] != want[1] or int(pl["seed"]) != int(want[2]) or int(pl["wave_seed"]) != int(want[3]) or str(pl["level"]) != "veteran":
				drift += 1
				print("     %s -> %s" % [date, str(pl)])
		_check(drift == 0, "scénarios épinglés (5 dates relevées avec Godot 4.7) : inchangés (%d écarts)" % drift)
	else:
		print("  --     scénarios épinglés non vérifiés : relevés avec Godot 4.7, ici %s" % str(v["string"]))

	# toute une année : secteurs et mutateurs valides, répartition plausible
	var t0 := int(Time.get_unix_time_from_datetime_string("2026-01-01T12:00:00"))
	var bad := 0
	var n_mut := [0, 0, 0]
	var by_sector := {}
	var by_mut := {}
	var wave_seeds := {}
	for i in 365:
		var date := Time.get_date_string_from_unix_time(t0 + i * 86400)
		var pl: Dictionary = Daily.plan(d, date)
		var ms: Array = pl["mutators"]
		if not d.sector_by_id.has(str(pl["sector"])) or Mutators.clean(d, ms).size() != ms.size() or ms.size() > 2 or str(pl["level"]) != str(cfg["level"]) \
				or int(pl["seed"]) < 1000 or int(pl["seed"]) >= 91000 or str(pl["date"]) != date:
			bad += 1
		n_mut[mini(ms.size(), 2)] += 1
		by_sector[str(pl["sector"])] = int(by_sector.get(str(pl["sector"]), 0)) + 1
		for m in ms:
			by_mut[str(m)] = int(by_mut.get(str(m), 0)) + 1
		wave_seeds[int(pl["wave_seed"])] = true
	_check(bad == 0, "365 jours de scénarios : secteur existant, mutateurs compatibles (deux au plus), graine de ville dans la plage (%d anomalies)" % bad)
	print("   année 2026 : mutateurs 0/1/2 = %s, secteurs %s, mutateurs %s" % [str(n_mut), str(by_sector), str(by_mut)])
	_check(n_mut[0] >= 90 and n_mut[0] <= 170 and n_mut[1] >= 130 and n_mut[1] <= 200 and n_mut[2] >= 40 and n_mut[2] <= 110, "répartition des mutateurs proche de 35 / 45 / 20 %")
	_check(by_sector.size() == d.sectors.size() and by_mut.size() == d.mutators.size() and wave_seeds.size() >= 360, "tous les secteurs et tous les mutateurs reviennent dans l'année ; graines de vagues presque toutes différentes (%d)" % wave_seeds.size())

	# mêmes vagues pour tous : le générateur des vagues est isolé de celui des tirs et des effets
	var plan: Dictionary = Daily.plan(d, "2026-11-23")
	var wa = _plan_world(d, plan, false)
	var wb = _plan_world(d, plan, true)
	var wc = _plan_world(d, plan, false)
	wc.wave_rng.seed = int(plan["wave_seed"]) + 1
	for w in [wa, wb, wc]:
		w.director.start()
	var t_first: float = float(wa.director.waves[0]["t"])
	for step in int((t_first + 3.0) / 0.1):
		for w in [wa, wb, wc]:
			_sim(w, 0.1)
	var sa: Vector2 = wa.crowd.last_spawn
	var sb: Vector2 = wb.crowd.last_spawn
	var sc2: Vector2 = wc.crowd.last_spawn
	_check(wa.director.t > t_first and sa != Vector2.ZERO and sa.distance_to(sb) < 0.01, "même graine de vagues : le premier groupe (%.0f s) apparaît au même endroit, même si le joueur a tiré entre-temps (%.0f ; %.0f)" % [t_first, sa.x, sa.y])
	_check(sa.distance_to(sc2) > 1.0, "autre graine de vagues : le groupe apparaît ailleurs")
	_check(wa.crowd.n_zombies + wa.buildings.zombies_inside() > 0 and wa.mutators == plan["mutators"] and wa.mode == "daily", "le monde du défi porte le mode et les mutateurs du scénario")


# ---------------------------------------------------------------- Nuit blanche

## Monde de Nuit blanche, construit comme le jeu : la mission du secteur passe par la difficulté, les mutateurs, puis par
## Main._build_mission (calendrier des vagues, seuils de note, objectifs en cycles).
func _endless_world(sector_id: String = "mission_02", level_id: String = "veteran", mutators: Array = [], seed_v: int = -1):
	var d = Defs.load_all()
	var base: Dictionary = Campaign.load_mission(d, sector_id)
	var mn = Main.new()
	mn.ctx = Ctx.new()
	mn.ctx.mode = "endless"
	mn.ctx.mutators = Mutators.clean(d, mutators)
	var m: Dictionary = mn._build_mission(d, base, level_id)
	mn.free()
	var c: Dictionary = m["city"]
	return _make_world(int(c["seed"]) if seed_v < 0 else seed_v, m, float(c["size"]), str(c["style"]), "endless", mutators, str(c.get("file", "")))


func _test_endless() -> void:
	print("# Nuit blanche")
	var d = Defs.load_all()
	var ec: Dictionary = d.mode_cfg("endless")
	var bad := 0
	for k in ["screamer", "alpha", "colossus"]:
		var sch: Dictionary = ec["specials"][k]
		if int(sch["every"]) < 1 or int(sch["from"]) < 1:
			bad += 1
	var iv: Array = ec["interval_s"]
	var cn: Array = ec["count"]
	var rt: Array = ec["rating"]
	if float(iv[1]) >= float(iv[0]) or int(cn[1]) <= int(cn[0]) or rt.size() != 4 or float(ec["hp_growth"]) <= 0.0:
		bad += 1
	for i in range(1, rt.size()):
		if int(rt[i]) <= int(rt[i - 1]):
			bad += 1
	_check(bad == 0, "data/modes.json : calendrier des spéciaux, intervalles décroissants, effectifs croissants, seuils de note croissants (%d anomalies)" % bad)

	# objectifs qui reviennent par cycles (fonction de la scène principale, appelée sans la scène)
	var mn = Main.new()
	var base: Dictionary = Campaign.load_mission(d, "mission_02")
	var n_sec_base := 0
	var n_hid_base := 0
	for o in base["objectives"]:
		if str(o.get("kind", "secondary")) == "hidden":
			n_hid_base += 1
		else:
			n_sec_base += 1
	var cyc_obj: Array = mn._endless_objectives(base["objectives"], ec)
	mn.free()
	var ids := {}
	var dup := 0
	var n_sec := 0
	var n_hid := 0
	for o in cyc_obj:
		if ids.has(str(o["id"])):
			dup += 1
		ids[str(o["id"])] = true
		if str(o.get("kind", "secondary")) == "hidden":
			n_hid += 1
		else:
			n_sec += 1
	_check(dup == 0 and n_sec == n_sec_base * int(ec["objective_cycles"]) and n_hid == n_hid_base, "objectifs de Nuit blanche : %d secondaires en %d cycles, %d cachés une seule fois, identifiants uniques" % [n_sec, int(ec["objective_cycles"]), n_hid])

	# génération des vagues
	var ctx = _endless_world()
	var dr = ctx.director
	_check(dr.endless and dr.duration == INF and dr.max_lost == int(ec["max_lost"]) and dr.waves.is_empty() and ctx.mode == "endless", "directeur en Nuit blanche : sans fin, %d civils perdus au plus, aucune vague écrite" % dr.max_lost)
	dr.max_lost = 100000                 # on mesure le générateur de vagues, pas la survie du secteur
	dr.start()
	_check(_radio_said(ctx, "nuit blanche"), "la radio ouvre la Nuit blanche")
	var seen := {}
	var waves_at: Array = []
	var last_n := 0
	var hp_before: float = ctx.rule("zombie_hp", 40.0)
	var run_before: float = ctx.rule("runner_ratio", 0.2)
	for i in 1800:
		_sim(ctx, 0.2)
		if dr.wave_n != last_n:
			last_n = dr.wave_n
			waves_at.append(dr.t)
		for zt in [Crowd.ZT_SCREAMER, Crowd.ZT_ALPHA, Crowd.ZT_COLOSSUS]:
			if ctx.crowd.count_special(zt) > 0:
				seen[zt] = true
		if dr.wave_n >= 9 and seen.size() == 3:
			break
	print("   vagues à t = %s" % str(waves_at.map(func(t): return int(t))))
	_check(dr.wave_n >= 9 and dr.state == "running", "neuf vagues lancées en %.0f s" % dr.t)
	_check(absf(float(waves_at[0]) - float(ec["first_wave_s"])) < 0.3, "la première vague arrive à %.0f s" % float(waves_at[0]))
	var gaps_ok := true
	for i in range(1, waves_at.size()):
		var gap: float = float(waves_at[i]) - float(waves_at[i - 1])
		if gap > float(iv[0]) + 0.3 or gap < float(iv[1]) - 0.3:
			gaps_ok = false
	_check(gaps_ok and float(waves_at[waves_at.size() - 1]) - float(waves_at[waves_at.size() - 2]) < float(waves_at[1]) - float(waves_at[0]), "l'intervalle entre vagues reste entre %d s et %d s et raccourcit" % [int(iv[0]), int(iv[1])])
	_check(ctx.wave_no == dr.wave_n and int(ctx.score.st["waves"]) == dr.wave_n - 1, "la vague en cours est publiée (%d) ; la précédente est comptée tenue (%d)" % [ctx.wave_no, int(ctx.score.st["waves"])])
	_check(seen.size() == 3, "hurleur, alpha et colosse sont apparus selon le calendrier des vagues (4, 6 et 8)")
	_check(ctx.rule("zombie_hp", 40.0) > hp_before * 1.05 and ctx.rule("runner_ratio", 0.2) > run_before, "les infectés d'une vague tardive sont plus coriaces (%.1f PV contre %.1f) et plus souvent des coureurs (%.2f contre %.2f)" % [ctx.rule("zombie_hp", 40.0), hp_before, ctx.rule("runner_ratio", 0.2), run_before])
	_check(_radio_said(ctx, "vague"), "la radio annonce les vagues")
	# fin de patrouille choisie par le joueur : le score est conservé, la patrouille est notée, sans étoile
	for i in ctx.crowd.MAX_P:
		var z = ctx.crowd.pool[i]
		if z.alive and z.kind == Crowd.K_ZOMBIE and ctx.score.points < 3000:
			ctx.crowd.damage_area(z.pos.x, z.pos.y, 0.05, 9999.0, 0.0, 2)
	var pts: int = ctx.score.points
	dr.end_patrol()
	var res: Dictionary = ctx.score.result
	_check(dr.state == "won" and dr.end_reason.contains("Relève") and _radio_said(ctx, "Relève"), "fin de patrouille : état « won », la radio annonce la relève")
	_check(pts > 0 and int(res["total"]) == pts and str(res["mode"]) == "endless" and int(res["waves"]) == dr.wave_n and (res["stars"] as Array).is_empty(),
			"le score est conservé (%d points), le bilan porte le mode et les vagues (%d), aucune étoile" % [int(res["total"]), int(res["waves"])])
	var targets: Array = ec["rating"]
	_check(ctx.score.rating_for(int(targets[0]) - 1) == "D" and ctx.score.rating_for(int(targets[0])) == "C" and ctx.score.rating_for(int(targets[3])) == "S" and str(res["rating"]) != "—",
			"notes de Nuit blanche : seuils %s, patrouille notée %s même si le secteur a souffert" % [str(targets), str(res["rating"])])

	# déterminisme : même graine = même Nuit blanche (sans le joueur)
	var e1 = _endless_world("mission_03", "veteran", [], 77)
	var e2 = _endless_world("mission_03", "veteran", [], 77)
	var e3 = _endless_world("mission_03", "veteran", [], 77)
	e3.wave_rng.seed += 5
	for w in [e1, e2, e3]:
		w.director.max_lost = 100000
		w.director.start()
	for i in 500:
		for w in [e1, e2, e3]:
			_sim(w, 0.2)
	_check(e1.director.wave_n == e2.director.wave_n and e1.crowd.n_zombies == e2.crowd.n_zombies and e1.director.lost == e2.director.lost and e1.crowd.last_spawn.distance_to(e2.crowd.last_spawn) < 0.001,
			"même graine : deux Nuits blanches identiques (vague %d, %d infectés, %d civils perdus)" % [e1.director.wave_n, e1.crowd.n_zombies, e1.director.lost])
	_check(e1.crowd.last_spawn.distance_to(e3.crowd.last_spawn) > 1.0 or e1.crowd.n_zombies != e3.crowd.n_zombies, "autre graine de vagues : une autre nuit")
	# mutateurs en Nuit blanche
	var em0 = _endless_world("mission_02", "veteran", [])
	var em = _endless_world("mission_02", "veteran", ["radio_down", "runners"])
	_check(em.has_mutator("radio_down") and em.rule("runner_ratio", 0.0) > 1.8 * em0.rule("runner_ratio", 0.0) and em0.rule("runner_ratio", 0.0) > 0.0,
			"mutateurs actifs en Nuit blanche (coureurs : %.2f contre %.2f sans le mutateur)" % [em.rule("runner_ratio", 0.0), em0.rule("runner_ratio", 0.0)])
	em.director.start()
	_check(_radio_said(em, "panne de liaison") and not _radio_said(em, "nuit blanche"), "panne radio en Nuit blanche : seule la panne est annoncée")


# ---------------------------------------------------------------- profil : défi du jour et Nuit blanche

func _lines_has(lines: Array, label: String, value: int) -> bool:
	for l in lines:
		if str(l[0]).begins_with(label) and int(l[1]) == value:
			return true
	return false


func _test_modes_profile() -> void:
	print("# profil : défi du jour et Nuit blanche")
	var p = _new_profile()
	var ex := {"date": "2026-11-23", "sector": "mission_04", "mutators": ["fog"], "mut_mult": 1.12}
	var win: Dictionary = _fake_result({"mutators": ["fog"]})
	var r1: Dictionary = p.apply_mission(win, "mission_04", 1.0, 1.0, 1, "daily", ex)
	_check(r1["mode"] == "daily" and r1["daily"]["first_win"] and r1["daily"]["streak"] == 1 and r1["daily"]["rank"] == 1, "premier défi gagné : première victoire du jour, série 1, premier du classement")
	_check(_lines_has(r1["xp_lines"], "Premier défi du jour", 120) and _lines_has(r1["credits_lines"], "Premier défi du jour", 60), "prime du premier défi : 120 XP et 60 crédits")
	var mut_line := false
	for l in r1["xp_lines"]:
		if str(l[0]).begins_with("Mutateurs"):
			mut_line = true
	_check(mut_line, "le multiplicateur des mutateurs apparaît dans les gains")
	_check(r1["new_stars"] == 0 and not r1["new_rating"] and not r1["record"] and p.sector_stars() == 0 and int(p.mission_record("mission_04")["plays"]) == 0,
			"le défi du jour ne touche ni aux étoiles, ni aux notes, ni aux records du secteur")
	_check(int(p.stats["daily_wins"]) == 1 and int(p.daily["wins"]) == 1 and int(p.daily["plays"]) == 1 and p.daily_today("2026-11-23")["won"] and int(p.daily_today("2026-11-23")["best"]) == 6500,
			"compteurs : une victoire, une partie, meilleur score du jour 6 500")
	var got: Array = []
	for m in r1["medals"]:
		got.append(m[0])
	_check(got.has("daily_1") and got.has("mut_win"), "médailles : « Fidèle au poste » et « Sous contrainte » (%s)" % str(got))
	# même jour : pas de seconde prime
	var r2: Dictionary = p.apply_mission(win, "mission_04", 1.0, 1.0, 1, "daily", ex)
	_check(not r2["daily"]["first_win"] and not _lines_has(r2["xp_lines"], "Premier défi du jour", 120) and int(p.daily["streak"]) == 1 and int(p.daily["plays"]) == 2 and int(p.stats["daily_wins"]) == 2,
			"même jour, nouvelle victoire : pas de seconde prime, la série reste à 1")
	# lendemain : série de 2
	var ex2 := ex.duplicate()
	ex2["date"] = "2026-11-24"
	var r3: Dictionary = p.apply_mission(win, "mission_04", 1.0, 1.0, 1, "daily", ex2)
	_check(r3["daily"]["streak"] == 2 and _lines_has(r3["xp_lines"], "Série de 2 jours", 60) and _lines_has(r3["credits_lines"], "Série de 2 jours", 30), "lendemain : série de 2 jours, prime de série 60 XP et 30 crédits")
	_check(p.daily_streak("2026-11-24") == 2 and p.daily_streak("2026-11-25") == 2 and p.daily_streak("2026-11-26") == 0, "la série reste vivante le lendemain, rompue le surlendemain")
	# une défaite ne rompt rien, ne rapporte pas de prime et compte une partie
	var ex3 := ex.duplicate()
	ex3["date"] = "2026-11-25"
	var lost: Dictionary = _fake_result({"won": false, "rating": "—", "n_stars": 0, "total": 1500})
	var r4: Dictionary = p.apply_mission(lost, "mission_04", 1.0, 1.0, 1, "daily", ex3)
	_check(not r4["daily"]["first_win"] and int(p.stats["daily_wins"]) == 3 and int(p.daily["plays"]) == 4 and int(p.daily["wins"]) == 3, "défaite au défi : une partie de plus, aucune prime ni victoire")
	# un jour manqué : la série repart à 1, le record de série reste
	var ex4 := ex.duplicate()
	ex4["date"] = "2026-11-27"
	var r5: Dictionary = p.apply_mission(win, "mission_04", 1.0, 1.0, 1, "daily", ex4)
	_check(r5["daily"]["streak"] == 1 and int(p.daily["best_streak"]) == 2, "jour manqué : la série repart à 1, le record reste à 2")
	# série longue : prime plafonnée à 7 jours
	var q = _new_profile()
	var last_rep: Dictionary = {}
	for k in 9:
		var ex5 := ex.duplicate()
		ex5["date"] = "2026-12-%02d" % (1 + k)
		last_rep = q.apply_mission(win, "mission_04", 1.0, 1.0, 1, "daily", ex5)
	_check(last_rep["daily"]["streak"] == 9 and _lines_has(last_rep["xp_lines"], "Série de 9 jours", 210) and _lines_has(last_rep["credits_lines"], "Série de 9 jours", 105),
			"série de 9 jours : prime plafonnée à 7 jours (210 XP, 105 crédits)")
	_check(q.has_medal("daily_3") and q.has_medal("daily_7") and int(q.daily["best_streak"]) == 9, "médailles de série : trois et sept nuits de suite")
	# classement local : dix scores au plus, du meilleur au moins bon
	var b = _new_profile()
	for k in 12:
		var exb := ex.duplicate()
		exb["date"] = "2027-02-%02d" % (1 + k)
		b.apply_mission(_fake_result({"total": 1000 * (k + 1)}), "mission_04", 1.0, 1.0, 1, "daily", exb)
	var board: Array = b.daily["board"]
	var sorted_ok := true
	for i in range(1, board.size()):
		if int(board[i]["score"]) > int(board[i - 1]["score"]):
			sorted_ok = false
	_check(board.size() == 10 and sorted_ok and int(board[0]["score"]) == 12000 and int(board[9]["score"]) == 3000, "classement local : 10 scores, du meilleur (12 000) au dixième (3 000)")
	var exl := ex.duplicate()
	exl["date"] = "2027-02-20"
	var low: Dictionary = b.apply_mission(_fake_result({"total": 500}), "mission_04", 1.0, 1.0, 1, "daily", exl)
	exl["date"] = "2027-02-21"
	var top: Dictionary = b.apply_mission(_fake_result({"total": 12500}), "mission_04", 1.0, 1.0, 1, "daily", exl)
	_check(low["daily"]["rank"] == 0 and top["daily"]["rank"] == 1 and (b.daily["board"] as Array).size() == 10, "un mauvais score reste hors classement, un meilleur score prend la tête")

	# --- Nuit blanche
	var e = _new_profile()
	var res_e := _fake_result({"total": 12000, "time": 600.0, "objectives": {"secondary": [], "hidden": []}, "stars": [], "n_stars": 0, "rating": "B", "mode": "endless", "waves": 7})
	var re1: Dictionary = e.apply_mission(res_e, "mission_02", 1.0, 1.0, 1, "endless", {"waves": 7, "mut_mult": 1.0})
	var xs := 0
	var cs := 0
	for l in re1["xp_lines"]:
		xs += int(l[1])
	for l in re1["credits_lines"]:
		cs += int(l[1])
	_check(xs == 1220 and cs == 154, "gains en Nuit blanche : 12 000 points, 7 vagues, 10 minutes -> %d XP (960 + 140 + 120) et %d crédits (96 + 28 + 30)" % [xs, cs])
	var res_lost := res_e.duplicate(true)
	res_lost["won"] = false
	var e_b = _new_profile()
	var re_l: Dictionary = e_b.apply_mission(res_lost, "mission_02", 1.0, 1.0, 1, "endless", {"waves": 7, "mut_mult": 1.0})
	_check(re_l["xp_lines"] == re1["xp_lines"], "en Nuit blanche, la fin de patrouille et l'effondrement du secteur rapportent pareil (aucune pénalité de défaite)")
	_check(int(e.stats["wins"]) == 0 and int(e.stats["missions"]) == 1 and e.missions.is_empty() and e.sector_stars() == 0, "Nuit blanche : ni victoire de carrière, ni fiche de campagne, ni étoile")
	var rec: Dictionary = e.endless_record("mission_02")
	_check(re1["endless"]["record_waves"] and re1["endless"]["record_score"] and re1["endless"]["record_time"] and int(rec["best_waves"]) == 7 and int(rec["best_score"]) == 12000 and int(rec["best_time"]) == 600 and int(rec["plays"]) == 1,
			"premier record : 7 vagues, 12 000 points, 10 minutes")
	var res_w := _fake_result({"total": 9000, "time": 400.0, "objectives": {"secondary": [], "hidden": []}, "stars": [], "n_stars": 0, "mode": "endless", "waves": 5})
	var re2: Dictionary = e.apply_mission(res_w, "mission_02", 1.0, 1.0, 1, "endless", {"waves": 5})
	_check(not re2["endless"]["record_waves"] and not re2["endless"]["record_score"] and not re2["endless"]["record_time"] and int(e.endless_record("mission_02")["best_waves"]) == 7 and int(e.endless_record("mission_02")["plays"]) == 2,
			"partie plus courte : aucun record battu, records conservés")
	var res_x := _fake_result({"total": 8000, "time": 700.0, "objectives": {"secondary": [], "hidden": []}, "stars": [], "n_stars": 0, "mode": "endless", "waves": 9})
	var re3: Dictionary = e.apply_mission(res_x, "mission_02", 1.0, 1.0, 1, "endless", {"waves": 9})
	_check(re3["endless"]["record_waves"] and not re3["endless"]["record_score"] and re3["endless"]["record_time"] and e.endless_best_waves() == 9 and int(e.stats["endless_waves"]) == 9,
			"record de vagues et de durée battus, pas celui du score")
	var gotm: Array = []
	for r in [re1, re2, re3]:
		for m in r["medals"]:
			gotm.append(m[0])
	_check(gotm.has("nb_5") and not gotm.has("nb_12") and e.has_medal("nb_5"), "médaille « Nuit blanche » à 5 vagues, pas encore « Insomnie » (12)")
	var res_big := _fake_result({"total": 30000, "time": 1500.0, "objectives": {"secondary": [], "hidden": []}, "stars": [], "n_stars": 0, "mode": "endless", "waves": 26})
	e.apply_mission(res_big, "mission_03", 1.0, 1.0, 1, "endless", {"waves": 26})
	_check(e.has_medal("nb_12") and e.has_medal("nb_25") and e.endless_best_waves() == 26, "26 vagues : « Insomnie » et « Jusqu'à l'aube »")
	_check(not e.has_medal("first_win"), "une Nuit blanche n'est pas une victoire de campagne : pas de médaille de première victoire")

	# --- sauvegarde et rechargement
	var path := "user://pnc_test_profile_modes.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var sv = _new_profile(path)
	sv.daily = p.daily.duplicate(true)
	sv.endless = e.endless.duplicate(true)
	sv.stats["daily_wins"] = 3
	sv.stats["endless_waves"] = 26
	_check(sv.save(), "sauvegarde écrite")
	var ld = _new_profile(path)
	_check(ld.load_file() and JSON.stringify(ld.to_dict()) == JSON.stringify(sv.to_dict()), "aller-retour identique avec défi du jour et Nuit blanche")
	_check(int(ld.daily["best_streak"]) == 2 and (ld.daily["board"] as Array).size() == (p.daily["board"] as Array).size() and ld.endless_best_waves() == 26 and ld.daily_streak("2026-11-27") == 1 and int(ld.stats["daily_wins"]) == 3,
			"série, classement, records de Nuit blanche et compteurs conservés")
	for ext in ["", ".bad", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ext))


# ---------------------------------------------------------------- radio du lot 5

func _test_lot5_radio() -> void:
	print("# radio du lot 5")
	var radio: Dictionary = _json("res://data/radio_script.json")
	var need := ["special_colossus", "special_screamer", "special_alpha", "colossus_down", "screamer_down", "alpha_down", "sup_barrage", "sup_drone", "sup_decoy",
			"sup_drop", "sup_drop_done", "wave", "start_endless", "end_patrol", "radio_fail"]
	var missing: Array = []
	var odd: Array = []
	for ev in need:
		if not radio["events"].has(ev):
			missing.append(ev)
			continue
		var e: Dictionary = radio["events"][ev]
		if int(e.get("priority", 0)) <= 0 or float(e.get("wait_s", 0.0)) <= 0.0 or not e.has("cooldown_s") or (e["variants"] as Array).is_empty():
			odd.append(ev)
	_check(missing.is_empty() and odd.is_empty(), "les %d événements radio du lot 5 existent, avec priorité, délai et variantes (absents : %s, incomplets : %s)" % [need.size(), str(missing), str(odd)])
	var wr: Array = radio["slots"]["wave"]["range"]
	_check(int(wr[0]) == 2 and int(wr[1]) == 60 and _slot_ok(radio, "wave", 2) and _slot_ok(radio, "wave", 60) and not _slot_ok(radio, "wave", 61), "annonce de vague : lisible de la 2e à la 60e")
	# événements dont la radio se tait en panne : toute alerte de la station est filtrée, les échanges internes ne le sont pas
	var say_all := true
	for ev in Ctx.RADIO_DOWN_KEEP:
		if not radio["events"].has(ev):
			say_all = false
	_check(say_all, "chaque événement conservé en panne radio existe dans le script (%d)" % Ctx.RADIO_DOWN_KEEP.size())
	var bank: Dictionary = _json("res://audio/radio/voices.json")["clips"]
	var absent: Array = _bank_keys(radio).filter(func(k): return not bank.has(k))
	_check(absent.is_empty(), "la banque de voix couvre tout le script (%d répliques, %d absentes)" % [bank.size(), absent.size()])
	# toute annonce de vague et de spéciaux sort du directeur avec une clé connue du script
	var src := FileAccess.get_file_as_string("res://scripts/sim/director.gd") + FileAccess.get_file_as_string("res://scripts/core/supports.gd")
	var unknown: Array = []
	var rx := RegEx.new()
	rx.compile("say\\(\"([a-z_]+)\"")
	for mt in rx.search_all(src):
		var key: String = mt.get_string(1)
		if key.ends_with("_"):
			continue                      # préfixe d'un événement composé (sup_<appui>, special_<type>) : vérifié par la liste ci-dessus
		if not radio["events"].has(key):
			unknown.append(key)
	_check(unknown.is_empty(), "les événements émis par le directeur et les appuis existent tous dans le script radio (inconnus : %s)" % str(unknown))


## Pertes lisibles : cause de chaque perte, conseil « raser », répit avant le premier repas, réglages de difficulté.
func _test_readable_losses() -> void:
	print("# pertes lisibles et conseil « raser »")
	# --- décompte par cause : la somme des causes retenues vaut les pertes, celle des morts vaut dévorés + collatéral
	var c = _make_world(4242)
	var d = c.director
	var bs = c.buildings
	d.civilian_lost(2, "inside", Vector2(100.0, 100.0))
	d.civilian_lost(1, "eaten", Vector2(900.0, 900.0))          # ancien nom : la rue
	_check(d.lost == 3 and d.eaten == 3 and d.lost_by["inside"] == 2 and d.lost_by["street"] == 1 and d.dead_by["inside"] == 2 and d.dead_by["street"] == 1,
			"civils dévorés : 2 dans un immeuble, 1 dans la rue (%s)" % str(d.lost_by))
	d.collateral_weight = 0.5
	d.civilian_lost(3, "shot", Vector2(300.0, 300.0))
	_check(d.collateral == 3 and d.dead_by["shot"] == 3 and d.lost_by["shot"] == 1 and d.lost == 4, "3 civils touchés à 50 % : 3 morts, 1 perte comptée (reste 0,5)")
	d.civilian_lost(1, "collateral", Vector2(300.0, 300.0))     # ancien nom : nos tirs ; le reste de 0,5 fait une perte entière
	_check(d.collateral == 4 and d.lost_by["shot"] == 2 and d.lost == 5, "le demi-civil restant complète une perte entière (%s)" % str(d.lost_by))
	var tb := -1
	for b in bs.n:
		if bs.occ[b] >= 5 and bs.status[b] == bs.ST_OK:
			tb = b
			break
	var occ_b: int = bs.occ[tb]
	d.collateral_weight = 1.0
	var lost0: int = d.lost
	bs.destroy(tb)
	_check(d.dead_by["razed"] == occ_b and d.lost_by["razed"] == occ_b and d.lost == lost0 + occ_b and d.collateral == 4 + occ_b,
			"un immeuble rasé : ses %d habitants sont ensevelis, comptés dans « rasés »" % occ_b)
	var sum_lost := 0
	var sum_dead := 0
	for k in d.CAUSES:
		sum_lost += int(d.lost_by[k])
		sum_dead += int(d.dead_by[k])
	_check(sum_lost == d.lost and sum_dead == d.eaten + d.collateral + d.contained, "invariants : somme des causes = pertes (%d), morts = dévorés + collatéral + ensevelis à raison (%d)" % [d.lost, sum_dead])
	# --- raser un immeuble déjà perdu : le prix d'un civil dévoré, ni bavure ni série rompue ; raser un immeuble qui tenait encore : −150 et série rompue
	var rz_c = _make_world(4249)
	var rz_d = rz_c.director
	var rz_b = rz_c.buildings
	var rz_s = rz_c.score
	var rz_pair: Array = []
	for b in rz_b.n:
		if rz_b.occ[b] >= 5 and rz_b.status[b] == rz_b.ST_OK:
			rz_pair.append(b)
			if rz_pair.size() == 2:
				break
	rz_b.occ[rz_pair[0]] = 9
	rz_b.infest(rz_pair[0], 4, 0.0)                 # 4 infectés dedans, 9 habitants : perdu
	rz_b.occ[rz_pair[1]] = 7                        # aucun infecté : il tient
	rz_s.chain = 12
	rz_s.mult = rz_s.tier_of(12)
	_check(rz_b.advice(rz_pair[0]) == "raze" and rz_b.advice(rz_pair[1]) == "safe", "(préalable) l'un est perdu, l'autre tient : %s et %s" % [rz_b.advice(rz_pair[0]), rz_b.advice(rz_pair[1])])
	rz_b.destroy(rz_pair[0])
	_check(rz_d.contained == 9 and rz_d.collateral == 0 and rz_d.dead_by["razed"] == 9 and rz_d.lost == 9 and int(rz_d.loss_events.back()["ok"]) == 1,
			"immeuble perdu rasé : 9 ensevelis à raison (%d), aucune bavure (%d), 9 pertes comptées (%d)" % [rz_d.contained, rz_d.collateral, rz_d.lost])
	_check(rz_s.st["chain_breaks"] == 0 and rz_s.chain >= 12 and rz_s.st["collateral"] == 0 and rz_s.st["contained"] == 9,
			"immeuble perdu rasé : la série n'est pas rompue (%d), pas de bavure au score" % rz_s.chain)
	_check(_radio_said(rz_c, "contagion arrêtée"), "la radio salue l'immeuble perdu rasé (« contagion arrêtée »), sans reproche")
	rz_b.destroy(rz_pair[1])
	_check(rz_d.collateral == 7 and rz_d.contained == 9 and rz_d.dead_by["razed"] == 16 and rz_s.st["chain_breaks"] == 1 and not bool(rz_d.loss_events.back()["ok"]),
			"immeuble qui tenait encore rasé : 7 bavures (%d), série rompue (%d)" % [rz_d.collateral, rz_s.st["chain_breaks"]])
	var rz_sum := 0
	for k in rz_d.CAUSES:
		rz_sum += int(rz_d.dead_by[k])
	_check(rz_sum == rz_d.eaten + rz_d.collateral + rz_d.contained, "invariants après les deux immeubles rasés : %d morts" % rz_sum)
	var rz_c2 = _make_world(4250)
	var rz_pts: int = rz_c2.score.points
	rz_c2.score.on_contained(3)
	_check(rz_c2.score.points - rz_pts == 3 * int(_json("res://data/scoring.json")["points"]["civ_eaten"]), "un civil enseveli à raison coûte autant qu'un civil dévoré")
	# événements d'écran : les pertes proches de même cause sont fusionnées
	var c2 = _make_world(4243)
	var d2 = c2.director
	d2.civilian_lost(1, "street", Vector2(500.0, 500.0))
	c2.time += 1.0
	d2.civilian_lost(1, "street", Vector2(520.0, 510.0))
	d2.civilian_lost(1, "inside", Vector2(520.0, 510.0))
	c2.time += 5.0
	d2.civilian_lost(1, "street", Vector2(520.0, 510.0))
	_check(d2.loss_events.size() == 3 and int(d2.loss_events[0]["n"]) == 2 and d2.loss_events[1]["cause"] == "inside" and int(d2.loss_events[2]["n"]) == 1,
			"pertes d'écran : deux dévorés proches fusionnent, une autre cause ou 5 s plus tard font un nouvel événement (%s)" % str(d2.loss_events.size()))

	# --- conseil « raser » : table de cas (BuildingSystem.advice)
	var c3 = _make_world(4244)
	var b3 := -1
	for b in c3.buildings.n:
		if c3.buildings.occ[b] >= 3:
			b3 = b
			break
	var bs3 = c3.buildings
	var cases := [
		# occupants, infectés entrés, en train de se transformer (ne comptent pas), siège (part de la porte), attendu
		[10, 0, 0, 0.0, "safe"], [10, 0, 0, 0.3, "siege"], [10, 0, 0, 1.0, "open"], [0, 0, 0, 0.0, "empty"],
		[10, 1, 0, 1.0, "defend"], [10, 2, 0, 1.0, "defend"], [10, 3, 0, 1.0, "defend"], [10, 4, 0, 1.0, "raze"],
		[14, 4, 0, 1.0, "raze"], [15, 4, 0, 1.0, "defend"], [15, 5, 0, 1.0, "defend"],
		[10, 1, 3, 1.0, "defend"],                     # les corps qui vont se relever ne sont pas encore des infectés
		[2, 2, 0, 1.0, "raze"], [3, 2, 0, 1.0, "defend"],
		[0, 1, 0, 1.0, "empty"], [0, 2, 0, 1.0, "raze"],   # plus d'habitants : un infecté seul sort tout seul, à deux on rase sans rien perdre
		[18, 6, 0, 1.0, "raze"], [30, 6, 0, 1.0, "defend"], [30, 10, 0, 1.0, "raze"], [60, 20, 0, 1.0, "raze"], [61, 30, 0, 1.0, "defend"],
	]
	var all_ok := true
	var bad := ""
	for cs in cases:
		bs3.lost_latch[b3] = 0                     # chaque ligne est un immeuble neuf : le verrou « perdu » ne doit pas fausser la table
		bs3.occ[b3] = int(cs[0])
		bs3.zin[b3] = int(cs[1])
		bs3.turning[b3] = int(cs[2])
		bs3.siege[b3] = float(cs[3]) * bs3.door_hp[b3]
		var got: String = bs3.advice(b3)
		if got != cs[4]:
			all_ok = false
			bad += " [occ %d, inf %d+%d, siège %.1f -> %s au lieu de %s]" % [cs[0], cs[1], cs[2], cs[3], got, cs[4]]
	_check(all_ok, "conseil d'immeuble : les %d cas de la table (sain, siège, porte forcée, défendre, raser) :%s" % [cases.size(), bad])
	_check(bs3.raze_min_inf() == 4, "un immeuble est perdu à partir de 4 infectés dedans, le seuil de sortie en flot (%d)" % bs3.raze_min_inf())
	# verrou : une fois le seuil atteint, l'immeuble reste perdu tant qu'il contient des infectés (la première sortie ramène 4 à 3)
	bs3.lost_latch[b3] = 0
	bs3.occ[b3] = 10
	bs3.turning[b3] = 0
	bs3.siege[b3] = bs3.door_hp[b3]
	var seq: Array = []
	for zz in [3, 4, 3, 2, 0, 3]:
		bs3.zin[b3] = zz
		seq.append(bs3.advice(b3))
	_check(seq == ["defend", "raze", "raze", "raze", "open", "defend"], "verrou : 3, 4, 3, 2, 0, 3 infectés donnent %s" % str(seq))
	bs3.status[b3] = bs3.ST_RUINS
	_check(bs3.advice(b3) == "ruins", "un immeuble en ruines n'a plus de conseil")
	bs3.status[b3] = bs3.ST_OK

	# le conseil ne clignote pas : 4 infectés entrent (brèche d'une vague), le premier ressort, il en reste 3 ; l'avis reste « raser »
	var c3b = _make_world(4248)
	c3b.director.state = "running"
	var b3b := -1
	for b in c3b.buildings.n:
		if c3b.buildings.occ[b] >= 1:
			b3b = b
			break
	c3b.buildings.occ[b3b] = 12
	c3b.buildings.infest(b3b, 4, 0.0)
	var seen := {}
	var min_zin := 99
	for i in 200:
		_sim(c3b, 0.1)
		if c3b.buildings.status[b3b] == c3b.buildings.ST_OK and c3b.buildings.occ[b3b] > 0:
			seen[c3b.buildings.advice(b3b)] = true
			min_zin = mini(min_zin, c3b.buildings.zin[b3b])
	_check(seen.size() == 1 and seen.has("raze") and min_zin <= 3, "conseil stable pendant les sorties d'infectés : %s (infectés dedans au plus bas : %d)" % [str(seen.keys()), min_zin])

	# --- radio : « immeuble perdu » une seule fois par immeuble, « porte attaquée » aussi
	var c4 = _make_world(4245)
	c4.director.state = "running"
	var b4 := -1
	for b in c4.buildings.n:
		if c4.buildings.occ[b] >= 1:
			b4 = b
			break
	c4.buildings.occ[b4] = 9
	c4.buildings.infest(b4, 4, 0.0)
	for i in 100:
		_sim(c4, 0.1)
	var n_adv := 0
	for r in c4.radio_log:
		if str(r[0]).contains("immeuble perdu"):
			n_adv += 1
	_check(n_adv == 1 and c4.buildings.advised[b4] & 1 == 1, "4 infectés dans un immeuble de 9 habitants : la radio dit une fois « immeuble perdu » (%d)" % n_adv)
	var c5 = _make_world(4246)
	c5.director.state = "running"
	var b5 := -1
	for b in c5.buildings.n:
		if c5.buildings.occ[b] >= 1:
			b5 = b
			break
	c5.buildings.occ[b5] = 8
	c5.buildings.siege[b5] = 0.5 * c5.buildings.door_hp[b5]
	c5.buildings.mark_active(b5)
	for i in 30:
		_sim(c5, 0.1)
	_check(_radio_said(c5, "porte attaquée") and c5.buildings.advised[b5] & 2 == 2, "porte à moitié enfoncée : « porte attaquée, abattez les infectés devant la porte »")
	var script: Dictionary = _json("res://data/radio_script.json")
	var ev_ok := true
	for ev in ["raze_advice", "siege_alert", "loss_inside", "loss_street"]:
		if not script["events"].has(ev):
			ev_ok = false
	_check(ev_ok, "les quatre nouveaux échanges radio sont dans le script (la banque de voix les couvre : voir le test du script)")

	# --- répit avant le premier repas d'une intrusion
	var c6 = _make_world(4247)
	c6.mission["rules"]["amb_target"] = 0.0          # (lot 8) pas de civils des rues : on mesure le répit des repas dans l'immeuble
	var b6 := -1
	for b in c6.buildings.n:
		if c6.buildings.occ[b] >= 12:
			b6 = b
			break
	if b6 >= 0:
		c6.buildings.infest(b6, 4, 12.0)
		for i in 110:
			_sim(c6, 0.1)
		var eaten_11: int = int(c6.director.lost_by["inside"])         # (lot 8 : dévorés DANS l'immeuble ; un civil qui sort peut être pris dans la rue)
		for i in 200:
			_sim(c6, 0.1)
		_check(eaten_11 == 0 and int(c6.director.lost_by["inside"]) >= 1, "12 s de répit : personne n'est dévoré dans l'immeuble avant 11 s (%d), puis les repas commencent (%d à 31 s)" % [eaten_11, int(c6.director.lost_by["inside"])])
	else:
		_check(false, "aucun immeuble de 12 habitants pour l'essai du répit")

	# --- difficulté : intrusion de départ, durée des repas, répit
	var dd = Defs.load_all()
	var base: Dictionary = Campaign.load_mission(dd, "mission_01")
	var mr: Dictionary = Campaign.apply_difficulty(base, dd.level("recruit"))
	var mv: Dictionary = Campaign.apply_difficulty(base, dd.level("veteran"))
	var mn: Dictionary = Campaign.apply_difficulty(base, dd.level("nightmare"))
	var er: float = mr["rules"]["eat_interval_s"]
	var ev_: float = mv["rules"]["eat_interval_s"]
	var en: float = mn["rules"]["eat_interval_s"]
	_check(er > ev_ and ev_ > en and absf(en - float(base["rules"]["eat_interval_s"])) < 0.001, "repas plus lents aux niveaux faciles : %.1f > %.1f > %.1f s" % [er, ev_, en])
	var gr: float = mr["rules"]["breach_grace_s"]
	var gv: float = mv["rules"]["breach_grace_s"]
	var gn: float = mn["rules"]["breach_grace_s"]
	_check(gr > gv and gv > gn and gn == 0.0, "répit avant le premier repas : %.0f > %.0f > %.0f s" % [gr, gv, gn])
	# une intrusion lancée par une vague porte le répit de la difficulté : le premier repas attend (eat_t négatif)
	var cv = _make_sector_world("mission_01", "veteran")
	cv.director._breach(1, 5000.0, 30)
	var cn = _make_sector_world("mission_01", "nightmare")
	cn.director._breach(1, 5000.0, 30)
	var eat_v := 0.0
	var eat_n := 0.0
	for b in cv.buildings.n:
		if cv.buildings.zin[b] > 0:
			eat_v = cv.buildings.eat_t[b]
	for b in cn.buildings.n:
		if cn.buildings.zin[b] > 0:
			eat_n = cn.buildings.eat_t[b]
	_check(is_equal_approx(eat_v, -8.0 * 4.0) and eat_n == 0.0, "intrusion d'une vague : Vétéran a 8 s de répit (%.0f), Cauchemar aucun (%.0f)" % [eat_v, eat_n])


# ---------------------------------------------------------------- lot 7 : priorité urgente, immeuble rouge, viseur assisté

## Fausse vue de la ville : note l'alerte « à raser » que BuildingSystem envoie au rendu (CityRenderer.set_state).
class FakeCityView extends RefCounted:
	var alert := {}

	func set_state(b: int, _occ: float, _inf: float, _col: float, _fire: float, a: float = 0.0) -> void:
		alert[b] = a


## Monde du lot 7 : directeur « en cours », sans vague (ni objectif, sauf demande) ; l'aide du niveau vaut `assist` (1 : Recrue, 0 : Vétéran et Cauchemar).
func _world7(assist: float, seed_v: int = 7100, with_obj: bool = false):
	var m: Dictionary = _json("res://data/mission_01.json")
	m["difficulty"] = {"assist": assist}
	if not with_obj:
		m["objectives"] = []
	var ctx = _make_world(seed_v, m)
	ctx.director.waves = []
	ctx.director.state = "running"
	ctx.assist = Assist.new()
	ctx.assist.setup(ctx)
	return ctx


## Les n premiers immeubles habités (au moins min_occ habitants, intacts), à au moins min_gap mètres les uns des autres.
func _pick_buildings7(ctx, n: int, min_occ: int, min_gap: float) -> Array:
	var out: Array = []
	var bs = ctx.buildings
	var city = ctx.city
	for b in bs.n:
		if bs.status[b] != bs.ST_OK or bs.occ[b] < min_occ:
			continue
		var p := Vector2(city.b_cx[b], city.b_cz[b])
		var far := true
		for o in out:
			if p.distance_to(Vector2(city.b_cx[o], city.b_cz[o])) < min_gap:
				far = false
				break
		if far:
			out.append(b)
			if out.size() == n:
				break
	return out


## Le candidat de clé `key` parmi ceux du moment ({} s'il n'y est pas).
func _cand7(ctx, key: String) -> Dictionary:
	for c in ctx.director.prio.candidates():
		if c["key"] == key:
			return c
	return {}


## Premier civil et premier infecté vivants ({"civ": P ou null, "zom": P ou null}).
func _people7(ctx) -> Dictionary:
	var out := {"civ": null, "zom": null}
	var cr = ctx.crowd
	for i in cr.pool.size():
		var p = cr.pool[i]
		if not p.alive:
			continue
		if p.kind == cr.K_CIVIL and out["civ"] == null:
			out["civ"] = p
		elif p.kind == cr.K_ZOMBIE and out["zom"] == null:
			out["zom"] = p
	return out


## Une image de jeu de l'aimant (le temps de jeu avance ; le joueur n'est pas simulé : note_input se fait à la main).
func _frame7(ctx, dt: float = 1.0 / 60.0) -> void:
	ctx.time += dt
	ctx.assist.update(dt)


## `secs` secondes d'images à 60 par seconde, le joueur ne touchant à rien.
func _frames7(ctx, secs: float) -> void:
	for i in int(round(secs * 60.0)):
		_frame7(ctx)


## Scénario d'attraction : un immeuble à raser et la visée à plus de 700 m de lui. Retourne {ctx, b, target (point à viser), radius} ({} si la carte ne s'y prête pas).
func _pull_scn7(assist: float, seed_v: int = 7110) -> Dictionary:
	var c = _world7(assist, seed_v)
	var bl: Array = _pick_buildings7(c, 2, 5, 700.0)
	if bl.size() < 2:
		return {}
	var b: int = bl[0]
	c.buildings.occ[b] = 9
	c.buildings.infest(b, 4, 0.0)
	c.gunship.aim = Vector2(c.city.b_cx[bl[1]], c.city.b_cz[bl[1]])
	var pr: Dictionary = c.director.urgent()
	return {"ctx": c, "b": b, "target": c.director.prio.aim_point(pr), "radius": float(pr["radius"]), "kind": str(pr["kind"])}


func _test_urgent_assist() -> void:
	print("# lot 7 : priorité urgente, immeuble rouge, viseur assisté de la Recrue")
	# --- rien d'urgent
	var c0 = _world7(1.0)
	var pr0 = c0.director.prio
	var u_none: Dictionary = c0.director.urgent()
	_check(str(u_none["kind"]) == "none" and int(u_none["level"]) == 0 and str(u_none["key"]) == "" and pr0.candidates().is_empty(),
			"sans menace ni objectif : rien d'urgent")
	var bl: Array = _pick_buildings7(c0, 3, 5, 700.0)
	_check(bl.size() == 3, "(préalable) trois immeubles habités à plus de 700 m les uns des autres (%d trouvés)" % bl.size())
	if bl.size() < 3:
		return
	var bs = c0.buildings
	var city = c0.city
	var ba: int = bl[0]
	var bb: int = bl[1]
	var bc: int = bl[2]

	# --- immeuble perdu : à raser, au 105 mm, niveau 5
	bs.occ[ba] = 9
	bs.infest(ba, 4, 0.0)
	var cr_a: Dictionary = _cand7(c0, "raze:%d" % ba)
	_check(bs.advice(ba) == "raze" and not cr_a.is_empty() and cr_a["kind"] == "raze" and int(cr_a["level"]) == 5 and int(cr_a["weapon"]) == 2 and _near(cr_a["pull"], 1.0),
			"4 infectés dans 9 habitants : urgence « raze », niveau 5, au 105 mm")
	if cr_a.is_empty():
		return
	_check(str(cr_a["title"]) == "RASEZ L'IMMEUBLE" and str(cr_a["hint"]) == "PERDU · 4 INFECTÉS DEDANS · 9 HAB.",
			"le bandeau dit quoi faire et pourquoi : « %s · %s »" % [cr_a["title"], cr_a["hint"]])
	var cpos: Vector2 = cr_a["pos"]
	var want_r := clampf(0.35 * maxf(city.b_w[ba], city.b_d[ba]), 10.0, 30.0)
	_check(cpos.is_equal_approx(Vector2(city.b_cx[ba], city.b_cz[ba])) and _near(cr_a["radius"], want_r),
			"zone d'un immeuble à raser : son centre, %.0f m de rayon" % want_r)
	var gp: Vector3 = c0.gunship.pos
	var hh: float = float(cr_a["h"])
	var ap: Vector2 = pr0.aim_point(cr_a)
	var kk: float = (gp.y - hh) / gp.y
	var back := Vector2(gp.x + (ap.x - gp.x) * kk, gp.z + (ap.y - gp.z) * kk)          # le point de la ligne de visée à la hauteur du toit
	_check(hh > 5.0 and back.distance_to(cpos) < 0.05 and ap.distance_to(Vector2(gp.x, gp.z)) > cpos.distance_to(Vector2(gp.x, gp.z)),
			"point visé : la ligne de visée passe par le toit (%.0f m de haut), le sol visé est derrière l'immeuble vu de la canonnière" % hh)
	_check(pr0.aim_point({"pos": Vector2(12.0, 34.0), "h": 0.0}) == Vector2(12.0, 34.0), "cible au sol : on vise le point lui-même")

	# --- rouge : le rendu reçoit l'alerte pour l'immeuble à raser, pas pour les autres
	var fv := FakeCityView.new()
	bs.view = fv
	bs._mark(ba)
	_check(_near(fv.alert.get(ba, -1.0), 1.0) and bs.is_raze_alert(ba), "immeuble à raser : le rendu reçoit l'alerte (rouge dans la scène, sur le cadre et sur la minicarte)")
	bs.occ[bb] = 12
	bs.infest(bb, 1, 0.0)
	_check(bs.advice(bb) == "defend" and _near(fv.alert.get(bb, -1.0), 0.0) and not bs.is_raze_alert(bb), "1 infecté dans 12 habitants : à défendre, pas rouge")
	bs.occ[ba] = 0
	bs._mark(ba)
	_check(_near(fv.alert.get(ba, -1.0), 0.0) and not bs.is_raze_alert(ba), "plus personne à ensevelir : le rouge s'éteint")
	bs.occ[ba] = 9
	bs.status[ba] = bs.ST_RUINS
	bs._mark(ba)
	_check(_near(fv.alert.get(ba, -1.0), 0.0) and not bs.is_raze_alert(ba), "immeuble en ruines : plus rouge")
	bs.status[ba] = bs.ST_OK
	bs._mark(ba)
	_check(_near(fv.alert.get(ba, -1.0), 1.0), "l'alerte suit le conseil : rouge à nouveau quand l'immeuble est de nouveau perdu")
	bs.view = null

	# --- à défendre : niveau 2, 25 mm, on vise la porte
	var cd_b: Dictionary = _cand7(c0, "defend:%d" % bb)
	_check(not cd_b.is_empty() and cd_b["kind"] == "defend" and int(cd_b["level"]) == 2 and int(cd_b["weapon"]) == 0 and _near(cd_b["pull"], 0.8) and str(cd_b["hint"]).begins_with("NE RASEZ PAS"),
			"immeuble infesté mais pas perdu : urgence « defend », niveau 2, au 25 mm, « NE RASEZ PAS »")
	_check(not cd_b.is_empty() and Vector2(cd_b["pos"]).distance_to(pr0.door_pos(bb)) < 0.01 and float(cd_b["h"]) == 0.0, "à défendre : on vise la porte, au sol")

	# --- porte attaquée
	bs.occ[bc] = 8
	bs.mark_active(bc)
	var door_rows := []
	for f in [0.05, 0.30, 0.60, 1.0]:
		bs.siege[bc] = f * bs.door_hp[bc]
		var cdr: Dictionary = _cand7(c0, "door:%d" % bc)
		door_rows.append("" if cdr.is_empty() else "%d|%s|%d" % [int(cdr["level"]), cdr["title"], int(cdr["weapon"])])
	_check(door_rows == ["", "2|DÉFENDEZ LA PORTE|0", "3|DÉFENDEZ LA PORTE|0", "3|PORTE FORCÉE|0"],
			"portes : à 5 %% rien, à 30 %% niveau 2, à 60 %% niveau 3, forcée niveau 3 « PORTE FORCÉE » (%s)" % str(door_rows))
	bs.siege[bc] = 0.30 * bs.door_hp[bc]
	var cd30: Dictionary = _cand7(c0, "door:%d" % bc)
	_check(not cd30.is_empty() and str(cd30["hint"]) == "PORTE ATTAQUÉE 30 % · 8 HAB.", "le bandeau d'une porte attaquée donne la part et les habitants (%s)" % str(cd30.get("hint", "")))
	bs.siege[bc] = bs.door_hp[bc]

	# --- infecté sur des civils
	_check(_cand7(c0, "street").is_empty(), "(préalable) personne dans la rue : pas d'urgence de rue")
	var ok_civ: bool = c0.crowd.spawn_civilian_at_door(bc)
	var ok_zom: bool = c0.crowd.spawn_zombie_at_door(bc)
	var pp: Dictionary = _people7(c0)
	_check(ok_civ and ok_zom and pp["civ"] != null and pp["zom"] != null, "(préalable) un civil et un infecté devant la même porte")
	if not (ok_civ and ok_zom and pp["civ"] != null and pp["zom"] != null):
		return
	var civ = pp["civ"]
	var zom = pp["zom"]
	var cst: Dictionary = _cand7(c0, "street")
	_check(not cst.is_empty() and int(cst["level"]) == 4 and _near(cst["pull"], 1.0) and str(cst["title"]) == "TIREZ SUR LES INFECTÉS" and str(cst["hint"]) == "1 CIVIL POURSUIVI",
			"infecté sur un civil (moins de 9 m) : urgence « street », niveau 4 (%s)" % str(cst.get("hint", "")))
	zom.pos = civ.pos + Vector2(12.0, 0.0)
	cst = _cand7(c0, "street")
	_check(not cst.is_empty() and int(cst["level"]) == 2 and _near(cst["pull"], 0.7), "infecté à 12 m d'un civil : niveau 2, attraction plus faible")
	zom.pos = civ.pos + Vector2(20.0, 0.0)
	_check(_cand7(c0, "street").is_empty() and c0.crowd.street_threat().is_empty(), "infecté à 20 m : plus de menace de rue")

	# --- infectés spéciaux : l'arme conseillée suit le type
	var sp_rows := []
	for zt in [Crowd.ZT_COLOSSUS, Crowd.ZT_SCREAMER, Crowd.ZT_ALPHA]:
		var cs = _world7(1.0, 7130 + int(zt))
		var sp = cs.crowd.spawn_special(int(zt), cs.gunship.center, 200.0, 900.0)
		var found: Dictionary = {}
		if sp != null:
			for c in cs.director.prio.candidates():
				if c["kind"] == "special":
					found = c
		sp_rows.append("-" if found.is_empty() else "%d|%d|%s|%.1f" % [int(found["level"]), int(found["weapon"]), str(found["title"]), float(found["pull"])])
	_check(sp_rows == ["3|2|ABATTEZ LE COLOSSE|0.8", "3|0|ABATTEZ LE HURLEUR|0.8", "3|1|ABATTEZ L'ALPHA|0.8"],
			"infectés spéciaux : niveau 3 ; 105 mm contre le colosse, 25 mm contre le hurleur, 40 mm contre l'alpha (%s)" % str(sp_rows))

	# --- objectif de mission
	var co = _world7(1.0, 7140, true)
	co.objectives.items = [{"state": "active", "has_pos": true, "pos": Vector2(-700.0, -300.0), "radius": 120.0, "type": "intercept", "title": "Intercepter le convoi", "t_end": 0.0, "b": -1}]
	var uo: Dictionary = co.director.urgent()
	_check(str(uo["kind"]) == "objective" and int(uo["level"]) == 1 and int(uo["weapon"]) == 1 and _near(uo["pull"], 0.5) and _near(uo["radius"], 60.0),
			"objectif de mission : niveau 1, 40 mm, attraction réduite de moitié (%s)" % str(uo["title"]))

	# --- classement (monde c0) : le niveau l'emporte sur la distance, une urgence disparue est remplacée tout de suite
	c0.gunship.aim = Vector2(civ.pos)
	zom.pos = civ.pos
	c0.time += 0.3
	var order: Array = [str(c0.director.urgent()["key"])]                  # raze, bien que la rue soit sous la visée
	bs.destroy(ba)
	c0.time += 0.3
	order.append(str(c0.director.urgent()["key"]))                         # l'immeuble rasé disparaît : la rue (niveau 4) prend la suite sans attendre
	zom.pos = civ.pos + Vector2(40.0, 0.0)
	c0.time += 0.3
	order.append(str(c0.director.urgent()["key"]))                         # plus de menace de rue : la porte forcée (niveau 3)
	zom.pos = civ.pos
	c0.time += 0.3
	order.append(str(c0.director.urgent()["key"]))                         # une urgence plus haute remplace tout de suite celle qui était en place
	_check(order == ["raze:%d" % ba, "street", "door:%d" % bc, "street"],
			"classement : raze > rue (même sous la visée), puis rue > porte, remplacement immédiat (%s)" % str(order))
	_check(pr0.changes == 4, "quatre changements de cible, pas un de plus (%d)" % pr0.changes)

	# --- maintien : deux cibles de même niveau ne s'échangent pas avant 3 s ni pour moins de 400 m d'avantage
	var ch = _world7(1.0, 7101)
	var hb: Array = _pick_buildings7(ch, 2, 5, 800.0)
	if hb.size() == 2:
		for b in hb:
			ch.buildings.occ[b] = 12
			ch.buildings.infest(b, 1, 0.0)
		var hp = ch.director.prio
		var pa: Vector2 = hp.door_pos(hb[0])
		var pb: Vector2 = hp.door_pos(hb[1])
		var dab: float = pa.distance_to(pb)
		var ka := "defend:%d" % hb[0]
		var kb := "defend:%d" % hb[1]
		ch.gunship.aim = pa
		var k1: String = str(ch.director.urgent()["key"])
		ch.gunship.aim = pb                                                # la visée est sur B ; A est à plus de 800 m
		ch.time += 1.0
		var k2: String = str(ch.director.urgent()["key"])                  # A est maintenu (moins de 3 s)
		ch.time += Priority.HOLD_S
		var k3: String = str(ch.director.urgent()["key"])                  # 3 s plus tard, B prend la suite
		var dir_ab: Vector2 = (pb - pa).normalized()
		ch.gunship.aim = pa + dir_ab * ((dab - (Priority.STICKY_M - 100.0)) * 0.5)      # A est plus proche que B de 300 m seulement
		ch.time += Priority.HOLD_S + 1.0
		var k4: String = str(ch.director.urgent()["key"])                  # B reste (A n'a pas 400 m d'avance)
		ch.gunship.aim = pa + dir_ab * ((dab - (Priority.STICKY_M + 200.0)) * 0.5)      # A est plus proche de 600 m
		ch.time += Priority.HOLD_S + 1.0
		var k5: String = str(ch.director.urgent()["key"])                  # A reprend la main
		_check([k1, k2, k3, k4, k5] == [ka, ka, kb, kb, ka],
				"maintien : A, A (encore 1 s), B (après %.0f s), B (A plus près de 300 m seulement), A (plus près de 600 m) : %s" % [Priority.HOLD_S, str([k1, k2, k3, k4, k5])])
		_check(hp.changes == 3, "trois changements de cible seulement (%d)" % hp.changes)
	else:
		_check(false, "maintien : pas deux immeubles éloignés de 800 m dans la carte d'essai")

	# --- calcul paresseux et directeur à l'arrêt
	var cc = _world7(1.0, 7102)
	var cb1: Array = _pick_buildings7(cc, 1, 5, 100.0)
	if cb1.size() == 1:
		cc.time = 10.0
		var kz: String = str(cc.director.urgent()["key"])                  # rien d'urgent
		cc.buildings.occ[cb1[0]] = 9
		cc.buildings.infest(cb1[0], 4, 0.0)
		cc.time += Priority.PERIOD * 0.5
		var k_cache: String = str(cc.director.urgent()["key"])             # dans la période : le calcul en cache
		cc.time += Priority.PERIOD
		var k_new: String = str(cc.director.urgent()["key"])
		_check(kz == "" and k_cache == "" and k_new == "raze:%d" % cb1[0],
				"calcul au plus tous les %.2f s de jeu : rien (%s), toujours rien (%s), puis l'immeuble à raser (%s)" % [Priority.PERIOD, kz, k_cache, k_new])
		cc.director.state = "won"
		cc.time += 0.3
		var k_end: String = str(cc.director.urgent()["key"])
		cc.director.state = "running"
		cc.time += 0.3
		var k_back: String = str(cc.director.urgent()["key"])
		_check(k_end == "" and k_back == "raze:%d" % cb1[0], "directeur à l'arrêt : aucune urgence (« %s »), elle revient quand la partie reprend" % k_end)
	else:
		_check(false, "pas d'immeuble habité pour l'essai du cache")

	# --- difficulté : l'aide n'existe qu'en Recrue
	var dd = Defs.load_all()
	var base: Dictionary = Campaign.load_mission(dd, "mission_01")
	var lv_assist := []
	for lid in ["recruit", "veteran", "nightmare"]:
		var mm: Dictionary = Campaign.apply_difficulty(base, dd.level(lid))
		lv_assist.append(float(mm["difficulty"].get("assist", -1.0)))
	_check(lv_assist == [1.0, 0.0, 0.0], "aide du viseur : Recrue 1, Vétéran 0, Cauchemar 0 (%s)" % str(lv_assist))
	var wr = _make_sector_world("mission_01", "recruit")
	wr.assist = Assist.new()
	wr.assist.setup(wr)
	var wn = _make_sector_world("mission_01", "nightmare")
	wn.assist = Assist.new()
	wn.assist.setup(wn)
	_check(_near(wr.assist.level(), 1.0) and _near(wn.assist.level(), 0.0), "l'aimant lit la difficulté de la partie : Recrue %.1f, Cauchemar %.1f" % [wr.assist.level(), wn.assist.level()])

	# --- attraction : la visée rejoint la zone de l'immeuble à raser, puis s'arrête
	var sa: Dictionary = _pull_scn7(1.0)
	if sa.is_empty():
		_check(false, "viseur assisté : pas deux immeubles à plus de 700 m pour l'essai")
		return
	var ca = sa["ctx"]
	var tgt: Vector2 = sa["target"]
	var rad: float = sa["radius"]
	var a0: Vector2 = ca.gunship.aim
	var d0: float = a0.distance_to(tgt)
	var moved_1s := 0.0
	var t_in := -1.0
	var a_in := Vector2.ZERO
	for i in 720:                                                           # 12 s à 60 images par seconde
		_frame7(ca)
		if i == 59:
			moved_1s = a0.distance_to(ca.gunship.aim)
		if ca.assist.inside and t_in < 0.0:
			t_in = float(i + 1) / 60.0
			a_in = ca.gunship.aim
	var d1: float = ca.gunship.aim.distance_to(tgt)
	_check(sa["kind"] == "raze" and d0 > 600.0 and t_in > 0.0 and t_in < 8.0,
			"Recrue : la visée part à %.0f m de l'immeuble à raser et entre dans sa zone en %.1f s" % [d0, t_in])
	_check(d1 <= rad * Assist.ENTER_K + 0.001 and d1 >= rad * Assist.ENTER_K * 0.9 - 0.5,
			"elle s'arrête dans la zone sans la dépasser : %.1f m du point visé (zone %.1f m)" % [d1, rad])
	_check(ca.gunship.aim == a_in and not ca.assist.active, "une fois dans la zone, plus aucun mouvement (aucun tremblement)")
	_check(moved_1s > 100.0 and moved_1s <= Assist.MAX_SPEED + 1.0, "vitesse de départ au zoom de base : %.0f m en 1 s (plafond %.0f m/s)" % [moved_1s, Assist.MAX_SPEED])
	var dir_to: Vector2 = (tgt - a0).normalized()
	_check((ca.gunship.aim - a0).normalized().dot(dir_to) > 0.999 and absf(ca.assist.pulled_m - (d0 - d1)) < 0.1,
			"trajectoire droite vers la cible, chemin sous l'aimant = distance parcourue (%.1f m)" % ca.assist.pulled_m)

	# --- zoom : plus le champ est étroit, plus l'attraction est lente (jamais plus de 0,9 largeur d'image par seconde)
	var sz: Dictionary = _pull_scn7(1.0)
	var cz = sz["ctx"]
	cz.gunship.fov = 4.0
	var f4: float = cz.assist.field_m()
	cz.gunship.fov = 1.0
	var f1: float = cz.assist.field_m()
	var az0: Vector2 = cz.gunship.aim
	_frames7(cz, 1.0)
	var moved_zoom: float = az0.distance_to(cz.gunship.aim)
	_check(absf(f4 / f1 - tan(deg_to_rad(2.0)) / tan(deg_to_rad(0.5))) < 0.02, "largeur de l'image au sol : %.0f m à 4°, %.0f m à 1°" % [f4, f1])
	_check(moved_zoom <= Assist.FIELD_MAX * f1 * 1.02 + 0.5 and moved_zoom < 0.6 * moved_1s,
			"zoom fort (1°) : %.0f m en 1 s, soit %.2f largeur d'image (plafond %.1f), contre %.0f m au zoom de base" % [moved_zoom, moved_zoom / f1, Assist.FIELD_MAX, moved_1s])
	var t_in_z := -1.0
	for i in 1800:                                                          # 30 s
		_frame7(cz)
		if cz.assist.inside:
			t_in_z = float(i + 1) / 60.0 + 1.0
			break
	_check(t_in_z > t_in and t_in_z > 0.0 and t_in_z < 25.0, "même au zoom fort la visée arrive dans la zone : %.1f s (zoom de base : %.1f s)" % [t_in_z, t_in])

	# --- le joueur reste maître : l'aimant s'efface devant ses gestes, reprend après un instant de calme
	var sb: Dictionary = _pull_scn7(1.0)
	var cbz = sb["ctx"]
	var db: Vector2 = (Vector2(sb["target"]) - cbz.gunship.aim).normalized()
	var perp := Vector2(-db.y, db.x)
	var ab0: Vector2 = cbz.gunship.aim
	for i in 60:                                                            # 1 s : la souris bouge, à angle droit de la cible
		cbz.assist.note_input(perp * 0.2)
		_frame7(cbz)
	var moved_busy: float = ab0.distance_to(cbz.gunship.aim)
	_check(moved_busy / moved_1s > 0.27 and moved_busy / moved_1s < 0.33,
			"le joueur déplace la visée : l'aimant ne garde que %.0f %% de sa force (%.0f m en 1 s au lieu de %.0f)" % [100.0 * moved_busy / moved_1s, moved_busy, moved_1s])
	var step_busy := moved_busy / 60.0
	_frames7(cbz, 0.6)
	var ab1: Vector2 = cbz.gunship.aim
	_frame7(cbz)
	var step_calm: float = ab1.distance_to(cbz.gunship.aim)
	_check(step_calm > 3.0 * step_busy, "après 0,5 s de calme l'aimant retrouve toute sa force (pas par image ×%.1f)" % (step_calm / step_busy))

	# --- le joueur s'éloigne franchement de la cible : l'aimant se suspend 3 s
	var sk: Dictionary = _pull_scn7(1.0)
	var ck = sk["ctx"]
	var dk: Vector2 = (Vector2(sk["target"]) - ck.gunship.aim).normalized()
	for i in 30:                                                            # 0,5 s dans le sens opposé à la cible
		ck.assist.note_input(-dk * 2.0)
		_frame7(ck)
	var paused: bool = ck.assist.pause_t > 0.0
	var ak: Vector2 = ck.gunship.aim
	_frames7(ck, 2.0)
	var still: bool = ck.gunship.aim == ak and not ck.assist.active
	_frames7(ck, Assist.BREAK_S)
	var resumed: bool = ck.gunship.aim.distance_to(Vector2(sk["target"])) < ak.distance_to(Vector2(sk["target"])) - 10.0
	_check(paused and still and resumed, "le joueur s'éloigne de la cible : l'aimant se suspend (%s), n'attire plus pendant ce temps (%s), reprend ensuite (%s)" % [str(paused), str(still), str(resumed)])
	ck.assist.reset()
	_check(ck.assist.pause_t == 0.0 and not ck.assist.inside and ck.assist.pulled_m == 0.0, "reset() (nouvelle partie) remet l'aimant à zéro")

	# --- pas d'attraction pendant le tir ni juste après
	var sf: Dictionary = _pull_scn7(1.0)
	var cf = sf["ctx"]
	cf.arms.trigger = true
	var af0: Vector2 = cf.gunship.aim
	_frames7(cf, 1.0)
	var in_fire: bool = cf.gunship.aim == af0 and not cf.assist.active
	cf.arms.trigger = false
	_frames7(cf, Assist.FIRE_GRACE_S - 0.15)
	var in_grace: bool = cf.gunship.aim == af0
	_frames7(cf, 0.6)
	var after: bool = cf.gunship.aim.distance_to(af0) > 20.0
	_check(in_fire and in_grace and after, "tir en cours : aucune attraction (%s), ni dans les %.1f s qui suivent (%s), puis elle reprend (%s)" % [str(in_fire), Assist.FIRE_GRACE_S, str(in_grace), str(after)])

	# --- pas d'attraction quand le désignateur laser tient un infecté
	var sd: Dictionary = _pull_scn7(1.0)
	var cdz = sd["ctx"]
	cdz.designator = Designator.new()
	cdz.designator.setup(cdz)
	cdz.designator.active = true
	var ad0: Vector2 = cdz.gunship.aim
	_frames7(cdz, 1.0)
	var des_still: bool = cdz.gunship.aim == ad0
	cdz.designator.active = false
	_frames7(cdz, 1.0)
	_check(des_still and cdz.gunship.aim.distance_to(ad0) > 50.0, "désignateur verrouillé : l'aimant se tait ; verrou relâché : il reprend")

	# --- pas d'aide en Vétéran ni en Cauchemar
	var s0: Dictionary = _pull_scn7(0.0)
	var c00 = s0["ctx"]
	var a00: Vector2 = c00.gunship.aim
	_frames7(c00, 5.0)
	_check(c00.gunship.aim == a00 and not c00.assist.active and c00.assist.strength == 0.0 and c00.assist.pulled_m == 0.0 and s0["kind"] == "raze",
			"sans aide (Vétéran, Cauchemar) : la visée n'obéit qu'au joueur, même devant un immeuble à raser")

	# --- rien d'urgent : rien n'attire
	var cn0 = _world7(1.0, 7150)
	var an0: Vector2 = cn0.gunship.aim
	_frames7(cn0, 3.0)
	_check(cn0.gunship.aim == an0 and not cn0.assist.inside, "rien d'urgent : la visée reste où le joueur la met")

	# --- l'attraction suit la force de la cible : un objectif tire deux fois moins fort qu'un immeuble à raser
	co.gunship.aim = Vector2(300.0, 200.0)
	var ao0: Vector2 = co.gunship.aim
	co.time += 1.0
	_frames7(co, 1.0)
	var moved_obj: float = ao0.distance_to(co.gunship.aim)
	_check(moved_obj / moved_1s > 0.47 and moved_obj / moved_1s < 0.53, "objectif de mission : attraction à %.0f %% de celle d'un immeuble à raser (%.0f m en 1 s)" % [100.0 * moved_obj / moved_1s, moved_obj])

	# --- réglage de la taille du texte : profil et écran
	var tp := "user://pnc_test_text.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tp))
	var pt = _new_profile(tp)
	pt.settings["text"] = 2
	var saved: bool = pt.save()
	var pt2 = _new_profile(tp)
	var loaded: bool = pt2.load_file()
	_check(saved and loaded and int(pt2.settings.get("text", -1)) == 2, "la taille du texte est enregistrée dans le profil")
	var wf := FileAccess.open(tp, FileAccess.WRITE)
	wf.store_string(JSON.stringify({"version": 1, "settings": {"text": 9}}))
	wf.close()
	var pt3 = _new_profile(tp)
	pt3.load_file()
	wf = FileAccess.open(tp, FileAccess.WRITE)
	wf.store_string(JSON.stringify({"version": 1, "settings": {"text": -4}}))
	wf.close()
	var pt4 = _new_profile(tp)
	pt4.load_file()
	wf = FileAccess.open(tp, FileAccess.WRITE)
	wf.store_string(JSON.stringify({"version": 1, "settings": {}}))
	wf.close()
	var pt5 = _new_profile(tp)
	pt5.load_file()
	_check(int(pt3.settings.get("text", -1)) == 2 and int(pt4.settings.get("text", -1)) == 0 and not pt5.settings.has("text"),
			"valeur hors plage ramenée à 0–2 (9 → %d, −4 → %d), absente : réglage par défaut" % [int(pt3.settings.get("text", -1)), int(pt4.settings.get("text", -1))])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tp))
	var hud = Hud.new()
	hud.set_text_size(0, false)
	var ts0: float = hud.ts
	hud.set_text_size(2, false)
	var ts2: float = hud.ts
	hud.set_text_size(9, false)
	var ts9: float = hud.ts
	hud.set_text_size(-3, false)
	var tsm: float = hud.ts
	hud.set_text_size(2, false)
	hud.cycle_text_size()
	var lv_wrap: int = hud.text_level
	hud.cycle_text_size()
	var lv_next: int = hud.text_level
	_check(_near(ts0, 1.0) and _near(ts2, 1.6) and _near(ts9, 1.6) and _near(tsm, 1.0) and lv_wrap == 0 and lv_next == 1,
			"taille du texte de l'écran : normal ×%.1f, très grand ×%.1f, bornée aux extrêmes, la touche T fait le tour (2 → %d → %d)" % [ts0, ts2, lv_wrap, lv_next])
	_check(Hud.TEXT_SCALES.size() == 3 and Hud.TEXT_DEFAULT == 1 and float(Hud.TEXT_SCALES[Hud.TEXT_DEFAULT]) >= 1.3,
			"par défaut le texte est plus grand qu'avant (×%.1f)" % float(Hud.TEXT_SCALES[Hud.TEXT_DEFAULT]))
	hud.free()

	# --- câblage dans la boucle de jeu (main.gd) : l'aimant joue après le désignateur, avant la canonnière ; la touche T change la taille
	var msrc: String = FileAccess.get_file_as_string("res://scripts/main.gd")
	var i_des: int = msrc.find("designator.update(")
	var i_as: int = msrc.find("ctx.assist.update(")
	var i_gs: int = msrc.find("gunship.update(", i_as)
	_check(i_des >= 0 and i_as > i_des and i_gs > i_as and msrc.contains("ctx.assist.note_input(") and msrc.contains("ctx.assist.reset()") and msrc.contains("hud.cycle_text_size()"),
			"main.gd : l'aimant joue après le désignateur et avant la canonnière, note les gestes du joueur, repart à zéro à chaque partie")



func _test_idle_game() -> void:
	print("# partie sans aucune intervention du joueur")
	var ctx = _make_world(1914)
	ctx.director.start()
	var t := 0.0
	var t_ms := Time.get_ticks_msec()
	while ctx.director.state == "running" and t < 700.0:
		_sim(ctx, 0.1)
		t += 0.1
	var d = ctx.director
	print("   issue %s à t=%.0f s — perdus %d/%d, sauvés %d, dévorés %d, zombies en rue %d (%d ms de calcul)" % [
			d.state, d.t, d.lost, d.max_lost, d.saved, d.eaten, ctx.crowd.n_zombies, Time.get_ticks_msec() - t_ms])
	_check(d.state == "lost", "sans intervention, le secteur tombe")


func _visible(ctx, p: Vector2) -> bool:
	var o: Vector3 = ctx.gunship.pos
	var t3 := Vector3(p.x, 0.0, p.y)
	var h: Dictionary = ctx.buildings.trace(o, (t3 - o).normalized())
	return h["pos"].distance_to(t3) < 5.0


func _bot_choose(ctx) -> Dictionary:
	var gs = ctx.gunship
	var bs = ctx.buildings
	# 0. colosse en vue : seul le 105 mm en vient à bout (deux obus), comme l'alerte radio le demande au tireur
	var col = null
	var col_d := INF
	for i in ctx.crowd.MAX_P:
		var q = ctx.crowd.pool[i]
		if q.alive and q.kind == 0 and q.ztype == Crowd.ZT_COLOSSUS and not q.rising and ctx.arms.ammo[2] >= 1.0 and _visible(ctx, q.pos):
			var dq: float = gs.aim.distance_to(q.pos)
			if dq < col_d:
				col_d = dq
				col = q
	if col != null:
		return {"pos": col.pos, "weapon": 2, "zombie": col}
	# 0 bis. hurleur en vue : un obus de 40 mm (à défaut, une rafale de 25 mm) le fait taire, et sa frénésie cesse d'emballer les groupes
	var scr = null
	var scr_d := INF
	for i in ctx.crowd.MAX_P:
		var q = ctx.crowd.pool[i]
		if q.alive and q.kind == 0 and q.ztype == Crowd.ZT_SCREAMER and not q.rising and (ctx.arms.ammo[1] >= 2.0 or ctx.arms.ammo[0] >= 100.0) and _visible(ctx, q.pos):
			var dq: float = gs.aim.distance_to(q.pos)
			if dq < scr_d:
				scr_d = dq
				scr = q
	if scr != null:
		return {"pos": scr.pos, "weapon": 1 if ctx.arms.ammo[1] >= 2.0 else 0, "zombie": scr}
	# 0 ter. alpha en vue : le chef de meute tombe sous trois obus de 40 mm, et la meute s'immobilise
	var alp = null
	var alp_d := INF
	for i in ctx.crowd.MAX_P:
		var q = ctx.crowd.pool[i]
		if q.alive and q.kind == 0 and q.ztype == Crowd.ZT_ALPHA and not q.rising and ctx.arms.ammo[1] >= 3.0 and _visible(ctx, q.pos):
			var dq: float = gs.aim.distance_to(q.pos)
			if dq < alp_d:
				alp_d = dq
				alp = q
	if alp != null:
		return {"pos": alp.pos, "weapon": 1, "zombie": alp}
	# 1. immeuble débordé -> 105 mm, mais seulement si cela coûte peu de civils (un humain ne rase pas une tour de 35 habitants
	#    pour quatre infectés : le dégât collatéral dépasserait ce que ceux-ci mangeraient) ou si l'infection va déborder
	var best_b := -1
	var best_score := 0.0
	for b in bs.infested_list():
		if bs.advice(b) == "raze":              # le même conseil que celui qui s'affiche au joueur (BuildingSystem.advice)
			var sc: float = float(bs.zin[b]) - 0.002 * gs.aim.distance_to(Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b]))
			if sc > best_score:
				best_score = sc
				best_b = b
	if best_b >= 0:
		return {"pos": Vector2(ctx.city.b_cx[best_b], ctx.city.b_cz[best_b]), "weapon": 2}
	# 2. meilleure grappe de zombies (échantillon) pas trop loin de la visée
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
		if not _visible(ctx, z.pos):
			continue
		var n := 0
		for o in zs:
			if o.pos.distance_squared_to(z.pos) < 144.0:
				n += 1
		var urgent := 0.0
		if z.mode == 1 and z.target_b >= 0:
			var door: Vector2 = ctx.city.b_door_pos[z.target_b]
			urgent = maxf(0.0, 1.0 - z.pos.distance_to(door) / 300.0) * 6.0
		elif z.mode == 3 and z.target_b >= 0:
			urgent = 4.0 + 10.0 * ctx.buildings.siege[z.target_b] / ctx.buildings.door_hp[z.target_b]
		var score: float = float(n) + urgent - 0.004 * gs.aim.distance_to(z.pos)
		if score > bscore:
			bscore = score
			best = z
	if best == null:
		return {}
	return {"pos": best.pos, "weapon": 0, "zombie": best}


## Monde du robot : la ville du secteur choisi (graine variable) et sa mission à la difficulté choisie.
func _bot_base(d) -> Dictionary:
	return Campaign.load_file(bot_mfile) if bot_mfile != "" else Campaign.load_mission(d, bot_sector)


func _make_bot_world(seed_v: int):
	var d = Defs.load_all()
	var base: Dictionary = _bot_base(d)
	var m: Dictionary = Campaign.apply_difficulty(base, d.level(bot_level))
	var c: Dictionary = m["city"]
	return _make_world(seed_v, m, float(c["size"]), str(c["style"]), "campaign", [], str(c.get("file", "")))


func _run_bot(seed_v: int, verbose: bool) -> Dictionary:
	var ctx = _make_bot_world(seed_v)
	ctx.director.start()
	var gs = ctx.gunship
	var t := 0.0
	var retarget := 0.0
	var tgt := {}
	var slew_speed := 230.0
	var react := 0.0
	while ctx.director.state == "running" and t < 700.0:
		var dt := 0.1
		retarget -= dt
		if retarget <= 0.0:
			retarget = 0.7
			tgt = _bot_choose(ctx)
			if not tgt.is_empty():
				ctx.arms.select(int(tgt["weapon"]))
		if tgt.is_empty():
			ctx.arms.trigger = false
		else:
			var p: Vector2 = tgt["pos"]
			if tgt.has("zombie") and tgt["zombie"].alive and tgt["zombie"].kind == 0:
				p = tgt["zombie"].pos
				tgt["pos"] = p
			var to: Vector2 = p - gs.aim
			var step := slew_speed * dt
			if to.length() > 900.0:
				gs.center_target = p
			if to.length() > step:
				gs.aim += to.normalized() * step
				ctx.arms.trigger = false
			else:
				gs.aim = p
				ctx.arms.trigger = true
		_sim(ctx, dt)
		t += dt
		if bot_trace and fmod(t, 10.0) < dt:
			print(_bot_trace_line(ctx, t, tgt))
	var d = ctx.director
	var res: Dictionary = ctx.score.result
	var spawned := {"colossus": 0, "screamer": 0, "alpha": 0}
	for wi in mini(d._wi, d.waves.size()):
		var w: Dictionary = d.waves[wi]
		if str(w.get("type", "")) == "special":
			spawned[str(w["zt"])] = int(spawned[str(w["zt"])]) + int(w.get("count", 1))
	var spec := "C %d/%d H %d/%d A %d/%d" % [int(ctx.score.st["kills_colossus"]), spawned["colossus"], int(ctx.score.st["kills_screamer"]), spawned["screamer"],
			int(ctx.score.st["kills_alpha"]), spawned["alpha"]]
	return {"spec": spec, "state": d.state, "t": d.t, "lost": d.lost, "saved": d.saved, "eaten": d.eaten,
			"collateral": d.collateral, "kills": d.kills, "destroyed": d.destroyed,
			"shots": ctx.arms.shots, "score": int(res.get("total", 0)), "rating": str(res.get("rating", "?")),
			"stars": int(res.get("n_stars", 0)), "chain_best": int(ctx.score.st["chain_best"]),
			"sub": int(res.get("subtotal", 0)), "prot": int(ctx.score.st["protected"]), "acc": float(res.get("accuracy", 0.0)),
			"obj": ctx.objectives.count_done("secondary"), "hid": ctx.objectives.count_done("hidden"),
			"obj_pts": int(ctx.score.st["obj_points"])}


## Durée de tenue de chaque secteur (ou de la mission --mfile) sans aucune intervention, sur six villes de graines différentes.
## Mesure sans robot : elle ne dépend ni de l'adresse du joueur ni de celle du robot, seulement de la dynamique de l'infection.
func _idle_report() -> void:
	print("# tenue sans intervention (difficulté %s)" % bot_level)
	var d = Defs.load_all()
	var ids: Array = []
	for sc in d.sectors:
		ids.append(str(sc["id"]))
	if bot_mfile != "":
		ids = [bot_sector]
	for id in ids:
		bot_sector = id
		var sum_t := 0.0
		var min_t := 9999.0
		var sum_l60 := 0.0
		var n := 6
		for k in n:
			var ctx = _make_bot_world(1914 + 31 * k)
			ctx.director.start()
			var t := 0.0
			var l60 := 0
			while ctx.director.state == "running" and t < 700.0:
				_sim(ctx, 0.1)
				t += 0.1
				if absf(t - 60.0) < 0.05:
					l60 = ctx.director.lost
			sum_t += ctx.director.t
			min_t = minf(min_t, ctx.director.t)
			sum_l60 += float(l60)
		print("   %-11s : tombe en moyenne à %3.0f s (au plus tôt %3.0f s), %4.1f civils perdus à 60 s" % [id, sum_t / n, min_t, sum_l60 / n])


## Le point est-il dans la zone où l'on joue ? La zone de la mission (disque, lot 8) ; à défaut, 800 m autour du centre d'orbite.
func _in_play_area(ctx, q: Vector2, center: Vector2) -> bool:
	if ctx.has_zone():
		return ctx.in_zone(q)
	return q.distance_to(center) <= 800.0


## Part des rues visibles depuis la canonnière (sans immeuble en travers), tout au long d'un tour d'orbite, secteur par secteur.
func _vis_report() -> void:
	print("# visibilité des rues depuis l'orbite")
	var d = Defs.load_all()
	for sc in d.sectors:
		var ctx = _make_sector_world(str(sc["id"]), "veteran")
		var city = ctx.city
		var gs = ctx.gunship
		var vis := 0
		var tot := 0
		var dvis := 0
		var dtot := 0
		var bvis := 0
		var btot := 0
		var worst := 1.0
		var steps := 12
		var dt := 107.0 / float(steps)
		var rng := RandomNumberGenerator.new()
		rng.seed = 5
		for k in steps:
			for i in int(dt * 10.0):
				gs.update(0.1)
			var v_k := 0
			var n_k := 0
			for j in 160:
				var e := rng.randi_range(0, city.edge_a.size() - 1)
				var q: Vector2 = city.nodes[city.edge_a[e]].lerp(city.nodes[city.edge_b[e]], rng.randf())
				if not _in_play_area(ctx, q, gs.center):
					continue
				n_k += 1
				if _visible(ctx, q):
					v_k += 1
			vis += v_k
			tot += n_k
			worst = minf(worst, float(v_k) / float(maxi(n_k, 1)))
			# pieds d'immeubles : là où les infectés s'attroupent pour enfoncer les portes
			for j in 160:
				var b := rng.randi_range(0, city.building_count() - 1)
				var dp: Vector2 = city.b_door_pos[b]
				if city.b_occ[b] <= 0 or not _in_play_area(ctx, dp, gs.center):
					continue
				dtot += 1
				var seen := _visible(ctx, dp)
				if seen:
					dvis += 1
				if city.b_occ[b] >= 20:
					btot += 1
					if seen:
						bvis += 1
		print("   %-12s %-11s : %3d %% des rues visibles en moyenne (pire instant %3d %%), %3d %% des portes (%d %% pour les immeubles de 20 habitants et plus, %d échantillons)" % [sc["id"], str(city.meta.get("style", "?")), int(100.0 * vis / maxf(tot, 1)), int(100.0 * worst), int(100.0 * dvis / maxf(dtot, 1)), int(100.0 * bvis / maxf(btot, 1)), btot])


## Ligne d'état du robot (option --bottrace) : civils, zombies en rue / visibles, immeubles infestés (habitants/infectés).
func _bot_trace_line(ctx, t: float, tgt: Dictionary) -> String:
	var cr = ctx.crowd
	var n_z := 0
	var n_vis := 0
	for i in cr.MAX_P:
		var p = cr.pool[i]
		if p.alive and p.kind == 0:
			n_z += 1
			if n_z % 4 == 0 and _visible(ctx, p.pos):
				n_vis += 1
	var inf: Array = []
	for b in ctx.buildings.infested_list():
		inf.append("%d/%d" % [ctx.buildings.occ[b], ctx.buildings.zin[b]])
	var thr: int = ctx.buildings.threatened_list().size()
	var sp := "C%d H%d A%d" % [cr.count_special(Crowd.ZT_COLOSSUS), cr.count_special(Crowd.ZT_SCREAMER), cr.count_special(Crowd.ZT_ALPHA)]
	return "      t=%3.0f perdus %2d (dévorés %2d) zombies %3d (visibles ≈%3d) infestés [%s] menacés %d  spéciaux %s  cible %s" % [
			t, ctx.director.lost, ctx.director.eaten, n_z, n_vis * 4, ", ".join(inf), thr, sp,
			("arme %d" % int(tgt["weapon"])) if not tgt.is_empty() else "aucune"]


func ctx_duration() -> float:
	return float(_bot_base(Defs.load_all()).get("duration_s", 420))


func _test_bot_games() -> void:
	print("# parties d'un robot (aucune anticipation, visée à 230 m/s) — %s, difficulté %s" % [bot_sector, bot_level])
	var wins := 0
	var best_t := 0.0
	var sum_lost := 0
	for i in n_bots:
		var t_ms := Time.get_ticks_msec()
		var r := _run_bot(bot_seed0 + i * 31, false)
		best_t = maxf(best_t, float(r["t"]))
		sum_lost += int(r["lost"])
		if r["state"] == "won":
			wins += 1
		print("   graine %d : %s à t=%.0f s — perdus %d (dévorés %d, collatéral %d), sauvés %d, tués %d, immeubles détruits %d, coups %d, score %d (%s, %d étoile%s, série max %d ; combat %d, protégés %d, précision %d %% ; objectifs %d/5 + %d cachés = %d pts ; spéciaux %s)  [%d ms]" % [
				bot_seed0 + i * 31, r["state"], r["t"], r["lost"], r["eaten"], r["collateral"], r["saved"], r["kills"],
				r["destroyed"], r["shots"], r["score"], r["rating"], r["stars"], "s" if r["stars"] > 1 else "", r["chain_best"],
				r["sub"], r["prot"], int(100.0 * r["acc"]), r["obj"], r["hid"], r["obj_pts"], r["spec"], Time.get_ticks_msec() - t_ms])
	print("   victoires : %d / %d (la meilleure partie tient %.0f s sur %.0f)" % [wins, n_bots, best_t, float(ctx_duration())])
	# Avec peu de parties, une série de victoires ou de défaites est probable sans que la mission soit en cause : à Montmartre en
	# Vétéran le robot gagne environ trois parties sur quatre (23 sur 32 le 25 novembre), donc 4 victoires d'affilée arrivent
	# une fois sur quatre avec 4 parties et une fois sur quatorze avec 8. On n'exige donc une victoire ET une défaite qu'à partir de
	# 16 parties (moins d'une série sur cent), et seulement une partie menée presque jusqu'au bout en dessous.
	# Depuis le lot 8 (zone de 600 m, infectés errants, civils des rues), le robot gagne toutes ses parties dans plusieurs secteurs, même en
	# Cauchemar (32 sur 32 au Quartier latin le 26 novembre) : exiger au moins une défaite ferait échouer le test sans qu'aucun code ne soit
	# en cause. On exige donc seulement que la mission ait des enjeux (le robot y perd des civils) ; le taux de victoires est affiché sans
	# plafond (voir « Équilibrage » du README).
	if n_bots >= 16:
		_check(wins >= 1, "la mission est gagnable par un joueur raisonnable (robot : %d victoire%s sur %d)" % [wins, "s" if wins > 1 else "", n_bots])
		_check(sum_lost > 0, "la mission a des enjeux : le robot y perd des civils (%.1f par partie en moyenne)" % (float(sum_lost) / float(n_bots)))
		print("  --     pas de plafond exigé sur les victoires du robot (%d sur %d en %s)" % [wins, n_bots, bot_level])
	elif n_bots >= 4:
		_check(wins >= 1 or best_t >= 0.7 * float(ctx_duration()), "la mission est jouable (une victoire, ou une partie tenue 70 % du temps ; --bots=16 pour juger)")
		print("  --     difficulté non évaluée en dessous de 16 parties (%d victoire%s sur %d)" % [wins, "s" if wins > 1 else "", n_bots])
	else:
		print("  --     équilibrage non évalué (il faut au moins --bots=4)")


# ---------------------------------------------------------------- lot 8

## Mesure sans verdict : le secteur --sector joué sans joueur pendant --secs secondes, avec le décompte de la foule toutes les 10 s.
func _probe8() -> void:
	var ctx = _make_sector_world(bot_sector, bot_level)
	var dd = ctx.director
	var cr = ctx.crowd
	dd.start()
	var t_step := 0.0
	var worst := 0.0
	var n := int(probe_secs / 0.05)
	print("# sonde : %s (%s), zone %.0f m, %d civils des rues au départ" % [bot_sector, bot_level, ctx.zone_radius(), cr.n_amb])
	for i in n:
		var t1 := Time.get_ticks_usec()
		_sim(ctx, 0.05)
		var us := float(Time.get_ticks_usec() - t1)
		t_step += us
		worst = maxf(worst, us)
		if i % 200 == 199:
			var hunt := 0
			var wand := 0
			var chase := 0
			var siege := 0
			var herd := 0
			var out_z := 0
			for p in cr.pool:
				if p.alive and p.kind == cr.K_ZOMBIE:
					match p.mode:
						1: hunt += 1
						2: wand += 1
						3: siege += 1
						5: chase += 1
					if p.herd > 0:
						herd += 1
				if p.alive and not ctx.in_zone(p.pos, 5.0):
					out_z += 1
			print("  t=%3.0f  zombies %3d (chasse %2d, erre %2d, porte %2d, poursuite %2d, groupes %2d)  civils des rues %2d  évacués %d  perdus %d/%d (dedans %d, rue %d, tirs %d)  sauvés %d  dehors %d" % [
					dd.t, cr.n_zombies, hunt, wand, siege, chase, herd, cr.n_amb, cr.n_civils, dd.lost, dd.max_lost,
					int(dd.lost_by["inside"]), int(dd.lost_by["street"]), int(dd.lost_by["shot"]), dd.saved, out_z])
			if out_z > 0 and i < 400:
				for p in cr.pool:
					if p.alive and not ctx.in_zone(p.pos, 5.0):
						print("      hors zone : kind %d amb %s mode %d pos (%.0f, %.0f) distance au centre %.0f" % [p.kind, str(p.amb), p.mode, p.pos.x, p.pos.y, p.pos.distance_to(ctx.zone_center())])
	print("  coût moyen d'un pas de simulation : %.2f ms (pire %.2f ms)" % [t_step / float(n) / 1000.0, worst / 1000.0])


func _test_lot8() -> void:
	print("# lot 8 : zone réduite, cadence par arme, métro, civils des rues, carrés rouges")
	_lot8_data()
	_lot8_arms()
	_lot8_zone()
	_lot8_seek()
	_lot8_herds()
	_lot8_street()
	_lot8_lock()


## Les cinq missions et la difficulté : ce que le lot 8 a changé dans les données.
func _lot8_data() -> void:
	var dif: Dictionary = _json("res://data/difficulty.json")
	var lk := {}
	for lv in dif["levels"]:
		lk[str(lv["id"])] = float(lv.get("lock", -1.0))
	_check(lk.get("recruit", -1.0) == 1.0 and lk.get("veteran", -1.0) == 1.0 and lk.get("nightmare", -1.0) == 0.0,
			"difficulté : carrés rouges en Recrue et en Vétéran, aucun en Cauchemar (%s)" % str(lk))
	var bad: Array = []
	for i in range(1, 6):
		var tag := "mission_%02d" % i
		var m: Dictionary = _json("res://data/%s.json" % tag)
		var zn: Dictionary = m.get("zone", {})
		if float(zn.get("radius_m", 0.0)) != 600.0:
			bad.append("%s : zone %s" % [tag, str(zn)])
		if float(m["orbit"]["radius_m"]) - float(zn.get("radius_m", 0.0)) < 200.0:
			bad.append("%s : l'orbite frôle la zone" % tag)
		var n_metro := 0
		for w in m["waves"]:
			if float(w.get("r_max", 0.0)) > 600.0 or float(w.get("radius", 0.0)) > 450.0:
				bad.append("%s : vague hors zone (%s)" % [tag, str(w)])
			if str(w.get("type", "")) == "metro":
				n_metro += 1
		if n_metro < 3:
			bad.append("%s : %d vague(s) du métro" % [tag, n_metro])
		for o in m.get("objectives", []):
			if (float(o.get("radius", 0.0)) > 450.0 and str(o.get("type", "")) != "intercept") or float(o.get("r_max", 0.0)) > 600.0:
				bad.append("%s : objectif hors zone (%s)" % [tag, str(o.get("id", ""))])
		var r: Dictionary = m["rules"]
		var sr := float(r.get("seek_ratio", 1.0))
		if sr <= 0.0 or sr > 0.5 or float(r.get("amb_target", 0.0)) < 20.0 or float(r.get("amb_spawn_s", 0.0)) <= 0.0:
			bad.append("%s : règles de la foule (seek %.2f, civils des rues %s)" % [tag, sr, str(r.get("amb_target"))])
	_check(bad.is_empty(), "5 missions : zone de 600 m, orbite à 200 m au moins, vagues et objectifs dans la zone, 3 groupes du métro au moins, peu de chercheurs de porte, civils des rues %s" % (str(bad) if not bad.is_empty() else ""))


## Rechargement propre à chaque arme : changer d'arme n'attend jamais celle qu'on quitte.
func _lot8_arms() -> void:
	var c = _make_world(8101)
	c.director.state = "running"
	for w in c.weapons:
		w["dispersion_mrad"] = 0.0
	var ar = c.arms
	_check(ar.cooldowns.size() == c.weapons.size() and ar.cooldowns.size() == 3, "une cadence de tir par arme (%d)" % ar.cooldowns.size())
	var per2 := 60.0 / float(c.weapons[2]["rpm"])
	ar.select(2)
	ar.trigger = true
	ar.update(0.0)
	_check(ar.shots == 1 and absf(float(ar.cooldowns[2]) - per2) < 0.01 and absf(ar.reload_fraction(2) - 1.0) < 0.01,
			"105 mm : un obus, puis %.1f s de rechargement" % per2)
	ar.trigger = false
	var cd_before: Array = ar.cooldowns.duplicate()
	ar.select(0)
	_check(ar.cooldowns == cd_before and ar.current == 0, "changer d'arme ne touche à aucun rechargement")
	ar.trigger = true
	ar.update(0.0)
	_check(ar.shots == 2, "25 mm : elle tire tout de suite, sans attendre l'obusier (%d tirs)" % ar.shots)
	ar.trigger = false
	ar.update(1.0)
	_check(absf(float(ar.cooldowns[2]) - (per2 - 1.0)) < 0.02, "l'obusier se recharge en arrière-plan (%.2f s restantes sur %.1f)" % [float(ar.cooldowns[2]), per2])
	ar.select(2)
	var shots_b: int = ar.shots
	ar.trigger = true
	ar.update(0.0)
	_check(ar.shots == shots_b and ar.reload_fraction(2) > 0.5, "repris trop tôt, l'obusier attend la fin de SON rechargement (%.1f s)" % float(ar.cooldowns[2]))
	ar.trigger = false
	ar.update(per2)
	ar.trigger = true
	ar.update(0.0)
	_check(ar.shots == shots_b + 1, "… et il tire dès qu'il est prêt")
	ar.trigger = false
	# la propriété `cooldown` désigne l'arme en main
	ar.select(1)
	ar.cooldown = 0.7
	_check(float(ar.cooldowns[1]) == 0.7 and float(ar.cooldowns[0]) == 0.0 and absf(float(ar.cooldowns[2]) - per2) < 0.01 and ar.cooldown == 0.7,
			"`cooldown` est le rechargement de l'arme en main seulement")
	# cadence du 40 mm : un coup toutes les 0,6 s, quoi qu'on ait tiré avant
	ar.cooldown = 0.0
	var s0: int = ar.shots
	ar.trigger = true
	for i in 10:
		ar.update(0.3)
	_check(ar.shots - s0 == 5 or ar.shots - s0 == 6, "40 mm : 5 ou 6 coups en 3 s (cadence de 100 coups/min), %d tirés" % (ar.shots - s0))


## Les secteurs : zone de jeu, sorties, métro, visée bridée, rien ne naît hors de la zone.
func _lot8_zone() -> void:
	for i in range(1, 6):
		var sid := "mission_%02d" % i
		var c = _make_sector_world(sid)
		var zc: Vector2 = c.zone_center()
		var r: float = c.zone_radius()
		var gs = c.gunship
		var ev: Array = c.director.evac_list()
		var mt: Array = c.director.metro_list()
		var ev_in := true
		for n in ev:
			if not c.in_zone(c.city.nodes[n]):
				ev_in = false
		var mt_in := true
		for n in mt:
			if not c.in_zone(c.city.nodes[n]):
				mt_in = false
		_check(c.has_zone() and r == 600.0 and gs.center.is_equal_approx(zc) and c.in_zone(zc) and c.in_zone(zc + Vector2(r - 1.0, 0.0)) and not c.in_zone(zc + Vector2(r + 1.0, 0.0)) and gs.radius - r >= 199.0,
				"%s : zone de %.0f m centrée en (%.0f, %.0f), orbite de %.0f m centrée dessus" % [sid, r, zc.x, zc.y, gs.radius])
		_check(ev.size() >= 5 and ev_in and c.city.metro_nodes.size() == 8 and mt.size() == 8 and mt_in,
				"%s : %d points d'évacuation et %d bouches de métro, tous dans la zone" % [sid, ev.size(), mt.size()])
		gs.aim = zc + Vector2(3000.0, 2500.0)
		gs.update(0.016)
		var d_far: float = gs.aim.distance_to(zc)
		gs.aim = zc + Vector2(100.0, -50.0)
		gs.update(0.016)
		_check(d_far <= r + 0.01 and d_far > r - 1.0 and gs.aim.is_equal_approx(zc + Vector2(100.0, -50.0)),
				"%s : la visée ne sort pas de la zone (ramenée à %.1f m du centre) et reste libre dedans" % [sid, d_far])
	# sans clé « zone » : toute la carte, comme avant le lot 8
	var mz: Dictionary = _json("res://data/mission_01.json")
	mz.erase("zone")
	var cz = _make_world(8110, mz)
	var half: float = cz.zone_radius()
	var far: Vector2 = cz.zone_clamp(Vector2(5000.0, -5000.0))
	_check(not cz.has_zone() and half == 1200.0 and cz.in_zone(Vector2(1100.0, -1100.0)) and not cz.in_zone(Vector2(1300.0, 0.0)) and absf(far.x - (half - 30.0)) < 0.01 and absf(far.y + (half - 30.0)) < 0.01,
			"sans clé « zone », toute la carte compte comme avant (demi-côté de %.0f m)" % half)
	# une partie sans joueur : personne ne vit loin de la zone, ni infecté ni civil
	var c2 = _make_sector_world("mission_02")
	var zc2: Vector2 = c2.zone_center()
	c2.director.start()
	var worst := 0.0
	var who := ""
	for k in 3000:
		_sim(c2, 0.05)
		if k % 20 == 19:
			for p in c2.crowd.pool:
				if p.alive and p.pos.distance_to(zc2) > worst:
					worst = p.pos.distance_to(zc2)
					who = "kind %d mode %d" % [p.kind, p.mode]
	_check(worst <= 600.0 + 60.0, "150 s de partie : le plus éloigné du centre est à %.0f m (zone de 600 m ; %s)" % [worst, who])


## 30 % seulement des infectés visent une porte ; les groupes d'objectif les visent tous.
func _lot8_seek() -> void:
	var c = _make_sector_world("mission_02")
	var cr = c.crowd
	var zl: PackedInt32Array = cr.zone_edges()
	var n := 300
	var n_seek := 0
	var n_m1 := 0
	var n_m2 := 0
	for i in n:
		var z = cr.spawn_zombie(zl[(i * 7) % zl.size()], 0.5)
		if z == null:
			continue
		cr._assign(z)
		if z.seeker:
			n_seek += 1
		if z.mode == 1:
			n_m1 += 1
		elif z.mode == 2:
			n_m2 += 1
	var share: float = float(n_seek) / float(n)
	_check(share > 0.2 and share < 0.4, "%d infectés tirés : %.0f %% cherchent une porte (règle seek_ratio = %.1f)" % [n, share * 100.0, c.rule("seek_ratio", 1.0)])
	_check(n_m1 <= n_seek and n_m1 >= int(0.6 * float(n_seek)) and n_m2 >= n - n_seek - 5,
			"les chercheurs prennent un immeuble (%d sur %d), les autres errent (%d)" % [n_m1, n_seek, n_m2])
	var c3 = _make_sector_world("mission_02")
	c3.mission["rules"].erase("seek_ratio")
	var all_seek := true
	for i in 40:
		var z3 = c3.crowd.spawn_zombie(c3.crowd.zone_edges()[(i * 5) % c3.crowd.zone_edges().size()], 0.5)
		if z3 != null and not z3.seeker:
			all_seek = false
	_check(all_seek, "sans règle seek_ratio, tous les infectés visent une porte (comportement d'avant)")
	var c4 = _make_sector_world("mission_02")
	var got: int = c4.crowd.spawn_tagged_group(c4.gunship.center, 300.0, 6, 7)
	var tagged := 0
	var hunting := 0
	for p in c4.crowd.pool:
		if p.alive and p.kind == Crowd.K_ZOMBIE and p.tag == 7:
			tagged += 1
			p.seeker = false                         # même si le tirage dit le contraire : un groupe d'objectif vise toujours un immeuble
			c4.crowd._assign(p)
			if p.mode == 1 and p.target_b >= 0:
				hunting += 1
	_check(got >= 4 and tagged == got and hunting == tagged, "un groupe d'objectif (%d infectés) vise toujours un immeuble (%d)" % [tagged, hunting])


## Groupes du métro : ils sortent ensemble d'une bouche et errent ensemble.
func _lot8_herds() -> void:
	for sid in ["mission_01", "mission_04"]:
		var c = _make_sector_world(sid)
		c.mission["rules"]["amb_target"] = 0.0
		c.director.waves = []
		var cr = c.crowd
		var mt: Array = c.director.metro_list()
		var groups: Array = []                               # un groupe errant et un groupe d'errants isolés à chacune des 8 bouches
		for node in mt:
			var at: Vector2 = c.city.nodes[node]
			var before: Array = []
			for p in cr.pool:
				if p.alive:
					before.append(p.id)
			var got: int = cr.spawn_herd(node, 6)
			var herd: Array = []
			for p in cr.pool:
				if p.alive and p.kind == Crowd.K_ZOMBIE and p.herd > 0 and not before.has(p.id):
					herd.append(p)
			var solo: Array = []
			var adj: Array = cr.graph.adj[node]
			for i in 6:
				var e: int = adj[i % adj.size()]
				var zs = cr.spawn_zombie(e, 0.05 if cr.graph.ea[e] == node else 0.95)
				if zs != null:
					zs.seeker = false
					solo.append(zs)
			groups.append({"node": node, "at": at, "got": got, "herd": herd, "solo": solo})
		var g0: Dictionary = groups[0]
		var near := true
		var same := true
		var no_seek := true
		for p in g0["herd"]:
			if p.pos.distance_to(g0["at"]) > 15.0:
				near = false
			if p.herd != g0["herd"][0].herd:
				same = false
			if p.seeker:
				no_seek = false
		for k in 30:
			_sim(c, 0.1)
		var wander := true
		for p in g0["herd"]:
			if p.alive and p.mode != 2:
				wander = false
		_check(mt.size() == 8 and int(g0["got"]) == 6 and (g0["herd"] as Array).size() == 6 and near and same and no_seek and wander,
				"%s : 6 infectés sortent ensemble d'une bouche (à 15 m au plus), errent dans les rues et ne visent pas de porte" % sid)
		for k in 270:
			_sim(c, 0.1)
		var sum_h := 0.0
		var sum_s := 0.0
		var moved := 0.0
		var lost := 0
		var in_bld := 0
		for g in groups:
			var cen := Vector2.ZERO
			var n := 0
			for p in g["herd"]:
				if p.alive:
					cen += p.pos
					n += 1
					if p.mode == 1:
						in_bld += 1
				else:
					lost += 1
			cen /= maxf(float(n), 1.0)
			var sp := 0.0
			for p in g["herd"]:
				if p.alive:
					sp = maxf(sp, p.pos.distance_to(cen))
			sum_h += sp
			moved += cen.distance_to(g["at"])
			var cs := Vector2.ZERO
			var ns := 0
			for p in g["solo"]:
				if p.alive:
					cs += p.pos
					ns += 1
			cs /= maxf(float(ns), 1.0)
			var ss := 0.0
			for p in g["solo"]:
				if p.alive:
					ss = maxf(ss, p.pos.distance_to(cs))
			sum_s += ss
		var ng := float(groups.size())
		_check(lost == 0 and in_bld == 0 and moved / ng >= 20.0,
				"%s : 30 s plus tard, les groupes ont marché de %.0f m en moyenne, aucun n'est entré dans un immeuble" % [sid, moved / ng])
		_check(sum_h / ng < sum_s / ng and sum_h / ng <= 60.0,
				"%s : un groupe errant reste plus soudé que des errants isolés partis du même point (étalement moyen %.0f m contre %.0f m)" % [sid, sum_h / ng, sum_s / ng])


## Liste des civils des rues vivants.
func _amb_list8(ctx) -> Array:
	var out: Array = []
	for p in ctx.crowd.pool:
		if p.alive and p.kind == Crowd.K_CIVIL and p.amb:
			out.append(p)
	return out


## Monde sans infecté ni vague, partie lancée, rues peuplées de `n` civils.
func _street_world8(n: int, level: String = "veteran"):
	var c = _make_sector_world("mission_02", level)
	c.mission["start_zombies"] = 0
	c.director.waves = []
	c.director.start()
	c.crowd.step(0.2)
	return c


## Civils des rues : population, fuite, poursuite, pertes, sortie silencieuse.
func _lot8_street() -> void:
	var c = _street_world8(30)
	var dd = c.director
	var cr = c.crowd
	var l0 := _amb_list8(c)
	var all_in := true
	for p in l0:
		if not c.in_zone(p.pos, 40.0):
			all_in = false
	_check(l0.size() >= 15 and all_in and cr.n_civils == 0, "au départ %d civils courent dans les rues de la zone (sans compter parmi les civils à protéger : %d)" % [l0.size(), cr.n_civils])
	for k in 2400:
		_sim(c, 0.05)
	var l1 := _amb_list8(c)
	_check(cr.amb_out >= 8 and dd.saved == 0 and dd.lost == 0 and cr.n_civils == 0,
			"en 120 s, %d civils des rues atteignent une sortie sans bruit : ni sauvés (%d), ni perdus (%d)" % [cr.amb_out, dd.saved, dd.lost])
	_check(l1.size() >= 20 and l1.size() <= 45, "la population des rues se renouvelle : %d civils (cible %.0f)" % [l1.size(), c.rule("amb_target", 0.0)])

	# fuite : un infecté immobile à 14 m devant le civil
	var f = _street_world8(30)
	var fl := _amb_list8(f)
	var chosen: Array = []
	for p in fl:
		var far := true
		for q in chosen:
			if q.pos.distance_to(p.pos) < 90.0:
				far = false
		if far and chosen.size() < 6:
			chosen.append(p)
	var starts: Array = []
	var threats: Array = []
	for p in chosen:
		var heading: Vector2 = f.graph.edir[p.edge] * float(p.dir)
		var tp: Vector2 = p.pos + heading * 14.0
		var e_t: int = p.edge
		var t_t: float = clampf(p.t + float(p.dir) * 14.0 / maxf(f.graph.elen[p.edge], 1.0), 0.02, 0.98)
		var z = f.crowd.spawn_zombie(e_t, t_t)
		z.idle = 9999.0
		z.mode = 0
		starts.append(p.pos.distance_to(z.pos))
		threats.append(z)
	for k in 40:
		_sim(f, 0.1)
	var fled := 0
	var scared := 0
	for i in chosen.size():
		var p = chosen[i]
		if p.alive and p.kind == Crowd.K_CIVIL and p.pos.distance_to(threats[i].pos) >= float(starts[i]) + 4.0:
			fled += 1
		if p.alive and p.fear > 0.0:
			scared += 1
	_check(chosen.size() >= 4 and fled >= chosen.size() - 1 and scared == chosen.size(),
			"%d civils sur %d s'éloignent d'un infecté placé 14 à 23 m devant eux (au moins 4 m de plus après 4 s), tous ont peur (%d)" % [fled, chosen.size(), scared])

	# poursuite et prise : l'infecté libre, à 20 m, se lance ; à 2 m, il attrape sa proie
	var h = _street_world8(30)
	var hl := _amb_list8(h)
	var prey = hl[0]
	var z2 = h.crowd.spawn_zombie(prey.edge, clampf(prey.t - float(prey.dir) * 20.0 / maxf(h.graph.elen[prey.edge], 1.0), 0.02, 0.98))
	z2.mode = 0
	z2.idle = 0.0
	z2.seeker = false
	for k in 10:
		_sim(h, 0.1)
	_check(z2.mode == Crowd.MODE_CHASE and z2.chase == prey.id and not h.crowd.street_threat().is_empty(),
			"un infecté libre à ~20 m d'un civil se lance à sa poursuite (mode %d) ; le bandeau « civil poursuivi » le voit" % z2.mode)
	var h2 = _street_world8(30)
	var prey2 = _amb_list8(h2)[0]
	var z3 = h2.crowd.spawn_zombie(prey2.edge, clampf(prey2.t - float(prey2.dir) * 2.0 / maxf(h2.graph.elen[prey2.edge], 1.0), 0.02, 0.98))
	z3.idle = 0.0
	z3.mode = 0
	z3.speed = 6.0
	var street0: int = int(h2.director.lost_by["street"])
	for k in 100:
		_sim(h2, 0.1)
		if int(h2.director.lost_by["street"]) > street0:
			break
	_check(int(h2.director.lost_by["street"]) > street0 and not (prey2.alive and prey2.kind == Crowd.K_CIVIL),
			"un civil des rues rattrapé est une perte « rue » (%d)" % (int(h2.director.lost_by["street"]) - street0))

	# dégâts collatéraux : un obus qui tombe sur un civil des rues compte comme un tir
	var k2 = _street_world8(30)
	var victim = _amb_list8(k2)[0]
	var shot0: int = int(k2.director.dead_by["shot"])
	var res: Vector2i = k2.crowd.damage_area(victim.pos.x, victim.pos.y, 8.0, 130.0, 0.6, 1)
	_check(res.y >= 1 and int(k2.director.dead_by["shot"]) - shot0 == res.y and victim.kind == Crowd.K_DEAD,
			"obus de 40 mm sur un civil des rues : %d tué, compté parmi les civils tués par nos tirs (%d)" % [res.y, int(k2.director.dead_by["shot"]) - shot0])


## Premier immeuble haut dont le pied arrière (vu de la canonnière) cache le sol : retourne {b, hid (Vector2 caché), seen (Vector2 visible)} ou {}.
func _hidden_spot8(ctx) -> Dictionary:
	var gs = ctx.gunship
	var bs = ctx.buildings
	var city = ctx.city
	var eye: Vector3 = gs.pos
	var e2 := Vector2(eye.x, eye.z)
	for b in bs.n:
		if bs.status[b] != bs.ST_OK or city.b_h[b] < 22.0:
			continue
		var bp := Vector2(city.b_cx[b], city.b_cz[b])
		if not ctx.in_zone(bp, -120.0) or bp.distance_to(e2) < 300.0:
			continue
		var dir: Vector2 = (bp - e2).normalized()
		var hid := Vector2.INF
		for dist in [10.0, 14.0, 18.0, 24.0]:
			for ang in [0.0, 0.3, -0.3]:
				var zp: Vector2 = bp + dir.rotated(ang) * dist
				if bs.building_at(zp.x, zp.y) < 0 and bs.blocked(eye, Vector3(zp.x, 1.0, zp.y)):
					hid = zp
					break
			if hid != Vector2.INF:
				break
		if hid == Vector2.INF:
			continue
		var d3: Vector3 = (Vector3(hid.x, 0.0, hid.y) - eye).normalized()
		if int(bs.trace(eye, d3)["b"]) < 0:
			continue                                         # le tir droit sur ce point passerait : pas un cas qui sépare le guidage du tir normal
		var seen := Vector2.INF
		for dist2 in [30.0, 45.0, 60.0, 80.0]:
			var vp: Vector2 = bp - dir * dist2
			if bs.building_at(vp.x, vp.y) < 0 and not bs.blocked(eye, Vector3(vp.x, 1.0, vp.y)):
				seen = vp
				break
		if seen == Vector2.INF:
			continue
		return {"b": b, "hid": hid, "seen": seen}
	return {}


## Monde du verrouillage : secteur 1, partie « en cours », canonnière à son angle de départ, ni infecté ni civil des rues.
func _lock_world8(level: String = "veteran"):
	var c = _make_sector_world("mission_01", level)
	c.mission["start_zombies"] = 0
	c.mission["rules"]["amb_target"] = 0.0
	c.director.waves = []
	c.director.state = "running"
	c.lock = Lock.new()
	c.lock.setup(c)
	for w in c.weapons:
		w["dispersion_mrad"] = 0.0
	c.gunship.update(0.0)
	return c


## Un infecté immobile à `pos`.
func _still8(ctx, pos: Vector2):
	var z = _put(ctx, pos, Crowd.K_ZOMBIE)
	z.idle = 9999.0
	z.mode = 0
	return z


## Carrés rouges et obus guidés : ligne de vue, verrouillage, difficulté, tir sur un infecté caché.
func _lot8_lock() -> void:
	var c = _lock_world8()
	var gs = c.gunship
	var bs = c.buildings
	var sp: Dictionary = _hidden_spot8(c)
	_check(not sp.is_empty(), "(préalable) un immeuble haut cache un morceau de rue à la canonnière (%s)" % ("trouvé" if not sp.is_empty() else "introuvable"))
	if sp.is_empty():
		return
	var b: int = sp["b"]
	var hid: Vector2 = sp["hid"]
	var seen: Vector2 = sp["seen"]
	var eye: Vector3 = gs.pos
	_check(bs.blocked(eye, Vector3(hid.x, 1.0, hid.y)) and not bs.blocked(eye, Vector3(seen.x, 1.0, seen.y)) and not bs.blocked(eye, Vector3(hid.x, bs.h_max + 1.0, hid.y)),
			"ligne de vue : coupée derrière l'immeuble %d (%.0f m de haut), libre devant lui et au-dessus de son toit" % [b, c.city.b_h[b]])
	var zh = _still8(c, hid)
	var zv = _still8(c, seen)
	gs.aim = (hid + seen) * 0.5
	gs.update(0.0)
	var lk = c.lock
	lk.scan()
	var n1: int = lk.hidden.size()
	lk.scan()
	var n2: int = lk.hidden.size()
	_check(lk.level == 1.0 and n1 == 0 and n2 == 1 and (lk.hidden[0] as Vector2).is_equal_approx(hid) and lk.hidden_p[0] == zh and zv.hid == 0,
			"verrouillage : l'infecté caché est verrouillé à la 2e mesure (pas de clignotement), pas celui qui est en vue (%d, %d)" % [n1, n2])
	zh.pos = seen
	lk.scan()
	lk.scan()
	_check(lk.hidden.is_empty(), "sorti de derrière l'immeuble, il perd son carré")
	zh.pos = hid
	zh.hid = 0
	lk.update(0.16)
	lk.update(0.16)
	_check(lk.hidden.size() == 1, "update() mesure toutes les %.2f s (%d verrouillé)" % [lk.PERIOD, lk.hidden.size()])
	zh.alive = false
	_check(lk.guide(Vector3(eye.x, eye.y, eye.z), (Vector3(hid.x, 0.0, hid.y) - eye).normalized(), 8.0) == null, "un infecté tué ne guide plus aucun obus (avant même la mesure suivante)")
	zh.alive = true
	zh.kind = Crowd.K_DEAD
	_check(lk.guide(Vector3(eye.x, eye.y, eye.z), (Vector3(hid.x, 0.0, hid.y) - eye).normalized(), 8.0) == null, "un infecté abattu (cadavre) ne guide plus d'obus non plus")
	zh.kind = Crowd.K_ZOMBIE
	c.director.state = "won"
	lk.update(0.16)
	_check(lk.hidden.is_empty() and not lk.enabled(), "partie finie : plus de verrouillage")
	c.director.state = "running"

	# coût : beaucoup d'infectés dans le champ, la mesure reste bornée
	c.crowd.spawn_cluster(c.gunship.aim, 0.0, 300.0, 200)
	var worst_us := 0.0
	var tot_us := 0.0
	var frames := 180
	for i in frames:
		var t0 := Time.get_ticks_usec()
		lk.update(1.0 / 60.0)
		var us: float = float(Time.get_ticks_usec() - t0)
		worst_us = maxf(worst_us, us)
		tot_us += us
	_check(lk.tests > 40 and lk.tests <= lk.MAX_TESTS and worst_us < 4000.0,
			"%d infectés évalués par passe (au plus %d), étalés sur les images : %.2f ms par image au pire, %.2f ms en moyenne" % [lk.tests, lk.MAX_TESTS, worst_us / 1000.0, tot_us / float(frames) / 1000.0])

	# Cauchemar : aucun carré, aucune aide
	var cn = _lock_world8("nightmare")
	var zn = _still8(cn, hid)
	cn.gunship.aim = hid
	cn.gunship.update(0.0)
	cn.lock.update(0.16)
	cn.lock.update(0.16)
	cn.lock.update(0.16)
	_check(cn.lock.level == 0.0 and cn.lock.hidden.is_empty() and zn.hid == 0, "Cauchemar : pas de carré rouge (niveau %.0f)" % cn.lock.level)

	# tir au 40 mm sur l'infecté caché : sans aide l'obus éclate sur l'immeuble, guidé il tombe dans la rue
	var ray: Array = gs.ray()
	var cg = _lock_world8()
	var zg = _still8(cg, hid)
	cg.gunship.aim = hid
	cg.gunship.update(0.0)
	cg.lock.scan()
	cg.lock.scan()
	var hit0: Dictionary = cg.buildings.trace(cg.gunship.ray()[0], cg.gunship.ray()[1])
	cg.arms.select(1)
	cg.arms.trigger = true
	cg.arms.update(0.0)
	cg.arms.trigger = false
	var sh = cg.arms.shells[0] if cg.arms.shells.size() > 0 else null
	var guided: bool = sh != null and sh.b == -1 and absf(sh.pos.y) < 0.01 and Vector2(sh.pos.x, sh.pos.z).distance_to(hid) < 1.0
	cg.arms.update(1.3)
	_check(int(hit0["b"]) >= 0 and guided and not (zg.alive and zg.kind == Crowd.K_ZOMBIE),
			"tir de 40 mm sur un infecté verrouillé derrière l'immeuble %d : obus guidé jusqu'à la rue, l'infecté est abattu" % int(hit0["b"]))
	var r40: float = float(cg.weapons[1]["splash_radius_m"])
	var zg2 = _still8(cg, hid)
	cg.lock.scan()
	cg.lock.scan()
	_check(cg.lock.aim_guided(int(hit0["b"]), r40) and not cg.lock.aim_guided(-1, r40),
			"le viseur annonce « TIR GUIDÉ » quand le tir le serait (et jamais sans immeuble sous le réticule)")
	var cf = _lock_world8("nightmare")
	var zf = _still8(cf, hid)
	cf.gunship.aim = hid
	cf.gunship.update(0.0)
	cf.arms.select(1)
	cf.arms.trigger = true
	cf.arms.update(0.0)
	cf.arms.trigger = false
	var sf = cf.arms.shells[0] if cf.arms.shells.size() > 0 else null
	var on_roof: bool = sf != null and sf.b >= 0 and sf.pos.y > 4.0
	cf.arms.update(1.3)
	_check(on_roof and zf.alive and zf.kind == Crowd.K_ZOMBIE, "même tir en Cauchemar : l'obus éclate sur l'immeuble, l'infecté derrière vit (obus à %.0f m de haut)" % (sf.pos.y if sf != null else -1.0))
	_check(not cf.lock.aim_guided(int(sf.b) if sf != null else 0, r40), "Cauchemar : le viseur n'annonce jamais de tir guidé")
	# un immeuble à raser garde les obus qui lui sont destinés
	var cr2 = _lock_world8()
	var zr = _still8(cr2, hid)
	cr2.gunship.aim = hid
	cr2.gunship.update(0.0)
	cr2.lock.scan()
	cr2.lock.scan()
	var hb: int = int(cr2.buildings.trace(cr2.gunship.ray()[0], cr2.gunship.ray()[1])["b"])
	cr2.buildings.occ[hb] = 6
	cr2.buildings.infest(hb, 4, 0.0)
	var alert: bool = cr2.buildings.is_raze_alert(hb)
	cr2.arms.select(1)
	cr2.arms.trigger = true
	cr2.arms.update(0.0)
	var sr = cr2.arms.shells[0] if cr2.arms.shells.size() > 0 else null
	_check(alert and sr != null and sr.b == hb, "sur un immeuble à raser (rouge), l'obus n'est pas détourné : il le frappe (immeuble %d)" % hb)
	_check(alert and not cr2.lock.aim_guided(hb, r40), "sur un immeuble à raser, le viseur n'annonce pas de tir guidé")
