extends RefCounted
## Générateur de ville de test « ParisLite » : trame de rues à largeurs variables,
## îlots haussmanniens (immeubles de 4 à 8 niveaux en périmètre, cour intérieure), parcs, fleuve.
## Ce n'est PAS Paris : il sert à développer le jeu en attendant l'import de données réelles
## (même format de sortie, voir CityData).

const CityData = preload("res://scripts/world/city_data.gd")
const SIDEWALK := 3.0

## Variantes de secteur. Chaque clé absente prend la valeur du style « latin » (la ville d'origine ; la même graine donne
## exactement la même ville qu'avant l'ajout des styles).
##   bx, bz : largeur des îlots (m) selon X et Z ; narrow : largeur des rues ordinaires ; wide_p, wide : part et largeur des boulevards ;
##   depth : épaisseur des immeubles en bordure d'îlot ; lv_shift : décalage du nombre d'étages ; park_p : part d'îlots en parc ;
##   river : fleuve sur la rangée centrale ; occ_mult, occ_max : habitants ; tower_p, tower_r, tower_lv : tours de bureaux (La Défense),
##   dans un rayon tower_r autour du centre ; hole : rayon sans rues autour du centre (un grand îlot) ; stadium : tribunes dans
##   ce grand îlot ; metro : nombre de bouches de métro.
const STYLE_DEFAULT := {
	"bx": [70.0, 135.0], "bz": [55.0, 100.0], "narrow": [9.0, 15.0], "wide_p": 0.14, "wide": [24.0, 32.0],
	"depth": [12.0, 17.0], "lv_shift": 0, "park_p": 0.07, "river": true, "occ_mult": 1.0, "occ_max": 40,
	"tower_p": 0.0, "tower_r": 0.0, "tower_lv": [12, 40], "hole": 0.0, "stadium": false, "metro": 0,
}
const STYLES := {
	"latin": {},
	"montmartre": {"bx": [48.0, 92.0], "bz": [42.0, 80.0], "narrow": [5.5, 9.5], "wide_p": 0.05, "wide": [20.0, 26.0],
			"depth": [9.0, 13.0], "lv_shift": -1, "park_p": 0.05, "river": false, "occ_mult": 0.9},
	"halles": {"lv_shift": 0, "occ_mult": 1.0, "park_p": 0.03, "metro": 12},
	"defense": {"bx": [115.0, 190.0], "bz": [100.0, 170.0], "wide_p": 0.6, "wide": [24.0, 36.0], "depth": [14.0, 20.0],
			"river": false, "park_p": 0.04, "tower_p": 0.3, "tower_r": 700.0, "tower_lv": [10, 26], "occ_max": 80, "occ_mult": 0.65},
	"stade": {"river": false, "hole": 130.0, "stadium": true, "park_p": 0.05},
}

var rng := RandomNumberGenerator.new()
var P: Dictionary = {}


static func style_names() -> Array:
	return STYLES.keys()


