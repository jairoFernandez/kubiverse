class_name StorageTank
extends Entity
## A PersistentVolumeClaim as a storage tank in its hall: full and green when
## Bound to a volume, empty with a blinking light while Pending, red if Lost.
## Pipes (drawn by World) go to the pods that mount it.

var _geo: Node3D
var _lamp: MeshInstance3D
var _sig := ""
var _t := 0.0


func _init() -> void:
	kind = "volume"


static func status_color(d: Dictionary) -> Color:
	match str(d.get("status", "")):
		"Bound": return Vox.GREEN
		"Pending": return Vox.YELLOW
	return Vox.RED


func update_data(d: Dictionary) -> void:
	data = d
	key = d.ns + "/" + d.name
	var sig := "%s|%s|%s" % [d.get("status", ""), d.get("capacity", ""), d.ns]
	if sig != _sig:
		_sig = sig
		_rebuild()


func users() -> Array:
	return data.get("pods", []) if data.get("pods") != null else []


func label_text() -> String:
	return "pvc " + str(data.get("name", ""))


func label_sub() -> String:
	var size := str(data.get("capacity", "")) if str(data.get("capacity", "")) != "" else str(data.get("request", ""))
	var st := str(data.get("status", ""))
	if st == "Pending":
		return tr("%s - PENDING: no volume yet (class %s)") % [size, data.get("class", "?")]
	return tr("%s %s - used by %d pods") % [size, st, users().size()]


func label_color() -> Color:
	return status_color(data)


func anchor() -> Vector3:
	return global_position + Vector3(0, 2.7, 0)


func pipe_origin() -> Vector3:
	return global_position + Vector3(0, 0.6, 0)


func _rebuild() -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	var shell := Vox.ns_color(data.get("ns", "")).darkened(0.35)
	var c := status_color(data)
	var bound := str(data.get("status", "")) == "Bound"
	Vox.box(_geo, Vector3(1.6, 0.16, 1.6), Vector3(0, 0.08, 0), Vox.SLATE)
	# The tank: a stack of boxes, rounded by a smaller one on each face.
	for i in 4:
		var y := 0.35 + i * 0.45
		Vox.box(_geo, Vector3(1.3, 0.42, 1.3), Vector3(0, y, 0), shell)
		Vox.box(_geo, Vector3(1.45, 0.3, 1.0), Vector3(0, y, 0), shell.lightened(0.08))
	# The level window: full when Bound.
	var level := 1.6 if bound else 0.2
	Vox.box(_geo, Vector3(0.3, 1.7, 0.06), Vector3(0, 1.0, 0.68), Color(0.05, 0.05, 0.08))
	Vox.box(_geo, Vector3(0.24, level, 0.08), Vector3(0, 0.17 + level * 0.5, 0.7), c, 1.2, false)
	Vox.box(_geo, Vector3(1.0, 0.2, 1.0), Vector3(0, 2.1, 0), shell.lightened(0.15))
	_lamp = Vox.box(_geo, Vector3(0.24, 0.24, 0.24), Vector3(0, 2.32, 0), c, 2.0, false)


func _process(delta: float) -> void:
	_t += delta
	position = position.lerp(target, clampf(delta * 3.0, 0.0, 1.0))
	if _lamp:
		_lamp.visible = str(data.get("status", "")) == "Bound" or fmod(_t, 0.8) < 0.45
