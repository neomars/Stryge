extends Node3D
## Effets visuels : flashs d'impact et flammes (sprites additifs), traceurs (rubans) et explosions :
## boule de feu, onde de choc, éclats qui rebondissent et refroidissent, étincelles, poussière et fumée légère
## (particules sans état calculées par les shaders, voir particle_set.gd).

const SPRITE_SHADER := preload("res://shaders/thermal_sprite.gdshader")
const TRACER_SHADER := preload("res://shaders/thermal_tracer.gdshader")
const DEBRIS_SHADER := preload("res://shaders/thermal_debris.gdshader")
const SPARK_SHADER := preload("res://shaders/thermal_spark.gdshader")
const SMOKE_SHADER := preload("res://shaders/thermal_smoke.gdshader")
const BLAST_SHADER := preload("res://shaders/thermal_blast.gdshader")
const ParticleSet := preload("res://scripts/core/particle_set.gd")
const MAX_S := 160
const N_DEBRIS := 1600
const N_SPARKS := 900
const N_SMOKE := 1800
const N_BLAST := 220


class Sp:
	var pos := Vector3.ZERO
	var size := 1.0
	var life := 1.0
	var age := 0.0
	var power := 1.0
	var kind := 0          # 0 = flash, 1 = flamme liée à un immeuble
	var b := -1
	var sd := 0.0


class Tr:
	var from := Vector3.ZERO
	var to := Vector3.ZERO
	var t := 0.0
	var dur := 1.0
	var power := 1.0
	var width_px := 2.4
	var arc := 0.0


var ctx
var sprites: Array = []
var tracers: Array = []
var mm: MultiMesh
var tmesh: ImmediateMesh

var t_fx := 0.0                                  # horloge des particules (s), gelée pendant la pause
var rng := RandomNumberGenerator.new()           # générateur propre aux effets : ne touche pas à la simulation
var wind := Vector3(2.4, 0.0, -0.9)              # vent (m/s) qui emporte la fumée
var debris
var sparks
var smoke
var blast
var burners := {}                                # immeuble -> cumul d'émission de fumée
var collapsing := {}                             # immeuble -> secondes restantes de poussière d'effondrement


