extends RefCounted
## Échanges radio : station directrice (Lutèce), radio de l'avion (Nocturne 2-1) et Tireur.
##
## Les répliques viennent de data/radio_script.json ; les voix de la banque audio/radio/voices.wav (générée par
## tools/audio/make_voices.py). Une réplique = quelques phrases courtes mises bout à bout (nombre, direction, distance
## prononcés par des phrases enregistrées à part), encadrées de clics d'émission / réception, avec un fond de
## radio propre à chaque canal. Le journal radio du HUD affiche chaque réplique au moment où elle est dite.
##
## La file d'attente gère les priorités : une alerte grave interrompt la suite d'un échange anodin, les messages
## trop vieux sont abandonnés (ce qui n'est plus d'actualité n'est pas dit). La cadence est celle du temps réel :
## la durée d'une réplique est celle du son, jamais celle de la simulation.
##
## Sans banque de voix (fichiers absents) ou sans carte son, le déroulement est le même, simplement muet et
## cadencé sur la longueur du texte : le journal radio reste cohérent.

class Exchange:
	extends RefCounted
	var event := ""
	var prio := 0
	var lines: Array = []        # [{who, label, text, kind, pcm: PackedByteArray, dur: float, has_audio: bool}]
	var t_enq := 0.0
	var wait := 20.0
	var idx := 0
	var truncated := false

enum S { IDLE, LINE, GAP }

const RATE := 8000
const PTT_LEAD_S := 0.02
const PTT_TAIL_S := 0.04
const BED_DB := -14.0

var ctx
var plan: Dictionary = {}           # contenu de data/radio_script.json
var ready_to_talk := false          # script chargé
var has_voices := false             # banque de voix chargée

var _speakers: Dictionary = {}
var _slots: Dictionary = {}
var _events: Dictionary = {}
var _clips: Dictionary = {}
var _bank := PackedByteArray()
var _ptt: Dictionary = {}           # "ptt_base_on" -> PackedByteArray
var _beds: Dictionary = {}          # "base" -> AudioStreamWAV
var _gap_s := 0.13
var _reply_gap := Vector2(0.3, 0.55)

var _voice: AudioStreamPlayer
var _bed: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()
var _queue: Array = []
var _cur: Exchange = null
var _state := S.IDLE
var _clock := 0.0
var _line_t := 0.0
var _line_dur := 0.0
var _line_audio := false
var _gap_t := 0.0
var _paused := false
var _last_said: Dictionary = {}
var _last_variant: Dictionary = {}
var _n_started := 0                 # nombre de répliques démarrées (contrôles)
var trace := false                  # --audio-log : journal horodaté sur la sortie standard


func setup(p_ctx, host: Node, sfx: Dictionary) -> void:
	ctx = p_ctx
	_rng.randomize()
	plan = _read_json("res://data/radio_script.json")
	if plan.is_empty():
		push_warning("Radio : data/radio_script.json introuvable, messages écrits seulement.")
	else:
		_speakers = plan.get("speakers", {})
		_slots = plan.get("slots", {})
		_events = plan.get("events", {})
		_gap_s = float(plan.get("gap_s", 0.13))
		var rg: Array = plan.get("reply_gap_s", [0.3, 0.55])
		_reply_gap = Vector2(float(rg[0]), float(rg[1]))
		ready_to_talk = true
	_load_bank()
	for who in _speakers:
		for k in ["on", "off"]:
			var name := "ptt_%s_%s" % [who, k]
			if sfx.has(name):
				_ptt[name] = (sfx[name] as AudioStreamWAV).data
		if sfx.has("static_" + who):
			_beds[who] = sfx["static_" + who]
	_voice = AudioStreamPlayer.new()
	_voice.bus = "Radio"
	_voice.name = "RadioVoix"
	host.add_child(_voice)
	_bed = AudioStreamPlayer.new()
	_bed.bus = "Radio"
	_bed.volume_db = BED_DB
	_bed.name = "RadioFond"
	host.add_child(_bed)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


func _load_bank() -> void:
	var meta := _read_json("res://audio/radio/voices.json")
	if meta.is_empty() or not FileAccess.file_exists("res://audio/radio/voices.wav"):
		return
	var w: AudioStreamWAV = AudioStreamWAV.load_from_file("res://audio/radio/voices.wav")
	if w == null or w.format != AudioStreamWAV.FORMAT_16_BITS or w.stereo:
		push_warning("Radio : banque de voix illisible (attendu : WAV mono 16 bits).")
		return
	_bank = w.data
	_clips = meta.get("clips", {})
	has_voices = not _clips.is_empty() and _bank.size() > 0


