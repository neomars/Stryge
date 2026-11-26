extends RefCounted
## Ambiance sonore, entendue DEPUIS L'AVION : tirs des trois armes, mécanique d'armement, grondement des
## turbopropulseurs, radio (via radio.gd). Ni impacts ni effondrements : à 2 000 m d'altitude on ne les entend pas.
##
## Les sons sont dans audio/sfx (voir tools/audio/make_sfx.py) ; leurs points de bouclage dans audio/sfx/sfx.json.
## Le comportement de chaque arme est décrit dans data/weapons.json (clé « sfx ») :
##   mode « burst » : rafale = départ + boucle tant que la gâchette est tenue + fin de rafale ;
##   mode « single » : un coup par tir (variantes tirées au sort) + bruits mécaniques différés (« reload »,
##   [délai_s, son, gain_dB], en temps de jeu pour rester calé sur la barre de rechargement du HUD).
## Le jeu fonctionne sans ces fichiers (silence) : rien ici ne fait échouer le démarrage.
##
## Bus : Sfx (armes), Radio (voix + fond), Ambience (moteurs) -> Master (limiteur). Quand la radio parle,
## les moteurs et les armes baissent un peu (ducking) pour garder les voix intelligibles.

const RadioComms := preload("res://scripts/core/radio.gd")

const SFX_DIR := "res://audio/sfx/"
const BUS_SFX_DB := -2.0
const BUS_AMB_DB := -17.0
const BUS_RADIO_DB := 0.0
const DUCK_SFX_DB := 2.5
const DUCK_AMB_DB := 7.0

var ctx
var radio                       # RadioComms
var sfx: Dictionary = {}        # nom -> AudioStreamWAV
var loaded := false
var muted := false
var voices_muted := false

var _host: Node
var _idx: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _bus_sfx := -1
var _bus_radio := -1
var _bus_amb := -1
var _engine: AudioStreamPlayer
var _bursts: Dictionary = {}    # index d'arme -> [lecteur boucle, lecteur fin]
var _shots: Dictionary = {}     # index d'arme -> lecteur
var _mech: Dictionary = {}      # "nom@gain" -> lecteur
var _sched: Array = []          # [[reste_s, nom, gain_dB], ...] en temps de jeu
var _burst_on := false
var _burst_idx := -1
var _last_shots := 0
var _last_fire := -9.0
var _dry_t := 0.0
var _clock := 0.0
var _duck := 0.0
var _paused := false
var _record: AudioEffectRecord = null
var _pitch_idx := -1                     # indices des effets ajoutés au bus Radio par le style de voix
var _drive_idx := -1
var _record_path := ""
var _n_shots := 0               # compteurs de contrôle
var _n_bursts := 0
var trace := false              # --audio-log : journal horodaté sur la sortie standard


func setup(p_ctx, host: Node) -> void:
	ctx = p_ctx
	_host = host
	_rng.randomize()
	_setup_buses()
	_load_sfx()
	_setup_weapons()
	_engine = _player(sfx.get("engine_loop"), "Ambience", 0.0, 1)
	if _engine != null:
		_engine.play(_rng.randf() * 6.0)
	radio = RadioComms.new()
	radio.setup(ctx, host, sfx)


# ---------------------------------------------------------------- mise en place

func _ensure_bus(bus_name: String, db: float) -> int:
	var i := AudioServer.get_bus_index(bus_name)
	if i < 0:
		AudioServer.add_bus()
		i = AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, bus_name)
		AudioServer.set_bus_send(i, "Master")
	AudioServer.set_bus_volume_db(i, db)
	return i


func _setup_buses() -> void:
	_bus_sfx = _ensure_bus("Sfx", BUS_SFX_DB)
	_bus_radio = _ensure_bus("Radio", BUS_RADIO_DB)
	_bus_amb = _ensure_bus("Ambience", BUS_AMB_DB)
	# la voix de la radio tient dans la bande téléphonique : on coupe les images de la reconversion 8 kHz -> 44,1 kHz
	if AudioServer.get_bus_effect_count(_bus_radio) == 0:
		var lpf := AudioEffectLowPassFilter.new()
		lpf.cutoff_hz = 3800.0
		lpf.db = AudioEffectFilter.FILTER_24DB
		AudioServer.add_bus_effect(_bus_radio, lpf)
	# limiteur final : évite toute saturation quand rafale, coup de 105 mm et voix se superposent
	if AudioServer.get_bus_effect_count(0) == 0:
		var lim := AudioEffectHardLimiter.new()
		lim.ceiling_db = -1.0
		lim.pre_gain_db = 0.0
		AudioServer.add_bus_effect(0, lim)


func _load_sfx() -> void:
	var f := SFX_DIR + "sfx.json"
	if not FileAccess.file_exists(f):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(f))
	if not (d is Dictionary):
		return
	_idx = d
	for name in _idx:
		var path := "%s%s.wav" % [SFX_DIR, name]
		if not FileAccess.file_exists(path):
			continue
		var w: AudioStreamWAV = AudioStreamWAV.load_from_file(path)
		if w == null:
			continue
		var info: Dictionary = _idx[name]
		if info.has("loop_end"):
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = int(info.get("loop_begin", 0))
			w.loop_end = int(info["loop_end"])
		sfx[name] = w
	loaded = not sfx.is_empty()


