extends RefCounted
## Profil du joueur : XP et grade, crédits d'appui, améliorations, médailles, cosmétiques, statistiques de carrière.
## Sauvegardé en JSON (user://profile.json) ; `path` vide = profil en mémoire seulement (essais, pilote automatique).

const Upgrades := preload("res://scripts/meta/upgrades.gd")
const Campaign := preload("res://scripts/meta/campaign.gd")
const Daily := preload("res://scripts/meta/daily.gd")

const VERSION := 1
const RATINGS := ["D", "C", "B", "A", "S"]

var defs                                   # Defs
var path := ""
var xp := 0
var credits := 0
var grade_paid := 0                        # plus haut grade dont la prime de promotion a été versée
var upgrades: Dictionary = {}              # id -> niveau
var medals: Dictionary = {}                # id -> {"n": numéro de la mission où elle a été obtenue}
var owned: Array = []                      # cosmétiques achetés
var equipped: Dictionary = {}              # emplacement -> id
var stats: Dictionary = {}
var missions: Dictionary = {}              # id de mission -> {plays, wins, best_score, best_rating, stars_done, best_stars, best_diff}
var settings: Dictionary = {}              # choix à reprendre au prochain lancement : sector (id), difficulty (id), picked (présent et vrai si le niveau a été choisi par le joueur), text (taille du texte : 0 à 2)
var daily: Dictionary = {}                 # défi du jour : last_win, streak, best_streak, plays, wins, today, board
var endless: Dictionary = {}               # Nuit blanche : id de secteur -> {plays, best_score, best_waves, best_time}
var load_error := ""


func setup(p_defs, p_path: String = "") -> void:
	defs = p_defs
	path = p_path
	reset()


func reset() -> void:
	xp = 0
	credits = 0
	grade_paid = 0
	upgrades = {}
	medals = {}
	owned = []
	equipped = defs.default_equipped()
	stats = {"missions": 0, "wins": 0, "kills": 0, "saved": 0, "collateral": 0, "obj": 0, "hidden": 0, "shells": 0, "play_s": 0,
			"nm_wins": 0, "daily_wins": 0, "endless_waves": 0, "specials": 0, "colossus": 0, "support_calls": 0}
	missions = {}
	daily = _new_daily()
	endless = {}
	settings = {"sector": "", "difficulty": ""}
	load_error = ""


# ---------------------------------------------------------------- sauvegarde

func to_dict() -> Dictionary:
	return {
		"version": VERSION, "xp": xp, "credits": credits, "grade_paid": grade_paid,
		"upgrades": upgrades, "medals": medals, "owned": owned, "equipped": equipped,
		"stats": stats, "missions": missions, "settings": settings, "daily": daily, "endless": endless,
	}


