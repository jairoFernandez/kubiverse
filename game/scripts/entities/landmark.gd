class_name Landmark
extends Entity
## A building of the plant you can walk into:
##  - LIBRARY: storage. Columns, a dome and a big open book over the door.
##  - BANK: secrets. White columns, a gold pediment and a vault wheel.

const W := 11.0
const D := 8.0
const H := 5.5

var what := "library"   # library | bank
var _wheel: Node3D
var _t := 0.0


func setup(w: String) -> void:
	what = w
	kind = "landmark"
	key = "@" + w
	data = {"name": w}
	for c in get_children():
		c.queue_free()
	if w == "library":
		_library()
	else:
		_bank()


func _library() -> void:
	var stone := Color("c9b99a")
	Vox.box(self, Vector3(W, H, D), Vector3(0, H * 0.5, 0), stone)
	Vox.box(self, Vector3(W + 0.8, 0.5, D + 0.8), Vector3(0, 0.25, 0), stone.darkened(0.2))
	Vox.box(self, Vector3(W + 0.6, 0.5, D + 0.6), Vector3(0, H + 0.25, 0), stone.darkened(0.25))
	# The dome.
	for i in 4:
		var s := 6.0 - i * 1.4
		Vox.box(self, Vector3(s, 0.7, s), Vector3(0, H + 0.85 + i * 0.7, -0.6), Color("5f7a8a").lightened(i * 0.06))
	# Columns on the facade.
	for x in [-4.2, -2.4, 2.4, 4.2]:
		Vox.box(self, Vector3(0.7, H - 0.6, 0.7), Vector3(x, (H - 0.6) * 0.5 + 0.5, D * 0.5 + 0.4), stone.lightened(0.1))
	# Tall windows with book spines behind.
	for x in [-3.3, 3.3]:
		Vox.box(self, Vector3(1.2, 2.6, 0.1), Vector3(x, 2.6, D * 0.5 + 0.05), Color("1d2b53"))
		for k in 5:
			Vox.box(self, Vector3(0.16, 0.7, 0.12), Vector3(x - 0.45 + k * 0.22, 2.0, D * 0.5 + 0.08), [Vox.RED, Vox.GREEN, Vox.BLUE, Vox.YELLOW, Vox.ORANGE][k], 0.3)
	# The door and a big open book over it.
	Vox.box(self, Vector3(2.2, 3.0, 0.2), Vector3(0, 1.5, D * 0.5 + 0.05), Color("3a2a1e"))
	Vox.box(self, Vector3(1.4, 0.9, 0.15), Vector3(-0.72, H - 0.9, D * 0.5 + 0.12), Vox.WHITE, 0.6)
	Vox.box(self, Vector3(1.4, 0.9, 0.15), Vector3(0.72, H - 0.9, D * 0.5 + 0.12), Vox.WHITE, 0.6)
	Vox.box(self, Vector3(0.12, 0.95, 0.18), Vector3(0, H - 0.9, D * 0.5 + 0.14), Vox.BROWN)


func _bank() -> void:
	var marble := Color("e8e4dc")
	Vox.box(self, Vector3(W, H, D), Vector3(0, H * 0.5, 0), marble.darkened(0.08))
	for i in 3:  # steps
		Vox.box(self, Vector3(W + 1.2 - i * 0.4, 0.25, D + 1.6 - i * 0.4), Vector3(0, 0.125 + i * 0.25, 0.3), marble.darkened(0.15 + i * 0.03))
	for x in [-4.4, -2.6, -0.9, 0.9, 2.6, 4.4]:
		Vox.box(self, Vector3(0.6, H - 1.0, 0.6), Vector3(x, (H - 1.0) * 0.5 + 0.75, D * 0.5 + 0.5), marble)
	# Gold pediment and roof.
	Vox.box(self, Vector3(W + 0.6, 0.6, D + 1.2), Vector3(0, H + 0.1, 0.3), Vox.YELLOW.darkened(0.2), 0.2)
	for i in 3:
		Vox.box(self, Vector3(W - i * 3.0, 0.5, 1.2), Vector3(0, H + 0.65 + i * 0.5, D * 0.5 + 0.2), Vox.YELLOW.darkened(0.1), 0.3)
	# The vault wheel on the door.
	Vox.box(self, Vector3(2.6, 3.2, 0.2), Vector3(0, 1.85, D * 0.5 + 0.05), Color("5a5f6e"))
	_wheel = Node3D.new()
	_wheel.position = Vector3(0, 1.9, D * 0.5 + 0.2)
	add_child(_wheel)
	Vox.box(_wheel, Vector3(1.4, 1.4, 0.1), Vector3.ZERO, Color("9aa0ad"))
	for a in 4:
		var spoke := Vox.box(_wheel, Vector3(1.8, 0.14, 0.14), Vector3.ZERO, Vox.YELLOW, 0.4)
		spoke.rotation.z = a * PI / 4.0
	# Pearls in the windows.
	for x in [-3.6, 3.6]:
		Vox.box(self, Vector3(1.0, 1.4, 0.1), Vector3(x, 2.4, D * 0.5 + 0.05), Color("1d2b53"))
		Vox.box(self, Vector3(0.35, 0.35, 0.12), Vector3(x, 2.3, D * 0.5 + 0.09), Color("fff1e8"), 1.2)


func _process(delta: float) -> void:
	_t += delta
	if _wheel:
		_wheel.rotation.z = sin(_t * 0.6) * 0.6


func door_position() -> Vector3:
	return global_position + Vector3(0, 0, D * 0.5 + 1.6)


func footprint() -> Rect2:
	return Rect2(position.x - W * 0.5, position.z - D * 0.5, W, D)


func label_text() -> String:
	return tr("LIBRARY (storage)") if what == "library" else tr("BANK (secrets)")


func label_sub() -> String:
	return str(data.get("sub", ""))


func label_color() -> Color:
	return Vox.PEACH if what == "library" else Vox.YELLOW


func anchor() -> Vector3:
	return global_position + Vector3(0, H + 3.2, 0)


func pick_radius() -> float:
	return 60.0
