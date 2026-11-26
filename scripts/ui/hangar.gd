extends RefCounted
## Atelier de l'équipage : améliorations des armes, capteurs, équipage, médailles et personnalisation.
## Écran de contrôles Godot construit par Screens ; les achats passent par le profil (ctx.profile).

const UiKit := preload("res://scripts/ui/ui_kit.gd")

const TAB_NAMES := ["25 MM", "40 MM", "105 MM", "CAPTEURS", "ÉQUIPAGE", "APPUIS", "MÉDAILLES", "PERSONNALISER"]
const TAB_CATS := ["weapon_0", "weapon_1", "weapon_2", "sensor", "crew", "support"]

var scr                                     # Screens
var ctx
var tab := 0
var dirty_world := false                    # améliorations achetées : le monde doit être reconstruit au retour
var _head: VBoxContainer
var _body: VBoxContainer
var _tab_buttons: Array = []
var _scroll_pos := 0


func setup(p_scr, p_ctx) -> void:
	scr = p_scr
	ctx = p_ctx


func build(v: VBoxContainer, first_tab: int = 0) -> void:
	tab = clampi(first_tab, 0, TAB_NAMES.size() - 1)
	v.add_child(UiKit.label("ATELIER DE L'ÉQUIPAGE", 30, UiKit.MAIN, HORIZONTAL_ALIGNMENT_CENTER))
	_head = VBoxContainer.new()
	v.add_child(_head)
	v.add_child(UiKit.hline())
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	v.add_child(tabs)
	_tab_buttons.clear()
	for i in TAB_NAMES.size():
		var b := Button.new()
		b.text = TAB_NAMES[i]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(104, 32)
		b.add_theme_font_size_override("font_size", 15)
		b.pressed.connect(show_tab.bind(i))
		tabs.add_child(b)
		_tab_buttons.append(b)
	_body = VBoxContainer.new()
	_body.custom_minimum_size = Vector2(0, 392)
	v.add_child(_body)
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 16)
	v.add_child(bar)
	var hint := UiKit.label("←  →  pour changer de rubrique", 12, UiKit.DIM)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(hint)
	var back := UiKit.button("Retour   (Échap)", Callable(scr, "close_hangar"), 220.0)
	bar.add_child(back)
	show_tab(tab)


func show_tab(i: int) -> void:
	tab = clampi(i, 0, TAB_NAMES.size() - 1)
	for k in _tab_buttons.size():
		_tab_buttons[k].set_pressed_no_signal(k == tab)
	_refresh()


func handle_key(ev: InputEventKey) -> bool:
	match ev.keycode:
		KEY_LEFT:
			show_tab(maxi(tab - 1, 0))
			return true
		KEY_RIGHT:
			show_tab(mini(tab + 1, TAB_NAMES.size() - 1))
			return true
	return false


func _clear(n: Node) -> void:
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()


## Reconstruit l'en-tête (grade, crédits) et la rubrique courante.
func _refresh() -> void:
	var prof = ctx.profile
	_clear(_head)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	_head.add_child(h)
	var ins = prof.equipped_item("insignia")
	var ic := UiKit.InsigniaIcon.new()
	ic.setup(ins.get("shape", []), 40.0)
	h.add_child(ic)
	var gv := VBoxContainer.new()
	gv.add_theme_constant_override("separation", 0)
	gv.add_child(UiKit.label(prof.grade_name().to_upper(), 20, UiKit.MAIN))
	var gp: Vector2i = prof.grade_progress()
	gv.add_child(UiKit.label("XP %s / %s" % [UiKit.thousands(gp.x), UiKit.thousands(gp.y)] if gp.y > 0 else "Grade maximal", 13, UiKit.DIM))
	h.add_child(gv)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sp)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 0)
	cv.add_child(UiKit.label("%s  CRÉDITS D'APPUI" % UiKit.thousands(prof.credits), 22, UiKit.GOLD, HORIZONTAL_ALIGNMENT_RIGHT))
	cv.add_child(UiKit.label("%d / %d médailles   ·   %d / %d niveaux d'amélioration" % [prof.medal_count(), prof.defs.medal_list.size(), prof.total_levels(), prof.defs.total_upgrade_levels()], 13, UiKit.DIM, HORIZONTAL_ALIGNMENT_RIGHT))
	h.add_child(cv)
	_clear(_body)
	if tab < TAB_CATS.size():
		_body.add_child(_upgrades_page(TAB_CATS[tab]))
	elif tab == TAB_CATS.size():
		_body.add_child(_medals_page())
	else:
		_body.add_child(_cosmetics_page())


