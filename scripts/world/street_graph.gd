extends RefCounted
## Graphe routier : nœuds (intersections), arêtes (tronçons), A*, accrochage des portes.
## Une entité se déplace sur une arête : (edge, t ∈ [0,1], décalage latéral en m).

const CELL := 128.0

var node_pos := PackedVector2Array()
var ea := PackedInt32Array()
var eb := PackedInt32Array()
var ew := PackedFloat32Array()
var elen := PackedFloat32Array()
var edir := PackedVector2Array()
var adj: Array = []            # par nœud : Array d'indices d'arêtes
var astar := AStar2D.new()
var _egrid := {}


static func _key(cx: int, cz: int) -> int:
	return (cx + 1024) * 4096 + (cz + 1024)


func build(city) -> void:
	node_pos = city.nodes
	ea = city.edge_a
	eb = city.edge_b
	ew = city.edge_w
	var n := node_pos.size()
	var m := ea.size()
	astar.clear()
	adj.clear()
	for i in n:
		astar.add_point(i, node_pos[i])
		adj.append([])
	elen = PackedFloat32Array()
	elen.resize(m)
	edir = PackedVector2Array()
	edir.resize(m)
	_egrid.clear()
	for e in m:
		var pa: Vector2 = node_pos[ea[e]]
		var pb: Vector2 = node_pos[eb[e]]
		var d := pb - pa
		var l := d.length()
		elen[e] = l
		edir[e] = d / maxf(l, 0.001)
		astar.connect_points(ea[e], eb[e], true)
		adj[ea[e]].append(e)
		adj[eb[e]].append(e)
		var x0 := int(floor(minf(pa.x, pb.x) / CELL))
		var x1 := int(floor(maxf(pa.x, pb.x) / CELL))
		var z0 := int(floor(minf(pa.y, pb.y) / CELL))
		var z1 := int(floor(maxf(pa.y, pb.y) / CELL))
		for cx in range(x0, x1 + 1):
			for cz in range(z0, z1 + 1):
				var k := _key(cx, cz)
				if not _egrid.has(k):
					_egrid[k] = []
				_egrid[k].append(e)


func pos_on_edge(e: int, t: float, off: float) -> Vector2:
	var a: Vector2 = node_pos[ea[e]]
	var b: Vector2 = node_pos[eb[e]]
	return a.lerp(b, t) + edir[e].orthogonal() * off


func edge_between(a: int, b: int) -> int:
	for e in adj[a]:
		if (ea[e] == a and eb[e] == b) or (ea[e] == b and eb[e] == a):
			return e
	return -1


## Arête la plus proche d'un point : [edge, t, distance].
## Recherche par anneaux de cases autour du point ; s'arrête dès qu'aucune case non explorée ne peut contenir mieux.
func nearest_edge(p: Vector2, max_ring: int = 40) -> Array:
	var cx := int(floor(p.x / CELL))
	var cz := int(floor(p.y / CELL))
	var best_e := -1
	var best_t := 0.0
	var best_d := INF
	for ring in range(0, max_ring + 1):
		if ring >= 2 and best_e >= 0 and best_d <= float(ring - 1) * CELL:
			break
		for dx in range(-ring, ring + 1):
			for dz in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dz)) != ring:
					continue
				var lst = _egrid.get(_key(cx + dx, cz + dz))
				if lst == null:
					continue
				for e in lst:
					var a: Vector2 = node_pos[ea[e]]
					var ab: Vector2 = node_pos[eb[e]] - a
					var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
					var d := (a + ab * t).distance_to(p)
					if d < best_d:
						best_d = d
						best_e = e
						best_t = t
	return [best_e, best_t, best_d]


## Objectif (arête, t) pour atteindre un nœud.
func node_goal(n: int) -> Array:
	var e: int = adj[n][0]
	return [e, 0.0 if ea[e] == n else 1.0]


