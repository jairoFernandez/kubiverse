class_name StorageFactory
extends Entity
## A StorageClass as the tank factory of the storage yard: its provisioner
## builds a PersistentVolume for each claim that asks for this class. The
## default class has a star on the roof.

var _geo: Node3D
var _gear: MeshInstance3D
var _sig := ""
var _t := 0.0


func _init() -> void:
	kind = "storageclass"


func update_data(d: Dictionary) -> void:
	data = d
	key = str(d.name)
	var sig := "%s|%s" % [d.get("provisioner", ""), d.get("default", false)]
	if sig != _sig:
		_sig = sig
		_rebuild()


func label_text() -> String:
	return "storageclass " + str(data.get("name", "")) + (" *" if data.get("default", false) else "")


func label_sub() -> String:
	return str(data.get("provisioner", ""))


func label_color() -> Color:
	return Vox.YELLOW if data.get("default", false) else Vox.SILVER


func anchor() -> Vector3:
	return global_position + Vector3(0, 3.2, 0)


func _rebuild() -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	var wall := Color(0.46, 0.4, 0.5)
	Vox.box(_geo, Vector3(3.0, 2.2, 2.2), Vector3(0, 1.1, 0), wall)
	Vox.box(_geo, Vector3(3.2, 0.2, 2.4), Vector3(0, 2.3, 0), wall.darkened(0.2))
	Vox.box(_geo, Vector3(0.5, 1.2, 0.5), Vector3(0.9, 3.0, -0.5), wall.darkened(0.3))   # chimney
	Vox.box(_geo, Vector3(1.2, 1.4, 0.08), Vector3(0, 0.7, 1.12), Color(0.1, 0.1, 0.14))   # door
	_gear = Vox.box(_geo, Vector3(0.7, 0.7, 0.12), Vector3(-0.8, 1.6, 1.12), Vox.YELLOW if data.get("default", false) else Vox.SILVER, 0.6)
	if data.get("default", false):
		Vox.box(_geo, Vector3(0.4, 0.4, 0.4), Vector3(-0.6, 2.7, 0), Vox.YELLOW, 1.6, false)


func _process(delta: float) -> void:
	_t += delta
	if _gear:
		_gear.rotation.z = _t * 1.5
