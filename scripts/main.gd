extends Node3D
## Stryge — point d'entrée : assemble le monde, les systèmes, les vues et la boucle de jeu.
## Arguments (après « -- ») : --seed=N  --size=2400  --style=latin  --city=chemin.json  --autopilot=demo  --out=/tmp/shots
##   --mission=mission_03 (secteur ; sans cela : le dernier secteur joué)  --difficulty=recruit|veteran|nightmare
##   --nosound (sans audio)  --audio-record=/tmp/mix.wav (enregistre le mélange)  --audio-seconds=60 (quitte après 60 s)  --audio-log (journal)
##   --daily[=AAAA-MM-JJ] (défi du jour : celui de la date, par défaut d'aujourd'hui)  --endless (Nuit blanche sur le secteur choisi)
##   --mutators=fog,radio_down,...  (mutateurs de data/mutators.json)
##   --export-check (contrôle d'un export : données, sons et shaders présents dans le paquet ; quitte avec le code 0 si tout y est)
##   --profile=chemin.json (profil du joueur ailleurs que dans user://profile.json)  --noprofile (profil neuf, jamais sauvegardé ;
##   c'est aussi le cas avec --autopilot, sauf si --profile est donné)

const Ctx := preload("res://scripts/ctx.gd")
const CityData := preload("res://scripts/world/city_data.gd")
const CityGen := preload("res://scripts/world/city_generator.gd")
const StreetGraph := preload("res://scripts/world/street_graph.gd")
const CityRenderer := preload("res://scripts/world/city_renderer.gd")
const BuildingSystem := preload("res://scripts/sim/building_system.gd")
const Crowd := preload("res://scripts/sim/crowd.gd")
const Director := preload("res://scripts/sim/director.gd")
const Gunship := preload("res://scripts/core/gunship.gd")
const Arms := preload("res://scripts/core/arms.gd")
const Predictor := preload("res://scripts/core/predictor.gd")
const Designator := preload("res://scripts/core/designator.gd")
const Assist := preload("res://scripts/core/assist.gd")
const Lock := preload("res://scripts/core/lock.gd")
const Supports := preload("res://scripts/core/supports.gd")
const Fx := preload("res://scripts/core/fx.gd")
const Sound := preload("res://scripts/core/sound.gd")
const Score := preload("res://scripts/meta/score.gd")
const Objectives := preload("res://scripts/meta/objectives.gd")
const Defs := preload("res://scripts/meta/defs.gd")
const Campaign := preload("res://scripts/meta/campaign.gd")
const Mutators := preload("res://scripts/meta/mutators.gd")
const Daily := preload("res://scripts/meta/daily.gd")
const Profile := preload("res://scripts/meta/profile.gd")
const Screens := preload("res://scripts/ui/screens.gd")
const Hud := preload("res://scripts/ui/hud.gd")
const AutoPilot := preload("res://scripts/dev/autopilot.gd")
const POST_SHADER := preload("res://shaders/thermal_post.gdshader")
const ExportCheck := preload("res://scripts/dev/export_check.gd")

var ctx
var cam: Camera3D
var post_mat: ShaderMaterial
var hud
var state := "briefing"        # briefing | playing | paused | ended
var white_hot := true
var marks_on := true           # marquage couleur civils / zombies (touche C)
var mark_level := 1.0
var show_map := true
var show_help := false
var slew_accum := Vector2.ZERO
var aim_range := 2500.0
var aim_bearing := 0.0
var aim_pos := Vector3.ZERO       # point touché par la ligne de visée (sol ou toit)
var aim_b := -1                   # immeuble sous le réticule, -1 si le sol
var aim_site := 60.0              # angle de site : dépression de la visée sous l'horizontale (°)
var trigger_override := false
var flash_level := 0.0
var args := {}
var autopilot = null
var screens = null                # Screens : débriefing et menus (Control)
var reticle_style: Dictionary = {}   # réticule cosmétique équipé (width, ring, center)
var _prev_shots := 0
var session: Dictionary = {}      # session en cours : mission, difficulty, mode, mutators, seed, wave_seed, date
var _weapons_base: Array = []     # armes de data/weapons.json (avant améliorations et mutateurs)


