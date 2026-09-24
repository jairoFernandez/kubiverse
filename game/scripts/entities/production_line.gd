class_name ProductionLine
extends Entity
## HALL level: a Deployment / StatefulSet / DaemonSet as an assembly line.
## Console at the start shows desired vs ready replicas; each pod is a robot
## working at one station along the conveyor. The belt runs only while some
## replicas are ready.

const STATION := 2.0
const START := 3.0

var stations := 1
var length := 4.0
var _geo: Node3D
var _belt_bars: Array[MeshInstance3D] = []
var _crates: Array[MeshInstance3D] = []
var _sig := ""
var _t := 0.0


func _init() -> void:
	kind = "workload"


func update_data(d: Dictionary, n_pods: int) -> void:
	data = d
	key = "%s/%s/%s" % [d.ns, d.kind, d.name]
	stations = maxi(1, maxi(int(d.desired), n_pods))
	length = START + stations * STATION
	var sig := "%d|%d|%d|%s" % [int(d.desired), int(d.ready), stations, d.kind]
	if sig != _sig:
		_sig = sig
		_rebuild()


func station_position(i: int) -> Vector3:
	return target + Vector3(START + (i + 0.5) * STATION - 0.6, 0, 1.25)


func label_text() -> String:
	return "%s %s" % [str(data.get("kind", "")).to_lower(), data.get("name", "")]


func label_sub() -> String:
	return tr("%d of %d replicas ready") % [int(data.get("ready", 0)), int(data.get("desired", 0))]


func label_color() -> Color:
	var desired := int(data.get("desired", 0))
	var ready := int(data.get("ready", 0))
	if desired == 0:
		return Vox.SILVER
	if ready >= desired:
		return Vox.GREEN
	return Vox.YELLOW if ready > 0 else Vox.RED


func anchor() -> Vector3:
	return global_position + Vector3(0.6, 3.0, 0)


## Solid parts the player cannot walk through (x, z, w, d in world space).
func blockers() -> Array[Rect2]:
	return [Rect2(target.x - 0.4, target.z - 1.0, 2.2, 2.0), Rect2(target.x + 1.8, target.z - 0.6, length - 1.8, 1.2)]


func _rebuild() -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	_belt_bars.clear()
	_crates.clear()
	var nsc := Vox.ns_color(data.get("ns", ""))
	var desired := int(data.get("desired", 0))
	var ready := int(data.get("ready", 0))
	# Control console
	Vox.box(_geo, Vector3(1.6, 1.4, 1.6), Vector3(0.6, 0.7, 0), nsc.darkened(0.35))
	Vox.box(_geo, Vector3(1.4, 0.8, 0.1), Vector3(0.6, 1.3, 0.82), Color("0b0d1a"), 0.0, false)
	# Replica lamps on the console screen: lit = ready
	var n := mini(desired, 8)
	for i in n:
		var lit := i < ready
		Vox.box(_geo, Vector3(0.12, 0.12, 0.05), Vector3(0.1 + (i % 4) * 0.32, 1.45 - (i / 4) * 0.3, 0.88), Vox.GREEN if lit else Vox.RED.darkened(0.3), 2.0 if lit else 0.4, false)
	# Kind icon on top
	var icon := Node3D.new()
	icon.position = Vector3(0.6, 2.0, 0)
	icon.name = "Icon"
	_geo.add_child(icon)
	match data.get("kind", ""):
		"StatefulSet":
			for i in 3:
				Vox.box(icon, Vector3(0.7, 0.14, 0.7), Vector3(0, i * 0.18, 0), nsc if i % 2 == 0 else nsc.darkened(0.3))
		"DaemonSet":
			for i in 3:
				Vox.box(icon, Vector3(0.8 - i * 0.25, 0.18, 0.8 - i * 0.25), Vector3(0, i * 0.18, 0), nsc)
		_:
			var c := Vox.box(icon, Vector3(0.5, 0.5, 0.5), Vector3(0, 0.2, 0), nsc)
			c.rotation = Vector3(deg_to_rad(45), 0, deg_to_rad(35))
	# Conveyor: frame, rollers, moving bars
	var belt_len := length - 1.8
	var bx := 1.8 + belt_len * 0.5
	Vox.box(_geo, Vector3(belt_len, 0.5, 1.2), Vector3(bx, 0.25, 0), Color("3a3f55"))
	Vox.box(_geo, Vector3(belt_len, 0.06, 1.0), Vector3(bx, 0.53, 0), Color("22252f"), 0.0, false)
	for i in int(belt_len / 0.8):
		var bar := Vox.box(_geo, Vector3(0.12, 0.04, 0.96), Vector3(1.9 + i * 0.8, 0.57, 0), Color("4a4f66"), 0.0, false)
		_belt_bars.append(bar)
	for x in [1.9, 1.8 + belt_len - 0.1]:
		for z in [-0.55, 0.55]:
			Vox.box(_geo, Vector3(0.14, 0.5, 0.14), Vector3(x, 0.25, z), Vox.YELLOW, 0.0, false)
	# Station markers (where each pod-robot works)
	for i in stations:
		var sx := START + (i + 0.5) * STATION - 0.6
		Vox.box(_geo, Vector3(1.4, 0.03, 1.1), Vector3(sx, 0.02, 1.25), Vox.YELLOW.darkened(0.45) if i < desired else Color("2a2d3a"), 0.0, false)
	# Products riding the belt
	for i in 3:
		var crate := Vox.box(_geo, Vector3(0.4, 0.35, 0.4), Vector3(2.0, 0.75, 0), [Vox.BROWN, Vox.PEACH, nsc][i])
		crate.set_meta("off", float(i) / 3.0)
		_crates.append(crate)


func _process(delta: float) -> void:
	_t += delta
	position = position.lerp(target, clampf(delta * 3.0, 0.0, 1.0))
	var ready := int(data.get("ready", 0))
	var desired := maxi(1, int(data.get("desired", 1)))
	var speed := 1.2 * float(ready) / desired
	var belt_len := length - 1.8
	for i in _belt_bars.size():
		var bar := _belt_bars[i]
		bar.position.x = 1.9 + fposmod(i * 0.8 + _t * speed, belt_len - 0.2)
	for c in _crates:
		c.visible = ready > 0
		c.position.x = 1.9 + fposmod(float(c.get_meta("off")) * belt_len + _t * speed, belt_len - 0.3)
	var icon: Node3D = _geo.get_node_or_null("Icon") if _geo else null
	if icon:
		icon.rotation.y += delta
