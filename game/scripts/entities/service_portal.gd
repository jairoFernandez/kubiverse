class_name ServicePortal
extends Entity
## A Service as a portal arch. Beams (drawn by World) link it to the pods its
## selector matches.

var _geo: Node3D
var _core: MeshInstance3D
var _sig := ""
var _t := 0.0


func _init() -> void:
	kind = "service"


static func type_color(d: Dictionary) -> Color:
	if d.get("cluster_ip", "") == "None":
		return Vox.SILVER
	match d.get("type", ""):
		"NodePort": return Vox.ORANGE
		"LoadBalancer": return Vox.PINK
		"ExternalName": return Vox.LAVENDER
	return Vox.BLUE


func update_data(d: Dictionary) -> void:
	data = d
	key = d.ns + "/" + d.name
	var sig := "%s|%s|%s" % [d.get("type", ""), d.get("cluster_ip", ""), d.ns]
	if sig != _sig:
		_sig = sig
		_rebuild()


func backends() -> Array:
	return data.get("pods", []) if data.get("pods") != null else []


func label_text() -> String:
	return "service " + str(data.get("name", ""))


func label_sub() -> String:
	return tr("%s - sends traffic to %d pods") % [data.get("type", ""), backends().size()]


func label_color() -> Color:
	return type_color(data)


func anchor() -> Vector3:
	return global_position + Vector3(0, 2.6, 0)


func beam_origin() -> Vector3:
	return global_position + Vector3(0, 2.15, 0)


func _rebuild() -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	var frame := Vox.ns_color(data.get("ns", "")).darkened(0.25)
	var tc := type_color(data)
	Vox.box(_geo, Vector3(2.0, 0.15, 0.8), Vector3(0, 0.075, 0), Vox.SLATE)
	for x in [-0.72, 0.72]:
		Vox.box(_geo, Vector3(0.36, 1.9, 0.4), Vector3(x, 1.1, 0), frame)
	Vox.box(_geo, Vector3(1.9, 0.36, 0.44), Vector3(0, 2.05, 0), frame)
	Vox.box(_geo, Vector3(0.3, 0.3, 0.46), Vector3(0, 2.05, 0), tc, 2.0, false)
	_core = Vox.box(_geo, Vector3(1.08, 1.7, 0.08), Vector3(0, 1.0, 0), tc, 1.2, false)


func _process(delta: float) -> void:
	_t += delta
	position = position.lerp(target, clampf(delta * 3.0, 0.0, 1.0))
	if _core:
		_core.scale = Vector3(1.0, 1.0, 1.0 + sin(_t * 4.0) * 0.5)
		_core.visible = backends().size() > 0 or fmod(_t, 0.8) < 0.4
