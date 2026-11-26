extends RefCounted
## Construit les maillages de la ville : sol, routes, parcs, eau, points d'évacuation, immeubles (MultiMesh).

const GROUND_SHADER := preload("res://shaders/thermal_ground.gdshader")
const BUILDING_SHADER := preload("res://shaders/thermal_building.gdshader")

# Chaleur de base (0 = froid, 1 = très chaud). Valeurs choisies pour que les personnes (≈1,0) ressortent.
const H_GROUND := 0.25
const H_SIDEWALK := 0.285
const H_ROAD := 0.335
const CLASS_PATH := 2       # mêmes valeurs que CityData.CLASS_PATH / FLAG_BRIDGE
const FLAG_BRIDGE := 1
const H_PATH := 0.30        # chemin sans trottoir (cartes réelles)
const H_BRIDGE := 0.35      # tablier d'un pont : un peu plus chaud que l'eau et la chaussée voisine
const H_PARK := 0.17
const H_WATER := 0.075
const H_EVAC := 0.62
const H_METRO := 0.78      # grille d'aération du métro : l'air chaud sort


class MB:
	var v := PackedVector3Array()
	var c := PackedColorArray()
	var idx := PackedInt32Array()

	func quad(a: Vector3, b: Vector3, cc: Vector3, d: Vector3, col: Color) -> void:
		var o := v.size()
		v.append(a)
		v.append(b)
		v.append(cc)
		v.append(d)
		c.append(col)
		c.append(col)
		c.append(col)
		c.append(col)
		idx.append(o)
		idx.append(o + 1)
		idx.append(o + 2)
		idx.append(o)
		idx.append(o + 2)
		idx.append(o + 3)

	func rect(x0: float, z0: float, x1: float, z1: float, y: float, col: Color) -> void:
		quad(Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), col)

	## Maillage triangulé (eau, parcs des villes réelles) : sommets (x, z), indices de triangles.
	func tris(pts: PackedVector2Array, ix: PackedInt32Array, y: float, col: Color) -> void:
		var o := v.size()
		for p in pts:
			v.append(Vector3(p.x, y, p.y))
			c.append(col)
		for k in ix:
			idx.append(o + k)

	func strip(a: Vector2, b: Vector2, ext_a: float, ext_b: float, hw: float, y: float, col: Color) -> void:
		var d := (b - a).normalized()
		var n := d.orthogonal() * hw
		var a2 := a - d * ext_a
		var b2 := b + d * ext_b
		quad(Vector3(a2.x - n.x, y, a2.y - n.y), Vector3(b2.x - n.x, y, b2.y - n.y),
				Vector3(b2.x + n.x, y, b2.y + n.y), Vector3(a2.x + n.x, y, a2.y + n.y), col)

	func to_mesh() -> ArrayMesh:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_COLOR] = c
		arrays[Mesh.ARRAY_INDEX] = idx
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return m


var root: Node3D
var city = null
var b_mm: MultiMesh = null
var _atmos_mats: Array = []     # matériaux dont l'atténuation atmosphérique (atmos_k) suit la météo (brouillard)


func build(parent: Node3D, p_city, graph) -> void:
	city = p_city
	root = Node3D.new()
	root.name = "City"
	parent.add_child(root)
	_build_ground(graph)
	_build_buildings()


func _col(heat: float, amp: float, water: float = 0.0) -> Color:
	return Color(heat, amp, water, 1.0)


