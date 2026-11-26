extends RefCounted
## Mutateurs : variantes de règles choisies avant le départ (data/mutators.json). Fonctions statiques :
## la mission et les armes sont copiées puis transformées, les originaux ne sont jamais modifiés.

const Campaign := preload("res://scripts/meta/campaign.gd")


## Identifiants valides, sans doublon, sans incompatibilité, au plus defs.max_mutators (l'ordre de la liste est respecté :
## un mutateur incompatible avec un précédent est écarté).
static func clean(defs, ids: Array) -> Array:
	var out: Array = []
	for v in ids:
		var id := str(v)
		if not defs.mutator_by_id.has(id) or out.has(id) or out.size() >= defs.max_mutators:
			continue
		var clash := false
		for o in out:
			if (defs.mutator(str(o)).get("excludes", []) as Array).has(id) or (defs.mutator(id).get("excludes", []) as Array).has(str(o)):
				clash = true
		if not clash:
			out.append(id)
	return out


## Ajoute ou retire un mutateur (les incompatibles sont retirés à l'ajout). Retourne la nouvelle liste.
static func toggled(defs, ids: Array, id: String) -> Array:
	var cur: Array = clean(defs, ids)
	if cur.has(id):
		cur.erase(id)
		return cur
	var excl: Array = defs.mutator(id).get("excludes", [])
	var out: Array = []
	for o in cur:
		if not excl.has(str(o)):
			out.append(str(o))
	if out.size() >= defs.max_mutators:
		return cur                    # déjà le maximum : rien ne change
	out.append(id)
	return clean(defs, out)


## Multiplicateur des gains d'XP et de crédits : produit des (1 + bonus).
static func reward_mult(defs, ids: Array) -> float:
	var f := 1.0
	for id in clean(defs, ids):
		f *= 1.0 + float(defs.mutator(str(id)).get("bonus", 0.0))
	return f


## Effet cumulé d'un réglage numérique (produit des facteurs) ; `default_value` si aucun mutateur actif ne le porte.
static func factor(defs, ids: Array, key: String, default_value: float = 1.0) -> float:
	var f := default_value
	var any := false
	for id in clean(defs, ids):
		var ef: Dictionary = defs.mutator(str(id)).get("effects", {})
		if ef.has(key):
			f = float(ef[key]) if not any else f * float(ef[key])
			any = true
	return f


static func has_effect(defs, ids: Array, key: String) -> bool:
	for id in clean(defs, ids):
		if (defs.mutator(str(id)).get("effects", {}) as Dictionary).has(key):
			return true
	return false


## Mission transformée : portes, coureurs, objectifs (la panne radio ne laisse que les objectifs bonus, jamais annoncés).
static func apply(base: Dictionary, defs, ids: Array) -> Dictionary:
	var ok: Array = clean(defs, ids)
	var m: Dictionary = base.duplicate(true)
	var r: Dictionary = m.get("rules", {})
	var df := factor(defs, ok, "doors")
	if absf(df - 1.0) > 0.0001:
		for k in ["door_hp_min", "door_hp_max"]:
			if r.has(k):
				r[k] = float(r[k]) * df
	var rf := factor(defs, ok, "runners")
	if absf(rf - 1.0) > 0.0001 and r.has("runner_ratio"):
		r["runner_ratio"] = clampf(float(r["runner_ratio"]) * rf, 0.0, Campaign.RUNNER_MAX)
	m["rules"] = r
	if has_effect(defs, ok, "radio_down"):
		var keep: Array = []
		for o in m.get("objectives", []):
			if str(o.get("kind", "secondary")) == "hidden":
				keep.append(o)
		m["objectives"] = keep
	m["mutators"] = ok
	return m


## Armes transformées : réserves de munitions et régénération (copie profonde).
static func weapons(base: Array, defs, ids: Array) -> Array:
	var ok: Array = clean(defs, ids)
	var out: Array = base.duplicate(true)
	var am := factor(defs, ok, "ammo")
	var rg := factor(defs, ok, "regen")
	if absf(am - 1.0) < 0.0001 and absf(rg - 1.0) < 0.0001:
		return out
	for w in out:
		if w.has("ammo"):
			w["ammo"] = maxi(int(round(float(w["ammo"]) * am)), 1)
		if w.has("regen_per_s"):
			w["regen_per_s"] = float(w["regen_per_s"]) * rg
	return out


## « Brouillard · Portes fragiles » (vide sans mutateur).
static func names(defs, ids: Array) -> String:
	var parts: Array = []
	for id in clean(defs, ids):
		parts.append(str(defs.mutator(str(id)).get("name", id)))
	return " · ".join(parts)