# ---------------------------------------------------------------- demandes

## Demande un échange radio. event : clé de « events » ; params : dir (0..7, 0 = nord, sens horaire), dist (m),
## n (effectif), civ (civils). fallback / kind : message écrit utilisé si le script ne connaît pas l'événement.
func say(event: String, params: Dictionary, fallback: String, kind: String) -> void:
	if not ready_to_talk or not _events.has(event):
		if fallback != "":
			ctx.radio(fallback, kind)
		return
	var ev: Dictionary = _events[event]
	var cd := float(ev.get("cooldown_s", 0.0))
	if cd > 0.0 and _last_said.has(event) and _clock - float(_last_said[event]) < cd:
		return
	_last_said[event] = _clock
	var variants: Array = ev["variants"]
	var vi := _rng.randi_range(0, variants.size() - 1)
	if variants.size() > 1 and vi == int(_last_variant.get(event, -1)):
		vi = (vi + 1 + _rng.randi_range(0, variants.size() - 2)) % variants.size()
	_last_variant[event] = vi
	if trace:
		print("[radio] %7.2f s  demande « %s » %s (file : %d)" % [_clock, event, str(params), _queue.size()])
	var ex := Exchange.new()
	ex.event = event
	ex.prio = int(ev.get("priority", 3))
	ex.wait = float(ev.get("wait_s", 20.0))
	ex.t_enq = _clock
	for line in variants[vi]:
		ex.lines.append(_build_line(line, params, ev))
	_enqueue(ex)


func _enqueue(ex: Exchange) -> void:
	var same: Array = _queue.filter(func(e): return e.event == ex.event)
	if same.size() >= 2:
		_queue.erase(same[0])
	_queue.append(ex)
	if _queue.size() > 6:
		var worst: Exchange = _queue[0]
		for e in _queue:
			if e.prio < worst.prio:
				worst = e
		_queue.erase(worst)
	# une alerte nettement plus grave coupe la suite de l'échange en cours (après la réplique en cours)
	if _cur != null and ex.prio >= _cur.prio + 3:
		_cur.truncated = true


# ---------------------------------------------------------------- construction des répliques

func _build_line(line: Dictionary, params: Dictionary, ev: Dictionary) -> Dictionary:
	var who: String = line["who"]
	var spk: Dictionary = _speakers.get(who, {})
	var shown: Array = []
	var pcm := PackedByteArray()
	var any_audio := false
	var on: PackedByteArray = _ptt.get("ptt_%s_on" % who, PackedByteArray())
	var off: PackedByteArray = _ptt.get("ptt_%s_off" % who, PackedByteArray())
	if has_voices:
		pcm.append_array(on)
		pcm.append_array(_silence(PTT_LEAD_S))
	var first := true
	for a in line["say"]:
		var r := _atom(who, str(a), params)
		if r[0] == "":
			continue
		shown.append(r[1])
		if has_voices and _clips.has(r[0]):
			if not first:
				pcm.append_array(_silence(_gap_s))
			var c: Array = _clips[r[0]]
			var s := int(c[0]) * 2
			pcm.append_array(_bank.slice(s, s + int(c[1]) * 2))
			any_audio = true
			first = false
	if any_audio:
		pcm.append_array(_silence(PTT_TAIL_S))
		pcm.append_array(off)
	var text := _join(shown)
	var kind: String = str(spk.get("kind", "info"))
	if who == "base":
		if bool(ev.get("alert", false)):
			kind = "alert"
		elif bool(ev.get("good", false)):
			kind = "good"
	var dur := float(pcm.size()) / 2.0 / float(RATE) if any_audio else 0.9 + 0.055 * float(text.length())
	return {"who": who, "label": str(spk.get("label", who)), "text": text, "kind": kind,
			"pcm": pcm if any_audio else PackedByteArray(), "dur": dur, "has_audio": any_audio}


