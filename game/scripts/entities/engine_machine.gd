class_name EngineMachine
extends Entity
## A control-plane (or node) component in the ENGINE ROOM. Its lamp shows
## the health of its pod in kube-system when the cluster exposes it
## (managed clusters hide the control plane: then it reads "managed").

var comp := ""            # api | etcd | controllers | scheduler | kubelet | you | dns | proxy | cni
var _geo: Node3D
var _spin: Node3D
var _lamp: MeshInstance3D
var _t := 0.0
var _pulse := 0.0


func _init() -> void:
	kind = "engine"


func setup(c: String, k: String, d: Dictionary) -> void:
	comp = c
	key = k
	data = d
	if _geo == null:
		_build()
	var col: Color = {"ok": Vox.GREEN, "bad": Vox.RED, "managed": Vox.LAVENDER, "none": Vox.SLATE}.get(str(d.get("status", "none")), Vox.SLATE)
	_lamp.material_override = Vox.mat(col, 3.0, false)


func _build() -> void:
	_geo = Node3D.new()
	add_child(_geo)
	match comp:
		"api":
			Vox.box(_geo, Vector3(4.0, 5.5, 4.0), Vector3(0, 2.75, 0), Color("3b4f8a"))
			Vox.box(_geo, Vector3(4.4, 0.4, 4.4), Vector3(0, 5.7, 0), Vox.SILVER)
			for x in [-1.0, 1.0]:
				Vox.box(_geo, Vector3(1.4, 1.0, 0.2), Vector3(x, 2.4, 2.05), Color("a8e6ff"), 1.5, false)  # counters
			Vox.box(_geo, Vector3(0.2, 2.0, 0.2), Vector3(0, 6.9, 0), Vox.SILVER)
			_spin = Node3D.new()
			_spin.position = Vector3(0, 7.9, 0)
			_geo.add_child(_spin)
			Vox.box(_spin, Vector3(1.6, 0.15, 0.15), Vector3.ZERO, Vox.BLUE, 2.0, false)
		"etcd":
			Vox.box(_geo, Vector3(3.6, 3.2, 3.0), Vector3(0, 1.6, 0), Vox.SLATE)
			Vox.box(_geo, Vector3(2.4, 2.4, 0.3), Vector3(0, 1.6, 1.55), Vox.SILVER)
			Vox.box(_geo, Vector3(0.9, 0.9, 0.3), Vector3(0, 1.6, 1.75), Vox.YELLOW, 0.8)
			var members := maxi(1, int(data.get("members", 1)))
			for i in mini(members, 5):
				Vox.box(_geo, Vector3(1.6, 0.35, 1.6), Vector3(0, 3.4 + i * 0.45, 0), Vox.GREEN.darkened(0.2), 1.0, false)
		"controllers":
			Vox.box(_geo, Vector3(4.2, 2.4, 3.0), Vector3(0, 1.2, 0), Color("5b4a3a"))
			_spin = Node3D.new()
			_spin.position = Vector3(0, 3.6, 0)
			_geo.add_child(_spin)
			for i in 3:
				var g := Node3D.new()
				g.position = Vector3(-1.3 + i * 1.3, 0, 0)
				_spin.add_child(g)
				Vox.box(g, Vector3(1.1, 1.1, 0.3), Vector3.ZERO, Vox.ORANGE, 0.3)
				for a in 6:
					Vox.box(g, Vector3(0.3, 0.3, 0.3), Vector3(0.7, 0, 0).rotated(Vector3.FORWARD, a * TAU / 6.0), Vox.ORANGE, 0.3)
		"scheduler":
			Vox.box(_geo, Vector3(1.0, 5.0, 1.0), Vector3(0, 2.5, 0), Vox.YELLOW.darkened(0.2))
			_spin = Node3D.new()
			_spin.position = Vector3(0, 5.2, 0)
			_geo.add_child(_spin)
			Vox.box(_spin, Vector3(5.0, 0.5, 0.5), Vector3(1.5, 0, 0), Vox.YELLOW)
			Vox.box(_spin, Vector3(0.1, 1.6, 0.1), Vector3(3.7, -0.8, 0), Vox.SILVER)
			Vox.box(_spin, Vector3(0.8, 0.8, 0.8), Vector3(3.7, -1.9, 0), Vox.PINK, 0.8)
			Vox.box(_geo, Vector3(2.4, 0.6, 2.4), Vector3(0, 0.3, 0), Vox.SLATE)
		"kubelet":
			Vox.box(_geo, Vector3(3.2, 1.8, 2.6), Vector3(0, 0.9, 0), Color("2f5d50"))
			_spin = Node3D.new()  # the container runtime: a drum
			_spin.position = Vector3(0.6, 2.3, 0)
			_geo.add_child(_spin)
			Vox.box(_spin, Vector3(1.2, 1.0, 1.2), Vector3.ZERO, Vox.BLUE.darkened(0.2), 0.5)
			Vox.box(_geo, Vector3(0.8, 0.8, 0.2), Vector3(-0.8, 1.2, 1.35), Color("a8e6ff"), 1.2, false)
		"you":
			Vox.box(_geo, Vector3(3.0, 1.0, 1.6), Vector3(0, 0.9, 0), Vox.BROWN)
			Vox.box(_geo, Vector3(1.8, 1.2, 0.2), Vector3(0, 2.0, -0.4), Vox.SLATE)
			Vox.box(_geo, Vector3(1.5, 0.9, 0.1), Vector3(0, 2.0, -0.28), Vox.GREEN.darkened(0.4), 1.5, false)
		"dns":
			Vox.box(_geo, Vector3(1.6, 3.0, 1.6), Vector3(0, 1.5, 0), Vox.RED.darkened(0.3))
			Vox.box(_geo, Vector3(1.2, 1.6, 0.1), Vector3(0, 1.7, 0.82), Color("a8e6ff"), 0.8, false)
		"proxy":
			Vox.box(_geo, Vector3(2.6, 2.2, 1.2), Vector3(0, 1.1, 0), Vox.LAVENDER.darkened(0.3))
			for i in 6:
				Vox.box(_geo, Vector3(0.25, 0.25, 0.1), Vector3(-0.9 + (i % 3) * 0.9, 1.0 + (i / 3) * 0.7, 0.62), [Vox.GREEN, Vox.YELLOW, Vox.BLUE][i % 3], 2.0, false)
		"cni":
			for i in 3:
				Vox.box(_geo, Vector3(0.6, 0.6, 3.0), Vector3(-0.9 + i * 0.9, 0.4 + i * 0.5, 0), Vox.PINK.darkened(0.3 * i))
			Vox.box(_geo, Vector3(1.2, 1.2, 1.2), Vector3(0, 0.6, 0), Vox.PINK, 0.6)
	_lamp = Vox.box(_geo, Vector3(0.5, 0.5, 0.5), Vector3(1.6, 0.4, 1.4), Vox.SLATE, 3.0, false)