## Reprend un dictionnaire lu sur disque en écartant tout ce que les données ne connaissent plus.
func from_dict(d: Dictionary) -> void:
	reset()
	xp = maxi(int(d.get("xp", 0)), 0)
	credits = maxi(int(d.get("credits", 0)), 0)
	var gcount: int = defs.grade_count()
	grade_paid = clampi(int(d.get("grade_paid", grade_index())), 0, maxi(gcount - 1, 0))
	var up = d.get("upgrades", {})
	if typeof(up) == TYPE_DICTIONARY:
		for k in up.keys():
			if defs.up_by_id.has(str(k)):
				var mx: int = (defs.up_by_id[str(k)]["levels"] as Array).size()
				var lv := clampi(int(up[k]), 0, mx)
				if lv > 0:
					upgrades[str(k)] = lv
	var md = d.get("medals", {})
	if typeof(md) == TYPE_DICTIONARY:
		for k in md.keys():
			if defs.medal_by_id.has(str(k)):
				var e = md[k]
				medals[str(k)] = {"n": int(e.get("n", 0)) if typeof(e) == TYPE_DICTIONARY else 0}
	var ow = d.get("owned", [])
	if typeof(ow) == TYPE_ARRAY:
		for c in ow:
			if defs.cos_by_id.has(str(c)) and not owned.has(str(c)):
				owned.append(str(c))
	var eq = d.get("equipped", {})
	if typeof(eq) == TYPE_DICTIONARY:
		for slot in eq.keys():
			var id := str(eq[slot])
			if defs.cos_by_id.has(id) and str(defs.cos_by_id[id]["slot"]) == str(slot) and is_unlocked(id):
				equipped[str(slot)] = id
	var st = d.get("stats", {})
	if typeof(st) == TYPE_DICTIONARY:
		for k in stats.keys():
			stats[k] = maxi(int(st.get(k, 0)), 0)
	var ms = d.get("missions", {})
	if typeof(ms) == TYPE_DICTIONARY:
		for k in ms.keys():
			var e = ms[k]
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var rec := _new_mission()
			rec["plays"] = maxi(int(e.get("plays", 0)), 0)
			rec["wins"] = maxi(int(e.get("wins", 0)), 0)
			rec["best_score"] = maxi(int(e.get("best_score", 0)), 0)
			rec["best_rating"] = clampi(int(e.get("best_rating", -1)), -1, RATINGS.size() - 1)
			var sd = e.get("stars_done", [])
			if typeof(sd) == TYPE_ARRAY:
				var arr: Array = []
				for b in sd:
					arr.append(bool(b))
				rec["stars_done"] = arr
			rec["best_stars"] = _count_true(rec["stars_done"])
			rec["best_diff"] = clampi(int(e.get("best_diff", -1)), -1, maxi(defs.levels.size() - 1, -1))
			missions[str(k)] = rec
	var dl = d.get("daily", {})
	if typeof(dl) == TYPE_DICTIONARY:
		daily["last_win"] = str(dl.get("last_win", "")) if Daily.valid_date(str(dl.get("last_win", ""))) else ""
		daily["streak"] = maxi(int(dl.get("streak", 0)), 0)
		daily["best_streak"] = maxi(int(dl.get("best_streak", 0)), int(daily["streak"]))
		daily["plays"] = maxi(int(dl.get("plays", 0)), 0)
		daily["wins"] = maxi(int(dl.get("wins", 0)), 0)
		var td = dl.get("today", {})
		if typeof(td) == TYPE_DICTIONARY and Daily.valid_date(str(td.get("date", ""))):
			daily["today"] = {"date": str(td["date"]), "best": maxi(int(td.get("best", 0)), 0),
					"plays": maxi(int(td.get("plays", 0)), 0), "won": bool(td.get("won", false))}
		var bd = dl.get("board", [])
		if typeof(bd) == TYPE_ARRAY:
			var board: Array = []
			for e in bd:
				if typeof(e) == TYPE_DICTIONARY and Daily.valid_date(str(e.get("date", ""))):
					board.append({"date": str(e["date"]), "score": maxi(int(e.get("score", 0)), 0), "rating": str(e.get("rating", "—")),
							"won": bool(e.get("won", false)), "sector": str(e.get("sector", "")), "mut": maxi(int(e.get("mut", 0)), 0)})
			daily["board"] = _trim_board(board)
	var en = d.get("endless", {})
	if typeof(en) == TYPE_DICTIONARY:
		for k in en.keys():
			var e2 = en[k]
			if defs.sector_by_id.has(str(k)) and typeof(e2) == TYPE_DICTIONARY:
				endless[str(k)] = {"plays": maxi(int(e2.get("plays", 0)), 0), "best_score": maxi(int(e2.get("best_score", 0)), 0),
						"best_waves": maxi(int(e2.get("best_waves", 0)), 0), "best_time": maxi(int(e2.get("best_time", 0)), 0)}
	var se = d.get("settings", {})
	if typeof(se) == TYPE_DICTIONARY:
		if defs.sector_by_id.has(str(se.get("sector", ""))):
			settings["sector"] = str(se["sector"])
		if defs.level_by_id.has(str(se.get("difficulty", ""))):
			settings["difficulty"] = str(se["difficulty"])
		if bool(se.get("picked", false)):
			settings["picked"] = true                            # niveau choisi par le joueur (et non enregistré par défaut) : voir Campaign.start_level
		if se.has("text"):
			settings["text"] = clampi(int(se["text"]), 0, 2)     # taille du texte de l'écran de jeu (touche T) : 0 normal, 1 grand, 2 très grand


## Charge le fichier. Retourne vrai si un profil a été lu ; un fichier corrompu est mis de côté (.bad).
func load_file() -> bool:
	load_error = ""
	if path == "" or not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		load_error = "profil illisible"
		return false
	var txt := f.get_as_text()
	f.close()
	var parser := JSON.new()
	var j = parser.data if parser.parse(txt) == OK else null
	if typeof(j) != TYPE_DICTIONARY:
		DirAccess.copy_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(path) + ".bad")
		reset()
		load_error = "profil corrompu : une copie a été mise de côté (.bad), nouveau profil créé"
		return false
	from_dict(j)
	return true


## Écriture atomique (fichier temporaire puis renommage) : une coupure ne laisse jamais un profil à moitié écrit.
func save() -> bool:
	if path == "":
		return true
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict(), " "))
	f.close()
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path))
	return err == OK


# ---------------------------------------------------------------- grade

func grade_index() -> int:
	var g := 0
	for i in defs.grades.size():
		if xp >= int(defs.grades[i]["xp"]):
			g = i
	return g


