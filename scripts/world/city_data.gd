extends RefCounted
## Format de ville commun au générateur procédural et au convertisseur de cartes réelles (tools/city).
## Repère local en mètres : X = est, Z = sud, Y = haut, origine au centre de la zone.
## Les portes sont calculées au chargement (StreetGraph.snap_doors) sauf si le fichier les fournit (« doors »).
##
## pnc-city-1 : réseau (nodes/edges), emprises (buildings), zones rectangulaires (areas).
## pnc-city-2 : en plus — drapeau de pont et classe « chemin » sur les tronçons, maillages triangulés de l'eau et des parcs
##              (mesh), repères nommés (places), portes précalculées (doors).

const FORMAT := "pnc-city-1"
const FORMAT2 := "pnc-city-2"
const CLASS_STREET := 0
const CLASS_BOULEVARD := 1
const CLASS_PATH := 2        # chemin : pas de trottoir
const FLAG_BRIDGE := 1

var meta: Dictionary = {"name": "ParisLite", "size": [2400.0, 2400.0]}

# Réseau routier
var nodes := PackedVector2Array()
var edge_a := PackedInt32Array()
var edge_b := PackedInt32Array()
var edge_w := PackedFloat32Array()      # largeur de chaussée (m)
var edge_class := PackedInt32Array()    # 0 = rue, 1 = boulevard, 2 = chemin (sans trottoir)
var edge_flag := PackedInt32Array()     # bit 0 = pont (pnc-city-2 ; 0 partout ailleurs)

# Immeubles : emprise rectangulaire orientée
# (centre, largeur sur X local, profondeur sur Z local, lacet en rad autour de Y, hauteur, habitants)
var b_cx := PackedFloat32Array()
var b_cz := PackedFloat32Array()
var b_w := PackedFloat32Array()
var b_d := PackedFloat32Array()
var b_yaw := PackedFloat32Array()
var b_h := PackedFloat32Array()
var b_occ := PackedInt32Array()

# Portes (calculées, pas stockées dans le JSON)
var b_door_edge := PackedInt32Array()
var b_door_t := PackedFloat32Array()
var b_door_pos := PackedVector2Array()
var b_door_off := PackedFloat32Array()   # décalage latéral signé par rapport à l'axe du tronçon (m)

# Zones : [type, x0, z0, x1, z1] avec type = "park" | "water" | "evac"
var areas: Array = []
# Maillages triangulés (villes réelles) : sommets (x, z) et indices de triangles
var water_v := PackedVector2Array()
var water_i := PackedInt32Array()
var park_v := PackedVector2Array()
var park_i := PackedInt32Array()
# Repères nommés : [{n, x, z, k, r}] (k = monument | gare | stade | parc | eau | place)
var places: Array = []
# Portes précalculées par le convertisseur : par immeuble, le tronçon et la position (x, z) de la porte
var pre_door_edge := PackedInt32Array()
var pre_door_pos := PackedVector2Array()
# Points d'évacuation (indices de nœuds)
var evac_nodes := PackedInt32Array()
# Bouches de métro (indices de nœuds) : des infectés peuvent en surgir (vagues « metro »)
var metro_nodes := PackedInt32Array()


func size_m() -> Vector2:
	var s: Array = meta.get("size", [2400.0, 2400.0])
	return Vector2(float(s[0]), float(s[1]))


func building_count() -> int:
	return b_cx.size()


func add_building(cx: float, cz: float, w: float, d: float, yaw: float, h: float, occ: int) -> int:
	b_cx.append(cx)
	b_cz.append(cz)
	b_w.append(w)
	b_d.append(d)
	b_yaw.append(yaw)
	b_h.append(h)
	b_occ.append(occ)
	return b_cx.size() - 1


func is_real() -> bool:
	return str(meta.get("style", "")) == "real"


func has_extras() -> bool:
	return not water_v.is_empty() or not park_v.is_empty() or not places.is_empty() or not pre_door_edge.is_empty() \
			or (not edge_flag.is_empty() and edge_flag.count(0) != edge_flag.size())


func _mesh_dict(v: PackedVector2Array, ix: PackedInt32Array) -> Dictionary:
	var a: Array = []
	for p in v:
		a.append(snappedf(p.x, 0.1))
		a.append(snappedf(p.y, 0.1))
	var t: Array = []
	for k in ix:
		t.append(k)
	return {"v": a, "i": t}