## Itinéraire d'une position (e0, t0) vers (e1, t1).
## Retourne {ok, dir, nodes} : dir = sens initial sur e0, nodes = nœuds à traverser dans l'ordre.
func plan(e0: int, t0: float, e1: int, t1: float) -> Dictionary:
	if e0 == e1:
		return {"ok": true, "dir": 1 if t1 >= t0 else -1, "nodes": PackedInt32Array()}
	var best := INF
	var best_dir := 1
	var best_nodes := PackedInt32Array()
	for s in 2:
		var n_start: int = eb[e0] if s == 0 else ea[e0]
		var c0: float = (1.0 - t0) * elen[e0] if s == 0 else t0 * elen[e0]
		if c0 >= best:
			continue
		for g in 2:
			var n_end: int = ea[e1] if g == 0 else eb[e1]
			var c1: float = t1 * elen[e1] if g == 0 else (1.0 - t1) * elen[e1]
			if c0 + c1 >= best:
				continue
			var path := astar.get_id_path(n_start, n_end)
			if path.is_empty():
				continue
			var cost := c0 + c1
			for k in range(1, path.size()):
				cost += node_pos[path[k - 1]].distance_to(node_pos[path[k]])
			if cost < best:
				best = cost
				best_dir = 1 if s == 0 else -1
				best_nodes = PackedInt32Array()
				for k in path.size():
					best_nodes.append(path[k])
	return {"ok": best < INF, "dir": best_dir, "nodes": best_nodes}


## Calcule porte, arête et décalage latéral de chaque immeuble.
## Une ville réelle fournit ses portes précalculées (pre_door_*) : on ne fait alors que les valider.
func snap_doors(city) -> void:
	var n: int = city.building_count()
	city.b_door_edge = PackedInt32Array()
	city.b_door_t = PackedFloat32Array()
	city.b_door_pos = PackedVector2Array()
	city.b_door_off = PackedFloat32Array()
	city.b_door_edge.resize(n)
	city.b_door_t.resize(n)
	city.b_door_pos.resize(n)
	city.b_door_off.resize(n)
	var pre: bool = city.pre_door_edge.size() == n
	var m := ea.size()
	for i in n:
		if pre:
			var pe: int = city.pre_door_edge[i]
			if pe >= 0 and pe < m:
				var pa: Vector2 = node_pos[ea[pe]]
				var pab: Vector2 = node_pos[eb[pe]] - pa
				var pdoor: Vector2 = city.pre_door_pos[i]
				var pt: float = clampf((pdoor - pa).dot(pab) / maxf(pab.length_squared(), 0.0001), 0.0, 1.0)
				city.b_door_edge[i] = pe
				city.b_door_t[i] = pt
				city.b_door_pos[i] = pdoor
				city.b_door_off[i] = (pdoor - (pa + pab * pt)).dot(edir[pe].orthogonal())
				continue
		var c := Vector2(city.b_cx[i], city.b_cz[i])
		var ne := nearest_edge(c)
		var e: int = ne[0]
		if e < 0:
			e = 0               # graphe sans aucun tronçon proche : cas dégénéré, jamais atteint avec une vraie carte
		var a: Vector2 = node_pos[ea[e]]
		var ab: Vector2 = node_pos[eb[e]] - a
		var t: float = ne[1]
		var q := a + ab * t
		var dv := q - c
		var yaw: float = city.b_yaw[i]
		var cs := cos(yaw)
		var sn := sin(yaw)
		var lx := dv.x * cs - dv.y * sn
		var lz := dv.x * sn + dv.y * cs
		var hx: float = city.b_w[i] * 0.5
		var hz: float = city.b_d[i] * 0.5
		var tb := INF
		if absf(lx) > 0.0001:
			tb = minf(tb, hx / absf(lx))
		if absf(lz) > 0.0001:
			tb = minf(tb, hz / absf(lz))
		if tb == INF:
			tb = 0.0
		tb = minf(tb, 1.0)
		var dl := Vector2(lx, lz) * tb
		var door := c + Vector2(dl.x * cs + dl.y * sn, -dl.x * sn + dl.y * cs)
		var t2 := clampf((door - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		var foot := a + ab * t2
		city.b_door_edge[i] = e
		city.b_door_t[i] = t2
		city.b_door_pos[i] = door
		city.b_door_off[i] = (door - foot).dot(edir[e].orthogonal())
