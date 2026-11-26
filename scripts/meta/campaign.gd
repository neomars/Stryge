extends RefCounted
## Campagne : déblocage des secteurs par les étoiles, choix du secteur de départ, chargement d'une mission
## et application d'un niveau de difficulté. Fonctions statiques : l'état vit dans le profil (settings, missions),
## les données dans Defs (secteurs, niveaux).

const MISSION_DIR := "res://data/"
const RUNNER_MAX := 0.7


# ---------------------------------------------------------------- déblocage

## Étoiles cumulées dans les secteurs de la campagne (meilleur résultat de chaque condition d'étoile).
static func total_stars(_defs, prof) -> int:
	return prof.sector_stars()


static func is_unlocked(defs, prof, id: String) -> bool:
	var sc: Dictionary = defs.sector(id)
	return not sc.is_empty() and total_stars(defs, prof) >= int(sc.get("unlock", 0))


## Étoiles qu'il manque pour ouvrir le secteur (0 s'il est ouvert).
static func stars_missing(defs, prof, id: String) -> int:
	var sc: Dictionary = defs.sector(id)
	if sc.is_empty():
		return 0
	return maxi(int(sc.get("unlock", 0)) - total_stars(defs, prof), 0)


## Identifiants des secteurs ouverts, dans l'ordre de la campagne.
static func unlocked_ids(defs, prof) -> Array:
	var out: Array = []
	for sc in defs.sectors:
		if is_unlocked(defs, prof, str(sc["id"])):
			out.append(str(sc["id"]))
	return out


## Secteurs que ce résultat vient d'ouvrir : ouverts avec `stars_after` étoiles et pas avec `stars_before`.
static func newly_unlocked(defs, stars_before: int, stars_after: int) -> Array:
	var out: Array = []
	for sc in defs.sectors:
		var u := int(sc.get("unlock", 0))
		if stars_before < u and stars_after >= u:
			out.append(str(sc["id"]))
	return out


## Prochain secteur fermé (le moins cher en étoiles), ou {}.
static func next_locked(defs, prof) -> Dictionary:
	var best := {}
	for sc in defs.sectors:
		if not is_unlocked(defs, prof, str(sc["id"])):
			if best.is_empty() or int(sc["unlock"]) < int(best["unlock"]):
				best = sc
	return best


## Secteur proposé au lancement : le dernier joué s'il est ouvert, sinon le premier.
static func start_sector(defs, prof) -> String:
	var last := str(prof.settings.get("sector", ""))
	if last != "" and is_unlocked(defs, prof, last):
		return last
	return str(defs.sectors[0]["id"]) if not defs.sectors.is_empty() else ""


## Difficulté proposée au lancement :
##  - le niveau que le joueur a choisi lui-même (réglage « picked » : bouton du briefing, carte de campagne, modes) ;
##  - sinon, tant qu'il n'a gagné aucune mission, le niveau de « première partie » (Recrue) : un niveau enregistré tout seul
##    par une partie perdue ne doit pas enfermer un débutant dans le réglage de référence ;
##  - sinon le dernier niveau joué, ou à défaut le niveau par défaut.
static func start_level(defs, prof) -> String:
	var last := str(prof.settings.get("difficulty", ""))
	var valid: bool = defs.level_by_id.has(last)
	if valid and bool(prof.settings.get("picked", false)):
		return last
	if int(prof.stats.get("wins", 0)) == 0:
		return defs.first_level
	if valid:
		return last
	return defs.default_level


# ---------------------------------------------------------------- missions

## Lit le fichier d'une mission de la campagne ({} s'il est absent ou illisible).
static func load_mission(defs, id: String) -> Dictionary:
	var sc: Dictionary = defs.sector(id)
	var path: String = MISSION_DIR + str(sc["file"]) if not sc.is_empty() else MISSION_DIR + id + ".json"
	return load_file(path)


