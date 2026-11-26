extends SceneTree
## Banc d'essai des personnages : dessine des planches de poses (cycles de marche et de course, variété,
## états, tour complet) et les enregistre en PNG, sans passer par le jeu.
##
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
##       --rendering-method gl_compatibility -s tests/viewer.gd -- --out=/tmp/humans [--sheet=gait] [--color=1]
##
## Planches : gait (marche, course, zombie, vue de côté et de face), variety, states, turn. Par défaut : toutes.
## Les images sont en niveaux de gris (chaleur brute) ; --color=1 garde le marquage vert/magenta du jeu.

const HumanMesh = preload("res://scripts/world/human_mesh.gd")
const SHADER: Shader = preload("res://shaders/thermal_human.gdshader")

var _out := "/tmp/humans"
var _sheet := "all"
var _color := false
var _vp: SubViewport
var _cam: Camera3D
var _mmi: MultiMeshInstance3D
var _mm: MultiMesh
var _ruler: Node3D


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--sheet="):
			_sheet = a.substr(8)
		elif a.begins_with("--color="):
			_color = a.substr(8) == "1"
	DirAccess.make_dir_recursive_absolute(_out)
	_build_scene()
	_run()


func _build_scene() -> void:
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.size = Vector2i(1280, 400)
	root.add_child(_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.07, 0.07)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 2.2
	_cam.near = 0.1
	_cam.far = 200.0
	_cam.environment = env
	_vp.add_child(_cam)
	_cam.position = Vector3(0, 1.0, 40.0)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	var hm := HumanMesh.new()
	_mm.mesh = hm.build()
	_mm.instance_count = 64
	_mm.visible_instance_count = 0
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("min_px", 0.0)
	mat.set_shader_parameter("atmos_k", 0.0)
	mat.set_shader_parameter("debug_gray", not _color)
	_mmi.material_override = mat
	_vp.add_child(_mmi)
	_ruler = Node3D.new()
	_vp.add_child(_ruler)
	print("[viewer] maillage : ", hm.triangle_count(), " triangles")


# une personne : position (x, z), orientation (rad), échelle, type, graine, phase, allure, chaleur
func _p(x: float, yaw: float, kind: int, seed: float, ph: float, g: float, heat: float = 0.85,
		z: float = 0.0, sc: float = 1.0, y: float = 0.0) -> Dictionary:
	return {"x": x, "y": y, "z": z, "yaw": yaw, "sc": sc, "kind": kind, "seed": seed, "ph": ph, "g": g, "heat": heat}


