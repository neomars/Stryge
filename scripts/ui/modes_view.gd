extends RefCounted
## Écran des modes de jeu hors campagne : le défi du jour (même scénario pour tous, série de jours, classement local) et la
## Nuit blanche (vagues sans fin sur un secteur ouvert, records par secteur). Écran de contrôles construit par Screens ;
## le départ recharge la scène (Game.start_daily, Game.start_endless).

const UiKit := preload("res://scripts/ui/ui_kit.gd")
const Daily := preload("res://scripts/meta/daily.gd")
const Campaign := preload("res://scripts/meta/campaign.gd")
const Mutators := preload("res://scripts/meta/mutators.gd")

var scr                                     # Screens
var ctx
var from := "briefing"                      # écran d'où la page a été ouverte
var date := ""                              # date du défi du jour (AAAA-MM-JJ)
var sector := 0                             # Nuit blanche : secteur choisi (indice dans defs.sectors)
var level := 0                              # Nuit blanche : difficulté choisie (indice dans defs.levels)
var unlocked := false
var _lv_buttons: Array = []
var _sec_name: Label
var _record: VBoxContainer


func setup(p_scr, p_ctx) -> void:
	scr = p_scr
	ctx = p_ctx


func build(v: VBoxContainer, p_from: String) -> void:
	from = p_from
	var defs = ctx.profile.defs
	unlocked = scr.game.modes_unlocked()
	date = Daily.today()
	sector = _open_near(maxi(defs.sector_index(str(ctx.mission.get("id", ""))), 0))
	level = maxi(defs.level_index(str(ctx.difficulty().get("id", defs.default_level))), 0)
	v.add_child(UiKit.label("MODES DE JEU", 30, UiKit.MAIN, HORIZONTAL_ALIGNMENT_CENTER))
	v.add_child(UiKit.label("Hors campagne : ni étoiles ni secteurs à ouvrir, mais de l'XP, des crédits, des médailles et des records.", 14, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER))
	v.add_child(UiKit.hline())
	if not unlocked:
		v.add_child(UiKit.label("Ces modes s'ouvrent après votre première victoire en campagne.", 16, UiKit.WARN, HORIZONTAL_ALIGNMENT_CENTER))
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 22)
	v.add_child(cols)
	_daily_card(cols)
	_endless_card(cols)
	v.add_child(UiKit.hline())
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	v.add_child(bar)
	var hint := UiKit.label("D : défi du jour    N : Nuit blanche    ←  →  secteur    ↑  ↓  ou  1 2 3  difficulté", 12, UiKit.DIM)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(hint)
	bar.add_child(UiKit.button("Retour   (Échap)", Callable(scr, "close_modes"), 220.0))
	_refresh_endless()


func _card(cols: HBoxContainer) -> VBoxContainer:
	var pc := PanelContainer.new()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pc.custom_minimum_size = Vector2(540, 0)
	pc.add_theme_stylebox_override("panel", UiKit.box(Color(0, 0, 0, 0.45), UiKit.LINE, 1, 16.0, 12.0))
	cols.add_child(pc)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 3)
	pc.add_child(cv)
	return cv


func _centered(b: Button) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_child(b)
	return h


# ---------------------------------------------------------------- défi du jour

