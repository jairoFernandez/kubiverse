class_name Pearl
extends Entity
## A Secret as a pearl in the bank's vault (on the tray of its namespace):
## gold for TLS certificates, blue for registry credentials, white for the
## rest. One nobody uses is dull; one pods reference but that doesn't exist
## is a cracked red pearl outside the vault. A ConfigMap is a notebook in
## the library's reference section (same data, same inspector).

var _geo: Node3D
var _glow: MeshInstance3D
var _sig := ""
var _t := 0.0


func _init() -> void:
	kind = "config"


func missing() -> bool:
	return str(data.get("exists", "")) == "no"


func users() -> Array:
	return data.get("pods", []) if data.get("pods") != null else []


static func pearl_color(d: Dictionary) -> Color:
	if str(d.get("exists", "")) == "no":
		return Vox.RED
	match str(d.get("type", "")):
		"tls": return Color("ffd966")
		"registry": return Color("7ec8ff")
	return Color("fff4ec")


func update_data(d: Dictionary) -> void:
	data = d
	key = "%s/%s/%s" % [d.kind, d.ns, d.name]
	var sig := "%s|%s|%s|%d" % [d.kind, d.get("type", ""), d.get("exists", ""), users().size()]
	if sig == _sig:
		return
	_sig = sig
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	if str(d.kind) == "Secret":
		var c := pearl_color(d)
		var dull := users().is_empty() and not missing()
		if dull:
			c = c.darkened(0.45)
		var m := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.34
		sm.height = 0.68
		sm.radial_segments = 12
		sm.rings = 6
		m.mesh = sm
		m.material_override = Vox.mat(c if not missing() else Color(1, 0.2, 0.3, 0.55), 0.0 if dull else 0.9, false)
		m.position = Vector3(0, 0.34, 0)
		_geo.add_child(m)
		_glow = m
		if missing():  # a crack
			Vox.box(_geo, Vector3(0.05, 0.3, 0.05), Vector3(0.05, 0.24, 0.2), Color(0.3, 0, 0.05), 0.0, false).rotation.z = 0.5
	else:
		# ConfigMap: a notebook, with a tab per key read by name.
		var keys: Array = d.get("keys", []) if d.get("keys") != null else []
		var cover := Color("4a90c8") if not missing() else Color(1, 0.2, 0.3, 0.55)
		if users().is_empty() and not missing():
			cover = cover.darkened(0.45)
		Vox.box(_geo, Vector3(0.5, 0.12, 0.66), Vector3(0, 0.06, 0), cover, 0.0, not missing())
		Vox.box(_geo, Vector3(0.44, 0.1, 0.6), Vector3(0.02, 0.07, 0), Vox.WHITE, 0.0, false)
		for i in mini(keys.size(), 4):
			Vox.box(_geo, Vector3(0.08, 0.04, 0.12), Vector3(0.28, 0.08, -0.22 + i * 0.15), [Vox.YELLOW, Vox.GREEN, Vox.PINK, Vox.ORANGE][i], 0.5, false)


func label_text() -> String:
	return ("secret " if str(data.get("kind", "")) == "Secret" else "configmap ") + str(data.get("name", ""))


func label_sub() -> String:
	if missing():
		return tr("MISSING - %d pods can't start") % (data.get("missing", []) as Array).size() if data.get("missing") != null else tr("MISSING")
	if users().is_empty():
		return tr("nobody uses it")
	return tr("%d pods use it") % users().size()


func label_color() -> Color:
	return pearl_color(data) if str(data.get("kind", "")) == "Secret" else Color("7ec8ff")


func anchor() -> Vector3:
	return global_position + Vector3(0, 0.9, 0)


func pick_radius() -> float:
	return 14.0


func _process(delta: float) -> void:
	_t += delta
	position = position.lerp(target, clampf(delta * 3.0, 0.0, 1.0))
	if _glow and missing():
		_glow.visible = fmod(_t, 0.8) < 0.55
