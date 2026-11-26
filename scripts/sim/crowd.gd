extends RefCounted
## Foule des rues : zombies et civils en fuite, qui se déplacent sur le graphe routier.
## Les civils encore dans les immeubles ne sont que des compteurs (BuildingSystem.occ).

const HumanMesh := preload("res://scripts/world/human_mesh.gd")
const PERSON_SHADER := preload("res://shaders/thermal_human.gdshader")

const MAX_P := 1024
const K_ZOMBIE := 0
const K_CIVIL := 1
const K_EATEN := 2      # civil dévoré, au sol, qui se relèvera en zombie
const K_DEAD := 3       # cadavre qui refroidit
const TICK := 0.2
const VIS_SCALE := 1.3  # les personnages sont légèrement grossis pour rester lisibles à 2,5 km
const ZOMBIE_CAP := 420
const RISE_TIME := 1.8  # durée pendant laquelle un corps dévoré se relève en zombie
const FALL_TIME := 0.7  # durée de la chute d'un civil dévoré ou abattu
const FEED_TIME := 3.4  # durée du repas d'un zombie après une capture

# Codes d'allure transmis au shader (champ w des données d'instance)
const G_POUND := 3.0    # zombie qui martèle une porte
const G_FEED := 4.0     # zombie penché sur sa proie
const G_RISE := 5.0     # 5 + degré de chute (0 debout, 1 au sol) : zombie qui se relève

# Infectés spéciaux (data/zombies.json)
const ZT_COLOSSUS := 1
const ZT_SCREAMER := 2
const ZT_ALPHA := 3
const ZT_IDS := ["", "colossus", "screamer", "alpha"]
const MODE_DECOY := 4   # zombie attiré par un leurre sonore
const MODE_CHASE := 5   # zombie qui poursuit un civil de la rue


class P:
	var id := 0
	var alive := false
	var kind := 0
	var mode := 0              # zombie : 0 = sans cible, 1 = chasse, 2 = erre, 3 = siège d'une porte
	var edge := 0
	var t := 0.0
	var dir := 1
	var off := 0.0
	var off_pref := 0.0
	var side := 1.0
	var route := PackedInt32Array()
	var ri := 0
	var last_leg := false
	var arrived := false
	var goal_edge := 0
	var goal_t := 0.0
	var goal_off := 0.0
	var speed := 1.2
	var hp := 40.0
	var heat := 0.5
	var phase := 0.0
	var timer := 0.0
	var idle := 0.0
	var target_b := -1
	var pos := Vector2.ZERO
	var runner := false
	var tag := 0               # groupe d'objectif auquel appartient le zombie (0 : aucun)
	# --- apparence 3D
	var yaw := 0.0             # cap du personnage (rad, 0 = face au nord / -Z)
	var look := 0.0            # graine d'apparence 0..0.979 : morphologie, vêtements, démarche, membres
	var gait := 0.0            # allure lissée : 0 à l'arrêt, ~0.3 marche, 1 course
	var lie := 0.0             # 0 debout .. 1 au sol (chute, corps dévorés, cadavres, relèvement)
	var rising := false        # corps dévoré qui se relève en zombie
	var feed := 0.0            # temps de repas restant (zombie)
	var face := Vector2.ZERO   # point regardé pendant un siège ou un repas
	var has_face := false
	var scale_v := 1.0         # variation de taille individuelle
	var corpse_civil := false  # le cadavre est celui d'un civil (sinon d'un zombie)
	# --- infectés spéciaux
	var ztype := 0             # 0 ordinaire, 1 colosse, 2 hurleur, 3 alpha
	var bulk := 1.0            # largeur du corps à l'affichage
	var armor := [1.0, 1.0, 1.0]   # part des dégâts qui passe, pour chacune des trois armes
	var door_mult := 1.0       # multiplicateur des coups portés à une porte
	var points := 0            # points de base d'élimination (0 : barème ordinaire)
	var pack := 0              # meute : 1 + indice de l'alpha suivi (0 : aucune)
	var frenzy := 0.0          # temps restant de frénésie (un hurleur a hurlé à portée)
	var scream_t := 0.0        # hurleur : délai avant le prochain hurlement
	# --- comportement de rue
	var seeker := true         # infecté qui cherche une porte à enfoncer (sinon il erre dans les rues)
	var herd := 0              # groupe errant (sorti du métro) : tous ses membres partagent la même destination
	var amb := false           # civil des rues (ambiance) : court, fuit les infectés, quitte la zone par une sortie ; ne compte pas comme sauvé
	var fear_t := 0.0          # civil des rues : délai avant de pouvoir changer de fuite
	var chase := -1            # infecté qui poursuit un civil des rues : indice du civil (-1 : aucun)
	var exit := false          # civil des rues : son but est une sortie (point d'évacuation) et non un refuge de passage
	var hid := 0               # infecté : mesures récentes de « caché derrière un immeuble » (0 à 3 ; 2 et plus : verrouillé en rouge)
	var fear := 0.0            # civil des rues : peur restante (s) ; il court plus vite tant qu'elle dure

	func reset() -> void:
		kind = 0
		mode = 0
		route = PackedInt32Array()
		ri = 0
		last_leg = false
		arrived = false
		timer = 0.0
		idle = 0.0
		target_b = -1
		phase = randf() * 6.28
		runner = false
		tag = 0
		yaw = randf() * 6.283
		look = float(randi() % 980) * 0.001
		gait = 0.0
		lie = 0.0
		rising = false
		feed = 0.0
		has_face = false
		scale_v = randf_range(0.93, 1.07)
		ztype = 0
		bulk = 1.0
		armor = [1.0, 1.0, 1.0]
		door_mult = 1.0
		points = 0
		pack = 0
		frenzy = 0.0
		scream_t = 0.0
		seeker = true
		herd = 0
		amb = false
		fear_t = 0.0
		chase = -1
		exit = false
		fear = 0.0
		hid = 0


var ctx
var graph
var pool: Array = []
var free_ids: Array = []
var mm: MultiMesh = null
var n_zombies := 0
var n_civils := 0
var n_eaten := 0
var last_spawn := Vector2.ZERO
var last_hit_z := 0           # zombies touchés par le dernier damage_area (pour la précision)
var screams := 0              # hurlements poussés depuis le début (tests)
var _frenzy_mult := 1.7       # accélération due à un hurleur / à une meute (relue de data/zombies.json)
var _pack_speed := 1.3
var decoy_pos := Vector2.ZERO    # leurre sonore : point sur la rue, rayon d'effet, temps restant
var decoy_r := 0.0
var decoy_left := 0.0
var _decoy_edge := -1
var _decoy_t := 0.0
var _acc := 0.0
var _budget := 0
var _mat: ShaderMaterial = null
var _zgrid := {}
var _buf := PackedFloat32Array()
var _zone_edges := PackedInt32Array()     # tronçons dont le milieu est dans la zone de jeu : seuls lieux d'apparition et de destination
var _zone_ready := false
var _clock := 0.0                          # temps de la foule (s), propre à la simulation
var n_amb := 0                             # civils des rues (ambiance) en vie : ils ne comptent pas dans n_civils (protégés, objectifs)
var amb_out := 0                           # civils des rues arrivés à une sortie de la zone depuis le début (essais, mesures)
var _amb_t := 0.0                          # délai avant la prochaine apparition d'un civil des rues
var _zgrid3 := {}                          # infectés en cases de 24 m (portée de la peur des civils)
var _cgrid := {}                           # civils des rues en cases de 16 m (portée de la poursuite des infectés)
var _herd_n := 0
var _herd_goal := {}                       # groupe errant -> [tronçon, t, date d'expiration] : la destination commune du moment


