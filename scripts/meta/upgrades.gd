extends RefCounted
## Effets des améliorations de l'atelier : réglages absolus (« mods ») et armes modifiées.
##
## Chaque niveau d'amélioration décrit l'effet TOTAL de ce niveau (pas un ajout au niveau précédent).
## Clés d'effet :
##   w<i>.<stat>   variation relative d'une statistique de l'arme i (w* = toutes les armes). Les variations
##                 relatives de plusieurs améliorations s'additionnent : valeur = base × (1 + somme).
##   mod.<clé>     valeur absolue, lue par le jeu avec ctx.mod() : predict, zoom_max, laser, door_hp, civ_speed,
##                 obj_time_s, chain_keep, xp_bonus, credit_bonus. Plusieurs sources se cumulent par addition,
##                 sauf predict, zoom_max et laser, pour lesquels on garde la plus grande valeur.

const MAX_KEYS := ["predict", "zoom_max", "laser"]
const MIN_STAT := {"dispersion_mrad": 0.05, "rpm": 1.0, "ammo": 1.0}


## Effets de tous les niveaux possédés : {"rel": [{stat: somme}] par arme (clé -1 : toutes), "mod": {clé: valeur}}.
static func effects(defs, levels: Dictionary) -> Dictionary:
	var rel := {}
	var mod := {}
	for it in defs.up_items:
		var lv: int = int(levels.get(str(it["id"]), 0))
		if lv <= 0:
			continue
		lv = mini(lv, (it["levels"] as Array).size())
		var eff: Dictionary = it["levels"][lv - 1]["effects"]
		for k in eff.keys():
			var key := str(k)
			var v: float = float(eff[k])
			if key.begins_with("mod."):
				var mk := key.substr(4)
				if MAX_KEYS.has(mk):
					mod[mk] = maxf(float(mod.get(mk, 0.0)), v)
				else:
					mod[mk] = float(mod.get(mk, 0.0)) + v
			elif key.begins_with("w"):
				var dot := key.find(".")
				if dot < 0:
					continue
				var wsel := key.substr(1, dot - 1)
				var wi := -1 if wsel == "*" else int(wsel)
				var stat := key.substr(dot + 1)
				if not rel.has(wi):
					rel[wi] = {}
				rel[wi][stat] = float(rel[wi].get(stat, 0.0)) + v
	return {"rel": rel, "mod": mod}


## Réglages absolus du profil (pour ctx.mods).
static func mods(defs, levels: Dictionary) -> Dictionary:
	return effects(defs, levels)["mod"]


## Armes modifiées (copie profonde : data/weapons.json n'est jamais touché).
static func weapons(base: Array, defs, levels: Dictionary) -> Array:
	var out: Array = base.duplicate(true)
	var rel: Dictionary = effects(defs, levels)["rel"]
	for i in out.size():
		var w: Dictionary = out[i]
		var sums := {}                        # statistique -> somme des variations (arme précise + toutes les armes)
		for sel in [-1, i]:
			if rel.has(sel):
				for stat in rel[sel].keys():
					sums[stat] = float(sums.get(stat, 0.0)) + float(rel[sel][stat])
		for stat in sums.keys():
			if w.has(stat):
				w[stat] = _scaled(str(stat), w[stat], 1.0 + float(sums[stat]))
	return out


static func _scaled(stat: String, base, f: float):
	var v: float = float(base) * f
	if MIN_STAT.has(stat):
		v = maxf(v, float(MIN_STAT[stat]))
	if stat == "ammo" or stat == "rpm":
		return int(round(v))
	return v
