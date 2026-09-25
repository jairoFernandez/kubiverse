class_name VaultBox
extends Entity
## A Secret as a safe (a padlock, a dial and a ribbon by its type: gold for
## TLS, blue for registry credentials) or a ConfigMap as a filing cabinet, in
## the hall's vault. One drawer per key the pods read by name. Cables (drawn
## by World) go to the pods that use it. A reference to something that
## doesn't exist is a red ghost; one nobody uses gathers dust.

var _geo: Node3D
var _lamp: MeshInstance3D
var _sig := ""
var _t := 0.0


func _init() -> void:
	kind = "config"


func is_secret() -> bool:
	return str(data.get("kind", "")) == "Secret"


func missing() -> bool:
	return str(data.get("exists", "")) == "no"


func users() -> Array:
	return data.get("pods", []) if data.get("pods") != null else []


static func type_color(d: Dictionary) -> Color:
	if str(d.get("exists", "")) == "no":
		return Vox.RED
	if str(d.get("kind", "")) != "Secret":
		return Vox.BLUE.lightened(0.2)
	match str(d.get("type", "")):
		"tls": return Vox.YELLOW
		"registry": return Vox.BLUE
	return Vox.LAVENDER


func update_data(d: Dictionary) -> void:
	data = d
	key = "%s/%s/%s" % [d.kind, d.ns, d.name]
	var keys: Array = d.get("keys", []) if d.get("keys") != null else []
	var sig := "%s|%s|%s|%d|%d" % [d.kind, d.get("type", ""), d.get("exists", ""), keys.size(), users().size()]
	if sig != _sig:
		_sig = sig
		_rebuild()


func label_text() -> String:
	return ("secret " if is_secret() else "configmap ") + str(data.get("name", ""))


func label_sub() -> String:
	if missing():
		return tr("MISSING - %d pods can't start") % (data.get("missing", []) as Array).size() if data.get("missing") != null else tr("MISSING")
	if users().is_empty():
		return tr("nobody uses it")
	var keys: Array = data.get("keys", []) if data.get("keys") != null else []
	return tr("%d pods use it") % users().size() + ((" · " + tr("%d keys by name") % keys.size()) if not keys.is_empty() else "")


func label_color() -> Color:
	return type_color(data)


func anchor() -> Vector3:
	return global_position + Vector3(0, 2.2, 0)


func cable_origin() -> Vector3:
	return global_position + Vector3(0, 1.0, 0.5)


func _rebuild() -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	var c := type_color(data)
	var ghost := missing()
	var dusty := users().is_empty() and not ghost
	var keys: Array = data.get("keys", []) if data.get("keys") != null else []
	if is_secret():
		var steel := Color(0.3, 0.32, 0.38) if not dusty else Color(0.24, 0.24, 0.26)
		if ghost:
			steel = Color(1, 0.2, 0.3, 0.35)
		Vox.box(_geo, Vector3(1.4, 1.5, 1.2), Vector3(0, 0.75, 0), steel, 0.6 if ghost else 0.0, not ghost)
		Vox.box(_geo, Vector3(1.2, 1.3, 0.06), Vector3(0, 0.75, 0.62), steel.lightened(0.12), 0.0, not ghost)
		# The dial and the handle.
		Vox.box(_geo, Vector3(0.36, 0.36, 0.08), Vector3(-0.2, 0.9, 0.67), Color(0.75, 0.75, 0.8))
		Vox.box(_geo, Vector3(0.08, 0.4, 0.08), Vector3(0.35, 0.8, 0.68), Color(0.75, 0.75, 0.8))
		# Padlock on top, the colour of its type.
		Vox.box(_geo, Vector3(0.3, 0.26, 0.14), Vector3(0, 1.66, 0.4), c, 0.4)
		Vox.box(_geo, Vector3(0.2, 0.16, 0.04), Vector3(0, 1.86, 0.4), c.darkened(0.3))
		# TLS: a ribbon across; registry: a key on the side.
		match str(data.get("type", "")):
			"tls": Vox.box(_geo, Vector3(1.42, 0.14, 1.22), Vector3(0, 1.2, 0), c, 0.3)
			"registry": Vox.box(_geo, Vector3(0.06, 0.12, 0.5), Vector3(0.72, 0.8, 0.1), c, 0.5)
	else:
		var wood := Color(0.55, 0.42, 0.3) if not dusty else Color(0.4, 0.33, 0.27)
		if ghost:
			wood = Color(1, 0.2, 0.3, 0.35)
		var drawers := clampi(keys.size(), 2, 5)
		var h := 0.4 * drawers + 0.1
		Vox.box(_geo, Vector3(1.0, h, 1.0), Vector3(0, h * 0.5, 0), wood, 0.6 if ghost else 0.0, not ghost)
		for i in drawers:
			var y := 0.25 + i * 0.4
			Vox.box(_geo, Vector3(0.84, 0.32, 0.06), Vector3(0, y, 0.52), wood.lightened(0.15), 0.0, not ghost)
			Vox.box(_geo, Vector3(0.24, 0.06, 0.06), Vector3(0, y, 0.56), c if i < keys.size() else Color(0.7, 0.7, 0.7), 0.4 if i < keys.size() else 0.0)
	# A little lamp: the state at a glance.
	_lamp = Vox.box(_geo, Vector3(0.16, 0.16, 0.16), Vector3(0.5, 1.7 if is_secret() else 0.5 + 0.4 * clampi(keys.size(), 2, 5), 0.3),
		Vox.RED if ghost else (Vox.SLATE if dusty else Vox.GREEN), 1.5, false)


func _process(delta: float) -> void:
	_t += delta
	position = position.lerp(target, clampf(delta * 3.0, 0.0, 1.0))
	if _lamp and missing():
		_lamp.visible = fmod(_t, 0.6) < 0.35
