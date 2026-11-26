extends RefCounted
## Désignateur laser (capteur de l'atelier) : clic droit (ou E) désigne l'infecté le plus proche du réticule ;
## la nacelle le suit tant que le joueur ne s'en éloigne pas franchement.
##   niveau 1 : rayon de désignation 30 m ;
##   niveau 2 : 60 m ; la cible suivante est désignée quand la première tombe ; la visée est avancée du chemin que
##              la cible parcourra pendant le vol de l'obus (tir anticipé) ;
##   niveau 3 : 100 m, et la dispersion des obus lourds (40 mm, 105 mm) est réduite de moitié tant que le verrou tient.

const RADII := [0.0, 30.0, 60.0, 100.0]
const FOLLOW := 6.0            # raideur du suivi (1/s)
const BREAK_FACTOR := 2.5      # le verrou saute quand le point visé s'éloigne de plus de 2,5 × le rayon
const MIN_BREAK := 70.0
const MAX_LEAD := 10.0         # avance maximale sur la cible (m)

var ctx
var active := false
var target = null              # Crowd.P suivi
var last_pos := Vector2.ZERO
var vel := Vector2.ZERO        # vitesse estimée de la cible (m/s, lissée)
var locks := 0                 # nombre de désignations de la mission
var fail_t := -99.0            # date (temps de jeu) de la dernière désignation sans cible à portée


func setup(p_ctx) -> void:
	ctx = p_ctx
	release()
	locks = 0
	fail_t = -99.0


func level() -> int:
	return clampi(int(ctx.mod("laser")), 0, 3)


func radius() -> float:
	return RADII[level()]


func toggle() -> void:
	if level() == 0:
		return
	if active:
		release()
	else:
		designate()


func designate() -> bool:
	if level() == 0:
		return false
	var p = _nearest(ctx.gunship.aim)
	if p == null:
		fail_t = ctx.time
		return false
	_lock(p)
	locks += 1
	return true


func release() -> void:
	active = false
	target = null
	vel = Vector2.ZERO


func _lock(p) -> void:
	target = p
	last_pos = p.pos
	vel = Vector2.ZERO
	active = true


func _nearest(from: Vector2):
	var p = ctx.crowd.nearest_zombie(from)
	if p == null or p.pos.distance_to(from) > radius():
		return null
	return p


## La cible désignée est-elle encore un infecté debout ?
func _valid() -> bool:
	return target != null and target.alive and target.kind == 0


## Où la nacelle doit viser : la cible, avancée de son chemin pendant le vol de l'obus (niveau 2 et 3).
func aim_point() -> Vector2:
	if target == null:
		return ctx.gunship.aim
	var p: Vector2 = target.pos
	if level() >= 2:
		var lead: Vector2 = vel * float(ctx.weapons[ctx.arms.current]["flight_time_s"])
		if lead.length() > MAX_LEAD:
			lead = lead.normalized() * MAX_LEAD
		p += lead
	return p


func update(dt: float) -> void:
	if not active:
		return
	if not _valid():
		var nxt = _nearest(last_pos) if level() >= 2 else null
		if nxt == null:
			release()
			return
		_lock(nxt)
	if dt > 0.0:
		var v: Vector2 = (target.pos - last_pos) / dt
		if v.length() <= 6.0:
			vel = vel.lerp(v, 1.0 - exp(-4.0 * dt))
	last_pos = target.pos
	var gs = ctx.gunship
	if gs.aim.distance_to(target.pos) > maxf(radius() * BREAK_FACTOR, MIN_BREAK):
		release()
		return
	gs.aim += (aim_point() - gs.aim) * (1.0 - exp(-FOLLOW * dt))


## Facteur appliqué à la dispersion de l'arme `weapon` (0,5 tant que le verrou tient au niveau 3, pour les obus lourds).
func dispersion_factor(weapon: int) -> float:
	if active and level() >= 3 and weapon >= 1:
		return 0.5
	return 1.0
