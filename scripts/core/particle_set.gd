extends RefCounted
## Tampon circulaire de particules « sans état » dessinées par un MultiMesh.
##
## Le CPU n'écrit une particule qu'à sa naissance ; ensuite son shader calcule sa position, sa taille
## et sa luminosité à partir de l'horloge `t_now` (uniform). Une particule morte (âge hors de [0, durée])
## est rejetée hors de l'écran par le shader. Quand le tampon est plein, la plus ancienne est écrasée.
##
## Disposition d'une instance (16 flottants, MultiMesh en TRANSFORM_3D + données d'instance).
## La « transformation » est détournée : le shader relit ses colonnes dans MODEL_MATRIX.
##   MODEL_MATRIX[3].xyz = p (position de départ)     MODEL_MATRIX[0].xyz = v (vitesse initiale)
##   MODEL_MATRIX[1].xyz = (naissance, durée de vie, s0)
##   MODEL_MATRIX[2].xyz = (s1, graine, extra)
##   INSTANCE_CUSTOM     = (c0, c1, c2, c3)
## Dans le tampon (lignes de 4 : colonne X, colonne Y, colonne Z, origine) cela donne :
##   [vx, t0, s1, px,  vy, life, seed, py,  vz, s0, extra, pz,  c0, c1, c2, c3]

var mm: MultiMesh
var mat: ShaderMaterial
var n := 0
var head := 0
var buf := PackedFloat32Array()
var dirty := false


func setup(parent: Node3D, node_name: String, mesh: Mesh, shader: Shader, count: int, aabb: AABB, priority: int) -> void:
	n = count
	buf.resize(n * 16)
	for i in n:
		var o := i * 16
		buf[o + 1] = 1.0e9          # naissance dans un futur lointain : jamais affichée
		buf[o + 5] = 1.0
	mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = n
	mm.custom_aabb = aabb
	mm.buffer = buf
	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = mm
	mat = ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = priority
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


func emit(p: Vector3, v: Vector3, t0: float, life: float, s0: float, s1: float, seed: float, extra: float,
		c0: float, c1: float, c2: float, c3: float) -> void:
	var o := head * 16
	buf[o] = v.x
	buf[o + 1] = t0
	buf[o + 2] = s1
	buf[o + 3] = p.x
	buf[o + 4] = v.y
	buf[o + 5] = life
	buf[o + 6] = seed
	buf[o + 7] = p.y
	buf[o + 8] = v.z
	buf[o + 9] = s0
	buf[o + 10] = extra
	buf[o + 11] = p.z
	buf[o + 12] = c0
	buf[o + 13] = c1
	buf[o + 14] = c2
	buf[o + 15] = c3
	head = (head + 1) % n
	dirty = true


## À appeler à chaque image : met l'horloge du shader à jour et envoie le tampon s'il a changé.
func flush(t_now: float) -> void:
	mat.set_shader_parameter("t_now", t_now)
	if dirty:
		mm.buffer = buf
		dirty = false