func grade_name(i: int = -1) -> String:
	return str(defs.grades[grade_index() if i < 0 else i]["name"])


func grade_short(i: int = -1) -> String:
	return str(defs.grades[grade_index() if i < 0 else i]["short"])


## [XP gagnées dans le grade, XP à gagner pour le suivant] ; le second vaut 0 au grade maximal.
func grade_progress() -> Vector2i:
	var g := grade_index()
	var lo: int = int(defs.grades[g]["xp"])
	if g + 1 >= defs.grades.size():
		return Vector2i(xp - lo, 0)
	return Vector2i(xp - lo, int(defs.grades[g + 1]["xp"]) - lo)


## Verse la prime de chaque grade nouvellement atteint ; retourne leurs indices.
func _settle_grade() -> Array:
	var out: Array = []
	var g := grade_index()
	while grade_paid < g:
		grade_paid += 1
		credits += int(defs.grades[grade_paid].get("credits", 0))
		out.append(grade_paid)
	return out


# ---------------------------------------------------------------- atelier

func level(id: String) -> int:
	return int(upgrades.get(id, 0))


func max_level(id: String) -> int:
	return (defs.up_by_id[id]["levels"] as Array).size() if defs.up_by_id.has(id) else 0


## Définition du prochain niveau ({} au maximum).
func next_level(id: String) -> Dictionary:
	var lv := level(id)
	if not defs.up_by_id.has(id) or lv >= max_level(id):
		return {}
	return defs.up_by_id[id]["levels"][lv]


func can_buy(id: String) -> Dictionary:
	var nl := next_level(id)
	if nl.is_empty():
		return {"ok": false, "why": "niveau maximal" if defs.up_by_id.has(id) else "inconnu"}
	if grade_index() < int(nl["grade"]):
		return {"ok": false, "why": "grade requis : %s" % defs.grades[int(nl["grade"])]["name"]}
	if credits < int(nl["cost"]):
		return {"ok": false, "why": "il manque %d crédits" % (int(nl["cost"]) - credits)}
	return {"ok": true, "why": ""}


func buy(id: String) -> bool:
	if not can_buy(id)["ok"]:
		return false
	credits -= int(next_level(id)["cost"])
	upgrades[id] = level(id) + 1
	return true


func total_levels() -> int:
	var n := 0
	for k in upgrades.keys():
		n += int(upgrades[k])
	return n


func shop_complete() -> bool:
	return total_levels() >= defs.total_upgrade_levels()


func mods() -> Dictionary:
	return Upgrades.mods(defs, upgrades)


func weapons(base: Array) -> Array:
	return Upgrades.weapons(base, defs, upgrades)


# ---------------------------------------------------------------- cosmétiques

func is_unlocked(id: String) -> bool:
	if not defs.cos_by_id.has(id):
		return false
	var u: Dictionary = defs.cos_by_id[id].get("unlock", {})
	if u.has("default"):
		return true
	if u.has("medal"):
		return medals.has(str(u["medal"]))
	if u.has("cost"):
		return owned.has(id)
	if u.has("grade"):
		return grade_index() >= int(u["grade"])
	return false


func unlock_text(id: String) -> String:
	if not defs.cos_by_id.has(id):
		return ""
	var u: Dictionary = defs.cos_by_id[id].get("unlock", {})
	if u.has("default"):
		return "acquis"
	if u.has("medal"):
		var m: Dictionary = defs.medal_by_id.get(str(u["medal"]), {})
		return "médaille « %s »" % str(m.get("name", u["medal"]))
	if u.has("cost"):
		return "%d crédits, grade %s" % [int(u["cost"]), defs.grades[int(u.get("grade", 0))]["name"]]
	if u.has("grade"):
		return "grade %s" % defs.grades[int(u["grade"])]["name"]
	return ""


func can_buy_cosmetic(id: String) -> Dictionary:
	if not defs.cos_by_id.has(id):
		return {"ok": false, "why": "inconnu"}
	var u: Dictionary = defs.cos_by_id[id].get("unlock", {})
	if not u.has("cost") or owned.has(id):
		return {"ok": false, "why": "non vendu" if not u.has("cost") else "déjà acheté"}
	if grade_index() < int(u.get("grade", 0)):
		return {"ok": false, "why": "grade requis : %s" % defs.grades[int(u.get("grade", 0))]["name"]}
	if credits < int(u["cost"]):
		return {"ok": false, "why": "il manque %d crédits" % (int(u["cost"]) - credits)}
	return {"ok": true, "why": ""}


func buy_cosmetic(id: String) -> bool:
	if not can_buy_cosmetic(id)["ok"]:
		return false
	credits -= int(defs.cos_by_id[id]["unlock"]["cost"])
	owned.append(id)
	return true


