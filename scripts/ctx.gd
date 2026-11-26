extends RefCounted
## Contexte partagé entre les systèmes (pas d'autoload : tout est passé explicitement).

var rng := RandomNumberGenerator.new()
## Tirages du scénario (où tombent les vagues, quels immeubles sont visés) : à part de `rng`, que les tirs et les effets
## consomment à leur rythme. Avec la même graine, deux parties voient donc le même scénario (défi du jour).
var wave_rng := RandomNumberGenerator.new()
var mode := "campaign"   # campaign | daily | endless
var mutators: Array = [] # identifiants des mutateurs actifs (voir data/mutators.json)
var wave_no := 0         # Nuit blanche : numéro de la vague en cours (0 : mode sans vagues numérotées)
var supports = null      # Supports (appuis ponctuels) ; null dans les tests sans appuis
var zombie_types: Dictionary = {}   # infectés spéciaux (data/zombies.json) indexés par identifiant
var city = null          # CityData
var graph = null         # StreetGraph
var buildings = null     # BuildingSystem
var crowd = null         # Crowd
var arms = null          # Arms
var fx = null            # Fx (null dans les tests sans rendu)
var gunship = null       # Gunship
var director = null      # Director
var score = null         # Score (points, série, étoiles) ; null dans les tests qui n'en ont pas besoin
var objectives = null    # Objectives (objectifs de mission annoncés par la radio)
var profile = null       # Profile (grade, améliorations, médailles, cosmétiques) ; null dans les tests qui n'en ont pas besoin
var mods: Dictionary = {}  # réglages absolus issus des améliorations (voir scripts/meta/upgrades.gd)
var predictor = null     # Predictor (capteur : point d'impact anticipé) ; null dans les tests qui n'en ont pas besoin
var designator = null    # Designator (capteur : désignation laser d'un infecté) ; idem
var assist = null        # Assist (viseur attiré vers la zone urgente en Recrue) ; null dans les tests qui n'en ont pas besoin
var lock = null          # Lock (infectés cachés derrière un immeuble : carrés rouges et tirs guidés) ; null dans les tests qui n'en ont pas besoin
var sound = null         # Sound (null dans les tests logiques et avec --nosound : seul le journal radio écrit reste)
var weapons: Array = []
var mission: Dictionary = {}       # mission jouée : la mission du secteur transformée par la difficulté (clé « difficulty »)
var base_mission: Dictionary = {}  # mission du secteur telle qu'écrite dans data/ (avant difficulté)
var time := 0.0
var radio_log: Array = []   # [[texte, type, date], ...]


func radio(text: String, kind: String = "info") -> void:
	radio_log.append([text, kind, time])
	if radio_log.size() > 40:
		radio_log.pop_front()


## Avec la panne radio, la station ne répond plus : seuls les échanges internes de l'avion passent.
const RADIO_DOWN_KEEP := ["radio_fail", "recenter", "kills", "building_lost", "building_clear",
		"colossus_down", "screamer_down", "alpha_down"]


## Message radio du scénario : échange vocal (Base, avion, tireur) si le son est actif, sinon simple ligne de journal.
## event : clé de data/radio_script.json ; params : dir (0..7), dist (m), n, civ ; fallback/kind : texte écrit de repli.
func say(event: String, params: Dictionary = {}, fallback: String = "", kind: String = "info") -> void:
	if mutators.has("radio_down") and not RADIO_DOWN_KEEP.has(event):
		return
	if sound != null:
		sound.say(event, params, fallback, kind)
	elif fallback != "":
		radio(fallback, kind)


## Réglage issu des améliorations de l'atelier (predict, zoom_max, laser, door_hp, civ_speed, obj_time_s, chain_keep...).
func mod(key: String, default_value: float = 0.0) -> float:
	return float(mods.get(key, default_value))


## Niveau de difficulté de la partie (dictionnaire de data/difficulty.json, vide dans les essais sans campagne).
func difficulty() -> Dictionary:
	return mission.get("difficulty", {})


func has_mutator(id: String) -> bool:
	return mutators.has(id)


func rule(key: String, default_value: float) -> float:
	var r: Dictionary = mission.get("rules", {})
	return float(r.get(key, default_value))


# ---------------------------------------------------------------- zone de jeu (« périmètre »)

## Zone de jeu : disque de `radius_m` mètres autour de (`cx`, `cz`), clé « zone » de la mission (600 m : un périmètre deux fois plus étroit
## que les 2 400 m de la carte). Ni infectés, ni civils, ni objectifs n'y apparaissent en dehors, et la visée n'en sort pas. Sans clé « zone »
## (cartes d'essai, ateliers), toute la carte compte comme avant.
func has_zone() -> bool:
	return mission.has("zone")


func zone_center() -> Vector2:
	var z: Dictionary = mission.get("zone", {})
	return Vector2(float(z.get("cx", 0.0)), float(z.get("cz", 0.0)))


func zone_radius() -> float:
	if has_zone():
		return float((mission["zone"] as Dictionary).get("radius_m", 600.0))
	var sz: Vector2 = city.size_m() if city != null else Vector2(2400.0, 2400.0)
	return minf(sz.x, sz.y) * 0.5


## Le point est-il dans la zone de jeu (avec une marge en plus, négative pour rester à l'intérieur) ?
func in_zone(p: Vector2, margin: float = 0.0) -> bool:
	if has_zone():
		return p.distance_to(zone_center()) <= zone_radius() + margin
	var r := zone_radius() + margin
	return absf(p.x) <= r and absf(p.y) <= r


## Ramène un point dans la zone (le plus proche point de la zone) ; sans zone, dans le carré de la carte moins 30 m de bord.
func zone_clamp(p: Vector2) -> Vector2:
	if has_zone():
		var c := zone_center()
		var off := p - c
		var r := zone_radius()
		return c + off.normalized() * r if off.length() > r else p
	var h := zone_radius() - 30.0
	return Vector2(clampf(p.x, -h, h), clampf(p.y, -h, h))
