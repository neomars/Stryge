extends RefCounted
## Maillage humanoïde (environ 2 600 triangles avec les accessoires), articulé dans le vertex shader.
##
## Repère : pieds en y = 0, taille 1,8 m, regard vers -Z, +X = côté droit du personnage.
## Attributs par sommet (la couleur de sommet est évitée : le moteur la mélange aux données d'instance) :
##   UV.x    accessoire : 0 = corps, sinon A_* ; le shader replie les accessoires non portés sur leur pivot
##   UV.y    cavité 0..1 : creux du corps (aisselle, entrejambe, col) plus chauds car moins rayonnants
##   UV2.x   identifiant d'os B_*, lu par shaders/thermal_human.gdshader
##   UV2.y   zone de chaleur R_* (peau, haut, manches, jambes, chaussures, cheveux...)
## Les positions des articulations sont recopiées dans le shader : si on les change ici, les changer là-bas.

const B_PELVIS := 0
const B_TORSO := 1
const B_HEAD := 2
const B_UARM_R := 3
const B_LARM_R := 4
const B_UARM_L := 5
const B_LARM_L := 6
const B_ULEG_R := 7
const B_LLEG_R := 8
const B_FOOT_R := 9
const B_ULEG_L := 10
const B_LLEG_L := 11
const B_FOOT_L := 12

const R_SKIN := 0
const R_TOP := 1
const R_SLEEVE_UP := 2
const R_SLEEVE_LO := 3
const R_HAND := 4
const R_PANTS_UP := 5
const R_PANTS_LO := 6
const R_SHOE := 7
const R_HAIR := 8
const R_COAT := 9
const R_PACK := 10
const R_HAT := 11

const A_BASE := 0
const A_HOOD := 1
const A_PACK := 2
const A_COAT := 3
const A_LONG := 4
const A_PONY := 5
const A_CAP := 6

var _v := PackedVector3Array()
var _n := PackedVector3Array()
var _uv := PackedVector2Array()
var _uv2 := PackedVector2Array()
var _i := PackedInt32Array()


func build() -> ArrayMesh:
	_v.clear()
	_n.clear()
	_uv.clear()
	_uv2.clear()
	_i.clear()
	_build_body()
	_build_accessories()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _v
	arrays[Mesh.ARRAY_NORMAL] = _n
	arrays[Mesh.ARRAY_TEX_UV] = _uv
	arrays[Mesh.ARRAY_TEX_UV2] = _uv2
	arrays[Mesh.ARRAY_INDEX] = _i
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	m.custom_aabb = AABB(Vector3(-1.4, -0.3, -1.4), Vector3(2.8, 2.6, 2.8))
	return m


func triangle_count() -> int:
	return _i.size() / 3


# ---------------------------------------------------------------- corps