## A work order arrived: a quick glow and a jolt.
func pulse() -> void:
	_pulse = 0.6


func _process(delta: float) -> void:
	_t += delta
	_pulse = maxf(0.0, _pulse - delta)
	var busy := 1.0 + _pulse * 8.0
	if _spin:
		match comp:
			"controllers":
				for g in _spin.get_children():
					g.rotation.z += delta * busy * (1.0 if g.get_index() % 2 == 0 else -1.0)
			"scheduler":
				_spin.rotation.y = sin(_t * 0.4) * 1.2 + _pulse * 2.0
			"kubelet":
				_spin.rotation.y += delta * busy * 1.5
			_:
				_spin.rotation.y += delta * busy
	_geo.scale = Vector3.ONE * (1.0 + _pulse * 0.08)


func port() -> Vector3:
	return global_position + Vector3(0, 1.2, 0)


func label_text() -> String:
	return tr(str(data.get("title", comp)))


func label_sub() -> String:
	var s := tr(str(data.get("role", "")))
	match str(data.get("status", "")):
		"managed": s += "  ·  " + tr("managed by the provider (hidden)")
		"bad": s += "  ·  " + tr("NOT HEALTHY")
	return s


func label_color() -> Color:
	return {"ok": Vox.GREEN, "bad": Vox.RED, "managed": Vox.LAVENDER}.get(str(data.get("status", "")), Vox.WHITE)


func anchor() -> Vector3:
	var h: float = {"api": 8.8, "etcd": 5.8, "controllers": 5.0, "scheduler": 6.4, "kubelet": 3.6, "you": 3.2, "dns": 3.8, "proxy": 3.0, "cni": 2.6}.get(comp, 4.0)
	return global_position + Vector3(0, h, 0)


func pick_radius() -> float:
	return 40.0
