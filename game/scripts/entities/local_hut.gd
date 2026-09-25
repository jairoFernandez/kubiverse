class_name LocalHut
extends Entity
## "Your PC": the machine running the bridge (127.0.0.1). Port-forward tubes
## start at the manifold on its roof: private doors into the cluster that
## skip the Ingress gate.

var _screen: MeshInstance3D
var _t := 0.0


func _init() -> void:
	kind = "home"
	key = "@home"
	data = {"name": "127.0.0.1"}
	_build()


func _build() -> void:
	# Little cabin with a big monitor facing the plant.
	Vox.box(self, Vector3(3.2, 2.2, 3.0), Vector3(0, 1.1, 0), Vox.NAVY)
	Vox.box(self, Vector3(3.6, 0.35, 3.4), Vector3(0, 2.35, 0), Vox.PEACH)
	Vox.box(self, Vector3(0.9, 1.3, 0.1), Vector3(0.9, 0.65, 1.52), Vox.BROWN)  # door
	Vox.box(self, Vector3(1.5, 1.0, 0.12), Vector3(-0.6, 1.4, 1.52), Vox.SLATE)
	_screen = Vox.box(self, Vector3(1.3, 0.8, 0.08), Vector3(-0.6, 1.4, 1.6), Vox.BLUE, 2.5, false)
	# Tube manifold on the roof: where every port-forward starts.
	Vox.box(self, Vector3(1.4, 0.6, 1.4), Vector3(0, 2.8, 0), Vox.SILVER)
	Vox.box(self, Vector3(1.0, 0.25, 1.0), Vector3(0, 3.2, 0), Color("a8e6ff"), 2.0, false)
	# Antenna with a blinking light.
	Vox.box(self, Vector3(0.12, 1.2, 0.12), Vector3(1.3, 3.1, -1.2), Vox.SILVER)


func _process(delta: float) -> void:
	_t += delta
	if _screen:
		var busy: bool = world != null and not world.forwards.is_empty()
		var col := Color("a8e6ff") if busy else Vox.BLUE
		_screen.material_override = Vox.mat(col, 1.5 + (sin(_t * 6.0) * 0.8 if busy else 0.0), false)


## Where the tubes plug in.
func port() -> Vector3:
	return global_position + Vector3(0, 3.3, 0)


func footprint() -> Rect2:
	return Rect2(position.x - 1.8, position.z - 1.7, 3.6, 3.4)


func label_text() -> String:
	return tr("YOUR PC  127.0.0.1")


func label_sub() -> String:
	var n: int = world.forwards.size() if world else 0
	return tr("%d port-forwards open") % n if n > 0 else tr("port-forward a pod or Service to open a tunnel")


func label_color() -> Color:
	return Color("a8e6ff")


func anchor() -> Vector3:
	return global_position + Vector3(0, 4.2, 0)
