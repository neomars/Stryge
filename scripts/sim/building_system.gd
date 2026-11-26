extends RefCounted
## État et simulation des immeubles : habitants, infestation, dégâts, effondrement, tracé de rayon.
## Les civils restés dans un immeuble ne sont qu'un compteur (occ) ; seuls ceux qui sortent
## deviennent des entités de la foule.

const CELL := 32.0       # grille des emprises (tracé de rayon, dégâts de zone)
const TCELL := 128.0     # grille des centres (choix de cible par les zombies)
const ST_OK := 0
const ST_COLLAPSING := 1
const ST_RUINS := 2

## Plafond du coefficient de hauteur des points de vie d'un immeuble (100 PV jusqu'à 22 m, puis proportionnel à la hauteur).
const HP_TALL_MAX := 2.0
var ctx
var city
var n := 0
var hp := PackedFloat32Array()
var occ := PackedInt32Array()          # civils vivants à l'intérieur
var occ_max := PackedInt32Array()
var zin := PackedInt32Array()          # zombies à l'intérieur
var turning := PackedInt32Array()      # civils dévorés qui vont se relever
var status := PackedByteArray()
var collapse := PackedFloat32Array()
var fire := PackedFloat32Array()
var eat_t := PackedFloat32Array()
var flee_t := PackedFloat32Array()
var turn_t := PackedFloat32Array()
var burst_t := PackedFloat32Array()
var siege := PackedFloat32Array()      # « zombie-secondes » passées à marteler la porte
var door_hp := PackedFloat32Array()    # résistance de la porte (même unité)
var door_roll := PackedFloat32Array()  # tirage (0..1) qui fixe la résistance de la porte dans l'intervalle de la mission
var idle_t := PackedFloat32Array()
var announced := PackedByteArray()
var advised := PackedByteArray()       # conseils déjà donnés à la radio pour cet immeuble (bit 1 : raser, bit 2 : porte attaquée)
var lost_latch := PackedByteArray()    # 1 : l'immeuble a atteint le seuil « perdu » et le reste tant qu'il contient des infectés (voir advice)
var view = null                        # CityRenderer (set_state), null en test
var h_max := 60.0
var _grid := {}
var _tgrid := {}
var _active := {}


static func _key(ix: int, iz: int) -> int:
	return (ix + 4096) * 8192 + (iz + 4096)


func setup(p_ctx, p_city) -> void:
	ctx = p_ctx
	city = p_city
	n = city.building_count()
	hp.resize(n)
	occ.resize(n)
	occ_max.resize(n)
	zin.resize(n)
	turning.resize(n)
	status.resize(n)
	collapse.resize(n)
	fire.resize(n)
	eat_t.resize(n)
	flee_t.resize(n)
	turn_t.resize(n)
	burst_t.resize(n)
	siege.resize(n)
	door_hp.resize(n)
	door_roll.resize(n)
	idle_t.resize(n)
	announced.resize(n)
	advised.resize(n)
	lost_latch.resize(n)
	h_max = 10.0
	for i in n:
		hp[i] = 100.0 * clampf(city.b_h[i] / 22.0, 1.0, HP_TALL_MAX)     # une tour tient au plus deux obus de 105 mm
		occ[i] = city.b_occ[i]
		occ_max[i] = maxi(city.b_occ[i], 1)
		door_roll[i] = ctx.rng.randf()
		h_max = maxf(h_max, city.b_h[i])
		_insert(i)
	reroll_doors()


## Recalcule la résistance des portes depuis les règles de la mission (la difficulté peut les avoir changées avant le départ).
## Un grand immeuble (tribune, tour) a plusieurs entrées, un hall blindé, des rideaux : au-delà de `door_big_free` habitants
## (40 par défaut), la porte résiste plus longtemps, d'un `door_big_div`-ième (100 par défaut) de plus par habitant en trop.
func reroll_doors() -> void:
	var lo: float = ctx.rule("door_hp_min", 70.0)
	var hi: float = ctx.rule("door_hp_max", 130.0)
	var mod_f: float = 1.0 + ctx.mod("door_hp")
	var free: float = ctx.rule("door_big_free", 40.0)
	var div: float = maxf(ctx.rule("door_big_div", 100.0), 1.0)
	for i in n:
		var big: float = 1.0 + maxf(float(occ_max[i]) - free, 0.0) / div
		door_hp[i] = (lo + (hi - lo) * door_roll[i]) * mod_f * big