func equip(slot: String, id: String) -> bool:
	if not defs.cos_by_id.has(id) or str(defs.cos_by_id[id]["slot"]) != slot or not is_unlocked(id):
		return false
	equipped[slot] = id
	return true


func equipped_item(slot: String) -> Dictionary:
	return defs.cos_by_id.get(str(equipped.get(slot, "")), {})


## Cosmétiques utilisables (gratuits ou déjà achetés) : sert à repérer les nouveautés.
func unlocked_set() -> Dictionary:
	var out := {}
	for id in defs.cos_by_id.keys():
		if is_unlocked(str(id)):
			out[str(id)] = true
	return out


# ---------------------------------------------------------------- médailles

func has_medal(id: String) -> bool:
	return medals.has(id)


func medal_count() -> int:
	return medals.size()


func mission_record(id: String) -> Dictionary:
	return missions.get(id, _new_mission())


static func _new_mission() -> Dictionary:
	return {"plays": 0, "wins": 0, "best_score": 0, "best_rating": -1, "stars_done": [], "best_stars": 0, "best_diff": -1}


static func _new_daily() -> Dictionary:
	return {"last_win": "", "streak": 0, "best_streak": 0, "plays": 0, "wins": 0, "today": {}, "board": []}


## Record de Nuit blanche d'un secteur (valeurs nulles si jamais joué).
func endless_record(sector_id: String) -> Dictionary:
	return endless.get(sector_id, {"plays": 0, "best_score": 0, "best_waves": 0, "best_time": 0})


## Meilleur score de Nuit blanche, tous secteurs confondus.
func endless_best_waves() -> int:
	var b := 0
	for k in endless.keys():
		b = maxi(b, int(endless[k]["best_waves"]))
	return b


## Le défi de cette date est-il déjà gagné ? Meilleur score du jour (0 si non joué).
func daily_today(date: String) -> Dictionary:
	var t: Dictionary = daily.get("today", {})
	if str(t.get("date", "")) == date:
		return t
	return {"date": date, "best": 0, "plays": 0, "won": false}


## Série de jours consécutifs encore vivante à cette date (0 si elle est rompue).
func daily_streak(date: String) -> int:
	var lw := str(daily.get("last_win", ""))
	if lw == date or lw == Daily.previous_day(date):
		return int(daily.get("streak", 0))
	return 0


func _trim_board(board: Array) -> Array:
	board.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
	var n: int = int(defs.mode_cfg("daily").get("board", 10))
	return board.slice(0, n) if board.size() > n else board


## Enregistre une partie du défi du jour : série, meilleur score du jour, classement local.
## Retourne {first_win, streak, rank (1 = meilleur, 0 = hors classement)}.
func _record_daily(date: String, total: int, won: bool, rating: String, extra: Dictionary) -> Dictionary:
	daily["plays"] = int(daily["plays"]) + 1
	var t: Dictionary = daily_today(date)
	t["plays"] = int(t["plays"]) + 1
	t["best"] = maxi(int(t["best"]), total)
	var first_win := false
	var streak := int(daily["streak"])
	if won:
		daily["wins"] = int(daily["wins"]) + 1
		t["won"] = true
		if str(daily["last_win"]) != date:
			first_win = true
			streak = streak + 1 if str(daily["last_win"]) == Daily.previous_day(date) else 1
			daily["streak"] = streak
			daily["best_streak"] = maxi(int(daily["best_streak"]), streak)
			daily["last_win"] = date
	daily["today"] = t
	var entry := {"date": date, "score": total, "rating": rating, "won": won, "sector": str(extra.get("sector", "")),
			"mut": (extra.get("mutators", []) as Array).size()}
	var board: Array = (daily["board"] as Array).duplicate()
	board.append(entry)
	board = _trim_board(board)
	var rank := 0
	for i in board.size():
		if board[i] == entry:
			rank = i + 1
			break
	daily["board"] = board
	return {"first_win": first_win, "streak": streak, "rank": rank}


## Enregistre une partie de Nuit blanche. Retourne {record_score, record_waves, record_time}.
func _record_endless(sector_id: String, total: int, waves: int, secs: int) -> Dictionary:
	var e: Dictionary = endless_record(sector_id).duplicate()
	var out := {"record_score": total > int(e["best_score"]), "record_waves": waves > int(e["best_waves"]),
			"record_time": secs > int(e["best_time"])}
	e["plays"] = int(e["plays"]) + 1
	e["best_score"] = maxi(int(e["best_score"]), total)
	e["best_waves"] = maxi(int(e["best_waves"]), waves)
	e["best_time"] = maxi(int(e["best_time"]), secs)
	endless[sector_id] = e
	stats["endless_waves"] = maxi(int(stats["endless_waves"]), waves)
	return out