func _daily_card(cols: HBoxContainer) -> void:
	var defs = ctx.profile.defs
	var prof = ctx.profile
	var cfg: Dictionary = defs.mode_cfg("daily")
	var plan: Dictionary = Daily.plan(defs, date)
	var cv := _card(cols)
	cv.add_child(UiKit.label("DÉFI DU JOUR", 13, UiKit.DIM))
	cv.add_child(UiKit.label(UiKit.date_fr(date), 24, UiKit.MAIN))
	cv.add_child(UiKit.row("Secteur", str(defs.sector(str(plan["sector"])).get("name", plan["sector"])), UiKit.DIM, UiKit.MAIN, 15))
	cv.add_child(UiKit.row("Difficulté", str(defs.level(str(plan["level"])).get("name", plan["level"])), UiKit.DIM, UiKit.MAIN, 15))
	var muts: Array = plan["mutators"]
	var mt := UiKit.row("Mutateurs", Mutators.names(defs, muts) if not muts.is_empty() else "aucun", UiKit.DIM, UiKit.GOLD if not muts.is_empty() else UiKit.MAIN, 15)
	cv.add_child(mt)
	var same := UiKit.label("Le même scénario pour tous les joueurs, à chaque essai de la journée.", 13, UiKit.DIM)
	cv.add_child(same)
	cv.add_child(UiKit.hline())
	var td: Dictionary = prof.daily_today(date)
	var tries := int(td.get("plays", 0))
	if bool(td.get("won", false)):
		cv.add_child(UiKit.row("Aujourd'hui", "réussi  ·  %d essai%s" % [tries, "s" if tries > 1 else ""], UiKit.DIM, UiKit.GOOD, 15))
	elif tries > 0:
		cv.add_child(UiKit.row("Aujourd'hui", "%d essai%s, pas encore réussi" % [tries, "s" if tries > 1 else ""], UiKit.DIM, UiKit.WARN, 15))
	else:
		cv.add_child(UiKit.row("Aujourd'hui", "pas encore tenté", UiKit.DIM, UiKit.MAIN, 15))
	var best := int(td.get("best", 0))
	cv.add_child(UiKit.row("Meilleur score du jour", UiKit.thousands(best) if best > 0 else "—", UiKit.DIM, UiKit.MAIN, 15))
	var streak: int = prof.daily_streak(date)
	cv.add_child(UiKit.row("Série de jours", "%d   (record %d)" % [streak, int(prof.daily.get("best_streak", 0))], UiKit.DIM, UiKit.GOLD if streak >= 2 else UiKit.MAIN, 15))
	var fs: Dictionary = cfg.get("first", {})
	var ss: Dictionary = cfg.get("streak", {})
	var prime: Label
	if bool(td.get("won", false)):
		prime = UiKit.label("Prime du jour déjà encaissée : revenez demain pour prolonger la série.", 13, UiKit.DIM)
	else:
		prime = UiKit.label("Premier défi réussi du jour : +%d XP, +%d crédits, puis +%d XP par jour de série (%d jours au plus)." %
				[int(fs.get("xp", 0)), int(fs.get("credits", 0)), int(ss.get("xp", 0)), int(ss.get("max_days", 7))], 13, UiKit.GOLD)
	prime.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prime.custom_minimum_size = Vector2(500, 0)
	cv.add_child(prime)
	cv.add_child(UiKit.hline())
	cv.add_child(UiKit.label("CLASSEMENT LOCAL", 13, UiKit.DIM))
	var board: Array = prof.daily.get("board", [])
	if board.is_empty():
		cv.add_child(UiKit.label("Aucune partie enregistrée.", 14, UiKit.DIM))
	for i in mini(board.size(), 4):
		var e: Dictionary = board[i]
		var nm := str(defs.sector(str(e.get("sector", ""))).get("name", ""))
		var now: bool = str(e.get("date", "")) == date
		cv.add_child(UiKit.row("%d.   %s   %s" % [i + 1, UiKit.date_fr(str(e.get("date", "")), true), nm],
				"%s   %s" % [UiKit.thousands(int(e.get("score", 0))), str(e.get("rating", "—"))], UiKit.GOLD if now else UiKit.DIM, UiKit.GOLD if now else UiKit.MAIN, 14))
	cv.add_child(UiKit.spacer(2))
	var go := UiKit.button("Jouer le défi du jour   (D)", Callable(self, "start_daily"), 320.0)
	go.disabled = not unlocked
	cv.add_child(_centered(go))


# ---------------------------------------------------------------- Nuit blanche

func _open_sectors() -> Array:
	var defs = ctx.profile.defs
	var out: Array = []
	for i in defs.sectors.size():
		if Campaign.is_unlocked(defs, ctx.profile, str(defs.sectors[i]["id"])):
			out.append(i)
	if out.is_empty():
		out.append(0)
	return out


## Secteur ouvert le plus proche de l'indice donné (lui-même s'il est ouvert).
func _open_near(i: int) -> int:
	var open: Array = _open_sectors()
	if open.has(i):
		return i
	var best: int = int(open[0])
	for k in open:
		if absi(int(k) - i) < absi(best - i):
			best = int(k)
	return best


