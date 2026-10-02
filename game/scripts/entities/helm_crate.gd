class_name HelmCrate
extends Entity
## Helm in the basement of a hall, as shipping crates:
##   kind "helm"      - a release: a big crate in Helm's navy with the wheel,
##                      its status lamp and revision; an umbrella chart has
##                      its subcharts around it, linked by pipes;
##   kind "chart"     - a chart of a release (a subchart of an umbrella):
##                      a smaller crate, the objects it made on its label;
##   kind "repochart" - a chart in a chart repository (ChartMuseum) on the
##                      repository's shelves.

const NAVY := Color("0f1689")
const WHEEL := Color("e8eaf6")

var _geo: Node3D
var _lamp: MeshInstance3D
var _sig := ""
var _t := 0.0
var size := 1.6


func setup(k: String, d: Dictionary, key_: String) -> void:
	kind = k
	key = key_
	data = d
	var sig := "%s|%s|%s|%s" % [k, d.get("status", ""), d.get("version", ""), d.get("umbrella", false)]
	match k:
		"helm": size = 2.6 if d.get("umbrella", false) else 2.2
		"chart": size = 1.5
		_: size = 0.8
	if sig != _sig:
		_sig = sig
		_rebuild()


func status_color() -> Color:
	match str(data.get("status", "deployed")):
		"deployed": return Vox.GREEN
		"failed": return Vox.RED
		"superseded", "uninstalled": return Vox.SILVER
	return Vox.YELLOW   # pending-install / pending-upgrade / pending-rollback / uninstalling


func label_text() -> String:
	match kind:
		"helm":
			return ("umbrella " if data.get("umbrella", false) else "") + "helm release " + str(data.get("name", ""))
		"chart":
			return ("subchart %s" if not data.get("parent", false) else "chart %s") % data.get("name", "")
	return "chart " + str(data.get("name", ""))


func label_sub() -> String:
	match kind:
		"helm":
			var ch := str(data.get("chart", ""))
			var n := (data.get("charts", []) as Array).size()
			var what := ch if ch != "" else (tr("%d charts") % n)
			return "%s · rev %d · %s" % [what, int(data.get("revision", 0)), tr(str(data.get("status", "deployed")))]
		"chart":
			var objs: Array = (data.get("workloads", []) as Array) + (data.get("services", []) as Array).map(func(s): return "Service/" + s)
			var shown := ", ".join(objs.slice(0, 2).map(func(o): return str(o).to_lower()))
			return "%s%s%s" % [data.get("version", ""), "  " + shown if shown != "" else "", " +%d" % (objs.size() - 2) if objs.size() > 2 else ""]
	return "%s · %d %s" % [data.get("version", ""), int(data.get("versions", 1)), tr("versions")]


func label_color() -> Color:
	return status_color() if kind == "helm" else (Color("8fa8ff") if kind == "chart" else Vox.SILVER)


func anchor() -> Vector3:
	return global_position + Vector3(0, size + 0.9, 0)


func pick_radius() -> float:
	return 30.0 if kind != "repochart" else 18.0


func build_box() -> AABB:
	return AABB(Vector3(-size * 0.5, 0, -size * 0.5), Vector3(size, size, size))


func _rebuild() -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	var s := size
	var body := NAVY if kind == "helm" else (Color("2a3a9c") if kind == "chart" else Color("3b4a7a"))
	Vox.box(_geo, Vector3(s, s, s), Vector3(0, s * 0.5, 0), body)
	# Wooden slats on the edges, like a shipping crate.
	var slat := Color("c47a2c") if kind != "repochart" else Color("a0612a")
	var t := 0.08 * s
	for y in [t * 0.5, s - t * 0.5]:
		Vox.box(_geo, Vector3(s + 0.04, t, s + 0.04), Vector3(0, y, 0), slat, 0.0, false)
	for x in [-1, 1]:
		for z in [-1, 1]:
			Vox.box(_geo, Vector3(t, s, t), Vector3(x * (s * 0.5 - t * 0.4), s * 0.5, z * (s * 0.5 - t * 0.4)), slat, 0.0, false)
	# Helm's wheel on the front: a hub and its spokes, in voxels.
	if kind != "repochart":
		var r := s * 0.28
		var face := Vector3(0, s * 0.52, s * 0.5 + 0.03)
		Vox.box(_geo, Vector3(r * 0.5, r * 0.5, 0.04), face, WHEEL, 0.5, false)
		for i in 6:
			var a := TAU * i / 6.0
			var spoke := Vox.box(_geo, Vector3(r * 2.1, 0.07 * s, 0.04), face, WHEEL, 0.4, false)
			spoke.rotation.z = a
	if kind == "helm":
		_lamp = Vox.box(_geo, Vector3.ONE * 0.36, Vector3(0, s + 0.25, 0), status_color(), 2.5, false)
		_lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Umbrella: an umbrella on the lid, the charts it bundles below it.
		if data.get("umbrella", false):
			Vox.box(_geo, Vector3(0.1, 1.2, 0.1), Vector3(s * 0.3, s + 0.6, 0), Vox.SILVER, 0.0, false)
			for i in 5:
				var w := 1.6 - absf(i - 2) * 0.45
				Vox.box(_geo, Vector3(w, 0.12, 0.3), Vector3(s * 0.3, s + 1.2 - absf(i - 2) * 0.12, (i - 2) * 0.28), Vox.PINK if i % 2 == 0 else Vox.WHITE, 0.2, false)


func _process(delta: float) -> void:
	_t += delta
	if _lamp and str(data.get("status", "")).begins_with("pending"):
		_lamp.visible = fmod(_t, 0.6) < 0.4