## Un atome du script -> [clé dans la banque, texte affiché]. Clé vide si la valeur du slot manque.
func _atom(who: String, a: String, params: Dictionary) -> Array:
	if a.begins_with("{") and a.ends_with("}"):
		var name := a.substr(1, a.length() - 2)
		var sl: Dictionary = _slots.get(name, {})
		if sl.is_empty() or not params.has(name):
			return ["", ""]
		var val := 0
		var txt := ""
		if sl.has("values"):
			var vals: Array = sl["values"]
			val = clampi(int(params[name]), 0, vals.size() - 1)
			txt = str(sl["text"]).replace("{v}", str(vals[val]))
		else:
			var r: Array = sl["range"]
			var st := maxi(int(r[2]), 1)
			val = clampi(int(round(float(params[name]) / float(st))) * st, int(r[0]), int(r[1]))
			if val == 1 and sl.has("one"):
				txt = str(sl["one"]["text"])
			else:
				txt = str(sl["text"]).replace("{v}", str(val))
		return ["%s|{%s}=%d" % [who, name, val], txt]
	var parts := a.split("|")
	return ["%s|%s" % [who, parts[0]], parts[1] if parts.size() > 1 else parts[0]]


static func _join(parts: Array) -> String:
	var s := ""
	for i in parts.size():
		var p: String = parts[i]
		if i > 0:
			var last := s.substr(s.length() - 1)
			if ".!?".contains(last):
				s += " "
				p = p.substr(0, 1).to_upper() + p.substr(1)      # nouvelle phrase : majuscule
			else:
				s += " " if ",;:".contains(last) else ", "
		s += p
	if s.length() > 0 and not ".!?".contains(s.substr(s.length() - 1)):
		s += "."
	return s


static func _silence(sec: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(int(sec * float(RATE)) * 2)
	return b


# ---------------------------------------------------------------- déroulement

func update(delta: float) -> void:
	if _paused:
		return
	_clock += delta
	match _state:
		S.IDLE:
			_gap_t -= delta
			if _gap_t <= 0.0:
				_pop_next()
		S.LINE:
			_line_t += delta
			var over := _line_t >= _line_dur + 0.25
			if _line_audio:
				over = (_line_t > 0.15 and not _voice.playing) or _line_t >= _line_dur + 1.5
			if over:
				_finish_line()
		S.GAP:
			_gap_t -= delta
			if _gap_t <= 0.0:
				_start_line()


func _pop_next() -> void:
	_queue = _queue.filter(func(e): return _clock - e.t_enq <= e.wait)
	if _queue.is_empty():
		return
	var best: Exchange = _queue[0]
	for e in _queue:
		if e.prio > best.prio:
			best = e
	_queue.erase(best)
	_cur = best
	_cur.idx = 0
	_start_line()


func _start_line() -> void:
	var ln: Dictionary = _cur.lines[_cur.idx]
	_state = S.LINE
	_line_t = 0.0
	_line_dur = float(ln["dur"])
	_line_audio = bool(ln["has_audio"])
	_n_started += 1
	ctx.radio("%s : %s" % [ln["label"], ln["text"]], str(ln["kind"]))
	if trace:
		print("[radio] %7.2f s  %s : %s  (%.1f s%s)" % [_clock, ln["label"], ln["text"], _line_dur, "" if _line_audio else ", muet"])
	if _line_audio:
		var w := AudioStreamWAV.new()
		w.format = AudioStreamWAV.FORMAT_16_BITS
		w.mix_rate = RATE
		w.stereo = false
		w.data = ln["pcm"]
		_voice.stream = w
		_voice.play()
		var bed: AudioStreamWAV = _beds.get(ln["who"])
		if bed != null:
			_bed.stream = bed
			_bed.play(_rng.randf() * maxf(bed.get_length() - 0.5, 0.1))


func _finish_line() -> void:
	_bed.stop()
	_voice.stop()
	_cur.idx += 1
	if _cur.idx >= _cur.lines.size() or _cur.truncated:
		_cur = null
		_state = S.IDLE
		_gap_t = 0.9
	else:
		_state = S.GAP
		_gap_t = _rng.randf_range(_reply_gap.x, _reply_gap.y)


# ---------------------------------------------------------------- état

func set_paused(p: bool) -> void:
	_paused = p
	_voice.stream_paused = p
	_bed.stream_paused = p


func is_speaking() -> bool:
	return _state == S.LINE and _line_audio


func is_busy() -> bool:
	return _state != S.IDLE or not _queue.is_empty()


func lines_started() -> int:
	return _n_started