func _build_ground(graph) -> void:
	var mb := MB.new()
	var sz: Vector2 = city.size_m()
	var far := maxf(sz.x, sz.y) * 2.5
	mb.rect(-far, -far, far, far, 0.0, _col(H_GROUND, 1.0))

	# demi-largeur max des rues à chaque nœud, pour couvrir les carrefours
	var node_hw := PackedFloat32Array()
	node_hw.resize(graph.node_pos.size())
	for e in graph.ea.size():
		var hw: float = graph.ew[e] * 0.5
		node_hw[graph.ea[e]] = maxf(node_hw[graph.ea[e]], hw)
		node_hw[graph.eb[e]] = maxf(node_hw[graph.eb[e]], hw)
	# eau et parcs des cartes réelles : maillages triangulés, posés sous les trottoirs et les chaussées
	if not city.water_v.is_empty():
		mb.tris(city.water_v, city.water_i, 0.02, _col(H_WATER, 0.5, 1.0))
	if not city.park_v.is_empty():
		mb.tris(city.park_v, city.park_i, 0.06, _col(H_PARK, 1.6))
	var has_flags: bool = city.edge_flag.size() == graph.ea.size()
	for e in graph.ea.size():
		if city.edge_class[e] == CLASS_PATH:
			continue                                   # chemin : pas de trottoir
		var a: Vector2 = graph.node_pos[graph.ea[e]]
		var b: Vector2 = graph.node_pos[graph.eb[e]]
		var ea_x: float = node_hw[graph.ea[e]] + 3.0
		var eb_x: float = node_hw[graph.eb[e]] + 3.0
		mb.strip(a, b, ea_x, eb_x, graph.ew[e] * 0.5 + 3.0, 0.04, _col(H_SIDEWALK, 0.9))
	for e in graph.ea.size():
		var a2: Vector2 = graph.node_pos[graph.ea[e]]
		var b2: Vector2 = graph.node_pos[graph.eb[e]]
		var heat_r := H_ROAD
		if city.edge_class[e] == CLASS_PATH:
			heat_r = H_PATH
		elif has_flags and (city.edge_flag[e] & FLAG_BRIDGE) != 0:
			heat_r = H_BRIDGE
		mb.strip(a2, b2, node_hw[graph.ea[e]], node_hw[graph.eb[e]], graph.ew[e] * 0.5, 0.08, _col(heat_r, 0.8))

	for a in city.areas:
		var kind: String = a[0]
		var x0: float = a[1]
		var z0: float = a[2]
		var x1: float = a[3]
		var z1: float = a[4]
		match kind:
			"park":
				mb.rect(x0, z0, x1, z1, 0.06, _col(H_PARK, 1.6))
			"water":
				mb.rect(x0, z0, x1, z1, 0.02, _col(H_WATER, 0.5, 1.0))
			"evac":
				mb.rect(x0, z0, x1, z1, 0.12, _col(H_EVAC, 0.5))
			"metro":
				mb.rect(x0, z0, x1, z1, 0.14, _col(H_METRO, 0.9))

	var mi := MeshInstance3D.new()
	mi.name = "Ground"
	mi.mesh = mb.to_mesh()
	var mat := ShaderMaterial.new()
	mat.shader = GROUND_SHADER
	mi.material_override = mat
	_atmos_mats.append(mat)
	mi.custom_aabb = AABB(Vector3(-far, -1.0, -far), Vector3(far * 2.0, 2.0, far * 2.0))
	root.add_child(mi)


func _unit_cube() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var idx := PackedInt32Array()
	for nrm in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]:
		var t1: Vector3 = nrm.cross(Vector3.UP) if absf(nrm.y) < 0.5 else Vector3.RIGHT
		var t2: Vector3 = nrm.cross(t1)
		var c: Vector3 = Vector3(0.0, 0.5, 0.0) + nrm * 0.5
		var o := v.size()
		v.append(c - t1 * 0.5 - t2 * 0.5)
		v.append(c + t1 * 0.5 - t2 * 0.5)
		v.append(c + t1 * 0.5 + t2 * 0.5)
		v.append(c - t1 * 0.5 + t2 * 0.5)
		for k in 4:
			n.append(nrm)
		idx.append(o)
		idx.append(o + 1)
		idx.append(o + 2)
		idx.append(o)
		idx.append(o + 2)
		idx.append(o + 3)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _build_buildings() -> void:
	var n: int = city.building_count()
	b_mm = MultiMesh.new()
	b_mm.transform_format = MultiMesh.TRANSFORM_3D
	b_mm.use_custom_data = true
	b_mm.mesh = _unit_cube()
	b_mm.instance_count = n
	var sz: Vector2 = city.size_m()
	b_mm.custom_aabb = AABB(Vector3(-sz.x, -20.0, -sz.y), Vector3(sz.x * 2.0, 400.0, sz.y * 2.0))
	for i in n:
		var basis := Basis(Vector3.UP, city.b_yaw[i]) * Basis.from_scale(Vector3(city.b_w[i], city.b_h[i], city.b_d[i]))
		b_mm.set_instance_transform(i, Transform3D(basis, Vector3(city.b_cx[i], 0.0, city.b_cz[i])))
		var occ_frac := 0.02
		if city.b_occ[i] > 0:
			occ_frac = 0.05 + 0.33
		b_mm.set_instance_custom_data(i, Color(occ_frac, 0.0, 0.0, 0.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Buildings"
	mmi.multimesh = b_mm
	var mat := ShaderMaterial.new()
	mat.shader = BUILDING_SHADER
	mmi.material_override = mat
	_atmos_mats.append(mat)
	root.add_child(mmi)


## Atténuation atmosphérique de la chaleur du sol et des immeubles (0,00005 par défaut ; le brouillard la multiplie).
func set_atmos(k: float) -> void:
	for m in _atmos_mats:
		m.set_shader_parameter("atmos_k", k)


## Données d'instance : (fenêtres habitées, fenêtres infestées, effondrement, feu). `alert` (0 ou 1) : immeuble à raser, à dessiner en
## rouge ; il est codé dans la première composante (+ 2,0 : les fenêtres habitées n'en dépassent jamais 0,4), que le shader décode.
func set_state(i: int, occ_frac: float, inf_frac: float, collapse: float, fire: float, alert: float = 0.0) -> void:
	if b_mm != null:
		b_mm.set_instance_custom_data(i, Color(occ_frac + 2.0 * alert, inf_frac, collapse, fire))