func _insert(i: int) -> void:
	var yaw: float = city.b_yaw[i]
	var c := absf(cos(yaw))
	var s := absf(sin(yaw))
	var hw: float = city.b_w[i] * 0.5
	var hd: float = city.b_d[i] * 0.5
	var hx := c * hw + s * hd
	var hz := s * hw + c * hd
	var cx: float = city.b_cx[i]
	var cz: float = city.b_cz[i]
	for ix in range(int(floor((cx - hx) / CELL)), int(floor((cx + hx) / CELL)) + 1):
		for iz in range(int(floor((cz - hz) / CELL)), int(floor((cz + hz) / CELL)) + 1):
			var k := _key(ix, iz)
			if not _grid.has(k):
				_grid[k] = []
			_grid[k].append(i)
	var tk := _key(int(floor(cx / TCELL)), int(floor(cz / TCELL)))
	if not _tgrid.has(tk):
		_tgrid[tk] = []
	_tgrid[tk].append(i)


# ---------------------------------------------------------------- géométrie

func height_of(b: int) -> float:
	return city.b_h[b] * (1.0 - 0.93 * collapse[b])


func _inside(b: int, x: float, z: float) -> bool:
	var dx: float = x - city.b_cx[b]
	var dz: float = z - city.b_cz[b]
	var yaw: float = city.b_yaw[b]
	var c := cos(yaw)
	var s := sin(yaw)
	var lx: float = dx * c - dz * s
	var lz: float = dx * s + dz * c
	return absf(lx) <= city.b_w[b] * 0.5 and absf(lz) <= city.b_d[b] * 0.5


func building_at(x: float, z: float) -> int:
	var lst = _grid.get(_key(int(floor(x / CELL)), int(floor(z / CELL))))
	if lst == null:
		return -1
	for b in lst:
		if _inside(b, x, z):
			return b
	return -1


## Distance 2D du point à l'emprise (0 si dedans).
func dist_to(b: int, x: float, z: float) -> float:
	var dx: float = x - city.b_cx[b]
	var dz: float = z - city.b_cz[b]
	var yaw: float = city.b_yaw[b]
	var c := cos(yaw)
	var s := sin(yaw)
	var lx: float = dx * c - dz * s
	var lz: float = dx * s + dz * c
	var ex := maxf(absf(lx) - city.b_w[b] * 0.5, 0.0)
	var ez := maxf(absf(lz) - city.b_d[b] * 0.5, 0.0)
	return sqrt(ex * ex + ez * ez)


func near(x: float, z: float, r: float) -> Array:
	var out: Array = []
	var seen := {}
	for ix in range(int(floor((x - r) / CELL)), int(floor((x + r) / CELL)) + 1):
		for iz in range(int(floor((z - r) / CELL)), int(floor((z + r) / CELL)) + 1):
			var lst = _grid.get(_key(ix, iz))
			if lst == null:
				continue
			for b in lst:
				if seen.has(b):
					continue
				seen[b] = true
				if dist_to(b, x, z) <= r:
					out.append(b)
	return out


## Premier point touché par un rayon (immeuble ou sol) : {pos, b}.
## On remonte le rayon depuis le sol sur la hauteur maximale des immeubles.
func trace(o: Vector3, d: Vector3) -> Dictionary:
	if d.y > -0.001:
		return {"pos": o + d * 6000.0, "b": -1}
	var tg := -o.y / d.y
	var g := o + d * tg
	var s_max := h_max / (-d.y)
	var step := 1.5
	var s := s_max
	var prev_s := s_max + step
	while s > 0.0:
		var p := g - d * s
		var b := building_at(p.x, p.z)
		if b >= 0 and p.y <= height_of(b):
			var lo := s
			var hi := prev_s
			for k in 4:
				var mid := (lo + hi) * 0.5
				var pm := g - d * mid
				var bm := building_at(pm.x, pm.z)
				if bm >= 0 and pm.y <= height_of(bm):
					lo = mid
				else:
					hi = mid
			return {"pos": g - d * lo, "b": b}
		prev_s = s
		s -= step
	return {"pos": g, "b": -1}


