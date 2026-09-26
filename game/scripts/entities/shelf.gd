class_name Shelf
extends Entity
## A StorageClass as a section of the library: a long bookshelf with three
## boards and a sign on top (the default class has a gold one). Its books
## (the PersistentVolumes of that class) are placed on it by World.

const LEN := 7.0
const BOARDS := 3
const BOARD_H := 1.25

var _sig := ""


func _init() -> void:
	kind = "storageclass"


func update_data(d: Dictionary) -> void:
	data = d
	key = str(d.name)
	var sig := "%s|%s" % [d.get("provisioner", ""), d.get("default", false)]
	if sig != _sig:
		_sig = sig
		for c in get_children():
			c.queue_free()
		var wood := Color("6b4a32")
		Vox.box(self, Vector3(LEN, BOARDS * BOARD_H + 0.3, 0.2), Vector3(0, (BOARDS * BOARD_H + 0.3) * 0.5, -0.45), wood.darkened(0.2))
		for x in [-LEN * 0.5, LEN * 0.5]:
			Vox.box(self, Vector3(0.2, BOARDS * BOARD_H + 0.3, 1.0), Vector3(x, (BOARDS * BOARD_H + 0.3) * 0.5, 0), wood)
		for b in BOARDS + 1:
			Vox.box(self, Vector3(LEN, 0.12, 1.0), Vector3(0, b * BOARD_H + 0.06, 0), wood.lightened(0.1))
		var sign_col := Vox.YELLOW if d.get("default", false) else Vox.SILVER
		Vox.box(self, Vector3(3.2, 0.6, 0.12), Vector3(0, BOARDS * BOARD_H + 0.75, -0.3), sign_col, 0.5)


## Where the i-th book stands (x along the shelf, which board).
func slot(x: float, board: int) -> Vector3:
	return global_position + Vector3(-LEN * 0.5 + 0.3 + x, board * BOARD_H + 0.12, 0.05)


func capacity_x() -> float:
	return LEN - 0.6


func label_text() -> String:
	return tr("section %s") % str(data.get("name", "")) + (" *" if data.get("default", false) else "")


func label_sub() -> String:
	return "%s · %s" % [data.get("provisioner", ""), data.get("reclaim", "")]


func label_color() -> Color:
	return Vox.YELLOW if data.get("default", false) else Vox.PEACH


func anchor() -> Vector3:
	return global_position + Vector3(0, BOARDS * BOARD_H + 1.6, 0)


func pick_radius() -> float:
	return 40.0