static func _count_true(a: Array) -> int:
	var n := 0
	for b in a:
		if b:
			n += 1
	return n


## Étoiles cumulées dans les secteurs de la campagne : elles ouvrent les secteurs suivants.
func sector_stars() -> int:
	var n := 0
	for sc in defs.sectors:
		n += int(mission_record(str(sc["id"]))["best_stars"])
	return n


## Faits de carrière (préfixe c_) pour les conditions de médailles.
func career_facts() -> Dictionary:
	var stars := 0
	for k in missions.keys():
		stars += int(missions[k]["best_stars"])
	var sectors_won := 0
	for sc in defs.sectors:
		if int(mission_record(str(sc["id"]))["wins"]) > 0:
			sectors_won += 1
	return {
		"c_missions": int(stats["missions"]), "c_wins": int(stats["wins"]), "c_kills": int(stats["kills"]),
		"c_saved": int(stats["saved"]), "c_collateral": int(stats["collateral"]), "c_obj": int(stats["obj"]),
		"c_hidden": int(stats["hidden"]), "c_stars": stars, "c_medals": medals.size(),
		"c_upgrades": total_levels(), "c_grade": grade_index(), "c_xp": xp,
		"shop_complete": 1 if shop_complete() else 0,
		"c_sectors": sectors_won, "c_nightmare": int(stats["nm_wins"]),
		"c_daily_wins": int(stats["daily_wins"]), "c_streak": int(daily.get("best_streak", 0)), "c_endless": int(stats["endless_waves"]),
		"c_specials": int(stats["specials"]), "c_colossus": int(stats["colossus"]), "c_supports": int(stats["support_calls"]),
	}


## Faits d'une mission terminée (résultat de Score.finish).
static func mission_facts(res: Dictionary) -> Dictionary:
	var st: Dictionary = res.get("stats", {})
	var kw: Array = st.get("kills_w", [0, 0, 0])
	var sw: Array = st.get("shells_w", [0, 0, 0])
	var heavy := 0
	for w in range(1, sw.size()):
		heavy += int(sw[w])
	var acc: float = float(res.get("accuracy", -1.0))
	var obj: Dictionary = res.get("objectives", {})
	var sec: Array = obj.get("secondary", [])
	var hid: Array = obj.get("hidden", [])
	var done := 0
	for s in sec:
		if s["ok"]:
			done += 1
	var found := 0
	for h in hid:
		if h["found"]:
			found += 1
	var rating := str(res.get("rating", "—"))
	var f := {
		"won": 1 if res.get("won", false) else 0,
		"kills": int(res.get("kills", 0)), "saved": int(res.get("saved", 0)), "lost": int(res.get("lost", 0)),
		"collateral": int(res.get("collateral", 0)), "eaten": int(res.get("eaten", 0)), "destroyed": int(res.get("destroyed", 0)),
		"chain_best": int(st.get("chain_best", 0)), "clean_best": int(st.get("clean_best", 0)), "score": int(res.get("total", 0)),
		"rating": RATINGS.find(rating) if RATINGS.has(rating) else -1, "stars": int(res.get("n_stars", 0)),
		"accuracy": int(round(acc * 100.0)) if acc >= 0.0 else -1, "shells_heavy": heavy,
		"obj_done": done, "obj_total": sec.size(), "objectives_all": 1 if sec.size() > 0 and done == sec.size() else 0,
		"hidden_found": found, "hidden_total": hid.size(), "hidden_all": 1 if hid.size() > 0 and found == hid.size() else 0,
		"max_kills_shell": int(st.get("max_kills_shell", 0)), "max_kill_range": float(st.get("max_kill_range", 0.0)),
		"hit_streak_best": int(st.get("hit_streak_best", 0)), "protected": int(st.get("protected", 0)),
		"time": float(res.get("time", 0.0)), "diff": int(res.get("diff", -1)),
		"specials": int(st.get("specials", 0)), "kills_colossus": int(st.get("kills_colossus", 0)),
		"kills_screamer": int(st.get("kills_screamer", 0)), "kills_alpha": int(st.get("kills_alpha", 0)),
		"supports": int(st.get("supports", 0)), "support_kills": int(st.get("support_kills", 0)),
		"mut_n": (res.get("mutators", []) as Array).size(),
		"e_waves": int(res.get("waves", 0)) if str(res.get("mode", "campaign")) == "endless" else 0,
		"e_minutes": int(float(res.get("time", 0.0)) / 60.0) if str(res.get("mode", "campaign")) == "endless" else 0,
	}
	if str(res.get("mode", "campaign")) == "endless":
		f["won"] = 0                 # une patrouille interrompue n'est pas une victoire
		f["rating"] = -1
		f["stars"] = 0
		f["diff"] = -1
	for w in 3:
		f["kills_w%d" % w] = int(kw[w]) if w < kw.size() else 0
	return f


