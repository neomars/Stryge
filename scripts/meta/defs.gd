extends RefCounted
## Données de progression : grades, améliorations, médailles, cosmétiques (fichiers data/*.json).
## Chargées une fois et partagées par le profil, l'atelier et les écrans.

const FILES := {
	"progression": "res://data/progression.json",
	"upgrades": "res://data/upgrades.json",
	"medals": "res://data/medals.json",
	"cosmetics": "res://data/cosmetics.json",
	"campaign": "res://data/campaign.json",
	"difficulty": "res://data/difficulty.json",
	"mutators": "res://data/mutators.json",
	"zombies": "res://data/zombies.json",
	"supports": "res://data/supports.json",
	"modes": "res://data/modes.json",
}

var progression: Dictionary = {}
var grades: Array = []
var up_cats: Array = []                    # catégories de l'atelier, dans l'ordre d'affichage
var up_items: Array = []                   # améliorations, dans l'ordre du fichier
var up_by_id: Dictionary = {}
var medal_list: Array = []
var medal_by_id: Dictionary = {}
var tiers: Dictionary = {}
var slots: Array = []                      # emplacements de cosmétiques
var cos_items: Dictionary = {}             # emplacement -> liste
var cos_by_id: Dictionary = {}             # id -> élément (avec la clé « slot »)
var sectors: Array = []                    # secteurs de la campagne, dans l'ordre (voir data/campaign.json)
var sector_by_id: Dictionary = {}
var levels: Array = []                     # niveaux de difficulté, du plus facile au plus dur (voir data/difficulty.json)
var level_by_id: Dictionary = {}
var stars_available := 0                   # étoiles à gagner dans toute la campagne
var default_level := "veteran"
var first_level := "recruit"
var mutators: Array = []                   # mutateurs (voir data/mutators.json)
var mutator_by_id: Dictionary = {}
var max_mutators := 3
var zombie_types: Dictionary = {}          # infectés spéciaux : id -> paramètres (voir data/zombies.json)
var supports: Array = []                   # appuis ponctuels (voir data/supports.json)
var support_by_id: Dictionary = {}
var modes: Dictionary = {}                 # défi du jour et Nuit blanche (voir data/modes.json)
var error := ""


## Charge les fichiers de données ; retourne null (et ne plante pas) si l'un manque ou est illisible.
static func load_all() -> RefCounted:
	var d = load("res://scripts/meta/defs.gd").new()
	var raw := {}
	for k in FILES.keys():
		var f := FileAccess.open(str(FILES[k]), FileAccess.READ)
		if f == null:
			d.error = "fichier introuvable : %s" % FILES[k]
			return d
		var j = JSON.parse_string(f.get_as_text())
		if typeof(j) != TYPE_DICTIONARY:
			d.error = "fichier illisible : %s" % FILES[k]
			return d
		raw[k] = j
	d._index(raw)
	return d


func ok() -> bool:
	return error == ""


func _index(raw: Dictionary) -> void:
	progression = raw["progression"]
	grades = progression.get("grades", [])
	up_cats = raw["upgrades"].get("categories", [])
	up_items = raw["upgrades"].get("items", [])
	for it in up_items:
		up_by_id[str(it["id"])] = it
	medal_list = raw["medals"].get("medals", [])
	tiers = raw["medals"].get("tiers", {})
	for m in medal_list:
		medal_by_id[str(m["id"])] = m
	slots = raw["cosmetics"].get("slots", [])
	var items: Dictionary = raw["cosmetics"].get("items", {})
	for s in slots:
		var sid := str(s["id"])
		var lst: Array = items.get(sid, [])
		cos_items[sid] = lst
		for c in lst:
			c["slot"] = sid
			cos_by_id[str(c["id"])] = c
	sectors = raw["campaign"].get("sectors", [])
	for sc in sectors:
		sector_by_id[str(sc["id"])] = sc
		var f := FileAccess.open("res://data/%s" % str(sc["file"]), FileAccess.READ)
		var mj = JSON.parse_string(f.get_as_text()) if f != null else null
		if typeof(mj) != TYPE_DICTIONARY:
			error = "mission introuvable ou illisible : %s" % str(sc["file"])
			return
		sc["n_stars"] = (mj.get("stars", []) as Array).size()
		stars_available += int(sc["n_stars"])
	levels = raw["difficulty"].get("levels", [])
	for i in levels.size():
		levels[i]["index"] = i
		level_by_id[str(levels[i]["id"])] = levels[i]
	default_level = str(raw["difficulty"].get("default", "veteran"))
	first_level = str(raw["difficulty"].get("first_play", "recruit"))
	mutators = raw["mutators"].get("mutators", [])
	max_mutators = int(raw["mutators"].get("max_active", 3))
	for m in mutators:
		mutator_by_id[str(m["id"])] = m
	zombie_types = raw["zombies"].get("types", {})
	supports = raw["supports"].get("supports", [])
	for sp in supports:
		support_by_id[str(sp["id"])] = sp
	modes = raw["modes"]


func grade_count() -> int:
	return grades.size()


func upgrades_in(cat: String) -> Array:
	var out: Array = []
	for it in up_items:
		if str(it["cat"]) == cat:
			out.append(it)
	return out


## Nombre total de niveaux achetables dans l'atelier.
func total_upgrade_levels() -> int:
	var n := 0
	for it in up_items:
		n += (it["levels"] as Array).size()
	return n


func default_equipped() -> Dictionary:
	var out := {}
	for s in slots:
		var sid := str(s["id"])
		for c in cos_items.get(sid, []):
			if c.get("unlock", {}).has("default"):
				out[sid] = str(c["id"])
				break
	return out


# ---------------------------------------------------------------- campagne

func sector(id: String) -> Dictionary:
	return sector_by_id.get(id, {})


func sector_index(id: String) -> int:
	for i in sectors.size():
		if str(sectors[i]["id"]) == id:
			return i
	return -1


## Niveau de difficulté par identifiant (le niveau par défaut si l'identifiant est inconnu).
func level(id: String) -> Dictionary:
	if level_by_id.has(id):
		return level_by_id[id]
	return level_by_id.get(default_level, levels[0] if not levels.is_empty() else {})


func level_index(id: String) -> int:
	return int(level(id).get("index", 0))


# ---------------------------------------------------------------- mutateurs, infectés spéciaux, appuis, modes

func mutator(id: String) -> Dictionary:
	return mutator_by_id.get(id, {})


func support(id: String) -> Dictionary:
	return support_by_id.get(id, {})


func zombie_type(id: String) -> Dictionary:
	return zombie_types.get(id, {})


## Mode « défi du jour » ou « Nuit blanche » (dictionnaire de data/modes.json).
func mode_cfg(id: String) -> Dictionary:
	return modes.get(id, {})