## La ligne de vue de `eye` (la canonnière) vers `p` (un point près du sol) est-elle coupée par un immeuble ? On remonte le segment depuis `p`
## par pas de `step` mètres et l'on s'arrête dès qu'il dépasse l'immeuble le plus haut. Sert aux carrés rouges des infectés cachés.
func blocked(eye: Vector3, p: Vector3, step: float = 4.0) -> bool:
	var d: Vector3 = eye - p
	var len: float = d.length()
	if len < 2.0 or d.y <= 0.02:
		return false
	d /= len
	var s_max: float = minf(len, (h_max - p.y) / d.y)
	var s := 1.2                              # on ne teste pas le point lui-même
	while s < s_max:
		var q: Vector3 = p + d * s
		var b := building_at(q.x, q.z)
		if b >= 0 and q.y <= height_of(b):
			return true
		s += step
	return false


# ---------------------------------------------------------------- dégâts

func damage(b: int, amount: float) -> void:
	if status[b] != ST_OK or amount <= 0.0:
		return
	hp[b] -= amount
	if hp[b] <= 0.0:
		destroy(b)
	else:
		fire[b] = minf(fire[b] + amount * 0.004, 0.3)
		_active[b] = true
		_mark(b)
		if ctx.fx != null and fire[b] > 0.1:
			ctx.fx.add_burner(b)


## Dégâts d'une explosion : coup direct (direct_b) + effet de souffle sur les immeubles voisins.
func splash(p: Vector3, r: float, dmg: float, direct_b: int) -> void:
	if direct_b >= 0:
		damage(direct_b, dmg)
	for b in near(p.x, p.z, r):
		if b == direct_b:
			continue
		var d := dist_to(b, p.x, p.z)
		damage(b, dmg * 0.35 * (1.0 - d / r))


func destroy(b: int) -> void:
	if status[b] != ST_OK:
		return
	var was_lost: bool = advice(b) == "raze"      # l'immeuble était-il déjà perdu quand il tombe ? (avant de le vider)
	status[b] = ST_COLLAPSING
	collapse[b] = 0.0
	fire[b] = 1.0
	var alive_occ := occ[b]
	var zombies := zin[b] + turning[b]
	occ[b] = 0
	zin[b] = 0
	turning[b] = 0
	_active[b] = true
	ctx.director.on_building_destroyed(b, alive_occ, zombies, was_lost)
	if ctx.fx != null:
		var c := Vector3(city.b_cx[b], 0.0, city.b_cz[b])
		var sz := maxf(city.b_w[b], city.b_d[b])
		ctx.fx.add_flash(c + Vector3(0.0, city.b_h[b] * 0.5, 0.0), sz * 1.4, 1.0, 1.1)
		ctx.fx.add_fire(c + Vector3(0.0, 3.0, 0.0), sz * 0.9, b)
		ctx.fx.collapse(b)
	_mark(b)


# ---------------------------------------------------------------- infestation

func targetable(b: int) -> bool:
	return b >= 0 and status[b] == ST_OK and occ[b] > 0


## k infectés entrent d'un coup. grace_s : répit avant le premier repas (le temps de voir l'alerte et de viser l'immeuble).
func infest(b: int, k: int, grace_s: float = 0.0) -> void:
	zin[b] += k
	siege[b] = door_hp[b]
	announced[b] = 1
	eat_t[b] = 0.0 - maxf(grace_s, 0.0) * float(zin[b])
	_active[b] = true
	_mark(b)


## Un zombie martèle la porte pendant dt secondes.
func pound(b: int, dt: float) -> void:
	siege[b] += dt
	idle_t[b] = 0.0
	_active[b] = true
	if siege[b] >= door_hp[b] and announced[b] == 0:
		announced[b] = 1
		ctx.director.on_breach(b)


func mark_active(b: int) -> void:
	_active[b] = true


func is_breached(b: int) -> bool:
	return siege[b] >= door_hp[b]


