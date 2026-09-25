class_name PVTank
extends Entity
## A PersistentVolume in the storage yard: a big tank with its size written
## on it, full to its claim's real use (when Prometheus knows it). Bound ones
## are green, Available ones waiting for a claim are blue, Released ones
## (their claim is gone, the data may still be there) orange, Failed red.

var used_pct := -1.0   # the claim's real use, set by World
var _geo: Node3D
var _sig := ""


func _init() -> void:
	kind = "pv"


static func status_color(d: Dictionary) -> Color:
	match str(d.get("status", "")):
		"Bound": return Vox.GREEN
		"Available": return Vox.BLUE
		"Released": return Vox.ORANGE
	return Vox.RED


func update_data(d: Dictionary, use := -1.0) -> void:
	data = d
	key = str(d.name)
	used_pct = use
	var sig := "%s|%s|%d" % [d.get("status", ""), d.get("capacity", ""), int(use / 5.0)]
	if sig != _sig:
		_sig = sig
		_rebuild()


func label_text() -> String:
	return "pv " + str(data.get("name", ""))


func label_sub() -> String:
	var claim := str(data.get("claim", ""))
	var s := "%s %s" % [data.get("capacity", ""), data.get("status", "")]
	if claim != "":
		s += " - " + claim
	if used_pct >= 0.0:
		s += " - " + tr("%d%% used") % int(used_pct)
	return s


func label_color() -> Color:
	return status_color(data)


func anchor() -> Vector3:
	return global_position + Vector3(0, 3.4, 0)


func _rebuild() -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	var c := status_color(data)
	var shell := Color(0.62, 0.64, 0.7)
	Vox.box(_geo, Vector3(2.0, 0.2, 2.0), Vector3(0, 0.1, 0), Vox.SLATE)
	for i in 5:
		var y := 0.45 + i * 0.5
		Vox.box(_geo, Vector3(1.7, 0.46, 1.7), Vector3(0, y, 0), shell)
		Vox.box(_geo, Vector3(1.9, 0.34, 1.3), Vector3(0, y, 0), shell.darkened(0.08))
		Vox.box(_geo, Vector3(1.3, 0.34, 1.9), Vector3(0, y, 0), shell.darkened(0.08))
	Vox.box(_geo, Vector3(1.2, 0.2, 1.2), Vector3(0, 2.8, 0), shell.lightened(0.1))
	# The level gauge: the real use, or full when bound without numbers.
	var level := 2.3
	if used_pct >= 0.0:
		level = maxf(0.08, 2.3 * clampf(used_pct / 100.0, 0.0, 1.0))
	elif str(data.get("status", "")) != "Bound":
		level = 0.3
	var gauge := Vox.RED if used_pct >= 90.0 else c
	Vox.box(_geo, Vector3(0.34, 2.36, 0.06), Vector3(0, 1.4, 0.96), Color(0.05, 0.05, 0.08))
	Vox.box(_geo, Vector3(0.26, level, 0.08), Vector3(0, 0.25 + level * 0.5, 0.98), gauge, 1.2, false)
	Vox.box(_geo, Vector3(0.3, 0.3, 0.3), Vector3(0, 3.05, 0), c, 1.8, false)