func _build_body() -> void:
	# bassin : de l'entrejambe à la ceinture
	_loft([
		[0.78, 0.0, 0.004, 0.085, 0.070, R_PANTS_UP, 0.9],
		[0.86, 0.0, 0.012, 0.145, 0.102, R_PANTS_UP, 0.25],
		[0.95, 0.0, 0.010, 0.158, 0.106, R_PANTS_UP, 0.0],
		[1.03, 0.0, 0.002, 0.140, 0.093, R_TOP, 0.0],
		[1.08, 0.0, 0.0, 0.135, 0.090, R_TOP, 0.0],
	], 10, B_PELVIS, R_TOP, A_BASE, true, false)

	# buste : taille, côtes, poitrine, épaules, base du cou
	_loft([
		[1.02, 0.0, 0.0, 0.136, 0.090, R_TOP, 0.0],
		[1.12, 0.0, -0.003, 0.140, 0.092, R_TOP, 0.0],
		[1.24, 0.0, -0.008, 0.158, 0.100, R_TOP, 0.0],
		[1.33, 0.0, -0.012, 0.176, 0.110, R_TOP, 0.0],
		[1.41, 0.0, -0.006, 0.186, 0.103, R_TOP, 0.25],
		[1.47, 0.0, 0.0, 0.120, 0.082, R_TOP, 0.10],
		[1.515, 0.0, 0.0, 0.058, 0.056, R_TOP, 0.35],
	], 10, B_TORSO, R_TOP, A_BASE, false, true)

	# cou, puis tête (le cou suit la tête : même os)
	_loft([
		[1.455, 0.0, 0.004, 0.056, 0.056, R_SKIN, 0.4],
		[1.58, 0.0, 0.008, 0.050, 0.052, R_SKIN, 0.2],
	], 8, B_HEAD, R_SKIN, A_BASE, false, false)
	_head(Vector3(0.0, 1.69, 0.0), Vector3(0.084, 0.112, 0.098))

	for side in [1.0, -1.0]:
		var sx: float = side
		var r: bool = sx > 0.0
		var b_ua := B_UARM_R if r else B_UARM_L
		var b_la := B_LARM_R if r else B_LARM_L
		var b_ul := B_ULEG_R if r else B_ULEG_L
		var b_ll := B_LLEG_R if r else B_LLEG_L
		var b_ft := B_FOOT_R if r else B_FOOT_L

		# --- bras : épaule arrondie, bras, coude, avant-bras, main
		_ellipsoid(Vector3(sx * 0.192, 1.425, 0.0), Vector3(0.062, 0.062, 0.062), 5, 8, b_ua, R_SLEEVE_UP, A_BASE, 0.0)
		_loft([
			[1.43, sx * 0.194, 0.0, 0.058, 0.058, R_SLEEVE_UP, 0.0],
			[1.39, sx * 0.198, 0.0, 0.056, 0.056, R_SLEEVE_UP, 0.45],
			[1.30, sx * 0.202, 0.0, 0.049, 0.050, R_SLEEVE_UP, 0.0],
			[1.20, sx * 0.206, 0.0, 0.043, 0.044, R_SLEEVE_UP, 0.0],
			[1.14, sx * 0.208, 0.0, 0.041, 0.042, R_SLEEVE_UP, 0.1],
		], 8, b_ua, R_SLEEVE_UP, A_BASE, false, false)
		_ellipsoid(Vector3(sx * 0.208, 1.14, 0.0), Vector3(0.042, 0.042, 0.043), 4, 8, b_la, R_SLEEVE_LO, A_BASE, 0.0)
		_loft([
			[1.14, sx * 0.208, 0.0, 0.041, 0.042, R_SLEEVE_LO, 0.0],
			[1.06, sx * 0.209, 0.0, 0.042, 0.042, R_SLEEVE_LO, 0.0],
			[0.98, sx * 0.210, 0.0, 0.036, 0.035, R_SLEEVE_LO, 0.0],
			[0.90, sx * 0.211, 0.0, 0.029, 0.026, R_SLEEVE_LO, 0.0],
			[0.865, sx * 0.211, 0.0, 0.027, 0.024, R_HAND, 0.15],
		], 8, b_la, R_SLEEVE_LO, A_BASE, false, false)
		# main : paume, phalanges, bout des doigts légèrement repliés
		_loft([
			[0.870, sx * 0.211, 0.0, 0.028, 0.023, R_HAND, 0.1],
			[0.835, sx * 0.211, -0.002, 0.041, 0.019, R_HAND, 0.0],
			[0.780, sx * 0.211, -0.007, 0.041, 0.016, R_HAND, 0.0],
			[0.730, sx * 0.211, -0.014, 0.034, 0.013, R_HAND, 0.0],
			[0.695, sx * 0.211, -0.022, 0.020, 0.010, R_HAND, 0.0],
		], 6, b_la, R_HAND, A_BASE, false, true)
		# pouce
		_loft([
			[0.850, sx * 0.182, -0.016, 0.014, 0.014, R_HAND, 0.0],
			[0.800, sx * 0.184, -0.026, 0.012, 0.012, R_HAND, 0.0],
			[0.765, sx * 0.188, -0.030, 0.008, 0.008, R_HAND, 0.0],
		], 5, b_la, R_HAND, A_BASE, false, true)

		# --- jambes : hanche, cuisse, genou, mollet, pied
		_ellipsoid(Vector3(sx * 0.092, 0.935, 0.0), Vector3(0.088, 0.075, 0.090), 4, 8, b_ul, R_PANTS_UP, A_BASE, 0.0)
		_loft([
			[0.96, sx * 0.092, 0.0, 0.086, 0.088, R_PANTS_UP, 0.0],
			[0.86, sx * 0.093, 0.004, 0.083, 0.088, R_PANTS_UP, 0.0],
			[0.74, sx * 0.094, 0.0, 0.072, 0.077, R_PANTS_UP, 0.0],
			[0.62, sx * 0.094, -0.002, 0.060, 0.064, R_PANTS_UP, 0.0],
			[0.52, sx * 0.094, -0.004, 0.052, 0.056, R_PANTS_UP, 0.2],
		], 10, b_ul, R_PANTS_UP, A_BASE, false, false)
		_ellipsoid(Vector3(sx * 0.094, 0.50, -0.004), Vector3(0.052, 0.050, 0.054), 4, 8, b_ll, R_PANTS_LO, A_BASE, 0.0)
		_loft([
			[0.50, sx * 0.094, -0.004, 0.051, 0.054, R_PANTS_LO, 0.0],
			[0.42, sx * 0.095, 0.006, 0.054, 0.058, R_PANTS_LO, 0.0],
			[0.30, sx * 0.095, 0.004, 0.046, 0.048, R_PANTS_LO, 0.0],
			[0.18, sx * 0.095, 0.0, 0.037, 0.039, R_PANTS_LO, 0.0],
			[0.095, sx * 0.095, 0.0, 0.038, 0.040, R_PANTS_LO, 0.0],
		], 8, b_ll, R_PANTS_LO, A_BASE, false, false)
		_ellipsoid(Vector3(sx * 0.095, 0.085, 0.0), Vector3(0.040, 0.040, 0.042), 4, 8, b_ft, R_PANTS_LO, A_BASE, 0.0)
		# chaussure : talon, cheville, cambrure, avant-pied, bout (anneaux le long de Z : z, x, y, rx, ry)
		_loft_z([
			[0.062, sx * 0.095, 0.045, 0.030, 0.034],
			[0.020, sx * 0.095, 0.052, 0.038, 0.046],
			[-0.040, sx * 0.095, 0.040, 0.043, 0.038],
			[-0.110, sx * 0.095, 0.032, 0.046, 0.030],
			[-0.185, sx * 0.095, 0.026, 0.040, 0.024],
			[-0.235, sx * 0.095, 0.020, 0.026, 0.017],
		], 8, b_ft, R_SHOE, true, true)