func setup(p_ctx) -> void:
	ctx = p_ctx
	rng.seed = 90210
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = MAX_S
	mm.visible_instance_count = 0
	var sz: Vector2 = ctx.city.size_m()
	mm.custom_aabb = AABB(Vector3(-sz.x, -5.0, -sz.y), Vector3(sz.x * 2.0, 400.0, sz.y * 2.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Sprites"
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = SPRITE_SHADER
	mmi.material_override = mat
	add_child(mmi)

	tmesh = ImmediateMesh.new()
	var ti := MeshInstance3D.new()
	ti.name = "Tracers"
	ti.mesh = tmesh
	var tm := ShaderMaterial.new()
	tm.shader = TRACER_SHADER
	ti.material_override = tm
	ti.custom_aabb = AABB(Vector3(-6000.0, -200.0, -6000.0), Vector3(12000.0, 6000.0, 12000.0))
	add_child(ti)

	# --- particules d'explosion
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 1.0, 1.0)
	var bb := AABB(Vector3(-sz.x, -5.0, -sz.y), Vector3(sz.x * 2.0, 900.0, sz.y * 2.0))
	smoke = ParticleSet.new()
	smoke.setup(self, "Smoke", quad, SMOKE_SHADER, N_SMOKE, bb, 0)
	smoke.mat.set_shader_parameter("wind", wind)
	debris = ParticleSet.new()
	debris.setup(self, "Debris", box, DEBRIS_SHADER, N_DEBRIS, bb, 1)
	blast = ParticleSet.new()
	blast.setup(self, "Blast", quad, BLAST_SHADER, N_BLAST, bb, 2)
	sparks = ParticleSet.new()
	sparks.setup(self, "Sparks", quad, SPARK_SHADER, N_SPARKS, bb, 3)


func add_flash(p: Vector3, radius: float, power: float, life: float) -> void:
	var s := Sp.new()
	s.pos = p
	s.size = radius * 2.4
	s.life = maxf(life, 0.05)
	s.power = power
	s.kind = 0
	_push(s)


func add_fire(p: Vector3, radius: float, b: int) -> void:
	var s := Sp.new()
	s.pos = p
	s.size = radius * 2.0
	s.kind = 1
	s.b = b
	s.sd = ctx.rng.randf() * 6.28
	_push(s)


func add_tracer(from: Vector3, to: Vector3, dur: float, power: float, width_px: float) -> void:
	var t := Tr.new()
	t.from = from
	t.to = to
	t.dur = maxf(dur, 0.05)
	t.power = power
	t.width_px = width_px
	t.arc = 0.004 * from.distance_to(to)
	tracers.append(t)
	if tracers.size() > 96:
		tracers.pop_front()


func _push(s: Sp) -> void:
	if sprites.size() >= MAX_S:
		sprites.pop_front()
	sprites.append(s)


# ---------------------------------------------------------------- émetteurs de particules

func _rr(a: float, b: float) -> float:
	return rng.randf_range(a, b)


## Direction aléatoire dans un cône de demi-angle `half` (rad) autour de `axis`.
func _cone_dir(axis: Vector3, half: float) -> Vector3:
	var cz := rng.randf_range(cos(half), 1.0)
	var a := rng.randf() * TAU
	var r := sqrt(maxf(1.0 - cz * cz, 0.0))
	var b := axis.cross(Vector3.RIGHT if absf(axis.x) < 0.9 else Vector3.UP).normalized()
	var c := axis.cross(b)
	return (b * cos(a) + c * sin(a)) * r + axis * cz


## Éclats : v = vitesse, s = taille (m), life = temps avant disparition, tau = refroidissement (s).
func _debris(p: Vector3, count: int, vmin: float, vmax: float, smin: float, smax: float,
		life_min: float, life_max: float, half: float, tau: float) -> void:
	for i in count:
		var v := _cone_dir(Vector3.UP, half) * _rr(vmin, vmax)
		var s := _rr(smin, smax)
		debris.emit(p, v, t_fx, _rr(life_min, life_max), s, s, rng.randf(), _rr(-9.0, 9.0),
				0.0, 1.0, tau * _rr(0.7, 1.4), 0.0)


func _sparks(p: Vector3, count: int, vmin: float, vmax: float, half: float, life_min: float, life_max: float) -> void:
	for i in count:
		var v := _cone_dir(Vector3.UP, half) * _rr(vmin, vmax)
		sparks.emit(p, v, t_fx, _rr(life_min, life_max), 0.07, 0.0, rng.randf(), 0.0, _rr(0.75, 1.0), 0.0, 0.0, 0.0)


## Bouffée de poussière ou de fumée. alpha = opacité, h0 = chaleur initiale, h_end = teinte froide.
func _puff(p: Vector3, v: Vector3, s0: float, s1: float, life: float, alpha: float,
		h0: float, tau: float, h_end: float, buoy: float) -> void:
	smoke.emit(p, v, t_fx, life, s0, s1, rng.randf(), buoy, alpha, h0, tau, h_end)


## Trace de brûlure à plat sur le sol.
func _scorch(p: Vector3, size: float, life: float, alpha: float, h0: float, tau: float, h_end: float) -> void:
	smoke.emit(Vector3(p.x, 0.0, p.z), Vector3.ZERO, t_fx, life, size * 0.85, size, rng.randf(), 0.0,
			alpha, h0, tau, 1.0 + h_end)


func _fireball(p: Vector3, s0: float, s1: float, life: float, tau: float, power: float, lift: float) -> void:
	blast.emit(p, Vector3.ZERO, t_fx, life, s0, s1, rng.randf(), lift, power, 0.0, tau, 0.0)


func _ring(p: Vector3, radius: float, life: float, tau: float, power: float) -> void:
	blast.emit(Vector3(p.x, 0.0, p.z), Vector3.ZERO, t_fx, life, 0.0, radius, rng.randf(), 0.0, power, 1.0, tau, 0.0)


func _glare(p: Vector3, s0: float, s1: float, life: float, power: float) -> void:
	blast.emit(p, Vector3.ZERO, t_fx, life, s0, s1, rng.randf(), 0.0, power, 2.0, 0.12, 0.0)


func _footprint_pt(b: int, fx: float, fz: float) -> Vector3:
	var city = ctx.city
	var yaw: float = city.b_yaw[b]
	var c := cos(yaw)
	var s := sin(yaw)
	var lx: float = fx * city.b_w[b]
	var lz: float = fz * city.b_d[b]
	return Vector3(city.b_cx[b] + lx * c + lz * s, 0.0, city.b_cz[b] - lx * s + lz * c)


# ---------------------------------------------------------------- recettes

## Impact d'un obus : w = arme (0 = 25 mm, 1 = 40 mm, 2 = 105 mm), b = immeuble touché (-1 = sol).
func impact(p: Vector3, w: int, b: int) -> void:
	var on_ground := p.y < 3.0
	var q := p + Vector3(0.0, 0.4, 0.0)
	match w:
		0:
			_puff(q, Vector3(_rr(-1.5, 1.5), _rr(1.5, 3.0), _rr(-1.5, 1.5)), 1.4, _rr(4.5, 6.5), _rr(1.8, 2.6),
					0.55, 0.9, 0.4, 0.34, 0.4)
			_sparks(q, 3, 6.0, 18.0, 1.2, 0.3, 0.6)
			_debris(q, 2, 4.0, 11.0, 0.10, 0.22, 3.5, 6.0, 1.1, 1.0)
			if on_ground:
				_scorch(p, _rr(1.8, 2.6), 7.0, 0.55, 0.9, 1.5, 0.2)
		1:
			_fireball(q + Vector3(0.0, 1.5, 0.0), 1.5, 6.5, 0.5, 0.12, 1.0, 3.0)
			if on_ground:
				_ring(p, 15.0, 0.55, 0.16, 0.85)
			for i in 3:
				var o := Vector3(_rr(-2.0, 2.0), _rr(0.0, 2.0), _rr(-2.0, 2.0))
				_puff(q + o, Vector3(_rr(-3.0, 3.0), _rr(3.0, 7.0), _rr(-3.0, 3.0)), 3.0, _rr(10.0, 14.0),
						_rr(6.0, 9.0), 0.50, 0.95, 0.9, 0.33, 1.2)
			_sparks(q, 9, 12.0, 34.0, 1.3, 0.45, 0.9)
			_debris(q, 11, 8.0, 26.0, 0.14, 0.5, 5.0, 9.0, 1.2, 2.0)
			if on_ground:
				_scorch(p, _rr(6.0, 8.0), 22.0, 0.7, 1.0, 5.0, 0.18)
		_:
			_fireball(q + Vector3(0.0, 3.0, 0.0), 4.0, 20.0, 1.0, 0.2, 1.0, 9.0)
			_fireball(q + Vector3(0.0, 6.0, 0.0), 3.0, 13.0, 1.5, 0.35, 0.8, 16.0)
			if on_ground:
				_ring(p, 55.0, 0.95, 0.26, 1.0)
			# poussière rasante poussée par le souffle
			for i in 12:
				var a := TAU * float(i) / 12.0 + _rr(-0.2, 0.2)
				var sp := _rr(14.0, 22.0)
				_puff(q + Vector3(0.0, 2.0, 0.0), Vector3(cos(a) * sp, _rr(0.5, 3.0), sin(a) * sp),
						6.0, _rr(22.0, 32.0), _rr(9.0, 13.0), 0.46, 0.9, 2.0, 0.3, 0.3)
			# panache qui monte
			for i in 8:
				var o := Vector3(_rr(-4.0, 4.0), _rr(0.0, 5.0), _rr(-4.0, 4.0))
				_puff(q + o, Vector3(_rr(-2.0, 2.0), _rr(7.0, 13.0), _rr(-2.0, 2.0)), 6.0, _rr(20.0, 28.0),
						_rr(11.0, 17.0), 0.42, 1.0, 2.5, 0.3, 2.2)
			_sparks(q + Vector3(0.0, 2.0, 0.0), 26, 20.0, 58.0, 1.35, 0.6, 1.3)
			_debris(q, 34, 10.0, 42.0, 0.25, 0.9, 7.0, 12.0, 1.3, 4.0)
			if on_ground:
				_scorch(p, 30.0, 55.0, 0.85, 1.0, 14.0, 0.17)
	if b >= 0 and w >= 1:
		add_burner(b)


## Bouffée d'air chaud d'une bouche de métro d'où sort un groupe d'infectés : de la vapeur qui monte dans la nuit.
func metro_vent(p2: Vector2) -> void:
	var p := Vector3(p2.x, 1.2, p2.y)
	for i in 9:
		var o := Vector3(_rr(-2.5, 2.5), _rr(0.0, 1.0), _rr(-2.5, 2.5))
		_puff(p + o, Vector3(_rr(-1.0, 1.0), _rr(3.0, 6.5), _rr(-1.0, 1.0)), 2.5, _rr(10.0, 15.0), _rr(4.0, 7.0), 0.40, 0.9, 1.4, 0.3, 0.9)


## Hurlement d'un infecté : une onde pâle part du sol (la portée réelle du hurlement dépasse largement celle de l'image).
func scream(p2: Vector2, radius: float) -> void:
	_ring(Vector3(p2.x, 0.0, p2.y), minf(radius * 0.4, 70.0), 0.9, 0.3, 0.34)


## Onde du leurre sonore, répétée tant qu'il agit.
func decoy_pulse(p2: Vector2) -> void:
	_ring(Vector3(p2.x, 0.0, p2.y), 34.0, 1.1, 0.35, 0.30)


## Effondrement d'un immeuble : onde de choc, nuage de poussière, panache, gros morceaux de façade.
func collapse(b: int) -> void:
	var city = ctx.city
	var h: float = city.b_h[b]
	var sz := maxf(city.b_w[b], city.b_d[b])
	var c := Vector3(city.b_cx[b], 0.0, city.b_cz[b])
	_ring(c, sz * 1.6 + 14.0, 1.4, 0.38, 0.9)
	_glare(c + Vector3(0.0, h * 0.4, 0.0), sz * 0.4, sz * 1.3, 0.35, 0.7)
	for i in 18:
		var a := TAU * float(i) / 18.0 + _rr(-0.15, 0.15)
		var base := _footprint_pt(b, clampf(cos(a) * 0.62, -0.5, 0.5), clampf(sin(a) * 0.62, -0.5, 0.5))
		var out := Vector3(base.x - c.x, 0.0, base.z - c.z).normalized()
		_puff(base + Vector3(0.0, 3.0, 0.0), out * _rr(7.0, 15.0) + Vector3(0.0, _rr(1.0, 4.0), 0.0),
				8.0, _rr(26.0, 40.0), _rr(10.0, 15.0), 0.48, 0.85, 3.0, 0.32, 0.5)
	for i in 8:
		var o := Vector3(_rr(-0.25, 0.25) * sz, _rr(2.0, maxf(h * 0.5, 3.0)), _rr(-0.25, 0.25) * sz)
		_puff(c + o, Vector3(_rr(-2.5, 2.5), _rr(5.0, 11.0), _rr(-2.5, 2.5)), 9.0, _rr(26.0, 38.0),
				_rr(12.0, 18.0), 0.44, 1.0, 5.0, 0.3, 2.5)
	for i in 38:
		var q := _footprint_pt(b, _rr(-0.5, 0.5), _rr(-0.5, 0.5)) + Vector3(0.0, _rr(0.1, 0.9) * h, 0.0)
		var out := Vector3(q.x - c.x, 0.0, q.z - c.z).normalized()
		var v := out * _rr(5.0, 24.0) + Vector3(_rr(-3.0, 3.0), _rr(4.0, 20.0), _rr(-3.0, 3.0))
		var s := _rr(0.5, 1.8)
		debris.emit(q, v, t_fx, _rr(10.0, 16.0), s, s, rng.randf(), _rr(-5.0, 5.0), 0.0, 0.9, _rr(4.0, 8.0), 0.0)
	_sparks(c + Vector3(0.0, h * 0.6, 0.0), 22, 14.0, 45.0, 1.3, 0.6, 1.4)
	collapsing[b] = 3.0
	add_burner(b)


## Un immeuble qui brûle émet de la fumée légère tant que son feu reste vif.
func add_burner(b: int) -> void:
	if not burners.has(b):
		burners[b] = 0.0


func _emitters(dt: float) -> void:
	var bs = ctx.buildings
	var city = ctx.city
	for b in burners.keys():
		var f: float = bs.fire[b]
		var ruin: bool = bs.status[b] != 0
		if f <= (0.125 if ruin else 0.06):
			burners.erase(b)
			continue
		var acc: float = burners[b] + dt * ((0.25 + 2.0 * f) if ruin else (0.3 + 4.0 * f))
		var guard := 0
		while acc >= 1.0 and guard < 4:
			guard += 1
			acc -= 1.0
			var y: float = city.b_h[b] * (1.0 - 0.93 * bs.collapse[b])
			var p := _footprint_pt(b, _rr(-0.4, 0.4), _rr(-0.4, 0.4)) + Vector3(0.0, y, 0.0)
			_puff(p, Vector3(_rr(-0.5, 0.5), _rr(2.5, 4.5), _rr(-0.5, 0.5)), _rr(3.0, 5.0), 12.0 + 14.0 * f,
					_rr(9.0, 12.0), 0.24 + 0.24 * f, 0.8, 4.0, 0.31, 1.8)
		burners[b] = acc
	for b in collapsing.keys():
		var left: float = collapsing[b] - dt
		if left <= 0.0:
			collapsing.erase(b)
			continue
		collapsing[b] = left
		var n_new := int(round(dt * 9.0 + rng.randf() - 0.5))
		var prog: float = bs.collapse[b]
		for i in maxi(n_new, 0):
			var a := rng.randf() * TAU
			var p := _footprint_pt(b, clampf(cos(a) * 0.6, -0.5, 0.5), clampf(sin(a) * 0.6, -0.5, 0.5))
			var out := Vector3(p.x - city.b_cx[b], 0.0, p.z - city.b_cz[b]).normalized()
			p.y = maxf(city.b_h[b] * (1.0 - prog) * _rr(0.2, 1.0), 2.0)
			_puff(p, out * _rr(3.0, 9.0) + Vector3(0.0, _rr(0.5, 3.0), 0.0), 7.0, _rr(20.0, 32.0), _rr(7.0, 10.0),
					0.34, 0.85, 3.0, 0.32, 0.8)


# ---------------------------------------------------------------- mise à jour

func update(dt: float, cam: Camera3D) -> void:
	t_fx += dt
	_emitters(dt)
	smoke.flush(t_fx)
	debris.flush(t_fx)
	blast.flush(t_fx)
	sparks.flush(t_fx)

	# sprites
	for i in range(sprites.size() - 1, -1, -1):
		var s: Sp = sprites[i]
		s.age += dt
		if s.kind == 0 and s.age >= s.life:
			sprites.remove_at(i)
		elif s.kind == 1 and ctx.buildings.fire[s.b] <= 0.125:
			sprites.remove_at(i)
	var k := 0
	for s in sprites:
		var a := 0.0
		var size: float = s.size
		if s.kind == 0:
			var u: float = s.age / s.life
			a = s.power * (1.0 - u) * (1.0 - u)
			size = s.size * (0.6 + 0.8 * u)
		else:
			var f: float = ctx.buildings.fire[s.b]
			a = clampf(f * 1.3, 0.0, 1.0) * 0.85
			size = s.size * (0.85 + 0.15 * sin(s.age * 7.0 + s.sd))
		mm.set_instance_transform(k, Transform3D(Basis.from_scale(Vector3(size, size, 1.0)), s.pos))
		mm.set_instance_custom_data(k, Color(a, float(s.kind), s.sd, 0.0))
		k += 1
	mm.visible_instance_count = k

	# traceurs
	for i in range(tracers.size() - 1, -1, -1):
		var tr: Tr = tracers[i]
		tr.t += dt
		if tr.t / tr.dur - 0.14 >= 1.0:
			tracers.remove_at(i)
	tmesh.clear_surfaces()
	if tracers.is_empty():
		return
	var vp_h := get_viewport().get_visible_rect().size.y
	var cp := cam.global_position
	var tan_h := tan(deg_to_rad(ctx.gunship.fov) * 0.5)
	tmesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for tr: Tr in tracers:
		var f1 := clampf(tr.t / tr.dur, 0.0, 1.0)
		var f0 := clampf(tr.t / tr.dur - 0.14, 0.0, 1.0)
		var p0 := _arc(tr, f0)
		var p1 := _arc(tr, f1)
		var mid := (p0 + p1) * 0.5
		var px_m := 2.0 * cp.distance_to(mid) * tan_h / vp_h
		var side: Vector3 = (p1 - p0).cross(cp - mid).normalized() * (0.5 * tr.width_px * px_m)
		var c0 := Color(1.0, 1.0, 1.0, 0.0)
		var c1 := Color(1.0, 1.0, 1.0, tr.power)
		var v0 := p0 - side
		var v1 := p0 + side
		var v2 := p1 + side
		var v3 := p1 - side
		tmesh.surface_set_color(c0)
		tmesh.surface_add_vertex(v0)
		tmesh.surface_set_color(c0)
		tmesh.surface_add_vertex(v1)
		tmesh.surface_set_color(c1)
		tmesh.surface_add_vertex(v2)
		tmesh.surface_set_color(c0)
		tmesh.surface_add_vertex(v0)
		tmesh.surface_set_color(c1)
		tmesh.surface_add_vertex(v2)
		tmesh.surface_set_color(c1)
		tmesh.surface_add_vertex(v3)
	tmesh.surface_end()


func _arc(tr, f: float) -> Vector3:
	return tr.from.lerp(tr.to, f) + Vector3.UP * (tr.arc * 4.0 * f * (1.0 - f))