func setup(p_ctx) -> void:
	ctx = p_ctx
	graph = ctx.graph
	pool.clear()
	free_ids.clear()
	for i in MAX_P:
		var p := P.new()
		p.id = i
		pool.append(p)
	for i in MAX_P:
		free_ids.append(MAX_P - 1 - i)
	_zone_ready = false


func setup_view(parent: Node3D) -> void:
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = HumanMesh.new().build()
	mm.instance_count = MAX_P
	_buf.resize(MAX_P * 16)
	mm.visible_instance_count = 0
	var sz: Vector2 = ctx.city.size_m()
	mm.custom_aabb = AABB(Vector3(-sz.x, -5.0, -sz.y), Vector3(sz.x * 2.0, 20.0, sz.y * 2.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "People"
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = PERSON_SHADER
	mmi.material_override = mat
	_mat = mat
	parent.add_child(mmi)


## Atténuation atmosphérique de la chaleur des personnes (brouillard : plus forte).
func set_atmos(k: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter("atmos_k", k)


# ---------------------------------------------------------------- allocation

func _alloc() -> P:
	if free_ids.is_empty():
		return null
	var i: int = free_ids.pop_back()
	var p: P = pool[i]
	p.alive = true
	p.reset()
	return p


func _free(p: P) -> void:
	if p.alive:
		if p.ztype == ZT_ALPHA and p.kind == K_ZOMBIE:
			_release_pack(p, false)
		p.alive = false
		free_ids.append(p.id)


func alive_count() -> int:
	return MAX_P - free_ids.size()


# ---------------------------------------------------------------- création

## `r` : générateur des tirages (celui du scénario pour les vagues ; celui des effets par défaut).
func spawn_zombie(edge: int, t: float, r: RandomNumberGenerator = null) -> P:
	if n_zombies >= ZOMBIE_CAP:
		return null
	var p := _alloc()
	if p == null:
		return null
	var rr: RandomNumberGenerator = r if r != null else ctx.rng
	p.kind = K_ZOMBIE
	p.seeker = rr.randf() < ctx.rule("seek_ratio", 1.0)          # la part des infectés qui visent une porte (le reste erre dans les rues)
	p.runner = rr.randf() < ctx.rule("runner_ratio", 0.2)
	p.speed = rr.randf_range(3.0, 3.6) if p.runner else rr.randf_range(1.0, 1.6)
	p.hp = ctx.rule("zombie_hp", 40.0) * (0.75 if p.runner else 1.0)
	p.heat = rr.randf_range(0.60, 0.76)
	p.edge = edge
	p.t = t
	p.side = -1.0 if rr.randf() < 0.5 else 1.0
	p.off = p.side * rr.randf_range(0.0, maxf(graph.ew[edge] * 0.5 - 1.3, 0.5))
	p.off_pref = p.off
	p.pos = graph.pos_on_edge(edge, t, p.off)
	n_zombies += 1
	return p


## Tronçons situés dans la zone de jeu (voir ctx.in_zone) : calculés au premier besoin.
func zone_edges() -> PackedInt32Array:
	if not _zone_ready:
		_zone_edges = PackedInt32Array()
		for e in graph.ea.size():
			if ctx.in_zone(edge_mid(e)):
				_zone_edges.append(e)
		_zone_ready = true
	return _zone_edges


func edge_mid(e: int) -> Vector2:
	return (graph.node_pos[graph.ea[e]] + graph.node_pos[graph.eb[e]]) * 0.5


## Un tronçon de la zone de jeu dont le milieu est entre rmin et rmax de `center` ; -1 si le tirage n'en trouve pas.
func _random_edge_in_ring(center: Vector2, rmin: float, rmax: float) -> int:
	var zl: PackedInt32Array = zone_edges()
	if zl.is_empty():
		return -1
	for k in 120:
		var e: int = zl[ctx.wave_rng.randi_range(0, zl.size() - 1)]
		var d := edge_mid(e).distance_to(center)
		if d >= rmin and d <= rmax:
			return e
	return -1


# ---------------------------------------------------------------- infectés spéciaux

## Paramètres d'un type spécial (data/zombies.json) ; {} si le type est inconnu.
func ztype_cfg(zt: int) -> Dictionary:
	if zt <= 0 or zt >= ZT_IDS.size():
		return {}
	return ctx.zombie_types.get(ZT_IDS[zt], {})


## Fait du zombie p un infecté spécial de type zt : points de vie, vitesse, taille, blindage, chaleur.
func make_special(p: P, zt: int, r: RandomNumberGenerator) -> void:
	var cfg: Dictionary = ztype_cfg(zt)
	if cfg.is_empty():
		return
	p.ztype = zt
	p.seeker = true                      # un infecté spécial vise toujours une porte
	p.runner = false
	var sp: Array = cfg.get("speed", [1.0, 1.5])
	p.speed = r.randf_range(float(sp[0]), float(sp[1]))
	p.hp = float(cfg.get("hp", 100.0)) * ctx.rule("zombie_hp", 40.0) / 40.0
	p.scale_v = float(cfg.get("scale", 1.0)) * r.randf_range(0.97, 1.03)
	p.bulk = float(cfg.get("bulk", 1.0))
	p.armor = (cfg.get("armor", [1.0, 1.0, 1.0]) as Array).duplicate()
	p.door_mult = float(cfg.get("door", 1.0))
	p.points = int(cfg.get("points", 0))
	p.heat = float(cfg.get("heat", 0.85))
	if zt == ZT_SCREAMER:
		p.scream_t = r.randf_range(1.5, 3.5)


## Un infecté spécial sur une rue entre rmin et rmax du centre ; un alpha arrive avec sa meute. Retourne l'infecté ou null.
func spawn_special(zt: int, center: Vector2, rmin: float, rmax: float) -> P:
	var e := _random_edge_in_ring(center, rmin, rmax)
	if e < 0:
		return null
	var r: RandomNumberGenerator = ctx.wave_rng
	var t0: float = r.randf_range(0.2, 0.8)
	var p := spawn_zombie(e, t0, r)
	if p == null:
		return null
	make_special(p, zt, r)
	last_spawn = p.pos
	if zt == ZT_ALPHA:
		var pk: Array = ztype_cfg(ZT_ALPHA).get("pack", [5, 8])
		var n := r.randi_range(int(pk[0]), int(pk[1]))
		var acc := p.pos
		var got := 1
		for i in n:
			var m := spawn_zombie(e, clampf(t0 + r.randf_range(-0.05, 0.05), 0.02, 0.98), r)
			if m == null:
				break
			m.pack = p.id + 1
			acc += m.pos
			got += 1
		last_spawn = acc / float(got)
	return p


## Nombre d'infectés spéciaux vivants de ce type (0 : tous types).
func count_special(zt: int = 0) -> int:
	var n := 0
	for i in MAX_P:
		var p: P = pool[i]
		if p.alive and p.kind == K_ZOMBIE and p.ztype > 0 and (zt == 0 or p.ztype == zt):
			n += 1
	return n


## Hurlement : les infectés proches s'emballent pendant quelques secondes.
func _scream(p: P) -> void:
	var cfg: Dictionary = ztype_cfg(ZT_SCREAMER)
	p.scream_t = float(cfg.get("every_s", 7.0))
	var rad := float(cfg.get("radius_m", 170.0))
	var fr := float(cfg.get("frenzy_s", 5.0))
	for i in MAX_P:
		var q: P = pool[i]
		if q.alive and q.kind == K_ZOMBIE and not q.rising and q.pos.distance_squared_to(p.pos) <= rad * rad:
			q.frenzy = maxf(q.frenzy, fr)
	screams += 1
	if ctx.fx != null:
		ctx.fx.scream(p.pos, rad)


## La meute perd son chef : elle ne le suit plus ; si le chef est tombé (panic), elle s'immobilise un instant.
func _release_pack(alpha: P, panic: bool) -> void:
	var tag := alpha.id + 1
	var pt := float(ztype_cfg(ZT_ALPHA).get("panic_s", 4.5))
	for i in MAX_P:
		var q: P = pool[i]
		if q.alive and q.pack == tag:
			q.pack = 0
			if panic and q.kind == K_ZOMBIE and q.mode != 3 and not q.rising:
				q.mode = 0
				q.target_b = -1
				q.idle = pt + ctx.rng.randf_range(0.0, 1.5)


## Leurre sonore : pendant `duration` secondes, les infectés à moins de `radius` de `pos` qui ne sont pas à une porte
## convergent vers le point de rue le plus proche. Retourne faux s'il n'y a pas de rue à proximité.
func place_decoy(pos: Vector2, radius: float, duration: float) -> bool:
	var ne: Array = graph.nearest_edge(pos)
	if int(ne[0]) < 0:
		return false
	_decoy_edge = int(ne[0])
	_decoy_t = float(ne[1])
	decoy_pos = graph.pos_on_edge(_decoy_edge, _decoy_t, 0.0)
	decoy_r = radius
	decoy_left = duration
	return true


## Vitesse réelle d'un infecté : la frénésie (hurleur à portée) et la meute (alpha vivant) l'accélèrent.
func _eff_speed(p: P) -> float:
	var sp := p.speed
	if p.kind == K_ZOMBIE:
		if p.frenzy > 0.0:
			sp *= _frenzy_mult
		if p.pack > 0:
			sp *= _pack_speed
		if p.mode == MODE_CHASE:
			sp *= 1.3                      # il a vu sa proie : il force l'allure
	elif p.kind == K_CIVIL and p.fear > 0.0:
		sp *= 1.15                         # la peur donne des jambes
	return sp


## Fait apparaître `count` zombies, par grappes de 3 à 6, sur des rues situées entre rmin et rmax du centre.
func spawn_cluster(center: Vector2, rmin: float, rmax: float, count: int) -> int:
	var spawned := 0
	var guard := 0
	var acc := Vector2.ZERO
	while spawned < count and guard < 80:
		guard += 1
		var e := _random_edge_in_ring(center, rmin, rmax)
		if e < 0:
			continue
		var k := mini(count - spawned, ctx.wave_rng.randi_range(3, 6))
		var t0: float = ctx.wave_rng.randf_range(0.15, 0.85)
		for j in k:
			var p := spawn_zombie(e, clampf(t0 + ctx.wave_rng.randf_range(-0.07, 0.07), 0.02, 0.98), ctx.wave_rng)
			if p == null:
				if spawned > 0:
					last_spawn = acc / float(spawned)
				return spawned
			acc += p.pos
			spawned += 1
	if spawned > 0:
		last_spawn = acc / float(spawned)
	return spawned


## Point d'une rue situé entre rmin et rmax de center (milieu d'un tronçon tiré au hasard) ; Vector2.INF s'il n'y en a pas.
func pick_street_point(center: Vector2, rmin: float, rmax: float) -> Vector2:
	for attempt in 6:
		var e := _random_edge_in_ring(center, rmin, rmax)
		if e >= 0:
			return (graph.node_pos[graph.ea[e]] + graph.node_pos[graph.eb[e]]) * 0.5
	return Vector2.INF


## `count` zombies, par grappes de 3 à 6, sur les rues situées à moins de `radius` de `center`, marqués `tag`
## (groupe d'un objectif). Retourne le nombre créé ; last_spawn = leur centre.
func spawn_tagged_group(center: Vector2, radius: float, count: int, tag: int) -> int:
	var cands: Array = []
	var r := radius
	for widen in 4:
		for e in graph.ea.size():
			var mid: Vector2 = (graph.node_pos[graph.ea[e]] + graph.node_pos[graph.eb[e]]) * 0.5
			if mid.distance_to(center) <= r and ctx.in_zone(mid, 40.0):
				cands.append(e)
		if not cands.is_empty():
			break
		r *= 1.6
	if cands.is_empty():
		return 0
	var spawned := 0
	var acc := Vector2.ZERO
	var guard := 0
	while spawned < count and guard < 60:
		guard += 1
		var e: int = cands[ctx.wave_rng.randi_range(0, cands.size() - 1)]
		var k := mini(count - spawned, ctx.wave_rng.randi_range(3, 6))
		var t0: float = ctx.wave_rng.randf_range(0.15, 0.85)
		for j in k:
			var p := spawn_zombie(e, clampf(t0 + ctx.wave_rng.randf_range(-0.07, 0.07), 0.02, 0.98), ctx.wave_rng)
			if p == null:
				guard = 999
				break
			p.tag = tag
			acc += p.pos
			spawned += 1
	if spawned > 0:
		last_spawn = acc / float(spawned)
	return spawned


## Groupe de `count` infectés qui sortent d'une bouche de métro (nœud `node`) et errent ensemble dans les rues de la zone :
## ils n'attaquent pas les portes, mais poursuivent les civils qu'ils croisent. Retourne le nombre créé ; last_spawn = la bouche.
func spawn_herd(node: int, count: int) -> int:
	if node < 0 or node >= graph.adj.size() or (graph.adj[node] as Array).is_empty():
		return 0
	_herd_n += 1
	var hid := _herd_n
	var at: Vector2 = graph.node_pos[node]
	var got := 0
	for i in count:
		var e: int = (graph.adj[node] as Array)[ctx.wave_rng.randi_range(0, (graph.adj[node] as Array).size() - 1)]
		var d: float = ctx.wave_rng.randf_range(0.5, 9.0)                 # ils débouchent à quelques mètres de l'escalier
		var t0 := clampf(d / maxf(graph.elen[e], 1.0), 0.01, 0.45)
		if graph.ea[e] != node:
			t0 = 1.0 - t0
		var p := spawn_zombie(e, t0, ctx.wave_rng)
		if p == null:
			break
		p.herd = hid
		p.seeker = false
		got += 1
	if got > 0:
		last_spawn = at
	return got


## Groupe de k zombies qui arrivent par la rue sur la porte de l'immeuble b et l'assiègent.
func spawn_assault(b: int, k: int) -> int:
	var city = ctx.city
	var e: int = city.b_door_edge[b]
	var L: float = graph.elen[e]
	var side := 1.0 if ctx.wave_rng.randf() < 0.5 else -1.0
	var got := 0
	for i in k:
		var d: float = ctx.wave_rng.randf_range(12.0, 30.0)
		var t0 := clampf(city.b_door_t[b] + side * d / L, 0.02, 0.98)
		var p := spawn_zombie(e, t0, ctx.wave_rng)
		if p == null:
			break
		p.runner = false
		p.speed = ctx.wave_rng.randf_range(1.8, 2.4)
		if _route(p, e, city.b_door_t[b], city.b_door_off[b]):
			p.target_b = b
			p.mode = 1
			got += 1
		else:
			p.mode = 0
	return got


func spawn_zombie_at_door(b: int) -> bool:
	var p := spawn_zombie(ctx.city.b_door_edge[b], ctx.city.b_door_t[b])
	if p == null:
		return false
	p.off = ctx.city.b_door_off[b]
	p.off_pref = p.off
	p.pos = graph.pos_on_edge(p.edge, p.t, p.off)
	return true


func spawn_civilian_at_door(b: int) -> bool:
	var p := _alloc()
	if p == null:
		return false
	var city = ctx.city
	p.kind = K_CIVIL
	p.speed = ctx.rng.randf_range(3.6, 4.6) * (1.0 + ctx.mod("civ_speed"))
	p.hp = 20.0
	p.heat = ctx.rng.randf_range(0.93, 1.0)
	p.edge = city.b_door_edge[b]
	p.t = city.b_door_t[b]
	p.side = -1.0 if ctx.rng.randf() < 0.5 else 1.0
	p.off = city.b_door_off[b]
	p.pos = graph.pos_on_edge(p.edge, p.t, p.off)
	var best_n := -1
	var bd := INF
	for en in ctx.director.evac_list():
		var d: float = city.nodes[en].distance_squared_to(p.pos)
		if d < bd:
			bd = d
			best_n = en
	var ok := false
	if best_n >= 0:
		var goal: Array = graph.node_goal(best_n)
		ok = _route(p, goal[0], goal[1], 0.0)
	if not ok:
		_free(p)
		return false
	return true


# ---------------------------------------------------------------- déplacement

func _pick_pref(p: P) -> void:
	if p.last_leg:
		p.off_pref = p.goal_off
	else:
		var w: float = graph.ew[p.edge]
		p.off_pref = p.side * maxf(w * 0.5 - 1.3, 0.5) * ctx.rng.randf_range(0.5, 1.0)


func _route(p: P, e1: int, t1: float, goff: float) -> bool:
	var pl: Dictionary = graph.plan(p.edge, p.t, e1, t1)
	if not pl["ok"]:
		return false
	p.dir = pl["dir"]
	p.route = pl["nodes"]
	p.ri = 0
	p.goal_edge = e1
	p.goal_t = t1
	p.goal_off = goff
	p.last_leg = p.route.is_empty()
	p.arrived = false
	_pick_pref(p)
	return true


func _advance(p: P, dist: float) -> void:
	var g = graph
	var guard := 0
	while dist > 0.0001 and not p.arrived and guard < 8:
		guard += 1
		var L: float = g.elen[p.edge]
		if p.last_leg:
			var remain: float = (p.goal_t - p.t) * p.dir * L
			if remain <= dist:
				p.t = p.goal_t
				p.arrived = true
			else:
				p.t += p.dir * dist / L
			return
		var end_t := 1.0 if p.dir > 0 else 0.0
		var remain2: float = (end_t - p.t) * p.dir * L
		if remain2 > dist:
			p.t += p.dir * dist / L
			return
		dist -= maxf(remain2, 0.0)
		p.t = end_t
		var node: int = g.eb[p.edge] if p.dir > 0 else g.ea[p.edge]
		p.ri += 1
		if p.ri < p.route.size():
			var e: int = g.edge_between(node, p.route[p.ri])
			if e < 0:
				p.arrived = true
				return
			p.edge = e
		else:
			p.edge = p.goal_edge
			p.last_leg = true
		p.dir = 1 if g.ea[p.edge] == node else -1
		p.t = 0.0 if p.dir > 0 else 1.0


func _move(p: P, dt: float) -> void:
	var before := p.edge
	var old := p.pos
	_advance(p, _eff_speed(p) * dt)
	if p.edge != before:
		_pick_pref(p)
	# le changement de voie reste proportionné à l'allure : pas de « marche en crabe »
	p.off = move_toward(p.off, p.off_pref, clampf(p.speed * 0.6, 0.6, 2.6) * dt)
	p.pos = graph.pos_on_edge(p.edge, p.t, p.off)
	var d := p.pos - old
	if d.length_squared() > 1e-7:
		p.yaw = lerp_angle(p.yaw, atan2(-d.x, -d.y), minf(1.0, dt * 9.0))
	p.gait = move_toward(p.gait, _gait_for(p), dt * 3.0)
	_walk_phase(p, dt)


## Allure visée d'après la vitesse : ~0,17 zombie lent, ~0,4 zombie rapide, 0,8-1 course.
func _gait_for(p: P) -> float:
	return clampf((_eff_speed(p) - 0.5) / 3.0, 0.0, 1.0)


## Fait avancer le cycle de pas au rythme du déplacement réel (pas de glissade des pieds).
func _walk_phase(p: P, dt: float) -> void:
	var v: float = _eff_speed(p) * clampf(p.gait / maxf(_gait_for(p), 0.05), 0.0, 1.0)
	var run_f := smoothstep(0.35, 0.95, p.gait)
	var stride: float = lerpf(1.25, 2.6, run_f) * VIS_SCALE * p.scale_v
	p.phase += dt * TAU * v / stride


func _turn_to(p: P, target: Vector2, dt: float) -> void:
	var d := target - p.pos
	if d.length_squared() > 0.01:
		p.yaw = lerp_angle(p.yaw, atan2(-d.x, -d.y), minf(1.0, dt * 6.0))


func _assign(p: P) -> void:
	if p.pack > 0:
		var a: P = pool[p.pack - 1]
		if a.alive and a.kind == K_ZOMBIE and a.ztype == ZT_ALPHA:
			if a.target_b >= 0 and ctx.buildings.targetable(a.target_b):
				var ab: int = a.target_b
				if _route(p, ctx.city.b_door_edge[ab], ctx.city.b_door_t[ab], ctx.city.b_door_off[ab]):
					p.target_b = ab
					p.mode = 1
					return
			p.idle = 0.4                  # le chef n'a pas encore choisi sa cible : on le suit des yeux
			return
		p.pack = 0
	if p.seeker or p.tag != 0:                  # les groupes d'objectif visent toujours les immeubles ; les autres à leur gré
		var b: int = ctx.buildings.pick_target(p.pos)
		if b >= 0:
			if _route(p, ctx.city.b_door_edge[b], ctx.city.b_door_t[b], ctx.city.b_door_off[b]):
				p.target_b = b
				p.mode = 1
				return
	_assign_wander(p)


func _assign_wander(p: P) -> void:
	var zl: PackedInt32Array = zone_edges()
	var best_e := -1
	var best_t := 0.0
	var best_d := INF
	if p.herd > 0:
		# un groupe errant avance ensemble : tant que sa destination commune est valable, tous ses membres la rejoignent
		var hg = _herd_goal.get(p.herd)
		if hg != null and _clock < float(hg[2]):
			best_e = int(hg[0])
			best_t = float(hg[1]) + ctx.rng.randf_range(-0.03, 0.03)
		elif not zl.is_empty():
			for k in 10:
				var e2: int = zl[ctx.rng.randi_range(0, zl.size() - 1)]
				var d2 := edge_mid(e2).distance_to(p.pos)
				if d2 > 140.0 and d2 < best_d:
					best_d = d2
					best_e = e2
					best_t = ctx.rng.randf()
			if best_e >= 0:
				_herd_goal[p.herd] = [best_e, best_t, _clock + 40.0]
	elif not zl.is_empty():
		for k in 6:
			var e: int = zl[ctx.rng.randi_range(0, zl.size() - 1)]
			var d := edge_mid(e).distance_to(p.pos)
			if d > 60.0 and d < best_d:
				best_d = d
				best_e = e
				best_t = ctx.rng.randf()
	if best_e >= 0 and _route(p, best_e, clampf(best_t, 0.02, 0.98), 0.0):
		p.mode = 2
		p.target_b = -1
	else:
		p.mode = 0
		p.idle = 2.0


# ---------------------------------------------------------------- simulation

func step(dt: float) -> void:
	_budget = 10
	_clock += dt
	if decoy_left > 0.0:
		decoy_left = maxf(decoy_left - dt, 0.0)
	_acc += dt
	if _acc >= TICK:
		_acc -= TICK
		_tick()
	var nz := 0
	var nc := 0
	var na := 0
	var ne := 0
	for i in MAX_P:
		var p: P = pool[i]
		if not p.alive:
			continue
		match p.kind:
			K_ZOMBIE:
				nz += 1
				_step_zombie(p, dt)
			K_CIVIL:
				if p.amb:
					na += 1
				else:
					nc += 1
				_step_civil(p, dt)
			K_EATEN:
				ne += 1
				_step_eaten(p, dt)
			K_DEAD:
				_step_dead(p, dt)
	n_zombies = nz
	n_civils = nc
	n_amb = na
	n_eaten = ne


func _step_zombie(p: P, dt: float) -> void:
	if p.frenzy > 0.0:
		p.frenzy -= dt
	if p.ztype == ZT_SCREAMER and not p.rising:
		p.scream_t -= dt
		if p.scream_t <= 0.0:
			_scream(p)
	if p.rising:
		# le corps dévoré se relève : debout, il redevient un zombie comme les autres
		p.lie = maxf(p.lie - dt / RISE_TIME, 0.0)
		if p.lie <= 0.0:
			p.rising = false
			p.idle = 0.5
		return
	if p.mode == 3:
		# siège : le zombie martèle la porte jusqu'à ce qu'elle cède
		if not ctx.buildings.targetable(p.target_b):
			p.mode = 0
			p.target_b = -1
			return
		p.phase += dt * 7.0
		p.gait = 0.0
		if p.off != p.off_pref:
			p.off = move_toward(p.off, p.off_pref, 1.2 * dt)
			p.pos = graph.pos_on_edge(p.edge, p.t, p.off)
		_turn_to(p, p.face, dt)
		ctx.buildings.pound(p.target_b, dt * p.door_mult)
		if ctx.buildings.is_breached(p.target_b):
			_enter_building(p)
		return
	if p.idle > 0.0:
		p.idle -= dt
		p.gait = move_toward(p.gait, 0.0, dt * 3.0)
		if p.feed > 0.0:
			# repas : penché sur sa proie, secoué de saccades
			p.feed -= dt
			p.phase += dt * 2.0
			_turn_to(p, p.face, dt)
		return
	if p.mode == 0:
		p.gait = move_toward(p.gait, 0.0, dt * 3.0)
		if _budget > 0:
			_budget -= 1
			_assign(p)
		return
	if p.mode == MODE_DECOY:
		if decoy_left <= 0.0:
			p.mode = 0
			p.target_b = -1
			return
		if p.arrived:
			p.gait = move_toward(p.gait, 0.0, dt * 3.0)       # arrivé au leurre : il piétine sur place
			return
	if p.mode == MODE_CHASE:
		var prey: P = pool[p.chase] if p.chase >= 0 else null
		if prey == null or not prey.alive or prey.kind != K_CIVIL or p.timer <= 0.0:
			p.mode = 0                                         # la proie est morte, sortie ou trop loin : il reprend sa route
			p.chase = -1
			return
	_move(p, dt)
	if p.arrived and p.mode != MODE_DECOY:
		if p.mode == 1 and ctx.buildings.targetable(p.target_b):
			if ctx.buildings.is_breached(p.target_b):
				_enter_building(p)
			else:
				p.mode = 3
				p.face = Vector2(ctx.city.b_cx[p.target_b], ctx.city.b_cz[p.target_b])
				p.has_face = true
		else:
			p.mode = 0
			p.target_b = -1


## Le zombie entre dans l'immeuble qu'il assiégeait : il disparaît de la rue et passe dans le décompte de l'immeuble.
func _enter_building(p: P) -> void:
	ctx.buildings.enter(p.target_b)
	if p.tag != 0 and ctx.objectives != null:
		ctx.objectives.on_entered(p.tag)
	_free(p)


func _step_civil(p: P, dt: float) -> void:
	if p.fear > 0.0:
		p.fear -= dt
	_move(p, dt)
	if p.arrived:
		if not p.amb:
			ctx.director.civilian_saved(1)
			_free(p)
		elif p.exit:
			amb_out += 1
			_free(p)                       # il a rejoint la sortie : il quitte la zone sans bruit (ni sauvé, ni perdu)
		elif p.fear > 0.0:
			pass                           # cerné au bout d'un tronçon : il reste tapi tant qu'un infecté rôde à moins de la portée de sa peur
		elif not _amb_pick_goal(p, null):
			_free(p)                       # nulle part où aller : il disparaît


func _step_eaten(p: P, dt: float) -> void:
	p.timer -= dt
	p.lie = minf(p.lie + dt / FALL_TIME, 1.0)
	p.heat = maxf(p.heat - dt * 0.04, 0.55)
	if p.timer <= 0.0:
		p.kind = K_ZOMBIE
		p.mode = 0
		p.seeker = ctx.rng.randf() < ctx.rule("seek_ratio", 1.0)
		p.hp = 28.0
		p.heat = ctx.rng.randf_range(0.60, 0.76)
		p.speed = ctx.rng.randf_range(1.0, 1.6)
		p.target_b = -1
		p.idle = 0.8
		p.rising = true
		p.lie = 1.0
		p.gait = 0.0
		p.feed = 0.0


func _step_dead(p: P, dt: float) -> void:
	p.timer -= dt
	p.lie = minf(p.lie + dt / FALL_TIME, 1.0)
	p.heat = maxf(p.heat - dt * 0.035, 0.14)
	if p.timer <= 0.0:
		_free(p)


func _kill(p: P, was_civil: bool) -> void:
	p.kind = K_DEAD
	p.timer = 28.0
	p.heat = 0.9 if was_civil else 0.72
	p.corpse_civil = was_civil
	p.lie = 0.0
	p.rising = false
	p.feed = 0.0


func _tick() -> void:
	_zgrid.clear()
	_frenzy_mult = float(ztype_cfg(ZT_SCREAMER).get("speed_mult", 1.7))
	_pack_speed = float(ztype_cfg(ZT_ALPHA).get("pack_speed", 1.3))
	var dbudget := 24          # au plus 24 infectés détournés par tick : le bruit se propage, il ne téléporte pas
	for i in MAX_P:
		var p: P = pool[i]
		if not p.alive or p.kind != K_ZOMBIE:
			continue
		var k := _gk(int(floor(p.pos.x / 8.0)), int(floor(p.pos.y / 8.0)))
		if not _zgrid.has(k):
			_zgrid[k] = []
		_zgrid[k].append(p)
		if (p.mode == 1 or p.mode == 3) and not ctx.buildings.targetable(p.target_b):
			p.mode = 0
		if decoy_left > 0.0 and dbudget > 0 and p.mode != 3 and p.mode != MODE_DECOY and not p.rising \
				and p.idle <= 0.0 and p.pos.distance_squared_to(decoy_pos) <= decoy_r * decoy_r:
			dbudget -= 1
			if _route(p, _decoy_edge, _decoy_t, 0.0):
				p.mode = MODE_DECOY
				p.target_b = -1
	for i in MAX_P:
		var c: P = pool[i]
		if not c.alive or c.kind != K_CIVIL:
			continue
		var z := _zombie_near(c)
		if z != null:
			c.kind = K_EATEN
			c.timer = ctx.rule("turn_delay_s", 6.0)
			c.heat = 0.9
			c.lie = 0.0
			c.gait = 0.0
			z.idle = FEED_TIME
			if z.mode != 3:
				z.feed = FEED_TIME
				z.face = c.pos
				z.has_face = true
			ctx.director.civilian_lost(1, "street", c.pos)
	_tick_street()


# ---------------------------------------------------------------- civils des rues : peur, fuite, poursuite

## Civils des rues (ambiance) : la population est maintenue à `amb_target` (règle de la mission ; 0 : aucun). Ils sortent des immeubles,
## courent vers un point d'évacuation de la zone et détalent devant les infectés ; les infectés errants qui les voient les poursuivent.
## Appelé à chaque pas de calcul de la foule (TICK).
func _tick_street() -> void:
	var fear_r: float = ctx.rule("amb_fear_m", 45.0)
	var chase_r: float = ctx.rule("amb_chase_m", 28.0)
	var target := int(ctx.rule("amb_target", 0.0))
	_cgrid.clear()
	_zgrid3.clear()
	var amb_any := false
	for i in MAX_P:
		var q: P = pool[i]
		if not q.alive:
			continue
		if q.kind == K_CIVIL and q.amb:
			amb_any = true
			var kc := _gk(int(floor(q.pos.x / 16.0)), int(floor(q.pos.y / 16.0)))
			if _cgrid.has(kc):
				_cgrid[kc].append(q)
			else:
				_cgrid[kc] = [q]
		elif q.kind == K_ZOMBIE and not q.rising:
			var kz := _gk(int(floor(q.pos.x / 24.0)), int(floor(q.pos.y / 24.0)))
			if _zgrid3.has(kz):
				_zgrid3[kz].append(q)
			else:
				_zgrid3[kz] = [q]
	var routes := 14                        # au plus 14 calculs d'itinéraire par pas : la foule ne gèle jamais l'image
	if amb_any:
		# 1. les infectés qui ne sont ni à une porte, ni à table, ni en meute, repèrent un civil proche et le poursuivent
		for i in MAX_P:
			var z: P = pool[i]
			if not z.alive or z.kind != K_ZOMBIE or z.rising or z.mode == 3 or z.mode == MODE_DECOY or z.pack > 0 or z.idle > 0.0:
				continue
			if z.mode == MODE_CHASE:
				z.timer -= TICK
				var prey: P = pool[z.chase] if z.chase >= 0 else null
				if prey != null and prey.alive and prey.kind == K_CIVIL and z.timer > 0.0 and routes > 0 \
						and prey.pos.distance_squared_to(z.pos) <= chase_r * chase_r * 4.0:
					routes -= 1
					_route(z, prey.edge, prey.t, 0.0)      # la proie bouge : on recalcule le trajet
				else:
					z.mode = 0
					z.chase = -1
				continue
			var reach := chase_r if (z.mode == 0 or z.mode == 2) else 14.0     # un infecté qui fonce vers une porte ne s'écarte que pour une proie à côté
			var cx := int(floor(z.pos.x / 16.0))
			var cz := int(floor(z.pos.y / 16.0))
			var best: P = null
			var bd := reach * reach
			for ix in range(cx - 1, cx + 2):
				for iz in range(cz - 1, cz + 2):
					var lst = _cgrid.get(_gk(ix, iz))
					if lst == null:
						continue
					for c in lst:
						var d2: float = z.pos.distance_squared_to(c.pos)
						if d2 < bd:
							bd = d2
							best = c
			if best != null and routes > 0:
				routes -= 1
				if _route(z, best.edge, best.t, 0.0):
					z.mode = MODE_CHASE
					z.chase = best.id
					z.timer = 12.0
					z.target_b = -1
		# 2. les civils voient les infectés à portée et fuient ; ils vont vers une sortie en s'écartant de la menace
		for i in MAX_P:
			var c2: P = pool[i]
			if not c2.alive or c2.kind != K_CIVIL or not c2.amb:
				continue
			c2.fear_t -= TICK
			var cx2 := int(floor(c2.pos.x / 24.0))
			var cz2 := int(floor(c2.pos.y / 24.0))
			var th: P = null
			var td := fear_r * fear_r
			for ix in range(cx2 - 2, cx2 + 3):
				for iz in range(cz2 - 2, cz2 + 3):
					var lz = _zgrid3.get(_gk(ix, iz))
					if lz == null:
						continue
					for z2 in lz:
						var d3: float = z2.pos.distance_squared_to(c2.pos)
						if d3 < td:
							td = d3
							th = z2
			if th == null:
				continue
			c2.fear = 3.0
			if c2.fear_t > 0.0 or routes <= 0:
				continue
			# faut-il changer de cap ? oui si la menace est près, ou si l'on court vers elle
			var heading: Vector2 = graph.edir[c2.edge] * float(c2.dir)
			var to_th: Vector2 = (th.pos - c2.pos).normalized()
			if sqrt(td) <= 18.0 or heading.dot(to_th) > 0.2:
				routes -= 1
				c2.fear_t = 1.4 if _amb_pick_goal(c2, th) else 0.6
	# 3. la population des rues se renouvelle : un civil sort d'un immeuble à intervalle régulier tant que la cible n'est pas atteinte
	if target > 0:
		_amb_t -= TICK
		if n_amb < target and _amb_t <= 0.0:
			_amb_spawn_one()
			_amb_t = ctx.rule("amb_spawn_s", 1.6)


## Un infecté (non encore relevé) à moins de r mètres de pos ? (cases de 24 m construites au dernier pas de calcul)
func _zombie_within(pos: Vector2, r: float) -> bool:
	var cx := int(floor(pos.x / 24.0))
	var cz := int(floor(pos.y / 24.0))
	var n := int(ceil(r / 24.0))
	for ix in range(cx - n, cx + n + 1):
		for iz in range(cz - n, cz + n + 1):
			var lst = _zgrid3.get(_gk(ix, iz))
			if lst == null:
				continue
			for z in lst:
				if z.pos.distance_squared_to(pos) <= r * r:
					return true
	return false


## Fait sortir un civil des rues par la porte d'un immeuble de la zone (intact, habité, sans infecté à moins de 60 m). Vrai si réussi.
func _amb_spawn_one() -> bool:
	var nb: int = ctx.buildings.n
	if nb <= 0:
		return false
	for tries in 14:
		var b: int = ctx.rng.randi_range(0, nb - 1)
		if not ctx.buildings.targetable(b):
			continue
		var dp := Vector2(ctx.city.b_cx[b], ctx.city.b_cz[b])
		if not ctx.in_zone(dp, -30.0) or _zombie_within(dp, 60.0):
			continue
		return spawn_ambient_at_door(b)
	return false


## Remplit d'un coup la rue de `n` civils (au début de la partie : les rues ne sont pas vides à l'instant zéro).
func fill_ambient(n: int) -> int:
	var got := 0
	for i in n:
		if _amb_spawn_one():
			got += 1
	return got


func spawn_ambient_at_door(b: int) -> bool:
	var p := _alloc()
	if p == null:
		return false
	var city = ctx.city
	p.kind = K_CIVIL
	p.amb = true
	p.speed = ctx.rng.randf_range(3.4, 4.4) * (1.0 + ctx.mod("civ_speed"))
	p.hp = 20.0
	p.heat = ctx.rng.randf_range(0.93, 1.0)
	p.edge = city.b_door_edge[b]
	p.t = city.b_door_t[b]
	p.side = -1.0 if ctx.rng.randf() < 0.5 else 1.0
	p.off = city.b_door_off[b]
	p.pos = graph.pos_on_edge(p.edge, p.t, p.off)
	if not _amb_pick_goal(p, null):
		_free(p)
		return false
	return true


## Choisit le but d'un civil des rues et lance sa course. Sans menace : le point d'évacuation de la zone le plus proche. Avec une menace
## (infecté `th`) : un but qui l'éloigne de l'infecté (au moins 25 m de plus qu'aujourd'hui) et dont le premier pas ne va pas vers lui,
## de préférence une sortie. Retourne faux si aucun but ne convient (le civil garde alors son trajet).
func _amb_pick_goal(p: P, th: P) -> bool:
	var cands: Array = []                    # [tronçon, t, point, est une sortie]
	for en in ctx.director.evac_list():
		var g: Array = graph.node_goal(en)
		cands.append([int(g[0]), float(g[1]), graph.node_pos[en], true])
	if th != null:
		var zl: PackedInt32Array = zone_edges()
		if not zl.is_empty():
			for k in 4:
				var e: int = zl[ctx.rng.randi_range(0, zl.size() - 1)]
				cands.append([e, ctx.rng.randf(), edge_mid(e), false])
	var best_i := -1
	var best_s := -INF
	var tdist := th.pos.distance_to(p.pos) if th != null else 0.0
	for i in cands.size():
		var gp: Vector2 = cands[i][2]
		var dist := p.pos.distance_to(gp)
		var score := -dist * 0.5
		if th != null:
			if dist < 50.0 and not bool(cands[i][3]):
				continue
			var away := th.pos.distance_to(gp) - tdist
			if away < 25.0:
				continue
			var pl: Dictionary = graph.plan(p.edge, p.t, int(cands[i][0]), float(cands[i][1]))
			if not pl["ok"]:
				continue
			var step_dir: Vector2 = graph.edir[p.edge] * float(pl["dir"])
			if tdist < 35.0 and step_dir.dot((th.pos - p.pos).normalized()) > 0.35:
				continue                                 # le premier pas va vers l'infecté : mauvais choix
			score += away * 0.6 + (40.0 if bool(cands[i][3]) else 0.0)
		elif dist < 30.0 and not bool(cands[i][3]):
			continue
		if score > best_s:
			best_s = score
			best_i = i
	if best_i < 0:
		if th == null:
			return false
		# cerné : aucune destination ne l'éloigne de l'infecté (impasse, infecté entre lui et le reste de la ville). Il file au bout
		# du tronçon, du côté opposé, et s'y tapit (voir _step_civil) ; si même ce bout ne l'éloigne pas, il garde son trajet.
		var pa: Vector2 = graph.node_pos[graph.ea[p.edge]]
		var pb: Vector2 = graph.node_pos[graph.eb[p.edge]]
		var t_end := 0.98 if pb.distance_squared_to(th.pos) > pa.distance_squared_to(th.pos) else 0.02
		if graph.pos_on_edge(p.edge, t_end, 0.0).distance_to(th.pos) <= tdist + 4.0:
			return false
		if not _route(p, p.edge, t_end, 0.0):
			return false
		p.exit = false
		return true
	if not _route(p, int(cands[best_i][0]), float(cands[best_i][1]), 0.0):
		return false
	p.exit = bool(cands[best_i][3])
	return true


func _gk(ix: int, iz: int) -> int:
	return (ix + 4096) * 8192 + (iz + 4096)


func _zombie_near(c: P) -> P:
	var cx := int(floor(c.pos.x / 8.0))
	var cz := int(floor(c.pos.y / 8.0))
	for ix in range(cx - 1, cx + 2):
		for iz in range(cz - 1, cz + 2):
			var lst = _zgrid.get(_gk(ix, iz))
			if lst == null:
				continue
			for z in lst:
				if z.idle <= 0.0 and z.pos.distance_squared_to(c.pos) < 6.25:
					return z
	return null


# ---------------------------------------------------------------- dégâts et requêtes

## Dégâts de zone sur les personnes. Retourne (zombies tués, civils tués).
## `w` : arme de l'impact (0 à 2) ; les infectés blindés n'encaissent qu'une part des dégâts selon l'arme. -1 : sans blindage.
func damage_area(x: float, z: float, r: float, dmg: float, falloff: float, w: int = -1) -> Vector2i:
	var zk := 0
	var ck := 0
	var hz := 0
	var r2 := r * r
	for i in MAX_P:
		var p: P = pool[i]
		if not p.alive or p.kind > K_CIVIL:
			continue
		var dx := p.pos.x - x
		var dz := p.pos.y - z
		var d2 := dx * dx + dz * dz
		if d2 > r2:
			continue
		var eff := dmg * (1.0 - falloff * sqrt(d2) / r)
		if p.ztype != 0 and w >= 0 and w < p.armor.size():
			eff *= float(p.armor[w])
		p.hp -= eff
		if p.kind == K_ZOMBIE:
			hz += 1
		if p.hp <= 0.0:
			if p.kind == K_ZOMBIE:
				zk += 1
				ctx.director.zombie_killed(1, p.runner, p.points, p.ztype)
				if p.ztype == ZT_ALPHA:
					_release_pack(p, true)
				_kill(p, false)
			else:
				ck += 1
				ctx.director.civilian_lost(1, "shot", p.pos)
				_kill(p, true)
	last_hit_z = hz
	return Vector2i(zk, ck)


func nearest_zombie(pos: Vector2) -> P:
	var best: P = null
	var bd := INF
	for i in MAX_P:
		var p: P = pool[i]
		if p.alive and p.kind == K_ZOMBIE:
			var d := p.pos.distance_squared_to(pos)
			if d < bd:
				bd = d
				best = p
	return best


## Civils en danger dans la rue : l'infecté qui a le plus de civils (vivants, en fuite) à moins de 16 m, le plus proche d'eux à égalité.
## {} si aucun infecté n'est à moins de 16 m d'un civil ; sinon {"pos": position de l'infecté, "dist": distance au civil le plus proche (m),
## "civ": nombre de civils à moins de 16 m}. Calcul à la demande (priorité du moment, quatre fois par seconde au plus) : civils rangés en
## cases de 16 m, puis chaque infecté ne regarde que les neuf cases voisines.
func street_threat() -> Dictionary:
	var cg := {}
	for i in MAX_P:
		var c: P = pool[i]
		if c.alive and c.kind == K_CIVIL:
			var k := _gk(int(floor(c.pos.x / 16.0)), int(floor(c.pos.y / 16.0)))
			if cg.has(k):
				cg[k].append(c)
			else:
				cg[k] = [c]
	if cg.is_empty():
		return {}
	var best := {}
	var best_n := 0
	var best_d := INF
	for i in MAX_P:
		var z: P = pool[i]
		if not z.alive or z.kind != K_ZOMBIE or z.rising:
			continue
		var cx := int(floor(z.pos.x / 16.0))
		var cz := int(floor(z.pos.y / 16.0))
		var n := 0
		var dmin := INF
		for ix in range(cx - 1, cx + 2):
			for iz in range(cz - 1, cz + 2):
				var lst = cg.get(_gk(ix, iz))
				if lst == null:
					continue
				for c in lst:
					var d: float = z.pos.distance_to(c.pos)
					if d <= 16.0:
						n += 1
						dmin = minf(dmin, d)
		if n > 0 and (n > best_n or (n == best_n and dmin < best_d)):
			best_n = n
			best_d = dmin
			best = {"pos": z.pos, "dist": dmin, "civ": n}
	return best


## Zombies et civils proches d'un point (pour les tests et le pilote automatique).
func count_near(pos: Vector2, r: float, kind: int) -> int:
	var c := 0
	for i in MAX_P:
		var p: P = pool[i]
		if p.alive and p.kind == kind and p.pos.distance_to(pos) <= r:
			c += 1
	return c


# ---------------------------------------------------------------- affichage

## Écrit d'un coup le tampon du MultiMesh : 12 flottants de transformation (3 lignes de 4, origine
## en dernière colonne) puis 4 de données d'instance lues par thermal_human.gdshader :
##   x = chaleur, y = type + graine d'apparence, z = phase du pas, w = allure ou degré de chute.
## Types : 0 zombie, 1 civil, 2 civil dévoré, 3 cadavre de civil, 4 cadavre de zombie.
func write_view() -> void:
	if mm == null:
		return
	var b := _buf
	var o := 0
	var k := 0
	for i in MAX_P:
		var p: P = pool[i]
		if not p.alive:
			continue
		var s: float = VIS_SCALE * p.scale_v
		var sb: float = s * p.bulk
		var c: float = cos(p.yaw) * sb
		var sn: float = sin(p.yaw) * sb
		var kd := float(p.kind)
		var w := p.gait
		match p.kind:
			K_ZOMBIE:
				if p.rising:
					w = G_RISE + p.lie
				elif p.mode == 3:
					w = G_POUND
				elif p.feed > 0.0:
					w = G_FEED
			K_DEAD:
				w = p.lie
				if not p.corpse_civil:
					kd = 4.0
			K_EATEN:
				w = p.lie
		b[o] = c
		b[o + 1] = 0.0
		b[o + 2] = sn
		b[o + 3] = p.pos.x
		b[o + 4] = 0.0
		b[o + 5] = s
		b[o + 6] = 0.0
		b[o + 7] = 0.02
		b[o + 8] = -sn
		b[o + 9] = 0.0
		b[o + 10] = c
		b[o + 11] = p.pos.y
		b[o + 12] = p.heat
		b[o + 13] = kd + p.look
		b[o + 14] = p.phase
		b[o + 15] = w
		o += 16
		k += 1
	_buf = b
	mm.buffer = b
	mm.visible_instance_count = k