## Immeubles dont la porte tient encore mais est attaquée.
func siege_list() -> Array:
	var out: Array = []
	for b in _active:
		if status[b] == ST_OK and siege[b] > 2.0 and siege[b] < door_hp[b]:
			out.append(b)
	return out


func enter(b: int) -> void:
	zin[b] += 1
	_active[b] = true
	_mark(b)


func zombies_inside() -> int:
	var s := 0
	for b in _active:
		if status[b] == ST_OK:
			s += zin[b] + turning[b]
	return s


## Que faire de cet immeuble ? Un seul calcul pour l'écran (conseil sous la visée, étiquettes), la radio et le robot d'essai.
##   "ruins"  détruit.   "safe"  aucune menace.   "empty"  plus personne à sauver.
##   "siege"  la porte tient mais des infectés la martèlent : les abattre devant la porte, ne rien raser.
##   "open"   porte forcée, aucun infecté à l'intérieur pour l'instant : surveiller.
##   "defend" des infectés dedans, mais l'immeuble n'est pas perdu : tenir la rue et les sorties, ne pas raser.
##   "raze"   immeuble perdu : le raser coûte moins de civils que de le laisser aux infectés (et arrête la contamination de la rue).
## Perdu = au moins `raze_min_inf` infectés à l'intérieur (par défaut `burst_threshold` : à ce nombre ils sortent en flot) et au plus
## `raze_max_occ` habitants vivants ; ou 2 habitants au plus avec 2 infectés ; ou immeuble submergé (infectés ≥ un tiers des habitants, au
## moins 6). Seuls comptent les infectés entrés (`zin`), les civils en train de se transformer pas encore. Le seuil franchi, l'immeuble reste
## perdu tant qu'il contient des infectés (verrou `lost_latch`) : la première sortie ramène le compte de 4 à 3, et sans verrou le conseil
## passerait de OUI à NON pendant que l'obus est en l'air.
## Mesures des robots d'essai (README, « Comprendre les pertes ») : l'effet de raser sur les victoires est faible et change de signe d'un
## essai à l'autre (ne jamais raser fait aussi bien que ce conseil sur le jeu livré) : raser est un dernier recours, pas un levier.
## Seuil à 3 infectés, comptage des corps en train de se relever ou plafond d'habitants différent : pas mieux, parfois moins bien.
func advice(b: int) -> String:
	if status[b] != ST_OK:
		return "ruins"
	var inf: int = zin[b]
	var o: int = occ[b]
	if inf <= 0:
		lost_latch[b] = 0
		if o <= 0:
			return "empty"
		if siege[b] >= door_hp[b]:
			return "open"
		return "siege" if siege[b] > 2.0 else "safe"
	if inf >= raze_min_inf():
		lost_latch[b] = 1
	if lost_latch[b] == 1 and o <= int(ctx.rule("raze_max_occ", 14.0)):
		return "raze"
	if inf >= 2 and o <= 2:
		return "raze"
	if o <= 60 and inf >= maxi(6, o / 3):
		return "raze"
	return "empty" if o <= 0 else "defend"


## Nombre d'infectés dedans à partir duquel un immeuble est perdu (voir advice).
func raze_min_inf() -> int:
	return maxi(1, int(ctx.rule("raze_min_inf", ctx.rule("burst_threshold", 4.0))))


## Immeubles habités actuellement attaqués : porte assiégée, infectés à l'intérieur ou civils en train de se transformer.
func threatened_list() -> Array:
	var out: Array = []
	for b in _active.keys():
		if status[b] == ST_OK and occ[b] > 0 and (siege[b] > 0.0 or zin[b] > 0 or turning[b] > 0):
			out.append(b)
	return out


func infested_list() -> Array:
	var out: Array = []
	for b in _active:
		if status[b] == ST_OK and zin[b] > 0:
			out.append(b)
	return out