func _jobs() -> Array:
	var jobs: Array = []
	var side := -PI * 0.5      # regard vers +X (profil droit vers la caméra)
	var front := PI            # face à la caméra
	if _sheet == "all" or _sheet == "gait":
		for spec in [["walk", 1, 0.35, 0.85], ["run", 1, 1.0, 0.85], ["zomb", 0, 0.45, 0.97]]:
			var pl: Array = []
			for i in 8:
				pl.append(_p(1.5 * i, side, spec[1], 0.321, TAU * i / 8.0, spec[2], spec[3]))
			jobs.append({"name": "gait_%s_side" % spec[0], "w": 1920, "h": 420, "cx": 5.25, "cy": 1.0, "ch": 2.3,
					"people": pl, "ground": true})
		for spec in [["walk", 1, 0.35, 0.85], ["run", 1, 1.0, 0.85], ["zomb", 0, 0.45, 0.97]]:
			var pl2: Array = []
			for i in 8:
				pl2.append(_p(1.5 * i, front, spec[1], 0.321, TAU * i / 8.0, spec[2], spec[3]))
			jobs.append({"name": "gait_%s_front" % spec[0], "w": 1920, "h": 420, "cx": 5.25, "cy": 1.0, "ch": 2.3,
					"people": pl2, "ground": true})
	if _sheet == "all" or _sheet == "variety":
		var rows := [[1, 0.0, 0.85], [1, 0.35, 0.85], [0, 0.45, 0.97], [0, 0.0, 0.97]]
		var pl3: Array = []
		for r in 4:
			for c in 10:
				var sd: float = fmod(0.013 + 0.0937 * float(r * 10 + c), 1.0)
				pl3.append(_p(1.2 * c, front if r % 2 == 0 else PI * 0.8, rows[r][0], sd,
						TAU * (0.13 * c + 0.31 * r), rows[r][1], rows[r][2], 0.0, 1.0, 2.2 * (3 - r)))
		jobs.append({"name": "variety", "w": 1920, "h": 1000, "cx": 5.4, "cy": 4.0, "ch": 9.0,
				"people": pl3, "ground": true})
	if _sheet == "all" or _sheet == "states":
		var pl4: Array = []
		var specs := [[0, 3.0, 0.0, "pound"], [0, 3.0, 1.6, "pound"], [0, 4.0, 0.0, "feed"], [0, 4.0, 1.1, "feed"],
				[0, 6.0, 0.0, "lie"], [0, 5.8, 0.0, "rise"], [0, 5.6, 0.0, "rise"],
				[0, 5.4, 0.0, "rise"], [0, 5.2, 0.0, "rise"], [0, 5.05, 0.0, "rise"],
				[2, 0.5, 0.0, "eaten"], [2, 1.0, 0.0, "eaten"], [3, 1.0, 0.0, "corpse"], [4, 1.0, 0.0, "zcorpse"]]
		for i in specs.size():
			var spec: Array = specs[i]
			var heat := 0.97
			if spec[0] == 2:
				heat = 0.85
			elif spec[0] == 3:
				heat = 0.35
			elif spec[0] == 4:
				heat = 0.30
			var row := i / 7
			var col := i % 7
			pl4.append(_p(1.9 * col, side if (i % 2 == 0) else front, spec[0], 0.321 + 0.037 * i, spec[2] + 0.4, spec[1], heat,
					0.0, 1.0, 2.4 * (1 - row)))
		jobs.append({"name": "states", "w": 1920, "h": 780, "cx": 5.7, "cy": 1.9, "ch": 5.2,
				"people": pl4, "ground": true})
	if _sheet == "all" or _sheet == "turn":
		var pl5: Array = []
		for i in 8:
			pl5.append(_p(1.3 * i, TAU * i / 8.0, 1, 0.73, 1.2, 0.0, 0.85))
		jobs.append({"name": "turn_civil", "w": 1920, "h": 420, "cx": 4.55, "cy": 1.0, "ch": 2.3, "people": pl5, "ground": true})
		var pl6: Array = []
		for i in 8:
			pl6.append(_p(1.3 * i, TAU * i / 8.0, 0, 0.73, 1.2, 0.0, 0.97))
		jobs.append({"name": "turn_zombie", "w": 1920, "h": 420, "cx": 4.55, "cy": 1.0, "ch": 2.3, "people": pl6, "ground": true})
	return jobs


func _apply(job: Dictionary) -> void:
	_vp.size = Vector2i(job["w"], job["h"])
	_cam.size = job["ch"]
	_cam.position = Vector3(job["cx"], job["cy"], 40.0)
	var pl: Array = job["people"]
	_mm.visible_instance_count = pl.size()
	for i in pl.size():
		var d: Dictionary = pl[i]
		var b := Basis(Vector3.UP, d["yaw"]).scaled(Vector3.ONE * d["sc"])
		_mm.set_instance_transform(i, Transform3D(b, Vector3(d["x"], d["y"], d["z"])))
		_mm.set_instance_custom_data(i, Color(d["heat"], float(d["kind"]) + d["seed"], d["ph"], d["g"]))
	for c in _ruler.get_children():
		c.queue_free()
	if job.get("ground", false):
		var seen := {}
		for d in pl:
			var yk: float = d["y"]
			if not seen.has(yk):
				seen[yk] = true
				_add_box(Vector3(job["cx"], yk - 0.01, -1.0), Vector3(40.0, 0.02, 0.2), 0.30)
				for k in range(1, 7):
					_add_box(Vector3(job["cx"], yk + 0.3 * k, -3.0), Vector3(40.0, 0.004, 0.05), 0.12 if k % 3 else 0.2)


func _add_box(pos: Vector3, size: Vector3, g: float) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(g, g, g)
	mi.material_override = m
	mi.position = pos
	_ruler.add_child(mi)


func _run() -> void:
	var jobs := _jobs()
	for job in jobs:
		_apply(job)
		for _f in 4:
			await process_frame
		var img: Image = _vp.get_texture().get_image()
		var path: String = _out.path_join(str(job["name"]) + ".png")
		var err := img.save_png(path)
		print("[viewer] ", path, " ", img.get_size(), " err=", err)
	quit()
