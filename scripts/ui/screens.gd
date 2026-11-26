extends RefCounted
## Écrans de menu et de débriefing (nœuds Control posés au-dessus de la vue thermique).

const UiKit := preload("res://scripts/ui/ui_kit.gd")
const Hangar := preload("res://scripts/ui/hangar.gd")
const CampaignView := preload("res://scripts/ui/campaign_view.gd")
const MutatorsView := preload("res://scripts/ui/mutators_view.gd")
const ModesView := preload("res://scripts/ui/modes_view.gd")
const Campaign := preload("res://scripts/meta/campaign.gd")
const Mutators := preload("res://scripts/meta/mutators.gd")
const Daily := preload("res://scripts/meta/daily.gd")

var ctx
var game
var root: Control
var current: Control = null
var mode := ""                # briefing | hangar | campaign | mutators | modes | debrief | "" (aucun écran)
var _pages: Array = []        # pages du débriefing (Control)
var _tabs: Array = []         # boutons d'onglet
var _page := 0
var _hangar = null
var _back := "briefing"       # écran d'où l'atelier a été ouvert
var _campaign = null
var _camp_back := "briefing"  # écran d'où la carte de campagne a été ouverte
var _mutators = null
var _modes = null
var _modes_back := "briefing" # écran d'où la page des modes de jeu a été ouverte
var _last_res: Dictionary = {}


func setup(p_ctx, p_game, layer: CanvasLayer) -> void:
	ctx = p_ctx
	game = p_game
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiKit.make_theme()
	layer.add_child(root)


func is_open() -> bool:
	return current != null


func close() -> void:
	mode = ""
	if current != null:
		current.queue_free()
		current = null


## Bandeau passager en haut de l'écran (médaille obtenue, achat...).
func toast(text: String) -> void:
	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	cc.offset_top = 22.0
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pc := PanelContainer.new()
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_child(UiKit.label(text, 18, UiKit.GOLD, HORIZONTAL_ALIGNMENT_CENTER))
	cc.add_child(pc)
	root.add_child(cc)
	var tw := cc.create_tween()
	tw.tween_interval(2.6)
	tw.tween_property(cc, "modulate:a", 0.0, 0.6)
	tw.tween_callback(cc.queue_free)


func apply_cosmetics() -> void:
	game.apply_cosmetics()


## Fond sombre, panneau centré de largeur donnée. Retourne la boîte verticale à remplir.
func _frame(width: float, dim: float = 0.66) -> VBoxContainer:
	close()
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, dim)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(bg)
	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_child(cc)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(width, 0)
	cc.add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	pc.add_child(v)
	current = bg
	return v


# ---------------------------------------------------------------- débriefing

## Touches des écrans ouverts. Retourne vrai si la touche est consommée.
func handle_key(ev: InputEventKey) -> bool:
	if current == null or not ev.pressed or ev.echo:
		return false
	match mode:
		"hangar":
			if ev.keycode == KEY_ESCAPE:
				close_hangar()
			elif _hangar != null:
				_hangar.handle_key(ev)
			return true                   # rien ne passe au jeu pendant l'atelier
		"campaign":
			if ev.keycode == KEY_ESCAPE:
				close_campaign()
			elif ev.keycode == KEY_J:
				open_modes("campaign")
			elif _campaign != null:
				_campaign.handle_key(ev)
			return true                   # rien ne passe au jeu pendant la carte
		"mutators":
			if ev.keycode == KEY_ESCAPE or ev.keycode == KEY_U or ev.keycode == KEY_ENTER or ev.keycode == KEY_KP_ENTER:
				close_mutators()
			elif _mutators != null:
				_mutators.handle_key(ev)
			return true
		"modes":
			if ev.keycode == KEY_ESCAPE or ev.keycode == KEY_J:
				close_modes()
			elif _modes != null:
				_modes.handle_key(ev)
			return true
		"briefing":
			match ev.keycode:
				KEY_ENTER, KEY_KP_ENTER:
					game.start_mission()
					return true
				KEY_A:
					open_hangar("briefing")
					return true
				KEY_K:
					open_campaign("briefing")
					return true
				KEY_U:
					open_mutators()
					return true
				KEY_J:
					open_modes("briefing")
					return true
				KEY_UP:
					_step_difficulty(1)
					return true
				KEY_DOWN:
					_step_difficulty(-1)
					return true
		"debrief":
			match ev.keycode:
				KEY_A:
					open_hangar("debrief")
					return true
				KEY_K:
					open_campaign("debrief")
					return true
				KEY_J:
					open_modes("debrief")
					return true
				KEY_LEFT:
					_show_page(maxi(_page - 1, 0))
					return true
				KEY_RIGHT:
					_show_page(mini(_page + 1, _pages.size() - 1))
					return true
				KEY_TAB:
					_show_page((_page + 1) % _pages.size())
					return true
	return false


func _show_page(i: int) -> void:
	_page = clampi(i, 0, _pages.size() - 1)
	for k in _pages.size():
		_pages[k].visible = k == _page
		_tabs[k].set_pressed_no_signal(k == _page)