## Choisit un immeuble habité proche (parmi les 3 plus proches) ; -1 s'il n'y en a pas.
func pick_target(pos: Vector2) -> int:
	var cx := int(floor(pos.x / TCELL))
	var cz := int(floor(pos.y / TCELL))
	var cands: Array = []
	for ring in 14:
		for ix in range(cx - ring, cx + ring + 1):
			for iz in range(cz - ring, cz + ring + 1):
				if maxi(absi(ix - cx), absi(iz - cz)) != ring:
					continue
				var lst = _tgrid.get(_key(ix, iz))
				if lst == null:
					continue
				for b in lst:
					if occ[b] > 0 and status[b] == ST_OK:
						var bp := Vector2(city.b_cx[b], city.b_cz[b])
						if ctx.in_zone(bp, 30.0):                    # les immeubles hors de la zone de jeu ne sont pas attaqués
							cands.append([pos.distance_squared_to(bp), b])
		if cands.size() >= 6:
			break
	if cands.is_empty():
		return -1
	cands.sort_custom(func(a, c): return a[0] < c[0])
	var k := mini(cands.size(), 3)
	return cands[ctx.rng.randi_range(0, k - 1)][1]


# ---------------------------------------------------------------- simulation

func step(dt: float) -> void:
	for b in _active.keys():
		_step_one(b, dt)


func _step_one(b: int, dt: float) -> void:
	var st: int = status[b]
	if st == ST_COLLAPSING:
		collapse[b] = minf(collapse[b] + dt / 3.0, 1.0)
		if collapse[b] >= 1.0:
			status[b] = ST_RUINS
	if st != ST_OK:
		fire[b] = maxf(fire[b] - dt / 75.0, 0.12)
		_mark(b)
		if status[b] == ST_RUINS and fire[b] <= 0.121:
			_active.erase(b)
		return
	fire[b] = maxf(fire[b] - dt / 40.0, 0.0)
	if siege[b] > 0.0 and siege[b] < door_hp[b]:
		idle_t[b] += dt
		if idle_t[b] > 1.5:
			siege[b] = maxf(siege[b] - dt, 0.0)
	if occ[b] > 0 and zin[b] > 0:
		eat_t[b] += dt * float(zin[b])
		var ei: float = ctx.rule("eat_interval_s", 9.0)
		if eat_t[b] >= ei:
			eat_t[b] -= ei
			occ[b] -= 1
			turning[b] += 1
			ctx.director.civilian_lost(1, "inside", Vector2(city.b_cx[b], city.b_cz[b]))
		flee_t[b] += dt
		if flee_t[b] >= ctx.rule("flee_interval_s", 4.5) and occ[b] > 0:
			flee_t[b] = 0.0
			if ctx.crowd.spawn_civilian_at_door(b):
				occ[b] -= 1
	if turning[b] > 0:
		turn_t[b] += dt
		if turn_t[b] >= ctx.rule("turn_delay_s", 6.0):
			turn_t[b] = 0.0
			turning[b] -= 1
			zin[b] += 1
	if zin[b] >= raze_min_inf():
		lost_latch[b] = 1                   # seuil « perdu » atteint (voir advice), même si personne n'a demandé le conseil à cet instant
	elif zin[b] <= 0:
		lost_latch[b] = 0
	if zin[b] > 0 and (zin[b] >= int(ctx.rule("burst_threshold", 4.0)) or occ[b] <= 0):
		burst_t[b] += dt
		if burst_t[b] >= ctx.rule("burst_interval_s", 2.5):
			burst_t[b] = 0.0
			if ctx.crowd.spawn_zombie_at_door(b):
				zin[b] -= 1
	_mark(b)
	var sieged: bool = siege[b] > 0.0 and siege[b] < door_hp[b]
	if zin[b] <= 0 and turning[b] <= 0 and fire[b] <= 0.0 and not sieged:
		_active.erase(b)


## Immeuble à raser (conseil « raser » avec des habitants à ensevelir) : le rendu le colore en rouge, l'écran l'entoure et le marque sur la carte.
func is_raze_alert(b: int) -> bool:
	return status[b] == ST_OK and occ[b] > 0 and zin[b] > 0 and advice(b) == "raze"


func _mark(b: int) -> void:
	if view == null:
		return
	var of := 0.02
	if occ[b] > 0:
		of = 0.05 + 0.33 * float(occ[b]) / float(occ_max[b])
	var inf_f := minf(0.45, 0.07 * float(zin[b]) + 0.05 * float(turning[b]))
	view.set_state(b, of, inf_f, collapse[b], fire[b], 1.0 if is_raze_alert(b) else 0.0)
