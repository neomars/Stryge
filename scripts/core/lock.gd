extends RefCounted
## Verrouillage des infectés cachés (clé « lock » de data/difficulty.json : 1 en Recrue et Vétéran, 0 en Cauchemar).
##
## Vu de la canonnière, un immeuble masque la rue derrière lui. Le système garde les yeux sur les infectés que la ligne de vue coupe (test
## BuildingSystem.blocked) et les « verrouille » : le HUD les entoure d'un carré rouge, seulement tant qu'ils sont cachés. Un infecté visible
## n'a pas de carré. Un obus tiré sur un point du sol où se trouve un infecté verrouillé (à moins du rayon d'effet de l'arme) n'éclate pas sur
## le toit : il est guidé et tombe dans la rue, comme s'il avait été tiré sur une cible à découvert.

const PERIOD := 0.15            # s entre deux relevés des infectés proches du champ de l'image (les infectés vont à 3,6 m/s au plus : 0,5 m d'écart)
const PER_FRAME := 16           # infectés évalués par image au plus : une passe de 130 infectés s'étale sur ~8 images (jamais d'à-coup)
const HIDE_ON := 2              # un infecté est verrouillé quand 2 mesures sur 3 le disent caché (pas de clignotement)
const MAX_TESTS := 120          # infectés évalués par passe (les plus proches de la visée d'abord) : le coût reste borné

var ctx
var level := 1.0                # 0 : pas de verrouillage
var hidden: Array = []          # positions au sol (Vector2) des infectés verrouillés à la fin de la dernière passe
var hidden_p: Array = []        # les mêmes infectés (fiches de la foule) : le HUD et le guidage lisent leur position du moment, et sautent les morts
var tests := 0                  # infectés évalués par la dernière passe (essais)
var _t := 0.0
var _queue: Array = []          # fiches à évaluer dans la passe en cours
var _qi := 0


func setup(p_ctx) -> void:
	ctx = p_ctx
	reset()


func reset() -> void:
	hidden = []
	hidden_p = []
	_queue = []
	_qi = 0
	_t = 0.0
	level = float(ctx.difficulty().get("lock", 1.0)) if ctx != null else 1.0


func enabled() -> bool:
	return level > 0.0 and ctx.director != null and ctx.director.state == "running"


## Rayon (m) autour de la visée où l'on évalue les infectés : un peu plus que le champ de l'image (rapport 16/9, diagonale comprise).
func view_radius() -> float:
	var gs = ctx.gunship
	var dist: float = gs.pos.distance_to(Vector3(gs.aim.x, 0.0, gs.aim.y))
	return clampf(1.9 * dist * tan(deg_to_rad(gs.fov) * 0.5) + 40.0, 120.0, 1200.0)


## Une image de jeu : évalue au plus PER_FRAME infectés de la passe en cours ; une nouvelle passe démarre PERIOD secondes après la précédente.
func update(dt: float) -> void:
	_t -= dt
	if not enabled():
		hidden = []
		hidden_p = []
		_queue = []
		_qi = 0
		return
	if _qi >= _queue.size():
		if _t > 0.0:
			return
		_t = PERIOD
		_queue = _candidates()
		_qi = 0
	var n := mini(PER_FRAME, _queue.size() - _qi)
	for k in n:
		_test(_queue[_qi + k])
	_qi += n
	if _qi >= _queue.size():
		_publish()


## Passe complète en une fois (essais).
func scan() -> void:
	_queue = _candidates()
	for p in _queue:
		_test(p)
	_qi = _queue.size()
	_publish()


## Infectés vivants proches du champ de l'image : les MAX_TESTS plus proches de la visée.
func _candidates() -> Array:
	var gs = ctx.gunship
	var r := view_radius()
	var r2 := r * r
	var cands: Array = []
	for p in ctx.crowd.pool:
		if p.alive and p.kind == ctx.crowd.K_ZOMBIE:
			var d2: float = p.pos.distance_squared_to(gs.aim)
			if d2 <= r2:
				cands.append([d2, p])
	if cands.size() > MAX_TESTS:
		cands.sort_custom(func(a, b): return a[0] < b[0])
		cands.resize(MAX_TESTS)
	var out: Array = []
	for c in cands:
		out.append(c[1])
	tests = out.size()
	return out


func _test(p) -> void:
	if not p.alive or p.kind != ctx.crowd.K_ZOMBIE:
		return
	var occluded: bool = ctx.buildings.blocked(ctx.gunship.pos, Vector3(p.pos.x, 1.0, p.pos.y))
	p.hid = clampi(p.hid + (1 if occluded else -1), 0, 3)


func _publish() -> void:
	hidden = []
	hidden_p = []
	for p in _queue:
		if p.alive and p.kind == ctx.crowd.K_ZOMBIE and p.hid >= HIDE_ON:
			hidden.append(p.pos)
			hidden_p.append(p)


## Un tir lâché maintenant au centre du réticule serait-il guidé ? Vrai si le viseur est sur un immeuble qui n'est pas à raser et qu'un infecté
## verrouillé est à portée d'éclat de l'arme (le viseur l'affiche : « TIR GUIDÉ »). Même règle que le détournement dans Arms._fire_one.
func aim_guided(b: int, radius: float) -> bool:
	if level <= 0.0 or b < 0 or hidden_p.is_empty() or ctx.buildings.is_raze_alert(b):
		return false
	var ray: Array = ctx.gunship.ray()
	return guide(ray[0], ray[1], radius) != null


## Un obus tiré le long du rayon (o, d) : le point du sol où il tomberait sans l'immeuble, s'il est à moins de `radius` m d'un infecté
## verrouillé ; sinon null.
func guide(o: Vector3, d: Vector3, radius: float) -> Variant:
	if hidden_p.is_empty() or d.y > -0.001:
		return null
	var tg: float = -o.y / d.y
	var gx: float = o.x + d.x * tg
	var gz: float = o.z + d.z * tg
	var g2 := Vector2(gx, gz)
	var r2 := radius * radius
	for p in hidden_p:
		if p.alive and p.kind == ctx.crowd.K_ZOMBIE and p.pos.distance_squared_to(g2) <= r2:
			return Vector3(gx, 0.0, gz)
	return null