func show_debrief(res: Dictionary) -> void:
	_last_res = res
	var v := _frame(900.0)
	mode = "debrief"
	_pages.clear()
	_tabs.clear()
	_page = 0
	var won: bool = res["won"]
	var gmode := str(res.get("mode", "campaign"))
	var title := "MISSION ACCOMPLIE" if won else "SECTEUR PERDU"
	if gmode == "daily":
		title = "DÉFI DU JOUR RÉUSSI" if won else "DÉFI DU JOUR : SECTEUR PERDU"
	elif gmode == "endless":
		title = "PATROUILLE TERMINÉE" if won else "LE SECTEUR EST TOMBÉ"
	v.add_child(UiKit.label(title, 34, UiKit.GOOD if won else UiKit.WARN, HORIZONTAL_ALIGNMENT_CENTER))
	var lvl: Dictionary = ctx.profile.defs.level(str(res.get("difficulty", "")))
	var why := str(res["reason"]) if (gmode == "campaign" or not won) else ""
	if not lvl.is_empty():
		why += ("   ·   " if why != "" else "") + "difficulté %s" % str(lvl["name"]).to_lower()
	if gmode == "daily" and str(res.get("date", "")) != "":
		why += "   ·   %s" % UiKit.date_fr(str(res["date"]))
	var muts_res: Array = res.get("mutators", [])
	if not muts_res.is_empty():
		why += "   ·   mutateurs : %s" % Mutators.names(ctx.profile.defs, muts_res)
	var wl := UiKit.label(why, 15, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	wl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wl.custom_minimum_size = Vector2(840, 0)
	v.add_child(wl)
	v.add_child(UiKit.hline())

	# note, étoiles, score
	var top := HBoxContainer.new()
	top.alignment = BoxContainer.ALIGNMENT_CENTER
	top.add_theme_constant_override("separation", 56)
	v.add_child(top)
	var rating: String = res["rating"]
	var c1 := VBoxContainer.new()
	c1.add_theme_constant_override("separation", 0)
	c1.add_child(UiKit.label("NOTE", 13, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER))
	c1.add_child(UiKit.label(rating, 54, UiKit.rating_color(rating), HORIZONTAL_ALIGNMENT_CENTER))
	top.add_child(c1)
	var c2 := VBoxContainer.new()
	c2.add_theme_constant_override("separation", 0)
	if gmode == "daily":
		var streak_n := int(res.get("progress", {}).get("daily", {}).get("streak", 0))
		c2.add_child(UiKit.label("SÉRIE DE JOURS", 13, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER))
		c2.add_child(UiKit.label(str(streak_n), 54, UiKit.GOLD if streak_n >= 2 else UiKit.MAIN, HORIZONTAL_ALIGNMENT_CENTER))
	elif gmode == "endless":
		c2.add_child(UiKit.label("VAGUES", 13, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER))
		c2.add_child(UiKit.label(str(int(res.get("waves", 0))), 54, UiKit.MAIN, HORIZONTAL_ALIGNMENT_CENTER))
	else:
		c2.add_child(UiKit.label("ÉTOILES", 13, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER))
		var sr := UiKit.StarsRow.new()
		sr.setup(int(res["n_stars"]), maxi(res["stars"].size(), 3), 34.0)
		c2.add_child(sr)
	top.add_child(c2)
	var c3 := VBoxContainer.new()
	c3.add_theme_constant_override("separation", 0)
	c3.add_child(UiKit.label("SCORE", 13, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER))
	c3.add_child(UiKit.label(UiKit.thousands(int(res["total"])), 40, UiKit.MAIN, HORIZONTAL_ALIGNMENT_CENTER))
	top.add_child(c3)
	v.add_child(UiKit.hline())

	# onglets
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	v.add_child(tabs)
	var names: Array = ["BILAN", "OBJECTIFS", "PROGRESSION"]
	for i in names.size():
		var b := Button.new()
		b.text = str(names[i])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(160, 30)
		b.pressed.connect(_show_page.bind(i))
		tabs.add_child(b)
		_tabs.append(b)
	var hint := UiKit.label("←  →  pour changer de page", 12, UiKit.DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_child(hint)

	# pages (hauteur fixe : le cadre ne bouge pas quand on change d'onglet)
	var holder := VBoxContainer.new()
	holder.custom_minimum_size = Vector2(0, 296)
	v.add_child(holder)
	for page in [_page_bilan(res), _page_objectives(res), _page_progress(res)]:
		holder.add_child(page)
		_pages.append(page)
	_show_page(0)

	# « il vous manquait… »
	var gaps: Array = []
	var defs_d = ctx.profile.defs
	if gmode == "daily":
		if won:
			gaps.append("Revenez demain : un nouveau défi prolongera votre série.")
		else:
			gaps.append("Même scénario, nouvelle tentative : la prime attend votre première victoire du jour.")
		if str(res["rating_next"]) != "":
			gaps.append("Encore %s points pour la note %s." % [UiKit.thousands(int(res["rating_missing"])), res["rating_next"]])
	elif gmode == "endless":
		if str(res["rating_next"]) != "":
			gaps.append("Encore %s points pour la note %s." % [UiKit.thousands(int(res["rating_missing"])), res["rating_next"]])
		var er_best: int = int(ctx.profile.endless_record(str(res.get("sector", ctx.mission.get("id", "")))).get("best_waves", 0))
		gaps.append("Record du secteur : %d vague%s." % [er_best, "s" if er_best > 1 else ""])
	else:
		if won:
			for s in res["stars"]:
				if not s["ok"] and str(s["gap"]) != "":
					gaps.append(str(s["gap"]))
					break
			if str(res["rating_next"]) != "":
				gaps.append("Encore %s points pour la note %s." % [UiKit.thousands(int(res["rating_missing"])), res["rating_next"]])
			var hid: Array = res["objectives"]["hidden"]
			var unknown := 0
			for h in hid:
				if not h["found"]:
					unknown += 1
			if unknown > 0:
				gaps.append("%d objectif%s bonus à découvrir." % [unknown, "s" if unknown > 1 else ""])
		else:
			gaps.append("Tenez le secteur jusqu'à l'aube pour décrocher notes et étoiles.")
	var fresh_sec: Array = res.get("progress", {}).get("sectors_unlocked", [])
	if not fresh_sec.is_empty():
		var sec_names: Array = []
		for sid in fresh_sec:
			sec_names.append(str(defs_d.sector(str(sid)).get("name", sid)))
		v.add_child(UiKit.label("NOUVEAU SECTEUR OUVERT :  %s" % "  ·  ".join(sec_names), 19, UiKit.GOOD, HORIZONTAL_ALIGNMENT_CENTER))
	elif gmode == "campaign":
		var nxt: Dictionary = Campaign.next_locked(defs_d, ctx.profile)
		if not nxt.is_empty():
			var miss: int = Campaign.stars_missing(defs_d, ctx.profile, str(nxt["id"]))
			gaps.append("Encore %d étoile%s pour ouvrir %s." % [miss, "s" if miss > 1 else "", str(nxt["name"])])
	if not gaps.is_empty():
		var g := UiKit.label("  ".join(gaps), 15, UiKit.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
		g.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(g)

	# boutons
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	v.add_child(bar)
	var shop := UiKit.button("Atelier   (A)", Callable(self, "open_hangar").bind("debrief"), 180.0)
	bar.add_child(shop)
	var camp := UiKit.button("Campagne   (K)", Callable(self, "open_campaign").bind("debrief"), 200.0)
	bar.add_child(camp)
	var modes_b := UiKit.button("Modes   (J)", Callable(self, "open_modes").bind("debrief"), 160.0)
	bar.add_child(modes_b)
	var replay := UiKit.button("Rejouer   (Entrée)", Callable(game, "replay"), 240.0)
	bar.add_child(replay)
	replay.grab_focus()


func _col(title: String) -> VBoxContainer:
	var c := VBoxContainer.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_theme_constant_override("separation", 2)
	c.add_child(UiKit.label(title, 14, UiKit.DIM))
	return c


## Détail des civils perdus, cause par cause (Director.dead_by) : d'où viennent les pertes, pour qu'on sache quoi changer.
## Les civils tués par nos tirs ne comptent dans le seuil que pour une part (difficulté) : on la rappelle sur leurs lignes.
func _loss_rows(box: Control, res: Dictionary) -> void:
	var dead: Dictionary = res.get("dead_by", {})
	if dead.is_empty():                       # résultat d'une ancienne forme : on garde le résumé d'avant
		box.add_child(UiKit.row("   dévorés %d  ·  dégâts collatéraux %d" % [res["eaten"], res["collateral"]], "", UiKit.DIM, UiKit.DIM, 13))
		return
	var w: float = float(res.get("collateral_weight", 1.0))
	var part := "" if w >= 0.999 else " (comptés à %d %%)" % int(round(w * 100.0))
	var ok_n: int = int(res.get("contained", 0))                 # ensevelis sous un immeuble déjà perdu : ce n'est pas une bavure
	var rows := [
		["dévorés dans un immeuble", "", int(dead.get("inside", 0))],
		["dévorés dans la rue", "", int(dead.get("street", 0))],
		["tués par vos tirs", part, int(dead.get("shot", 0))],
		["ensevelis sous un immeuble qui tenait encore", part, int(dead.get("razed", 0)) - ok_n],
		["ensevelis sous un immeuble déjà perdu", part, ok_n],
	]
	for r in rows:
		if int(r[2]) > 0:
			box.add_child(UiKit.row("   %s%s" % [r[0], r[1]], str(int(r[2])), UiKit.DIM, UiKit.DIM, 13))


## Page 1 : bilan chiffré, décompte des points, conditions d'étoiles.
func _page_bilan(res: Dictionary) -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 6)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 48)
	page.add_child(cols)
	var left := _col("BILAN")
	left.add_child(UiKit.row("Civils sauvés", str(res["saved"]), UiKit.MAIN, UiKit.GOOD))
	left.add_child(UiKit.row("Civils perdus", "%d / %d" % [res["lost"], res["max_lost"]]))
	_loss_rows(left, res)
	left.add_child(UiKit.row("Infectés neutralisés", str(res["kills"])))
	left.add_child(UiKit.row("Immeubles détruits", str(res["destroyed"])))
	var acc: float = float(res["accuracy"])
	left.add_child(UiKit.row("Obus lourds efficaces", "%d %%" % int(round(100.0 * acc)) if acc >= 0.0 else "—"))
	left.add_child(UiKit.row("Meilleure série", "%d" % int(res["stats"]["chain_best"])))
	cols.add_child(left)
	var right := _col("DÉCOMPTE DES POINTS")
	var sub: int = int(res["subtotal"])
	right.add_child(UiKit.row("Combat et sauvetages", UiKit.thousands(sub), UiKit.MAIN, UiKit.WARN if sub < 0 else UiKit.MAIN))
	for b in res["bonuses"]:
		right.add_child(UiKit.row(str(b[0]), "+" + UiKit.thousands(int(b[1])), UiKit.DIM, UiKit.GOOD, 14))
	right.add_child(UiKit.hline())
	right.add_child(UiKit.row("TOTAL", UiKit.thousands(int(res["total"])), UiKit.MAIN, UiKit.MAIN, 20))
	cols.add_child(right)
	page.add_child(UiKit.hline())
	if str(res.get("mode", "campaign")) != "campaign":
		_mode_block(page, res)
		return page
	for s in res["stars"]:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		var icon := UiKit.StarsRow.new()
		icon.setup(1 if s["ok"] else 0, 1, 18.0)
		h.add_child(icon)
		h.add_child(UiKit.label(str(s["text"]), 15, UiKit.MAIN if s["ok"] else UiKit.DIM))
		page.add_child(h)
	return page


static func _ordinal(n: int) -> String:
	return "1er" if n == 1 else "%de" % n


## Bas de la page « bilan » hors campagne : classement et série (défi du jour) ou vagues et records (Nuit blanche).
func _mode_block(page: VBoxContainer, res: Dictionary) -> void:
	var pr: Dictionary = res.get("progress", {})
	var prof = ctx.profile
	if str(res.get("mode", "")) == "daily":
		var dr: Dictionary = pr.get("daily", {})
		var date := str(res.get("date", ""))
		page.add_child(UiKit.label("DÉFI DU JOUR  ·  %s" % UiKit.date_fr(date), 14, UiKit.DIM))
		var rank := int(dr.get("rank", 0))
		var n_board: int = (prof.daily.get("board", []) as Array).size()
		page.add_child(UiKit.row("Classement local", ("%s sur %d" % [_ordinal(rank), n_board]) if rank > 0 else "hors du classement",
				UiKit.DIM, UiKit.GOLD if rank == 1 else UiKit.MAIN, 15))
		page.add_child(UiKit.row("Série de jours", "%d" % int(dr.get("streak", 0)), UiKit.DIM, UiKit.GOLD if int(dr.get("streak", 0)) >= 2 else UiKit.MAIN, 15))
		if bool(dr.get("first_win", false)):
			page.add_child(UiKit.label("Premier défi du jour réussi : la prime est ajoutée à vos gains.", 15, UiKit.GOOD))
		elif bool(res.get("won", false)):
			page.add_child(UiKit.label("Prime du jour déjà encaissée.", 15, UiKit.DIM))
		else:
			page.add_child(UiKit.label("Pas de prime tant que le défi n'est pas réussi.", 15, UiKit.DIM))
	else:
		var er: Dictionary = pr.get("endless", {})
		var rec: Dictionary = prof.endless_record(str(res.get("sector", ctx.mission.get("id", ""))))
		page.add_child(UiKit.label("NUIT BLANCHE", 14, UiKit.DIM))
		page.add_child(UiKit.row("Vagues tenues", "%d%s" % [int(res.get("waves", 0)), "   NOUVEAU RECORD" if bool(er.get("record_waves", false)) else "   (record %d)" % int(rec.get("best_waves", 0))],
				UiKit.DIM, UiKit.GOLD if bool(er.get("record_waves", false)) else UiKit.MAIN, 15))
		page.add_child(UiKit.row("Durée de la patrouille", "%s%s" % [UiKit.duration_fr(int(res.get("time", 0.0))), "   NOUVEAU RECORD" if bool(er.get("record_time", false)) else ""],
				UiKit.DIM, UiKit.GOLD if bool(er.get("record_time", false)) else UiKit.MAIN, 15))
		page.add_child(UiKit.row("Score", "%s%s" % [UiKit.thousands(int(res.get("total", 0))), "   NOUVEAU RECORD" if bool(er.get("record_score", false)) else ""],
				UiKit.DIM, UiKit.GOLD if bool(er.get("record_score", false)) else UiKit.MAIN, 15))


func _obj_row(state: int, title: String, note: String, right: String, rcol: Color, dim: bool = false) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var icon := UiKit.ResultIcon.new()
	icon.setup(state, 18.0)
	h.add_child(icon)
	var t := UiKit.label(title, 15, UiKit.DIM if dim else UiKit.MAIN)
	t.custom_minimum_size = Vector2(190, 0)
	h.add_child(t)
	var n := UiKit.label(note, 13, UiKit.DIM)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.clip_text = true
	h.add_child(n)
	h.add_child(UiKit.label(right, 15, rcol, HORIZONTAL_ALIGNMENT_RIGHT))
	return h


## Page 2 : objectifs secondaires (réussis ou perdus) et objectifs bonus (découverts ou non).
func _page_objectives(res: Dictionary) -> Control:
	var o: Dictionary = res["objectives"]
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 3)
	page.add_child(UiKit.label("OBJECTIFS ANNONCÉS PAR LA RADIO", 14, UiKit.DIM))
	var sec: Array = o["secondary"]
	if sec.is_empty():
		page.add_child(UiKit.label("Aucun objectif n'a été transmis.", 15, UiKit.DIM))
	for s in sec:
		if s["ok"]:
			page.add_child(_obj_row(1, str(s["title"]), str(s["text"]), "+" + UiKit.thousands(int(s["pts"])), UiKit.GOOD))
		else:
			page.add_child(_obj_row(0, str(s["title"]), str(s["why"]), "perdu", UiKit.WARN, true))
	page.add_child(UiKit.spacer(4))
	var hid: Array = o["hidden"]
	var found := 0
	for h in hid:
		if h["found"]:
			found += 1
	page.add_child(UiKit.label("OBJECTIFS BONUS NON ANNONCÉS  (%d / %d découverts)" % [found, hid.size()], 14, UiKit.DIM))
	for h in hid:
		if h["found"]:
			page.add_child(_obj_row(1, str(h["title"]), str(h["text"]), "+" + UiKit.thousands(int(h["pts"])), UiKit.GOOD))
		else:
			page.add_child(_obj_row(-1, "? ? ?", "objectif bonus non découvert", "", UiKit.DIM, true))
	return page