# ---------------------------------------------------------------- améliorations

func _upgrades_page(cat: String) -> Control:
	var prof = ctx.profile
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 392)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	sc.add_child(col)
	for it in prof.defs.upgrades_in(cat):
		col.add_child(_upgrade_row(it))
	return sc


func _upgrade_row(it: Dictionary) -> Control:
	var prof = ctx.profile
	var id := str(it["id"])
	var lv: int = prof.level(id)
	var mx: int = prof.max_level(id)
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UiKit.box(Color(0, 0, 0, 0.45), UiKit.LINE, 1, 12.0, 6.0))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	pc.add_child(h)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 0)
	h.add_child(info)
	info.add_child(UiKit.label(str(it["name"]), 17, UiKit.MAIN))
	var tx := UiKit.label(str(it["text"]), 12, UiKit.DIM)
	tx.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(tx)
	if lv > 0:
		info.add_child(UiKit.label("Actuel : " + str(it["levels"][lv - 1]["desc"]), 13, UiKit.GOOD))
	var nl: Dictionary = prof.next_level(id)
	if not nl.is_empty():
		info.add_child(UiKit.label("Prochain : " + str(nl["desc"]), 13, UiKit.GOLD))
	var pips := UiKit.Pips.new()
	pips.setup(lv, mx)
	pips.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(pips)
	var bv := VBoxContainer.new()
	bv.add_theme_constant_override("separation", 0)
	bv.custom_minimum_size = Vector2(210, 0)
	bv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(bv)
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(210, 34)
	btn.add_theme_font_size_override("font_size", 15)
	if nl.is_empty():
		btn.text = "NIVEAU MAXIMAL"
		btn.disabled = true
	else:
		btn.text = "Acheter · %s CA" % UiKit.thousands(int(nl["cost"]))
		var chk: Dictionary = prof.can_buy(id)
		btn.disabled = not chk["ok"]
		btn.pressed.connect(_buy.bind(id))
		if not chk["ok"]:
			var why := UiKit.label(str(chk["why"]), 11, UiKit.WARN, HORIZONTAL_ALIGNMENT_CENTER)
			bv.add_child(btn)
			bv.add_child(why)
			return pc
	bv.add_child(btn)
	return pc


func _buy(id: String) -> void:
	var prof = ctx.profile
	if prof.buy(id):
		dirty_world = true
		var meds: Array = prof.check_medals()
		prof.save()
		for m in meds:
			scr.toast("Médaille obtenue : %s" % str(prof.defs.medal_by_id[str(m[0])]["name"]))
		_refresh()


# ---------------------------------------------------------------- médailles

func _medals_page() -> Control:
	var prof = ctx.profile
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 392)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var g := GridContainer.new()
	g.columns = 3
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_theme_constant_override("h_separation", 8)
	g.add_theme_constant_override("v_separation", 6)
	sc.add_child(g)
	# obtenues d'abord, puis par palier
	var order := {"gold": 0, "silver": 1, "bronze": 2}
	var list: Array = prof.defs.medal_list.duplicate()
	list.sort_custom(func(a, b):
		var ga: int = 0 if prof.has_medal(str(a["id"])) else 1
		var gb: int = 0 if prof.has_medal(str(b["id"])) else 1
		if ga != gb:
			return ga < gb
		return int(order.get(str(a["tier"]), 3)) < int(order.get(str(b["tier"]), 3)))
	for m in list:
		var got: bool = prof.has_medal(str(m["id"]))
		var pc := PanelContainer.new()
		pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pc.add_theme_stylebox_override("panel", UiKit.box(Color(0, 0, 0, 0.4 if got else 0.2), UiKit.tier_color(str(m["tier"])) if got else UiKit.LINE, 1, 8.0, 5.0))
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		pc.add_child(h)
		var ic := UiKit.MedalIcon.new()
		ic.setup(str(m["tier"]), got, 36.0)
		h.add_child(ic)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 0)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(v)
		v.add_child(UiKit.label(str(m["name"]), 14, UiKit.MAIN if got else UiKit.DIM))
		var t := UiKit.label(str(m["text"]), 11, UiKit.DIM)
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		t.custom_minimum_size = Vector2(230, 0)
		v.add_child(t)
		g.add_child(pc)
	return sc