static func cond_ok(cond: Array, facts: Dictionary) -> bool:
	for c in cond:
		if not facts.has(str(c[0])):
			return false
		var v: float = float(facts[str(c[0])])
		var ref: float = float(c[2])
		match str(c[1]):
			">=":
				if not v >= ref:
					return false
			"<=":
				if not v <= ref:
					return false
			"==":
				if not is_equal_approx(v, ref):
					return false
			_:
				return false
	return true


## Attribue les médailles dont les conditions sont remplies (jusqu'à stabilité : une médaille donne de l'XP,
## qui peut donner un grade, qui peut en donner une autre). Retourne [[id, xp, crédits], ...] des nouvelles médailles.
## Une médaille de mission ne s'évalue que si `facts` contient les faits de mission ; sinon seules les médailles de carrière comptent.
func check_medals(mission_facts_d: Dictionary = {}) -> Array:
	var out: Array = []
	for _pass in 5:
		var facts := career_facts()
		facts.merge(mission_facts_d, true)
		var got := false
		for m in defs.medal_list:
			var id := str(m["id"])
			if medals.has(id) or not cond_ok(m["cond"], facts):
				continue
			var t: Dictionary = defs.tiers.get(str(m["tier"]), {})
			medals[id] = {"n": int(stats["missions"])}
			var mx := int(t.get("xp", 0))
			var mc := int(t.get("credits", 0))
			xp += mx
			credits += mc
			out.append([id, mx, mc])
			got = true
		if not got:
			break
		_settle_grade()
	return out


# ---------------------------------------------------------------- fin de mission