## Tête : ellipsoïde au menton resserré, léger nez ; visage et dessous du menton en peau, crâne en cheveux.
func _head(c: Vector3, r: Vector3) -> void:
	var lat := 8
	var lon := 12
	var base := _v.size()
	for i in range(lat + 1):
		var th := PI * float(i) / float(lat)
		for j in lon:
			var ph := TAU * float(j) / float(lon)
			var n := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
			var jaw := 1.0 + 0.30 * minf(n.y, 0.0)
			var p := c + Vector3(n.x * r.x * jaw, n.y * r.y, n.z * r.z * jaw)
			var front := clampf(-n.z, 0.0, 1.0)
			p.z -= 0.020 * smoothstep(0.80, 1.0, front) * exp(-pow((n.y + 0.02) / 0.22, 2.0))
			var nn := Vector3(n.x / r.x, n.y / r.y, n.z / r.z)
			var skin: bool = n.y < -0.35 or (n.z < -0.15 and n.y < 0.55)
			_vert(p, nn, B_HEAD, R_SKIN if skin else R_HAIR, A_BASE, 0.0)
	for i in range(lat):
		for j in lon:
			var j2 := (j + 1) % lon
			var a := base + i * lon + j
			var b := base + i * lon + j2
			var d := base + (i + 1) * lon + j
			var e := base + (i + 1) * lon + j2
			_tri(a, b, e)
			_tri(a, e, d)


