class_name LoanCard
extends Entity
## A PersistentVolumeClaim still waiting for its book, as a request card on
## the librarian's desk: yellow while it waits, red when it will never be
## served (its class doesn't exist).

var _geo: Node3D
var _t := 0.0


func _init() -> void:
	kind = "volume"


func update_data(d: Dictionary, hopeless: bool) -> void:
	data = d
	key = d.ns + "/" + d.name
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	var c := Vox.RED if hopeless else Vox.YELLOW
	Vox.box(_geo, Vector3(0.9, 0.05, 0.6), Vector3(0, 0.03, 0), Vox.WHITE)
	Vox.box(_geo, Vector3(0.7, 0.06, 0.08), Vector3(0, 0.05, -0.15), c, 0.8, false)
	Vox.box(_geo, Vector3(0.5, 0.06, 0.05), Vector3(-0.1, 0.05, 0.05), Vox.SLATE, 0.0, false)
	Vox.box(_geo, Vector3(0.12, 0.5, 0.12), Vector3(0.35, 0.3, 0.2), c, 1.4, false)   # a little flag


func label_text() -> String:
	return tr("request %s/%s") % [data.get("ns", ""), data.get("name", "")]


func label_sub() -> String:
	return tr("%s of class %s - waiting for a book") % [data.get("request", ""), data.get("class", "?")]


func label_color() -> Color:
	return Vox.YELLOW


func anchor() -> Vector3:
	return global_position + Vector3(0, 1.0, 0)


func pick_radius() -> float:
	return 16.0
