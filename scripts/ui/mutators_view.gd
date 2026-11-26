extends RefCounted
## Écran des mutateurs : des règles en plus, choisies avant le départ (data/mutators.json). Chacune change les gains d'XP et de
## crédits ; les bonus se multiplient. Écran de contrôles construit par Screens (même schéma que l'atelier). Les bascules passent
## par Game.toggle_mutator, qui refait la mission sans régénérer la ville. En défi du jour la liste est imposée (lecture seule).

const UiKit := preload("res://scripts/ui/ui_kit.gd")
const Mutators := preload("res://scripts/meta/mutators.gd")

var scr                                     # Screens
var ctx
var locked := false
var _buttons: Dictionary = {}               # identifiant -> bouton à bascule
var _sum: Label
var _names: Label


func setup(p_scr, p_ctx) -> void:
	scr = p_scr
	ctx = p_ctx


func build(v: VBoxContainer) -> void:
	var defs = ctx.profile.defs
	locked = ctx.mode == "daily"
	v.add_child(UiKit.label("MUTATEURS", 30, UiKit.MAIN, HORIZONTAL_ALIGNMENT_CENTER))
	var what := "Le défi du jour impose ses mutateurs." if locked else \
			"Des règles en plus pour une nuit plus dure : au plus %d à la fois, et les gains d'XP et de crédits suivent." % defs.max_mutators
	v.add_child(UiKit.label(what, 14, UiKit.DIM, HORIZONTAL_ALIGNMENT_CENTER))
	v.add_child(UiKit.hline())
	var i := 0
	for m in defs.mutators:
		i += 1
		var id := str(m["id"])
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 16)
		v.add_child(h)
		var b := Button.new()
		b.text = "%d   %s" % [i, str(m["name"])]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.disabled = locked
		b.custom_minimum_size = Vector2(250, 56)
		b.add_theme_font_size_override("font_size", 17)
		b.pressed.connect(_toggle.bind(id))
		h.add_child(b)
		_buttons[id] = b
		var tv := VBoxContainer.new()
		tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tv.add_theme_constant_override("separation", 0)
		h.add_child(tv)
		var t := UiKit.label(str(m["text"]), 14, UiKit.MAIN)
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		t.custom_minimum_size = Vector2(620, 0)
		tv.add_child(t)
		var bn := int(round(float(m.get("bonus", 0.0)) * 100.0))
		tv.add_child(UiKit.label("%s%d %% de gains" % ["+" if bn >= 0 else "", bn], 13, UiKit.GOOD if bn >= 0 else UiKit.WARN))
	v.add_child(UiKit.hline())
	_names = UiKit.label("", 15, UiKit.MAIN)
	v.add_child(_names)
	_sum = UiKit.label("", 17, UiKit.GOLD)
	v.add_child(_sum)
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(bar)
	var hint := UiKit.label("1 à %d  ·  bascule d'un mutateur" % defs.mutators.size(), 12, UiKit.DIM)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(hint)
	var back := UiKit.button("Fermer   (Échap)", Callable(scr, "close_mutators"), 220.0)
	bar.add_child(back)
	back.grab_focus()
	_sync()


func _toggle(id: String) -> void:
	if locked:
		_sync()
		return
	var was: bool = ctx.mutators.has(id)
	if not scr.game.toggle_mutator(id) and not was:
		scr.toast("Déjà %d mutateurs : retirez-en un d'abord." % ctx.profile.defs.max_mutators)
	_sync()


## Boutons, liste des mutateurs actifs et multiplicateur de gains remis d'équerre avec la partie.
func _sync() -> void:
	var defs = ctx.profile.defs
	for id in _buttons:
		(_buttons[id] as Button).set_pressed_no_signal(ctx.mutators.has(id))
	if ctx.mutators.is_empty():
		_names.text = "Aucun mutateur actif."
		_sum.text = "Gains normaux."
		return
	_names.text = "%d / %d actif%s :  %s" % [ctx.mutators.size(), defs.max_mutators, "s" if ctx.mutators.size() > 1 else "",
			Mutators.names(defs, ctx.mutators)]
	var pct := int(round((Mutators.reward_mult(defs, ctx.mutators) - 1.0) * 100.0))
	_sum.text = "Gains d'XP et de crédits :  %s%d %%" % ["+" if pct >= 0 else "", pct]


func handle_key(ev: InputEventKey) -> bool:
	var defs = ctx.profile.defs
	var n: int = ev.keycode - KEY_1
	if n < 0 or n >= defs.mutators.size():
		n = ev.keycode - KEY_KP_1
	if n >= 0 and n < defs.mutators.size():
		_toggle(str(defs.mutators[n]["id"]))
		return true
	return false