func generate(seed_value: int, size_m: float = 2400.0, style: String = "latin"):
	rng.seed = seed_value
	P = STYLE_DEFAULT.duplicate(true)
	P.merge(STYLES.get(style, {}), true)
	var city = CityData.new()
	city.meta = {"name": "ParisLite", "seed": seed_value, "size": [size_m, size_m],
			"origin_lonlat": [2.3522, 48.8566], "style": style}
	var lx := _lines(size_m, float(P["bx"][0]), float(P["bx"][1]), float(P["hole"]))
	var lz := _lines(size_m, float(P["bz"][0]), float(P["bz"][1]), float(P["hole"]))
	var xs: PackedFloat32Array = lx["pos"]
	var xw: PackedFloat32Array = lx["w"]
	var zs: PackedFloat32Array = lz["pos"]
	var zw: PackedFloat32Array = lz["w"]
	var nx := xs.size()
	var nz := zs.size()

	# Intersections et tronçons
	for i in nx:
		for j in nz:
			city.nodes.append(Vector2(xs[i], zs[j]))
	for i in nx:
		for j in nz:
			var id := i * nz + j
			if i + 1 < nx:
				city.edge_a.append(id)
				city.edge_b.append((i + 1) * nz + j)
				city.edge_w.append(zw[j])
				city.edge_class.append(1 if zw[j] >= 22.0 else 0)
			if j + 1 < nz:
				city.edge_a.append(id)
				city.edge_b.append(id + 1)
				city.edge_w.append(xw[i])
				city.edge_class.append(1 if xw[i] >= 22.0 else 0)

	# Îlots
	var river_row := int((nz - 1) / 2) if bool(P["river"]) else -1
	for i in nx - 1:
		for j in nz - 1:
			var x0 := xs[i] + xw[i] * 0.5 + SIDEWALK
			var x1 := xs[i + 1] - xw[i + 1] * 0.5 - SIDEWALK
			var z0 := zs[j] + zw[j] * 0.5 + SIDEWALK
			var z1 := zs[j + 1] - zw[j + 1] * 0.5 - SIDEWALK
			if x1 - x0 < 18.0 or z1 - z0 < 18.0:
				continue
			if j == river_row:
				city.areas.append(["water", x0 - SIDEWALK, z0 - SIDEWALK, x1 + SIDEWALK, z1 + SIDEWALK])
				continue
			if bool(P["stadium"]) and x0 < 0.0 and x1 > 0.0 and z0 < 0.0 and z1 > 0.0:
				_stadium(city, x0, z0, x1, z1)
				continue
			if rng.randf() < float(P["park_p"]):
				city.areas.append(["park", x0, z0, x1, z1])
				continue
			_fill_block(city, x0, z0, x1, z1)

	_pick_evac(city, size_m)
	if int(P["metro"]) > 0:
		_pick_metro(city, size_m, int(P["metro"]))
	return city


func _street_w() -> float:
	if rng.randf() < float(P["wide_p"]):
		return rng.randf_range(float(P["wide"][0]), float(P["wide"][1]))
	return rng.randf_range(float(P["narrow"][0]), float(P["narrow"][1]))


func _lines(size_m: float, bmin: float, bmax: float, hole: float = 0.0) -> Dictionary:
	var pos := PackedFloat32Array()
	var wid := PackedFloat32Array()
	var half := size_m * 0.5
	var w := _street_w()
	var p := -half + w * 0.5
	pos.append(p)
	wid.append(w)
	while true:
		var block := rng.randf_range(bmin, bmax)
		var w2 := _street_w()
		var p2 := p + w * 0.5 + block + w2 * 0.5
		if p2 + w2 * 0.5 > half:
			break
		if hole > 0.0 and absf(p2) < hole + w2 * 0.5:
			p = p2          # rue supprimée au centre : l'îlot central s'élargit
			w = w2
			continue
		pos.append(p2)
		wid.append(w2)
		p = p2
		w = w2
	return {"pos": pos, "w": wid}


func _base_levels() -> int:
	var r := rng.randf()
	if r < 0.15:
		return 4
	if r < 0.45:
		return 5
	if r < 0.80:
		return 6
	return 7


