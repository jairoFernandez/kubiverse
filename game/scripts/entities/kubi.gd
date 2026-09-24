class_name Kubi
extends Node3D
## Kubi, the assistant drone: a little floating dex-like robot that follows
## the player, looks at the nearest problem, and talks in a speech bubble.
## Y opens its panel (diagnosis + chat).

var target: Node3D                 # who to follow (the player)
var look_at_pos := Vector3.INF     # a problem to point at (INF = none)
var mood := "ok"                   # ok | alert | thinking | talking

var _body: Node3D
var _eyes: Array[MeshInstance3D] = []
var _screen: MeshInstance3D
var bubble := ""                  # speech bubble text (drawn by the HUD overlay)
var bubble_color := Vox.WHITE
var _bubble_t := 0.0
var _blink := 2.0
var _t := 0.0
var _arrow: Node3D


func _ready() -> void:
	scale = Vector3.ONE * 1.3
	_body = Node3D.new()
	add_child(_body)
	# Red dex body with a white bezel, a screen face and a lightning antenna.
	Vox.box(_body, Vector3(0.62, 0.72, 0.2), Vector3.ZERO, Vox.RED)
	Vox.box(_body, Vector3(0.5, 0.42, 0.04), Vector3(0, 0.08, 0.11), Vox.WHITE, 0.0, false)
	_screen = Vox.box(_body, Vector3(0.42, 0.34, 0.04), Vector3(0, 0.08, 0.13), Color("1d2b53"), 0.6, false)
	for x in [-0.1, 0.1]:
		_eyes.append(Vox.box(_body, Vector3(0.08, 0.12, 0.03), Vector3(x, 0.1, 0.155), Vox.BLUE, 3.0, false))
	Vox.box(_body, Vector3(0.1, 0.04, 0.03), Vector3(0, -0.2, 0.12), Vox.WHITE, 0.0, false)  # speaker grille
	Vox.box(_body, Vector3(0.05, 0.22, 0.05), Vector3(0.12, 0.47, 0), Vox.YELLOW, 1.5, false)
	Vox.box(_body, Vector3(0.12, 0.05, 0.05), Vector3(0.16, 0.58, 0), Vox.YELLOW, 1.5, false)
	for x in [-0.36, 0.36]:  # little side fins
		Vox.box(_body, Vector3(0.1, 0.3, 0.12), Vector3(x, -0.05, 0), Vox.RED.darkened(0.25))
	var glow := Vox.box(_body, Vector3(0.24, 0.05, 0.12), Vector3(0, -0.4, 0), Vox.BLUE, 3.0, false)
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Arrow floating in front, pointing at the problem.
	_arrow = Node3D.new()
	add_child(_arrow)
	var a := Vox.box(_arrow, Vector3(0.1, 0.1, 0.3), Vector3(0, 0, 0.15), Vox.ORANGE, 3.0, false)
	a.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	Vox.box(_arrow, Vector3(0.24, 0.1, 0.1), Vector3(0, 0, 0.32), Vox.ORANGE, 3.0, false)
	_arrow.visible = false
	for mi in find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Shows text in the speech bubble for a few seconds.
func say(text: String, secs := 6.0, color := Vox.WHITE) -> void:
	bubble = text
	bubble_color = color
	_bubble_t = secs


func snap_to_target() -> void:
	if target:
		global_position = _home()


func _home() -> Vector3:
	var fwd := Vector3(sin(target.rotation.y), 0, cos(target.rotation.y))
	var base := target.global_position
	if target.has_method("forward"):
		fwd = target.forward()
	var right := fwd.cross(Vector3.UP).normalized()
	return base - right * 0.9 - fwd * 0.5 + Vector3(0, 1.9, 0)


func _process(delta: float) -> void:
	_t += delta
	if target:
		var home := _home()
		if global_position.distance_to(home) > 12.0:
			global_position = home  # teleported / changed level
		global_position = global_position.lerp(home, clampf(delta * 4.0, 0.0, 1.0))
	# Bob, lean with speed, face the player's view or the problem.
	_body.position.y = sin(_t * 2.6) * 0.08
	var face := Vector3.INF
	if look_at_pos != Vector3.INF:
		face = look_at_pos
	elif target and target.has_method("forward"):
		face = global_position + target.forward()
	if face != Vector3.INF:
		var d := face - global_position
		d.y = 0
		if d.length() > 0.05:
			rotation.y = lerp_angle(rotation.y, atan2(d.x, d.z), clampf(delta * 6.0, 0.0, 1.0))
	_arrow.visible = look_at_pos != Vector3.INF and mood == "alert"
	if _arrow.visible:
		_arrow.position = Vector3(0, -0.1, 0.35 + sin(_t * 6.0) * 0.08)
	# Eyes: blink; colour by mood; "thinking" scans side to side.
	_blink -= delta
	var open := _blink > 0.0 or _blink < -0.12
	if _blink < -0.12:
		_blink = randf_range(2.0, 4.5)
	var col := {"ok": Vox.GREEN, "alert": Vox.ORANGE, "thinking": Vox.BLUE, "talking": Vox.WHITE}.get(mood, Vox.BLUE) as Color
	for i in _eyes.size():
		var e := _eyes[i]
		e.scale.y = 1.0 if open else 0.15
		e.material_override = Vox.mat(col, 3.0, false)
		e.position.x = (-0.1 if i == 0 else 0.1) + (sin(_t * 5.0) * 0.05 if mood == "thinking" else 0.0)
	if mood == "alert":
		_body.rotation.z = sin(_t * 14.0) * 0.08
	else:
		_body.rotation.z = lerpf(_body.rotation.z, 0.0, clampf(delta * 5.0, 0.0, 1.0))
	if _bubble_t > 0.0:
		_bubble_t -= delta
		if _bubble_t <= 0.0:
			bubble = ""