# ---------------------------------------------------------------- page « Progression » du débriefing

func _page_progress(res: Dictionary) -> Control:
	var pr: Dictionary = res.get("progress", {})
	var page := HBoxContainer.new()
	page.add_theme_constant_override("separation", 36)
	if pr.is_empty():
		page.add_child(UiKit.label("Profil non disponible.", 15, UiKit.DIM))
		return page
	var prof = ctx.profile
	var defs = prof.defs
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 3)
	page.add_child(left)
	var g_after: int = int(pr["grade_after"])
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	var ic := UiKit.InsigniaIcon.new()
	ic.setup(prof.equipped_item("insignia").get("shape", []), 52.0)
	head.add_child(ic)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 0)
	hv.add_child(UiKit.label(str(defs.grades[g_after]["name"]).to_upper(), 22, UiKit.MAIN))
	hv.add_child(UiKit.label("+%s XP" % UiKit.thousands(int(pr["xp_gain"])), 17, UiKit.GOLD))
	head.add_child(hv)
	left.add_child(head)
	# barre : part du grade avant la mission, part gagnée
	var lo: int = int(defs.grades[g_after]["xp"])
	var hi: int = int(defs.grades[g_after + 1]["xp"]) if g_after + 1 < defs.grades.size() else -1
	var promoted: bool = int(pr["grade_after"]) > int(pr["grade_before"])
	var bar := UiKit.XpBar.new()
	if hi > lo:
		var f_after: float = float(int(pr["xp_after"]) - lo) / float(hi - lo)
		var f_before: float = 0.0 if promoted else float(int(pr["xp_before"]) - lo) / float(hi - lo)
		bar.setup(380.0, f_before, f_after, "%s XP" % UiKit.thousands(int(pr["xp_after"])), "prochain grade : %s XP" % UiKit.thousands(hi))
	else:
		bar.setup(380.0, 1.0, 1.0, "%s XP" % UiKit.thousands(int(pr["xp_after"])), "grade maximal")
	left.add_child(bar)
	if promoted:
		left.add_child(UiKit.label("PROMOTION  ·  %s   (+%s crédits)" % [defs.grades[g_after]["name"], UiKit.thousands(int(pr["promo_credits"]))], 16, UiKit.GOLD))
	for l in pr["xp_lines"]:
		var n: int = int(l[1])
		left.add_child(UiKit.row(str(l[0]), ("+" if n > 0 else "") + UiKit.thousands(n), UiKit.DIM, UiKit.GOOD if n > 0 else UiKit.WARN, 14))
	if int(pr["medal_xp"]) > 0:
		left.add_child(UiKit.row("Médailles", "+" + UiKit.thousands(int(pr["medal_xp"])), UiKit.DIM, UiKit.GOOD, 14))

	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(400, 290)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(sc)
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(390, 0)
	right.add_theme_constant_override("separation", 3)
	sc.add_child(right)
	right.add_child(UiKit.label("CRÉDITS D'APPUI", 14, UiKit.DIM))
	for l in pr["credits_lines"]:
		var n2: int = int(l[1])
		right.add_child(UiKit.row(str(l[0]), ("+" if n2 > 0 else "") + UiKit.thousands(n2), UiKit.DIM, UiKit.GOOD if n2 > 0 else UiKit.WARN, 14))
	if int(pr["medal_credits"]) + int(pr["promo_credits"]) > 0:
		right.add_child(UiKit.row("Médailles et promotion", "+" + UiKit.thousands(int(pr["medal_credits"]) + int(pr["promo_credits"])), UiKit.DIM, UiKit.GOOD, 14))
	right.add_child(UiKit.hline())
	right.add_child(UiKit.row("Gain  (solde %s)" % UiKit.thousands(int(pr["credits_after"])), "+" + UiKit.thousands(int(pr["credits_gain"])), UiKit.MAIN, UiKit.GOLD, 16))
	var meds: Array = pr["medals"]
	if not meds.is_empty():
		right.add_child(UiKit.spacer(4))
		right.add_child(UiKit.label("MÉDAILLES OBTENUES (%d)" % meds.size(), 14, UiKit.DIM))
		for m in meds:
			var md: Dictionary = defs.medal_by_id[str(m[0])]
			var h := HBoxContainer.new()
			h.add_theme_constant_override("separation", 8)
			var mi := UiKit.MedalIcon.new()
			mi.setup(str(md["tier"]), true, 28.0)
			h.add_child(mi)
			var tv := VBoxContainer.new()
			tv.add_theme_constant_override("separation", 0)
			tv.add_child(UiKit.label(str(md["name"]), 15, UiKit.tier_color(str(md["tier"]))))
			tv.add_child(UiKit.label(str(md["text"]), 11, UiKit.DIM))
			h.add_child(tv)
			right.add_child(h)
	var fresh: Array = pr["unlocked"]
	if not fresh.is_empty():
		right.add_child(UiKit.spacer(4))
		right.add_child(UiKit.label("NOUVEAUX COSMÉTIQUES", 14, UiKit.DIM))
		for id in fresh:
			var c: Dictionary = defs.cos_by_id[str(id)]
			var sl := ""
			for sd in defs.slots:
				if str(sd["id"]) == str(c["slot"]):
					sl = str(sd["name"]).to_lower()
			right.add_child(UiKit.label("%s  (%s)" % [c["name"], sl], 14, UiKit.GOOD))
	return page


