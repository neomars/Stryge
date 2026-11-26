extends RefCounted
## Canonnière en virage de pylône (orbite à gauche, vue de dessus : sens anti-horaire)
## et nacelle optique : la caméra regarde en permanence un point visé au sol.

const MIN_FOV := 0.45             # champ minimal (°) pour le zoom de base (×8)
const BASE_ZOOM_MAX := 8.0

var ctx
var cam: Camera3D
var radius := 1500.0
var altitude := 2100.0
var speed := 95.0
var theta := 0.7                 # angle sur l'orbite (rad)
var center := Vector2.ZERO       # centre de l'orbite (x, z)
var center_target := Vector2.ZERO
var aim := Vector2.ZERO          # point visé au sol (x, z)
var pos := Vector3.ZERO
var base_fov := 4.0              # champ de l'arme sélectionnée (°)
var fov := 4.0
var zoom := 1.0
var zoom_max := BASE_ZOOM_MAX     # relevé par l'optique de l'atelier
var min_fov := MIN_FOV
var shake := 0.0
var view_h := 720.0              # hauteur de l'écran en unités de canevas
var half_extent := 1150.0
var max_aim_radius := 1500.0


func setup(p_ctx, p_cam: Camera3D) -> void:
	ctx = p_ctx
	cam = p_cam
	var o: Dictionary = ctx.mission.get("orbit", {})
	radius = float(o.get("radius_m", 1500.0))
	altitude = float(o.get("altitude_m", 2100.0))
	speed = float(o.get("speed_ms", 95.0))
	var sz: Vector2 = ctx.city.size_m()
	half_extent = minf(sz.x, sz.y) * 0.5 - 30.0
	center = ctx.zone_center()                    # l'orbite est centrée sur la zone de jeu (le centre de la carte s'il n'y en a pas)
	center_target = center
	aim = center + Vector2(40.0, -60.0)
	fov = base_fov
	# Projection en frustum : Camera3D.fov refuse moins de 1°, or on veut descendre bien plus bas
	# (zoom fort pour voir les personnages courir). `size` = hauteur du champ au plan proche.
	cam.projection = Camera3D.PROJECTION_FRUSTUM
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	update(0.0)


func update(dt: float) -> void:
	theta += speed / radius * dt
	var to_c := center_target - center
	var dist := to_c.length()
	if dist > 0.5:
		center += to_c / dist * minf(dist, 45.0 * dt)
	pos = Vector3(center.x + radius * cos(theta), altitude, center.y - radius * sin(theta))
	var fov_t := clampf(base_fov / zoom, min_fov, 30.0)
	fov = lerpf(fov, fov_t, 1.0 - exp(-7.0 * dt))
	cam.size = 2.0 * cam.near * tan(deg_to_rad(fov) * 0.5)
	cam.frustum_offset = Vector2.ZERO
	aim = ctx.zone_clamp(aim)                     # la visée ne sort pas de la zone de jeu (ni de la carte)
	var off := aim - center
	if off.length() > max_aim_radius:
		aim = center + off.normalized() * max_aim_radius
	cam.global_position = pos
	cam.look_at(Vector3(aim.x, 0.0, aim.y), Vector3.UP)
	if shake > 0.001:
		var a := deg_to_rad(fov) * 0.02 * shake
		cam.rotate_object_local(Vector3.RIGHT, ctx.rng.randfn(0.0, a))
		cam.rotate_object_local(Vector3.UP, ctx.rng.randfn(0.0, a))
		shake = lerpf(shake, 0.0, 1.0 - exp(-9.0 * dt))


## Déplace le point visé d'un nombre de pixels d'écran (1 px de souris ≈ 1 px d'image).
func slew_px(d: Vector2) -> void:
	var tgt := Vector3(aim.x, 0.0, aim.y)
	var dist := pos.distance_to(tgt)
	var m_per_px := 2.0 * dist * tan(deg_to_rad(fov) * 0.5) / view_h
	var fwd := Vector2(aim.x - pos.x, aim.y - pos.z).normalized()
	var right := Vector2(-fwd.y, fwd.x)
	var fore := dist / maxf(altitude, 1.0)     # ≈ 1 / sin(élévation) : raccourci de perspective
	aim += right * (d.x * m_per_px) + fwd * (-d.y * m_per_px * fore)


func recenter() -> void:
	center_target = aim


## [origine, direction, droite, haut] de la ligne de visée réelle (secousses comprises).
func ray() -> Array:
	var b := cam.global_transform.basis
	return [cam.global_position, -b.z, b.x, b.y]


func bearing_to(p: Vector3) -> float:
	var d := Vector2(p.x - pos.x, p.z - pos.z)
	return fposmod(rad_to_deg(atan2(d.x, -d.y)), 360.0)
