extends RefCounted
## Armement : cadence, munitions, dispersion, temps de vol des obus, impacts et dégâts de zone.

class Shell:
	var t := 0.0
	var dur := 1.0
	var pos := Vector3.ZERO
	var b := -1
	var w := 0
	var range := 0.0
	var support := false      # obus d'un appui (barrage) : ne compte ni dans les tirs ni dans la précision du joueur

var ctx
var current := 0
var ammo: Array = []
## Rechargement de CHAQUE arme (s restantes avant le prochain coup).  Changer d'arme n'attend donc jamais le rechargement de la
## précédente : elle finit de se recharger en arrière-plan et la nouvelle tire tout de suite si elle est prête.
var cooldowns: Array = []
## Rechargement de l'arme en main (lecture/écriture : le HUD, l'autopilote et les tests s'en servent tel quel).
var cooldown: float:
	get:
		return float(cooldowns[current]) if current >= 0 and current < cooldowns.size() else 0.0
	set(v):
		if current >= 0 and current < cooldowns.size():
			cooldowns[current] = v
var shells: Array = []
var trigger := false
var shots := 0
var _tracer_n := 0


func setup(p_ctx) -> void:
	ctx = p_ctx
	ammo.clear()
	cooldowns.clear()
	for w in ctx.weapons:
		ammo.append(float(w.get("ammo", 100)))
		cooldowns.append(0.0)
	current = 0
	ctx.gunship.base_fov = float(ctx.weapons[0]["fov_deg"])


func select(i: int) -> void:
	if i < 0 or i >= ctx.weapons.size() or i == current:
		return
	current = i                                    # aucun délai : la cadence de la nouvelle arme est la sienne (cooldowns[i])
	ctx.gunship.base_fov = float(ctx.weapons[i]["fov_deg"])
	if ctx.sound != null:
		ctx.sound.select(i)


## Rechargement restant d'une arme, en pourcentage de sa période (0 = prête, 1 = tout juste tirée).
func reload_fraction(i: int) -> float:
	if i < 0 or i >= cooldowns.size():
		return 0.0
	var per := 60.0 / float(ctx.weapons[i]["rpm"])
	return clampf(float(cooldowns[i]) / per, 0.0, 1.0) if per > 0.25 else 0.0


func cycle() -> void:
	select((current + 1) % ctx.weapons.size())


func period() -> float:
	return 60.0 / float(ctx.weapons[current]["rpm"])


func update(dt: float) -> void:
	for i in ctx.weapons.size():
		var wd: Dictionary = ctx.weapons[i]
		ammo[i] = minf(ammo[i] + float(wd.get("regen_per_s", 0.0)) * dt, float(wd.get("ammo", 0)))
	# chaque arme se recharge de son côté, qu'elle soit en main ou non ; seule l'arme en main qui tire garde un reste négatif
	# (le reliquat de temps du pas précédent, pour que la cadence soit exacte)
	for i in cooldowns.size():
		cooldowns[i] = float(cooldowns[i]) - dt
		if i != current or not trigger:
			cooldowns[i] = maxf(float(cooldowns[i]), 0.0)
	if trigger:
		var w: Dictionary = ctx.weapons[current]
		var per := 60.0 / float(w["rpm"])
		var guard := 0
		while float(cooldowns[current]) <= 0.0 and ammo[current] >= 1.0 and guard < 12:
			guard += 1
			_fire_one(w)
			cooldowns[current] = float(cooldowns[current]) + per
			ammo[current] -= 1.0
		if ammo[current] < 1.0:
			cooldowns[current] = maxf(float(cooldowns[current]), 0.0)
	for i in range(shells.size() - 1, -1, -1):
		var s: Shell = shells[i]
		s.t -= dt
		if s.t <= 0.0:
			shells.remove_at(i)
			_impact(s)


func _fire_one(w: Dictionary) -> void:
	var gs = ctx.gunship
	var ray: Array = gs.ray()
	var o: Vector3 = ray[0]
	var d: Vector3 = ray[1]
	var r: Vector3 = ray[2]
	var u: Vector3 = ray[3]
	var disp := float(w["dispersion_mrad"]) * 0.001
	if ctx.designator != null:
		disp *= ctx.designator.dispersion_factor(current)      # cible verrouillée au laser (niveau 3) : obus lourds plus groupés
	var dd: Vector3 = (d + r * ctx.rng.randfn(0.0, disp) + u * ctx.rng.randfn(0.0, disp)).normalized()
	var hit: Dictionary = ctx.buildings.trace(o, dd)
	if ctx.lock != null and int(hit["b"]) >= 0 and ctx.lock.level > 0.0 and not ctx.buildings.is_raze_alert(int(hit["b"])):
		# tir sur un infecté verrouillé caché derrière l'immeuble : l'obus est guidé et tombe dans la rue, pas sur le toit
		# (sauf sur un immeuble à raser : surligné en rouge, il reçoit les obus qui lui sont destinés)
		var gp = ctx.lock.guide(o, dd, float(w["splash_radius_m"]))
		if gp != null:
			hit = {"pos": gp, "b": -1}
	var s := Shell.new()
	s.dur = float(w["flight_time_s"])
	s.t = s.dur
	s.pos = hit["pos"]
	s.b = hit["b"]
	s.w = current
	s.range = o.distance_to(s.pos)
	shells.append(s)
	shots += 1
	if ctx.score != null:
		ctx.score.on_shot(current)
	gs.shake = minf(gs.shake + float(w["shake"]) * 0.3, 3.0)
	if ctx.fx != null:
		_tracer_n += 1
		if _tracer_n % maxi(int(w["tracer_every"]), 1) == 0:
			var hw := o.distance_to(s.pos) * tan(deg_to_rad(gs.fov) * 0.5)
			var from := o + r * (hw * 1.25) + u * (hw * 0.95) + d * 40.0
			ctx.fx.add_tracer(from, s.pos, s.dur, 1.0, 2.4 if float(w["splash_radius_m"]) < 5.0 else 3.6)


## Obus d'un appui (barrage) : il tombe du ciel au point demandé, avec les caractéristiques de la dernière arme (105 mm).
func support_shell(at: Vector2) -> void:
	var hit: Dictionary = ctx.buildings.trace(Vector3(at.x, 1500.0, at.y), Vector3.DOWN)
	var s := Shell.new()
	s.pos = hit["pos"]
	s.b = hit["b"]
	s.w = ctx.weapons.size() - 1
	s.support = true
	_impact(s)


func _impact(s: Shell) -> void:
	var w: Dictionary = ctx.weapons[s.w]
	var p: Vector3 = s.pos
	var rad := float(w["splash_radius_m"])
	var hz := 0
	var kills0: int = ctx.director.kills if s.support else 0
	if ctx.score != null and not s.support:
		ctx.score.begin_shell(s.w, s.range)
	if p.y < 4.0:
		ctx.crowd.damage_area(p.x, p.z, rad, float(w["damage_person"]), 0.6, s.w)
		hz = ctx.crowd.last_hit_z
	ctx.buildings.splash(p, rad, float(w["damage_building"]), s.b)
	if ctx.score != null:
		if s.support:
			ctx.score.st["support_kills"] = int(ctx.score.st["support_kills"]) + ctx.director.kills - kills0
		else:
			ctx.score.end_shell(hz)
	if ctx.fx != null:
		ctx.fx.add_flash(p + Vector3(0.0, 1.0, 0.0), float(w["flash_radius_m"]), float(w["flash"]), 0.5)
		ctx.fx.impact(p, s.w, s.b)