# ---------------------------------------------------------------- briefing

func show_briefing() -> void:
	var v := _frame(1080.0, 0.72)
	v.add_theme_constant_override("separation", 4)   # le briefing est le panneau le plus haut : il doit tenir dans 720 px
	mode = "briefing"
	var prof = ctx.profile
	var m: Dictionary = ctx.mission
	v.add_child(UiKit.label("STRYGE", 38, UiKit.MAIN, HORIZONTAL_ALIGNMENT_CENTER))
	var defs_b = prof.defs
	var sec_i: int = defs_b.sector_index(str(m.get("id", "")))
	var bmode: String = ctx.mode
	var sub := str(m.get("title", ""))
	if sec_i >= 0:
		sub += "   ·   secteur %d sur %d" % [sec_i + 1, defs_b.sectors.size()]
	if bmode == "daily":
		sub = "DÉFI DU JOUR   ·   %s   ·   %s" % [UiKit.date_fr(str(game.session.get("date", ""))), sub]
	elif bmode == "endless":
		sub = "NUIT BLANCHE   ·   %s" % sub
	v.add_child(UiKit.label(sub, 18, UiKit.GOLD if bmode != "campaign" else UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER))
	v.add_child(UiKit.hline())
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 36)
	v.add_child(cols)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 4)
	cols.add_child(left)
	var brief := UiKit.label(str(m.get("briefing", "")), 16, UiKit.MAIN)
	brief.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	brief.custom_minimum_size = Vector2(560, 0)
	left.add_child(brief)
	left.add_child(UiKit.spacer(4))
	var prim: Dictionary = m.get("primary", {})
	left.add_child(UiKit.label("OBJECTIF PRINCIPAL", 13, UiKit.DIM))
	var ptitle := "Tenir le plus longtemps possible" if bmode == "endless" else str(prim.get("title", "Tenir le secteur"))
	left.add_child(UiKit.label(ptitle.to_upper(), 19, UiKit.GOLD))
	left.add_child(UiKit.label("Le secteur tombe au-delà de %d civils perdus." % ctx.director.max_lost, 15, UiKit.WARN))
	if ctx.director.collateral_weight < 0.999 and ctx.director.collateral_counts:
		# une seule ligne : le panneau tient tout juste dans 720 px de haut (voir _print_panel_fit du pilote automatique)
		left.add_child(UiKit.label("Civils tués par vos tirs : comptés à %d %% dans ce total (score et étoiles : 100 %%)." % int(round(ctx.director.collateral_weight * 100.0)), 14, UiKit.DIM))
	# la règle du tireur, en une ligne (le détail est dans l'aide, touche H) ; le panneau est réduit au besoin par _fit_panel
	left.add_child(UiKit.label("Raser un immeuble tue tous ses habitants : seulement s'il est déjà perdu (aide : H).", 14, UiKit.DIM))
	if ctx.objectives != null and not ctx.objectives.items.is_empty():
		var n_sec := 0
		var n_hid := 0
		for it in ctx.objectives.items:
			if it["kind"] == "hidden":
				n_hid += 1
			else:
				n_sec += 1
		var hid := " ; %d bonus restent cachés" % n_hid if n_hid > 1 else (" ; un bonus reste caché" if n_hid == 1 else "")
		var rtxt := "La radio annonce jusqu'à %d objectifs secondaires%s." % [n_sec, hid]
		if bmode == "endless" and n_sec > 0:
			rtxt = "La radio annonce des objectifs par cycles%s." % hid
		elif n_sec == 0:
			rtxt = "La panne radio ne laisse que les objectifs bonus, jamais annoncés."
		var rl := UiKit.label(rtxt, 14, UiKit.DIM)
		rl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rl.custom_minimum_size = Vector2(560, 0)
		left.add_child(rl)
	left.add_child(UiKit.spacer(4))
	var rec: Dictionary = prof.mission_record(str(m.get("id", "mission")))
	if bmode == "campaign":
		left.add_child(UiKit.label("ÉTOILES À DÉCROCHER", 13, UiKit.DIM))
		var sd: Array = rec["stars_done"]
		var stars: Array = m.get("stars", [])
		for i in stars.size():
			var done: bool = i < sd.size() and bool(sd[i])
			var h := HBoxContainer.new()
			h.add_theme_constant_override("separation", 8)
			var ic := UiKit.StarsRow.new()
			ic.setup(1 if done else 0, 1, 18.0)
			h.add_child(ic)
			h.add_child(UiKit.label(str(stars[i].get("text", "")), 15, UiKit.MAIN if not done else UiKit.GOOD))
			left.add_child(h)
	else:
		left.add_child(UiKit.label("DÉFI DU JOUR" if bmode == "daily" else "NUIT BLANCHE", 13, UiKit.DIM))
		var rule := _mode_rule(bmode)
		for ln in rule:
			var rl2 := UiKit.label(str(ln), 14, UiKit.MAIN)
			rl2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			rl2.custom_minimum_size = Vector2(560, 0)
			left.add_child(rl2)
	left.add_child(UiKit.spacer(4))
	var drow := HBoxContainer.new()
	drow.add_theme_constant_override("separation", 6)
	left.add_child(drow)
	var dl := UiKit.label("DIFFICULTÉ", 13, UiKit.DIM)
	dl.custom_minimum_size = Vector2(104, 0)
	drow.add_child(dl)
	var cur_lv: Dictionary = ctx.difficulty()
	var cur_id := str(cur_lv.get("id", defs_b.default_level))
	for lvd in defs_b.levels:
		var lb := Button.new()
		lb.text = str(lvd["name"])
		lb.toggle_mode = true
		lb.focus_mode = Control.FOCUS_NONE
		lb.custom_minimum_size = Vector2(112, 30)
		lb.add_theme_font_size_override("font_size", 15)
		lb.set_pressed_no_signal(str(lvd["id"]) == cur_id)
		lb.disabled = bmode == "daily"
		lb.pressed.connect(_pick_difficulty.bind(str(lvd["id"])))
		drow.add_child(lb)
	if not cur_lv.is_empty():
		var lt := UiKit.label(("%s  (↑ ↓)" % str(cur_lv.get("text", ""))) if bmode != "daily" else "Difficulté imposée par le défi du jour.", 13, UiKit.DIM)
		lt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lt.custom_minimum_size = Vector2(560, 0)
		left.add_child(lt)
	# mutateurs
	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 6)
	left.add_child(mrow)
	var ml := UiKit.label("MUTATEURS", 13, UiKit.DIM)
	ml.custom_minimum_size = Vector2(104, 0)
	mrow.add_child(ml)
	var mb := Button.new()
	mb.text = "Choisir   (U)" if bmode != "daily" else "Voir   (U)"
	mb.focus_mode = Control.FOCUS_NONE
	mb.custom_minimum_size = Vector2(150, 30)
	mb.add_theme_font_size_override("font_size", 15)
	mb.pressed.connect(open_mutators)
	mrow.add_child(mb)
	var mtxt := "aucun"
	if not ctx.mutators.is_empty():
		var pct := int(round((Mutators.reward_mult(defs_b, ctx.mutators) - 1.0) * 100.0))
		mtxt = "%s   (%s%d %% de gains)" % [Mutators.names(defs_b, ctx.mutators), "+" if pct >= 0 else "", pct]
	var mt := UiKit.label(mtxt, 13, UiKit.GOLD if not ctx.mutators.is_empty() else UiKit.DIM)
	mt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mt.custom_minimum_size = Vector2(290, 0)
	mt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mrow.add_child(mt)

	# fiche d'équipage
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(350, 0)
	card.add_theme_stylebox_override("panel", UiKit.box(Color(0, 0, 0, 0.45), UiKit.LINE, 1, 16.0, 12.0))
	cols.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 5)
	card.add_child(cv)
	cv.add_child(UiKit.label("ÉQUIPAGE", 13, UiKit.DIM))
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	cv.add_child(top)
	var ins := UiKit.InsigniaIcon.new()
	ins.setup(prof.equipped_item("insignia").get("shape", []), 58.0)
	top.add_child(ins)
	var nv := VBoxContainer.new()
	nv.add_theme_constant_override("separation", 0)
	nv.add_child(UiKit.label(prof.grade_name().to_upper(), 22, UiKit.MAIN))
	nv.add_child(UiKit.label("%s crédits d'appui" % UiKit.thousands(prof.credits), 15, UiKit.GOLD))
	top.add_child(nv)
	var gp: Vector2i = prof.grade_progress()
	var xb := UiKit.XpBar.new()
	if gp.y > 0:
		xb.setup(318.0, float(gp.x) / float(gp.y), float(gp.x) / float(gp.y), "%s XP" % UiKit.thousands(prof.xp), "grade suivant : %s" % UiKit.thousands(prof.xp - gp.x + gp.y))
	else:
		xb.setup(318.0, 1.0, 1.0, "%s XP" % UiKit.thousands(prof.xp), "grade maximal")
	cv.add_child(xb)
	cv.add_child(UiKit.row("Médailles", "%d / %d" % [prof.medal_count(), prof.defs.medal_list.size()], UiKit.DIM, UiKit.MAIN, 14))
	cv.add_child(UiKit.row("Améliorations", "%d / %d niveaux" % [prof.total_levels(), prof.defs.total_upgrade_levels()], UiKit.DIM, UiKit.MAIN, 14))
	cv.add_child(UiKit.row("Missions jouées", "%d  (%d gagnées)" % [int(prof.stats["missions"]), int(prof.stats["wins"])], UiKit.DIM, UiKit.MAIN, 14))
	cv.add_child(UiKit.row("Étoiles de campagne", "%d / %d" % [prof.sector_stars(), defs_b.stars_available], UiKit.DIM, UiKit.GOLD, 14))
	var nxt_b: Dictionary = Campaign.next_locked(defs_b, prof)
	if not nxt_b.is_empty():
		var miss_b: int = Campaign.stars_missing(defs_b, prof, str(nxt_b["id"]))
		var nl := UiKit.label("Prochain secteur : %s, encore %d étoile%s." % [str(nxt_b["name"]), miss_b, "s" if miss_b > 1 else ""], 13, UiKit.DIM)
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.custom_minimum_size = Vector2(318, 0)
		cv.add_child(nl)
	cv.add_child(UiKit.hline())
	if bmode == "daily":
		var dd := str(game.session.get("date", ""))
		var td: Dictionary = prof.daily_today(dd)
		cv.add_child(UiKit.row("Meilleur du jour", UiKit.thousands(int(td.get("best", 0))) if int(td.get("best", 0)) > 0 else "—", UiKit.DIM, UiKit.MAIN, 14))
		cv.add_child(UiKit.row("Série de jours", str(prof.daily_streak(dd)), UiKit.DIM, UiKit.GOLD, 14))
	elif bmode == "endless":
		var er: Dictionary = prof.endless_record(str(m.get("id", "")))
		if int(er["plays"]) > 0:
			cv.add_child(UiKit.row("Record de vagues", str(int(er["best_waves"])), UiKit.DIM, UiKit.GOLD, 14))
			cv.add_child(UiKit.row("Meilleur score", UiKit.thousands(int(er["best_score"])), UiKit.DIM, UiKit.MAIN, 14))
		else:
			cv.add_child(UiKit.label("Première Nuit blanche sur ce secteur.", 14, UiKit.DIM))
	elif int(rec["plays"]) > 0:
		var rt: int = int(rec["best_rating"])
		cv.add_child(UiKit.row("Meilleur score", UiKit.thousands(int(rec["best_score"])), UiKit.DIM, UiKit.MAIN, 14))
		cv.add_child(UiKit.row("Meilleure note", str(prof.RATINGS[rt]) if rt >= 0 else "—", UiKit.DIM, UiKit.rating_color(str(prof.RATINGS[rt]) if rt >= 0 else "—"), 14))
	else:
		cv.add_child(UiKit.label("Première sortie sur ce secteur.", 14, UiKit.DIM))
	var afford := 0
	for it in prof.defs.up_items:
		if prof.can_buy(str(it["id"]))["ok"]:
			afford += 1
	if afford > 0:
		cv.add_child(UiKit.label("%d amélioration%s à votre portée à l'atelier." % [afford, "s" if afford > 1 else ""], 14, UiKit.GOLD))

	v.add_child(UiKit.hline())
	var k1 := UiKit.label("Souris / ZQSD : orienter    Clic gauche : tirer    1 2 3 : armes    4 5 6 7 : appuis    Molette : zoom    Espace : polarité    C : couleurs", 13, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	var k2 := UiKit.label("R : recentrer    M : carte    N : son    V : voix radio    H : aide    Échap : pause    U : mutateurs    J : modes de jeu", 13, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	v.add_child(k1)
	v.add_child(k2)
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	v.add_child(bar)
	var shop := UiKit.button("Atelier   (A)", Callable(self, "open_hangar").bind("briefing"), 180.0)
	bar.add_child(shop)
	var camp := UiKit.button("Campagne   (K)", Callable(self, "open_campaign").bind("briefing"), 200.0)
	bar.add_child(camp)
	var modes_b := UiKit.button("Modes   (J)", Callable(self, "open_modes").bind("briefing"), 160.0)
	bar.add_child(modes_b)
	var go_txt := "Lancer la mission   (Entrée)"
	if bmode == "daily":
		go_txt = "Lancer le défi   (Entrée)"
	elif bmode == "endless":
		go_txt = "Lancer la Nuit blanche   (Entrée)"
	var go := UiKit.button(go_txt, Callable(game, "start_mission"), 340.0)
	bar.add_child(go)
	go.grab_focus()
	_fit_panel(v.get_parent())


## Le briefing est le panneau le plus haut : selon la longueur du texte du secteur (cinq lignes à La Défense), il dépasse la
## fenêtre de 720 px de quelques pixels et ses boutons sont coupés. Une fois la mise en page faite, on le réduit juste assez.
func _fit_panel(pc: Control) -> void:
	await game.get_tree().process_frame
	await game.get_tree().process_frame
	if not is_instance_valid(pc) or not pc.is_inside_tree():
		return
	var vp_h: float = root.get_viewport_rect().size.y
	var k := minf(1.0, (vp_h - 4.0) / maxf(pc.size.y, 1.0))
	if k < 0.999:
		# Le CenterContainer ne place jamais le haut d'un panneau trop grand au-dessus de 0 : on réduit autour du milieu du bord
		# supérieur, puis on centre à la main le panneau réduit.
		pc.pivot_offset = Vector2(pc.size.x * 0.5, 0.0)
		pc.scale = Vector2(k, k)
		pc.position.y = (vp_h - k * pc.size.y) * 0.5


## Règles du défi du jour ou de la Nuit blanche, en quelques lignes pour le briefing.
func _mode_rule(bmode: String) -> Array:
	var defs = ctx.profile.defs
	var prof = ctx.profile
	if bmode == "daily":
		var cfg: Dictionary = defs.mode_cfg("daily")
		var fs: Dictionary = cfg.get("first", {})
		var dd := str(game.session.get("date", ""))
		var td: Dictionary = prof.daily_today(dd)
		var l2 := "Prime du premier défi réussi : +%d XP, +%d crédits, puis une série de jours." % [int(fs.get("xp", 0)), int(fs.get("credits", 0))]
		if bool(td.get("won", false)):
			l2 = "Prime du jour déjà encaissée : ce nouvel essai ne vise que le classement."
		return ["Même scénario pour tous les joueurs, à chaque essai de la journée.", l2]
	var er: Dictionary = prof.endless_record(str(ctx.mission.get("id", "")))
	var l1 := "Les vagues se succèdent sans fin, de plus en plus fortes. Échap puis Entrée : fin de la patrouille, points conservés."
	var l2b := "Premier passage : pas encore de record." if int(er["plays"]) == 0 else \
			"Record du secteur : %d vagues, %s points." % [int(er["best_waves"]), UiKit.thousands(int(er["best_score"]))]
	return [l1, l2b]


# ---------------------------------------------------------------- mutateurs et modes de jeu

func open_mutators() -> void:
	if game.state != "briefing":
		return
	var v := _frame(1000.0, 0.80)
	mode = "mutators"
	_mutators = MutatorsView.new()
	_mutators.setup(self, ctx)
	_mutators.build(v)


func close_mutators() -> void:
	_mutators = null
	show_briefing()


func open_modes(from: String) -> void:
	_modes_back = from
	var v := _frame(1180.0, 0.80)
	mode = "modes"
	_modes = ModesView.new()
	_modes.setup(self, ctx)
	_modes.build(v, from)


func close_modes() -> void:
	_modes = null
	match _modes_back:
		"debrief":
			show_debrief(_last_res)
		"campaign":
			open_campaign(_camp_back)
		_:
			show_briefing()


# ---------------------------------------------------------------- atelier

func open_hangar(from: String, first_tab: int = 0) -> void:
	_back = from
	var v := _frame(1140.0, 0.78)
	mode = "hangar"
	_hangar = Hangar.new()
	_hangar.setup(self, ctx)
	_hangar.build(v, first_tab)


func close_hangar() -> void:
	var dirty: bool = _hangar != null and _hangar.dirty_world
	_hangar = null
	if _back == "debrief":
		show_debrief(_last_res)
	elif dirty:
		game.reload_for_loadout()        # le monde est reconstruit avec les nouvelles armes et réglages
	else:
		show_briefing()


# ---------------------------------------------------------------- difficulté et carte de campagne

## Difficulté voisine (±1) pour le briefing, sans régénérer la ville.
func _step_difficulty(d: int) -> void:
	if ctx.mode == "daily":
		return
	var defs = ctx.profile.defs
	var cur: int = defs.level_index(str(ctx.difficulty().get("id", defs.default_level)))
	var i: int = clampi(cur + d, 0, defs.levels.size() - 1)
	if i != cur:
		game.set_difficulty(str(defs.levels[i]["id"]))


func _pick_difficulty(id: String) -> void:
	if ctx.mode == "daily":
		return
	if id != str(ctx.difficulty().get("id", "")):
		game.set_difficulty(id)
	else:
		show_briefing()               # un bouton à bascule se décoche tout seul : on reconstruit pour le remettre


func open_campaign(from: String) -> void:
	_camp_back = from
	var v := _frame(1230.0, 0.80)
	mode = "campaign"
	_campaign = CampaignView.new()
	_campaign.setup(self, ctx)
	_campaign.build(v, from)


## Retour de la carte. `level_id` : difficulté choisie sur la carte pour le secteur déjà chargé (changée sans régénérer la ville).
func close_campaign(level_id: String = "") -> void:
	_campaign = null
	if _camp_back == "debrief":
		show_debrief(_last_res)
	elif level_id != "" and level_id != str(ctx.difficulty().get("id", "")):
		game.set_difficulty(level_id)         # remontre le briefing
	else:
		show_briefing()
