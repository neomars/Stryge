extends RefCounted
## Prédicteur de tir (capteur de l'atelier) : un obus met du temps à tomber, les personnes avancent pendant ce temps.
## Toutes les 0,25 s on mesure le déplacement de chaque personne proche du point visé (vitesse = écart entre deux relevés).
##   niveau 1 : marqueur d'anticipation — où sera la grappe d'infectés la plus proche du réticule au moment de l'impact
##              (position actuelle de la grappe + vitesse moyenne × temps de vol de l'arme sélectionnée) ;
##   niveau 2 : estimation du nombre d'infectés que l'obus tomberait sur le point visé toucherait à l'arrivée ;
##   niveau 3 : même estimation pour les civils (alerte de bavure).

const SAMPLE_DT := 0.25
const RADIUS := 140.0          # personnes suivies autour du point visé (m)
const CLUSTER_R := 25.0        # la grappe : infectés à moins de 25 m de l'infecté le plus proche du réticule
const MAX_SPEED := 6.0         # une vitesse mesurée plus grande est une mesure aberrante (personnage réutilisé)

var ctx
var shown := false             # un marqueur est disponible (niveau ≥ 1 et au moins un infecté suivi)
var group_pos := Vector2.ZERO  # centre de la grappe au dernier relevé
var group_v := Vector2.ZERO    # vitesse moyenne de la grappe (m/s)
var n_follow := 0              # infectés dans la grappe
var n_hit := 0                 # infectés qui seraient touchés par un obus tombant sur le point visé (niveau ≥ 2)
var n_civ := 0                 # civils qui seraient touchés (niveau 3)
var _since := 0.0              # temps écoulé depuis le dernier relevé
var _acc := 0.0
var _prev: Dictionary = {}     # indice du personnage -> position au relevé précédent


func setup(p_ctx) -> void:
	ctx = p_ctx
	reset()


func reset() -> void:
	shown = false
	group_pos = Vector2.ZERO
	group_v = Vector2.ZERO
	n_follow = 0
	n_hit = 0
	n_civ = 0
	_since = 0.0
	_acc = 0.0
	_prev.clear()


func level() -> int:
	return clampi(int(ctx.mod("predict")), 0, 3)


func flight_time() -> float:
	return float(ctx.weapons[ctx.arms.current]["flight_time_s"])


## Position actuelle de la grappe (le dernier relevé, prolongé jusqu'à maintenant).
func group_now() -> Vector2:
	return group_pos + group_v * _since


## Où sera la grappe quand l'obus tiré maintenant arrivera.
func marker() -> Vector2:
	return group_pos + group_v * (_since + flight_time())


## Distance entre la grappe et son point d'arrivée anticipé (m).
func lead_m() -> float:
	return group_v.length() * flight_time()


func update(dt: float) -> void:
	if level() == 0:
		return
	_since += dt
	_acc += dt
	if _acc < SAMPLE_DT:
		return
	var step := _acc
	_acc = 0.0
	_since = 0.0
	var w: int = ctx.arms.current
	var t := float(ctx.weapons[w]["flight_time_s"])
	var aim: Vector2 = ctx.gunship.aim
	var cr = ctx.crowd
	var fresh := {}
	var near: Array = []                    # [position, vitesse, vitesse connue, type]
	var seed_d := INF
	var seed_pos := Vector2.ZERO
	for i in cr.MAX_P:
		var p = cr.pool[i]
		if not p.alive or p.kind > 1:
			continue
		var d: float = p.pos.distance_to(aim)
		if d > RADIUS:
			continue
		fresh[i] = p.pos
		var v := Vector2.ZERO
		var known := false
		if _prev.has(i):
			v = (p.pos - (_prev[i] as Vector2)) / maxf(step, 0.01)
			if v.length() <= MAX_SPEED:
				known = true
			else:
				v = Vector2.ZERO
		near.append([p.pos, v, known, p.kind])
		if p.kind == 0 and d < seed_d:
			seed_d = d
			seed_pos = p.pos
	_prev = fresh
	shown = false
	n_follow = 0
	group_v = Vector2.ZERO
	n_hit = 0
	n_civ = 0
	if seed_d == INF:
		return
	var cs := Vector2.ZERO
	var vs := Vector2.ZERO
	var nv := 0
	for e in near:
		if int(e[3]) == 0 and (e[0] as Vector2).distance_to(seed_pos) <= CLUSTER_R:
			cs += e[0]
			n_follow += 1
			if e[2]:
				vs += e[1]
				nv += 1
	group_pos = cs / float(n_follow)
	group_v = vs / float(nv) if nv > 0 else Vector2.ZERO
	shown = level() >= 1
	if level() >= 2:
		var rad := float(ctx.weapons[w]["splash_radius_m"])
		for e in near:
			if ((e[0] as Vector2) + (e[1] as Vector2) * t).distance_to(aim) <= rad:
				if int(e[3]) == 0:
					n_hit += 1
				elif level() >= 3:
					n_civ += 1
