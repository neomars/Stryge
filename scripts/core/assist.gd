extends RefCounted
## Viseur assisté (niveau Recrue, clé « assist » de data/difficulty.json) : tant que le joueur ne le tient pas, la visée est attirée vers
## la zone de la cible urgente (Director.urgent()). Ce n'est qu'un aimant : il ne tire jamais, s'arrête dès que le viseur est dans la zone,
## et s'efface devant le joueur :
##   - il n'attire que faiblement tant que la souris ou le clavier déplacent la visée, et reprend pleine force après un instant de calme ;
##   - si le joueur s'éloigne franchement de la cible, l'aimant se suspend BREAK_S secondes (il veut regarder ailleurs) ;
##   - il ne joue pas pendant le tir (ni juste après) ni quand le désignateur laser tient un infecté.
## Vétéran et Cauchemar n'ont pas d'aide (assist = 0) : la visée n'y obéit qu'au joueur.

const MAX_SPEED := 180.0        # m/s : vitesse maximale de l'attraction (cible loin, zoom faible)
const MIN_SPEED := 40.0         # m/s : vitesse minimale tant que le viseur n'est pas dans la zone (zoom faible)
const FIELD_MAX := 0.9          # la visée ne traverse jamais plus de 0,9 largeur d'image par seconde (zoom fort : attraction plus lente)
const FIELD_MIN := 0.15         # ... et jamais moins de 0,15 largeur d'image par seconde (sinon on n'arriverait jamais)
const GAIN := 1.0               # 1/s : au-delà, la vitesse est l'écart restant × GAIN (arrivée en douceur)
const BUSY_SCALE := 0.3         # part de l'attraction qui reste pendant que le joueur déplace la visée
const CALM_S := 0.5             # calme nécessaire pour retrouver toute la force
const FIRE_GRACE_S := 0.7       # pas d'attraction pendant le tir ni juste après
const AWAY_S := 0.35            # durée d'éloignement volontaire qui suspend l'aimant
const BREAK_S := 3.0            # suspension quand le joueur s'éloigne de la cible
const ENTER_K := 0.85           # le viseur est « dans la zone » à 85 % du rayon, il en ressort à 125 %
const LEAVE_K := 1.25

var ctx
var strength := 0.0             # 0 : pas d'aide ; 1 : aide de la Recrue (relu à chaque image)
var active := false             # l'aimant tire la visée à cette image
var inside := false             # le viseur est dans la zone de la cible
var pause_t := 0.0              # temps restant de suspension
var pulled_m := 0.0             # chemin total parcouru sous l'aimant (essais)
var _moved := Vector2.ZERO      # déplacement voulu par le joueur depuis la dernière image (m)
var _calm := 9.0
var _away := 0.0
var _fire_t := 0.0
var _key := ""


func setup(p_ctx) -> void:
	ctx = p_ctx
	reset()


func reset() -> void:
	active = false
	inside = false
	pause_t = 0.0
	pulled_m = 0.0
	_moved = Vector2.ZERO
	_calm = 9.0
	_away = 0.0
	_fire_t = 0.0
	_key = ""


## Force de l'aide du niveau en cours (0 à 1).
func level() -> float:
	return clampf(float(ctx.difficulty().get("assist", 0.0)), 0.0, 1.0)


## Largeur de l'image au sol (m) à la distance de la visée : l'attraction se règle dessus pour ne pas faire défiler l'image trop vite en zoom fort.
func field_m() -> float:
	var gs = ctx.gunship
	var rng: float = gs.pos.distance_to(Vector3(gs.aim.x, 0.0, gs.aim.y))
	return 2.0 * rng * tan(deg_to_rad(float(gs.fov)) * 0.5) * (16.0 / 9.0)


## Déplacement de la visée voulu par le joueur (mètres au sol), à appeler après chaque mouvement de souris ou de clavier.
func note_input(delta_aim: Vector2) -> void:
	_moved += delta_aim


## À appeler une fois par image de jeu, avant Gunship.update.
func update(dt: float) -> void:
	strength = level()
	active = false
	var moved := _moved
	_moved = Vector2.ZERO
	if strength <= 0.0 or dt <= 0.0 or ctx.director == null:
		return
	var typing: bool = moved.length() > 0.0001
	if typing:
		_calm = 0.0
	else:
		_calm += dt
	if ctx.arms != null and ctx.arms.trigger:
		_fire_t = FIRE_GRACE_S
	else:
		_fire_t = maxf(_fire_t - dt, 0.0)
	var pr: Dictionary = ctx.director.urgent()
	var kind := str(pr.get("kind", "none"))
	if kind == "none" or float(pr.get("pull", 0.0)) <= 0.0:
		inside = false
		_key = ""
		_away = 0.0
		return
	var key := str(pr.get("key", ""))
	if key != _key:
		_key = key                                  # nouvelle cible : on repart de zéro
		inside = false
		_away = 0.0
	var gs = ctx.gunship
	var target: Vector2 = ctx.director.prio.aim_point(pr)
	var to: Vector2 = target - gs.aim
	var dist := to.length()
	var radius := float(pr.get("radius", 20.0))
	# le joueur s'éloigne de la cible : on le laisse faire
	if typing and dist > 1.0 and moved.dot(to / dist) < -0.35 * moved.length():
		_away += dt
		if _away >= AWAY_S:
			pause_t = BREAK_S
			_away = 0.0
	else:
		_away = maxf(_away - 2.0 * dt, 0.0)
	if pause_t > 0.0:
		pause_t -= dt
		return
	if inside:
		if dist > radius * LEAVE_K:
			inside = false
	elif dist <= radius * ENTER_K:
		inside = true
	if inside or dist < 0.5:
		return
	if _fire_t > 0.0 or (ctx.designator != null and ctx.designator.active):
		return
	var scale_f := lerpf(BUSY_SCALE, 1.0, clampf(_calm / CALM_S, 0.0, 1.0))
	var field := field_m()
	var v_hi := clampf(FIELD_MAX * field, 12.0, MAX_SPEED)
	var v_lo := clampf(FIELD_MIN * field, 6.0, MIN_SPEED)
	var v := clampf((dist - radius * ENTER_K) * GAIN, v_lo, v_hi) * strength * float(pr["pull"]) * scale_f
	var step := minf(v * dt, dist - radius * ENTER_K * 0.9)
	if step <= 0.0:
		return
	gs.aim += to / dist * step
	pulled_m += step
	active = true