func to_dict() -> Dictionary:
	var n: Array = []
	for v in nodes:
		n.append([snappedf(v.x, 0.01), snappedf(v.y, 0.01)])
	var extras := has_extras()
	var e: Array = []
	for i in edge_a.size():
		var row := [edge_a[i], edge_b[i], snappedf(edge_w[i], 0.1), edge_class[i]]
		if extras:
			row.append(edge_flag[i] if i < edge_flag.size() else 0)
		e.append(row)
	var b: Array = []
	for i in b_cx.size():
		b.append([snappedf(b_cx[i], 0.01), snappedf(b_cz[i], 0.01), snappedf(b_w[i], 0.01),
				snappedf(b_d[i], 0.01), snappedf(b_yaw[i], 0.0001), snappedf(b_h[i], 0.1), b_occ[i]])
	var ev: Array = []
	for k in evac_nodes:
		ev.append(k)
	var mt: Array = []
	for k in metro_nodes:
		mt.append(k)
	var d := {"format": FORMAT2 if extras else FORMAT, "meta": meta, "nodes": n, "edges": e, "buildings": b,
			"areas": areas, "evac_nodes": ev, "metro_nodes": mt}
	if extras:
		var mesh := {}
		if not water_v.is_empty():
			mesh["water"] = _mesh_dict(water_v, water_i)
		if not park_v.is_empty():
			mesh["park"] = _mesh_dict(park_v, park_i)
		d["mesh"] = mesh
		d["places"] = places
		if pre_door_edge.size() == b_cx.size():
			var dr: Array = []
			for i in pre_door_edge.size():
				dr.append(pre_door_edge[i])
				dr.append(snappedf(pre_door_pos[i].x, 0.01))
				dr.append(snappedf(pre_door_pos[i].y, 0.01))
			d["doors"] = dr
	return d


static func _read_mesh(m: Dictionary) -> Array:
	var v := PackedVector2Array()
	var ix := PackedInt32Array()
	var a: Array = m.get("v", [])
	for k in range(0, a.size() - 1, 2):
		v.append(Vector2(float(a[k]), float(a[k + 1])))
	for k in m.get("i", []):
		ix.append(int(k))
	return [v, ix]


func from_dict(d: Dictionary) -> bool:
	var fmt := str(d.get("format", ""))
	if fmt != FORMAT and fmt != FORMAT2:
		return false
	meta = d.get("meta", meta)
	nodes = PackedVector2Array()
	for v in d["nodes"]:
		nodes.append(Vector2(float(v[0]), float(v[1])))
	edge_a = PackedInt32Array()
	edge_b = PackedInt32Array()
	edge_w = PackedFloat32Array()
	edge_class = PackedInt32Array()
	edge_flag = PackedInt32Array()
	for e in d["edges"]:
		edge_a.append(int(e[0]))
		edge_b.append(int(e[1]))
		edge_w.append(float(e[2]))
		edge_class.append(int(e[3]))
		edge_flag.append(int(e[4]) if e.size() > 4 else 0)
	b_cx = PackedFloat32Array()
	b_cz = PackedFloat32Array()
	b_w = PackedFloat32Array()
	b_d = PackedFloat32Array()
	b_yaw = PackedFloat32Array()
	b_h = PackedFloat32Array()
	b_occ = PackedInt32Array()
	for b in d["buildings"]:
		add_building(float(b[0]), float(b[1]), float(b[2]), float(b[3]), float(b[4]), float(b[5]), int(b[6]))
	areas = d.get("areas", [])
	evac_nodes = PackedInt32Array()
	for k in d.get("evac_nodes", []):
		evac_nodes.append(int(k))
	metro_nodes = PackedInt32Array()
	for k in d.get("metro_nodes", []):
		metro_nodes.append(int(k))
	water_v = PackedVector2Array()
	water_i = PackedInt32Array()
	park_v = PackedVector2Array()
	park_i = PackedInt32Array()
	var mesh: Dictionary = d.get("mesh", {})
	if mesh.has("water"):
		var w := _read_mesh(mesh["water"])
		water_v = w[0]
		water_i = w[1]
	if mesh.has("park"):
		var p := _read_mesh(mesh["park"])
		park_v = p[0]
		park_i = p[1]
	places = []
	for pl in d.get("places", []):
		places.append({"n": str(pl["n"]), "x": float(pl["x"]), "z": float(pl["z"]), "k": str(pl.get("k", "place")),
				"r": float(pl.get("r", 90.0))})
	pre_door_edge = PackedInt32Array()
	pre_door_pos = PackedVector2Array()
	var dr: Array = d.get("doors", [])
	if dr.size() == b_cx.size() * 3:
		for i in b_cx.size():
			pre_door_edge.append(int(dr[i * 3]))
			pre_door_pos.append(Vector2(float(dr[i * 3 + 1]), float(dr[i * 3 + 2])))
	return true


## Repère nommé le plus proche d'un point (dans son rayon), "" si aucun.
func place_at(x: float, z: float) -> String:
	var best := ""
	var best_s := 1.0
	for pl in places:
		var s: float = Vector2(pl["x"] - x, pl["z"] - z).length() / maxf(float(pl["r"]), 1.0)
		if s < best_s:
			best_s = s
			best = pl["n"]
	return best


func save_json(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict()))
	return true


func load_json(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	return from_dict(parsed)