func _ready() -> void:
	args = _parse_args()
	if args.has("export-check"):
		# contrôle d'un export (compilation GitHub) : données, sons et shaders présents dans le paquet
		set_process(false)
		set_process_input(false)
		get_tree().quit(ExportCheck.run(str(args.get("check-out", ""))))
		return
	ctx = Ctx.new()

	var wj = _load_json("res://data/weapons.json")
	var sj = _load_json("res://data/scoring.json")
	if wj == null or sj == null:
		push_error("Données de jeu introuvables (data/*.json).")
		get_tree().quit(1)
		return
	# profil du joueur : grade, améliorations, médailles, cosmétiques (les essais automatiques n'écrivent jamais le vrai profil)
	var defs = Defs.load_all()
	if not defs.ok():
		push_error("Données de progression : %s" % defs.error)
		get_tree().quit(1)
		return
	var prof_path := "user://profile.json"
	if args.has("profile"):
		prof_path = str(args["profile"])
	elif args.has("noprofile") or args.has("autopilot"):
		prof_path = ""
	ctx.profile = Profile.new()
	ctx.profile.setup(defs, prof_path)
	ctx.profile.load_file()
	if ctx.profile.load_error != "":
		push_warning(ctx.profile.load_error)
	# secteur et difficulté de cette partie
	var sess := _pick_session(defs)
	session = sess
	var mj: Dictionary = Campaign.load_mission(defs, str(sess["mission"]))
	if mj.is_empty():
		push_error("Mission introuvable : %s" % str(sess["mission"]))
		get_tree().quit(1)
		return
	ctx.base_mission = mj
	ctx.mode = str(sess["mode"])
	ctx.mutators = Mutators.clean(defs, sess["mutators"])
	ctx.zombie_types = defs.zombie_types
	ctx.mission = _build_mission(defs, mj, str(sess["difficulty"]))
	ctx.mods = ctx.profile.mods()
	_weapons_base = wj["weapons"]
	ctx.weapons = Mutators.weapons(ctx.profile.weapons(_weapons_base), defs, ctx.mutators)
	ctx.score = Score.new()
	ctx.score.setup(ctx, sj)
	ctx.objectives = Objectives.new()
	ctx.objectives.setup(ctx, ctx.mission.get("objectives", []))

	# --- monde
	var cdef: Dictionary = ctx.mission.get("city", {})
	var seed_v := int(args.get("seed", sess.get("seed", cdef.get("seed", 1914))))
	ctx.rng.seed = seed_v + 7
	if sess.has("wave_seed"):
		ctx.wave_rng.seed = int(sess["wave_seed"])          # défi du jour : mêmes tirages de vagues pour tous
	elif args.has("seed") or args.has("autopilot"):
		ctx.wave_rng.seed = seed_v + 8                      # essais et captures : reproductibles
	else:
		ctx.wave_rng.randomize()                            # campagne et Nuit blanche : des vagues différentes à chaque partie
	var city = CityData.new()
	if args.has("city"):
		if not city.load_json(str(args["city"])):
			push_error("Impossible de charger la ville : %s" % str(args["city"]))
			get_tree().quit(1)
			return
	elif cdef.has("file") and not args.has("style") and not args.has("size"):
		# secteur réel : carte convertie de l'IGN / OpenStreetMap (data/cities/<fichier>.json)
		var cpath := "res://data/cities/%s.json" % str(cdef["file"])
		if not city.load_json(cpath):
			push_error("Impossible de charger la carte : %s" % cpath)
			get_tree().quit(1)
			return
	else:
		city = CityGen.new().generate(seed_v, float(args.get("size", cdef.get("size", 2400.0))), str(args.get("style", cdef.get("style", "latin"))))
	var graph := StreetGraph.new()
	graph.build(city)
	graph.snap_doors(city)
	ctx.city = city
	ctx.graph = graph

	# --- environnement, caméra
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.025)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	cam = Camera3D.new()
	cam.near = 1200.0
	cam.far = 9000.0
	cam.fov = 4.0
	cam.current = true
	add_child(cam)

	# --- systèmes
	var cr := CityRenderer.new()
	cr.build(self, city, graph)
	var bs := BuildingSystem.new()
	var crowd := Crowd.new()
	var dir := Director.new()
	var gs := Gunship.new()
	var arms := Arms.new()
	var fx := Fx.new()
	fx.name = "Fx"
	add_child(fx)
	ctx.buildings = bs
	ctx.crowd = crowd
	ctx.director = dir
	ctx.gunship = gs
	ctx.arms = arms
	ctx.fx = fx
	bs.setup(ctx, city)
	bs.view = cr
	crowd.setup(ctx)
	crowd.setup_view(self)
	fx.setup(ctx)
	dir.setup(ctx)
	gs.setup(ctx, cam)
	var zmax := maxf(ctx.mod("zoom_max", gs.BASE_ZOOM_MAX), gs.BASE_ZOOM_MAX)
	gs.zoom_max = zmax
	gs.min_fov = gs.MIN_FOV * gs.BASE_ZOOM_MAX / zmax
	arms.setup(ctx)
	ctx.predictor = Predictor.new()
	ctx.predictor.setup(ctx)
	ctx.designator = Designator.new()
	ctx.designator.setup(ctx)
	ctx.assist = Assist.new()
	ctx.assist.setup(ctx)
	ctx.lock = Lock.new()
	ctx.lock.setup(ctx)
	ctx.supports = Supports.new()
	ctx.supports.setup(ctx, defs.supports)

	# --- post-traitement thermique + interface
	var post_layer := CanvasLayer.new()
	post_layer.layer = 1
	add_child(post_layer)
	var rect := ColorRect.new()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	post_mat = ShaderMaterial.new()
	post_mat.shader = POST_SHADER
	rect.material = post_mat
	post_layer.add_child(rect)
	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 2
	add_child(hud_layer)
	hud = Hud.new()
	hud_layer.add_child(hud)
	hud.setup(ctx, self)
	hud.set_text_size(int(ctx.profile.settings.get("text", Hud.TEXT_DEFAULT)), false)
	var ui_layer := CanvasLayer.new()
	ui_layer.layer = 3
	add_child(ui_layer)
	screens = Screens.new()
	screens.setup(ctx, self, ui_layer)

	# --- son : tirs, moteurs, radio vocale (désactivable : --nosound)
	if not args.has("nosound"):
		var snd := Sound.new()
		ctx.sound = snd
		snd.setup(ctx, self)
		if args.has("audio-log"):
			snd.trace = true
			snd.radio.trace = true
		if args.has("audio-record"):
			snd.start_record(str(args["audio-record"]))

	apply_cosmetics()
	_apply_atmosphere()
	screens.show_briefing()
	if args.has("autopilot"):
		autopilot = AutoPilot.new()
		autopilot.setup(self, args)
	print("PNG prêt : %d immeubles, %d tronçons, graine %d" % [city.building_count(), city.edge_a.size(), seed_v])


