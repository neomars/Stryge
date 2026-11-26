extends RefCounted
## Contrôle d'un export : vérifie que les fichiers lus directement par le jeu (données JSON, sons .wav, shaders, scène
## principale) sont bien dans le paquet. Sans eux, le jeu ne démarre pas (JSON) ou reste muet (WAV) sans planter.
##
## Lancé par le jeu lui-même avec l'option « --export-check » (après « -- ») :
##   binaire_exporté --headless -- --export-check
##   godot --headless --path . -- --export-check        (depuis les sources)
##   ... --export-check --check-out=/chemin/rapport.txt (écrit aussi le rapport dans ce fichier : utile sous Windows, où
##                                                       l'exécutable graphique n'affiche rien dans la console)
##
## Imprime « EXPORT_CHECK_OK » et rend le code 0 si tout est présent ; sinon liste les manques et rend le code 1.

const REQUIRED_JSON := [
	"res://data/weapons.json", "res://data/scoring.json", "res://data/campaign.json", "res://data/difficulty.json",
	"res://data/modes.json", "res://data/radio_script.json", "res://data/progression.json", "res://data/upgrades.json",
	"res://data/medals.json", "res://data/cosmetics.json", "res://data/mutators.json", "res://data/zombies.json",
	"res://data/supports.json",
	"res://data/mission_01.json", "res://data/mission_02.json", "res://data/mission_03.json",
	"res://data/mission_04.json", "res://data/mission_05.json",
	"res://data/cities/quartier_latin.json", "res://data/cities/montmartre.json", "res://data/cities/halles.json",
	"res://data/cities/defense.json", "res://data/cities/stade.json",
	"res://audio/sfx/sfx.json", "res://audio/radio/voices.json",
]
const REQUIRED_WAV := ["res://audio/radio/voices.wav"]
const SFX_DIR := "res://audio/sfx"
const MIN_SFX := 20
const REQUIRED_RES := [
	"res://scenes/main.tscn", "res://shaders/thermal_post.gdshader", "res://shaders/thermal_ground.gdshader",
	"res://shaders/thermal_building.gdshader", "res://shaders/thermal_human.gdshader",
]


## Rend le code de sortie (0 : tout est présent). report_path : fichier où écrire aussi le rapport (vide : aucun).
static func run(report_path: String = "") -> int:
	var problems: Array[String] = []
	var checked := 0

	for path in REQUIRED_JSON:
		if not FileAccess.file_exists(path):
			problems.append("fichier absent : " + path)
			continue
		var d = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(d) != TYPE_DICTIONARY:
			problems.append("JSON illisible ou vide : " + path)
		checked += 1

	var wavs: Array[String] = []
	for w_path in REQUIRED_WAV:
		wavs.append(w_path)
	var da := DirAccess.open(SFX_DIR)
	if da == null:
		problems.append("dossier absent : " + SFX_DIR)
	else:
		var n := 0
		for f in da.get_files():
			if f.ends_with(".wav"):
				wavs.append("%s/%s" % [SFX_DIR, f])
				n += 1
		if n < MIN_SFX:
			problems.append("%d sons seulement dans %s (au moins %d attendus)" % [n, SFX_DIR, MIN_SFX])
	for path in wavs:
		if not FileAccess.file_exists(path):
			problems.append("son absent : " + path)
			continue
		var w: AudioStreamWAV = AudioStreamWAV.load_from_file(path)
		if w == null or w.get_length() <= 0.0:
			problems.append("son illisible : " + path)
		checked += 1

	for path in REQUIRED_RES:
		if not ResourceLoader.exists(path) or load(path) == null:
			problems.append("ressource absente ou illisible : " + path)
		checked += 1

	var report: Array[String] = []
	if problems.is_empty():
		report.append("EXPORT_CHECK_OK %d fichiers contrôlés" % checked)
	else:
		for p in problems:
			report.append("EXPORT_CHECK_ECHEC " + p)
	for line in report:
		if problems.is_empty():
			print(line)
		else:
			printerr(line)
	if not report_path.is_empty():
		var f := FileAccess.open(report_path, FileAccess.WRITE)
		if f != null:
			f.store_string("\n".join(report) + "\n")
			f.close()
	return 0 if problems.is_empty() else 1