# ---------------------------------------------------------------- accessoires

func _build_accessories() -> void:
	# capuche : coque autour du crâne, ouverte sur le visage, et col roulé autour du cou
	_ellipsoid(Vector3(0.0, 1.69, 0.025), Vector3(0.112, 0.138, 0.128), 6, 12, B_HEAD, R_COAT, A_HOOD, 0.0, true)
	_loft([
		[1.60, 0.0, 0.022, 0.092, 0.090, R_COAT, 0.0],
		[1.50, 0.0, 0.028, 0.125, 0.105, R_COAT, 0.0],
		[1.42, 0.0, 0.020, 0.150, 0.110, R_COAT, 0.0],
	], 10, B_HEAD, R_COAT, A_HOOD, false, false)

	# casquette : dôme et visière
	_dome(Vector3(0.0, 1.715, 0.0), Vector3(0.092, 0.088, 0.104), 4, 10, B_HEAD, R_HAT, A_CAP)
	_ellipsoid(Vector3(0.0, 1.742, -0.100), Vector3(0.080, 0.007, 0.062), 3, 8, B_HEAD, R_HAT, A_CAP, 0.0)

	# cheveux longs, queue de cheval
	_loft([
		[1.77, 0.0, 0.050, 0.090, 0.062, R_HAIR, 0.0],
		[1.69, 0.0, 0.076, 0.098, 0.074, R_HAIR, 0.0],
		[1.59, 0.0, 0.092, 0.088, 0.056, R_HAIR, 0.0],
		[1.49, 0.0, 0.100, 0.078, 0.042, R_HAIR, 0.0],
		[1.39, 0.0, 0.104, 0.066, 0.032, R_HAIR, 0.0],
	], 8, B_HEAD, R_HAIR, A_LONG, false, true)
	_loft([
		[1.75, 0.0, 0.100, 0.026, 0.026, R_HAIR, 0.0],
		[1.67, 0.0, 0.134, 0.032, 0.032, R_HAIR, 0.0],
		[1.57, 0.0, 0.150, 0.026, 0.026, R_HAIR, 0.0],
		[1.49, 0.0, 0.153, 0.012, 0.012, R_HAIR, 0.0],
	], 6, B_HEAD, R_HAIR, A_PONY, false, true)

	# sac à dos
	_loft([
		[1.12, 0.0, 0.158, 0.118, 0.056, R_PACK, 0.0],
		[1.25, 0.0, 0.175, 0.146, 0.082, R_PACK, 0.0],
		[1.38, 0.0, 0.172, 0.142, 0.076, R_PACK, 0.0],
		[1.46, 0.0, 0.158, 0.104, 0.056, R_PACK, 0.0],
	], 10, B_TORSO, R_PACK, A_PACK, true, true)

	# pan de manteau : nappe en arc dans le dos et sur les côtés, du bassin aux genoux
	var rows := 6
	var cols := 9
	var base := _v.size()
	for rw in rows:
		var t := float(rw) / float(rows - 1)
		var y := lerpf(1.04, 0.56, t)
		var rx := lerpf(0.120, 0.222, t)
		var rz := lerpf(0.100, 0.175, t)
		for cl in cols:
			var a := lerpf(-1.75, 1.75, float(cl) / float(cols - 1))
			var p := Vector3(rx * sin(a), y, 0.004 + rz * cos(a))
			var nn := Vector3(sin(a) / rx, 0.35 * (0.2 + t), cos(a) / rz)
			_vert(p, nn, B_PELVIS, R_COAT, A_COAT, 0.0)
	for rw in range(rows - 1):
		for cl in range(cols - 1):
			var a0 := base + rw * cols + cl
			var b0 := a0 + 1
			var c0 := a0 + cols
			var d0 := c0 + 1
			_tri(a0, c0, d0)
			_tri(a0, d0, b0)


# ---------------------------------------------------------------- primitives

func _vert(p: Vector3, n: Vector3, bone: int, region: int, acc: int, cav: float) -> int:
	_v.append(p)
	_n.append(n.normalized())
	_uv.append(Vector2(float(acc), cav))
	_uv2.append(Vector2(float(bone), float(region)))
	return _v.size() - 1


