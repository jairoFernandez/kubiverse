class_name RemotePlayer
extends Node3D
## Another player of the party: a solid astronaut in their color with their
## name and hit points above (main's label overlay). Main moves it to where Party says they are
## (interpolated); a hit makes it flash, zero HP lays it down.

const COLORS := [Vox.YELLOW, Vox.BLUE, Vox.PINK, Vox.GREEN, Vox.ORANGE, Vox.LAVENDER, Vox.PEACH, Vox.RED]

var id := 0
var color := Vox.YELLOW
var _body: Node3D
var label := ""     # name + HP (drawn by the HUD overlay, like the ghosts' tags)
var _mats: Array[StandardMaterial3D] = []
var _flash := 0.0
var _t := randf() * 10.0
var _last := Vector3.INF


static func color_of(i: int) -> Color:
	return COLORS[posmod(i, COLORS.size())]


func setup(player_id: int, color_index: int, name_text: String) -> void:
	id = player_id
	color = color_of(color_index)
	_body = Node3D.new()
	add_child(_body)
	for spec in [[Vector3(0.6, 0.55, 0.4), Vector3(0, 0.66, 0), color], [Vector3(0.54, 0.48, 0.5), Vector3(0, 1.18, 0), Vox.WHITE],
			[Vector3(0.18, 0.4, 0.22), Vector3(-0.15, 0.2, 0), color], [Vector3(0.18, 0.4, 0.22), Vector3(0.15, 0.2, 0), color],
			[Vector3(0.12, 0.12, 0.5), Vector3(0.36, 0.8, 0.2), Vox.SLATE]]:
		var mi := MeshInstance3D.new()
		mi.mesh = Vox.box_mesh(spec[0])
		mi.position = spec[1]
		var m := StandardMaterial3D.new()
		m.albedo_color = spec[2]
		mi.material_override = m
		_mats.append(m)
		_body.add_child(mi)
	var visor := Vox.box(_body, Vector3(0.42, 0.22, 0.05), Vector3(0, 1.2, 0.26), Color("0b0d1a"), 0.0, false)
	visor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_info(name_text, PartyRules.MAX_HP)


func set_info(name_text: String, hp: int) -> void:
	label = "%s  %s" % [name_text, "♥%d" % hp if hp > 0 else "✖"]
	_body.rotation.z = 0.0 if hp > 0 else PI * 0.5   # down until they respawn


func place(p: Vector3, yaw: float) -> void:
	global_position = p
	rotation.y = yaw
	_last = p


func flash() -> void:
	_flash = 0.4


func _process(delta: float) -> void:
	_t += delta
	if _flash > 0.0:
		_flash -= delta
	var c := Vox.WHITE if _flash > 0.0 and fmod(_t, 0.12) < 0.06 else color
	for i in [0, 2, 3]:
		_mats[i].albedo_color = c