# ---------------------------------------------------------------- personnalisation

func _cosmetics_page() -> Control:
	var prof = ctx.profile
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 392)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)
	sc.add_child(col)
	for sl in prof.defs.slots:
		var sid := str(sl["id"])
		col.add_child(UiKit.label(str(sl["name"]), 14, UiKit.DIM))
		var fl := HFlowContainer.new()
		fl.add_theme_constant_override("h_separation", 8)
		fl.add_theme_constant_override("v_separation", 8)
		col.add_child(fl)
		for c in prof.defs.cos_items[sid]:
			fl.add_child(_cosmetic_tile(c))
		col.add_child(UiKit.spacer(6))
	return sc


func _cosmetic_tile(c: Dictionary) -> Control:
	var prof = ctx.profile
	var id := str(c["id"])
	var sid := str(c["slot"])
	var open: bool = prof.is_unlocked(id)
	var on: bool = str(prof.equipped.get(sid, "")) == id
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(150, 0)
	pc.add_theme_stylebox_override("panel", UiKit.box(Color(0, 0, 0, 0.45), UiKit.GOLD if on else UiKit.LINE, 2 if on else 1, 8.0, 6.0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	pc.add_child(v)
	var ink := UiKit.MAIN if open else Color(0.93, 0.98, 1.0, 0.3)
	var prev: Control
	match sid:
		"insignia":
			var ic := UiKit.InsigniaIcon.new()
			ic.setup(c["shape"], 52.0, ink)
			prev = ic
		"filter":
			prev = _filter_swatch(c, open)
		"reticle":
			var rp := UiKit.ReticlePreview.new()
			rp.setup(c, ink)
			prev = rp
		_:
			var vp := UiKit.VoicePreview.new()
			vp.setup(c, ink)
			prev = vp
	prev.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(prev)
	v.add_child(UiKit.label(str(c["name"]), 13, UiKit.MAIN if open else UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER))
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 28)
	b.add_theme_font_size_override("font_size", 13)
	if on:
		b.text = "ÉQUIPÉ"
		b.disabled = true
	elif open:
		b.text = "Équiper"
		b.pressed.connect(_equip.bind(sid, id))
	elif c["unlock"].has("cost"):
		var chk: Dictionary = prof.can_buy_cosmetic(id)
		b.text = "Acheter · %d CA" % int(c["unlock"]["cost"])
		b.disabled = not chk["ok"]
		b.pressed.connect(_buy_cosmetic.bind(id))
		if not chk["ok"]:
			b.tooltip_text = str(chk["why"])
	else:
		b.text = "Verrouillé"
		b.disabled = true
	v.add_child(b)
	if not open:
		var why := UiKit.label(prof.unlock_text(id), 10, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER)
		why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		why.custom_minimum_size = Vector2(130, 0)
		v.add_child(why)
	return pc


func _filter_swatch(c: Dictionary, open: bool) -> Control:
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 3)
	h.custom_minimum_size = Vector2(0, 52)
	var a: float = 1.0 if open else 0.35
	for key in ["tint", "zombie", "civil"]:
		var t: Array = c[key]
		var r := ColorRect.new()
		r.color = Color(float(t[0]), float(t[1]), float(t[2]), a)
		r.custom_minimum_size = Vector2(34 if key == "tint" else 14, 40)
		r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(r)
	return h


func _equip(slot: String, id: String) -> void:
	if ctx.profile.equip(slot, id):
		ctx.profile.save()
		scr.apply_cosmetics()
		_refresh()


func _buy_cosmetic(id: String) -> void:
	var prof = ctx.profile
	if prof.buy_cosmetic(id):
		prof.equip(str(prof.defs.cos_by_id[id]["slot"]), id)
		var meds: Array = prof.check_medals()
		prof.save()
		for m in meds:
			scr.toast("Médaille obtenue : %s" % str(prof.defs.medal_by_id[str(m[0])]["name"]))
		scr.apply_cosmetics()
		_refresh()