func _tri(a: int, b: int, c: int) -> void:
	_i.append(a)
	_i.append(b)
	_i.append(c)


## Solide de révolution elliptique le long de Y. Anneaux : [y, cx, cz, rx, rz, zone, cavité] (zone et cavité facultatives).
func _loft(rings: Array, sides: int, bone: int, region: int, acc: int, cap_bottom: bool, cap_top: bool) -> void:
	var nr := rings.size()
	var base := _v.size()
	for r in nr:
		var rg: Array = rings[r]
		var rp: Array = rings[maxi(r - 1, 0)]
		var rn: Array = rings[mini(r + 1, nr - 1)]
		var reg: int = int(rg[5]) if rg.size() > 5 else region
		var cav: float = float(rg[6]) if rg.size() > 6 else 0.0
		var dy: float = float(rn[0]) - float(rp[0])
		var rx: float = float(rg[3])
		var rz: float = float(rg[4])
		var drx: float = (float(rn[3]) - float(rp[3])) / maxf(absf(dy), 0.001) * signf(dy if dy != 0.0 else 1.0)
		var drz: float = (float(rn[4]) - float(rp[4])) / maxf(absf(dy), 0.001) * signf(dy if dy != 0.0 else 1.0)
		for s in sides:
			var a := TAU * float(s) / float(sides)
			var ca := cos(a)
			var sa := sin(a)
			var p := Vector3(float(rg[1]) + rx * ca, float(rg[0]), float(rg[2]) + rz * sa)
			var n := Vector3(rz * ca, -(rz * drx * ca * ca + rx * drz * sa * sa), rx * sa)
			_vert(p, n, bone, reg, acc, cav)
	for r in nr - 1:
		for s in sides:
			var s2 := (s + 1) % sides
			var a0 := base + r * sides + s
			var b0 := base + r * sides + s2
			var c0 := base + (r + 1) * sides + s2
			var d0 := base + (r + 1) * sides + s
			_tri(a0, d0, c0)
			_tri(a0, c0, b0)
	if cap_bottom:
		_cap(rings[0], sides, bone, region, acc, false)
	if cap_top:
		_cap(rings[nr - 1], sides, bone, region, acc, true)


func _cap(rg: Array, sides: int, bone: int, region: int, acc: int, up: bool) -> void:
	var ny := 1.0 if up else -1.0
	var reg: int = int(rg[5]) if rg.size() > 5 else region
	var cav: float = float(rg[6]) if rg.size() > 6 else 0.0
	var c := _vert(Vector3(float(rg[1]), float(rg[0]), float(rg[2])), Vector3(0.0, ny, 0.0), bone, reg, acc, cav)
	var first := _v.size()
	for s in sides:
		var a := TAU * float(s) / float(sides)
		_vert(Vector3(float(rg[1]) + float(rg[3]) * cos(a), float(rg[0]), float(rg[2]) + float(rg[4]) * sin(a)),
				Vector3(0.0, ny, 0.0), bone, reg, acc, cav)
	for s in sides:
		var s2 := (s + 1) % sides
		if up:
			_tri(c, first + s2, first + s)
		else:
			_tri(c, first + s, first + s2)