## Secteur et difficulté de la partie. Priorité : choix fait pendant cette exécution (conservé d'un rechargement de la scène à
## l'autre), puis arguments --mission / --difficulty (un secteur demandé en argument est jouable même s'il est encore fermé),
## puis réglages du profil (dernier secteur joué, dernière difficulté).
func _pick_session(defs) -> Dictionary:
	var prof = ctx.profile
	var sess: Dictionary = Engine.get_meta("pnc_session", {}) if Engine.has_meta("pnc_session") else {}
	# --daily : défi du jour d'une date (essais, captures) ; il s'impose sauf si une session a déjà été choisie
	if args.has("daily") and not sess.has("mission"):
		var date := str(args["daily"])
		if not Daily.valid_date(date):
			date = Daily.today()
		var plan: Dictionary = Daily.plan(defs, date)
		sess = {"mission": plan["sector"], "difficulty": plan["level"], "mode": "daily", "mutators": plan["mutators"],
				"seed": plan["seed"], "wave_seed": plan["wave_seed"], "date": date}
	var mission := ""
	var forced := false
	if sess.has("mission"):
		mission = str(sess["mission"])
		forced = true
	elif args.has("mission"):
		mission = str(args["mission"])
		forced = true
	if not defs.sector_by_id.has(mission):
		if mission != "":
			push_warning("Secteur inconnu : %s" % mission)
		mission = Campaign.start_sector(defs, prof)
		forced = false
	if not forced and not Campaign.is_unlocked(defs, prof, mission):
		mission = Campaign.start_sector(defs, prof)
	var level := ""
	if sess.has("difficulty"):
		level = str(sess["difficulty"])
	elif args.has("difficulty"):
		level = str(args["difficulty"])
	elif prof.path == "":
		level = defs.default_level            # essais et pilote automatique : toujours le réglage de référence
	else:
		level = Campaign.start_level(defs, prof)
	if not defs.level_by_id.has(level):
		push_warning("Difficulté inconnue : %s" % level)
		level = defs.default_level
	var mode := str(sess.get("mode", "campaign")) if sess.has("mission") else "campaign"
	if args.has("endless") and not sess.has("mission"):
		mode = "endless"
	if not ["campaign", "daily", "endless"].has(mode):
		mode = "campaign"
	var muts: Array = (sess.get("mutators", []) as Array).duplicate() if sess.has("mission") else []
	if args.has("mutators") and not sess.has("mutators"):
		muts = Array(str(args["mutators"]).split(",", false))
	var out := {"mission": mission, "difficulty": level, "mode": mode, "mutators": Mutators.clean(defs, muts)}
	for k in ["seed", "wave_seed", "date"]:
		if sess.has(k) and mode == "daily":
			out[k] = sess[k]
	return out