func _player(stream: AudioStream, bus: String, db: float, poly: int) -> AudioStreamPlayer:
	if stream == null:
		return null
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = bus
	p.volume_db = db
	p.max_polyphony = poly
	_host.add_child(p)
	return p


func _setup_weapons() -> void:
	for i in ctx.weapons.size():
		var cfg: Dictionary = ctx.weapons[i].get("sfx", {})
		var gain := float(cfg.get("gain_db", 0.0))
		match str(cfg.get("mode", "")):
			"burst":
				var a := _player(sfx.get(str(cfg.get("start", ""))), "Sfx", gain, 1)
				var b := _player(sfx.get(str(cfg.get("tail", ""))), "Sfx", gain, 2)
				if a != null:
					_bursts[i] = [a, b]
			"single":
				var rnd := AudioStreamRandomizer.new()
				rnd.random_pitch_semitones = 0.5
				rnd.random_volume_offset_db = 1.0
				var n := 0
				for k in cfg.get("samples", []):
					if sfx.has(str(k)):
						rnd.add_stream(-1, sfx[str(k)], 1.0)
						n += 1
				if n > 0:
					_shots[i] = _player(rnd, "Sfx", gain, 4)


# ---------------------------------------------------------------- appels du jeu

## Message radio (échange vocal si les voix sont disponibles, texte seul sinon).
func say(event: String, params: Dictionary, fallback: String, kind: String) -> void:
	if radio != null:
		radio.say(event, params, fallback, kind)
	elif fallback != "":
		ctx.radio(fallback, kind)


## Changement d'arme : déclic du sélecteur et ronflement du servo.
func select(_i: int) -> void:
	_mech_play("selector_%d" % _rng.randi_range(1, 3), -4.0)


## Retour sonore du désignateur laser : déclic de verrouillage, de relâchement ou d'échec (sons du sélecteur d'armes, plus discrets).
func cue(kind: String) -> void:
	match kind:
		"lock":
			_mech_play("selector_1", -5.0)
			_sched.append([0.09, "selector_2", -9.0])
		"release":
			_mech_play("selector_3", -11.0)
		"fail":
			_mech_play("selector_2", -14.0)


func update(delta: float, dt: float, state: String) -> void:
	if _paused:
		return
	_clock += delta
	_update_weapons(delta, state == "playing")
	_flush_schedule(dt)
	if radio != null:
		radio.update(delta)
	_update_duck(delta)


func _update_weapons(delta: float, playing: bool) -> void:
	var arms = ctx.arms
	var fired: int = arms.shots - _last_shots
	_last_shots = arms.shots
	var cur: int = arms.current
	var cfg: Dictionary = ctx.weapons[cur].get("sfx", {})
	var mode := str(cfg.get("mode", ""))
	if playing and fired > 0:
		_last_fire = _clock
		if mode == "single" and _shots.has(cur):
			(_shots[cur] as AudioStreamPlayer).play()
			_n_shots += 1
			if trace:
				print("[son] %7.2f s  coup %s" % [_clock, str(ctx.weapons[cur]["short"])])
			for r in cfg.get("reload", []):
				_sched.append([float(r[0]), str(r[1]), float(r[2])])
	# rafale : tant que la gâchette est tenue et que des coups partent réellement (la reconstitution des munitions
	# fait partir un coup sur deux quand le chargeur est vide : on ne coupe pas la boucle pour si peu)
	var want: bool = playing and mode == "burst" and _bursts.has(cur) and arms.trigger \
			and _clock - _last_fire < 0.30
	if want and not (_burst_on and _burst_idx == cur):
		if _burst_on:
			_burst_stop()
		_burst_start(cur)
	elif not want and _burst_on:
		_burst_stop()
	# déclic à vide : gâchette tenue sans munitions
	if playing and arms.trigger and arms.ammo[cur] < 1.0 and _clock - _last_fire > 0.30 \
			and (_bursts.has(cur) or _shots.has(cur)):
		_dry_t -= delta
		if _dry_t <= 0.0:
			_mech_play("dry_click", -6.0)
			_dry_t = 0.28 if mode == "burst" else 0.7
	else:
		_dry_t = 0.0


func _burst_start(i: int) -> void:
	var pl: Array = _bursts[i]
	if pl[1] != null:
		(pl[1] as AudioStreamPlayer).stop()
	(pl[0] as AudioStreamPlayer).play()
	_burst_on = true
	_burst_idx = i
	_n_bursts += 1
	if trace:
		print("[son] %7.2f s  rafale : début" % _clock)


func _burst_stop() -> void:
	if _burst_idx >= 0 and _bursts.has(_burst_idx):
		var pl: Array = _bursts[_burst_idx]
		(pl[0] as AudioStreamPlayer).stop()
		if pl[1] != null:
			(pl[1] as AudioStreamPlayer).play()
	_burst_on = false
	_burst_idx = -1
	if trace:
		print("[son] %7.2f s  rafale : fin" % _clock)


