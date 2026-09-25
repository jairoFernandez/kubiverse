class_name IngressGate
extends Entity
## The gate between the Internet city and the plant: the Ingress
## controller. Every Ingress rule (domain + path -> Service) goes through
## it. A red lamp means some route has no working backend.

var routes: Array = []    # [{host, path, ns, service, port, tls, status}] status: ok | empty | missing
var classes: Array = []
var addresses: Array = []
var _geo: Node3D
var _lamp: MeshInstance3D
var _bar: MeshInstance3D
var _t := 0.0


func _init() -> void:
	kind = "gate"
	key = "@gate"


func setup(r: Array, cls: Array, addr: Array) -> void:
	routes = r
	classes = cls
	addresses = addr
	data = {"name": "ingress", "routes": r, "classes": cls, "address": addr}
	if _geo == null:
		_build()
	var broken := routes.any(func(x): return x.status != "ok")
	_lamp.material_override = Vox.mat(Vox.RED if broken else Vox.GREEN, 3.0, false)


func _build() -> void:
	_geo = Node3D.new()
	add_child(_geo)
	# Two towers and a big lintel with the sign.
	for x in [-3.4, 3.4]:
		Vox.box(_geo, Vector3(1.2, 4.2, 1.2), Vector3(x, 2.1, 0), Vox.SLATE)
		Vox.box(_geo, Vector3(1.4, 0.3, 1.4), Vector3(x, 4.35, 0), Vox.SILVER)
		Vox.box(_geo, Vector3(0.5, 0.5, 0.2), Vector3(x, 3.2, 0.62), Vox.GREEN, 2.5, false)
	Vox.box(_geo, Vector3(8.0, 1.1, 1.0), Vector3(0, 4.4, 0), Vox.NAVY)
	Vox.box(_geo, Vector3(7.2, 0.7, 0.1), Vector3(0, 4.4, 0.52), Vox.GREEN.darkened(0.3), 1.2, false)
	for i in 6:  # little chevrons pointing into the plant
		Vox.box(_geo, Vector3(0.5, 0.18, 0.08), Vector3(-2.2 + i * 0.9, 4.4, 0.6), Vox.YELLOW, 2.0, false)
	_lamp = Vox.box(_geo, Vector3(0.6, 0.6, 0.6), Vector3(0, 5.3, 0), Vox.GREEN, 3.0, false)
	# Barrier arm (raised when traffic flows)
	Vox.box(_geo, Vector3(0.4, 1.0, 0.4), Vector3(-2.6, 0.5, 1.0), Vox.SILVER)
	_bar = Vox.box(_geo, Vector3(4.8, 0.16, 0.16), Vector3(-0.2, 1.0, 1.0), Vox.RED)


func _process(delta: float) -> void:
	_t += delta
	if _bar:
		# Open while there are routes; shut when nothing is exposed.
		var open := not routes.is_empty()
		_bar.rotation.z = lerpf(_bar.rotation.z, 1.3 if open else 0.0, clampf(delta * 3.0, 0.0, 1.0))
		_bar.position = Vector3(-2.6 + cos(_bar.rotation.z) * 2.4, 1.0 + sin(_bar.rotation.z) * 2.4, 1.0)


func label_text() -> String:
	return tr("INGRESS (the door to the Internet)")


func label_sub() -> String:
	if routes.is_empty():
		return tr("closed: no Ingress, nothing is published by domain")
	var hosts := {}
	var bad := 0
	for r in routes:
		hosts[r.host] = true
		if r.status != "ok":
			bad += 1
	var t := tr("%d domains, %d routes") % [hosts.size(), routes.size()]
	if bad > 0:
		t += "  " + tr("(%d broken)") % bad
	return t


func label_color() -> Color:
	return Vox.RED if routes.any(func(x): return x.status != "ok") else Vox.GREEN


func anchor() -> Vector3:
	return global_position + Vector3(0, 6.2, 0)


func pick_radius() -> float:
	return 60.0