## Solide elliptique le long de Z (pied). Anneaux : [z, cx, cy, rx, ry].
func _loft_z(rings: Array, sides: int, bone: int, region: int, cap_front: bool, cap_back: bool) -> void:
	var nr := rings.size()
	var base := _v.size()
	for r in nr:
		var rg: Array = rings[r]
		var rp: Array = rings[maxi(r - 1, 0)]
		var rn: Array = rings[mini(r + 1, nr - 1)]
		var dz: float = float(rn[0]) - float(rp[0])
		var rx: float = float(rg[3])
		var ry: float = float(rg[4])
		var sg: float = signf(dz if dz != 0.0 else 1.0)
		var drx: float = (float(rn[3]) - float(rp[3])) / maxf(absf(dz), 0.001) * sg
		var dry: float = (float(rn[4]) - float(rp[4])) / maxf(absf(dz), 0.001) * sg
		for s in sides:
			var a := TAU * float(s) / float(sides)
			var ca := cos(a)
			var sa := sin(a)
			var p := Vector3(float(rg[1]) + rx * ca, float(rg[2]) + ry * sa, float(rg[0]))
			var n := Vector3(ry * ca, rx * sa, -(rx * dry * sa * sa + ry * drx * ca * ca))
			_vert(p, n, bone, region, A_BASE, 0.0)
	for r in nr - 1:
		for s in sides:
			var s2 := (s + 1) % sides
			var a0 := base + r * sides + s
			var b0 := base + r * sides + s2
			var c0 := base + (r + 1) * sides + s2
			var d0 := base + (r + 1) * sides + s
			_tri(a0, d0, c0)
			_tri(a0, c0, b0)
	if cap_back:
		_cap_z(rings[0], sides, bone, region, 1.0)
	if cap_front:
		_cap_z(rings[nr - 1], sides, bone, region, -1.0)


func _cap_z(rg: Array, sides: int, bone: int, region: int, nz: float) -> void:
	var c := _vert(Vector3(float(rg[1]), float(rg[2]), float(rg[0])), Vector3(0.0, 0.0, nz), bone, region, A_BASE, 0.0)
	var first := _v.size()
	for s in sides:
		var a := TAU * float(s) / float(sides)
		_vert(Vector3(float(rg[1]) + float(rg[3]) * cos(a), float(rg[2]) + float(rg[4]) * sin(a), float(rg[0])),
				Vector3(0.0, 0.0, nz), bone, region, A_BASE, 0.0)
	for s in sides:
		var s2 := (s + 1) % sides
		if nz > 0.0:
			_tri(c, first + s2, first + s)
		else:
			_tri(c, first + s, first + s2)


## Ellipsoïde complète (ou coque de capuche si `hood` : on omet les quads de l'ouverture du visage).
func _ellipsoid(c: Vector3, r: Vector3, lat: int, lon: int, bone: int, region: int, acc: int, cav: float,
		hood: bool = false) -> void:
	var base := _v.size()
	for i in range(lat + 1):
		var th := PI * float(i) / float(lat)
		for j in lon:
			var ph := TAU * float(j) / float(lon)
			var n := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
			_vert(c + Vector3(n.x * r.x, n.y * r.y, n.z * r.z), Vector3(n.x / r.x, n.y / r.y, n.z / r.z),
					bone, region, acc, cav)
	for i in range(lat):
		for j in lon:
			var j2 := (j + 1) % lon
			if hood:
				var th_m := PI * (float(i) + 0.5) / float(lat)
				var ph_m := TAU * (float(j) + 0.5) / float(lon)
				var nz := sin(th_m) * sin(ph_m)
				var ny := cos(th_m)
				if nz < -0.42 and ny < 0.62 and ny > -0.55:
					continue
			var a := base + i * lon + j
			var b := base + i * lon + j2
			var d := base + (i + 1) * lon + j
			var e := base + (i + 1) * lon + j2
			_tri(a, b, e)
			_tri(a, e, d)


## Calotte (moitié haute d'un ellipsoïde).
func _dome(c: Vector3, r: Vector3, lat: int, lon: int, bone: int, region: int, acc: int) -> void:
	var base := _v.size()
	for i in range(lat + 1):
		var th := 0.5 * PI * float(i) / float(lat)
		for j in lon:
			var ph := TAU * float(j) / float(lon)
			var n := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
			_vert(c + Vector3(n.x * r.x, n.y * r.y, n.z * r.z), Vector3(n.x / r.x, n.y / r.y, n.z / r.z),
					bone, region, acc, 0.0)
	for i in range(lat):
		for j in lon:
			var j2 := (j + 1) % lon
			var a := base + i * lon + j
			var b := base + i * lon + j2
			var d := base + (i + 1) * lon + j
			var e := base + (i + 1) * lon + j2
			_tri(a, b, e)
			_tri(a, e, d)