func _split(total: float, wmin: float, wmax: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var rest := total
	while rest > wmax * 1.15:
		var w := rng.randf_range(wmin, wmax)
		out.append(w)
		rest -= w
	if rest < wmin * 0.7 and out.size() > 0:
		out[out.size() - 1] += rest
	else:
		out.append(rest)
	return out


func _fill_block(city, x0: float, z0: float, x1: float, z1: float) -> void:
	var bx := x1 - x0
	var bz := z1 - z0
	var ld := rng.randf_range(float(P["depth"][0]), float(P["depth"][1]))
	var lv := _base_levels()
	if bx < 2.0 * ld + 10.0 or bz < 2.0 * ld + 10.0:
		# îlot étroit : bâtiments pleins le long de la plus grande dimension
		if bx >= bz:
			_row_x(city, x0, x1, z0, z1, lv)
		else:
			_row_z(city, z0, z1, x0, x1, lv)
		return
	_row_x(city, x0, x1, z0, z0 + ld, lv)
	_row_x(city, x0, x1, z1 - ld, z1, lv)
	_row_z(city, z0 + ld, z1 - ld, x0, x0 + ld, lv)
	_row_z(city, z0 + ld, z1 - ld, x1 - ld, x1, lv)


func _row_x(city, xa: float, xb: float, za: float, zb: float, base_levels: int) -> void:
	var x := xa
	for w in _split(xb - xa, 9.0, 20.0):
		_add(city, x + w * 0.5, (za + zb) * 0.5, w - 0.5, zb - za, base_levels)
		x += w


func _row_z(city, za: float, zb: float, xa: float, xb: float, base_levels: int) -> void:
	var z := za
	for d in _split(zb - za, 9.0, 20.0):
		_add(city, (xa + xb) * 0.5, z + d * 0.5, xb - xa, d - 0.5, base_levels)
		z += d


func _add(city, cx: float, cz: float, w: float, d: float, base_levels: int) -> void:
	var lv := base_levels + int(P["lv_shift"])
	if rng.randf() < 0.3:
		lv += rng.randi_range(-1, 1)
	if float(P["tower_r"]) > 0.0 and Vector2(cx, cz).length() < float(P["tower_r"]):
		if rng.randf() < float(P["tower_p"]):
			lv += rng.randi_range(int(P["tower_lv"][0]), int(P["tower_lv"][1]))      # tour de bureaux
	elif rng.randf() < 0.006:
		lv += rng.randi_range(6, 14)      # tour rare
	lv = maxi(lv, 3)
	var h := lv * 3.1 + rng.randf_range(0.5, 2.0)
	var occ := 0
	if rng.randf() > 0.10:
		occ = clampi(roundi(lv * rng.randf_range(0.6, 1.5) * float(P["occ_mult"])), 1, int(P["occ_max"]))
	city.add_building(cx, cz, w, d, 0.0, h, occ)


## Stade : quatre tribunes collées au pourtour du grand îlot central (leur porte donne donc sur la rue), pelouse au milieu.
## Chaque tribune est un immeuble très peuplé : la foule du stade.
func _stadium(city, x0: float, z0: float, x1: float, z1: float) -> void:
	var cx := (x0 + x1) * 0.5
	var cz := (z0 + z1) * 0.5
	var dp := 26.0
	var w := x1 - x0
	var d := z1 - z0
	city.areas.append(["park", x0 + dp, z0 + dp, x1 - dp, z1 - dp])
	city.add_building(cx, z0 + dp * 0.5, w - 0.5, dp, 0.0, 33.0, 240)
	city.add_building(cx, z1 - dp * 0.5, w - 0.5, dp, 0.0, 33.0, 240)
	city.add_building(x0 + dp * 0.5, cz, dp, d - 2.0 * dp - 0.5, 0.0, 29.0, 160)
	city.add_building(x1 - dp * 0.5, cz, dp, d - 2.0 * dp - 0.5, 0.0, 29.0, 160)


## Bouches de métro : n nœuds du réseau, espacés d'au moins 200 m, dans la partie centrale de la carte.
func _pick_metro(city, size_m: float, n: int) -> void:
	var tries := 0
	while city.metro_nodes.size() < n and tries < 2000:
		tries += 1
		var i := rng.randi_range(0, city.nodes.size() - 1)
		var p: Vector2 = city.nodes[i]
		if absf(p.x) > size_m * 0.42 or absf(p.y) > size_m * 0.42 or city.metro_nodes.has(i):
			continue
		var ok := true
		for k in city.metro_nodes:
			if (city.nodes[k] as Vector2).distance_to(p) < 200.0:
				ok = false
				break
		if ok:
			city.metro_nodes.append(i)
			city.areas.append(["metro", p.x - 3.0, p.y - 3.0, p.x + 3.0, p.y + 3.0])


func _pick_evac(city, size_m: float) -> void:
	# 9 points de rassemblement répartis en grille 3 × 3 (≈ 800 m les uns des autres)
	var targets: Array = []
	for gx in [-0.33, 0.0, 0.33]:
		for gz in [-0.33, 0.0, 0.33]:
			targets.append(Vector2(gx, gz))
	for tg in targets:
		var want: Vector2 = tg * size_m
		var best := -1
		var bd := INF
		for i in city.nodes.size():
			var d: float = city.nodes[i].distance_squared_to(want)
			if d < bd:
				bd = d
				best = i
		if best >= 0 and not city.evac_nodes.has(best):
			city.evac_nodes.append(best)
			var p: Vector2 = city.nodes[best]
			city.areas.append(["evac", p.x - 16.0, p.y - 16.0, p.x + 16.0, p.y + 16.0])