## Applique le résultat d'une mission : XP, crédits, étoiles et records, médailles, promotions.
## xp_mult, credit_mult : multiplicateurs de difficulté sur l'XP et les crédits de la mission (hors médailles et primes).
## diff : indice du niveau de difficulté joué (-1 : non précisé), pour le record par difficulté et la médaille Cauchemar.
## mode : « campaign » (étoiles, notes et records du secteur), « daily » (défi du jour : ni étoile ni record de secteur ; série,
## prime et classement local) ou « endless » (Nuit blanche : gains selon le score, les vagues et la durée ; records à part).
## extra : mut_mult (multiplicateur des mutateurs), date (défi du jour), waves (Nuit blanche), mutators, sector.
## Retourne le rapport affiché par la page « Progression » du débriefing.
func apply_mission(res: Dictionary, mission_id: String, xp_mult: float = 1.0, credit_mult: float = 1.0, diff: int = -1,
		mode: String = "campaign", extra: Dictionary = {}) -> Dictionary:
	var won: bool = bool(res.get("won", false))
	var is_camp := mode == "campaign"
	var is_endless := mode == "endless"
	var P: Dictionary = defs.progression
	var cx: Dictionary = P["xp"]
	var cc: Dictionary = P["credits"]
	var md := mods()
	var rec: Dictionary = mission_record(mission_id) if is_camp else _new_mission()
	var obj: Dictionary = res.get("objectives", {})
	var n_obj: int = 0
	for s in obj.get("secondary", []):
		if s["ok"]:
			n_obj += 1
	var n_hid: int = 0
	for h in obj.get("hidden", []):
		if h["found"]:
			n_hid += 1
	var total: int = int(res.get("total", 0))
	var rating_rank: int = RATINGS.find(str(res.get("rating", "—"))) if won else -1

	# étoiles : une étoile ne rapporte son bonus qu'une fois par condition
	var done: Array = (rec["stars_done"] as Array).duplicate()
	var new_stars := 0
	var stars: Array = res.get("stars", [])
	while done.size() < stars.size():
		done.append(false)
	if won and is_camp:
		for i in stars.size():
			if stars[i]["ok"] and not done[i]:
				done[i] = true
				new_stars += 1
	var new_rating: bool = is_camp and won and rating_rank > int(rec["best_rating"])
	var record: bool = is_camp and total > int(rec["best_score"])

	var before_xp := xp
	var stars_before := sector_stars()
	var before_grade := grade_index()
	var unlocked_before := unlocked_set()

	var xl: Array = []
	var cl: Array = []
	var waves_n := int(extra.get("waves", 0))
	var mins_n := int(float(res.get("time", 0.0)) / 60.0)
	if is_endless:
		var ec: Dictionary = defs.mode_cfg("endless")
		var ex: Dictionary = ec.get("xp", {})
		var cr: Dictionary = ec.get("credits", {})
		_line(xl, "Score (%s points)" % _fmt(total), float(total) * float(ex.get("per_score", 0.0)))
		_line(cl, "Score (%s points)" % _fmt(total), float(total) * float(cr.get("per_score", 0.0)))
		_line(xl, "Vagues tenues (%d)" % waves_n, float(ex.get("per_wave", 0)) * waves_n)
		_line(cl, "Vagues tenues (%d)" % waves_n, float(cr.get("per_wave", 0)) * waves_n)
		_line(xl, "Patrouille (%d min)" % mins_n, float(ex.get("per_min", 0)) * mins_n)
		_line(cl, "Patrouille (%d min)" % mins_n, float(cr.get("per_min", 0)) * mins_n)
	else:
		_line(xl, "Score (%s points)" % _fmt(total), float(total) * float(cx.get("per_score", 0.0)))
		_line(cl, "Score (%s points)" % _fmt(total), float(total) * float(cc.get("per_score", 0.0)))
	if won and not is_endless:
		_line(xl, "Victoire", float(cx.get("win", 0)))
		_line(cl, "Victoire", float(cc.get("win", 0)))
		if is_camp:
			_line(xl, "Étoiles (%d)" % int(res.get("n_stars", 0)), float(cx.get("per_star", 0)) * int(res.get("n_stars", 0)))
			_line(cl, "Étoiles (%d)" % int(res.get("n_stars", 0)), float(cc.get("per_star", 0)) * int(res.get("n_stars", 0)))
	if n_obj > 0:
		_line(xl, "Objectifs réussis (%d)" % n_obj, float(cx.get("per_objective", 0)) * n_obj)
		_line(cl, "Objectifs réussis (%d)" % n_obj, float(cc.get("per_objective", 0)) * n_obj)
	if n_hid > 0:
		_line(xl, "Objectifs bonus découverts (%d)" % n_hid, float(cx.get("per_hidden", 0)) * n_hid)
		_line(cl, "Objectifs bonus découverts (%d)" % n_hid, float(cc.get("per_hidden", 0)) * n_hid)
	if new_stars > 0:
		_line(xl, "Nouvelle%s étoile%s (%d)" % ["s" if new_stars > 1 else "", "s" if new_stars > 1 else "", new_stars], float(cx.get("new_star", 0)) * new_stars)
		_line(cl, "Nouvelle%s étoile%s (%d)" % ["s" if new_stars > 1 else "", "s" if new_stars > 1 else "", new_stars], float(cc.get("new_star", 0)) * new_stars)
	if new_rating:
		_line(xl, "Meilleure note : %s" % RATINGS[rating_rank], float(cx.get("new_best_rating", 0)))
		_line(cl, "Meilleure note : %s" % RATINGS[rating_rank], float(cc.get("new_best_rating", 0)))
	if not won and not is_endless:
		_scale_lines(xl, float(cx.get("loss_fraction", 0.4)), "Mission perdue")
		_scale_lines(cl, float(cc.get("loss_fraction", 0.5)), "Mission perdue")
	if absf(xp_mult - 1.0) > 0.001:
		_scale_lines(xl, xp_mult, "Difficulté (×%s)" % str(snappedf(xp_mult, 0.01)).replace(".", ","))
	if absf(credit_mult - 1.0) > 0.001:
		_scale_lines(cl, credit_mult, "Difficulté (×%s)" % str(snappedf(credit_mult, 0.01)).replace(".", ","))
	var mm := float(extra.get("mut_mult", 1.0))
	if absf(mm - 1.0) > 0.001:
		var mlabel := "Mutateurs (×%s)" % str(snappedf(mm, 0.01)).replace(".", ",")
		_scale_lines(xl, mm, mlabel)
		_scale_lines(cl, mm, mlabel)
	var xb := float(md.get("xp_bonus", 0.0))
	if xb > 0.0:
		_scale_lines(xl, 1.0 + xb, "Mentor (+%d %%)" % int(round(xb * 100.0)))
	var cb := float(md.get("credit_bonus", 0.0))
	if cb > 0.0:
		_scale_lines(cl, 1.0 + cb, "Intendant (+%d %%)" % int(round(cb * 100.0)))
	var daily_rep := {}
	if mode == "daily":
		daily_rep = _record_daily(str(extra.get("date", "")), total, won, str(res.get("rating", "—")), extra)
		if daily_rep["first_win"]:
			var dc: Dictionary = defs.mode_cfg("daily")
			var fs: Dictionary = dc.get("first", {})
			var ss: Dictionary = dc.get("streak", {})
			_line(xl, "Premier défi du jour réussi", float(fs.get("xp", 0)))
			_line(cl, "Premier défi du jour réussi", float(fs.get("credits", 0)))
			var sn := int(daily_rep["streak"])
			if sn >= 2:
				var cap := mini(sn, int(ss.get("max_days", 7)))
				_line(xl, "Série de %d jours" % sn, float(ss.get("xp", 0)) * cap)
				_line(cl, "Série de %d jours" % sn, float(ss.get("credits", 0)) * cap)
	var gain_xp := _sum(xl)
	var gain_cr := _sum(cl)
	xp += gain_xp
	credits += gain_cr

	# statistiques de carrière et fiche de mission
	stats["missions"] = int(stats["missions"]) + 1
	if won and not is_endless:
		stats["wins"] = int(stats["wins"]) + 1
		if mode == "daily":
			stats["daily_wins"] = int(stats["daily_wins"]) + 1
		if diff >= 0 and defs.levels.size() > 1 and diff >= defs.levels.size() - 1:
			stats["nm_wins"] = int(stats["nm_wins"]) + 1
	stats["kills"] = int(stats["kills"]) + int(res.get("kills", 0))
	stats["saved"] = int(stats["saved"]) + int(res.get("saved", 0))
	stats["collateral"] = int(stats["collateral"]) + int(res.get("collateral", 0))
	stats["obj"] = int(stats["obj"]) + n_obj
	stats["hidden"] = int(stats["hidden"]) + n_hid
	var sw: Array = res.get("stats", {}).get("shells_w", [])
	for w in sw.size():
		stats["shells"] = int(stats["shells"]) + int(sw[w])
	stats["play_s"] = int(stats["play_s"]) + int(res.get("time", 0.0))
	var rst: Dictionary = res.get("stats", {})
	stats["specials"] = int(stats["specials"]) + int(rst.get("specials", 0))
	stats["colossus"] = int(stats["colossus"]) + int(rst.get("kills_colossus", 0))
	stats["support_calls"] = int(stats["support_calls"]) + int(rst.get("supports", 0))
	if is_camp:
		rec["plays"] = int(rec["plays"]) + 1
		if won:
			rec["wins"] = int(rec["wins"]) + 1
			rec["best_rating"] = maxi(int(rec["best_rating"]), rating_rank)
			rec["best_diff"] = maxi(int(rec.get("best_diff", -1)), diff)
		rec["best_score"] = maxi(int(rec["best_score"]), total)
		rec["stars_done"] = done
		rec["best_stars"] = _count_true(done)
		missions[mission_id] = rec
	var endless_rep := _record_endless(mission_id, total, waves_n, int(res.get("time", 0.0))) if is_endless else {}

	# grade (prime de promotion), médailles, puis grade encore (l'XP des médailles peut en donner un autre)
	_settle_grade()
	var med := check_medals(mission_facts(res))
	var promo: Array = []
	for g in range(before_grade + 1, grade_index() + 1):
		promo.append(g)
	var medal_xp := 0
	var medal_cr := 0
	for m in med:
		medal_xp += int(m[1])
		medal_cr += int(m[2])
	var prime := 0
	for g in promo:
		prime += int(defs.grades[g].get("credits", 0))
	var after_unlocked := unlocked_set()
	var fresh: Array = []
	for id in after_unlocked.keys():
		if not unlocked_before.has(id):
			fresh.append(id)
	return {
		"xp_lines": xl, "xp_gain": gain_xp + medal_xp, "xp_before": before_xp, "xp_after": xp,
		"credits_lines": cl, "credits_gain": gain_cr + medal_cr + prime, "credits_after": credits,
		"medal_xp": medal_xp, "medal_credits": medal_cr, "promo_credits": prime,
		"grade_before": before_grade, "grade_after": grade_index(), "promotions": promo,
		"medals": med, "unlocked": fresh, "new_stars": new_stars, "new_rating": new_rating, "record": record,
		"stars_total": sector_stars(), "sectors_unlocked": Campaign.newly_unlocked(defs, stars_before, sector_stars()),
		"mode": mode, "daily": daily_rep, "endless": endless_rep,
	}


static func _fmt(n: int) -> String:
	if n >= 1000:
		return "%d %03d" % [n / 1000, n % 1000]
	return str(n)


static func _line(lines: Array, label: String, v: float) -> void:
	var n := int(round(v))
	if n != 0:
		lines.append([label, n])


## Ajoute une ligne qui ramène la somme des lignes présentes à somme × facteur.
static func _scale_lines(lines: Array, f: float, label: String) -> void:
	var s := _sum(lines)
	var delta := int(round(float(s) * f)) - s
	if delta != 0:
		lines.append([label, delta])


static func _sum(lines: Array) -> int:
	var s := 0
	for l in lines:
		s += int(l[1])
	return s