func _flush_schedule(dt: float) -> void:
	for i in range(_sched.size() - 1, -1, -1):
		_sched[i][0] -= dt
		if _sched[i][0] <= 0.0:
			_mech_play(str(_sched[i][1]), float(_sched[i][2]))
			_sched.remove_at(i)


func _mech_play(name: String, db: float) -> void:
	if not sfx.has(name):
		return
	if trace:
		print("[son] %7.2f s  mécanique : %s" % [_clock, name])
	var key := "%s@%.1f" % [name, db]
	var p: AudioStreamPlayer = _mech.get(key)
	if p == null:
		p = _player(sfx[name], "Sfx", db, 2)
		_mech[key] = p
	p.play()


func _update_duck(delta: float) -> void:
	var target := 1.0 if (radio != null and radio.is_speaking()) else 0.0
	# attaque rapide (la voix prend la place), relâchement lent (pas de pompage entre deux répliques)
	_duck = move_toward(_duck, target, delta / (0.15 if target > _duck else 0.9))
	AudioServer.set_bus_volume_db(_bus_amb, BUS_AMB_DB - DUCK_AMB_DB * _duck)
	AudioServer.set_bus_volume_db(_bus_sfx, BUS_SFX_DB - DUCK_SFX_DB * _duck)


# ---------------------------------------------------------------- pause, coupures, contrôle

func set_paused(p: bool) -> void:
	_paused = p
	for n in _host.get_children():
		if n is AudioStreamPlayer:
			(n as AudioStreamPlayer).stream_paused = p
	if radio != null:
		radio.set_paused(p)


func toggle_mute() -> void:
	muted = not muted
	AudioServer.set_bus_mute(0, muted)


## Style de voix de la radio (cosmétique) : hauteur, bande passante et saturation ajoutées au traitement de la banque.
## st : {"pitch": 1.0, "lpf_hz": 3800.0, "drive": 0.0}
func set_voice_style(st: Dictionary) -> void:
	if _bus_radio < 0:
		return
	if AudioServer.get_bus_effect_count(_bus_radio) > 0:
		var lpf = AudioServer.get_bus_effect(_bus_radio, 0)
		if lpf is AudioEffectLowPassFilter:
			lpf.cutoff_hz = clampf(float(st.get("lpf_hz", 3800.0)), 1500.0, 9000.0)
	var pitch := clampf(float(st.get("pitch", 1.0)), 0.5, 2.0)
	if absf(pitch - 1.0) > 0.01:
		if _pitch_idx < 0:
			AudioServer.add_bus_effect(_bus_radio, AudioEffectPitchShift.new())
			_pitch_idx = AudioServer.get_bus_effect_count(_bus_radio) - 1
		(AudioServer.get_bus_effect(_bus_radio, _pitch_idx) as AudioEffectPitchShift).pitch_scale = pitch
		AudioServer.set_bus_effect_enabled(_bus_radio, _pitch_idx, true)
	elif _pitch_idx >= 0:
		AudioServer.set_bus_effect_enabled(_bus_radio, _pitch_idx, false)
	var drive := clampf(float(st.get("drive", 0.0)), 0.0, 1.0)
	if drive > 0.01:
		if _drive_idx < 0:
			var d := AudioEffectDistortion.new()
			d.mode = AudioEffectDistortion.MODE_OVERDRIVE
			AudioServer.add_bus_effect(_bus_radio, d)
			_drive_idx = AudioServer.get_bus_effect_count(_bus_radio) - 1
		(AudioServer.get_bus_effect(_bus_radio, _drive_idx) as AudioEffectDistortion).drive = drive
		AudioServer.set_bus_effect_enabled(_bus_radio, _drive_idx, true)
	elif _drive_idx >= 0:
		AudioServer.set_bus_effect_enabled(_bus_radio, _drive_idx, false)


func toggle_voices() -> void:
	voices_muted = not voices_muted
	AudioServer.set_bus_mute(_bus_radio, voices_muted)


func status() -> String:
	return "SON %s · VOIX %s" % ["COUPÉ" if muted else "ACTIF", "COUPÉES" if voices_muted else "ACTIVES"]


func clock() -> float:
	return _clock


## Enregistre le mélange final (Master) pour les contrôles automatiques : --audio-record=/chemin/mix.wav
func start_record(path: String) -> void:
	_record_path = path
	_record = AudioEffectRecord.new()
	AudioServer.add_bus_effect(0, _record)
	_record.set_recording_active(true)


func stop_record() -> void:
	if _record == null:
		return
	_record.set_recording_active(false)
	var rec: AudioStreamWAV = _record.get_recording()
	if rec != null and _record_path != "":
		rec.save_to_wav(_record_path)
		print("[son] enregistrement : %s (%.1f s)" % [_record_path, rec.get_length()])
	_record = null


func stats() -> String:
	return "rafales %d, coups %d, répliques radio %d" % [_n_bursts, _n_shots, radio.lines_started() if radio != null else 0]
