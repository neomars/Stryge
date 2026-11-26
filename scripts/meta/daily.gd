extends RefCounted
## Défi du jour : un scénario par date (secteur, graine de la ville, graine des vagues, mutateurs), tiré de la date seule.
## Il est donc le même pour tous les joueurs et à chaque nouvel essai du jour. Réglages : data/modes.json (clé « daily »).

const Mutators := preload("res://scripts/meta/mutators.gd")


## Date du jour au format AAAA-MM-JJ (heure locale). `--daily=AAAA-MM-JJ` la remplace (essais, captures).
static func today() -> String:
	return Time.get_date_string_from_system()


## Graine entière de 32 bits tirée d'un texte (FNV-1a) : stable d'une machine et d'une version à l'autre.
static func seed_of(text: String) -> int:
	var h := 2166136261
	for b in text.to_utf8_buffer():
		h = ((h ^ int(b)) * 16777619) & 0xFFFFFFFF
	return h


static func valid_date(date: String) -> bool:
	var parts := date.split("-")
	if parts.size() != 3 or parts[0].length() != 4 or parts[1].length() != 2 or parts[2].length() != 2:
		return false
	if not (parts[0].is_valid_int() and parts[1].is_valid_int() and parts[2].is_valid_int()):
		return false
	var mo := int(parts[1])
	var dy := int(parts[2])
	return mo >= 1 and mo <= 12 and dy >= 1 and dy <= 31


## Veille d'une date (AAAA-MM-JJ). Vide si la date est invalide.
static func previous_day(date: String) -> String:
	if not valid_date(date):
		return ""
	var t := Time.get_unix_time_from_datetime_string(date + "T12:00:00")
	return Time.get_date_string_from_unix_time(int(t) - 86400)


## Scénario du jour : {date, sector, level, mutators, seed (ville), wave_seed (vagues)}.
static func plan(defs, date: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_of("png-daily-" + date)
	var cfg: Dictionary = defs.mode_cfg("daily")
	var sectors: Array = defs.sectors
	var sector := str(sectors[rng.randi_range(0, sectors.size() - 1)]["id"]) if not sectors.is_empty() else ""
	# nombre de mutateurs : probabilités [aucun, un, deux]
	var probs: Array = cfg.get("mutators", [0.35, 0.45, 0.20])
	var roll := rng.randf()
	var n := 0
	var acc := 0.0
	for i in probs.size():
		acc += float(probs[i])
		if roll < acc:
			n = i
			break
		n = i
	# mutateurs tirés sans remise (mélange de Fisher-Yates avec le même générateur), incompatibilités écartées
	var pool: Array = []
	for m in defs.mutators:
		pool.append(str(m["id"]))
	for i in range(pool.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = pool[i]
		pool[i] = pool[j]
		pool[j] = tmp
	var ids: Array = []
	for id in pool:
		if ids.size() >= n:
			break
		var cand: Array = ids.duplicate()
		cand.append(id)
		if Mutators.clean(defs, cand).size() == cand.size():
			ids = cand
	return {
		"date": date, "sector": sector, "level": str(cfg.get("level", defs.default_level)), "mutators": ids,
		"seed": 1000 + rng.randi() % 90000, "wave_seed": rng.randi(),
	}