func _endless_card(cols: HBoxContainer) -> void:
	var defs = ctx.profile.defs
	var cv := _card(cols)
	cv.add_child(UiKit.label("NUIT BLANCHE", 13, UiKit.DIM))
	cv.add_child(UiKit.label("Une nuit sans aube", 24, UiKit.MAIN))
	var t := UiKit.label("Les vagues se succèdent sans fin, de plus en plus nombreuses : colosses, hurleurs et alphas rejoignent la meute. " +
			"Vous décidez de la fin de la patrouille (Échap, puis Entrée) et vos points sont conservés.", 14, UiKit.MAIN)
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(500, 0)
	cv.add_child(t)
	cv.add_child(UiKit.hline())
	cv.add_child(UiKit.label("SECTEUR", 13, UiKit.DIM))
	var sr := HBoxContainer.new()
	sr.add_theme_constant_override("separation", 8)
	cv.add_child(sr)
	var prev := Button.new()
	prev.text = "<"
	prev.focus_mode = Control.FOCUS_NONE
	prev.custom_minimum_size = Vector2(44, 34)
	prev.pressed.connect(step_sector.bind(-1))
	sr.add_child(prev)
	_sec_name = UiKit.label("", 19, UiKit.MAIN, HORIZONTAL_ALIGNMENT_CENTER)
	_sec_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sr.add_child(_sec_name)
	var next := Button.new()
	next.text = ">"
	next.focus_mode = Control.FOCUS_NONE
	next.custom_minimum_size = Vector2(44, 34)
	next.pressed.connect(step_sector.bind(1))
	sr.add_child(next)
	cv.add_child(UiKit.label("DIFFICULTÉ", 13, UiKit.DIM))
	var lr := HBoxContainer.new()
	lr.add_theme_constant_override("separation", 6)
	cv.add_child(lr)
	_lv_buttons.clear()
	for i in defs.levels.size():
		var b := Button.new()
		b.text = str(defs.levels[i]["name"])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(150, 32)
		b.add_theme_font_size_override("font_size", 15)
		b.set_pressed_no_signal(i == level)
		b.pressed.connect(set_level.bind(i))
		lr.add_child(b)
		_lv_buttons.append(b)
	cv.add_child(UiKit.hline())
	_record = VBoxContainer.new()
	_record.add_theme_constant_override("separation", 3)
	cv.add_child(_record)
	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cv.add_child(sp)
	var go := UiKit.button("Commencer la Nuit blanche   (N)", Callable(self, "start_endless"), 320.0)
	go.disabled = not unlocked
	cv.add_child(_centered(go))


func step_sector(d: int) -> void:
	var open: Array = _open_sectors()
	var k: int = open.find(sector)
	if k < 0:
		k = 0
	sector = int(open[clampi(k + d, 0, open.size() - 1)])
	_refresh_endless()


func set_level(i: int) -> void:
	level = clampi(i, 0, ctx.profile.defs.levels.size() - 1)
	for k in _lv_buttons.size():
		(_lv_buttons[k] as Button).set_pressed_no_signal(k == level)


## Nom du secteur choisi, son record de Nuit blanche et les mutateurs conservés.
func _refresh_endless() -> void:
	var defs = ctx.profile.defs
	var prof = ctx.profile
	var sc: Dictionary = defs.sectors[sector]
	var open: Array = _open_sectors()
	_sec_name.text = "%s   (%d / %d)" % [str(sc["name"]).to_upper(), open.find(sector) + 1, open.size()]
	for c in _record.get_children():
		_record.remove_child(c)
		c.queue_free()
	var rec: Dictionary = prof.endless_record(str(sc["id"]))
	_record.add_child(UiKit.label("RECORD SUR CE SECTEUR", 13, UiKit.DIM))
	if int(rec["plays"]) > 0:
		_record.add_child(UiKit.row("Vagues tenues", str(int(rec["best_waves"])), UiKit.DIM, UiKit.GOLD, 15))
		_record.add_child(UiKit.row("Meilleur score", UiKit.thousands(int(rec["best_score"])), UiKit.DIM, UiKit.MAIN, 15))
		_record.add_child(UiKit.row("Plus longue patrouille", UiKit.duration_fr(int(rec["best_time"])), UiKit.DIM, UiKit.MAIN, 15))
	else:
		_record.add_child(UiKit.label("Jamais joué sur ce secteur.", 14, UiKit.DIM))
	if not ctx.mutators.is_empty() and ctx.mode != "daily":
		var mu := UiKit.label("Mutateurs conservés :  %s" % Mutators.names(defs, ctx.mutators), 13, UiKit.GOLD)
		mu.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		mu.custom_minimum_size = Vector2(500, 0)
		_record.add_child(mu)


# ---------------------------------------------------------------- départs

func start_daily() -> void:
	if not unlocked:
		scr.toast("Ces modes s'ouvrent après votre première victoire en campagne.")
		return
	scr.game.start_daily(date)


func start_endless() -> void:
	if not unlocked:
		scr.toast("Ces modes s'ouvrent après votre première victoire en campagne.")
		return
	var defs = ctx.profile.defs
	var muts: Array = [] if ctx.mode == "daily" else ctx.mutators.duplicate()
	scr.game.start_endless(str(defs.sectors[sector]["id"]), str(defs.levels[level]["id"]), muts)


func handle_key(ev: InputEventKey) -> bool:
	match ev.keycode:
		KEY_D:
			start_daily()
		KEY_N:
			start_endless()
		KEY_LEFT:
			step_sector(-1)
		KEY_RIGHT:
			step_sector(1)
		KEY_UP:
			set_level(level + 1)
		KEY_DOWN:
			set_level(level - 1)
		KEY_1, KEY_KP_1:
			set_level(0)
		KEY_2, KEY_KP_2:
			set_level(1)
		KEY_3, KEY_KP_3:
			set_level(2)
		_:
			return false
	return true