## Mission jouée : celle du secteur, transformée par la difficulté puis par les mutateurs ; en Nuit blanche, le calendrier
## des vagues et les seuils de note viennent de data/modes.json.
func _build_mission(defs, base: Dictionary, level_id: String) -> Dictionary:
	var m: Dictionary = Mutators.apply(Campaign.apply_difficulty(base, defs.level(level_id)), defs, ctx.mutators)
	if ctx.mode == "endless":
		var ec: Dictionary = defs.mode_cfg("endless").duplicate(true)
		m["endless"] = ec
		m["score_targets"] = ec.get("rating", [3000, 8000, 15000, 26000])
		m["objectives"] = _endless_objectives(m.get("objectives", []), ec)
	return m


## Nuit blanche : les objectifs secondaires du secteur reviennent par cycles (objective_cycles fois, un cycle durant au moins
## objective_cycle_s secondes et jusqu'à la fin du dernier objectif) ; les objectifs cachés ne se gagnent qu'une fois.
func _endless_objectives(base: Array, ec: Dictionary) -> Array:
	var out: Array = []
	var last := 0.0
	for o in base:
		if str(o.get("kind", "secondary")) != "hidden":
			last = maxf(last, float(o.get("t", 0.0)) + float(o.get("duration", 0.0)))
	var cyc := maxf(float(ec.get("objective_cycle_s", 300.0)), last + 5.0)
	for k in int(ec.get("objective_cycles", 8)):
		for o in base:
			var hidden := str(o.get("kind", "secondary")) == "hidden"
			if hidden and k > 0:
				continue
			var c: Dictionary = (o as Dictionary).duplicate(true)
			if not hidden:
				c["t"] = float(c.get("t", 0.0)) + cyc * k
			if k > 0:
				c["id"] = "%s_c%d" % [str(c.get("id", "obj")), k]
			out.append(c)
	return out


