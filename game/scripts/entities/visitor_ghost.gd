class_name VisitorGhost
extends Node3D
## WATCHTOWER: someone else using the cluster, shown as a translucent
## astronaut walking to whatever they touch. Writes make them fire a zap,
## denied requests turn them red.

var key := ""
var goal := Vector3.ZERO
var color := Vox.PINK
var _body: Node3D
var label := ""      # name + tool (drawn by the HUD overlay)
var _mat: StandardMaterial3D
var _t := randf() * 10.0
var _alarm := 0.0


func setup(k: String, col: Color, text: String) -> void:
	key = k
	color = col
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(col, 0.55)
	_body = Node3D.new()
	add_child(_body)
	for spec in [[Vector3(0.6, 0.55, 0.4), Vector3(0, 0.66, 0)], [Vector3(0.54, 0.48, 0.5), Vector3(0, 1.18, 0)],
			[Vector3(0.18, 0.4, 0.22), Vector3(-0.15, 0.2, 0)], [Vector3(0.18, 0.4, 0.22), Vector3(0.15, 0.2, 0)]]:
		var mi := MeshInstance3D.new()
		mi.mesh = Vox.box_mesh(spec[0])
		mi.position = spec[1]
		mi.material_override = _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_body.add_child(mi)
	var visor := Vox.box(_body, Vector3(0.42, 0.22, 0.05), Vector3(0, 1.2, 0.26), Color("0b0d1a"), 0.0, false)
	visor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_text(text)


func set_text(text: String) -> void:
	label = text


## Red flashing for a while (denied request, secrets...).
func alarm() -> void:
	_alarm = 3.0


func _process(delta: float) -> void:
	_t += delta
	var to := goal - global_position
	to.y = 0
	var moving := to.length() > 0.3
	if moving:
		var step := minf(to.length(), 3.2 * delta)
		global_position += to.normalized() * step
		rotation.y = lerp_angle(rotation.y, atan2(to.x, to.z), clampf(delta * 8.0, 0.0, 1.0))
	global_position.y = lerpf(global_position.y, goal.y, clampf(delta * 5.0, 0.0, 1.0))
	_body.position.y = 0.15 + sin(_t * 3.0) * 0.1  # ghosts float
	if _alarm > 0.0:
		_alarm -= delta
		var on := fmod(_t, 0.3) < 0.15
		_mat.albedo_color = Color(Vox.RED if on else color, 0.7)
	else:
		_mat.albedo_color = Color(color, 0.45 + sin(_t * 2.0) * 0.1)
