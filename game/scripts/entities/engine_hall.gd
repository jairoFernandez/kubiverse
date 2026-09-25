class_name EngineHall
extends Entity
## The ENGINE ROOM building in the Kubernetes Quarter: a brick works with a
## big gear on its front and smoking chimneys. Inside, the control plane's
## machines (API server, etcd, scheduler, controllers, kubelets).

const W := 11.0
const D := 8.0
const H := 5.0

var _gear: Node3D
var _t := 0.0


func _init() -> void:
	kind = "engine_hall"
	key = "@engine"
	data = {"name": "engine"}
	_build()


func _build() -> void:
	Vox.box(self, Vector3(W, H, D), Vector3(0, H * 0.5, 0), Color("8a4b3a"))
	Vox.box(self, Vector3(W + 0.6, 0.5, D + 0.6), Vector3(0, H + 0.25, 0), Vox.SLATE)
	for i in 5:  # brick courses
		Vox.box(self, Vector3(W + 0.05, 0.12, D + 0.05), Vector3(0, 0.8 + i * 0.9, 0), Color("6f3a2d"), 0.0, false)
	for x in [-W * 0.3, W * 0.3]:
		Vox.box(self, Vector3(1.2, 3.0, 1.2), Vector3(x, H + 1.5, -D * 0.25), Vox.BROWN)
		Vox.box(self, Vector3(1.4, 0.3, 1.4), Vector3(x, H + 3.0, -D * 0.25), Vox.SLATE)
	# Big gear on the facade.
	_gear = Node3D.new()
	_gear.position = Vector3(W * 0.22, H * 0.6, D * 0.5 + 0.2)
	add_child(_gear)
	Vox.box(_gear, Vector3(2.2, 2.2, 0.3), Vector3.ZERO, Vox.ORANGE, 0.4)
	for a in 8:
		var tooth := Vox.box(_gear, Vector3(0.6, 0.6, 0.3), Vector3(1.35, 0, 0).rotated(Vector3.FORWARD, a * TAU / 8.0), Vox.ORANGE, 0.4)
		tooth.rotation.z = a * TAU / 8.0
	Vox.box(_gear, Vector3(0.6, 0.6, 0.4), Vector3.ZERO, Vox.SLATE)
	# Door and sign.
	Vox.box(self, Vector3(2.4, 2.8, 0.2), Vector3(-W * 0.2, 1.4, D * 0.5 + 0.05), Color("2a1d1a"))
	Vox.box(self, Vector3(5.0, 0.9, 0.15), Vector3(-W * 0.2, H - 0.8, D * 0.5 + 0.1), Vox.YELLOW, 1.2, false)


func _process(delta: float) -> void:
	_t += delta
	if _gear:
		_gear.rotation.z -= delta * 0.8
	if world and fmod(_t, 1.3) < delta:
		for x in [-W * 0.3, W * 0.3]:
			world.smoke(global_position + Vector3(x, H + 3.4, -D * 0.25), Color("5f574f"))


func door_position() -> Vector3:
	return global_position + Vector3(-W * 0.2, 0, D * 0.5 + 1.2)


func footprint() -> Rect2:
	return Rect2(position.x - W * 0.5, position.z - D * 0.5, W, D)


func label_text() -> String:
	return tr("ENGINE ROOM")


func label_sub() -> String:
	return tr("how Kubernetes works inside: API server, etcd, scheduler, controllers, kubelets")


func label_color() -> Color:
	return Vox.ORANGE


func anchor() -> Vector3:
	return global_position + Vector3(0, H + 4.0, 0)


func pick_radius() -> float:
	return 60.0