func _parse_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv: PackedStringArray = a.substr(2).split("=", true, 1)
			out[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return out


func _load_json(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


# ---------------------------------------------------------------- états

func start_mission() -> void:
	if state != "briefing":
		return
	screens.close()
	state = "playing"
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	ctx.director.start()


func set_paused(p: bool) -> void:
	if p and state == "playing":
		state = "paused"
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if ctx.sound != null:
			ctx.sound.set_paused(true)
	elif not p and state == "paused":
		state = "playing"
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if ctx.sound != null:
			ctx.sound.set_paused(false)


func _finish() -> void:
	state = "ended"
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var res: Dictionary = ctx.score.finish(ctx.director.state == "won")
	if not res.has("progress"):
		var lv: Dictionary = ctx.difficulty()
		res["difficulty"] = str(lv.get("id", ""))
		res["diff"] = int(lv.get("index", -1))
		res["sector"] = str(ctx.mission.get("id", ""))
		res["date"] = str(session.get("date", "")) if ctx.mode == "daily" else ""
		var extra := {"mut_mult": Mutators.reward_mult(ctx.profile.defs, ctx.mutators), "mutators": ctx.mutators.duplicate(),
				"sector": str(ctx.mission.get("id", "")), "waves": ctx.director.wave_n, "date": str(session.get("date", ""))}
		res["progress"] = ctx.profile.apply_mission(res, str(ctx.mission.get("id", "mission")),
				float(lv.get("xp_mult", 1.0)), float(lv.get("credit_mult", 1.0)), int(lv.get("index", -1)), ctx.mode, extra)
		_remember_session()
		ctx.profile.save()
	screens.show_debrief(res)


## Applique les cosmétiques équipés : filtre thermique, réticule, voix de la radio.
func apply_cosmetics() -> void:
	var prof = ctx.profile
	var f: Dictionary = prof.equipped_item("filter")
	if not f.is_empty():
		post_mat.set_shader_parameter("tint", Vector3(float(f["tint"][0]), float(f["tint"][1]), float(f["tint"][2])))
		post_mat.set_shader_parameter("zombie_tint", Vector3(float(f["zombie"][0]), float(f["zombie"][1]), float(f["zombie"][2])))
		post_mat.set_shader_parameter("civil_tint", Vector3(float(f["civil"][0]), float(f["civil"][1]), float(f["civil"][2])))
	reticle_style = prof.equipped_item("reticle")
	if ctx.sound != null:
		ctx.sound.set_voice_style(prof.equipped_item("voice"))


## Refait la mission, les armes et les systèmes qui en dépendent après un changement de difficulté ou de mutateurs au briefing
## (la ville n'est pas régénérée).
func _rebuild_rules(level_id: String) -> void:
	var defs = ctx.profile.defs
	ctx.mission = _build_mission(defs, ctx.base_mission, level_id)
	ctx.weapons = Mutators.weapons(ctx.profile.weapons(_weapons_base), defs, ctx.mutators)
	ctx.arms.setup(ctx)
	ctx.director.setup(ctx)
	ctx.objectives.setup(ctx, ctx.mission.get("objectives", []))
	ctx.supports.reset()
	ctx.assist.reset()
	ctx.lock.reset()
	ctx.buildings.reroll_doors()
	_apply_atmosphere()


## Mutateurs du briefing : bascule d'un mutateur (les incompatibles sont retirés). Retourne vrai si la liste a changé.
func toggle_mutator(id: String) -> bool:
	var defs = ctx.profile.defs
	if state != "briefing" or ctx.mode == "daily":       # le défi du jour impose ses mutateurs
		return false
	var before: Array = ctx.mutators.duplicate()
	ctx.mutators = Mutators.toggled(defs, ctx.mutators, id)
	if ctx.mutators == before:
		return false
	_rebuild_rules(str(ctx.difficulty().get("id", defs.default_level)))
	_remember_session()
	return true


## Brouillard : la chaleur s'éteint plus vite avec la distance (sol, immeubles, personnes) et l'image devient plus bruitée.
func _apply_atmosphere() -> void:
	var fog := 1.0 + 7.0 * Mutators.factor(ctx.profile.defs, ctx.mutators, "fog", 0.0)
	var k := 0.00005 * fog
	if ctx.buildings != null and ctx.buildings.view != null:
		ctx.buildings.view.set_atmos(k)
	if ctx.crowd != null:
		ctx.crowd.set_atmos(k)
	if post_mat != null:
		post_mat.set_shader_parameter("noise_amount", 0.045 if fog <= 1.0 else 0.085)
		post_mat.set_shader_parameter("vignette_amount", 0.5 if fog <= 1.0 else 0.66)


## Mémorise le secteur, la difficulté, le mode et les mutateurs courants pour la prochaine scène (rechargement) et le prochain lancement.
func _remember_session() -> void:
	var lv: Dictionary = ctx.difficulty()
	var sid := str(ctx.mission.get("id", ""))
	var cur := {"mission": sid, "difficulty": str(lv.get("id", "")), "mode": ctx.mode, "mutators": ctx.mutators.duplicate()}
	for k in ["seed", "wave_seed", "date"]:
		if session.has(k):
			cur[k] = session[k]
	Engine.set_meta("pnc_session", cur)
	ctx.profile.settings["sector"] = sid
	ctx.profile.settings["difficulty"] = str(lv.get("id", ""))


## Reconstruit le monde avec les armes et réglages achetés à l'atelier (le profil est sauvegardé d'abord).
func reload_for_loadout() -> void:
	_remember_session()
	ctx.profile.save()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()


func replay() -> void:
	if ctx.mode == "daily" and Daily.today() != str(session.get("date", "")) and not args.has("daily"):
		start_daily()                      # minuit est passé : le défi à rejouer est celui d'aujourd'hui
		return
	_remember_session()
	ctx.profile.save()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()


## Défi du jour, Nuit blanche : ouverts après les premières victoires (modes.json, clé unlock_wins).
func modes_unlocked() -> bool:
	return int(ctx.profile.stats["wins"]) >= int(ctx.profile.defs.modes.get("unlock_wins", 1))


## Lance le défi du jour (celui de la date donnée, par défaut d'aujourd'hui) : même scénario pour tous, à chaque essai.
func start_daily(date: String = "") -> void:
	var defs = ctx.profile.defs
	if not modes_unlocked():
		return
	if not Daily.valid_date(date):
		date = Daily.today()
	var plan: Dictionary = Daily.plan(defs, date)
	Engine.set_meta("pnc_session", {"mission": plan["sector"], "difficulty": plan["level"], "mode": "daily",
			"mutators": plan["mutators"], "seed": plan["seed"], "wave_seed": plan["wave_seed"], "date": date})
	ctx.profile.save()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()


## Lance la Nuit blanche sur un secteur déjà ouvert.
func start_endless(mission_id: String, level_id: String, mutators: Array = []) -> void:
	var defs = ctx.profile.defs
	if not modes_unlocked() or not defs.sector_by_id.has(mission_id) or not defs.level_by_id.has(level_id):
		return
	if not Campaign.is_unlocked(defs, ctx.profile, mission_id):
		return
	Engine.set_meta("pnc_session", {"mission": mission_id, "difficulty": level_id, "mode": "endless",
			"mutators": Mutators.clean(defs, mutators)})
	ctx.profile.settings["sector"] = mission_id
	ctx.profile.settings["difficulty"] = level_id
	ctx.profile.settings["picked"] = true            # choisi sur la carte ou dans les modes : repris tel quel au prochain lancement
	ctx.profile.save()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()


## Lance un autre secteur (ou le même à une autre difficulté) : la ville est régénérée, donc la scène est rechargée.
func select_session(mission_id: String, level_id: String) -> void:
	var defs = ctx.profile.defs
	if not defs.sector_by_id.has(mission_id) or not defs.level_by_id.has(level_id):
		return
	if not Campaign.is_unlocked(defs, ctx.profile, mission_id):
		return
	Engine.set_meta("pnc_session", {"mission": mission_id, "difficulty": level_id, "mode": "campaign", "mutators": []})
	ctx.profile.settings["sector"] = mission_id
	ctx.profile.settings["difficulty"] = level_id
	ctx.profile.settings["picked"] = true            # choisi sur la carte ou dans les modes : repris tel quel au prochain lancement
	ctx.profile.save()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()


## Change la difficulté avant le départ, sans régénérer la ville : la mission est recalculée depuis celle du secteur.
func set_difficulty(level_id: String) -> void:
	var defs = ctx.profile.defs
	if state != "briefing" or ctx.mode == "daily" or not defs.level_by_id.has(level_id):
		return                        # le défi du jour impose sa difficulté
	_rebuild_rules(level_id)
	_remember_session()
	ctx.profile.settings["picked"] = true         # choix du joueur : il sera repris tel quel au prochain lancement
	ctx.profile.save()
	screens.show_briefing()


func _exit_tree() -> void:
	if ctx != null and ctx.sound != null:
		ctx.sound.stop_record()


func capture(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)


# ---------------------------------------------------------------- entrées

func _input(event: InputEvent) -> void:
	var ui_open: bool = screens != null and screens.is_open()
	if ui_open and event is InputEventKey and screens.handle_key(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		if state == "playing":
			slew_accum += event.relative
	elif event is InputEventMouseButton and event.pressed:
		if ui_open:
			return
		if state == "briefing":
			start_mission()
		elif state == "playing":
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				ctx.gunship.zoom = clampf(ctx.gunship.zoom * 1.15, 0.25, ctx.gunship.zoom_max)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				ctx.gunship.zoom = clampf(ctx.gunship.zoom / 1.15, 0.25, ctx.gunship.zoom_max)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				_toggle_designator()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_ENTER, KEY_KP_ENTER:
				if state == "briefing":
					start_mission()
				elif state == "paused" and ctx.director.endless:
					ctx.director.end_patrol()          # Nuit blanche : on rend la main à l'équipage, le score est conservé
					set_paused(false)
				elif state == "ended" and not ui_open:
					replay()
			KEY_ESCAPE, KEY_P:
				set_paused(state == "playing")
			KEY_1, KEY_KP_1:
				ctx.arms.select(0)
			KEY_2, KEY_KP_2:
				ctx.arms.select(1)
			KEY_3, KEY_KP_3:
				ctx.arms.select(2)
			KEY_4, KEY_KP_4:
				_call_support(0)
			KEY_5, KEY_KP_5:
				_call_support(1)
			KEY_6, KEY_KP_6:
				_call_support(2)
			KEY_7, KEY_KP_7:
				_call_support(3)
			KEY_TAB:
				ctx.arms.cycle()
			KEY_SPACE:
				white_hot = not white_hot
			KEY_E:
				if state == "playing":
					_toggle_designator()
			KEY_C:
				marks_on = not marks_on
			KEY_R:
				if state == "playing":
					ctx.gunship.recenter()
					ctx.say("recenter", {}, "Nocturne 2-1 : recentrage de l'orbite sur la zone visée.", "info")
			KEY_M:
				show_map = not show_map
			KEY_N:
				if ctx.sound != null:
					ctx.sound.toggle_mute()
			KEY_V:
				if ctx.sound != null:
					ctx.sound.toggle_voices()
			KEY_H:
				show_help = not show_help
			KEY_T:
				hud.cycle_text_size()
			KEY_F11:
				var m := DisplayServer.window_get_mode()
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED
						if m == DisplayServer.WINDOW_MODE_FULLSCREEN else DisplayServer.WINDOW_MODE_FULLSCREEN)


## Appui demandé sur le point visé (touches 4 à 7) : l'ordre des appuis est celui de data/supports.json.
func _call_support(i: int) -> void:
	if state != "playing" or ctx.supports == null or i >= ctx.supports.defs.size():
		return
	var why: String = ctx.supports.request(str(ctx.supports.defs[i]["id"]), ctx.gunship.aim)
	if ctx.sound != null:
		ctx.sound.cue("lock" if why == "" else "fail")
	if why != "":
		ctx.radio("Appui refusé : " + why, "alert")


## Désignateur laser (clic droit ou E) : verrouille l'infecté le plus proche du réticule, ou relâche le verrou.
func _toggle_designator() -> void:
	var des = ctx.designator
	if des == null or des.level() == 0:
		return
	var was: bool = des.active
	des.toggle()
	if ctx.sound != null:
		ctx.sound.cue("lock" if des.active else ("release" if was else "fail"))


func _apply_input(dt: float) -> void:
	var d := slew_accum
	slew_accum = Vector2.ZERO
	var k := Vector2(
			float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT))
			- float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)),
			float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN))
			- float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)))
	var speed := 420.0 * (3.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	d += k * speed * dt
	if d != Vector2.ZERO:
		var a0: Vector2 = ctx.gunship.aim
		ctx.gunship.slew_px(d)
		ctx.assist.note_input(ctx.gunship.aim - a0)       # ce que le joueur a voulu : l'aimant de la Recrue s'efface devant lui


# ---------------------------------------------------------------- boucle

func _process(delta: float) -> void:
	var dt := minf(delta, 0.1)
	if hud.size.y > 0.0:
		ctx.gunship.view_h = hud.size.y
	if autopilot != null:
		autopilot.update(dt)
	match state:
		"briefing":
			ctx.gunship.update(dt)
			_update_aim()
		"playing":
			_play_frame(dt)
		"ended":
			ctx.gunship.update(dt)
			_update_aim()
			ctx.buildings.step(dt)
			ctx.crowd.step(dt)
	if state != "paused":
		ctx.fx.update(dt, cam)
	if ctx.sound != null:
		ctx.sound.update(delta, dt, state)
		if args.has("audio-seconds") and ctx.sound.clock() >= float(args["audio-seconds"]):
			get_tree().quit()
	ctx.crowd.write_view()
	_update_post(dt)
	hud.queue_redraw()


func _play_frame(dt: float) -> void:
	ctx.time += dt
	_apply_input(dt)
	ctx.designator.update(dt)        # le verrou laser tire la visée vers l'infecté désigné avant que la nacelle ne se règle
	ctx.assist.update(dt)            # Recrue : la visée est attirée vers la zone urgente (si le joueur ne la tient pas)
	ctx.gunship.update(dt)
	_update_aim()
	ctx.arms.trigger = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or trigger_override
	ctx.arms.update(dt)
	ctx.supports.update(dt)
	ctx.buildings.step(dt)
	ctx.crowd.step(dt)
	ctx.predictor.update(dt)
	ctx.director.step(dt)
	ctx.lock.update(dt)              # infectés cachés derrière un immeuble : carrés rouges (HUD) et obus guidés (Arms)
	if ctx.director.state == "won" or ctx.director.state == "lost":
		_finish()


func _update_aim() -> void:
	var ray: Array = ctx.gunship.ray()
	var o: Vector3 = ray[0]
	var hit: Dictionary = ctx.buildings.trace(o, ray[1])
	var p: Vector3 = hit["pos"]
	aim_range = o.distance_to(p)
	aim_bearing = ctx.gunship.bearing_to(p)
	aim_pos = p
	aim_b = int(hit["b"])
	aim_site = rad_to_deg(asin(clampf((o.y - p.y) / maxf(aim_range, 1.0), -1.0, 1.0)))


func _update_post(dt: float) -> void:
	if ctx.arms.shots != _prev_shots:
		_prev_shots = ctx.arms.shots
		var w: Dictionary = ctx.weapons[ctx.arms.current]
		flash_level = minf(flash_level + 0.04 * float(w["flash"]), 0.2)
	flash_level = maxf(flash_level - dt * 1.6, 0.0)
	mark_level = move_toward(mark_level, 1.0 if marks_on else 0.0, dt * 4.0)
	post_mat.set_shader_parameter("white_hot", white_hot)
	post_mat.set_shader_parameter("flash", flash_level)
	post_mat.set_shader_parameter("mark_strength", mark_level)