static func load_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var j = JSON.parse_string(f.get_as_text())
	return j if typeof(j) == TYPE_DICTIONARY else {}


## Arrondit v au multiple de `step` (à partir de `lo`) le plus proche, dans [lo, hi] : les nombres annoncés par la radio
## doivent rester des valeurs que la voix sait prononcer.
static func snap(v: float, lo: int, hi: int, step: int) -> int:
	var k := int(round((v - float(lo)) / float(step)))
	return clampi(lo + k * step, lo, hi)


## Copie de la mission transformée par un niveau de difficulté (voir data/difficulty.json). La mission d'origine n'est pas touchée.
## La copie porte la clé « difficulty » (le niveau lui-même : id, nom, indicateur d'impact, multiplicateurs de récompense).
static func apply_difficulty(base: Dictionary, lv: Dictionary) -> Dictionary:
	var m: Dictionary = base.duplicate(true)
	var wm := float(lv.get("waves", 1.0))
	m["max_civilians_lost"] = maxi(int(round(float(base.get("max_civilians_lost", 25)) * float(lv.get("lost", 1.0)))), 1)
	m["start_zombies"] = maxi(int(round(float(base.get("start_zombies", 30)) * float(lv.get("start", 1.0)))), 0)
	m["collateral_weight"] = clampf(float(lv.get("collat", 1.0)), 0.0, 1.0)
	# vagues réservées à une difficulté plus haute (clé « min_level » : 0 Recrue, 1 Vétéran, 2 Cauchemar) : elles sont retirées
	var lvl := int(lv.get("index", 1))
	var kept: Array = []
	for w in m.get("waves", []):
		if int(w.get("min_level", 0)) <= lvl:
			kept.append(w)
	if m.has("waves"):
		m["waves"] = kept
	for w in m.get("waves", []):
		match str(w.get("type", "streets")):
			"assault":
				w["zombies"] = maxi(int(round(float(w.get("zombies", 4)) * wm)), 2)
			"breach":
				w["count"] = maxi(int(round(float(w.get("count", 1)) * wm)), 1)
			"special":
				pass                  # les infectés spéciaux ne suivent pas le multiplicateur d'effectif
			_:
				w["count"] = maxi(int(round(float(w.get("count", 10)) * wm)), 3)
	var r: Dictionary = m.get("rules", {})
	if r.has("zombie_hp"):
		r["zombie_hp"] = float(r["zombie_hp"]) * float(lv.get("hp", 1.0))
	if r.has("runner_ratio"):
		r["runner_ratio"] = clampf(float(r["runner_ratio"]) * float(lv.get("runners", 1.0)), 0.0, RUNNER_MAX)
	for k in ["door_hp_min", "door_hp_max"]:
		if r.has(k):
			r[k] = float(r[k]) * float(lv.get("doors", 1.0))
	# repas des infectés enfermés avec des civils : plus lents aux niveaux faciles ; répit avant le premier repas d'une intrusion
	r["eat_interval_s"] = float(r.get("eat_interval_s", 9.0)) * float(lv.get("eat", 1.0))
	r["breach_grace_s"] = float(lv.get("grace", 0.0))
	m["rules"] = r
	for o in m.get("objectives", []):
		if str(o.get("kind", "secondary")) == "hidden":
			continue
		match str(o.get("type", "")):
			"hunt":
				o["count"] = snap(float(o["count"]) * wm, 10, 40, 5)
			"intercept":
				o["count"] = snap(float(o["count"]) * wm, 8, 30, 2)
			"hold":
				o["zombies"] = maxi(int(round(float(o.get("zombies", 4)) * wm)), 2)
				for rf in o.get("reinforce", []):
					rf["zombies"] = maxi(int(round(float(rf["zombies"]) * wm)), 1)
			"evac":
				o["zombies"] = maxi(int(round(float(o.get("zombies", 1)) * wm)), 1)
	m["difficulty"] = lv.duplicate(true)
	return m
